use crate::config::{Config, ConfigError, ConfigParseError};
use crate::dirstate::dirstate_map::{DirstateIdentity, DirstateMapWriteMode};
use crate::dirstate::on_disk::Docket as DirstateDocket;
use crate::dirstate::owning::OwningDirstateMap;
use crate::dirstate::{DirstateError, DirstateParents};
use crate::errors::HgResultExt;
use crate::errors::{HgError, IoResultExt};
use crate::lock::{try_with_lock_no_wait, LockError};
use crate::requirements::DIRSTATE_TRACKED_HINT_V1;
use crate::revlog::changelog::Changelog;
use crate::revlog::filelog::Filelog;
use crate::revlog::manifest::{Manifest, Manifestlog};
use crate::revlog::options::default_revlog_options;
use crate::revlog::{RevlogError, RevlogType};
use crate::utils::debug::debug_wait_for_file_or_print;
use crate::utils::files::get_path_from_bytes;
use crate::utils::hg_path::HgPath;
use crate::utils::strings::SliceExt;
use crate::vfs::{is_dir, is_file, Vfs, VfsImpl};
use crate::{exit_codes, requirements, NodePrefix, UncheckedRevision};
use std::cell::{Ref, RefCell, RefMut};
use std::collections::HashSet;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write as IoWrite;
use std::path::{Path, PathBuf};

const V2_MAX_READ_ATTEMPTS: usize = 5;

/// Docket file identity, data file uuid and the data size
type DirstateV2Identity = (Option<DirstateIdentity>, Option<Vec<u8>>, usize);

/// A repository on disk
pub struct Repo {
    working_directory: PathBuf,
    dot_hg: PathBuf,
    store: PathBuf,
    requirements: HashSet<String>,
    config: Config,
    dirstate_parents: LazyCell<DirstateParents>,
    dirstate_map: LazyCell<OwningDirstateMap>,
    changelog: LazyCell<Changelog>,
    manifestlog: LazyCell<Manifestlog>,
}

#[derive(Debug, derive_more::From)]
pub enum RepoError {
    NotFound {
        at: PathBuf,
    },
    #[from]
    ConfigParseError(ConfigParseError),
    #[from]
    Other(HgError),
}

impl From<ConfigError> for RepoError {
    fn from(error: ConfigError) -> Self {
        match error {
            ConfigError::Parse(error) => error.into(),
            ConfigError::Other(error) => error.into(),
        }
    }
}

impl From<RepoError> for HgError {
    fn from(value: RepoError) -> Self {
        match value {
            RepoError::NotFound { at } => HgError::abort(
                format!(
                    "abort: no repository found in '{}' (.hg not found)!",
                    at.display()
                ),
                exit_codes::ABORT,
                None,
            ),
            RepoError::ConfigParseError(config_parse_error) => {
                HgError::Abort {
                    message: String::from_utf8_lossy(
                        &config_parse_error.message,
                    )
                    .to_string(),
                    detailed_exit_code: exit_codes::CONFIG_PARSE_ERROR_ABORT,
                    hint: None,
                }
            }
            RepoError::Other(hg_error) => hg_error,
        }
    }
}

impl Repo {
    /// tries to find nearest repository root in current working directory or
    /// its ancestors
    pub fn find_repo_root() -> Result<PathBuf, RepoError> {
        let current_directory = crate::utils::current_dir()?;
        // ancestors() is inclusive: it first yields `current_directory`
        // as-is.
        for ancestor in current_directory.ancestors() {
            if is_dir(ancestor.join(".hg"))? {
                return Ok(ancestor.to_path_buf());
            }
        }
        Err(RepoError::NotFound {
            at: current_directory,
        })
    }

