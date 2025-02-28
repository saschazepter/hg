use std::borrow::Cow;

use crate::{
    bdiff::{self, Lines},
    errors::HgError,
    repo::Repo,
    revlog::{
        changelog::Changelog,
        filelog::{Filelog, FilelogRevisionData},
        manifest::Manifestlog,
    },
    utils::{
        self,
        hg_path::{HgPath, HgPathBuf},
        strings::{clean_whitespace, CleanWhitespace},
    },
    AncestorsIterator, FastHashMap, Graph, GraphError, Node, Revision,
    NULL_REVISION,
};
use itertools::Itertools as _;
use rayon::prelude::*;
use self_cell::self_cell;

/// Options for [`annotate`].
#[derive(Copy, Clone)]
pub struct AnnotateOptions {
    pub treat_binary_as_text: bool,
    pub follow_copies: bool,
    pub whitespace: CleanWhitespace,
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
    pub revision: Revision,
    /// The one-based line number in the original file.
    pub line_number: u32,
}

self_cell!(
    /// A wrapper around [`Lines`] that owns the buffer the lines point into.
    /// The buffer contains the file text processed by [`clean_whitespace`].
    struct OwnedLines {
        owner: Vec<u8>,
        #[covariant]
        dependent: Lines,
    }
);

impl OwnedLines {
    /// Cleans `data` based on `whitespace` and then splits into lines.
    fn split(
        data: Vec<u8>,
        whitespace: CleanWhitespace,
    ) -> Result<Self, HgError> {
        let data = match clean_whitespace(&data, whitespace) {
            Cow::Borrowed(_) => data,
            Cow::Owned(data) => data,
        };
        Self::try_new(data, |data| bdiff::split_lines(data))
    }

