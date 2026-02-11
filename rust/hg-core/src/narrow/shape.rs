//! The core of the logic for narrow shapes, which enable a composable algebra
//! for slicing a repo's history along its files.

use std::collections::HashSet;
use std::io::Write;
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

use crate::FastHashMap;
use crate::errors::HgError;
use crate::exit_codes;
use crate::file_patterns::FilePattern;
use crate::file_patterns::PatternError;
use crate::file_patterns::PatternSyntax;
use crate::matchers::ShapeMatcher;
use crate::repo::Repo;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::hg_path::HgPathError;
use crate::utils::hg_path::HgPathErrorKind;

lazy_static! {
    /// Only lower case ASCII alpha num, `-` and `.`
    static ref SHARD_NAME_REGEX: Regex =
        Regex::new(r"^[-\.[[:lower:]][[:digit:]]]+$").unwrap();

    /// Special files that need to be included in every single shape
    static ref HG_FILES_SHARD_PATHS: Vec<String> = vec![
        ".hgignore".to_string(),
        ".hgtags".to_string(),
        ".hgsub".to_string(),
        ".hgsubstate".to_string(),
    ];
}

/// Errors specific to handling shapes
#[derive(Debug, PartialEq)]
pub enum Error {
    /// A shard was declared with an empty name
    EmptyShardName,
    /// A shard was declared with a name that only has dots and/or hyphens
    DotOrHyphenOnlyShardName(String),
    /// A shard was declared with an invalid name that is not only dots
    /// and/or hyphens
    InvalidShardName(String),
    /// A shard was declared with a reserved name
    ReservedName(String),
    /// The following shards form a cycle
    CycleInShards(Vec<ShardName>),
    /// This path was found in two (or more) separate shards
    PathInMultipleShards(HgPathBuf),
    /// Two (or more) shards share the same name
    DuplicateShard(ShardName),
    /// This shard was defined without `paths` and `requires`
    ShardMissingPathsAndRequires(String),
    /// An invalid file pattern was given
    PatternError(PatternError),
    /// The config contains an invalid path, with this error
    InvalidPath(HgPathError),
    /// This config parsed correctly, but is of this unknown version
    UnknownVersion(usize),
    /// The config failed to parse, here is the error
    ParseError(toml::de::Error),
}

impl From<Error> for HgError {
    fn from(value: Error) -> Self {
        let exit_code = match value {
            Error::EmptyShardName
            | Error::DotOrHyphenOnlyShardName(_)
            | Error::InvalidShardName(_)
            | Error::ReservedName(_)
            | Error::CycleInShards(_)
            | Error::PathInMultipleShards(_)
            | Error::DuplicateShard(_)
            | Error::ShardMissingPathsAndRequires(_)
            | Error::InvalidPath(_)
            | Error::UnknownVersion(_) => exit_codes::CONFIG_ERROR_ABORT,
            Error::ParseError(_) => exit_codes::CONFIG_PARSE_ERROR_ABORT,
            Error::PatternError(_) => exit_codes::INPUT_ERROR,
        };
        let explanation = match value {
            Error::EmptyShardName => {
                "shard names must not be empty".to_string()
            }
            Error::DotOrHyphenOnlyShardName(name) => format!(
                "invalid shard name '{name}': \
                missing lowercase alphanumeric character"
            ),
            Error::InvalidShardName(name) => format!(
                "invalid shard name '{name}': \
                only lowercase alphanumeric, hyphen or dot are accepted"
            ),
            Error::ReservedName(name) => {
                format!("shard name '{name}' is reserved")
            }
            Error::CycleInShards(shard_names) => {
                let cycle = shard_names.into_iter().join("->");
                format!("shards form a cycle: {cycle}")
            }
            Error::PathInMultipleShards(path) => {
                format!(
                    "path is found in multiple shards: {}",
                    String::from_utf8_lossy(path.as_bytes())
                )
            }
            Error::DuplicateShard(name) => {
                format!("shard '{name}' defined multiple times")
            }
            Error::ShardMissingPathsAndRequires(name) => {
                format!("shard '{name}' needs one of `paths` or `requires`")
            }
            Error::InvalidPath(err) => {
                format!("`server-shapes` contains an invalid path: {err}")
            }
            Error::UnknownVersion(version) => {
                format!("unknown `server-shapes` version '{version}'")
            }
            Error::ParseError(err) => {
                format!("error parsing `server-shapes`:\n{err}")
            }
            Error::PatternError(err) => {
                format!("invalid pattern {err}")
            }
        };

        Self::abort(explanation, exit_code, None)
    }
}

const HG_FILES_SHARD: &str = ".hg-files";

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
    fn new(name: String) -> Result<Self, Error> {
        if name.is_empty() {
            return Err(Error::EmptyShardName);
        }
        if name.as_bytes().iter().all(|b| *b == b'.' || *b == b'-') {
            return Err(Error::DotOrHyphenOnlyShardName(name));
        }
        if !SHARD_NAME_REGEX.is_match(&name) {
            return Err(Error::InvalidShardName(name));
        }
        Ok(Self(name))
    }
}

/// Defines a subset of files in this repo's history.
/// Shards in a repo's [`StoreShards`] are mutually exclusive.
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
pub struct StoreShards {
    /// All [`Shard`] in the current repo, mapped by their [`ShardName`]
    shards: FastHashMap<ShardName, Shard>,
    /// All paths explicitly declared by the shards, mapped to their shard
    path_to_shard: FastHashMap<HgPathBuf, Shard>,
}

