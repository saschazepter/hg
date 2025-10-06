use std::cell::RefCell;
use std::collections::HashSet;
use std::io::Write;
use std::path::Path;
use std::rc::Rc;

use itertools::Itertools;
use sha2::Digest;
use sha2::Sha256;

use crate::filepatterns::IgnorePattern;
use crate::filepatterns::PatternError;
use crate::filepatterns::PatternSyntax;
use crate::matchers::AlwaysMatcher;
use crate::matchers::DifferenceMatcher;
use crate::matchers::Matcher;
use crate::matchers::NeverMatcher;
use crate::matchers::PatternMatcher;
use crate::matchers::UnionMatcher;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;

/// A node within a tree of narrow patterns.
///
/// It is used to create a normalized representation of potentially nested
/// include and exclude patterns to uniquely identify semantically equivalent
/// rules, as well as generating an associated file matcher.
#[derive(Debug, Clone, PartialEq)]
pub struct ShardTreeNode {
    /// The path (rooted by `b""`) that this node concerns
    path: ZeroPath,
    /// Whether this path is included or excluded
    included: bool,
    /// The set of child nodes (describing rules for sub-paths)
    children: Vec<Rc<RefCell<ShardTreeNode>>>,
}

impl ShardTreeNode {
    // XXX rename `ignorepattern` to something more general
    pub fn from_patterns(
        includes: &[IgnorePattern],
        excludes: &[IgnorePattern],
    ) -> Result<Self, PatternError> {
        let check_pattern = |pattern: &IgnorePattern| {
            if pattern.syntax != PatternSyntax::Path {
                let syntax = format!("{:?}", pattern.syntax);
                Err(PatternError::UnsupportedSyntax(syntax))
            } else {
                Ok(ZeroPath::new(&pattern.raw))
            }
        };
        let mut include_paths = includes
            .iter()
            .map(check_pattern)
            .collect::<Result<HashSet<_>, _>>()?;

        let exclude_paths = excludes
            .iter()
            .map(check_pattern)
            .collect::<Result<HashSet<_>, _>>()?;

        let empty_path = ZeroPath::new(b"");
        // `clone` passes `path:.` by default which is supposed to include
        // everything. This is the wrong API IMO and is a serialization detail
        // hitting internal logic (empty paths are annoying in text formats).
        let empty_path_alt = ZeroPath::new(b".");

        let root = if include_paths.contains(&empty_path)
            || include_paths.contains(&empty_path_alt)
            || include_paths.is_empty()
        {
            include_paths.remove(&empty_path_alt);
            // Need to include everything by default
            include_paths.insert(empty_path);
            vec![]
        } else {
            vec![&empty_path]
        };

        let nodes = root
            .into_iter()
            .chain(include_paths.iter().chain(exclude_paths.iter()))
            .map(|path| {
                Rc::new(RefCell::new(Self {
                    path: path.to_owned(),
                    included: include_paths.contains(path),
                    children: vec![],
                }))
            })
            .sorted_by(|a, b| a.borrow().path.cmp(&b.borrow().path));

        let mut stack: Vec<Rc<RefCell<ShardTreeNode>>> = vec![];
        for node in nodes {
            while !stack.is_empty()
                && !node
                    .borrow()
                    .sub_path_of(&stack.last().expect("not empty").borrow())
            {
                stack.pop();
            }
            if let Some(last) = stack.last_mut() {
                if last.borrow().included != node.borrow().included {
                    last.borrow_mut().children.push(node.clone());
                }
            }
            stack.push(node);
        }
        let root = stack.into_iter().next().expect("should have one element");
        let root = Rc::into_inner(root)
            .expect("should have only one ref")
            .into_inner();

        Ok(root)
    }

    pub fn matcher(&self, root_path: &Path) -> Box<dyn Matcher + Send> {
        let top_matcher = if self.path.is_empty() {
            // We're the root node
            if self.included {
                Box::new(AlwaysMatcher) as Box<dyn Matcher + Send>
            } else {
                Box::new(NeverMatcher) as Box<dyn Matcher + Send>
            }
        } else {
            Box::new(
                PatternMatcher::new(vec![IgnorePattern::new(
                    PatternSyntax::Path,
                    HgPathBuf::from(&self.path).as_bytes(),
                    root_path,
                )])
                .expect("patterns based on paths should always be valid"),
            ) as Box<dyn Matcher + Send>
        };
        if self.children.is_empty() {
            return top_matcher;
        }
        let sub_matcher = if self.children.len() == 1 {
            self.children[0].borrow().matcher(root_path)
        } else {
            let subs: Vec<_> = self
                .children
                .iter()
                .map(|child| child.borrow().matcher(root_path))
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
            let (sub_includes, sub_excludes) = child.borrow().flat();
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
