use itertools::Itertools as _;
use parking_lot::MappedRwLockReadGuard;

use crate::AncestorsIterator;
use crate::FastHashMap;
use crate::Graph;
use crate::GraphError;
use crate::NULL_REVISION;
use crate::Node;
use crate::Revision;
use crate::dirstate::owning::OwningDirstateMap;
use crate::errors::HgError;
use crate::repo::Repo;
use crate::revlog::RevisionOrWdir;
use crate::revlog::changelog::Changelog;
use crate::revlog::filelog::Filelog;
use crate::revlog::manifest::Manifestlog;
use crate::utils::RawData;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::{self};

/// [`Repo`] and related objects that often need to be passed together.
pub struct RepoState<'a> {
    repo: &'a Repo,
    pub changelog: MappedRwLockReadGuard<'a, Changelog>,
    pub manifestlog: MappedRwLockReadGuard<'a, Manifestlog>,
    dirstate_parents: Option<[Revision; 2]>,
    dirstate_map: Option<MappedRwLockReadGuard<'a, OwningDirstateMap>>,
}

impl<'a> RepoState<'a> {
    pub fn new(
        repo: &'a Repo,
        include_dirstate: bool,
    ) -> Result<Self, HgError> {
        let changelog = repo.changelog()?;
        let manifestlog = repo.manifestlog()?;
        let (dirstate_parents, dirstate_map) = if include_dirstate {
            let crate::DirstateParents { p1, p2 } = repo.dirstate_parents()?;
            let p1 = changelog.rev_from_node(p1.into())?;
            let p2 = changelog.rev_from_node(p2.into())?;
            let dirstate_map = repo.dirstate_map()?;
            (Some([p1, p2]), Some(dirstate_map))
        } else {
            (None, None)
        };
        Ok(Self {
            repo,
            changelog,
            manifestlog,
            dirstate_parents,
            dirstate_map,
        })
    }

    pub fn dirstate_parents(&self) -> [Revision; 2] {
        self.dirstate_parents.expect("should be set for wdir")
    }

    fn dirstate_map(&'a self) -> &'a OwningDirstateMap {
        self.dirstate_map.as_ref().expect("should be set for wdir")
    }
}

/// Helper for keeping track of multiple filelogs.
/// Also abstracts over reading from filelogs and from the working directory.
#[derive(Default)]
pub struct FilelogSet {
    /// List of filelogs. The first one is for the root file being blamed.
    /// Others are added only when following copies/renames.
    items: Vec<FilelogSetItem>,
    /// Mapping of paths to indexes in `items`.
    path_to_index: FastHashMap<HgPathBuf, FilelogIndex>,
}

pub struct FilelogSetItem {
    pub path: HgPathBuf,
    pub filelog: Filelog,
}

/// Identifies a filelog in a FilelogSet.
type FilelogIndex = u32;

impl FilelogSet {
    /// Returns filelog item at the given index.
    pub fn get(&self, index: FilelogIndex) -> &FilelogSetItem {
        &self.items[index as usize]
    }

    /// Opens a filelog by path and returns its index.
    fn open(
        &mut self,
        repo: &Repo,
        path: &HgPath,
    ) -> Result<FilelogIndex, HgError> {
        if let Some(&index) = self.path_to_index.get(path) {
            return Ok(index);
        }
        let index = self.items.len() as FilelogIndex;
        self.items.push(FilelogSetItem {
            filelog: repo.filelog(path)?,
            path: path.into(),
        });
        self.path_to_index.insert(path.into(), index);
        Ok(index)
    }

    /// Opens a filelog by path and returns the id for the given file node.
    fn open_at_node(
        &mut self,
        repo: &Repo,
        path: &HgPath,
        node: Node,
    ) -> Result<RevFileId, HgError> {
        let index = self.open(repo, path)?;
        let revision =
            self.get(index).filelog.revlog.rev_from_node(node.into())?;
        Ok(RevFileId { index, revision })
    }