impl StoreShards {
    #[tracing::instrument(level = "debug", skip_all)]
    pub fn from_repo_config(repo: &Repo) -> Result<Self, HgError> {
        let config = match repo.store_vfs().try_read("server-shapes")? {
            Some(data) => toml::from_slice(&data).map_err(|e| {
                // We've failed to parse this to the expected structure,
                // it could be for many different reasons.
                // Give a better error message if it's only because it's a
                // different version that also turns out to be incompatible
                // with this deserialization.
                // It's a little fragile, but it's better than nothing.
                let re = regex::bytes::Regex::new(r"^version\s*=\s*(\d+)$")
                    .expect("valid regex");
                if let Some(captures) = re.captures(&data)
                    && let Some(version) = captures.get(1)
                {
                    let version = String::from_utf8_lossy(version.as_bytes())
                        .parse::<usize>()
                        .expect("parsing an integer from a regex");
                    return Error::UnknownVersion(version);
                }
                Error::ParseError(e)
            })?,
            None => ShapesConfig::default(),
        };
        Ok(Self::from_config(config)?)
    }

    pub(crate) fn from_config(config: ShapesConfig) -> Result<Self, Error> {
        let ShapesConfig { version, mut shards } = config;
        if version != 0 {
            return Err(Error::UnknownVersion(version as usize));
        }
        let shards_len_before = shards.len();
        shards.push(ShardConfig {
            name: "base".to_string(),
            paths: Some(vec!["".to_string()]),
            shape: false,
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
        // This shard is included in all other shards. Having a shape that
        // doesn't include those special files seems like an anti-feature.
        shards.push(ShardConfig {
            name: HG_FILES_SHARD.to_string(),
            paths: Some(HG_FILES_SHARD_PATHS.clone()),
            shape: false,
            requires: None,
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

        let slf = Self { shards: validated_shards, path_to_shard };
        // Make sure we can generate all shapes and catch the last errors
        slf.all_shapes()?;
        Ok(slf)
    }

    /// Make sure the shard config is valid, create the shard struct and add
    /// to the path -> shard mapping
    fn validate_shard(
        shard_config: ShardConfig,
        user_provided: bool,
        path_to_shard: &mut FastHashMap<HgPathBuf, Shard>,
        shards: &mut FastHashMap<ShardName, Shard>,
    ) -> Result<(), Error> {
        let ShardConfig { name, shape, paths, requires } = shard_config;
        if user_provided
            && matches!(name.as_str(), "base" | "full" | HG_FILES_SHARD)
        {
            return Err(Error::ReservedName(name));
        }

        if paths.is_none() && requires.is_none() {
            return Err(Error::ShardMissingPathsAndRequires(name));
        }

        let mut hg_paths = vec![];
        if let Some(config_paths) = paths {
            for path in config_paths {
                let on_err = |e: HgPathErrorKind| Error::InvalidPath(e.into());
                let hg_path = HgPathBuf::from_bytes(
                    path.as_bytes()
                        .strip_suffix(b"/")
                        .unwrap_or(path.as_bytes()),
                );
                hg_path.check_state().map_err(on_err)?;
                hg_paths.push(hg_path);
            }
        }

        let mut requires_names = if name != HG_FILES_SHARD {
            let hg_files_shard_name =
                ShardName::new(HG_FILES_SHARD.to_string())
                    .expect("valid shard name");
            vec![hg_files_shard_name]
        } else {
            vec![]
        };
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
                return Err(Error::PathInMultipleShards(path));
            }
        }

        if shards.insert(name.to_owned(), shard).is_some() {
            return Err(Error::DuplicateShard(name));
        }
        Ok(())
    }

    /// Return all user-facing [`Shard`] as [`Shape`]
    pub fn all_shapes(&self) -> Result<Vec<Shape>, Error> {
        let mut all: Vec<_> =
            self.shards.iter().filter(|(_, shard)| shard.shape).collect();
        all.sort();
        all.into_iter()
            .map(|(name, shard)| Shape::new(name.to_owned(), self, &[shard]))
            .collect()
    }

    /// Return the [`Shape`] of name `name`, or `None`.
    pub fn shape(&self, name: &str) -> Result<Option<Shape>, Error> {
        let shard_name = ShardName::new(name.to_string())?;
        if let Some(shard) = self.shards.get(&shard_name)
            && shard.shape
        {
            let shape = Shape::new(shard_name, self, &[shard])?;
            return Ok(Some(shape));
        }
        Ok(None)
    }

    /// Gather all recursive dependent shards for `shard`
    fn dependencies<'a>(
        &'a self,
        shard: &'a Shard,
    ) -> Result<FastHashMap<&'a ShardName, &'a Shard>, Error> {
        let mut acc = FastHashMap::default();
        self.dependencies_from(shard, &[], &mut acc)?;
        Ok(acc)
    }

    /// Gather all recursive dependent shards for `shard`, given that the path
    /// through dependencies is `from` (to detect cycles) and we should
    /// accumulate the dependencies in `acc`.
    fn dependencies_from<'a>(
        &'a self,
        shard: &'a Shard,
        from: &[&'a ShardName],
        acc: &mut FastHashMap<&'a ShardName, &'a Shard>,
    ) -> Result<(), Error> {
        // TODO cache dependencies?
        for name in &shard.requires {
            if from.contains(&name) {
                let mut cycle: Vec<ShardName> =
                    from.iter().map(|n| (*n).to_owned()).collect();
                cycle.push(name.to_owned());
                return Err(Error::CycleInShards(cycle));
            }
            let sub_shard = &self.shards[name];
            acc.insert(name, sub_shard);
            let mut from = from.to_vec();
            from.push(name);
            self.dependencies_from(sub_shard, &from, acc)?;
        }

        Ok(())
    }
}

/// Represents a named narrow view into the repo's files (at the history level).
///
/// This is a user-facing concept.
#[derive(Debug, Clone)]
pub struct Shape {
    name: ShardName,
    pub(crate) tree: ShardTreeNode,
}

impl Shape {
    pub fn new(
        name: ShardName,
        store_shards: &StoreShards,
        shards: &[&Shard],
    ) -> Result<Self, Error> {
        let mut expanded_shards = vec![];
        for shard in shards {
            expanded_shards.push(*shard);
            expanded_shards.extend(store_shards.dependencies(shard)?.values())
        }
        let tree = ShardTreeNode::from_shards(store_shards, &expanded_shards)?;
        Ok(Self { name, tree })
    }

