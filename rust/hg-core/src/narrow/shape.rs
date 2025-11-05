//! The core of the logic for narrow shapes, which enable a composable algebra
//! for slicing a repo's history along its files.

use std::collections::HashSet;
use std::io::Write;
use std::path::Path;
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::RwLockReadGuard;
use std::sync::RwLockWriteGuard;

use itertools::Itertools;
use lazy_static::lazy_static;
use regex::Regex;
use serde::Deserialize;
use serde::Serialize;
use sha2::Digest;
use sha2::Sha256;

use crate::errors::HgError;
use crate::exit_codes;
use crate::file_patterns::FilePattern;
use crate::file_patterns::PatternError;
use crate::file_patterns::PatternSyntax;
use crate::matchers::AlwaysMatcher;
use crate::matchers::DifferenceMatcher;
use crate::matchers::Matcher;
use crate::matchers::NeverMatcher;
use crate::matchers::PatternMatcher;
use crate::matchers::UnionMatcher;
use crate::repo::Repo;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::hg_path::HgPathError;
use crate::FastHashMap;

lazy_static! {
    /// Only lower case ASCII alpha num, `-` and `.`
    static ref SHARD_NAME_REGEX: Regex =
        Regex::new(r"^[-\.[[:lower:]][[:digit:]]]+$").unwrap();
}

/// Canonical name within a repo for a [`Shard`].
/// Is restricted in which bytes can be used, see [`Self::new`].
#[derive(Debug, Clone, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct ShardName(String);

impl std::fmt::Display for ShardName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

impl ShardName {
    fn new(name: String) -> Result<Self, HgError> {
        if !SHARD_NAME_REGEX.is_match(&name) {
            let msg = format!(
                "shard name '{}' is invalid: \
                only lowercase alphanumeric ascii, `-` and `.` are supported.",
                &name
            );
            return Err(HgError::abort_simple(msg));
        }
        Ok(Self(name))
    }
}

/// Defines a subset of files in this repo's history.
/// Shards in a repo's [`ShardSet`] are mutually exclusive.
///
/// This is a "config-facing" or "admin-facing" concept and should not be
/// apparent to most users.
#[derive(Debug, Clone, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct Shard {
    /// The canonical name for this shard for a given repo
    name: ShardName,
    /// The repo paths that this shard covers across the history of its repo
    paths: Vec<HgPathBuf>,
    /// Other shards that this shard depends on
    requires: Vec<ShardName>,
    /// Whether this shard can be used within or as a [`Shape`]
    shape: bool,
}

/// The set of all [`Shard`] that make up a repository.
///
/// TODO make this self-referencing if all the cloning ends up being expensive
#[derive(Debug)]
pub struct ShardSet {
    /// All [`Shard`] in the current repo, mapped by their [`ShardName`]
    shards: FastHashMap<ShardName, Shard>,
    /// All paths explicitly declared by the shards, mapped to their shard
    path_to_shard: FastHashMap<HgPathBuf, Shard>,
}

impl ShardSet {
    pub fn from_repo_config(repo: &Repo) -> Result<Self, HgError> {
        let ShapesConfig { version, mut shards } =
            match repo.store_vfs().try_read("server-shapes")? {
                Some(data) => toml::from_slice(&data).map_err(|e| {
                    HgError::abort(
                        e.to_string(),
                        exit_codes::CONFIG_PARSE_ERROR_ABORT,
                        None,
                    )
                })?,
                None => ShapesConfig::default(),
            };
        if version != 0 {
            return Err(HgError::abort(
                format!("unknown server-shapes version {}", version),
                exit_codes::CONFIG_ERROR_ABORT,
                None,
            ));
        }
        let shards_len_before = shards.len();
        shards.push(ShardConfig {
            name: "base".to_string(),
            paths: Some(vec!["".to_string()]),
            shape: true,
            requires: None,
        });
        shards.push(ShardConfig {
            name: "full".to_string(),
            paths: None,
            shape: true,
            requires: Some(
                shards
                    .iter()
                    .map(|shard| shard.name.to_owned())
                    .sorted()
                    .collect(),
            ),
        });
        let reserved_range = shards_len_before..shards.len();
        let mut path_to_shard = FastHashMap::default();
        let mut validated_shards = FastHashMap::default();
        shards.into_iter().enumerate().try_for_each(|(idx, config)| {
            Self::validate_shard(
                config,
                !reserved_range.contains(&idx),
                &mut path_to_shard,
                &mut validated_shards,
            )
        })?;
        Ok(Self { shards: validated_shards, path_to_shard })
    }

