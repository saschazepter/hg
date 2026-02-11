use std::cell::Ref;

use itertools::Itertools as _;
use rayon::prelude::*;
use self_cell::self_cell;

use crate::AncestorsIterator;
use crate::FastHashMap;
use crate::Graph;
use crate::GraphError;
use crate::NULL_REVISION;
use crate::Node;
use crate::Revision;
use crate::bdiff::Lines;
use crate::bdiff::{self};
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
use crate::utils::strings::CleanWhitespace;
use crate::utils::strings::clean_whitespace;
use crate::utils::{self};

/// Options for [`annotate`].
#[derive(Copy, Clone)]
pub struct AnnotateOptions {
    pub treat_binary_as_text: bool,
    pub follow_copies: bool,
    pub whitespace: Option<CleanWhitespace>,
}

/// The final result of annotating a file.
pub enum AnnotateOutput {
    /// An annotated text file.
    Text(ChangesetAnnotatedFile),
    /// The file cannot be annotated because it is binary.
    Binary,
    /// The file was not found in the repository.
    NotFound,
}

/// A file with user-facing changeset annotations for each line.
pub struct ChangesetAnnotatedFile {
    // The lines of the file, including original line endings.
    pub lines: Vec<Vec<u8>>,
    // List of annotations corresponding to `lines`.
    pub annotations: Vec<ChangesetAnnotation>,
}

/// A user-facing changeset annotation for one line.
pub struct ChangesetAnnotation {
    /// The file path as it was at `revision`. This can be different from the
    /// file's current path if it was copied or renamed in the past.
    pub path: HgPathBuf,
    /// The changelog revision that introduced the line.
    pub revision: RevisionOrWdir,
    /// The one-based line number in the original file.
    pub line_number: u32,
}

self_cell!(
    /// A wrapper around [`Lines`] that owns the buffer the lines point into.
    /// The buffer contains the file text processed by [`clean_whitespace`].
    struct OwnedLines {
        owner: RawData,
        #[covariant]
        dependent: Lines,
    }
);

impl OwnedLines {
    /// Cleans `data` based on `whitespace` and then splits into lines.
    fn split(
        data: RawData,
        whitespace: Option<CleanWhitespace>,
    ) -> Result<Self, HgError> {
        if let Some(ws) = whitespace {
            let mut clean = data.into();
            clean_whitespace(&mut clean, ws);
            Self::try_new(RawData::from(clean), |data| bdiff::split_lines(data))
        } else {
            Self::try_new(data, |data| bdiff::split_lines(data))
        }
    }

    fn get(&self) -> &Lines<'_> {
        self.borrow_dependent()
    }
}

/// A file with filelog annotations for each line.
struct AnnotatedFile {
    lines: OwnedLines,
    annotations: Vec<Annotation>,
}

/// A filelog annotation for one line.
#[derive(Copy, Clone)]
struct Annotation {
    /// The file revision that introduced the line.
    id: FileId,
    /// The one-based line number in the original file.
    line_number: u32,
}

/// [`Repo`] and related objects that often need to be passed together.
struct RepoState<'a> {
    repo: &'a Repo,
    changelog: Ref<'a, Changelog>,
    manifestlog: Ref<'a, Manifestlog>,
    dirstate_parents: Option<[Revision; 2]>,
    dirstate_map: Option<Ref<'a, OwningDirstateMap>>,
}

