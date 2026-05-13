//! Implementation of a [`StoreBackend`] based off a local repository.

use std::convert::Infallible;

use dashmap::DashMap;
use hg::Node;
use hg::UncheckedRevision;
use hg::errors::HgError;
use hg::matchers::Matcher;
use hg::narrow;
use hg::operations::FilesForDirstateBorrowed;
use hg::repo::Repo;
use hg::revlog::manifest::Manifest;
use hg::sparse;
use hg::utils::RawData;
use hg::utils::hg_path::HgPath;
use hg::utils::u_u64;
use hg::warnings::HgWarningContext;
use rayon::iter::ParallelIterator;
use self_cell::self_cell;

use crate::server::Config;
use crate::server::store::ChangesetFiles;
use crate::server::store::Error;
use crate::server::store::ErrorKind;
use crate::server::store::FileInfo;
use crate::server::store::FileToken;
use crate::server::store::RevisionIdx;
use crate::server::store::StoreBackend;
use crate::server::store::StoreInfo;

/// A [`StoreBackend`] implementation that uses a normal, local repository.
pub struct LocalBackend {
    /// The backing repository
    repo: Repo,
    /// The configuration applicable to this backend
    server_config: Config,
    /// A cache of file nodeids to their size
    file_nodeid_to_size: DashMap<Node, u64>,
    /// The narrow matcher for this repository, computed at the start
    narrow_matcher: Box<dyn Matcher + Send + 'static>,
}

impl LocalBackend {
    pub fn new(repo: Repo, archive_view: bool) -> Result<Self, HgError> {
        let repo_config = repo.config();
        let server_config = Config {
            preload_structure: repo_config
                .get_bool(b"fuse", b"preload-working-copy-structure")?,
            archive_view,
        };
        let file_nodeid_to_size = DashMap::new();

        let warnings = HgWarningContext::new();
        let narrow_matcher = narrow::matcher(&repo, warnings.sender())?;
        let _ = warnings.finish(|warning| -> Result<(), Infallible> {
            // TODO better warnings
            tracing::warn!("narrow warning: {:?}", warning);
            Ok(())
        });

        Ok(Self { repo, server_config, file_nodeid_to_size, narrow_matcher })
    }

    /// Returns an iterator over this manifest given this sparse matcher
    fn changeset_files_iterator<'manifest>(
        &self,
        manifest: &'manifest Manifest,
        sparse_matcher: &impl Matcher,
    ) -> Result<ChangesetFilesIterator<'manifest>, HgError> {
        let files_for_rev = FilesForDirstateBorrowed::new(
            manifest,
            &self.narrow_matcher,
            sparse_matcher,
        );
        let cached_file_sizes = self.file_nodeid_to_size.len();

        // Collect all file sizes in parallel
        let size_span = tracing::debug_span!("computing sizes").entered();
        let vec = files_for_rev
            .par_iter()
            .map(|res| {
                let (path, file_node, flags) = res?;
                if let Some(size) = self.file_nodeid_to_size.get(&file_node) {
                    // We already know this size
                    return Ok(FileInfo {
                        path,
                        size: *size,
                        flags,
                        token: LocalToken(file_node),
                    });
                }
                let filelog = self.repo.filelog(path)?;
                // TODO keep a persistent NodeTree of filenode_id -> size until
                // we have it in revlogv2?
                let size = u_u64(filelog.contents_size_for_node(file_node)?);
                self.file_nodeid_to_size.insert(file_node, size);
                Ok(FileInfo { path, size, flags, token: LocalToken(file_node) })
            })
            .collect::<Result<Vec<_>, hg::revlog::RevlogError>>()?;
        drop(size_span);

        let cache_misses = self.file_nodeid_to_size.len() - cached_file_sizes;
        tracing::debug!("cached {} new filelog node sizes", cache_misses);

        Ok(ChangesetFilesIterator { inner: vec })
    }
}

impl StoreBackend<LocalToken> for LocalBackend {
    fn server_config(&self) -> &Config {
        &self.server_config
    }

    fn branch(&self, changeset: Node) -> Result<String, Error<LocalToken>> {
        match self.repo.changelog()?.branch(changeset) {
            Ok(branch) => Ok(branch),
            Err(err) => match err {
                HgError::Revlog(hg::revlog::RevlogError::InvalidRevision {
                    ..
                }) => Err(ErrorKind::NoSuchChangeset(changeset))?,
                _ => Err(err)?,
            },
        }
    }