    /// Make sure the shard config is valid, create the shard struct and add
    /// to the path -> shard mapping
    fn validate_shard(
        shard_config: ShardConfig,
        user_provided: bool,
        path_to_shard: &mut FastHashMap<HgPathBuf, Shard>,
        shards: &mut FastHashMap<ShardName, Shard>,
    ) -> Result<(), HgError> {
        let ShardConfig { name, shape, paths, requires } = shard_config;
        if user_provided && matches!(name.as_str(), "base" | "full") {
            let msg = format!("shard name '{}' is reserved", &name);
            return Err(HgError::abort(
                msg,
                exit_codes::CONFIG_ERROR_ABORT,
                None,
            ));
        }

        if paths.is_none() && requires.is_none() {
            let msg =
                format!("shard '{}' needs one of `paths` or `requires`", &name);
            return Err(HgError::abort(
                msg,
                exit_codes::CONFIG_ERROR_ABORT,
                None,
            ));
        }

        let mut hg_paths = vec![];
        if let Some(config_paths) = paths {
            for path in config_paths {
                let on_err = |e| {
                    let msg = format!(
                        "invalid path {} in server-shapes: {}",
                        &path,
                        HgPathError::from(e)
                    );
                    HgError::abort(msg, exit_codes::CONFIG_ERROR_ABORT, None)
                };
                let hg_path = HgPathBuf::from_bytes(
                    path.as_bytes()
                        .strip_suffix(b"/")
                        .unwrap_or(path.as_bytes()),
                );
                hg_path.check_state().map_err(on_err)?;
                hg_paths.push(hg_path);
            }
        }

        let mut requires_names = vec![];
        if let Some(requirements) = requires {
            for requirement in requirements {
                let name = ShardName::new(requirement)?;
                requires_names.push(name);
            }
        }
        requires_names.sort();

        let name = ShardName::new(name)?;
        let shard = Shard {
            name: name.to_owned(),
            paths: hg_paths.to_owned(),
            requires: requires_names,
            shape,
        };
        for path in hg_paths {
            if path_to_shard.insert(path.to_owned(), shard.to_owned()).is_some()
            {
                return Err(HgError::abort(
                    format!(
                        "path '{}' is in two separate shards",
                        String::from_utf8_lossy(path.as_bytes())
                    ),
                    exit_codes::CONFIG_ERROR_ABORT,
                    None,
                ));
            }
        }

        if shards.insert(name.to_owned(), shard).is_some() {
            return Err(HgError::abort(
                format!("shard '{}' defined twice", name),
                exit_codes::CONFIG_ERROR_ABORT,
                None,
            ));
        }
        Ok(())
    }

    /// Return all user-facing [`Shard`] as [`Shape`]
    pub fn all_shapes(&self) -> Result<Vec<Shape>, HgError> {
        let mut all: Vec<_> =
            self.shards.iter().filter(|(_, shard)| shard.shape).collect();
        all.sort();
        all.into_iter()
            .map(|(name, shard)| Shape::new(name.to_owned(), self, &[shard]))
            .collect()
    }

    /// Return the [`Shape`] of name `name`, or `None`.
    pub fn shape(&self, name: &str) -> Result<Option<Shape>, HgError> {
        let shard_name = ShardName::new(name.to_string())?;
        if let Some(shard) = self.shards.get(&shard_name) {
            if shard.shape {
                let shape = Shape::new(shard_name, self, &[shard])?;
                return Ok(Some(shape));
            }
        }
        Ok(None)
    }

    fn dependencies<'a>(
        &'a self,
        shard: &'a Shard,
    ) -> Result<FastHashMap<&'a ShardName, &'a Shard>, HgError> {
        // TODO cache dependencies?
        let mut all = FastHashMap::default();

        for name in &shard.requires {
            let mut to_visit = vec![name];
            let mut visited = HashSet::new();
            visited.insert(name);

            while let Some(name) = to_visit.pop() {
                let current_shard = &self.shards[name];

                for direct_dependency in &current_shard.requires {
                    let new_visit = visited.insert(direct_dependency);
                    if !new_visit {
                        return Err(HgError::abort(
                            format!(
                                "shard '{}' creates a cycle with '{}'",
                                name, direct_dependency
                            ),
                            exit_codes::CONFIG_ERROR_ABORT,
                            None,
                        ));
                    };

                    to_visit.push(direct_dependency);
                }
            }
            all.extend(
                visited.into_iter().map(|name| (name, &self.shards[name])),
            );
        }

        Ok(all)
    }
}

/// Represents a named narrow view into the repo's files (at the history level).
///
/// This is a user-facing concept.
pub struct Shape {
    name: ShardName,
    tree: ShardTreeNode,
}

