use rayon::prelude::*;
use self_cell::self_cell;

use crate::FastHashMap;
use crate::bdiff::Lines;
use crate::bdiff::{self};
use crate::errors::HgError;
use crate::linkrev::FileId;
use crate::linkrev::FilelogSet;
use crate::linkrev::RepoState;
use crate::linkrev::adjust_link_revision;
use crate::linkrev::ancestor_iter;
use crate::linkrev::check_link_revision;
use crate::repo::Repo;
use crate::revlog::RevisionOrWdir;
use crate::utils;
use crate::utils::RawData;
use crate::utils::hg_path::HgPath;
use crate::utils::hg_path::HgPathBuf;
use crate::utils::strings::CleanWhitespace;
use crate::utils::strings::clean_whitespace;

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