    /// Find a repository, either at the given path (which must contain a `.hg`
    /// sub-directory) or by searching the current directory and its
    /// ancestors.
    ///
    /// A method with two very different "modes" like this usually a code smell
    /// to make two methods instead, but in this case an `Option` is what rhg
    /// sub-commands get from Clap for the `-R` / `--repository` CLI argument.
    /// Having two methods would just move that `if` to almost all callers.
    pub fn find(
        config: &Config,
        explicit_path: Option<PathBuf>,
    ) -> Result<Self, RepoError> {
        if let Some(root) = explicit_path {
            if is_dir(root.join(".hg"))? {
                Self::new_at_path(root, config)
            } else if is_file(&root)? {
                Err(HgError::unsupported("bundle repository").into())
            } else {
                Err(RepoError::NotFound { at: root })
            }
        } else {
            let root = Self::find_repo_root()?;
            Self::new_at_path(root, config)
        }
    }

    /// To be called after checking that `.hg` is a sub-directory
    fn new_at_path(
        working_directory: PathBuf,
        config: &Config,
    ) -> Result<Self, RepoError> {
        let dot_hg = working_directory.join(".hg");

        let mut repo_config_files =
            vec![dot_hg.join("hgrc"), dot_hg.join("hgrc-not-shared")];

        let hg_vfs = VfsImpl::new(dot_hg.to_owned(), false);
        let mut reqs = requirements::load_if_exists(&hg_vfs)?;
        let relative =
            reqs.contains(requirements::RELATIVE_SHARED_REQUIREMENT);
        let shared =
            reqs.contains(requirements::SHARED_REQUIREMENT) || relative;

        // From `mercurial/localrepo.py`:
        //
        // if .hg/requires contains the sharesafe requirement, it means
        // there exists a `.hg/store/requires` too and we should read it
        // NOTE: presence of SHARESAFE_REQUIREMENT imply that store requirement
        // is present. We never write SHARESAFE_REQUIREMENT for a repo if store
        // is not present, refer checkrequirementscompat() for that
        //
        // However, if SHARESAFE_REQUIREMENT is not present, it means that the
        // repository was shared the old way. We check the share source
        // .hg/requires for SHARESAFE_REQUIREMENT to detect whether the
        // current repository needs to be reshared
        let share_safe = reqs.contains(requirements::SHARESAFE_REQUIREMENT);

        let store_path;
        if !shared {
            store_path = dot_hg.join("store");
        } else {
            let bytes = hg_vfs.read("sharedpath")?;
            let mut shared_path =
                get_path_from_bytes(bytes.trim_end_matches(|b| b == b'\n'))
                    .to_owned();
            if relative {
                shared_path = dot_hg.join(shared_path)
            }
            if !is_dir(&shared_path)? {
                return Err(HgError::corrupted(format!(
                    ".hg/sharedpath points to nonexistent directory {}",
                    shared_path.display()
                ))
                .into());
            }

            store_path = shared_path.join("store");

            let source_is_share_safe = requirements::load(VfsImpl::new(
                shared_path.to_owned(),
                true,
            ))?
            .contains(requirements::SHARESAFE_REQUIREMENT);

            if share_safe != source_is_share_safe {
                return Err(HgError::unsupported("share-safe mismatch").into());
            }

            if share_safe {
                repo_config_files.insert(0, shared_path.join("hgrc"))
            }
        }
        if share_safe {
            reqs.extend(requirements::load(VfsImpl::new(
                store_path.to_owned(),
                true,
            ))?);
        }

        let repo_config = if std::env::var_os("HGRCSKIPREPO").is_none() {
            config.combine_with_repo(&repo_config_files)?
        } else {
            config.clone()
        };

        let repo = Self {
            requirements: reqs,
            working_directory,
            store: store_path,
            dot_hg,
            config: repo_config,
            dirstate_parents: LazyCell::new(),
            dirstate_map: LazyCell::new(),
            changelog: LazyCell::new(),
            manifestlog: LazyCell::new(),
        };

        requirements::check(&repo)?;

        Ok(repo)
    }

    pub fn working_directory_path(&self) -> &Path {
        &self.working_directory
    }

