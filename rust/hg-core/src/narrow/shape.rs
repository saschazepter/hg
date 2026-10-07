//! The core of the logic for narrow shapes, which enable a composable algebra
//! for slicing a repo's history along its files.

use std::hash::Hash;
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
use crate::FastHashSet;
use crate::errors::HgBacktrace;
use crate::errors::HgError;
use crate::file_patterns::FilePattern;
use crate::file_patterns::PatternError;
use crate::file_patterns::PatternSyntax;
use crate::matchers::ShapeMatcher;
use crate::repo::Repo;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::hg_path::HgPathError;
use crate::utils::hg_path::HgPathErrorKind;
use crate::utils::hg_path::ZeroPath;
use crate::utils::u32_u;

lazy_static! {
    /// Only lower case ASCII alpha num, `-` and `.`.
    /// Mirrored by `_validate_shape_name` in `mercurial/shape.py`.
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

/// Every kind of error when handling shapes
#[derive(Debug, PartialEq)]
pub enum ErrorKind {
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
    /// Deserialization of the shape failed
    Deserialization(DeserializationError),
    /// No shard of this name is marked as a shape
    UnknownShape(String),
    /// A shape was requested without any name
    NoShapeNames,
}

/// All error cases specific to shape deserialization
#[derive(Debug, PartialEq)]
pub enum DeserializationError {
    /// Length of the data does not match the header
    InvalidLength {
        /// Size in bytes, according to the header. This is a lower bound if
        /// the header itself is truncated.
        expected: usize,
        /// The actual size in bytes
        got: usize,
    },
    /// A path that cannot be a path in the repository
    InvalidPath {
        /// The raw path bytes
        path: Vec<u8>,
    },
}

impl From<DeserializationError> for Error {
    fn from(value: DeserializationError) -> Self {
        Self::from(ErrorKind::Deserialization(value))
    }
}

/// Error specific to handling shapes
#[derive(Debug, PartialEq)]
pub struct Error {
    /// Boxed to prevent the error from being too large
    pub kind: Box<ErrorKind>,
    pub backtrace: HgBacktrace,
}

impl From<ErrorKind> for Error {
    fn from(value: ErrorKind) -> Self {
        Self { kind: Box::new(value), backtrace: HgBacktrace::capture() }
    }
}

impl From<HgPathError> for Error {
    fn from(path_err: HgPathError) -> Self {
        Self {
            kind: Box::new(ErrorKind::InvalidPath(path_err.kind.into())),
            backtrace: path_err.backtrace,
        }
    }
}

const HG_FILES_SHARD: &str = ".hg-files";

/// Store file in which a repo declares its shards and shapes
pub const SHAPES_FILE: &str = "server-shapes";

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
            return Err(ErrorKind::EmptyShardName)?;
        }
        if name.as_bytes().iter().all(|b| *b == b'.' || *b == b'-') {
            return Err(ErrorKind::DotOrHyphenOnlyShardName(name))?;
        }
        if !SHARD_NAME_REGEX.is_match(&name) {
            return Err(ErrorKind::InvalidShardName(name))?;
        }
        Ok(Self(name))
    }

    pub fn as_bytes(&self) -> &[u8] {
        self.0.as_bytes()
    }

    /// Validate `names`, then return them sorted and without duplicates.
    ///
    /// The first invalid name is reported, see [`Self::new`].
    pub fn canonical_names(names: &[&str]) -> Result<Vec<Self>, Error> {
        let mut names = names
            .iter()
            .map(|name| Self::new(name.to_string()))
            .collect::<Result<Vec<_>, _>>()?;
        names.sort();
        names.dedup();
        Ok(names)
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

/// Represent the "anonymous" Shape made of a single Shard.
///
/// This is used to computed the "shard id" and the matcher for files that
/// belong that that Shard (dependencies excluded).
///
/// These informations are useful when building sharded bundles
#[derive(Debug)]
pub struct ShardShape {
    /// Internal synthetic [`Shape`] to re-use fingerprinting and matching code
    fake_shape: Shape,
    /// `true` if this shard should be bundled with top-level files
    /// (e.g the changelog, manifest, caches, etc.)
    pub top_level: bool,
}

impl ShardShape {
    /// Returns a standalone version of this shard
    ///
    /// Returns None if it is not a shard, i.e. it has no paths.
    pub fn new(store_shards: &StoreShards, shard: &Shard) -> Option<Self> {
        if shard.paths.is_empty() {
            return None;
        }

        let includes: FastHashSet<_> =
            shard.paths.iter().map(|path| path.as_bytes()).collect();

        let paths =
            store_shards.path_to_shard.keys().map(|path| path.as_bytes());
        let tree = ShardTreeNode::from_paths(paths, includes);
        let tree = tree.expect("shards should already have been be validated");

        Some(Self {
            fake_shape: Shape { names: vec![shard.name.to_owned()], tree },
            top_level: shard.name.0.as_str() == HG_FILES_SHARD,
        })
    }

    /// Returns a matcher for this shard only, without its dependencies
    pub fn matcher(&self) -> ShapeMatcher {
        ShapeMatcher::new(self.fake_shape.to_owned())
    }

    /// Returns a fingerprint for this shard only, without its dependencies
    pub fn fingerprint(&self) -> Fingerprint {
        self.fake_shape.store_fingerprint().as_shard()
    }
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
        match repo.store_vfs().try_read(SHAPES_FILE)? {
            Some(data) => Self::from_bytes(&data),
            None => Ok(Self::from_config(ShapesConfig::default())?),
        }
    }

    #[tracing::instrument(level = "debug", skip_all)]
    pub fn from_bytes(data: &[u8]) -> Result<Self, HgError> {
        let config = toml::from_slice(data).map_err(|e| -> Error {
            // We've failed to parse this to the expected structure,
            // it could be for many different reasons.
            // Give a better error message if it's only because it's a
            // different version that also turns out to be incompatible
            // with this deserialization.
            // It's a little fragile, but it's better than nothing.
            let re = regex::bytes::Regex::new(r"^version\s*=\s*(\d+)$")
                .expect("valid regex");
            if let Some(captures) = re.captures(data)
                && let Some(version) = captures.get(1)
            {
                let version = String::from_utf8_lossy(version.as_bytes())
                    .parse::<usize>()
                    .expect("parsing an integer from a regex");
                return ErrorKind::UnknownVersion(version).into();
            }
            ErrorKind::ParseError(e).into()
        })?;
        Ok(Self::from_config(config)?)
    }

    pub(crate) fn from_config(config: ShapesConfig) -> Result<Self, Error> {
        let ShapesConfig { version, mut shards } = config;
        if version != 0 {
            return Err(ErrorKind::UnknownVersion(version as usize))?;
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
            return Err(ErrorKind::ReservedName(name))?;
        }

        if paths.is_none() && requires.is_none() {
            return Err(ErrorKind::ShardMissingPathsAndRequires(name))?;
        }

        let mut hg_paths = vec![];
        if let Some(config_paths) = paths {
            for path in config_paths {
                let on_err =
                    |e: HgPathErrorKind| ErrorKind::InvalidPath(e.into());
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
                return Err(ErrorKind::PathInMultipleShards(path))?;
            }
        }

        if shards.insert(name.to_owned(), shard).is_some() {
            return Err(ErrorKind::DuplicateShard(name))?;
        }
        Ok(())
    }

    /// Return all user-facing [`Shard`] as [`Shape`]
    pub fn all_shapes(&self) -> Result<Vec<Shape>, Error> {
        let mut all: Vec<_> =
            self.shards.iter().filter(|(_, shard)| shard.shape).collect();
        all.sort();
        all.into_iter()
            .map(|(name, shard)| {
                Shape::new(vec![name.to_owned()], self, &[shard])
            })
            .collect()
    }

    /// Return the [`Shape`] combining these `names`: it covers every file that
    /// any of them covers.
    ///
    /// The order of `names` does not matter and duplicates are ignored, but
    /// names that do not exist or are a [`Shard`] result in an error
    pub fn shape(&self, names: &[&str]) -> Result<Shape, Error> {
        if names.is_empty() {
            return Err(ErrorKind::NoShapeNames)?;
        }
        let shard_names = ShardName::canonical_names(names)?;
        let mut shards = Vec::with_capacity(shard_names.len());
        for name in &shard_names {
            match self.shards.get(name) {
                Some(shard) if shard.shape => shards.push(shard),
                _ => return Err(ErrorKind::UnknownShape(name.to_string()))?,
            }
        }
        Shape::new(shard_names, self, &shards)
    }

    /// Return enough information about each shard in the store to generate
    /// sharded bundles. See the public methods on [`ShardShape`].
    pub fn sharded_bundle_info(&self) -> Vec<ShardShape> {
        let mut shards = self.shards.values().collect::<Vec<_>>();
        shards.sort_by(|a, b| a.name.cmp(&b.name));

        shards
            .into_iter()
            .filter_map(|shard| ShardShape::new(self, shard))
            .collect()
    }

    /// Return the fingerprint of every standalone shard in `shape` to match
    /// against sharded bundles.
    /// A client cloning a particular shape will need to know which shards make
    /// up that shape to select the right set of bundles (one per shard).
    pub fn shard_fingerprints_for_shape(
        &self,
        shape: &Shape,
    ) -> Result<Vec<FastHashSet<Fingerprint>>, Error> {
        let mut dependent_shards = FastHashMap::default();
        for name in shape.names() {
            let Some(shard) = self.shards.get(name) else {
                return Err(ErrorKind::UnknownShape(name.to_string()))?;
            };
            dependent_shards.extend(self.dependencies(shard)?);
            dependent_shards.insert(name, shard);
        }
        let fingerprints = dependent_shards
            .into_iter()
            .filter_map(|(_name, shard)| ShardShape::new(self, shard))
            .map(|standalone| standalone.fingerprint())
            .collect();
        // For now we only have a single set of fingerprints for a given shape
        // but we start keeping track of multiple states of a shape, and thus
        // could answer multiple sets of fingerprints.
        Ok(vec![fingerprints])
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
                return Err(ErrorKind::CycleInShards(cycle))?;
            }
            let sub_shard = &self.shards[name];
            acc.insert(name, sub_shard);
            let mut from = from.to_vec();
            from.push(name);
            self.dependencies_from(sub_shard, &from, acc)?;
        }

        Ok(())
    }

    /// The names of the shapes that were added, removed, or changed (according
    /// to their fingerprint) between `self` and `new`.
    pub fn changed_shapes(&self, new: &Self) -> Result<Vec<ShardName>, Error> {
        Ok(changed_names(
            &self.shape_fingerprints()?,
            &new.shape_fingerprints()?,
        ))
    }

    /// The names of the shapes whose fingerprint changed between `self` and
    /// `new`.
    pub fn redefined_shapes(
        &self,
        new: &Self,
    ) -> Result<Vec<ShardName>, Error> {
        let old = self.shape_fingerprints()?;
        let new = new.shape_fingerprints()?;
        Ok(changed_names(&old, &new)
            .into_iter()
            .filter(|name| old.contains_key(name) && new.contains_key(name))
            .collect())
    }

    /// Returns map from shape name to its fingerprint.
    fn shape_fingerprints(
        &self,
    ) -> Result<FastHashMap<ShardName, Fingerprint>, Error> {
        Ok(self
            .all_shapes()?
            .into_iter()
            .flat_map(|shape| {
                let fingerprint = shape.store_fingerprint();
                shape
                    .names()
                    .iter()
                    .map(move |name| (name.to_owned(), fingerprint))
                    .collect::<Vec<_>>()
            })
            .collect())
    }

    /// The names of the shards that change (according to their fingerprint)
    /// between `self` and `new`.
    ///
    /// Pure renames do not show up in this list, since non-shape shard names do
    /// not need to be stable. We only care whether the overall set of shard
    /// fingerprints has changed, regardless of the shard names. However we
    /// still return them here for a better error message.
    pub fn changed_shards(&self, new: &Self) -> Vec<ShardName> {
        let old = self.shard_fingerprints();
        let new = new.shard_fingerprints();
        let removed = old.iter().filter(|&(id, _)| !new.contains_key(id));
        let added = new.iter().filter(|&(id, _)| !old.contains_key(id));
        removed
            .chain(added)
            .map(|(_, name)| name.to_owned())
            .sorted()
            .dedup()
            .collect()
    }

    /// Returns map from the fingerprint of the files a shard owns to its name.
    /// The fingerprint is what identifies a shard; the name is just for
    /// reporting to the user.
    ///
    /// This is not the same thing as the shard's `paths`; a shard nested inside
    /// another one carves its paths out of the outer shard, so adding or
    /// removing one shard changes the files owned by another.
    fn shard_fingerprints(&self) -> FastHashMap<Fingerprint, ShardName> {
        self.shards
            .iter()
            .filter_map(|(name, shard)| {
                let shard_shape = ShardShape::new(self, shard)?;
                Some((shard_shape.fingerprint(), name.to_owned()))
            })
            .collect()
    }
}