impl<'a> RepoState<'a> {
    fn new(repo: &'a Repo, include_dirstate: bool) -> Result<Self, HgError> {
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

    fn dirstate_parents(&self) -> [Revision; 2] {
        self.dirstate_parents.expect("should be set for wdir")
    }

    fn dirstate_map(&'a self) -> &'a OwningDirstateMap {
        self.dirstate_map.as_ref().expect("should be set for wdir")
    }
}

/// Helper for keeping track of multiple filelogs.
/// Also abstracts over reading from filelogs and from the working directory.
#[derive(Default)]
struct FilelogSet {
    /// List of filelogs. The first one is for the root file being blamed.
    /// Others are added only when following copies/renames.
    items: Vec<FilelogSetItem>,
    /// Mapping of paths to indexes in `items`.
    path_to_index: FastHashMap<HgPathBuf, FilelogIndex>,
}

struct FilelogSetItem {
    path: HgPathBuf,
    filelog: Filelog,
}

/// Identifies a filelog in a FilelogSet.
type FilelogIndex = u32;

/// Identifies a file revision in a FilelogSet.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
enum FileId {
    /// The file in the working directory.
    Wdir,
    /// A revision of the file in a filelog.
    Rev(RevFileId),
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
struct RevFileId {
    index: FilelogIndex,
    revision: Revision,
}

impl FilelogSet {
    /// Returns filelog item at the given index.
    fn get(&self, index: FilelogIndex) -> &FilelogSetItem {
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
    fn open_at_changelog_rev(
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
    fn open_and_read(
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
    fn read(&self, id: RevFileId) -> Result<RawData, HgError> {
        let filelog = &self.get(id.index).filelog;
        filelog.entry(id.revision)?.data()?.into_file_data()
    }

    /// Returns the parents of a file. If `follow_copies` is true, it treats
    /// the copy source as a parent. In that case, also returns the file data
    /// (since it has to read the file to extract the copy metadata).
    fn parents(
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
        } else if follow_copies {
            // A null p1 indicates there might be copy metadata.
            // Check for it, and if present use it as the parent.
            let data = filelog.entry(id.revision)?.data()?;
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
        if revisions[1] != NULL_REVISION {
            parents.push(FileId::Rev(RevFileId {
                index: id.index,
                revision: revisions[1],
            }));
        }
        Ok((parents, file_data))
    }
}

/// Per [`FileId`] information used in the [`annotate`] algorithm.
#[derive(Default)]
struct FileInfo {
    /// Parents of this revision (via p1 and p2 or copy metadata).
    /// These are always `FileId::Rev`, not `FileId::Wdir`, but we store
    /// `FileId` because everything would have to convert to it anyways.
    parents: Option<Vec<FileId>>,
    /// Current state for annotating the file.
    file: AnnotatedFileState,
    /// Remaining number of times `file` is needed before we can drop it.
    needed: usize,
    /// Current state for converting to a changelog revision.
    revision: ChangelogRevisionState,
    /// The value of `revision` from a descendant. If the linkrev needs
    /// adjustment, we can start iterating the changelog here.
    descendant: Option<RevisionOrWdir>,
}

/// State enum for reading a file and annotating it.
#[derive(Default)]
enum AnnotatedFileState {
    #[default]
    None,
    Read(OwnedLines),
    Annotated(AnnotatedFile),
}

/// State enum for converting a filelog revision to a changelog revision, but
/// only if needed (because it will appear in the final output).
#[derive(Default)]
enum ChangelogRevisionState {
    #[default]
    NotNeeded,
    Needed,
    Done(RevisionOrWdir),
}

/// A collection of [`FileInfo`], forming a graph via [`FileInfo::parents`].
#[derive(Default)]
struct FileGraph(FastHashMap<FileId, FileInfo>);

impl FileGraph {
    fn get_or_insert_default(&mut self, id: FileId) -> &mut FileInfo {
        self.0.entry(id).or_default()
    }
}

impl std::ops::Index<FileId> for FileGraph {
    type Output = FileInfo;
    fn index(&self, id: FileId) -> &Self::Output {
        self.0.get(&id).expect("the graph should be populated")
    }
}

impl std::ops::IndexMut<FileId> for FileGraph {
    fn index_mut(&mut self, id: FileId) -> &mut Self::Output {
        self.0.get_mut(&id).expect("the graph should be populated")
    }
}

/// Annotates each line of a file with changeset information.
pub fn annotate(
    repo: &Repo,
    path: &HgPath,
    changelog_revision: RevisionOrWdir,
    options: AnnotateOptions,
) -> Result<AnnotateOutput, HgError> {
    // Step 1: Load the base file and check if it's binary.
    let state = RepoState::new(repo, changelog_revision.is_wdir())?;
    let mut fls = FilelogSet::default();
    let Some((base_id, base_file_data)) =
        fls.open_and_read(&state, path, changelog_revision)?
    else {
        return Ok(AnnotateOutput::NotFound);
    };
    if !options.treat_binary_as_text && utils::files::is_binary(&base_file_data)
    {
        return Ok(AnnotateOutput::Binary);
    }

    // Step 2: DFS to build the graph.
    let mut graph = FileGraph::default();
    let mut visit = vec![base_id];
    while let Some(id) = visit.pop() {
        let info = graph.get_or_insert_default(id);
        if info.parents.is_some() {
            continue;
        }
        let (parents, file_data) =
            fls.parents(&state, path, id, options.follow_copies)?;
        info.parents = Some(parents.clone());
        if let Some(data) = file_data {
            info.file = AnnotatedFileState::Read(OwnedLines::split(
                data,
                options.whitespace,
            )?);
        }
        for id in parents {
            let info = graph.get_or_insert_default(id);
            info.needed += 1;
            if info.parents.is_none() {
                visit.push(id);
            }
        }
    }

    // Step 3: Read files and split lines. Do the base file with and without
    // whitespace cleaning. Do the rest of the files in parallel with rayon.
    let base_file_original_lines = match options.whitespace {
        None => None,
        _ => Some(OwnedLines::split(base_file_data.clone(), None)?),
    };
    graph[base_id].file = AnnotatedFileState::Read(OwnedLines::split(
        base_file_data,
        options.whitespace,
    )?);
    graph.0.par_iter_mut().try_for_each(
        |(&id, info)| -> Result<(), HgError> {
            if let AnnotatedFileState::None = info.file {
                let id = match id {
                    FileId::Rev(id) => id,
                    FileId::Wdir => unreachable!("only base file can be wdir"),
                };
                info.file = AnnotatedFileState::Read(OwnedLines::split(
                    fls.read(id)?,
                    options.whitespace,
                )?);
            }
            Ok(())
        },
    )?;

    // Step 4: DFS to do the actual annotate algorithm.
    // While we're at it, save the topological order.
    let mut topological_order = vec![];
    visit.push(base_id);
    while let Some(&id) = visit.last() {
        let info = &mut graph[id];
        if let AnnotatedFileState::Annotated(_) = info.file {
            visit.pop();
            continue;
        }
        let visit_len = visit.len();
        let parents = info.parents.clone().expect("parents set in step 2");
        for &id in &parents {
            match graph[id].file {
                AnnotatedFileState::Annotated(_) => {}
                _ => visit.push(id),
            }
        }
        if visit.len() != visit_len {
            continue;
        }
        visit.pop();
        topological_order.push(id);
        let lines = match std::mem::take(&mut graph[id].file) {
            AnnotatedFileState::Read(lines) => lines,
            _ => unreachable!(),
        };
        let mut parent_files = Vec::with_capacity(2);
        for &id in &parents {
            match graph[id].file {
                AnnotatedFileState::Annotated(ref file) => {
                    parent_files.push(file)
                }
                _ => unreachable!(),
            }
        }
        graph[id].file = AnnotatedFileState::Annotated(annotate_pair(
            id,
            lines,
            parent_files,
        )?);
        for &id in &parents {
            let info = &mut graph[id];
            info.needed -= 1;
            if info.needed == 0 {
                info.file = AnnotatedFileState::None;
            }
        }
    }

    // Step 5: Map filelog revisions to changelog revisions.
    let base_info = &mut graph[base_id];
    base_info.descendant = Some(changelog_revision);
    let AnnotatedFileState::Annotated(AnnotatedFile { lines, annotations }) =
        std::mem::take(&mut base_info.file)
    else {
        panic!("the base file should have been annotated in step 4")
    };
    // Don't use the lines from the graph if they had whitespace cleaned.
    let lines = base_file_original_lines.unwrap_or(lines);
    // Record which revisions appear in the output, and so must be converted.
    for &Annotation { id, .. } in &annotations {
        graph[id].revision = ChangelogRevisionState::Needed;
    }
    // Use the same object for all ancestor checks, since it internally
    // builds a hash set of seen revisions.
    let mut ancestors = ancestor_iter(&state, changelog_revision, None);
    // Do ancestor checks on all linkrevs. This is worthwhile even if they're
    // `ChangelogRevisionState::NotNeeded`, because it will yield better
    // `descendant`s for adjusting others. We go in topological order (older to
    // newer) so that we populate the ancestor bitset in a tight loop early on.
    for &id in &topological_order {
        if let Some(revision) =
            check_link_revision(&state, &fls, id, &mut ancestors)?
        {
            graph[id].revision = ChangelogRevisionState::Done(revision);
        }
    }
    // Iterate in reverse topological order so that we visits nodes after their
    // children, that way we can propagate `descendant` correctly.
    for &id in topological_order.iter().rev() {
        let info = &mut graph[id];
        let descendant =
            info.descendant.expect("descendant set by prior iteration");
        let propagate = match info.revision {
            ChangelogRevisionState::NotNeeded => descendant,
            ChangelogRevisionState::Done(revision) => revision,
            ChangelogRevisionState::Needed => {
                let revision =
                    adjust_link_revision(&state, &fls, descendant, id)?;
                info.revision = ChangelogRevisionState::Done(revision);
                revision
            }
        };
        for id in info.parents.clone().expect("parents set in step 2") {
            let descendant = &mut graph[id].descendant;
            // If the parent had other descendants, choose the smallest one
            // because we want to skip over as much as possible.
            *descendant = Some(descendant.unwrap_or(propagate).min(propagate));
        }
    }

    // Step 6: Convert to `ChangesetAnnotatedFile`.
    let mut changeset_annotations = Vec::with_capacity(annotations.len());
    for Annotation { id, line_number } in annotations {
        changeset_annotations.push(ChangesetAnnotation {
            path: match id {
                FileId::Wdir => path.into(),
                FileId::Rev(id) => fls.get(id.index).path.clone(),
            },
            revision: match graph[id].revision {
                ChangelogRevisionState::Done(revision) => revision,
                _ => unreachable!(),
            },
            line_number,
        });
    }
    Ok(AnnotateOutput::Text(ChangesetAnnotatedFile {
        lines: lines.get().iter().map(ToOwned::to_owned).collect(),
        annotations: changeset_annotations,
    }))
}

/// Annotates a file by diffing against its parents, attributing changed lines
/// to `id`, and copying ids from the parent results for unchanged lines.
/// If there are two parents and a line is unchanged in both diffs, p2 wins.
fn annotate_pair(
    id: FileId,
    lines: OwnedLines,
    parents: Vec<&AnnotatedFile>,
) -> Result<AnnotatedFile, HgError> {
    let len = lines.get().len();
    let mut annotations = Vec::with_capacity(len);
    for line_number in 1..(len + 1) as u32 {
        annotations.push(Annotation { id, line_number });
    }
    for parent in parents {
        for bdiff::Hunk { a1, a2, b1, b2 } in
            bdiff::diff(parent.lines.get(), lines.get())?.iter()
        {
            for (a, b) in (a1..a2).zip(b1..b2) {
                annotations[b as usize] = parent.annotations[a as usize];
            }
        }
    }
    Ok(AnnotatedFile { lines, annotations })
}

/// Creates an iterator over the ancestors of `base_revision` (inclusive),
/// stopping at `stop_revision` if provided. Panics if `base_revision` is null.
fn ancestor_iter<'a>(
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
fn check_link_revision(
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
fn adjust_link_revision(
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