impl Shape {
    pub fn new(
        name: ShardName,
        shard_set: &ShardSet,
        shards: &[&Shard],
    ) -> Result<Self, HgError> {
        let mut expanded_shards = vec![];
        for shard in shards {
            expanded_shards.push(*shard);
            expanded_shards.extend(shard_set.dependencies(shard)?.values())
        }
        let tree = ShardTreeNode::from_shards(shard_set, &expanded_shards)?;
        Ok(Self { name, tree })
    }

    /// Returns a [`Matcher`] that expresses the constraints of this shape
    pub fn matcher(&self) -> Box<dyn Matcher + Send> {
        self.tree.matcher()
    }

    pub fn store_fingerprint(&self) -> [u8; 32] {
        self.tree.fingerprint()
    }

    pub fn patterns(&self) -> (Vec<HgPathBuf>, Vec<HgPathBuf>) {
        let (includes, excludes) = self.tree.flat();
        (
            includes.into_iter().map(|i| i.to_hg_path_buf()).collect(),
            excludes.into_iter().map(|i| i.to_hg_path_buf()).collect(),
        )
    }

    pub fn name(&self) -> &ShardName {
        &self.name
    }
}

/// Matches the os-disk config for a single shard inside the [`ShapesConfig`]
#[derive(Serialize, Deserialize)]
struct ShardConfig {
    /// Canonical name for this shard. Used both in UI and protocol
    name: String,
    #[serde(default)]
    /// Whether this shard is also a user-accessible shape
    shape: bool,
    /// The paths that this shard concerns. Can only be none if this shard
    /// has [`Self::requires`]
    paths: Option<Vec<String>>,

    // TODO encoded paths for non-utf8 paths
    // encoded_paths: Option<Vec<String>>,
    /// Names of the shards that this shard depends on, to build a hierarchy
    requires: Option<Vec<String>>,
}

/// Matches the on-disk format for admins to define their repo's shards and
/// shapes
#[derive(Serialize, Deserialize, Default)]
pub struct ShapesConfig {
    // XXX should there be a `[meta]` section?
    /// The version of this config. For now only version `0` exists.
    version: u32,
    /// The shards and shapes defined by the repo's admins.
    shards: Vec<ShardConfig>,
}

/// A node within a tree of narrow patterns.
///
/// It is used to create a normalized representation of potentially nested
/// include and exclude patterns to uniquely identify semantically equivalent
/// rules, as well as generating an associated file matcher.
#[derive(Debug, Clone)]
pub struct ShardTreeNode {
    /// The path (rooted by `b""`) that this node concerns
    path: ZeroPath,
    /// Whether this path is included or excluded
    included: bool,
    /// The set of child nodes (describing rules for sub-paths)
    children: Vec<Arc<PanickingRwLock<ShardTreeNode>>>,
}

impl ShardTreeNode {
    /// Create the tree expressed by the server shapes config
    pub fn from_shards<'a>(
        shard_set: &'a ShardSet,
        shards: &[&'a Shard],
    ) -> Result<Self, HgError> {
        let mut shard_paths = HashSet::new();
        // Gather all paths recursively
        for shard in shards {
            shard_paths.extend(shard.paths.iter().map(|path| path.as_bytes()));
            shard_paths.extend(
                shard_set
                    .dependencies(shard)?
                    .values()
                    .flat_map(|shard| &shard.paths)
                    .map(|p| p.as_bytes()),
            );
        }
        assert!(!shard_paths.is_empty());
        Self::from_paths(
            shard_set.path_to_shard.keys().map(|path| path.as_bytes()),
            shard_paths,
        )
    }