    pub fn requirements(&self) -> &HashSet<String> {
        &self.requirements
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    /// For accessing repository files (in `.hg`), except for the store
    /// (`.hg/store`).
    pub fn hg_vfs(&self) -> VfsImpl {
        VfsImpl::new(self.dot_hg.to_owned(), false)
    }

    /// For accessing repository store files (in `.hg/store`)
    pub fn store_vfs(&self) -> VfsImpl {
        VfsImpl::new(self.store.to_owned(), false)
    }

    /// For accessing the working copy
    pub fn working_directory_vfs(&self) -> VfsImpl {
        VfsImpl::new(self.working_directory.to_owned(), false)
    }

    pub fn try_with_wlock_no_wait<R>(
        &self,
        f: impl FnOnce() -> R,
    ) -> Result<R, LockError> {
        try_with_lock_no_wait(&self.hg_vfs(), "wlock", f)
    }

    /// Whether this repo should use dirstate-v2.
    /// The presence of `dirstate-v2` in the requirements does not mean that
    /// the on-disk dirstate is necessarily in version 2. In most cases,
    /// a dirstate-v2 file will indeed be found, but in rare cases (like the
    /// upgrade mechanism being cut short), the on-disk version will be a
    /// v1 file.
    /// Semantically, having a requirement only means that a client cannot
    /// properly understand or properly update the repo if it lacks the support
    /// for the required feature, but not that that feature is actually used
    /// in all occasions.
    pub fn use_dirstate_v2(&self) -> bool {
        self.requirements
            .contains(requirements::DIRSTATE_V2_REQUIREMENT)
    }

    pub fn has_sparse(&self) -> bool {
        self.requirements.contains(requirements::SPARSE_REQUIREMENT)
    }

    pub fn has_narrow(&self) -> bool {
        self.requirements.contains(requirements::NARROW_REQUIREMENT)
    }

    pub fn has_nodemap(&self) -> bool {
        self.requirements
            .contains(requirements::NODEMAP_REQUIREMENT)
    }

    fn dirstate_file_contents(&self) -> Result<Vec<u8>, HgError> {
        Ok(self
            .hg_vfs()
            .read("dirstate")
            .io_not_found_as_none()?
            .unwrap_or_default())
    }

    fn dirstate_identity(&self) -> Result<Option<DirstateIdentity>, HgError> {
        Ok(self
            .hg_vfs()
            .symlink_metadata("dirstate")
            .io_not_found_as_none()?
            .map(DirstateIdentity::from))
    }

    pub fn dirstate_parents(&self) -> Result<DirstateParents, HgError> {
        Ok(*self
            .dirstate_parents
            .get_or_init(|| self.read_dirstate_parents())?)
    }

    fn read_dirstate_parents(&self) -> Result<DirstateParents, HgError> {
        let dirstate = self.dirstate_file_contents()?;
        let parents = if dirstate.is_empty() {
            DirstateParents::NULL
        } else if self.use_dirstate_v2() {
            let docket_res = crate::dirstate::on_disk::read_docket(&dirstate);
            match docket_res {
                Ok(docket) => docket.parents(),
                Err(_) => {
                    log::info!(
                        "Parsing dirstate docket failed, \
                        falling back to dirstate-v1"
                    );
                    *crate::dirstate::parsers::parse_dirstate_parents(
                        &dirstate,
                    )?
                }
            }
        } else {
            *crate::dirstate::parsers::parse_dirstate_parents(&dirstate)?
        };
        self.dirstate_parents.set(parents);
        Ok(parents)
    }

    /// Returns the information read from the dirstate docket necessary to
    /// check if the data file has been updated/deleted by another process
    /// since we last read the dirstate.
    /// Namely the docket file identity, data file uuid and the data size.
    fn get_dirstate_data_file_integrity(
        &self,
    ) -> Result<DirstateV2Identity, HgError> {
        assert!(
            self.use_dirstate_v2(),
            "accessing dirstate data file ID without dirstate-v2"
        );
        // Get the identity before the contents since we could have a race
        // between the two. Having an identity that is too old is fine, but
        // one that is younger than the content change is bad.
        let identity = self.dirstate_identity()?;
        let dirstate = self.dirstate_file_contents()?;
        if dirstate.is_empty() {
            Ok((identity, None, 0))
        } else {
            let docket_res = crate::dirstate::on_disk::read_docket(&dirstate);
            match docket_res {
                Ok(docket) => {
                    self.dirstate_parents.set(docket.parents());
                    Ok((
                        identity,
                        Some(docket.uuid.to_owned()),
                        docket.data_size(),
                    ))
                }
                Err(_) => {
                    log::info!(
                        "Parsing dirstate docket failed, \
                        falling back to dirstate-v1"
                    );
                    let parents =
                        *crate::dirstate::parsers::parse_dirstate_parents(
                            &dirstate,
                        )?;
                    self.dirstate_parents.set(parents);
                    Ok((identity, None, 0))
                }
            }
        }
    }

    fn new_dirstate_map(&self) -> Result<OwningDirstateMap, DirstateError> {
        if self.use_dirstate_v2() {
            // The v2 dirstate is split into a docket and a data file.
            // Since we don't always take the `wlock` to read it
            // (like in `hg status`), it is susceptible to races.
            // A simple retry method should be enough since full rewrites
            // only happen when too much garbage data is present and
            // this race is unlikely.
            let mut tries = 0;

            while tries < V2_MAX_READ_ATTEMPTS {
                tries += 1;
                match self.read_docket_and_data_file() {
                    Ok(m) => {
                        return Ok(m);
                    }
                    Err(e) => match e {
                        DirstateError::Common(HgError::RaceDetected(
                            context,
                        )) => {
                            log::info!(
                                "dirstate read race detected {} (retry {}/{})",
                                context,
                                tries,
                                V2_MAX_READ_ATTEMPTS,
                            );
                            continue;
                        }
                        _ => {
                            log::info!(
                                "Reading dirstate v2 failed, \
                                falling back to v1"
                            );
                            return self.new_dirstate_map_v1();
                        }
                    },
                }
            }
            let error = HgError::abort(
                format!("dirstate read race happened {tries} times in a row"),
                255,
                None,
            );
            Err(DirstateError::Common(error))
        } else {
            self.new_dirstate_map_v1()
        }
    }

    fn new_dirstate_map_v1(&self) -> Result<OwningDirstateMap, DirstateError> {
        debug_wait_for_file_or_print(self.config(), "dirstate.pre-read-file");
        let identity = self.dirstate_identity()?;
        let dirstate_file_contents = self.dirstate_file_contents()?;
        let parents = self.dirstate_parents()?;
        if dirstate_file_contents.is_empty() {
            self.dirstate_parents.set(parents);
            Ok(OwningDirstateMap::new_empty(Vec::new(), identity))
        } else {
            // Ignore the dirstate on-disk parents, they may have been set in
            // the repo before
            let (map, _) =
                OwningDirstateMap::new_v1(dirstate_file_contents, identity)?;
            self.dirstate_parents.set(parents);
            Ok(map)
        }
    }

    fn read_docket_and_data_file(
        &self,
    ) -> Result<OwningDirstateMap, DirstateError> {
        debug_wait_for_file_or_print(self.config(), "dirstate.pre-read-file");
        let dirstate_file_contents = self.dirstate_file_contents()?;
        let identity = self.dirstate_identity()?;
        if dirstate_file_contents.is_empty() {
            return Ok(OwningDirstateMap::new_empty(Vec::new(), identity));
        }
        let docket =
            crate::dirstate::on_disk::read_docket(&dirstate_file_contents)?;
        debug_wait_for_file_or_print(
            self.config(),
            "dirstate.post-docket-read-file",
        );
        self.dirstate_parents.set(docket.parents());
        let uuid = docket.uuid.to_owned();
        let data_size = docket.data_size();

        let context = "between reading dirstate docket and data file";
        let race_error = HgError::RaceDetected(context.into());
        let metadata = docket.tree_metadata();

        let mut map = if crate::vfs::is_on_nfs_mount(docket.data_filename()) {
            // Don't mmap on NFS to prevent `SIGBUS` error on deletion
            let contents = self.hg_vfs().read(docket.data_filename());
            let contents = match contents {
                Ok(c) => c,
                Err(HgError::IoError { error, context }) => {
                    match error.raw_os_error().expect("real os error") {
                        // 2 = ENOENT, No such file or directory
                        // 116 = ESTALE, Stale NFS file handle
                        //
                        // TODO match on `error.kind()` when
                        // `ErrorKind::StaleNetworkFileHandle` is stable.
                        2 | 116 => {
                            // Race where the data file was deleted right after
                            // we read the docket, try again
                            return Err(race_error.into());
                        }
                        _ => {
                            return Err(
                                HgError::IoError { error, context }.into()
                            )
                        }
                    }
                }
                Err(e) => return Err(e.into()),
            };
            OwningDirstateMap::new_v2(
                contents, data_size, metadata, uuid, identity,
            )
        } else {
            match self
                .hg_vfs()
                .mmap_open(docket.data_filename())
                .io_not_found_as_none()
            {
                Ok(Some(data_mmap)) => OwningDirstateMap::new_v2(
                    data_mmap, data_size, metadata, uuid, identity,
                ),
                Ok(None) => {
                    // Race where the data file was deleted right after we
                    // read the docket, try again
                    return Err(race_error.into());
                }
                Err(e) => return Err(e.into()),
            }
        }?;

        let write_mode_config = self
            .config()
            .get_str(b"devel", b"dirstate.v2.data_update_mode")
            .unwrap_or(Some("auto"))
            .unwrap_or("auto"); // don't bother for devel options
        let write_mode = match write_mode_config {
            "auto" => DirstateMapWriteMode::Auto,
            "force-new" => DirstateMapWriteMode::ForceNewDataFile,
            "force-append" => DirstateMapWriteMode::ForceAppend,
            _ => DirstateMapWriteMode::Auto,
        };

        let tracked_hint =
            self.requirements().contains(DIRSTATE_TRACKED_HINT_V1);

        map.with_dmap_mut(|m| {
            m.set_write_mode(write_mode);
            m.set_tracked_hint(tracked_hint);
        });

        Ok(map)
    }

    pub fn dirstate_map(
        &self,
    ) -> Result<Ref<OwningDirstateMap>, DirstateError> {
        self.dirstate_map.get_or_init(|| self.new_dirstate_map())
    }

    pub fn dirstate_map_mut(
        &self,
    ) -> Result<RefMut<OwningDirstateMap>, DirstateError> {
        self.dirstate_map
            .get_mut_or_init(|| self.new_dirstate_map())
    }

    fn new_changelog(&self) -> Result<Changelog, HgError> {
        Changelog::open(
            &self.store_vfs(),
            default_revlog_options(
                self.config(),
                self.requirements(),
                RevlogType::Changelog,
            )?,
        )
    }

    pub fn changelog(&self) -> Result<Ref<Changelog>, HgError> {
        self.changelog.get_or_init(|| self.new_changelog())
    }

    pub fn changelog_mut(&self) -> Result<RefMut<Changelog>, HgError> {
        self.changelog.get_mut_or_init(|| self.new_changelog())
    }

    fn new_manifestlog(&self) -> Result<Manifestlog, HgError> {
        Manifestlog::open(
            &self.store_vfs(),
            default_revlog_options(
                self.config(),
                self.requirements(),
                RevlogType::Manifestlog,
            )?,
        )
    }

    pub fn manifestlog(&self) -> Result<Ref<Manifestlog>, HgError> {
        self.manifestlog.get_or_init(|| self.new_manifestlog())
    }

    pub fn manifestlog_mut(&self) -> Result<RefMut<Manifestlog>, HgError> {
        self.manifestlog.get_mut_or_init(|| self.new_manifestlog())
    }

    /// Returns the manifest of the *changeset* with the given node ID
    pub fn manifest_for_node(
        &self,
        node: impl Into<NodePrefix>,
    ) -> Result<Manifest, RevlogError> {
        self.manifestlog()?.data_for_node(
            self.changelog()?
                .data_for_node(node.into())?
                .manifest_node()?
                .into(),
        )
    }

    /// Returns the manifest of the *changeset* with the given revision number
    pub fn manifest_for_rev(
        &self,
        revision: UncheckedRevision,
    ) -> Result<Manifest, RevlogError> {
        self.manifestlog()?.data_for_node(
            self.changelog()?
                .data_for_unchecked_rev(revision)?
                .manifest_node()?
                .into(),
        )
    }

    pub fn has_subrepos(&self) -> Result<bool, DirstateError> {
        if let Some(entry) = self.dirstate_map()?.get(HgPath::new(".hgsub"))? {
            Ok(entry.tracked())
        } else {
            Ok(false)
        }
    }

    pub fn filelog(&self, path: &HgPath) -> Result<Filelog, HgError> {
        Filelog::open(
            self,
            path,
            default_revlog_options(
                self.config(),
                self.requirements(),
                RevlogType::Filelog,
            )?,
        )
    }
    /// Write to disk any updates that were made through `dirstate_map_mut`.
    ///
    /// The "wlock" must be held while calling this.
    /// See for example `try_with_wlock_no_wait`.
    ///
    /// TODO: have a `WritableRepo` type only accessible while holding the
    /// lock?
    pub fn write_dirstate(&self) -> Result<(), DirstateError> {
        let map = self.dirstate_map()?;
        // TODO: Maintain a `DirstateMap::dirty` flag, and return early here if
        // it’s unset
        let parents = self.dirstate_parents()?;
        let (packed_dirstate, old_uuid_to_remove) = if self.use_dirstate_v2() {
            let (identity, uuid, data_size) =
                self.get_dirstate_data_file_integrity()?;
            let identity_changed = identity != map.old_identity();
            let uuid_changed = uuid.as_deref() != map.old_uuid();
            let data_length_changed = data_size != map.old_data_size();

            if identity_changed || uuid_changed || data_length_changed {
                // If any of identity, uuid or length have changed since
                // last disk read, don't write.
                // This is fine because either we're in a command that doesn't
                // write anything too important (like `hg status`), or we're in
                // `hg add` and we're supposed to have taken the lock before
                // reading anyway.
                //
                // TODO complain loudly if we've changed anything important
                // without taking the lock.
                // (see `hg help config.format.use-dirstate-tracked-hint`)
                log::debug!(
                    "dirstate has changed since last read, not updating."
                );
                return Ok(());
            }

            let uuid_opt = map.old_uuid();
            let write_mode = if uuid_opt.is_some() {
                DirstateMapWriteMode::Auto
            } else {
                DirstateMapWriteMode::ForceNewDataFile
            };
            let (data, tree_metadata, append, old_data_size) =
                map.pack_v2(write_mode)?;

            // Reuse the uuid, or generate a new one, keeping the old for
            // deletion.
            let (uuid, old_uuid) = match uuid_opt {
                Some(uuid) => {
                    let as_str = std::str::from_utf8(uuid)
                        .map_err(|_| {
                            HgError::corrupted(
                                "non-UTF-8 dirstate data file ID",
                            )
                        })?
                        .to_owned();
                    if append {
                        (as_str, None)
                    } else {
                        (DirstateDocket::new_uid(), Some(as_str))
                    }
                }
                None => (DirstateDocket::new_uid(), None),
            };

            let data_filename = format!("dirstate.{}", uuid);
            let data_filename = self.hg_vfs().join(data_filename);
            let mut options = std::fs::OpenOptions::new();
            options.write(true);

            // Why are we not using the O_APPEND flag when appending?
            //
            // - O_APPEND makes it trickier to deal with garbage at the end of
            //   the file, left by a previous uncommitted transaction. By
            //   starting the write at [old_data_size] we make sure we erase
            //   all such garbage.
            //
            // - O_APPEND requires to special-case 0-byte writes, whereas we
            //   don't need that.
            //
            // - Some OSes have bugs in implementation O_APPEND:
            //   revlog.py talks about a Solaris bug, but we also saw some ZFS
            //   bug: https://github.com/openzfs/zfs/pull/3124,
            //   https://github.com/openzfs/zfs/issues/13370
            //
            if !append {
                log::trace!("creating a new dirstate data file");
                options.create_new(true);
            } else {
                log::trace!("appending to the dirstate data file");
            }

            let data_size = (|| {
                // TODO: loop and try another random ID if !append and this
                // returns `ErrorKind::AlreadyExists`? Collision chance of two
                // random IDs is one in 2**32
                let mut file = options.open(&data_filename)?;
                if append {
                    file.seek(SeekFrom::Start(old_data_size as u64))?;
                }
                file.write_all(&data)?;
                file.flush()?;
                file.stream_position()
            })()
            .when_writing_file(&data_filename)?;

            let packed_dirstate = DirstateDocket::serialize(
                parents,
                tree_metadata,
                data_size,
                uuid.as_bytes(),
            )
            .map_err(|_: std::num::TryFromIntError| {
                HgError::corrupted("overflow in dirstate docket serialization")
            })?;

            (packed_dirstate, old_uuid)
        } else {
            let identity = self.dirstate_identity()?;
            if identity != map.old_identity() {
                // If identity changed since last disk read, don't write.
                // This is fine because either we're in a command that doesn't
                // write anything too important (like `hg status`), or we're in
                // `hg add` and we're supposed to have taken the lock before
                // reading anyway.
                //
                // TODO complain loudly if we've changed anything important
                // without taking the lock.
                // (see `hg help config.format.use-dirstate-tracked-hint`)
                log::debug!(
                    "dirstate has changed since last read, not updating."
                );
                return Ok(());
            }
            (map.pack_v1(parents)?, None)
        };

        let vfs = self.hg_vfs();
        vfs.atomic_write("dirstate", &packed_dirstate)?;
        if let Some(uuid) = old_uuid_to_remove {
            // Remove the old data file after the new docket pointing to the
            // new data file was written.
            vfs.unlink(Path::new(&format!("dirstate.{}", uuid)))?;
        }
        Ok(())
    }

    pub fn node(&self, rev: UncheckedRevision) -> Option<crate::Node> {
        self.changelog()
            .ok()
            .and_then(|c| c.node_from_unchecked_rev(rev).copied())
    }

    /// Change the current working directory parents cached in the repo.
    ///
    /// TODO
    /// This does *not* do a lot of what it expected from a full `set_parents`:
    ///     - parents should probably be stored in the dirstate
    ///     - dirstate should have a "changing parents" context
    ///     - dirstate should return copies if out of a merge context to be
    ///       discarded within the repo context
    /// See `setparents` in `context.py`.
    pub fn manually_set_parents(
        &self,
        new_parents: DirstateParents,
    ) -> Result<(), HgError> {
        let mut parents = self.dirstate_parents.value.borrow_mut();
        *parents = Some(new_parents);
        Ok(())
    }
}

/// Lazily-initialized component of `Repo` with interior mutability
///
/// This differs from `OnceCell` in that the value can still be "deinitialized"
/// later by setting its inner `Option` to `None`. It also takes the
/// initialization function as an argument when the value is requested, not
/// when the instance is created.
struct LazyCell<T> {
    value: RefCell<Option<T>>,
}

impl<T> LazyCell<T> {
    fn new() -> Self {
        Self {
            value: RefCell::new(None),
        }
    }

    fn set(&self, value: T) {
        *self.value.borrow_mut() = Some(value)
    }

    fn get_or_init<E>(
        &self,
        init: impl Fn() -> Result<T, E>,
    ) -> Result<Ref<T>, E> {
        let mut borrowed = self.value.borrow();
        if borrowed.is_none() {
            drop(borrowed);
            // Only use `borrow_mut` if it is really needed to avoid panic in
            // case there is another outstanding borrow but mutation is not
            // needed.
            *self.value.borrow_mut() = Some(init()?);
            borrowed = self.value.borrow()
        }
        Ok(Ref::map(borrowed, |option| option.as_ref().unwrap()))
    }

    fn get_mut_or_init<E>(
        &self,
        init: impl Fn() -> Result<T, E>,
    ) -> Result<RefMut<T>, E> {
        let mut borrowed = self.value.borrow_mut();
        if borrowed.is_none() {
            *borrowed = Some(init()?);
        }
        Ok(RefMut::map(borrowed, |option| option.as_mut().unwrap()))
    }
}