/// The names that differ between the two maps, whether because only one of them
/// has the name or because the values differ.
///
/// Note that this is sensitive to the names themselves, which is what we want
/// for shapes, since a client pins itself to the name it cloned as well as to
/// the fingerprint. Shards are compared differently, see [`changed_shards`].
///
/// [`changed_shards`]: StoreShards::changed_shards
fn changed_names<V: Hash + Eq>(
    old: &FastHashMap<ShardName, V>,
    new: &FastHashMap<ShardName, V>,
) -> Vec<ShardName> {
    let old: FastHashSet<(&ShardName, &V)> = old.iter().collect();
    let new: FastHashSet<(&ShardName, &V)> = new.iter().collect();
    old.symmetric_difference(&new)
        .map(|(name, _)| (*name).to_owned())
        .sorted()
        .dedup()
        .collect()
}

/// Represents a named narrow view into the repo's files (at the history level).
///
/// This is a user-facing concept.
#[derive(Debug, Clone)]
pub struct Shape {
    /// Several names if this is a composite shape
    names: Vec<ShardName>,
    pub(crate) tree: ShardTreeNode,
}

impl Shape {
    pub fn new(
        names: Vec<ShardName>,
        store_shards: &StoreShards,
        shards: &[&Shard],
    ) -> Result<Self, Error> {
        let mut expanded_shards = vec![];
        for shard in shards {
            expanded_shards.push(*shard);
            expanded_shards.extend(store_shards.dependencies(shard)?.values())
        }
        let tree = ShardTreeNode::from_shards(store_shards, &expanded_shards)?;
        Ok(Self { names, tree })
    }