    fn idx_for_node(
        &self,
        changeset: Node,
    ) -> Result<RevisionIdx, Error<LocalToken>> {
        if let Ok(idx) = self
            .repo
            .changelog()?
            .rev_from_node(changeset.into())
            .map(|n| RevisionIdx(n.0.try_into().expect("invalid revision")))
        {
            return Ok(idx);
        }
        // TODO report errors somehow?
        _ = self.repo.reload_revlogs();
        Ok(self
            .repo
            .changelog()?
            .rev_from_node(changeset.into())
            .map(|n| RevisionIdx(n.0.try_into().expect("invalid revision")))
            .map_err(|_| ErrorKind::NoSuchChangeset(changeset))?)
    }

    fn node_for_idx(
        &self,
        idx: RevisionIdx,
    ) -> Result<Node, Error<LocalToken>> {
        let changelog = self.repo.changelog()?;
        let revnum =
            idx.0.try_into().map_err(|_| ErrorKind::InvalidRevisionIdx(idx))?;
        let node_opt =
            changelog.node_from_unchecked_rev(UncheckedRevision(revnum));
        Ok(*node_opt.ok_or(ErrorKind::InvalidRevisionIdx(idx))?)
    }

    #[tracing::instrument(level = "debug", skip_all)]
    fn changeset_files(
        &self,
        changeset: Node,
    ) -> Result<impl ChangesetFiles<LocalToken>, Error<LocalToken>> {
        // Get the manifest
        let changelog = self.repo.changelog()?;
        let changeset_rev = changelog
            .rev_from_node(changeset.into())
            .map_err(|_| ErrorKind::NoSuchChangeset(changeset))?;
        let manifest = self.repo.manifest_for_node(changeset)?;

        // The sparse matcher
        let warnings = HgWarningContext::new();
        let sparse_matcher = sparse::matcher(
            &self.repo,
            Some(vec![changeset_rev]),
            warnings.sender(),
        )
        .map_err(HgError::from)?;
        let _ = warnings.finish(|warning| -> Result<(), Infallible> {
            // TODO better warnings
            tracing::warn!("sparse warning: {:?}", warning);
            Ok(())
        });

        // Create the iterator
        let manifest_files_iterator = ManifestRefIterator::try_new(
            manifest,
            |manifest| -> Result<ChangesetFilesIterator, HgError> {
                self.changeset_files_iterator(manifest, &sparse_matcher)
            },
        )?;
        Ok(manifest_files_iterator)
    }

    fn file_data(
        &self,
        changeset: Node,
        path: &HgPath,
        token: LocalToken,
    ) -> Result<RawData, Error<LocalToken>> {
        let Ok(filelog) = self.repo.filelog(path) else {
            return Err(ErrorKind::NoSuchFile {
                changeset,
                path: path.to_owned(),
                token,
            })?;
        };
        let data_for_node = match filelog
            .data_for_node(token.0)
            .and_then(|data| data.into_file_data())
        {
            Ok(data_for_node) => data_for_node,
            Err(e) => {
                tracing::debug!("read failed {:?}", e);
                return Err(ErrorKind::ReadFailed {
                    changeset,
                    path: path.to_owned(),
                    token,
                })?;
            }
        };
        Ok(data_for_node)
    }

    fn changeset_store_info(
        &self,
        changeset: Node,
    ) -> Result<Option<StoreInfo>, Error<LocalToken>> {
        let branch = self.branch(changeset)?;
        Ok(Some(StoreInfo {
            changeset,
            share_source: self.repo.working_directory_path().join(".hg"),
            narrow_patterns: narrow::raw_store_patterns(&self.repo)?,
            has_sparse: self.repo.has_sparse(),
            branch,
        }))
    }
}

self_cell!(
    /// Allows for the creation of an iterator over a [`Manifest`] inside the
    /// same struct.
    pub struct ManifestRefIterator {
        owner: Manifest,
        #[covariant]
        dependent: ChangesetFilesIterator,
    }
);

/// An implementation of [`ChangesetFiles`] for a local repository
pub struct ChangesetFilesIterator<'manifest> {
    inner: Vec<FileInfo<'manifest, LocalToken>>,
}

impl ChangesetFiles<LocalToken> for ManifestRefIterator {
    fn iter(&self) -> impl Iterator<Item = &FileInfo<'_, LocalToken>> {
        self.borrow_dependent().inner.iter()
    }
}

/// An implementation of [`FileToken`] for a local repository
#[derive(Debug, Clone, Copy)]
pub struct LocalToken(pub Node);

impl FileToken for LocalToken {}