    /// Create the tree expressed by old-style include and exclude patterns
    pub fn from_patterns<'a>(
        includes: &'a [FilePattern],
        excludes: &'a [FilePattern],
    ) -> Result<Self, HgError> {
        let check_pattern = |pattern: &'a FilePattern| {
            if pattern.syntax != PatternSyntax::Path {
                let syntax = format!("{:?}", pattern.syntax);
                Err(PatternError::UnsupportedSyntax(syntax))
            } else {
                Ok(pattern.raw.as_slice())
            }
        };
        let mut include_paths = includes
            .iter()
            .map(check_pattern)
            .collect::<Result<HashSet<&[u8]>, _>>()
            .map_err(|e| HgError::abort_simple(e.to_string()))?;

        let exclude_paths = excludes
            .iter()
            .map(check_pattern)
            .collect::<Result<HashSet<&[u8]>, _>>()
            .map_err(|e| HgError::abort_simple(e.to_string()))?;

        let empty_path = b"".as_slice();
        // `clone` passes `path:.` by default which is supposed to include
        // everything. This is the wrong API IMO and is a serialization detail
        // hitting internal logic (empty paths are annoying in text formats).
        let empty_path_alt = b".".as_slice();

        let root = if include_paths.contains(&empty_path)
            || include_paths.contains(&empty_path_alt)
            || include_paths.is_empty()
        {
            include_paths.remove(&empty_path_alt);
            // Need to include everything by default
            include_paths.insert(empty_path);
            vec![]
        } else {
            vec![empty_path]
        };

        Self::from_paths(
            root.into_iter().chain(include_paths.clone()).chain(exclude_paths),
            include_paths,
        )
    }

    /// `paths` is the iterator of all paths (included or not) and `includes`
    /// contains only the paths that are included.
    fn from_paths<Paths, Bytes>(
        paths: Paths,
        includes: HashSet<&[u8]>,
    ) -> Result<Self, HgError>
    where
        Paths: Iterator<Item = Bytes>,
        Bytes: AsRef<[u8]>,
    {
        // Generate a flat sequence of nodes, sorted via ZeroPath
        let nodes = paths
            .map(|path| {
                Arc::new(PanickingRwLock::new(Self {
                    path: ZeroPath::new(path.as_ref()),
                    included: includes.contains(path.as_ref()),
                    children: vec![],
                }))
            })
            .sorted_by(|a, b| a.read().path.cmp(&b.read().path));

        // Create the tree by looping over the nodes and keeping track of
        // where we are in the recursion via a stack
        let mut stack: Vec<Arc<PanickingRwLock<Self>>> = vec![];
        for node in nodes {
            while !stack.is_empty()
                && !node
                    .read()
                    .sub_path_of(&stack.last().expect("not empty").read())
            {
                stack.pop();
            }
            if let Some(last) = stack.last_mut() {
                // Only insert children that are not redundant
                if last.read().included != node.read().included {
                    last.write().children.push(node.clone());
                }
            }
            stack.push(node);
        }
        let root = stack.into_iter().next().expect("should have one element");
        let root = Arc::into_inner(root)
            .expect("should have only one ref")
            .into_inner();

        Ok(root)
    }

    /// Returns a [`Matcher`] that expresses the constraints of this node
    pub fn matcher(&self) -> Box<dyn Matcher + Send> {
        let top_matcher = if self.path.is_empty() {
            // We're the root node
            if self.included {
                Box::new(AlwaysMatcher) as Box<dyn Matcher + Send>
            } else {
                Box::new(NeverMatcher) as Box<dyn Matcher + Send>
            }
        } else {
            Box::new(
                PatternMatcher::new(vec![FilePattern::new(
                    PatternSyntax::Path,
                    HgPathBuf::from(&self.path).as_bytes(),
                    Path::new(".hg/store/server-shapes"),
                )])
                .expect("patterns based on paths should always be valid"),
            ) as Box<dyn Matcher + Send>
        };
        if self.children.is_empty() {
            return top_matcher;
        }
        let sub_matcher = if self.children.len() == 1 {
            self.children[0].read().matcher()
        } else {
            let subs: Vec<_> = self
                .children
                .iter()
                .map(|child| child.read().matcher())
                .collect();
            Box::new(UnionMatcher::new(subs)) as Box<dyn Matcher + Send>
        };

        if self.path.is_empty() && !self.included {
            return sub_matcher;
        }
        Box::new(DifferenceMatcher::new(top_matcher, sub_matcher))
    }

    /// Get the fingerprint for this node. It will return a different hash for
    /// a semantically different node, allowing for a quick comparison.
    pub fn fingerprint(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        self.serialize(&mut hasher).expect("writing to a hasher never fails");
        hasher.finalize().into()
    }

    /// `true` if `self` is a sub-path of `other`
    fn sub_path_of(&self, other: &Self) -> bool {
        self.path.starts_with(&other.path)
    }

    /// Return the node normalized as two flat sets of includes and excludes
    fn flat(&self) -> (Vec<ZeroPath>, Vec<ZeroPath>) {
        let mut includes = vec![];
        let mut excludes = vec![];

        if self.included {
            includes.push(self.path.clone());
        } else {
            excludes.push(self.path.clone());
        }

        for child in self.children.iter() {
            let (sub_includes, sub_excludes) = child.read().flat();
            includes.extend(sub_includes);
            excludes.extend(sub_excludes);
        }

        (includes, excludes)
    }

    /// Serialize this node with the following binary format:
    ///
    /// `<HEADER>\n<NUM>\n[<MARKER>/<PATH>\n...]`
    ///
    /// With:
    ///   - `<HEADER>` being the literal ascii bytes `shape-v1` to help identify
    ///     the format easily, and as a sanity check
    ///   - `<NUM>` is the number of paths as a little-endian 64bits integer
    ///   - `[X...]` is syntax for "for each element, do X"
    ///   - `<MARKER>` is either the literal ascii bytes `inc` or `exc`,
    ///     depending on whether this path is included or excluded
    ///   - `<PATH>` is the raw bytes of each path, rooted at the empty path
    fn serialize(&self, mut buf: impl Write) -> Result<(), std::io::Error> {
        let (includes, excludes) = self.flat();

        buf.write_all(b"shape-v1\n")?;
        let sorted_paths = includes
            .into_iter()
            .map(|i| (i, true))
            .chain(excludes.into_iter().map(|i| (i, false)))
            // sort by zero path so we get the children next to the parents
            .sorted_by(|a, b| a.0.cmp(&b.0));

        let number_of_paths: u64 =
            sorted_paths.len().try_into().expect("too many paths");
        buf.write_all(&number_of_paths.to_le_bytes())?;
        for (zero_path, included) in sorted_paths {
            buf.write_all(if included { b"inc" } else { b"exc" })?;
            buf.write_all(b"/")?;
            buf.write_all(zero_path.to_hg_path_buf().as_bytes())?;
            buf.write_all(b"\n")?;
        }

        Ok(())
    }
}