    /// Returns a [`Matcher`] that expresses the constraints of this shape
    pub fn matcher(&self) -> ShapeMatcher {
        ShapeMatcher::new(self.to_owned())
    }

    pub fn store_fingerprint(&self) -> Fingerprint {
        self.tree.fingerprint()
    }

    /// Serialize the patterns of this shape, see
    /// [`ShardTreeNode::serialize_patterns`]
    pub fn serialize_patterns(
        &self,
        buf: impl Write,
    ) -> Result<(), std::io::Error> {
        self.tree.serialize_patterns(buf)
    }

    pub fn patterns(&self) -> (Vec<HgPathBuf>, Vec<HgPathBuf>) {
        self.tree.flat()
    }

    /// The names of the shapes of this composite shape, or its own name
    pub fn names(&self) -> &[ShardName] {
        &self.names
    }

    pub fn from_patterns(
        includes: &[FilePattern],
        excludes: &[FilePattern],
    ) -> Result<Self, Error> {
        let tree = ShardTreeNode::from_patterns(includes, excludes)?;
        let name = ShardName::new("hg-internal".into()).expect("valid name");
        Ok(Self { names: vec![name], tree })
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

/// The version of the fingerprint computation that we currently produce
pub const FINGERPRINT_VERSION: u8 = 0;

/// What is identified by a given [`Fingerprint`]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FingerprintKind {
    /// A [`Shape`]
    Shape,
    /// A standalone [`Shard`], see [`ShardShape`]
    Shard,
}

impl FingerprintKind {
    /// The prefix of the text representation of fingerprints of this kind,
    /// e.g. `shape` in `shape00-<hex>`
    fn text_prefix(self) -> &'static str {
        match self {
            Self::Shape => "shape",
            Self::Shard => "shard",
        }
    }
}