    /// Opens a filelog by path and returns the id for the given changelog
    /// revision. Returns `None` if no filelog exists for that path.
    pub fn open_at_changelog_rev(
        &mut self,
        state: &RepoState,
        path: &HgPath,
        changelog_revision: Revision,
    ) -> Result<Option<RevFileId>, HgError> {
        let changelog_data =
            state.changelog.entry(changelog_revision)?.data()?;
        let manifest = state
            .manifestlog
            .data_for_node(changelog_data.manifest_node()?.into())?;
        let Some(entry) = manifest.find_by_path(path)? else {
            return Ok(None);
        };
        let node = entry.node_id()?;
        Ok(Some(self.open_at_node(state.repo, path, node)?))
    }

    /// Opens and reads a file by path at a changelog revision (or working
    /// directory), returning its id and contents. Returns `None` if not found.
    pub fn open_and_read(
        &mut self,
        state: &RepoState,
        path: &HgPath,
        revision: RevisionOrWdir,
    ) -> Result<Option<(FileId, RawData)>, HgError> {
        match revision.exclude_wdir() {
            Some(revision) => {
                match self.open_at_changelog_rev(state, path, revision)? {
                    None => Ok(None),
                    Some(id) => Ok(Some((FileId::Rev(id), self.read(id)?))),
                }
            }
            None => {
                let fs_path = utils::hg_path::hg_path_to_path_buf(path)?;
                let maybe_data =
                    state.repo.working_directory_vfs().try_read(fs_path)?;
                Ok(maybe_data.map(|data| (FileId::Wdir, RawData::from(data))))
            }
        }
    }

    /// Reads the contents of a file by id.
    pub fn read(&self, id: RevFileId) -> Result<RawData, HgError> {
        let filelog = &self.get(id.index).filelog;
        Ok(filelog.entry(id.revision)?.data()?.into_file_data()?)
    }

    /// Returns the parents of a file. If `follow_copies` is true, it treats
    /// the copy source as a parent. In that case, also returns the file data
    /// (since it has to read the file to extract the copy metadata).
    pub fn parents(
        &mut self,
        state: &RepoState,
        base_path: &HgPath,
        id: FileId,
        follow_copies: bool,
    ) -> Result<(Vec<FileId>, Option<RawData>), HgError> {
        let mut parents = Vec::<FileId>::with_capacity(2);
        let id = match id {
            FileId::Rev(id) => id,
            FileId::Wdir => {
                // If a file in the working directory is copied/renamed, its
                // parent is the copy source (just as it will be after
                // committing).
                let path = state
                    .dirstate_map()
                    .copy_map_get(base_path)?
                    .unwrap_or(base_path);
                for rev in state.dirstate_parents() {
                    if let Some(id) =
                        self.open_at_changelog_rev(state, path, rev)?
                    {
                        parents.push(FileId::Rev(id));
                    }
                }
                return Ok((parents, None));
            }
        };
        let filelog = &self.get(id.index).filelog;
        let revisions =
            filelog.parents(id.revision).map_err(from_graph_error)?;
        let mut file_data = None;
        if revisions[0] != NULL_REVISION {
            parents.push(FileId::Rev(RevFileId {
                index: id.index,
                revision: revisions[0],
            }));
        }
        if follow_copies {
            let filelog_entry = filelog.entry(id.revision)?;
            if filelog_entry.maybe_has_metadata() {
                // A null p1 indicates there might be copy metadata.
                // Check for it, and if present use it as the parent.
                let data = filelog_entry.data()?;
                let meta = data.metadata()?.parse()?;
                // If copy or copyrev occurs without the other, ignore it.
                // This matches filerevisioncopied in storageutil.py.
                if let (Some(copy), Some(copyrev)) = (meta.copy, meta.copyrev) {
                    parents.push(FileId::Rev(
                        self.open_at_node(state.repo, copy, copyrev)?,
                    ));
                }
                file_data = Some(data.into_file_data()?);
            }
        }
        if revisions[1] != NULL_REVISION {
            parents.push(FileId::Rev(RevFileId {
                index: id.index,
                revision: revisions[1],
            }));
        }
        Ok((parents, file_data))
    }
}

/// Identifies a file revision in a FilelogSet.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub enum FileId {
    /// The file in the working directory.
    Wdir,
    /// A revision of the file in a filelog.
    Rev(RevFileId),
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub struct RevFileId {
    pub index: FilelogIndex,
    pub revision: Revision,
}

/// Creates an iterator over the ancestors of `base_revision` (inclusive),
/// stopping at `stop_revision` if provided. Panics if `base_revision` is null.
pub fn ancestor_iter<'a>(
    state: &'a RepoState<'a>,
    base_revision: RevisionOrWdir,
    stop_revision: Option<Revision>,
) -> AncestorsIterator<&'a Changelog> {
    let base_revisions: &[Revision] = match base_revision.exclude_wdir() {
        Some(rev) => &[rev],
        None => &state.dirstate_parents(),
    };
    let stop_revision = stop_revision.unwrap_or(NULL_REVISION);
    AncestorsIterator::new(
        &*state.changelog,
        base_revisions.iter().copied(),
        stop_revision,
        true,
    )
    .expect("base_revision should not be null")
}