    /// Returns a [`Matcher`] that expresses the constraints of this shape
    pub fn matcher(&self) -> ShapeMatcher {
        ShapeMatcher::new(self.to_owned())
    }

    pub fn store_fingerprint(&self) -> [u8; 32] {
        self.tree.fingerprint()
    }

    pub fn patterns(&self) -> (Vec<HgPathBuf>, Vec<HgPathBuf>) {
        self.tree.flat()
    }

    pub fn name(&self) -> &ShardName {
        &self.name
    }

    pub fn from_patterns(
        includes: &[FilePattern],
        excludes: &[FilePattern],
    ) -> Result<Self, Error> {
        let tree = ShardTreeNode::from_patterns(includes, excludes)?;
        let name = ShardName::new("hg-internal".into()).expect("valid name");
        Ok(Self { name, tree })
    }
}

/// Matches the os-disk config for a single shard inside the [`ShapesConfig`]
#[derive(Debug, Serialize, Deserialize)]
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
#[derive(Debug, Serialize, Deserialize, Default)]
pub struct ShapesConfig {
    // XXX should there be a `[meta]` section?
    /// The version of this config. For now only version `0` exists.
    version: u32,
    /// The shards and shapes defined by the repo's admins.
    shards: Vec<ShardConfig>,
}

/// A temporary structure useful to create a [`ShardTreeNode`], since it
/// temporarily requires mutable aliasing.
#[derive(Clone)]
pub struct TempShardTreeNode {
    /// The [`ZeroPath`] (rooted by `b""`) that this node concerns
    path: ZeroPath,
    /// Whether this path is included or excluded
    included: bool,
    /// The set of mutably aliased child nodes (describing rules for sub-paths)
    children: Vec<Arc<PanickingRwLock<Self>>>,
}

impl std::fmt::Debug for TempShardTreeNode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TempShardTreeNode")
            .field("path", &self.path)
            .field("included", &self.included)
            // Remove the `RwLock` noise from the debug output
            .field(
                "children",
                &self
                    .children
                    .iter()
                    .map(|node| node.read().to_owned())
                    .collect::<Vec<Self>>(),
            )
            .finish()
    }
}

impl TempShardTreeNode {
    /// `true` if `self` is a sub-path of `other`
    fn sub_path_of(&self, other: &Self) -> bool {
        // Paths are both `ZeroPath`, which ensures this property.
        self.path.sub_path_of(&other.path)
    }
    /// Create a [`ShardTreeNode`] from this finished temp tree
    fn finish(&self) -> ShardTreeNode {
        ShardTreeNode {
            path: HgPathBuf::from(&self.path),
            included: self.included,
            children: self
                .children
                .iter()
                .map(|child| child.read().finish())
                .collect(),
        }
    }
}

/// A node within a tree of narrow patterns.
///
/// It is used to create a normalized representation of potentially nested
/// include and exclude patterns to uniquely identify semantically equivalent
/// rules, as well as generating an associated file matcher.
#[derive(Clone, Debug)]
pub struct ShardTreeNode {
    /// The path (rooted by `b""`) that this node concerns
    pub(crate) path: HgPathBuf,
    /// Whether this path is included or excluded
    pub(crate) included: bool,
    /// The set of child nodes (describing rules for sub-paths)
    pub(crate) children: Vec<Self>,
}

impl ShardTreeNode {
    /// Create the tree expressed by the server shapes config
    pub fn from_shards<'a>(
        store_shards: &'a StoreShards,
        shards: &[&'a Shard],
    ) -> Result<Self, Error> {
        let mut shard_paths = HashSet::new();
        // Gather all paths recursively
        for shard in shards {
            shard_paths.extend(shard.paths.iter().map(|path| path.as_bytes()));
            shard_paths.extend(
                store_shards
                    .dependencies(shard)?
                    .values()
                    .flat_map(|shard| &shard.paths)
                    .map(|p| p.as_bytes()),
            );
        }
        assert!(!shard_paths.is_empty());
        Self::from_paths(
            store_shards.path_to_shard.keys().map(|path| path.as_bytes()),
            shard_paths,
        )
    }