/// Identifies a given set of files in the store. Two semantically equivalent
/// shapes (or shards) have the same fingerprint.
///
/// Fingerprinting can be evolved over time, so it is tagged with the version
/// of the computation that produced it.
///
/// There are two representations:
///   - The version alongside the digest (see [`Self::version`] and
///     [`Self::digest`]), used for storage, exchange and any internal
///     manipulation
///   - The text one (see [`Self::to_text_bytes`]), only used for user-facing
///     things
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Fingerprint {
    /// What this fingerprint identifies
    kind: FingerprintKind,
    /// The version of the computation that produced [`Self::digest`]
    version: u8,
    /// The hash of the normalized shape
    digest: [u8; Self::DIGEST_SIZE],
}

impl Fingerprint {
    /// Size in bytes of the digest
    pub const DIGEST_SIZE: usize = 32;

    /// What this fingerprint identifies
    pub fn kind(&self) -> FingerprintKind {
        self.kind
    }

    /// The version of the computation that produced this fingerprint
    pub fn version(&self) -> u8 {
        self.version
    }

    /// The hash of the normalized shape, computed according to
    /// [`Self::version`]
    pub fn digest(&self) -> &[u8; Self::DIGEST_SIZE] {
        &self.digest
    }

    /// The text representation, as bytes: `shapeXY-<hex>` for a shape and
    /// `shardXY-<hex>` for a shard, with `XY` the version as a decimal number
    /// padded to two digits and `<hex>` the hexadecimal digest.
    pub fn to_text_bytes(&self) -> Vec<u8> {
        self.to_string().into_bytes()
    }

    /// The same fingerprint, identifying a standalone shard.
    ///
    /// A standalone shard is fingerprinted as the shape made of its own paths
    /// (see [`ShardShape`]).
    pub(crate) fn as_shard(self) -> Self {
        Self { kind: FingerprintKind::Shard, ..self }
    }
}

impl std::fmt::Display for Fingerprint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}{:02}-", self.kind.text_prefix(), self.version)?;
        for byte in self.digest {
            write!(f, "{:02x}", byte)?;
        }
        Ok(())
    }
}