    fn get(&self) -> &Lines {
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

/// Helper for keeping track of multiple filelogs.
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
struct FileId {
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

    /// Opens a new filelog by path and returns the id for the given file node.
    fn open_at_node(
        &mut self,
        repo: &Repo,
        path: &HgPath,
        node: Node,
    ) -> Result<FileId, HgError> {
        let index = self.open(repo, path)?;
        let revision =
            self.get(index).filelog.revlog.rev_from_node(node.into())?;
        Ok(FileId { index, revision })
    }

    /// Reads the contents of a file by id.
    fn read(&self, id: FileId) -> Result<FilelogRevisionData, HgError> {
        self.get(id.index).filelog.entry(id.revision)?.data()
    }

    /// Returns the parents of a file. If `follow_copies` is true, it treats
    /// the copy source as a parent. In that case, also returns the file data
    /// (since it has to read the file to extract the copy metadata).
    fn parents(
        &mut self,
        repo: &Repo,
        id: FileId,
        follow_copies: bool,
    ) -> Result<(Vec<FileId>, Option<Vec<u8>>), HgError> {
        let filelog = &self.get(id.index).filelog;
        let revisions =
            filelog.parents(id.revision).map_err(from_graph_error)?;
        let mut parents = Vec::with_capacity(2);
        let mut file_data = None;
        if revisions[0] != NULL_REVISION {
            parents.push(FileId {
                index: id.index,
                revision: revisions[0],
            });
        } else if follow_copies {
            // A null p1 indicates there might be copy metadata.
            // Check for it, and if present use it as the parent.
            let data = filelog.entry(id.revision)?.data()?;
            let meta = data.metadata()?.parse()?;
            // If copy or copyrev occurs without the other, ignore it.
            // This matches filerevisioncopied in storageutil.py.
            if let (Some(copy), Some(copyrev)) = (meta.copy, meta.copyrev) {
                parents.push(self.open_at_node(repo, copy, copyrev)?);
            }
            file_data = Some(data.into_file_data()?);
        }
        if revisions[1] != NULL_REVISION {
            parents.push(FileId {
                index: id.index,
                revision: revisions[1],
            });
        }
        Ok((parents, file_data))
    }
}

/// Per [`FileId`] information used in the [`annotate`] algorithm.
#[derive(Default)]
struct FileInfo {
    /// Parents of this revision (via p1 and p2 or copy metadata).
    parents: Option<Vec<FileId>>,
    /// Current state for annotating the file.
    file: AnnotatedFileState,
    /// Remaining number of times `file` is needed before we can drop it.
    needed: usize,
    /// Current state for converting to a changelog revision.
    revision: ChangelogRevisionState,
    /// The value of `revision` from a descendant. If the linkrev needs
    /// adjustment, we can start iterating the changelog here.
    descendant: Option<Revision>,
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
    Done(Revision),
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
    changelog_revision: Revision,
    options: AnnotateOptions,
) -> Result<AnnotateOutput, HgError> {
    // Step 1: Load the base file and check if it's binary.
    let changelog = repo.changelog()?;
    let manifestlog = repo.manifestlog()?;
    let mut fls = FilelogSet::default();
    let base_id = {
        let changelog_data = changelog.entry(changelog_revision)?.data()?;
        let manifest = manifestlog
            .data_for_node(changelog_data.manifest_node()?.into())?;
        let Some(entry) = manifest.find_by_path(path)? else {
            return Ok(AnnotateOutput::NotFound);
        };
        fls.open_at_node(repo, path, entry.node_id()?)?
    };
    let base_file_data = fls.read(base_id)?.into_file_data()?;
    if !options.treat_binary_as_text
        && utils::files::is_binary(&base_file_data)
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
            fls.parents(repo, id, options.follow_copies)?;
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
        CleanWhitespace::None => None,
        _ => Some(OwnedLines::split(
            base_file_data.clone(),
            CleanWhitespace::None,
        )?),
    };
    graph[base_id].file = AnnotatedFileState::Read(OwnedLines::split(
        base_file_data,
        options.whitespace,
    )?);
    graph.0.par_iter_mut().try_for_each(
        |(&id, info)| -> Result<(), HgError> {
            if let AnnotatedFileState::None = info.file {
                info.file = AnnotatedFileState::Read(OwnedLines::split(
                    fls.read(id)?.into_file_data()?,
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
    // Only convert revisions that actually appear in the final output.
    for &Annotation { id, .. } in &annotations {
        graph[id].revision = ChangelogRevisionState::Needed;
    }
    // Use the same object for all ancestor checks, since it internally
    // builds a hash set of seen revisions.
    let mut ancestors = ancestor_iter(&changelog, changelog_revision, None);
    // Iterate in reverse topological order so that we visits nodes after their
    // children, that way we can propagate `descendant` correctly.
    for &id in topological_order.iter().rev() {
        let info = &mut graph[id];
        let descendant =
            info.descendant.expect("descendant set by prior iteration");
        let propagate = match info.revision {
            ChangelogRevisionState::NotNeeded => descendant,
            ChangelogRevisionState::Needed => {
                let revision = adjust_link_revision(
                    &changelog,
                    &manifestlog,
                    &fls,
                    &mut ancestors,
                    descendant,
                    id,
                )?;
                info.revision = ChangelogRevisionState::Done(revision);
                revision
            }
            ChangelogRevisionState::Done(_) => unreachable!(),
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
            path: fls.get(id.index).path.clone(),
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
fn ancestor_iter(
    changelog: &Changelog,
    base_revision: Revision,
    stop_revision: Option<Revision>,
) -> AncestorsIterator<&Changelog> {
    AncestorsIterator::new(
        changelog,
        [base_revision],
        stop_revision.unwrap_or(NULL_REVISION),
        true,
    )
    .expect("base_revision should not be null")
}

/// If the linkrev of `id` is in `ancestors`, returns it. Otherwise, finds and
/// returns the first ancestor of `descendant` that introduced `id`.
fn adjust_link_revision(
    changelog: &Changelog,
    manifestlog: &Manifestlog,
    fls: &FilelogSet,
    ancestors: &mut AncestorsIterator<&Changelog>,
    descendant: Revision,
    id: FileId,
) -> Result<Revision, HgError> {
    let FilelogSetItem { filelog, path } = fls.get(id.index);
    let linkrev = filelog
        .revlog
        .link_revision(id.revision, &changelog.revlog)?;
    if ancestors.contains(linkrev).map_err(from_graph_error)? {
        return Ok(linkrev);
    }
    let file_node = *filelog.revlog.node_from_rev(id.revision);
    for ancestor in ancestor_iter(changelog, descendant, Some(linkrev)) {
        let ancestor = ancestor.map_err(from_graph_error)?;
        let data = changelog.entry(ancestor)?.data()?;
        if data.files().contains(&path.as_ref()) {
            let manifest_rev = manifestlog
                .revlog
                .rev_from_node(data.manifest_node()?.into())?;
            if let Some(entry) = manifestlog
                .inexact_data_delta_parents(manifest_rev)?
                .find_by_path(path)?
            {
                if entry.node_id()? == file_node {
                    return Ok(ancestor);
                }
            }
        }
    }
    // In theory this should be unreachable. But in case it happens, return the
    // linkrev. This matches _adjustlinkrev in context.py.
    Ok(linkrev)
}

/// Converts a [`GraphError`] to an [`HgError`].
fn from_graph_error(err: GraphError) -> HgError {
    HgError::corrupted(err.to_string())
}