    /// Create the tree expressed by old-style include and exclude patterns
    pub fn from_patterns<'a>(
        includes: &'a [FilePattern],
        excludes: &'a [FilePattern],
    ) -> Result<Self, Error> {
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
            .map_err(Error::PatternError)?;

        let exclude_paths = excludes
            .iter()
            .map(check_pattern)
            .collect::<Result<HashSet<&[u8]>, _>>()
            .map_err(Error::PatternError)?;

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
    ) -> Result<Self, Error>
    where
        Paths: Iterator<Item = Bytes>,
        Bytes: AsRef<[u8]>,
    {
        // Generate a flat sequence of nodes, sorted via ZeroPath
        let mut nodes = paths
            .map(|path| {
                Ok(Arc::new(PanickingRwLock::new(TempShardTreeNode {
                    path: ZeroPath::new(path.as_ref())?,
                    included: includes.contains(path.as_ref()),
                    children: vec![],
                })))
            })
            .collect::<Result<Vec<_>, Error>>()?;
        nodes.sort_by(|a, b| a.read().path.cmp(&b.read().path));

        // Create the tree by looping over the nodes and keeping track of
        // where we are in the recursion via a stack
        let mut stack: Vec<Arc<PanickingRwLock<TempShardTreeNode>>> = vec![];
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
                    stack.push(node);
                }
            } else {
                stack.push(node);
            }
        }
        let root = stack.into_iter().next().expect("should have one element");
        let root = Arc::into_inner(root)
            .expect("should have only one ref")
            .into_inner();

        Ok(root.finish())
    }

    /// Do not call this directly, use [`deepest_prefix_node`].
    fn deepest_node_impl(&self, path: &HgPath, skip: usize) -> Option<&Self> {
        let path_bytes = path.as_bytes();
        let self_bytes = self.path.as_bytes();

        // If the matched path doesn't match the current node, exit.
        if !self_bytes.is_empty() // The root node matches all
            && !(
                // The matched path starts with the node path
                path_bytes[skip..].starts_with(&self_bytes[skip..])
                // ...up to a directory boundary or the end of the path
                && (path_bytes.len() == self_bytes.len()
                    || (path_bytes[self_bytes.len()] == b'/')))
        {
            return None;
        }

        // Check if a child has a better match
        for child in &self.children {
            assert_ne!(self.included, child.included);
            let c_match = child.deepest_node_impl(path, self_bytes.len());
            if c_match.is_some() {
                // There can only be up to one matching child.
                //
                // The tree optimization ensures that the inclusion value of a
                // node is always different than the inclusion value of its
                // children. As a result, all children have the same inclusion
                // value.
                //
                // So if two children were to match, it would mean that one of
                // them would be a prefix of the other, with the same inclusion
                // value, at the same level. In this  case the node with the
                // longer match would be redundant with the other one, but in
                // practice such nodes have been optimized away already.
                return c_match;
            }
        }
        Some(self)
    }

    /// Get the fingerprint for this node. It will return a different hash for
    /// a semantically different node, allowing for a quick comparison.
    pub fn fingerprint(&self) -> [u8; 32] {
        let mut hasher = Sha256::new();
        self.serialize(&mut hasher).expect("writing to a hasher never fails");
        hasher.finalize().into()
    }

    /// Return the node normalized as two flat sets of includes and excludes
    fn flat(&self) -> (Vec<HgPathBuf>, Vec<HgPathBuf>) {
        let mut includes = vec![];
        let mut excludes = vec![];

        if self.included {
            includes.push(self.path.clone());
        } else {
            excludes.push(self.path.clone());
        }

        for child in self.children.iter() {
            let (sub_includes, sub_excludes) = child.flat();
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
        for (path, included) in sorted_paths {
            buf.write_all(if included { b"inc" } else { b"exc" })?;
            buf.write_all(b"/")?;
            buf.write_all(path.as_bytes())?;
            buf.write_all(b"\n")?;
        }

        Ok(())
    }
}