/// Flag set on the serialized size of a path if this path is included
const PATTERN_INCLUDED_FLAG: u16 = 1 << 15;

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
        let mut shard_paths = FastHashSet::default();
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
        Ok(Self::from_paths(
            store_shards.path_to_shard.keys().map(|path| path.as_bytes()),
            shard_paths,
        )?)
    }

    /// Create the tree expressed by old-style include and exclude patterns
    pub fn from_patterns<'a>(
        includes: &'a [FilePattern],
        excludes: &'a [FilePattern],
    ) -> Result<Self, Error> {
        let check_pattern = |pattern: &'a FilePattern| {
            if pattern.syntax != PatternSyntax::Path {
                Err(PatternError::UnsupportedSyntaxNarrow(
                    pattern.syntax.to_owned(),
                    HgBacktrace::capture(),
                ))
            } else {
                Ok(pattern.raw.as_slice())
            }
        };
        let mut include_paths = includes
            .iter()
            .map(check_pattern)
            .collect::<Result<FastHashSet<&[u8]>, _>>()
            .map_err(ErrorKind::PatternError)?; /*  */

        let exclude_paths = excludes
            .iter()
            .map(check_pattern)
            .collect::<Result<FastHashSet<&[u8]>, _>>()
            .map_err(ErrorKind::PatternError)?;

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

        Ok(Self::from_paths(
            root.into_iter().chain(include_paths.clone()).chain(exclude_paths),
            include_paths,
        )?)
    }

    /// `paths` is the iterator of all paths (included or not) and `includes`
    /// contains only the paths that are included.
    fn from_paths<Paths, Bytes>(
        paths: Paths,
        includes: FastHashSet<&[u8]>,
    ) -> Result<Self, HgPathError>
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
            .collect::<Result<Vec<_>, HgPathError>>()?;
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
    ///
    /// The digest of a version 0 fingerprint is the SHA-256 of the patterns
    /// block (see [`Self::serialize_patterns`]).
    pub fn fingerprint(&self) -> Fingerprint {
        let mut hasher = Sha256::new();
        self.serialize_patterns(&mut hasher)
            .expect("writing to a hasher never fails");
        Fingerprint {
            kind: FingerprintKind::Shape,
            version: FINGERPRINT_VERSION,
            digest: hasher.finalize().into(),
        }
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

    /// Return the paths of the node normalized as a flat sequence of
    /// `(path, included)`, in the canonical order (sorted by [`ZeroPath`], so
    /// we get the children next to their parents).
    fn flat_sorted(&self) -> Vec<(HgPathBuf, bool)> {
        let (includes, excludes) = self.flat();
        includes
            .into_iter()
            .map(|path| (path, true))
            .chain(excludes.into_iter().map(|path| (path, false)))
            .sorted_by_cached_key(|(path, _included)| {
                ZeroPath::try_from(path.as_ref())
                    .expect("paths of a node are valid")
            })
            .collect()
    }

    /// Serialize the includes and excludes of this node into a "patterns
    /// block".
    ///
    /// The binary format is the following (all integers are big-endian):
    ///
    /// `<COUNT>[<SIZE>...][<PATH>...]`
    ///
    /// With:
    ///   - `<COUNT>`, the number of paths as a 32 bits integer
    ///   - `[X...]` is syntax for "for each path, X"
    ///   - `<SIZE>`, the size in bytes of i-th path as a 16 bits integer. Its
    ///     highest bit is set if the path is included, and unset if it is
    ///     excluded (see [`PATTERN_INCLUDED_FLAG`])
    ///   - `<PATH>`, the raw bytes of the i-th path, rooted at the empty path
    ///
    /// Paths are sorted by [`ZeroPath`], so a directory is directly followed
    /// by its contents.
    pub fn serialize_patterns(
        &self,
        mut buf: impl Write,
    ) -> Result<(), std::io::Error> {
        let patterns = self.flat_sorted();

        let count: u32 = patterns.len().try_into().expect("too many paths");
        buf.write_all(&count.to_be_bytes())?;

        for (path, included) in patterns.iter() {
            let mut size: u16 = match path.len().try_into() {
                Ok(size) if size < PATTERN_INCLUDED_FLAG => size,
                _ => panic!("path is too long: {} bytes", path.len()),
            };
            if *included {
                size |= PATTERN_INCLUDED_FLAG;
            }
            buf.write_all(&size.to_be_bytes())?;
        }

        for (path, _included) in patterns.iter() {
            buf.write_all(path.as_bytes())?;
        }

        Ok(())
    }

    /// Returns the includes and exclude paths, by doing the reverse operation
    /// of [`Self::serialize_patterns`]
    pub fn deserialize_patterns(
        serialized: &[u8],
    ) -> Result<(Vec<HgPathBuf>, Vec<HgPathBuf>), Error> {
        const COUNT_SIZE: usize = size_of::<u32>();
        const LEN_SIZE: usize = size_of::<u16>();

        let invalid_length =
            |expected: usize| DeserializationError::InvalidLength {
                expected,
                got: serialized.len(),
            };

        // Validate everything we can from the fixed-size information first
        let Some((count, rest)) = serialized.split_first_chunk::<COUNT_SIZE>()
        else {
            return Err(invalid_length(COUNT_SIZE))?;
        };
        let count = u32_u(u32::from_be_bytes(*count));

        let sizes_len = count.saturating_mul(LEN_SIZE);
        let Some((sizes, paths)) = rest.split_at_checked(sizes_len) else {
            return Err(invalid_length(COUNT_SIZE + sizes_len))?;
        };
        let sizes: Vec<(usize, bool)> = sizes
            .as_chunks::<LEN_SIZE>()
            .0
            .iter()
            .map(|raw| {
                let raw = u16::from_be_bytes(*raw);
                let included = raw & PATTERN_INCLUDED_FLAG != 0;
                (usize::from(raw & !PATTERN_INCLUDED_FLAG), included)
            })
            .collect();

        let paths_len: usize = sizes.iter().map(|(size, _)| size).sum();
        if paths.len() != paths_len {
            return Err(invalid_length(COUNT_SIZE + sizes_len + paths_len))?;
        }

        let mut includes = vec![];
        let mut excludes = vec![];
        let mut rest = paths;
        for (size, included) in sizes {
            let (path, new_rest) = rest.split_at(size);
            rest = new_rest;
            let hg_path = HgPathBuf::from_bytes(path);
            // `check_state` accepts a trailing slash, a pattern cannot have one
            if hg_path.check_state().is_err() || path.ends_with(b"/") {
                return Err(DeserializationError::InvalidPath {
                    path: path.to_vec(),
                })?;
            }
            if included {
                includes.push(hg_path);
            } else {
                excludes.push(hg_path);
            }
        }

        Ok((includes, excludes))
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
    use std::path::Path;

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
                .map(|shape| shape.names().iter().join(","))
                .collect::<Vec<_>>(),
        );
        (store_shards, all_shape_names)
    }

    #[test]
    fn test_serialization() {
        let (store_shards, _) = valid_store_shards();
        for (name, shard) in store_shards.shards.iter() {
            let mut serialized = vec![];
            let internal_shape =
                Shape::new(vec![name.to_owned()], &store_shards, &[shard])
                    .unwrap();
            let patterns = internal_shape.patterns();
            internal_shape.tree.serialize_patterns(&mut serialized).unwrap();
            let patterns_from_serialized =
                ShardTreeNode::deserialize_patterns(&serialized).unwrap();
            assert_eq!(patterns, patterns_from_serialized);
        }
    }

    fn path_pattern(path: &str) -> FilePattern {
        FilePattern::new(PatternSyntax::Path, path.as_bytes(), Path::new(""))
    }

    #[test]
    fn test_patterns_block() {
        // `foo-x` is before `foo/bar` in bytes order, but not in the
        // canonical one.
        let includes = [path_pattern("foo"), path_pattern("foo-x")];
        let excludes = [path_pattern("foo/bar")];
        let tree = ShardTreeNode::from_patterns(&includes, &excludes).unwrap();

        let mut block = vec![];
        tree.serialize_patterns(&mut block).unwrap();
        assert_eq!(
            block,
            b"\x00\x00\x00\x04\x00\x00\x80\x03\x00\x07\x80\x05foofoo/barfoo-x"
        );

        let (includes, excludes) =
            ShardTreeNode::deserialize_patterns(&block).unwrap();
        let paths = |paths: &[&str]| -> Vec<HgPathBuf> {
            paths.iter().map(|p| HgPathBuf::from_bytes(p.as_bytes())).collect()
        };
        assert_eq!(includes, paths(&["foo", "foo-x"]));
        assert_eq!(excludes, paths(&["", "foo/bar"]));

        // The fingerprint is the hash of the block
        assert_eq!(
            tree.fingerprint().to_string(),
            concat!(
                "shape00-",
                "c1e75c57728686409c683838de48531c7705eeca5e8bb8d14fe8f9f7cbd0888b"
            )
        );

        // No paths at all is valid
        let empty = ShardTreeNode::deserialize_patterns(b"\x00\x00\x00\x00");
        assert_eq!(empty.unwrap(), (vec![], vec![]));
    }

    #[test]
    fn test_patterns_block_errors() {
        let assert_invalid_length = |data: &[u8], expected: usize| {
            let err = ShardTreeNode::deserialize_patterns(data).unwrap_err();
            assert_eq!(
                *err.kind,
                ErrorKind::Deserialization(
                    DeserializationError::InvalidLength {
                        expected,
                        got: data.len()
                    }
                )
            );
        };
        let assert_invalid_path = |data: &[u8], path: &[u8]| {
            let err = ShardTreeNode::deserialize_patterns(data).unwrap_err();
            assert_eq!(
                *err.kind,
                ErrorKind::Deserialization(DeserializationError::InvalidPath {
                    path: path.to_vec()
                })
            );
        };
        // Truncated count
        assert_invalid_length(b"", 4);
        assert_invalid_length(b"\x00\x00\x01", 4);
        // Truncated sizes
        assert_invalid_length(b"\x00\x00\x00\x02\x80\x03", 8);
        // Truncated paths
        assert_invalid_length(b"\x00\x00\x00\x01\x80\x03fo", 9);
        // Trailing data
        assert_invalid_length(b"\x00\x00\x00\x00f", 4);
        assert_invalid_length(b"\x00\x00\x00\x01\x80\x03fooo", 9);

        // Invalid paths
        assert_invalid_path(b"\x00\x00\x00\x01\x00\x02/f", b"/f");
        assert_invalid_path(b"\x00\x00\x00\x01\x00\x02f/", b"f/");
        assert_invalid_path(b"\x00\x00\x00\x01\x00\x04a//b", b"a//b");
        assert_invalid_path(b"\x00\x00\x00\x01\x00\x03a\x00b", b"a\x00b");
    }

    #[test]
    fn test_canonical_names() {
        let name = |name: &str| ShardName::new(name.to_string()).unwrap();

        // Sorted, without duplicates
        let names =
            ShardName::canonical_names(&["celeste", "babar", "celeste"]);
        assert_eq!(names.unwrap(), vec![name("babar"), name("celeste")]);
        assert_eq!(ShardName::canonical_names(&[]).unwrap(), vec![]);

        // The first invalid name is reported
        let err = ShardName::canonical_names(&["babar", "Zephir", ""]);
        assert_eq!(
            *err.unwrap_err().kind,
            ErrorKind::InvalidShardName("Zephir".to_string())
        );
        let err = ShardName::canonical_names(&["babar", "", "Zephir"]);
        assert_eq!(*err.unwrap_err().kind, ErrorKind::EmptyShardName);
    }

    #[test]
    fn test_unknown_shape() {
        let (store_shards, _) = valid_store_shards();
        // Unknown names and non-shapes (shards) are reported
        let err = store_shards.shape(&["zz"]).unwrap_err();
        assert_eq!(*err.kind, ErrorKind::UnknownShape("zz".to_string()));
        let err = store_shards.shape(&["baz"]).unwrap_err();
        assert_eq!(*err.kind, ErrorKind::UnknownShape("baz".to_string()));
    }

    #[test]
    fn test_shape_from_names() {
        let (store_shards, _) = valid_store_shards();
        let both = store_shards.shape(&["mummy", "bar"]).unwrap();
        let bar = store_shards.shape(&["bar"]).unwrap();
        let mummy = store_shards.shape(&["mummy"]).unwrap();

        // Names are sorted, duplicates and order do not matter
        let same = store_shards.shape(&["bar", "mummy", "bar"]).unwrap();
        assert_eq!(same.names(), both.names());
        assert_eq!(same.store_fingerprint(), both.store_fingerprint());

        // The combination covers what either shape covers, and nothing else
        let matcher = both.matcher();
        for file in ["bar/file", "stone/mummy/file"] {
            let file = HgPath::new(file.as_bytes());
            assert!(matcher.matches(file), "{file}");
            assert!(
                bar.matcher().matches(file) || mummy.matcher().matches(file),
                "{file}"
            );
        }
        // `bar/baz` is its own shard, which neither shape requires
        for file in ["foo/file", "bar/baz/file", "stone/mummy/chamber/file"] {
            let file = HgPath::new(file.as_bytes());
            assert!(!matcher.matches(file), "{file}");
        }

        // It is a shape of its own
        assert_ne!(both.store_fingerprint(), bar.store_fingerprint());
        assert_ne!(both.store_fingerprint(), mummy.store_fingerprint());

        // Unknown names and non-shapes (shards) are reported
        let err = store_shards.shape(&["bar", "zz"]).unwrap_err();
        assert_eq!(*err.kind, ErrorKind::UnknownShape("zz".to_string()));
        let err = store_shards.shape(&["bar", "baz"]).unwrap_err();
        assert_eq!(*err.kind, ErrorKind::UnknownShape("baz".to_string()));
        let err = store_shards.shape(&[]).unwrap_err();
        assert_eq!(*err.kind, ErrorKind::NoShapeNames);
    }

    #[test]
    fn test_shard_fingerprints_for_shapes() {
        let (store_shards, _) = valid_store_shards();
        let sets = |names: &[&str]| {
            let shape = store_shards.shape(names).unwrap();
            store_shards.shard_fingerprints_for_shape(&shape).unwrap()
        };
        // Several names give the union of their shards
        let baron = sets(&["baron"]);
        let mummy = sets(&["mummy"]);
        let both = sets(&["baron", "mummy"]);
        assert_eq!(both.len(), 1);
        let expected: FastHashSet<_> =
            baron[0].union(&mummy[0]).cloned().collect();
        assert_eq!(both[0], expected);
        assert!(both[0].len() > baron[0].len());
        // A shape that is not from the store is reported
        let outsider = Shape::from_patterns(&[], &[]).unwrap();
        let err =
            store_shards.shard_fingerprints_for_shape(&outsider).unwrap_err();
        let expected = ErrorKind::UnknownShape("hg-internal".to_string());
        assert_eq!(*err.kind, expected);
    }

    #[test]
    fn test_fingerprint_representations() {
        const DIGEST_HEX: &str =
            "ab00000000000000000000000000000000000000000000000000000000000001";
        let text_v00 = format!("shape00-{DIGEST_HEX}");
        let text_v12 = format!("shape12-{DIGEST_HEX}");
        let shard_text_v00 = format!("shard00-{DIGEST_HEX}");

        let mut digest = [0; Fingerprint::DIGEST_SIZE];
        digest[0] = 0xab;
        digest[31] = 0x01;
        let fingerprint =
            Fingerprint { kind: FingerprintKind::Shape, version: 0, digest };
        assert_eq!(fingerprint.kind(), FingerprintKind::Shape);
        assert_eq!(fingerprint.version(), 0);
        assert_eq!(fingerprint.digest(), &digest);
        assert_eq!(fingerprint.to_string(), text_v00);
        assert_eq!(fingerprint.to_text_bytes(), text_v00.as_bytes());

        // Same digest, different kind: not the same fingerprint
        let shard_fingerprint = fingerprint.as_shard();
        assert_eq!(shard_fingerprint.kind(), FingerprintKind::Shard);
        assert_eq!(shard_fingerprint.version(), 0);
        assert_eq!(shard_fingerprint.digest(), &digest);
        assert_eq!(shard_fingerprint.to_string(), shard_text_v00);
        assert_ne!(shard_fingerprint, fingerprint);

        // Same digest, different version: not the same fingerprint either
        let fingerprint_v12 = Fingerprint { version: 12, ..fingerprint };
        assert_eq!(fingerprint_v12.version(), 12);
        assert_eq!(fingerprint_v12.digest(), &digest);
        assert_eq!(fingerprint_v12.to_string(), text_v12);
        assert_ne!(fingerprint_v12, fingerprint);

        let tree = ShardTreeNode::from_patterns(&[], &[]).unwrap();
        assert_eq!(tree.fingerprint().kind(), FingerprintKind::Shape);
        assert_eq!(tree.fingerprint().version(), FINGERPRINT_VERSION);
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
            let shape = store_shards.shape(&[shard_name]).unwrap();
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
                let shape = store_shards.shape(&[name]).unwrap();
                let matcher = shape.matcher();
                (shape.names().iter().join(","), matcher)
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
        let shape = store_shards.shape(&["full"]).unwrap();
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
        let shape = store_shards.shape(&["bar"]).unwrap();
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
        let shape = store_shards.shape(&["baron"]).unwrap();
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

        let shape = store_shards.shape(&["stone"]).unwrap();
        dbg!(&shape.tree);
        let node = deepest_prefix_node(&shape.tree, HgPath::new(b"stone/liz"));
        assert_node(node, b"stone");
        assert_eq!(node.included, true);

        let shape = store_shards.shape(&["borden"]).unwrap();
        dbg!(&shape.tree);
        let node =
            deepest_prefix_node(&shape.tree, HgPath::new(b"stone/liz/zie/bor"));
        assert_node(node, b"stone/liz/zie");
        assert_eq!(node.included, false);

        let shape = store_shards.shape(&["mummy"]).unwrap();
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
        let shape = store_shards.shape(&["bar"]).unwrap();
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

        let shape = store_shards.shape(&["bazik"]).unwrap();
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
            VisitChildrenSet::Set(FastHashSet::from_iter([
                HgPathBuf::from_bytes(b"bar/baz/ik")
            ]))
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
                ErrorKind::ReservedName("full".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="base"
                paths=[""]
            "#,
                ErrorKind::ReservedName("base".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name=".hg-files"
                paths=[""]
            "#,
                ErrorKind::ReservedName(".hg-files".to_string()),
            ),
            (
                r#"
                version=999
                [[shards]]
                name="babar"
                paths=["babar"]
            "#,
                ErrorKind::UnknownVersion(999),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="Babar"
                paths=["babar"]
            "#,
                ErrorKind::InvalidShardName("Babar".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name=""
                paths=["babar"]
            "#,
                ErrorKind::EmptyShardName,
            ),
            (
                r#"
                version=0
                [[shards]]
                name="."
                paths=["babar"]
            "#,
                ErrorKind::DotOrHyphenOnlyShardName(".".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="-"
                paths=["babar"]
            "#,
                ErrorKind::DotOrHyphenOnlyShardName("-".to_string()),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="-.-"
                paths=["babar"]
            "#,
                ErrorKind::DotOrHyphenOnlyShardName("-.-".to_string()),
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
                ErrorKind::DuplicateShard(
                    ShardName::new("duplicate".to_string()).unwrap(),
                ),
            ),
            (
                r#"
                version=0
                [[shards]]
                name="too-little"
            "#,
                ErrorKind::ShardMissingPathsAndRequires(
                    "too-little".to_string(),
                ),
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
                ErrorKind::PathInMultipleShards(HgPathBuf::from_bytes(
                    b"secret",
                )),
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
                ErrorKind::InvalidPath(
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
                ErrorKind::InvalidPath(
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
                ErrorKind::CycleInShards(vec![
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
                ErrorKind::CycleInShards(vec![
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
            assert_eq!(*expected_error, *actual_error.kind);
        }
    }

    const SIMPLE_CONFIG: &str = r#"
        version = 0

        [[shards]]
        name = "foo"
        paths = ["foo"]

        [[shards]]
        name = "default"
        requires = ["base"]
        shape = true
    "#;

    fn changed(
        f: impl Fn(&StoreShards, &StoreShards) -> Vec<ShardName>,
        old: &str,
        new: &str,
    ) -> Vec<String> {
        let old = StoreShards::from_bytes(old.as_bytes()).unwrap();
        let new = StoreShards::from_bytes(new.as_bytes()).unwrap();
        let forwards = f(&old, &new);
        let backwards = f(&new, &old);
        assert_eq!(forwards, backwards);
        forwards.iter().map(ShardName::to_string).collect()
    }

    fn changed_shapes(old: &str, new: &str) -> Vec<String> {
        changed(|old, new| old.changed_shapes(new).unwrap(), old, new)
    }

    fn changed_shards(old: &str, new: &str) -> Vec<String> {
        changed(|old, new| old.changed_shards(new), old, new)
    }

    const NO_CHANGE: [&str; 0] = [];

    #[test]
    fn test_unchanged() {
        assert_eq!(changed_shapes(SIMPLE_CONFIG, SIMPLE_CONFIG), NO_CHANGE);
        assert_eq!(changed_shards(SIMPLE_CONFIG, SIMPLE_CONFIG), NO_CHANGE);

        // Comments, whitespace, and the order of shards are not meaningful
        // changes
        let reformatted = r#"
            version = 0
            # this is the default shape
            [[shards]]
            name = "default"
            shape = true
            requires = ["base"]
            [[shards]]
            name = "foo"
            paths = ["foo"]
        "#;
        assert_eq!(changed_shapes(SIMPLE_CONFIG, reformatted), NO_CHANGE);
        assert_eq!(changed_shards(SIMPLE_CONFIG, reformatted), NO_CHANGE);

        // Order of paths is not a meaningful change
        let old = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo", "bar"]
            shape = true
        "#;
        let new = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["bar", "foo"]
            shape = true
        "#;
        assert_eq!(changed_shapes(old, new), NO_CHANGE);
        assert_eq!(changed_shards(old, new), NO_CHANGE);
    }

    #[test]
    fn test_adding_shape() {
        let new = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]

            [[shards]]
            name = "default"
            requires = ["base"]
            shape = true

            [[shards]]
            name = "everything"
            requires = ["foo", "default"]
            shape = true
        "#;
        assert_eq!(changed_shapes(SIMPLE_CONFIG, new), vec!["everything"]);
        assert_eq!(changed_shards(SIMPLE_CONFIG, new), NO_CHANGE);
    }

    #[test]
    fn test_adding_shard() {
        // Simply adding a shard can affect shapes
        let new = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]

            [[shards]]
            name = "bar"
            paths = ["bar"]

            [[shards]]
            name = "default"
            requires = ["base"]
            shape = true
        "#;
        assert_eq!(changed_shapes(SIMPLE_CONFIG, new), vec!["default"]);
        // `base` owned the files under `bar` until now
        assert_eq!(changed_shards(SIMPLE_CONFIG, new), vec!["bar", "base"]);

        // If we adjust the shape as well, we can prevent it from changing
        let new = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]

            [[shards]]
            name = "bar"
            paths = ["bar"]

            [[shards]]
            name = "default"
            requires = ["base", "bar"]
            shape = true
        "#;
        assert_eq!(changed_shapes(SIMPLE_CONFIG, new), NO_CHANGE);
        assert_eq!(changed_shards(SIMPLE_CONFIG, new), vec!["bar", "base"]);
    }

    #[test]
    fn test_removing_shard() {
        // Removing a shard can also affect shapes
        let new = r#"
            version = 0

            [[shards]]
            name = "default"
            requires = ["base"]
            shape = true
        "#;
        assert_eq!(changed_shapes(SIMPLE_CONFIG, new), vec!["default"]);
        // `base` picks up the files that `foo` owned
        assert_eq!(changed_shards(SIMPLE_CONFIG, new), vec!["base", "foo"]);

        // We must first remove the shape, and only then can we remove the shard
        let remove_shape = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]
        "#;
        assert_eq!(
            changed_shapes(SIMPLE_CONFIG, remove_shape),
            vec!["default"]
        );
        assert_eq!(changed_shards(SIMPLE_CONFIG, remove_shape), NO_CHANGE);

        let remove_shard = r#"
            version = 0
            shards = []
        "#;
        assert_eq!(changed_shapes(remove_shape, remove_shard), NO_CHANGE);
        assert_eq!(
            changed_shards(remove_shape, remove_shard),
            vec!["base", "foo"]
        );
    }

    #[test]
    fn test_changing_existing_shard() {
        let old = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo", "bar"]

            [[shards]]
            name = "baz"
            paths = ["baz"]
        "#;
        let new = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]

            [[shards]]
            name = "baz"
            paths = ["baz"]
        "#;
        assert_eq!(changed_shards(old, new), vec!["base", "foo"]);
    }

    #[test]
    fn test_renaming_a_shard() {
        // The name of a (non-shape) shard is an internal detail. A pure rename
        // does not count as resharding.
        let old = r#"
            version = 0

            [[shards]]
            name = "foo"
            paths = ["foo"]
        "#;
        let new = r#"
            version = 0

            [[shards]]
            name = "renamed"
            paths = ["foo"]
        "#;
        assert_eq!(changed_shards(old, new), NO_CHANGE);
    }
}