/// If the linkrev of `id` is in `ancestors`, returns it.
pub fn check_link_revision(
    state: &RepoState<'_>,
    fls: &FilelogSet,
    id: FileId,
    ancestors: &mut AncestorsIterator<&Changelog>,
) -> Result<Option<RevisionOrWdir>, HgError> {
    let id = match id {
        FileId::Rev(id) => id,
        FileId::Wdir => return Ok(Some(RevisionOrWdir::wdir())),
    };
    let FilelogSetItem { filelog, .. } = fls.get(id.index);
    let linkrev =
        filelog.revlog.link_revision(id.revision, &state.changelog.revlog)?;
    if ancestors.contains(linkrev).map_err(from_graph_error)? {
        return Ok(Some(linkrev.into()));
    }
    Ok(None)
}

/// Finds and returns the first ancestor of `descendant` that introduced `id`
/// by scanning the changelog.
pub fn adjust_link_revision(
    state: &RepoState<'_>,
    fls: &FilelogSet,
    descendant: RevisionOrWdir,
    id: FileId,
) -> Result<RevisionOrWdir, HgError> {
    let id = match id {
        FileId::Rev(id) => id,
        FileId::Wdir => return Ok(RevisionOrWdir::wdir()),
    };
    let FilelogSetItem { filelog, path } = fls.get(id.index);
    let linkrev =
        filelog.revlog.link_revision(id.revision, &state.changelog.revlog)?;
    let file_node = *filelog.revlog.node_from_rev(id.revision);
    for ancestor in ancestor_iter(state, descendant, Some(linkrev)) {
        let ancestor = ancestor.map_err(from_graph_error)?;
        let data = state.changelog.entry(ancestor)?.data()?;
        if data.files().contains(&path.as_ref()) {
            let manifest_rev = state
                .manifestlog
                .revlog
                .rev_from_node(data.manifest_node()?.into())?;
            if let Some(entry) = state
                .manifestlog
                .inexact_data_delta_parents(manifest_rev)?
                .find_by_path(path)?
                && entry.node_id()? == file_node
            {
                return Ok(ancestor.into());
            }
        }
    }
    // In theory this should be unreachable. But in case it happens, return the
    // linkrev. This matches _adjustlinkrev in context.py.
    Ok(linkrev.into())
}

/// Converts a [`GraphError`] to an [`HgError`].
fn from_graph_error(err: GraphError) -> HgError {
    HgError::corrupted(err.to_string())
}