/// Returns the deepest node in `root` whose path is a prefix of
/// (or is exactly) `path`.
///
/// # Panics
///
/// Panics if `root` is not the root node (i.e. if it has a non-empty path).
pub(crate) fn deepest_prefix_node<'tree>(
    root: &'tree ShardTreeNode,
    path: &HgPath,
) -> &'tree ShardTreeNode {
    assert!(root.path.is_empty());
    if path.is_empty() {
        return root;
    }
    root.deepest_node_impl(path, 0).unwrap_or(root)
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
    fn new(bytes: &[u8]) -> Result<Self, Error> {
        let mut path = Vec::with_capacity(bytes.len());
        for (idx, byte) in bytes.iter().enumerate() {
            if idx == 0 {
                if *byte == b'/' {
                    let err = HgPathErrorKind::LeadingSlash(bytes.to_owned());
                    return Err(Error::InvalidPath(err.into()));
                }
                path.push(b'\0');
            }
            assert_ne!(*byte, b'\0');
            if idx == bytes.len() - 1 {
                if *byte == b'/' {
                    let err = HgPathErrorKind::EndsWithSlash(
                        HgPathBuf::from_bytes(bytes),
                    );
                    return Err(Error::InvalidPath(err.into()));
                }
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
        Ok(Self(path))
    }

    fn to_hg_path_buf(&self) -> HgPathBuf {
        self.into()
    }

    fn sub_path_of(&self, other: &Self) -> bool {
        self.0.starts_with(&other.0)
    }
}

impl TryFrom<&HgPath> for ZeroPath {
    type Error = Error;

    fn try_from(path: &HgPath) -> Result<Self, Error> {
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

    pub fn read(&self) -> RwLockReadGuard<'_, T> {
        self.0.read().expect("propagate panic")
    }

    pub fn write(&self) -> RwLockWriteGuard<'_, T> {
        self.0.write().expect("propagate panic")
    }

    pub fn into_inner(self) -> T
    where
        T: Sized,
    {
        self.0.into_inner().expect("propagate panic")
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::matchers::Matcher;
    use crate::matchers::VisitChildrenSet;

    /// produce a valid store sharding
    ///
    /// See [`test_patterns`] for each shard patterns.
    fn valid_store_shards() -> (StoreShards, Vec<&'static str>) {
        // Leading whitespace does not matter in TOML, I think this is more
        // readable
        let valid_config = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]
            requires = ["baz", "base"]
            shape = true

            [[shards]]
            name = "stone"
            paths = ["stone"]
            shape = true

            [[shards]]
            name = "lizard"
            paths = ["stone/liz/ard"]

            [[shards]]
            name = "lizzie"
            paths = ["stone/liz/zie"]

            [[shards]]
            name = "borden"
            paths = ["stone/liz/zie/bor/den"]
            requires = ["stone"]
            shape = true

            [[shards]]
            name = "mummy"
            paths = ["stone/mummy"]
            shape = true

            [[shards]]
            name = "chamber"
            paths = ["stone/mummy/chamber"]
            requires = ["stone"]
            shape = true

            [[shards]]
            name = "inner"
            paths = ["stone/mummy/chamber/inner"]

            [[shards]]
            name = "bar"
            paths = ["bar"]
            shape = true

            [[shards]]
            name = "baz"
            paths = ["bar/baz"]

            [[shards]]
            name = "bazik"
            paths = ["bar/baz/ik"]
            requires = ["bar"]
            shape = true

            [[shards]]
            name = "baziku"
            paths = ["bar/baz/ik/u"]

            [[shards]]
            name = "baron"
            requires = ["bar", "baziku"]
            shape = true

            [[shards]]
            name = "nested"
            paths = ["some/super/nested/file"]
            shape = true
        "#;

        // Make sure we can load this config
        let config_result = toml::from_str::<ShapesConfig>(valid_config);
        assert!(config_result.is_ok(), "{:?}", config_result);
        let config = config_result.unwrap();

        // We can create a storeshards
        let store_shards_result = StoreShards::from_config(config);
        assert!(store_shards_result.is_ok(), "{:?}", store_shards_result);
        let store_shards = store_shards_result.unwrap();

        let all_shard_names = vec![
            ".hg-files",
            "bar",
            "baron",
            "base",
            "baz",
            "bazik",
            "baziku",
            "borden",
            "chamber",
            "foo",
            "full",
            "inner",
            "lizard",
            "lizzie",
            "mummy",
            "nested",
            "stone",
        ];
        // Shards are as expected, along with the implicit shards
        assert_eq!(
            all_shard_names,
            store_shards
                .shards
                .keys()
                .sorted()
                .map(|k| k.to_string())
                .collect::<Vec<_>>(),
        );

        let all_shape_names = vec![
            "bar", "baron", "bazik", "borden", "chamber", "foo", "full",
            "mummy", "nested", "stone",
        ];
        // Shapes are as expected, along with the implicit shapes
        assert_eq!(
            all_shape_names,
            store_shards
                .all_shapes()
                .unwrap()
                .into_iter()
                .map(|shape| shape.name().to_string())
                .collect::<Vec<_>>(),
        );
        (store_shards, all_shape_names)
    }

    #[test]
    fn test_dependencies() {
        let (store_shards, _) = valid_store_shards();

        fn assert_dependencies(
            store_shards: &StoreShards,
            shard_name: &str,
            expected: Vec<&str>,
        ) {
            let dependencies = store_shards
                .dependencies(
                    &store_shards.shards
                        [&ShardName::new(shard_name.to_string()).unwrap()],
                )
                .unwrap()
                .into_keys()
                .sorted()
                .map(|n| n.to_string());
            let dependencies = dependencies.collect::<Vec<String>>();
            assert_eq!(expected, dependencies, "for shard {}", shard_name);
        }

        assert_dependencies(&store_shards, "bar", vec![".hg-files"]);
        assert_dependencies(
            &store_shards,
            "foo",
            vec![".hg-files", "base", "baz"],
        );
        assert_dependencies(
            &store_shards,
            "full",
            vec![
                ".hg-files",
                "bar",
                "baron",
                "base",
                "baz",
                "bazik",
                "baziku",
                "borden",
                "chamber",
                "foo",
                "inner",
                "lizard",
                "lizzie",
                "mummy",
                "nested",
                "stone",
            ],
        );
    }

    #[test]
    fn test_patterns() {
        let (store_shards, all_shape_names) = valid_store_shards();

        fn assert_patterns(
            store_shards: &StoreShards,
            shard_name: &str,
            expected_includes: &[&str],
            expected_excludes: &[&str],
        ) {
            let shape = store_shards.shape(shard_name).unwrap().unwrap();
            dbg!(&shard_name);
            dbg!(&shape.tree);
            let (includes, excludes) = shape.patterns();
            let expected_includes = expected_includes
                .iter()
                .map(|p| HgPathBuf::from_bytes(p.as_bytes()))
                .collect::<Vec<_>>();
            let expected_excludes = expected_excludes
                .iter()
                .map(|p| HgPathBuf::from_bytes(p.as_bytes()))
                .collect::<Vec<_>>();
            assert_eq!(
                expected_includes, includes,
                "wrong includes for shape {}",
                shard_name
            );
            assert_eq!(
                expected_excludes, excludes,
                "wrong excludes for shape {}",
                shard_name
            );
        }

        // Test the patterns for each shape (<include>, <exclude>)
        type Patterns<'a> = (&'a [&'a str], &'a [&'a str]);
        let shape_to_patterns: &[(&str, Patterns)] = &[
            ("full", (&[""], &[])),
            (
                "bar",
                (
                    &[".hgignore", ".hgsub", ".hgsubstate", ".hgtags", "bar"],
                    &["", "bar/baz"],
                ),
            ),
            (
                "baron",
                (
                    &[
                        ".hgignore",
                        ".hgsub",
                        ".hgsubstate",
                        ".hgtags",
                        "bar",
                        "bar/baz/ik/u",
                    ],
                    &["", "bar/baz"],
                ),
            ),
            (
                "bazik",
                (
                    &[
                        ".hgignore",
                        ".hgsub",
                        ".hgsubstate",
                        ".hgtags",
                        "bar",
                        "bar/baz/ik",
                    ],
                    &["", "bar/baz", "bar/baz/ik/u"],
                ),
            ),
            (
                "foo",
                (
                    &["", "bar/baz"],
                    &["bar", "bar/baz/ik", "some/super/nested/file", "stone"],
                ),
            ),
            (
                "stone",
                (
                    &[".hgignore", ".hgsub", ".hgsubstate", ".hgtags", "stone"],
                    &["", "stone/liz/ard", "stone/liz/zie", "stone/mummy"],
                ),
            ),
            (
                "borden",
                (
                    &[
                        ".hgignore",
                        ".hgsub",
                        ".hgsubstate",
                        ".hgtags",
                        "stone",
                        "stone/liz/zie/bor/den",
                    ],
                    &["", "stone/liz/ard", "stone/liz/zie", "stone/mummy"],
                ),
            ),
            (
                "mummy",
                (
                    &[
                        ".hgignore",
                        ".hgsub",
                        ".hgsubstate",
                        ".hgtags",
                        "stone/mummy",
                    ],
                    &["", "stone/mummy/chamber"],
                ),
            ),
            (
                "chamber",
                (
                    &[
                        ".hgignore",
                        ".hgsub",
                        ".hgsubstate",
                        ".hgtags",
                        "stone",
                        "stone/mummy/chamber",
                    ],
                    &[
                        "",
                        "stone/liz/ard",
                        "stone/liz/zie",
                        "stone/mummy",
                        "stone/mummy/chamber/inner",
                    ],
                ),
            ),
            (
                "nested",
                (
                    &[
                        ".hgignore",
                        ".hgsub",
                        ".hgsubstate",
                        ".hgtags",
                        "some/super/nested/file",
                    ],
                    &[""],
                ),
            ),
        ];

        for (shard_name, (expected_includes, expected_excludes)) in
            shape_to_patterns
        {
            assert_patterns(
                &store_shards,
                shard_name,
                expected_includes,
                expected_excludes,
            );
        }

        // Make sure we've tested all names
        assert_eq!(
            all_shape_names,
            shape_to_patterns
                .iter()
                .map(|(n, _)| *n)
                .sorted()
                .collect::<Vec<&str>>(),
        );
    }

    /// Test that every shape matches the right files
    #[test]
    fn test_matcher_simple() {
        let (store_shards, all_shape_names) = valid_store_shards();

        let files_to_shape: &[(&str, &[&str])] = &[
            // the core mercurial file shoudl always be included
            (".hgignore", &all_shape_names),
            (".hgsub", &all_shape_names),
            (".hgsubstate", &all_shape_names),
            (".hgtags", &all_shape_names),
            // babar is not matched by any explicit shard,
            // So it selected by "base". In addition "foo" depends on "base"
            ("babar/v", &["full", "foo"]),
            // `bar/` is matched by the "bar" shard and its dependencies
            ("bar/ba/v", &["full", "bar", "baron", "bazik"]),
            // we match full name only
            ("barbar/v", &["full", "foo"]),
            // However `bar/baz` is explicitly matched by "baz" (a shard), so
            // it isn't contained in "bar". It appears in "foo" (a
            // shape that include on "baz")
            ("bar/baz/f", &["full", "foo"]),
            ("bar/baz/g", &["full", "foo"]),
            ("bar/baz/i", &["full", "foo"]),
            ("bar/baz/blu/toto", &["full", "foo"]),
            // We match full name only
            ("bar/bazar", &["full", "bar", "baron", "bazik"]),
            // Again `bar/bar/ik` is matched by the "bazik" shard so it is
            // considered independently
            ("bar/baz/ik/U/j", &["full", "bazik"]),
            ("bar/baz/ik/U/k", &["full", "bazik"]),
            ("bar/baz/ik/U/m", &["full", "bazik"]),
            ("bar/baz/ik/h", &["full", "bazik"]),
            ("bar/baz/ik/i", &["full", "bazik"]),
            ("bar/baz/ik/o/l", &["full", "bazik"]),
            // `bar/baz/ik/u` is part of the "baziku" shard included in the
            // "baron" sharp
            ("bar/baz/ik/u/j", &["full", "baron"]),
            ("bar/baz/ik/u/k", &["full", "baron"]),
            ("bar/baz/ik/u/m", &["full", "baron"]),
            ("bar/baz/ik/u/klm/foo", &["full", "baron"]),
            // We match full name only
            ("bar/baz/ik/ups", &["full", "bazik"]),
            ("bar/baz/ik/ups/klm/bar", &["full", "bazik"]),
            // both "baron" and "bazik" includes "bar"
            ("bar/d", &["full", "bar", "baron", "bazik"]),
            ("bar/e", &["full", "bar", "baron", "bazik"]),
            // `foo/` is matched by the "foo" shape and no other
            ("foo/a", &["full", "foo"]),
            ("foo/b", &["full", "foo"]),
            ("foo/c", &["full", "foo"]),
            ("foo/y", &["full", "foo"]),
            // `stone/liz/` has three excluded directory within
            ("stone/foo", &["full", "stone", "borden", "chamber"]),
            ("stone/liz", &["full", "stone", "borden", "chamber"]),
            ("stone/mummy", &["full", "mummy"]),
            ("stone/mummy/return", &["full", "mummy"]),
            ("stone/mummy/chamber", &["full", "chamber"]),
            ("stone/mummy/chamber/inner", &["full"]),
            ("stone/mummy/chamber/babar", &["full", "chamber"]),
            ("stone/mummy/chamber/inner/babar", &["full"]),
            (
                "stone/liz/chamber/babar",
                &["full", "stone", "borden", "chamber"],
            ),
            ("stone/liz/chamber", &["full", "stone", "borden", "chamber"]),
            (
                "stone/liz/chamber/inner",
                &["full", "stone", "borden", "chamber"],
            ),
            (
                "stone/liz/chamber/inner/babar",
                &["full", "stone", "borden", "chamber"],
            ),
            ("stone/liz/foo", &["full", "stone", "borden", "chamber"]),
            ("stone/liz/babar", &["full", "stone", "borden", "chamber"]),
            ("stone/liz/ard", &["full"]),
            ("stone/liz/ard/babar", &["full"]),
            ("stone/liz/on", &["full", "stone", "borden", "chamber"]),
            ("stone/liz/on/babar", &["full", "stone", "borden", "chamber"]),
            ("stone/liz/zie", &["full"]),
            ("stone/liz/zie/babar", &["full"]),
            ("stone/liz/zie/bor", &["full"]),
            ("stone/liz/zie/bor/den", &["full", "borden"]),
            ("stone/liz/zie/bor/den/babar", &["full", "borden"]),
            // various unmatched stuff
            ("oops", &["full", "foo"]),
            ("some/super/other/nested", &["full", "foo"]),
            ("w", &["full", "foo"]),
            ("y", &["full", "foo"]),
            ("z", &["full", "foo"]),
        ];

        let shape_to_matcher: Vec<_> = all_shape_names
            .iter()
            .map(|name| {
                let shape = store_shards.shape(name).unwrap().unwrap();
                let matcher = shape.matcher();
                (shape.name().to_string(), matcher)
            })
            .collect();
        for (file, expected_shapes) in files_to_shape {
            let mut expected: Vec<_> = expected_shapes.to_vec();
            expected.sort();
            let file = HgPath::new(file.as_bytes());

            let matching: Vec<_> = shape_to_matcher
                .iter()
                .filter(|(_, matcher)| matcher.matches(file))
                .map(|(name, _)| name)
                .collect();
            assert_eq!(
                &expected, &matching,
                "file '{file}' doesn't match the expected shapes"
            );
        }
    }

    #[test]
    fn test_deepest_prefix_node() {
        let (store_shards, _) = valid_store_shards();

        #[track_caller]
        fn assert_node(node: &ShardTreeNode, expect: &[u8]) {
            assert_eq!(node.path.as_ref(), HgPath::new(expect));
        }

        // Full should always return the root node
        let shape = store_shards.shape("full").unwrap().unwrap();
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b""));
        assert_node(node, b"");
        assert_eq!(node.included, true);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"root"));
        assert_node(node, b"");
        assert_eq!(node.included, true);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"bar/baz"));
        assert_node(node, b"");
        assert_eq!(node.included, true);

        // Test simple nested shape
        let shape = store_shards.shape("bar").unwrap().unwrap();
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b""));
        assert_node(node, b"");
        assert_eq!(node.included, false);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"root"));
        assert_node(node, b"");
        assert_eq!(node.included, false);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"bar/test"));
        assert_node(node, b"bar");
        assert_eq!(node.included, true);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"bar/baz"));
        assert_node(node, b"bar/baz");
        assert_eq!(node.included, false);
        let node = deepest_prefix_node(
            &shape.tree,
            HgPath::new(b"bar/baz/nested/deeper"),
        );
        assert_node(node, b"bar/baz");
        assert_eq!(node.included, false);

        // Test doubly nested shape
        let shape = store_shards.shape("baron").unwrap().unwrap();
        dbg!(&shape);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b""));
        assert_node(node, b"");
        assert_eq!(node.included, false);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"root"));
        assert_node(node, b"");
        assert_eq!(node.included, false);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"bar/test"));
        assert_node(node, b"bar");
        assert_eq!(node.included, true);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"bar/baz"));
        assert_node(node, b"bar/baz");
        assert_eq!(node.included, false);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"bar/bazik"));
        assert_node(node, b"bar");
        assert_eq!(node.included, true);
        let node = deepest_prefix_node(
            &shape.tree,
            HgPath::new(b"bar/baz/nested/deeper"),
        );
        assert_node(node, b"bar/baz");
        assert_eq!(node.included, false);
        let node =
            deepest_prefix_node(&shape.tree, HgPath::new(b"bar/baz/ik/u"));
        assert_node(node, b"bar/baz/ik/u");
        assert_eq!(node.included, true);
        let node =
            deepest_prefix_node(&shape.tree, HgPath::new(b"bar/baz/ik/ui"));
        assert_node(node, b"bar/baz");
        assert_eq!(node.included, false);

        let shape = store_shards.shape("stone").unwrap().unwrap();
        dbg!(&shape.tree);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"stone/liz"));
        assert_node(node, b"stone");
        assert_eq!(node.included, true);

        let shape = store_shards.shape("borden").unwrap().unwrap();
        dbg!(&shape.tree);
        let node =
            deepest_prefix_node(&shape.tree, HgPath::new(b"stone/liz/zie/bor"));
        assert_node(node, b"stone/liz/zie");
        assert_eq!(node.included, false);

        let shape = store_shards.shape("mummy").unwrap().unwrap();
        dbg!(&shape.tree);
        let node = deepest_prefix_node(
            &shape.tree,
            HgPath::new(b"stone/mummy/chamber"),
        );
        assert_node(node, b"stone/mummy/chamber");
        assert_eq!(node.included, false);
    }

    #[test]
    fn test_matcher_visit_children_set() {
        let (store_shards, _all_shape_names) = valid_store_shards();
        let shape = store_shards.shape("bar").unwrap().unwrap();
        let matcher = shape.matcher();
        // Test an exact match on a non-included node
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(
                ["bar", ".hgignore", ".hgsubstate", ".hgtags", ".hgsub"]
                    .iter()
                    .map(|path| HgPathBuf::from_bytes(path.as_bytes()))
                    .collect()
            )
        );
        // Test an exact match on an included node
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"bar")),
            VisitChildrenSet::Recursive,
        );
        // Test a prefix match on an included node
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"bar/file")),
            VisitChildrenSet::Recursive,
        );
        // Test a no match
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"other")),
            VisitChildrenSet::Empty,
        );

        let shape = store_shards.shape("bazik").unwrap().unwrap();
        let matcher = shape.matcher();
        // Test an exact match on a non-included node, through a `requires`
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"")),
            VisitChildrenSet::Set(
                ["bar", ".hgignore", ".hgsubstate", ".hgtags", ".hgsub"]
                    .iter()
                    .map(|path| HgPathBuf::from_bytes(path.as_bytes()))
                    .collect()
            )
        );
        // Test a nested no-match
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"bar/baz/other")),
            VisitChildrenSet::Empty
        );
        // Test a prefix match on a non-included-non-root node
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"bar/baz")),
            VisitChildrenSet::Set(HashSet::from_iter([HgPathBuf::from_bytes(
                b"bar/baz/ik"
            )]))
        );
        // Test a nested exact match
        assert_eq!(
            matcher.visit_children_set(HgPath::new(b"bar/baz/ik")),
            VisitChildrenSet::Recursive
        );
    }

    #[test]
    fn test_config_invalid() {
        let pairs = &[
            (
                r#"
                version=0
                [[shards]]
                name="full"
                paths=[""]
            "#,
                Error::ReservedName("full".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="base"
                paths=[""]
            "#,
                Error::ReservedName("base".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name=".hg-files"
                paths=[""]
            "#,
                Error::ReservedName(".hg-files".to_string()),
            ),
            (
                r#"
                version=999
                [[shards]]
                name="babar"
                paths=["babar"]
            "#,
                Error::UnknownVersion(999),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="Babar"
                paths=["babar"]
            "#,
                Error::InvalidShardName("Babar".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name=""
                paths=["babar"]
            "#,
                Error::EmptyShardName,
            ),
            (
                r#"
                version=0
                [[shards]]
                name="."
                paths=["babar"]
            "#,
                Error::DotOrHyphenOnlyShardName(".".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="-"
                paths=["babar"]
            "#,
                Error::DotOrHyphenOnlyShardName("-".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="-.-"
                paths=["babar"]
            "#,
                Error::DotOrHyphenOnlyShardName("-.-".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="duplicate"
                paths=["babar"]
                [[shards]]
                name="duplicate"
                paths=["babar2"]
            "#,
                Error::DuplicateShard(
                    ShardName::new("duplicate".to_string()).unwrap(),
                ),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="too-little"
            "#,
                Error::ShardMissingPathsAndRequires("too-little".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name = "myshard"
                paths = ["secret"]
                [[shards]]
                name = "myshard2"
                paths = ["secret"]
            "#,
                Error::PathInMultipleShards(HgPathBuf::from_bytes(b"secret")),
            ),
            (
                r#"
                version=0
                [[shards]]
                name = "myshard"
                # Needs two slashes because we allow one trailing slash that
                # is stripped internally for quality of life
                paths = ["badpath//"]
            "#,
                Error::InvalidPath(
                    HgPathErrorKind::EndsWithSlash(HgPathBuf::from_bytes(
                        b"badpath/",
                    ))
                    .into(),
                ),
            ),
            (
                r#"
                version=0
                [[shards]]
                name = "myshard"
                paths = ["badpath//bad"]
            "#,
                Error::InvalidPath(
                    HgPathErrorKind::ConsecutiveSlashes {
                        bytes: b"badpath//bad".to_vec(),
                        second_slash_index: 8,
                    }
                    .into(),
                ),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="recursive"
                requires=["recursive"]
            "#,
                Error::CycleInShards(vec![
                    ShardName::new("recursive".to_string()).unwrap(),
                    ShardName::new("recursive".to_string()).unwrap(),
                ]),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="cyclic1"
                requires=["cyclic2"]
                [[shards]]
                name="cyclic2"
                requires=["cyclic3"]
                [[shards]]
                name="cyclic3"
                requires=["cyclic4"]
                [[shards]]
                name="cyclic4"
                requires=["cyclic1"]
            "#,
                Error::CycleInShards(vec![
                    ShardName::new("cyclic1".to_string()).unwrap(),
                    ShardName::new("cyclic2".to_string()).unwrap(),
                    ShardName::new("cyclic3".to_string()).unwrap(),
                    ShardName::new("cyclic4".to_string()).unwrap(),
                    ShardName::new("cyclic1".to_string()).unwrap(),
                ]),
            ),
        ];

        for (config, expected_error) in pairs {
            let config = toml::from_str::<ShapesConfig>(config)
                .expect("should be syntactically valid");
            let actual_error = StoreShards::from_config(config)
                .expect_err("should be an error at this stage");
            assert_eq!(expected_error, &actual_error);
        }
    }
}