/// An [`HgPathBuf`] with all `/` in `path` replaced with `\0`, and surrounded
/// by `\0`.
/// This ensures that a path and its subpath get sorted next to each other
#[derive(Clone, Hash, PartialEq, Eq, PartialOrd, Ord)]
struct ZeroPath(Vec<u8>);

impl std::fmt::Debug for ZeroPath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_tuple("ZeroPath").field(&self.to_hg_path_buf()).finish()
    }
}

impl ZeroPath {
    fn new(bytes: &[u8]) -> Self {
        let mut path = Vec::with_capacity(bytes.len());
        for (idx, byte) in bytes.iter().enumerate() {
            if idx == 0 {
                assert_ne!(*byte, b'/');
                path.push(b'\0');
            }
            assert_ne!(*byte, b':');
            assert_ne!(*byte, b'\0');
            if idx == bytes.len() - 1 {
                assert_ne!(*byte, b'/');
                path.push(*byte);
                path.push(b'\0');
            } else if *byte == b'/' {
                path.push(b'\0');
            } else {
                path.push(*byte);
            }
        }
        if path.is_empty() {
            path.push(b'\0');
        }
        Self(path)
    }

    fn is_empty(&self) -> bool {
        self.0 == b"\0"
    }

    fn to_hg_path_buf(&self) -> HgPathBuf {
        self.into()
    }

    fn starts_with(&self, other: &Self) -> bool {
        self.0.starts_with(&other.0)
    }
}

impl From<&HgPath> for ZeroPath {
    fn from(path: &HgPath) -> Self {
        Self::new(path.as_bytes())
    }
}

impl From<&ZeroPath> for HgPathBuf {
    fn from(path: &ZeroPath) -> Self {
        let bytes = path.0.as_slice();
        let mut path = Vec::with_capacity(bytes.len());
        for (idx, byte) in bytes.iter().enumerate() {
            if idx == 0 {
                assert_eq!(*byte, b'\0');
                continue;
            }
            assert_ne!(*byte, b':');
            assert_ne!(*byte, b'/');
            if idx == bytes.len() - 1 {
                assert_eq!(*byte, b'\0');
                continue;
            } else if *byte == b'\0' {
                path.push(b'/');
            } else {
                path.push(*byte);
            }
        }
        path.into()
    }
}

#[derive(Debug)]
/// Quality-of-life struct to help with unwrapping panics by default.
/// We only need a [`RwLock`] to work around the borrow checker for the tree
/// structure (RefCell wouldn't work because we need to be [`Sync`] + [`Send`]),
/// we don't *actually* do anything concurrent, so this is fine if the
/// implementation is correct, which it would break very loudly if it weren't.
struct PanickingRwLock<T: ?Sized>(RwLock<T>);

impl<T> PanickingRwLock<T> {
    pub fn new(inner: T) -> Self {
        Self(RwLock::new(inner))
    }

    pub fn read(&self) -> RwLockReadGuard<T> {
        self.0.read().expect("propagate panic")
    }

    pub fn write(&self) -> RwLockWriteGuard<T> {
        self.0.write().expect("propagate panic")
    }

    pub fn into_inner(self) -> T
    where
        T: Sized,
    {
        self.0.into_inner().expect("propagate panic")
    }
}
