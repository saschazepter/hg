//! A layer of lower-level revlog functionality to encapsulate most of the
//! IO work and expensive operations.
use std::borrow::Cow;
use std::io::ErrorKind;
use std::io::Seek;
use std::io::SeekFrom;
use std::io::Write;
use std::ops::Deref;
use std::ops::DerefMut;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::RwLock;
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::Ordering;

use schnellru::LruMap;
use sha1::Digest;
use sha1::Sha1;

use super::BaseRevision;
use super::NULL_REVISION;
use super::NULL_REVLOG_ENTRY_FLAGS;
use super::Revision;
use super::RevlogEntry;
use super::RevlogError;
use super::RevlogIndex;
use super::UncheckedRevision;
use super::compression::CompressionConfig;
use super::compression::Compressor;
use super::compression::NoneCompressor;
use super::compression::ZLIB_BYTE;
use super::compression::ZSTD_BYTE;
use super::compression::ZlibCompressor;
use super::compression::ZstdCompressor;
use super::compression::uncompressed_zstd_data;
use super::diff;
use super::diff::text_delta_with_offset;
use super::file_io::DelayedBuffer;
use super::file_io::FileHandle;
use super::file_io::RandomAccessFile;
use super::file_io::WriteHandles;
use super::index::INDEX_ENTRY_SIZE;
use super::index::Index;
use super::index::IndexHeader;
use super::manifest;
use super::node::NODE_BYTES_LENGTH;
use super::node::NULL_NODE;
use super::options::RevlogDataConfig;
use super::options::RevlogDeltaConfig;
use super::options::RevlogFeatureConfig;
use super::patch;
use super::patch::DeltaPiece;
use super::patch::PlainDeltaPiece;
use crate::Node;
use crate::NodePrefix;
use crate::dyn_bytes::DynBytes;
use crate::errors::HgError;
use crate::errors::IoResultExt;
use crate::exit_codes;
use crate::revlog::RevlogIndexNodeLookup;
use crate::revlog::RevlogType;
use crate::revlog::index::RevisionDataParams;
use crate::revlog::nodemap::NodeMap;
use crate::revlog::nodemap::NodeMapError;
use crate::revlog::nodemap::NodeTree;
use crate::transaction::Transaction;
use crate::utils::ByTotalChunksSize;
use crate::utils::RawData;
use crate::utils::u_i32;
use crate::utils::u32_u;
use crate::vfs::Vfs;

/// Matches the `_InnerRevlog` class in the Python code, as an arbitrary
/// boundary to incrementally rewrite higher-level revlog functionality in
/// Rust.
pub struct InnerRevlog {
    /// When index and data are not interleaved: bytes of the revlog index.
    /// When index and data are interleaved (inline revlog): bytes of the
    /// revlog index and data.
    pub index: Index,
    /// The store vfs that is used to interact with the filesystem
    vfs: Box<dyn Vfs>,
    /// The index file path, relative to the vfs root
    pub index_file: PathBuf,
    /// The data file path, relative to the vfs root (same as `index_file`
    /// if inline)
    data_file: PathBuf,
    /// Data config that applies to this revlog
    data_config: RevlogDataConfig,
    /// Delta config that applies to this revlog
    delta_config: RevlogDeltaConfig,
    /// Feature config that applies to this revlog
    feature_config: RevlogFeatureConfig,
    /// A view into this revlog's data file
    segment_file: RandomAccessFile,
    /// A cache of uncompressed chunks that have previously been restored.
    /// Its eviction policy is defined in [`Self::new`].
    uncompressed_chunk_cache: Option<UncompressedChunkCache>,
    /// Used to keep track of the actual target during diverted writes
    /// for the changelog
    original_index_file: Option<PathBuf>,
    /// Write handles to the index and data files
    /// XXX why duplicate from `index` and `segment_file`?
    writing_handles: Option<WriteHandles>,
    /// See [`DelayedBuffer`].
    delayed_buffer: Option<Arc<Mutex<DelayedBuffer>>>,
    /// Whether this revlog is inline. XXX why duplicate from `index`?
    pub inline: bool,
    /// A cache of the last revision, which is usually accessed multiple
    /// times.
    last_revision_cache: Mutex<Option<SingleRevisionCache>>,
    /// The [`Compressor`] that this revlog uses by default to compress data.
    /// This does not mean that this revlog uses this compressor for reading
    /// data, as different revisions may have different compression modes.
    compressor: Mutex<Box<dyn Compressor>>,
    revlog_type: RevlogType,
    /// The nodemap for this revlog, either lazy and in-memory or persistent
    nodemap: RevlogNodeMap,
}

impl InnerRevlog {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        vfs: Box<dyn Vfs>,
        index: Index,
        index_file: PathBuf,
        data_file: PathBuf,
        data_config: RevlogDataConfig,
        delta_config: RevlogDeltaConfig,
        feature_config: RevlogFeatureConfig,
        revlog_type: RevlogType,
        nodemap: Option<NodeTree>,
    ) -> Self {
        assert!(index_file.is_relative());
        assert!(data_file.is_relative());
        let segment_file = RandomAccessFile::new(
            dyn_clone::clone_box(&*vfs),
            if index.is_inline() {
                index_file.to_owned()
            } else {
                data_file.to_owned()
            },
        );

        let uncompressed_chunk_cache =
            data_config.uncompressed_cache_factor.map(
                // Arbitrary initial value
                // TODO check if using a hasher specific to integers is useful
                |_factor| {
                    let resize_factor = data_config
                        .uncompressed_cache_factor
                        .expect("cache should not exist without factor");
                    RwLock::new(LruMap::new(ByTotalChunksSize::new(
                        65536,
                        resize_factor,
                    )))
                },
            );

        let inline = index.is_inline();
        let nodemap =
            RevlogNodeMap::from_nodetree_option(nodemap, index_file.to_owned());
        Self {
            index,
            vfs,
            index_file,
            data_file,
            data_config,
            delta_config,
            feature_config,
            segment_file,
            uncompressed_chunk_cache,
            original_index_file: None,
            writing_handles: None,
            delayed_buffer: None,
            inline,
            last_revision_cache: Mutex::new(None),
            compressor: Mutex::new(match feature_config.compression_engine {
                CompressionConfig::Zlib { level } => {
                    Box::new(ZlibCompressor::new(level))
                }
                CompressionConfig::Zstd { level, threads } => {
                    Box::new(ZstdCompressor::new(level, threads))
                }
                CompressionConfig::None => Box::new(NoneCompressor),
            }),
            revlog_type,
            nodemap,
        }
    }

    /// Return number of entries of the revlog index
    pub fn len(&self) -> usize {
        self.index.len()
    }

    /// Return `true` if this revlog has no entries
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Return whether this revlog is inline (mixed index and data)
    pub fn is_inline(&self) -> bool {
        self.inline
    }

    /// Clear all caches from this revlog
    pub fn clear_cache(&mut self) {
        assert!(!self.is_delaying());
        if let Some(cache) = self.uncompressed_chunk_cache.as_ref() {
            // We don't clear the allocation here because it's probably faster.
            // We could change our minds later if this ends up being a problem
            // with regards to memory consumption.
            cache.write().expect("lock is poisoned").clear();
        }
    }

    /// Set the "last revision cache" content
    pub fn set_rev_cache(&self, rev: Revision, data: ForeignBytes) {
        let mut last_revision_cache =
            self.last_revision_cache.lock().expect("propagate mutex panic");
        let data = CachedBytes::Foreign(data);
        *last_revision_cache = Some(SingleRevisionCache { rev, data });
    }

    /// Set the "last revision cache" content from a Rust native type
    pub fn set_rev_cache_native(&self, rev: Revision, data: &RawData) {
        let mut last_revision_cache =
            self.last_revision_cache.lock().expect("propagate mutex panic");
        if let Some(cached) = &*last_revision_cache {
            // same a Arc clone when possible
            if cached.rev == rev {
                return;
            }
        }
        let data = CachedBytes::Native(data.clone());
        *last_revision_cache = Some(SingleRevisionCache { rev, data });
    }

    /// Clear the revision cache for the given revision (if any)
    pub fn clear_rev_cache(&self, rev: Revision) {
        let mut last_revision_cache =
            self.last_revision_cache.lock().expect("propagate mutex panic");
        if let Some(cached) = &*last_revision_cache
            && cached.rev == rev
        {
            last_revision_cache.take();
        }
    }

    /// retrieve a owned copy of the cache
    ///
    /// The cache lock is only held for the duration of that function and the
    /// cache value can then be used lock free.
    pub fn get_rev_cache(&self) -> Option<SingleRevisionCache> {
        let mutex_guard =
            self.last_revision_cache.lock().expect("propagate mutex panic");
        mutex_guard.as_ref().cloned()
    }

    /// Signal that we have seen a file this big
    ///
    /// This might update the limit of underlying cache.
    pub fn seen_file_size(&self, size: usize) {
        if let Some(Ok(mut cache)) =
            self.uncompressed_chunk_cache.as_ref().map(|c| c.try_write())
        {
            // Dynamically update the uncompressed_chunk_cache size to the
            // largest revision we've seen in this revlog.
            // Do it *before* restoration in case the current revision
            // is the largest.
            let limiter_mut = cache.limiter_mut();
            let new_max = size;
            limiter_mut.maybe_grow_max(new_max);
        }
    }

    /// Record the uncompressed raw chunk for rev
    ///
    /// This is a noop if the cache is disabled.
    pub fn record_uncompressed_chunk(&self, rev: Revision, data: RawData) {
        if let Some(Ok(mut cache)) =
            self.uncompressed_chunk_cache.as_ref().map(|c| c.try_write())
        {
            cache.insert(rev, data.clone());
        }
    }

    /// Return an entry for the null revision
    pub fn make_null_entry(&self) -> RevlogEntry<'_> {
        RevlogEntry {
            revlog: self,
            rev: NULL_REVISION,
            uncompressed_len: 0,
            p1: NULL_REVISION,
            p2: NULL_REVISION,
            flags: NULL_REVLOG_ENTRY_FLAGS,
            hash: NULL_NODE,
        }
    }

    /// Return the [`RevlogEntry`] for a [`Revision`] that is known to exist
    pub fn get_entry(
        &self,
        rev: Revision,
    ) -> Result<RevlogEntry<'_>, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(self.make_null_entry());
        }
        let index_entry = self.index.get_entry(rev);
        let p1 =
            self.index.check_revision(index_entry.p1()).ok_or_else(|| {
                RevlogError::corrupted(format!("p1 for rev {} is invalid", rev))
            })?;
        let p2 =
            self.index.check_revision(index_entry.p2()).ok_or_else(|| {
                RevlogError::corrupted(format!("p2 for rev {} is invalid", rev))
            })?;
        let entry = RevlogEntry {
            revlog: self,
            rev,
            uncompressed_len: index_entry.uncompressed_len(),
            p1,
            p2,
            flags: index_entry.flags(),
            hash: *index_entry.hash(),
        };
        Ok(entry)
    }

    /// Return the [`RevlogEntry`] for `rev`. If `rev` fails to check, this
    /// returns a [`RevlogError`].
    pub fn get_entry_for_unchecked_rev(
        &self,
        rev: UncheckedRevision,
    ) -> Result<RevlogEntry<'_>, RevlogError> {
        if rev == NULL_REVISION.into() {
            return Ok(self.make_null_entry());
        }
        let rev = self.index.check_revision(rev).ok_or_else(|| {
            RevlogError::corrupted(format!("rev {} is invalid", rev))
        })?;
        self.get_entry(rev)
    }

    /// Is the revlog currently delaying the visibility of written data?
    ///
    /// The delaying mechanism can be either in-memory or written on disk in a
    /// side-file.
    pub fn is_delaying(&self) -> bool {
        self.delayed_buffer.is_some() || self.original_index_file.is_some()
    }

    /// The offset of the data chunk for this revision
    #[inline(always)]
    pub fn data_start(&self, rev: Revision) -> usize {
        self.index.start(rev, &self.index.get_entry(rev))
    }

    /// The length of the data chunk for this revision
    #[inline(always)]
    pub fn data_compressed_length(&self, rev: Revision) -> usize {
        self.index.get_entry(rev).compressed_len() as usize
    }

    /// The end of the data chunk for this revision
    #[inline(always)]
    pub fn data_end(&self, rev: Revision) -> usize {
        self.data_start(rev) + self.data_compressed_length(rev)
    }

    /// Return the delta parent of the given revision
    pub fn delta_parent(&self, rev: Revision) -> Revision {
        let base =
            self.index.get_entry(rev).base_revision_or_base_of_delta_chain();
        if base.0 == rev.0 {
            NULL_REVISION
        } else if self.delta_config.general_delta {
            Revision(base.0)
        } else {
            Revision(rev.0 - 1)
        }
    }

    /// Return whether `rev` points to a snapshot revision (i.e. does not have
    /// a delta base).
    pub fn is_snapshot(&self, rev: Revision) -> Result<bool, RevlogError> {
        if !self.delta_config.sparse_revlog {
            return Ok(self.delta_parent(rev) == NULL_REVISION);
        }
        self.index.is_snapshot_unchecked(rev)
    }

    /// Return the delta chain for `rev` according to this revlog's config.
    /// See [`Index::delta_chain`] for more information.
    pub fn delta_chain(
        &self,
        rev: Revision,
        stop_rev: Option<Revision>,
    ) -> Result<(Vec<Revision>, bool), HgError> {
        self.index.delta_chain(rev, stop_rev)
    }

    /// Generate a possibly-compressed representation of data.
    /// Returns `None` if the data was not compressed.
    pub fn compress<'data>(
        &self,
        data: &'data [u8],
    ) -> Result<Option<Cow<'data, [u8]>>, RevlogError> {
        if data.is_empty() {
            return Ok(Some(data.into()));
        }
        let res = self.compressor.lock().unwrap().compress(data)?;
        if let Some(compressed) = res {
            // The revlog compressor added the header in the returned data.
            return Ok(Some(compressed.into()));
        }

        if data[0] == b'\0' {
            return Ok(Some(data.into()));
        }
        Ok(None)
    }

    /// Decompress a revlog chunk.
    ///
    /// The chunk is expected to begin with a header identifying the
    /// format type so it can be routed to an appropriate decompressor.
    pub fn decompress<'a>(
        &'a self,
        data: &'a [u8],
    ) -> Result<Cow<'a, [u8]>, RevlogError> {
        if data.is_empty() {
            return Ok(data.into());
        }

        // Revlogs are read much more frequently than they are written and many
        // chunks only take microseconds to decompress, so performance is
        // important here.

        let header = data[0];
        match header {
            // Settings don't matter as they only affect compression
            ZLIB_BYTE => Ok(ZlibCompressor::new(0).decompress(data)?.into()),
            // Settings don't matter as they only affect compression
            ZSTD_BYTE => Ok(ZstdCompressor::new(0, 0).decompress(data)?.into()),
            b'\0' => Ok(data.into()),
            b'u' => Ok((&data[1..]).into()),
            other => Err(HgError::unsupported(format!(
                "unknown compression header '{}'",
                other
            ))
            .into()),
        }
    }

    /// Obtain a segment of raw data corresponding to a range of revisions.
    ///
    /// Requests for data may be satisfied by a cache.
    ///
    /// Returns a 2-tuple of (offset, data) for the requested range of
    /// revisions. Offset is the integer offset from the beginning of the
    /// revlog and data is a slice of the raw byte data.
    ///
    /// Callers will need to call `self.start(rev)` and `self.length(rev)`
    /// to determine where each revision's data begins and ends.
    pub fn get_segment_for_revs(
        &self,
        start_rev: Revision,
        end_rev: Revision,
    ) -> Result<(usize, Vec<u8>), HgError> {
        let start = if start_rev == NULL_REVISION {
            0
        } else {
            let start_entry = self.index.get_entry(start_rev);
            self.index.start(start_rev, &start_entry)
        };
        let end_entry = self.index.get_entry(end_rev);
        let end = self.index.start(end_rev, &end_entry)
            + self.data_compressed_length(end_rev);

        let length = end - start;

        // XXX should we use mmap instead of doing this for platforms that
        // support madvise/populate?
        Ok((start, self.segment_file.read_chunk(start, length)?))
    }

    /// Return the uncompressed raw data for `rev`
    pub fn chunk_for_rev(&self, rev: Revision) -> Result<RawData, HgError> {
        if let Some(Ok(mut cache)) =
            self.uncompressed_chunk_cache.as_ref().map(|c| c.try_write())
            && let Some(chunk) = cache.get(&rev)
        {
            return Ok(chunk.clone());
        }
        // TODO revlogv2 should check the compression mode
        let data = self.get_segment_for_revs(rev, rev)?.1;
        let uncompressed = self.decompress(&data).map_err(|e| {
            HgError::abort(
                format!("revlog decompression error: {}", e),
                exit_codes::ABORT,
                None,
            )
        })?;
        let uncompressed: RawData = RawData::from(uncompressed.into_owned());
        self.record_uncompressed_chunk(rev, uncompressed.clone());
        Ok(uncompressed)
    }

    /// Execute `func` within a read context for the data file, meaning that
    /// the read handle will be taken and discarded after the operation.
    pub fn with_read<R>(
        &self,
        func: impl FnOnce() -> Result<R, RevlogError>,
    ) -> Result<R, RevlogError> {
        let exit_context = !self.is_open();
        self.enter_reading_context()?;
        let res = func();
        if exit_context {
            self.exit_reading_context();
        }
        res
    }

    /// `pub` only for use in hg-pyo3
    #[doc(hidden)]
    pub fn enter_reading_context(&self) -> Result<(), HgError> {
        if self.is_empty() {
            // Nothing to be read
            return Ok(());
        }
        if self.delayed_buffer.is_some() && self.is_inline() {
            return Err(HgError::abort(
                "revlog with delayed write should not be inline",
                exit_codes::ABORT,
                None,
            ));
        }
        self.segment_file.get_read_handle()?;
        Ok(())
    }

    /// `pub` only for use in hg-pyo3
    #[doc(hidden)]
    pub fn exit_reading_context(&self) {
        self.segment_file.exit_reading_context()
    }

    /// Fill the buffer returned by `get_buffer` with the possibly un-validated
    /// raw text for a revision. It can be already validated if it comes
    /// from the cache.
    pub fn raw_text<G, T>(
        &self,
        rev: Revision,
        get_buffer: G,
    ) -> Result<(), RevlogError>
    where
        G: FnOnce(
            usize,
            &mut dyn FnMut(
                &mut dyn RevisionBuffer<Target = T>,
            ) -> Result<(), RevlogError>,
        ) -> Result<(), RevlogError>,
    {
        let entry = &self.get_entry(rev)?;
        let raw_size = entry.uncompressed_len();
        let cached_rev = self.get_rev_cache();
        let cache = cached_rev.as_ref().map(|c| c.as_delta_base());
        if let Some(size) = raw_size {
            self.seen_file_size(u32_u(size));
        }
        let stop_rev = cache.map(|(r, _)| r);
        let (deltas, stopped) = self.chunks_for_chain(rev, stop_rev)?;
        let (base_text, deltas) = if stopped {
            (cache.expect("last revision should be cached").1, &deltas[..])
        } else {
            let (buf, deltas) = deltas.split_at(1);
            (buf[0].as_ref(), deltas)
        };
        let size = entry
            .uncompressed_len()
            .map(|l| l as usize)
            .unwrap_or(base_text.len());
        get_buffer(size, &mut |buf| {
            patch::build_data_from_deltas(buf, base_text, deltas)?;
            Ok(())
        })?;
        Ok(())
    }

    /// return a binary delta between two revisions + another delta
    ///
    /// The other delta is applied on rev_2.
    pub fn rev_delta_extra(
        &self,
        rev_1: Revision,
        rev_2: Revision,
        delta: &[u8],
    ) -> Result<Vec<u8>, RevlogError> {
        let old_entry = self.get_entry(rev_1)?;
        let old_empty = old_entry.uncompressed_len().is_some_and(|s| s == 0);

        if rev_2 == NULL_REVISION || old_empty {
            // restore the full text from the patch
            let base_text = self.get_entry(rev_2)?.data_unchecked()?;
            let d = patch::Delta::new(delta)?;
            let target_size = u_i32(base_text.len()) + d.len_diff();
            assert!(target_size > 0);
            let target_size = target_size as u32;
            let new_data = d.as_applied(&base_text, 0, target_size);

            Ok(if old_empty {
                // if the old version is empty, we can create a trivial "replace
                // all" delta
                let mut delta = vec![];
                let patch = PlainDeltaPiece {
                    start: 0,
                    end: 0,
                    data: new_data.as_ref(),
                };
                patch.write(&mut delta);
                delta
            } else {
                // NULL_REVISION don't have a delta chain, this might confuse
                // [`Self::rev_delta_non_null`] So deal with the
                // diffing here.
                assert!(rev_2 == NULL_REVISION);
                let old_data = old_entry.data_unchecked()?;
                if self.revlog_type == RevlogType::Manifestlog {
                    manifest::manifest_delta(&old_data, &new_data)
                } else {
                    diff::text_delta(&old_data, &new_data)
                }
            })
        } else {
            assert!(
                !delta.is_empty(),
                "empty delta passed to `rev_delta_extra`"
            );
            self.rev_delta_non_null(rev_1, rev_2, Some(delta))
        }
    }

    /// return a binary delta between two revisions (and an optional extra
    /// delta)
    pub fn rev_delta(
        &self,
        rev_1: Revision,
        rev_2: Revision,
    ) -> Result<Vec<u8>, RevlogError> {
        match (rev_1, rev_2) {
            (old, new) if old == new => Ok(vec![]), /* they are the same */
            // picture
            (old_rev, empty)
                if (self
                    .get_entry(empty)?
                    .uncompressed_len()
                    .is_some_and(|s| s == 0)
                    && self
                        .get_entry(old_rev)?
                        .uncompressed_len()
                        .is_some()) =>
            {
                let mut delta = vec![];
                let entry = &self.get_entry(old_rev)?;
                let deleted_size =
                    entry.uncompressed_len().expect("checked above?");
                let patch =
                    PlainDeltaPiece { start: 0, end: deleted_size, data: &[] };
                patch.write(&mut delta);
                Ok(delta)
            }
            (empty, new_rev)
                if self
                    .get_entry(empty)?
                    .uncompressed_len()
                    .is_some_and(|s| s == 0) =>
            {
                let mut delta = vec![];
                let entry = &self.get_entry(new_rev)?;
                let data = entry.data_unchecked()?;
                let patch =
                    PlainDeltaPiece { start: 0, end: 0, data: data.as_ref() };
                patch.write(&mut delta);
                Ok(delta)
            }
            (old, new) => self.rev_delta_non_null(old, new, None),
        }
    }

    /// inner part of `rev_delta` involving non null revision
    fn rev_delta_non_null(
        &self,
        rev_1: Revision,
        rev_2: Revision,
        extra_delta: Option<&[u8]>,
    ) -> Result<Vec<u8>, RevlogError> {
        // Search for common part in the delta chain of the two revisions
        //
        // We also detect if an optionally cached revision is part of such
        // common part.
        let entry_1 = &self.get_entry(rev_1)?;
        let entry_2 = &self.get_entry(rev_2)?;

        let (delta_chain_1, _) = self.delta_chain(rev_1, None)?;
        let (delta_chain_2, _) = self.delta_chain(rev_2, None)?;

        let cached_entry = self.get_rev_cache();
        let cached = cached_entry.as_ref().map(|c| c.as_delta_base());

        let zipped = std::iter::zip(delta_chain_1.iter(), delta_chain_2.iter());
        let (common_count, cached_idx) = match cached {
            None => (zipped.take_while(|(l, r)| l == r).count(), None),
            Some((cached_rev, _)) => {
                let mut count = 0;
                let mut cached_idx = None;
                for (old_rev, new_rev) in zipped {
                    if old_rev != new_rev {
                        break;
                    }
                    if cached_rev == *old_rev && count > 0 {
                        cached_idx = Some(count);
                    }
                    count += 1;
                }
                (count, cached_idx)
            }
        };

        // fast path the identical case
        //
        // This case might happen when the revision are different, the only
        // difference between them are empty delta (that got filtered
        // when building the delta chain.
        let delta = if common_count == delta_chain_1.len()
            && common_count == delta_chain_2.len()
        {
            match extra_delta {
                None => vec![],
                Some(delta) => delta.into(),
            }
        } else if common_count == 0 {
            let old_data = entry_1.data_unchecked()?;
            let new_data = if let Some(delta) = extra_delta {
                let base_text = entry_2.data_unchecked()?;
                let d = patch::Delta::new(delta)?;
                let target_size = u_i32(base_text.len()) + d.len_diff();
                assert!(target_size > 0);
                let target_size = target_size as u32;
                d.as_applied(&base_text, 0, target_size).into()
            } else {
                entry_2.data_unchecked()?
            };
            // Actually compute the delta we are looking for
            if self.revlog_type == RevlogType::Manifestlog {
                manifest::manifest_delta(&old_data, &new_data)
            } else {
                diff::text_delta(&old_data, &new_data)
            }
        } else if self.revlog_type == RevlogType::Manifestlog {
            let mut state = diff::RevDeltaState::new(
                self,
                cached_entry,
                common_count,
                cached_idx,
                delta_chain_1,
                delta_chain_2,
                extra_delta,
            )?;

            let p: diff::Prepared<'_, patch::RichDeltaPiece> =
                state.prepare()?;
            let common_2 = p.common_delta.clone();
            let new_delta = common_2.combine(p.new_delta);
            let old_delta = p.common_delta.combine(p.old_delta);
            let iter_old = old_delta.into_iter_from_base(p.base_text);
            let iter_new = new_delta.into_iter_from_base(p.base_text);
            manifest::manifest_delta_from_patches(iter_old, iter_new)
        } else {
            let mut state = diff::RevDeltaState::new(
                self,
                cached_entry,
                common_count,
                cached_idx,
                delta_chain_1,
                delta_chain_2,
                extra_delta,
            )?;

            let p: diff::Prepared<'_, PlainDeltaPiece> = state.prepare()?;

            let common_buff;
            let old_buff;
            let new_buff;

            // find the commonly affected part
            let Some((start, end)) = affected_range(&p.old_delta, &p.new_delta)
            else {
                return Ok(vec![]);
            };

            let skipped_size = p.common_size - (end - start);

            // build the common part (if ≠ from base
            let common_radix: &[u8] = if p.common_delta.is_empty() {
                &p.base_text[u32_u(start)..u32_u(end)]
            } else {
                // TODO: We could only restore the affected windows in the
                // common text.
                //
                // However it means we can no longer cache the result which has
                // a negative effect of some benchmark.
                // Restoring only the windows can have positive effect on
                // benchmark, so it is a worthy pursuit, but it need to be done
                // carefully while considering benchmark for
                // high level operation.
                common_buff = RawData::from(p.common_delta.as_applied(
                    p.base_text,
                    0,
                    p.common_size,
                ));
                self.set_rev_cache_native(p.common_rev, &common_buff);
                &common_buff[u32_u(start)..u32_u(end)]
            };

            // build the old text (if ≠ common)
            let old_data = if p.old_delta.is_empty() {
                common_radix
            } else {
                old_buff = p.old_delta.as_applied(
                    common_radix,
                    start,
                    p.old_size - skipped_size,
                );
                &old_buff
            };
            // build the new text (if ≠ common)
            let new_data = if p.new_delta.is_empty() {
                common_radix
            } else {
                new_buff = p.new_delta.as_applied(
                    common_radix,
                    start,
                    p.new_size - skipped_size,
                );
                &new_buff
            };
            text_delta_with_offset(start, old_data, new_data)
        };
        Ok(delta)
    }

    /// Only `pub` for `hg-pyo3`.
    /// Obtain decompressed raw data for the specified revisions that are
    /// assumed to be in ascending order.
    ///
    /// Returns a list with decompressed data for each requested revision.
    #[doc(hidden)]
    pub fn chunks(
        &self,
        revs: &[Revision],
        target_size: Option<u64>,
    ) -> Result<Vec<RawData>, RevlogError> {
        if revs.is_empty() {
            return Ok(vec![]);
        }
        let mut fetched_revs_vec = vec![];
        let mut chunks = Vec::with_capacity(revs.len());

        let fetched_revs = match self.uncompressed_chunk_cache.as_ref() {
            Some(cache) => {
                if let Ok(mut cache) = cache.try_write() {
                    for rev in revs.iter() {
                        match cache.get(rev) {
                            Some(hit) => chunks.push((*rev, hit.clone())),
                            None => fetched_revs_vec.push(*rev),
                        }
                    }
                    &fetched_revs_vec
                } else {
                    revs
                }
            }
            None => revs,
        };

        let already_cached = chunks.len();

        let sliced_chunks = if fetched_revs.is_empty() {
            vec![]
        } else if !self.data_config.with_sparse_read || self.is_inline() {
            vec![fetched_revs]
        } else {
            self.slice_chunk(fetched_revs, target_size)?
        };
        if !sliced_chunks.is_empty() {
            self.with_read(|| {
                for revs_chunk in sliced_chunks {
                    let first_rev = revs_chunk[0];
                    // Skip trailing revisions with empty diff
                    let last_rev_idx = revs_chunk
                        .iter()
                        .rposition(|r| self.data_compressed_length(*r) != 0)
                        .unwrap_or(revs_chunk.len() - 1);

                    let last_rev = revs_chunk[last_rev_idx];

                    let (offset, data) =
                        self.get_segment_for_revs(first_rev, last_rev)?;

                    let revs_chunk = &revs_chunk[..=last_rev_idx];

                    for rev in revs_chunk {
                        let chunk_start = self.data_start(*rev);
                        let chunk_length = self.data_compressed_length(*rev);
                        // TODO revlogv2 should check the compression mode
                        let bytes =
                            &data[chunk_start - offset..][..chunk_length];
                        let chunk = if !bytes.is_empty()
                            && bytes[0] == ZSTD_BYTE
                        {
                            // If we're using `zstd`, we want to try a more
                            // specialized decompression
                            let entry = self.index.get_entry(*rev);
                            let is_delta = entry
                                .base_revision_or_base_of_delta_chain()
                                != (*rev).into();
                            let uncompressed = uncompressed_zstd_data(
                                bytes,
                                is_delta,
                                entry.uncompressed_len(),
                            )?;
                            RawData::from(uncompressed)
                        } else {
                            // Otherwise just fallback to generic decompression.
                            RawData::from(self.decompress(bytes)?)
                        };

                        chunks.push((*rev, chunk));
                    }
                }
                Ok(())
            })?;

            if let Some(Ok(mut cache)) =
                self.uncompressed_chunk_cache.as_ref().map(|c| c.try_write())
            {
                for (rev, chunk) in chunks.iter().skip(already_cached) {
                    cache.insert(*rev, chunk.clone());
                }
            }
            // Use stable sort here since it's *mostly* sorted
            chunks.sort_by(|a, b| a.0.cmp(&b.0));
        }
        Ok(chunks.into_iter().map(|(_r, chunk)| chunk).collect())
    }

    /// Return the chunks of the delta-chain of a revision
    ///
    /// Only return the chunk for the chain above `cached_rev` if possible.
    ///
    /// return the chunks and a boolean stating if the cached_rev was reached.
    pub(super) fn chunks_for_chain(
        &self,
        rev: Revision,
        cached_rev: Option<Revision>,
    ) -> Result<(Vec<RawData>, bool), RevlogError> {
        let (delta_chain, stopped) = self.delta_chain(rev, cached_rev)?;
        // TODO: adjust the target size depending of `stopped`
        let target_size = self
            .get_entry(rev)?
            .uncompressed_len()
            .map(|raw_size| 4 * raw_size as u64);
        let deltas = self.chunks(&delta_chain, target_size)?;
        Ok((deltas, stopped))
    }

    /// Slice revs to reduce the amount of unrelated data to be read from disk.
    ///
    /// ``revs`` is sliced into groups that should be read in one time.
    /// Assume that revs are sorted.
    ///
    /// The initial chunk is sliced until the overall density
    /// (payload/chunks-span ratio) is above
    /// `revlog.data_config.sr_density_threshold`.
    /// No gap smaller than `revlog.data_config.sr_min_gap_size` is skipped.
    ///
    /// If `target_size` is set, no chunk larger than `target_size`
    /// will be returned.
    /// For consistency with other slicing choices, this limit won't go lower
    /// than `revlog.data_config.sr_min_gap_size`.
    ///
    /// If individual revision chunks are larger than this limit, they will
    /// still be raised individually.
    pub fn slice_chunk<'a>(
        &'a self,
        revs: &'a [Revision],
        target_size: Option<u64>,
    ) -> Result<Vec<&'a [Revision]>, RevlogError> {
        let target_size =
            target_size.map(|size| size.max(self.data_config.sr_min_gap_size));

        let target_density = self.data_config.sr_density_threshold;
        let min_gap_size = self.data_config.sr_min_gap_size as usize;
        let to_density = self.index.slice_chunk_to_density(
            revs,
            target_density,
            min_gap_size,
        );

        let mut sliced = vec![];

        for chunk in to_density {
            sliced.extend(
                self.slice_chunk_to_size(chunk, target_size)?.into_iter(),
            );
        }

        Ok(sliced)
    }

    /// Slice revs to match the target size
    ///
    /// This is intended to be used on chunks that density slicing selected,
    /// but that are still too large compared to the read guarantee of revlogs.
    /// This might happen when the "minimal gap size" interrupted the slicing
    /// or when chains are built in a way that create large blocks next to
    /// each other.
    fn slice_chunk_to_size<'a>(
        &self,
        revs: &'a [Revision],
        target_size: Option<u64>,
    ) -> Result<Vec<&'a [Revision]>, RevlogError> {
        let mut start_data = self.data_start(revs[0]);
        let end_data = self.data_end(revs[revs.len() - 1]);
        let full_span = end_data - start_data;

        let nothing_to_do =
            target_size.map(|size| full_span <= size as usize).unwrap_or(true);

        if nothing_to_do {
            return Ok(vec![revs]);
        }
        let target_size = target_size.expect("target_size is set") as usize;

        let mut start_rev_idx = 0;
        let mut end_rev_idx = 1;
        let mut chunks = vec![];

        for (idx, rev) in revs.iter().enumerate().skip(1) {
            let span = self.data_end(*rev) - start_data;
            let is_snapshot = self.is_snapshot(*rev)?;
            if span <= target_size && is_snapshot {
                end_rev_idx = idx + 1;
            } else {
                let chunk =
                    self.trim_chunk(revs, start_rev_idx, Some(end_rev_idx));
                if !chunk.is_empty() {
                    chunks.push(chunk);
                }
                start_rev_idx = idx;
                start_data = self.data_start(*rev);
                end_rev_idx = idx + 1;
            }
            if !is_snapshot {
                break;
            }
        }

        // For the others, we use binary slicing to quickly converge towards
        // valid chunks (otherwise, we might end up looking for the start/end
        // of many revisions). This logic is not looking for the perfect
        // slicing point, it quickly converges towards valid chunks.
        let number_of_items = revs.len();

        while (end_data - start_data) > target_size {
            end_rev_idx = number_of_items;
            if number_of_items - start_rev_idx <= 1 {
                // Protect against individual chunks larger than the limit
                break;
            }
            let mut local_end_data = self.data_end(revs[end_rev_idx - 1]);
            let mut span = local_end_data - start_data;
            while span > target_size {
                if end_rev_idx - start_rev_idx <= 1 {
                    // Protect against individual chunks larger than the limit
                    break;
                }
                end_rev_idx -= (end_rev_idx - start_rev_idx) / 2;
                local_end_data = self.data_end(revs[end_rev_idx - 1]);
                span = local_end_data - start_data;
            }
            let chunk = self.trim_chunk(revs, start_rev_idx, Some(end_rev_idx));
            if !chunk.is_empty() {
                chunks.push(chunk);
            }
            start_rev_idx = end_rev_idx;
            start_data = self.data_start(revs[start_rev_idx]);
        }

        let chunk = self.trim_chunk(revs, start_rev_idx, None);
        if !chunk.is_empty() {
            chunks.push(chunk);
        }

        Ok(chunks)
    }

    /// Returns `revs[startidx..endidx]` without empty trailing revs
    fn trim_chunk<'a>(
        &self,
        revs: &'a [Revision],
        start_rev_idx: usize,
        end_rev_idx: Option<usize>,
    ) -> &'a [Revision] {
        let mut end_rev_idx = end_rev_idx.unwrap_or(revs.len());

        // If we have a non-empty delta candidate, there is nothing to trim
        if revs[end_rev_idx - 1].0 < self.len() as BaseRevision {
            // Trim empty revs at the end, except the very first rev of a chain
            while end_rev_idx > 1
                && end_rev_idx > start_rev_idx
                && self.data_compressed_length(revs[end_rev_idx - 1]) == 0
            {
                end_rev_idx -= 1
            }
        }

        &revs[start_rev_idx..end_rev_idx]
    }

    /// Check the hash of some given data against the recorded hash.
    pub fn check_hash(
        &self,
        p1: Revision,
        p2: Revision,
        expected: &[u8],
        data: &[u8],
    ) -> bool {
        let h1 = self.index.get_entry(p1).hash();
        let h2 = self.index.get_entry(p2).hash();

        hash(data, h1.as_bytes(), h2.as_bytes()) == expected
    }

    /// Returns whether we are currently in a [`Self::with_write`] context
    pub fn is_writing(&self) -> bool {
        self.writing_handles.is_some()
    }

    /// Open the revlog files for writing
    ///
    /// Adding content to a revlog should be done within this context.
    /// TODO try using `BufRead` and `BufWrite` and see if performance improves
    pub fn with_write<R>(
        &mut self,
        transaction: &mut impl Transaction,
        data_end: Option<usize>,
        func: impl FnOnce() -> R,
    ) -> Result<R, HgError> {
        if self.is_writing() {
            return Ok(func());
        }
        self.enter_writing_context(data_end, transaction).inspect_err(
            |_| {
                self.exit_writing_context();
            },
        )?;
        let res = func();
        self.exit_writing_context();
        Ok(res)
    }

    /// `pub` only for use in hg-pyo3
    #[doc(hidden)]
    pub fn exit_writing_context(&mut self) {
        self.writing_handles.take();
        self.segment_file.writing_handle.get().map(|h| h.take());
        self.segment_file.reading_handle.get().map(|h| h.take());
    }

    /// `pub` only for use in hg-pyo3
    #[doc(hidden)]
    pub fn python_writing_handles(&self) -> Option<&WriteHandles> {
        self.writing_handles.as_ref()
    }

    /// `pub` only for use in hg-pyo3
    #[doc(hidden)]
    pub fn enter_writing_context(
        &mut self,
        data_end: Option<usize>,
        transaction: &mut impl Transaction,
    ) -> Result<(), HgError> {
        let data_size = if self.is_empty() {
            0
        } else {
            self.data_end(Revision((self.len() - 1) as BaseRevision))
        };
        let mut data_handle = if !self.is_inline() {
            let data_handle = match self.vfs.open_write(&self.data_file) {
                Ok(mut f) => {
                    if let Some(end) = data_end {
                        f.seek(SeekFrom::Start(end as u64))
                            .when_reading_file(&self.data_file)?;
                    } else {
                        f.seek(SeekFrom::End(0))
                            .when_reading_file(&self.data_file)?;
                    }
                    f
                }
                Err(err) => {
                    if err.kind() != Some(ErrorKind::NotFound) {
                        return Err(err.into());
                    }
                    self.vfs.create(&self.data_file, true)?
                }
            };
            transaction.add(&self.data_file, data_size);
            Some(FileHandle::from_file(
                data_handle,
                dyn_clone::clone_box(&*self.vfs),
                &self.data_file,
            ))
        } else {
            None
        };
        let index_size = self.len() * INDEX_ENTRY_SIZE;
        let index_handle = self.index_write_handle()?;
        if self.is_inline() {
            transaction.add(&self.index_file, data_size);
        } else {
            transaction.add(&self.index_file, index_size);
        }
        self.writing_handles = Some(WriteHandles {
            index_handle: index_handle.try_clone()?,
            data_handle: if let Some(d) = data_handle.as_mut() {
                Some(d.try_clone()?)
            } else {
                None
            },
        });
        *self.segment_file.reading_handle.get_or_default().borrow_mut() =
            if self.is_inline() {
                Some(index_handle)
            } else {
                data_handle
            };
        Ok(())
    }

    /// Get a write handle to the index, sought to the end of its data.
    fn index_write_handle(&self) -> Result<FileHandle, HgError> {
        let res = if self.delayed_buffer.is_none() {
            if self.data_config.check_ambig {
                self.vfs.open_check_ambig(&self.index_file)
            } else {
                self.vfs.open_write(&self.index_file)
            }
        } else {
            self.vfs.open_write(&self.index_file)
        };
        match res {
            Ok(mut handle) => {
                handle
                    .seek(SeekFrom::End(0))
                    .when_reading_file(&self.index_file)?;
                Ok(if let Some(delayed_buffer) = self.delayed_buffer.as_ref() {
                    FileHandle::from_file_delayed(
                        handle,
                        dyn_clone::clone_box(&*self.vfs),
                        &self.index_file,
                        delayed_buffer.clone(),
                    )?
                } else {
                    FileHandle::from_file(
                        handle,
                        dyn_clone::clone_box(&*self.vfs),
                        &self.index_file,
                    )
                })
            }
            Err(err) => {
                if err.kind() != Some(ErrorKind::NotFound) {
                    return Err(err.into());
                };
                if let Some(delayed_buffer) = self.delayed_buffer.as_ref() {
                    Ok(FileHandle::new_delayed(
                        dyn_clone::clone_box(&*self.vfs),
                        &self.index_file,
                        true,
                        delayed_buffer.clone(),
                    )?)
                } else {
                    Ok(FileHandle::new(
                        dyn_clone::clone_box(&*self.vfs),
                        &self.index_file,
                        true,
                        true,
                    )?)
                }
            }
        }
    }

    /// Split the data of an inline revlog into an index and a data file
    pub fn split_inline(
        &mut self,
        header: IndexHeader,
        new_index_file_path: Option<PathBuf>,
    ) -> Result<PathBuf, RevlogError> {
        assert!(self.delayed_buffer.is_none());
        let existing_handles = self.writing_handles.is_some();
        if let Some(handles) = &mut self.writing_handles {
            handles.index_handle.flush()?;
            self.writing_handles.take();
            self.segment_file.writing_handle.get().map(|h| h.take());
        }
        let mut new_data_file_handle =
            self.vfs.create(&self.data_file, true)?;
        // Drop any potential data, possibly redundant with the VFS impl.
        new_data_file_handle.set_len(0).when_writing_file(&self.data_file)?;

        self.with_read(|| -> Result<(), RevlogError> {
            for r in 0..self.index.len() {
                let rev = Revision(r as BaseRevision);
                let rev_segment = self.get_segment_for_revs(rev, rev)?.1;
                new_data_file_handle
                    .write_all(&rev_segment)
                    .when_writing_file(&self.data_file)?;
            }
            new_data_file_handle.flush().when_writing_file(&self.data_file)?;
            Ok(())
        })?;

        if let Some(index_path) = new_index_file_path {
            self.index_file = index_path
        }

        let mut new_index_handle = self.vfs.create(&self.index_file, true)?;
        let mut new_data = Vec::with_capacity(self.len() * INDEX_ENTRY_SIZE);
        for r in 0..self.len() {
            let rev = Revision(r as BaseRevision);
            let entry = self.index.entry_binary(rev);
            if r == 0 {
                new_data.extend(header.header_bytes);
            }
            new_data.extend(entry);
        }
        new_index_handle
            .write_all(&new_data)
            .when_writing_file(&self.index_file)?;
        // Replace the index with a new one because the buffer contains inline
        // data
        self.index = Index::new(DynBytes::new(Box::new(new_data)), header)?;
        self.inline = false;

        self.segment_file = RandomAccessFile::new(
            dyn_clone::clone_box(&*self.vfs),
            self.data_file.to_owned(),
        );
        if existing_handles {
            // Switched from inline to conventional, reopen the index
            let mut new_data_handle = Some(FileHandle::from_file(
                new_data_file_handle,
                dyn_clone::clone_box(&*self.vfs),
                &self.data_file,
            ));
            self.writing_handles = Some(WriteHandles {
                index_handle: self.index_write_handle()?,
                data_handle: if let Some(d) = new_data_handle.as_mut() {
                    Some(d.try_clone()?)
                } else {
                    None
                },
            });
            *self.segment_file.writing_handle.get_or_default().borrow_mut() =
                new_data_handle;
        }

        Ok(self.index_file.to_owned())
    }

    /// Write a new entry to this revlog.
    /// - `entry` is the index bytes
    /// - `header_and_data` is the compression header and the revision data
    /// - `offset` is the position in the data file to write to
    /// - `index_end` is the overwritten position in the index in revlog-v2,
    ///   since the format may allow a rewrite of garbage data at the end.
    /// - `data_end` is the overwritten position in the data-file in revlog-v2,
    ///   since the format may allow a rewrite of garbage data at the end.
    ///
    /// XXX Why do we have `data_end` *and* `offset`? Same question in Python
    pub fn write_entry(
        &mut self,
        mut transaction: impl Transaction,
        entry: &[u8],
        header_and_data: (&[u8], &[u8]),
        mut offset: usize,
        index_end: Option<u64>,
        data_end: Option<u64>,
    ) -> Result<(u64, Option<u64>), HgError> {
        let current_revision = self.len() - 1;
        let canonical_index_file = self.canonical_index_file();

        let is_inline = self.is_inline();
        let handles = match &mut self.writing_handles {
            None => {
                return Err(HgError::abort(
                    "adding revision outside of the `with_write` context",
                    exit_codes::ABORT,
                    None,
                ));
            }
            Some(handles) => handles,
        };
        let index_handle = &mut handles.index_handle;
        let data_handle = &mut handles.data_handle;
        if let Some(end) = index_end {
            index_handle
                .seek(SeekFrom::Start(end))
                .when_reading_file(&self.index_file)?;
        } else {
            index_handle
                .seek(SeekFrom::End(0))
                .when_reading_file(&self.index_file)?;
        }
        if let Some(data_handle) = data_handle {
            if let Some(end) = data_end {
                data_handle
                    .seek(SeekFrom::Start(end))
                    .when_reading_file(&self.data_file)?;
            } else {
                data_handle
                    .seek(SeekFrom::End(0))
                    .when_reading_file(&self.data_file)?;
            }
        }
        let (header, data) = header_and_data;

        if !is_inline {
            transaction.add(&self.data_file, offset);
            transaction
                .add(&canonical_index_file, current_revision * entry.len());
            let data_handle = data_handle
                .as_mut()
                .expect("data handle should exist when not inline");
            if !header.is_empty() {
                data_handle.write_all(header)?;
            }
            data_handle.write_all(data)?;
            match &mut self.delayed_buffer {
                Some(buf) => {
                    buf.lock()
                        .expect("propagate the panic")
                        .buffer
                        .write_all(entry)
                        .expect("write to delay buffer should succeed");
                }
                None => index_handle.write_all(entry)?,
            }
        } else if self.delayed_buffer.is_some() {
            return Err(HgError::abort(
                "invalid delayed write on inline revlog",
                exit_codes::ABORT,
                None,
            ));
        } else {
            offset += current_revision * entry.len();
            transaction.add(&canonical_index_file, offset);
            index_handle.write_all(entry)?;
            index_handle.write_all(header)?;
            index_handle.write_all(data)?;
        }
        let data_position = match data_handle {
            Some(h) => Some(h.position()?),
            None => None,
        };
        Ok((index_handle.position()?, data_position))
    }

    /// Return the real target index file and not the temporary when diverting
    pub fn canonical_index_file(&self) -> PathBuf {
        self.original_index_file
            .as_ref()
            .map(ToOwned::to_owned)
            .unwrap_or_else(|| self.index_file.to_owned())
    }

    /// Return the path to the diverted index
    fn diverted_index(&self) -> PathBuf {
        self.index_file.with_extension("i.a")
    }

    /// True if we're in a [`Self::with_write`] or [`Self::with_read`] context
    pub fn is_open(&self) -> bool {
        self.segment_file.is_open()
    }

    /// Set this revlog to delay its writes to a buffer
    pub fn delay(&mut self) -> Result<Option<PathBuf>, HgError> {
        assert!(!self.is_open());
        if self.is_inline() {
            return Err(HgError::abort(
                "revlog with delayed write should not be inline",
                exit_codes::ABORT,
                None,
            ));
        }
        if self.delayed_buffer.is_some() || self.original_index_file.is_some() {
            // Delay or divert already happening
            return Ok(None);
        }
        if self.is_empty() {
            self.original_index_file = Some(self.index_file.to_owned());
            self.index_file = self.diverted_index();
            if self.vfs.exists(&self.index_file) {
                self.vfs.unlink(&self.index_file)?;
            }
            Ok(Some(self.index_file.to_owned()))
        } else {
            self.delayed_buffer =
                Some(Arc::new(Mutex::new(DelayedBuffer::default())));
            Ok(None)
        }
    }

    /// Write the pending data (in memory) if any to the diverted index file
    /// (on disk temporary file)
    pub fn write_pending(
        &mut self,
    ) -> Result<(Option<PathBuf>, bool), HgError> {
        assert!(!self.is_open());
        if self.is_inline() {
            return Err(HgError::abort(
                "revlog with delayed write should not be inline",
                exit_codes::ABORT,
                None,
            ));
        }
        if self.original_index_file.is_some() {
            return Ok((None, true));
        }
        let mut any_pending = false;
        let pending_index_file = self.diverted_index();
        if self.vfs.exists(&pending_index_file) {
            self.vfs.unlink(&pending_index_file)?;
        }
        self.vfs.copy(&self.index_file, &pending_index_file)?;
        if let Some(delayed_buffer) = self.delayed_buffer.take() {
            let mut index_file_handle =
                self.vfs.open_write(&pending_index_file)?;
            index_file_handle
                .seek(SeekFrom::End(0))
                .when_writing_file(&pending_index_file)?;
            let delayed_data =
                &delayed_buffer.lock().expect("propagate the panic").buffer;
            index_file_handle
                .write_all(delayed_data)
                .when_writing_file(&pending_index_file)?;
            any_pending = true;
        }
        self.original_index_file = Some(self.index_file.to_owned());
        self.index_file = pending_index_file;
        Ok((Some(self.index_file.to_owned()), any_pending))
    }

    /// Overwrite the canonical file with the diverted file, or write out the
    /// delayed buffer.
    /// Returns an error if the revlog is neither diverted nor delayed.
    pub fn finalize_pending(&mut self) -> Result<PathBuf, HgError> {
        assert!(!self.is_open());
        if self.is_inline() {
            return Err(HgError::abort(
                "revlog with delayed write should not be inline",
                exit_codes::ABORT,
                None,
            ));
        }
        match (self.delayed_buffer.as_ref(), self.original_index_file.as_ref())
        {
            (None, None) => {
                return Err(HgError::abort(
                    "neither delay nor divert found on this revlog",
                    exit_codes::ABORT,
                    None,
                ));
            }
            (Some(delay), None) => {
                let mut index_file_handle =
                    self.vfs.open_write(&self.index_file)?;
                index_file_handle
                    .seek(SeekFrom::End(0))
                    .when_writing_file(&self.index_file)?;
                index_file_handle
                    .write_all(
                        &delay.lock().expect("propagate the panic").buffer,
                    )
                    .when_writing_file(&self.index_file)?;
                self.delayed_buffer = None;
            }
            (None, Some(divert)) => {
                if self.vfs.exists(&self.index_file) {
                    self.vfs.rename(&self.index_file, divert, true)?;
                }
                divert.clone_into(&mut self.index_file);
                self.original_index_file = None;
            }
            (Some(_), Some(_)) => unreachable!(
                "{} is in an inconsistent state of both delay and divert",
                self.canonical_index_file().display(),
            ),
        }
        Ok(self.canonical_index_file())
    }

    /// `pub` only for `hg-pyo3`. This is made a different method than
    /// [`Revlog::index`] in case there is a different invariant that pops up
    /// later.
    #[doc(hidden)]
    pub fn shared_index(&self) -> &Index {
        &self.index
    }

    /// Whether we can ignore censored revisions **in filelogs only**
    ///
    /// # Panics
    ///
    /// Panics if [`Self::revlog_type`] != [`RevlogType::Filelog`]
    pub fn ignore_filelog_censored_revisions(&self) -> bool {
        assert!(self.revlog_type == RevlogType::Filelog);
        self.feature_config.ignore_filelog_censored_revisions
    }

    /// Finds the unique [`Revision`] whose [`Node`] starts with the given
    /// binary prefix.
    /// If no [`Revision`] matches the given prefix, Ok(None) is returned.
    pub fn rev_from_node_prefix(
        &self,
        node_prefix: NodePrefix,
    ) -> Result<Option<Revision>, RevlogError> {
        self.nodemap
            .rev_from_node_prefix(&self.index, node_prefix)
            .map_err(|err| nodemap_error_to_revlog_error(err, node_prefix))
    }

    /// Returns the shortest length in bytes to uniquely identify this [`Node`].
    /// If no [`Revision`] matches the given node, `Ok(None)`` is returned.
    pub fn unique_prefix_len_node(
        &self,
        node: super::Node,
    ) -> Result<Option<usize>, RevlogError> {
        self.nodemap
            .unique_prefix_len_node(&self.index, &node)
            .map_err(|err| nodemap_error_to_revlog_error(err, node.into()))
    }

    /// `pub` only for `hg-pyo3`
    /// If `node_tree_opt` is `None`, this creates an empty in-memory nodemap.
    /// If it's `Some`, it creates a persistent nodemap.
    #[doc(hidden)]
    pub fn nodemap_set(
        &mut self,
        node_tree_opt: Option<NodeTree>,
        index_file: PathBuf,
    ) {
        self.nodemap =
            RevlogNodeMap::from_nodetree_option(node_tree_opt, index_file)
    }

    /// `pub` only for `hg-pyo3`
    #[doc(hidden)]
    pub fn nodemap_invalidate(&mut self) -> Result<(), NodeMapError> {
        self.nodemap.invalidate(&self.index)
    }

    /// `pub` only for `hg-pyo3`
    #[doc(hidden)]
    pub fn nodemap_incremental_data(&mut self) -> (usize, Vec<u8>) {
        self.nodemap.incremental_data()
    }

    /// `pub` only for `hg-pyo3`
    /// Appends this new node to the in-memory index and its nodemap. This is
    /// still needed because some places directly call the index instead of
    /// going through the [`InnerRevlog`], and that would need a separate
    /// cleanup.
    #[doc(hidden)]
    pub fn index_append(
        &mut self,
        params: RevisionDataParams,
    ) -> Result<(), RevlogError> {
        let node = Node::from(params.node_id);
        let rev =
            Revision(self.index.len().try_into().expect("revision too large"));
        self.index.append(params)?;
        self.nodemap
            .insert(&self.index, &node, rev)
            .map_err(|err| nodemap_error_to_revlog_error(err, node.into()))
    }
}

fn nodemap_error_to_revlog_error(
    err: NodeMapError,
    node_prefix: NodePrefix,
) -> RevlogError {
    // Pretty awful but no worse than what we had before. This
    // is being cleaned up in a separate effort for all errors, so we keep it
    // in a self-contained function
    match err {
        NodeMapError::MultipleResults => {
            RevlogError::AmbiguousPrefix(format!("{:x}", node_prefix))
        }
        NodeMapError::RevisionNotInIndex(rev) => {
            RevlogError::InvalidRevision(rev.to_string())
        }
    }
}

/// Encapsulates the state of a revlog's nodemap
enum RevlogNodeMapState {
    /// Non-persistent nodemap, lazily constructed in-memory
    InMemory {
        /// How many lookups have failed
        misses: AtomicUsize,
        /// The in-memory tree
        tree: NodeTree,
        /// The smallest revision number from the index we've cached. This is
        /// useful because (after a few misses) we lazily fill the nodemap from
        /// the end, so every subsequent query would start over from the tip if
        /// we didn't remember this.
        smallest_cached_rev: Option<Revision>,
    },
    /// Nodemap stored on disk in an append-mostly format
    Persistent(NodeTree),
}

/// The nodemap for a given revlog index. It only makes sense to use in the
/// context of a single [`InnerRevlog`].
struct RevlogNodeMap {
    /// Holds the state of the nodemap in a thread-safe manner. Most access
    /// patterns are reads, so we optimize for it.
    state: RwLock<RevlogNodeMapState>,
    /// The canonical index file for the target revlog, for debugging.
    index_file: PathBuf,
}

impl std::fmt::Debug for RevlogNodeMap {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RevlogNodeMap")
            .field("index_file", &self.index_file.display())
            .finish()
    }
}

impl RevlogNodeMap {
    /// Main insertion method, see [`NodeTree::insert`].
    pub fn insert(
        &self,
        idx: &impl RevlogIndex,
        node: &Node,
        rev: Revision,
    ) -> Result<(), NodeMapError> {
        let mut state = self.state.write().expect("propagate the panic");
        let tree = match state.deref_mut() {
            RevlogNodeMapState::InMemory {
                tree,
                // No need to adjust either of those
                misses: _,
                smallest_cached_rev: _,
            } => tree,
            RevlogNodeMapState::Persistent(tree) => tree,
        };
        tree.insert(idx, node, rev)
    }

    /// Find the unique [`Revision`] whose [`Node`] starts with the given
    /// binary prefix. The `idx` must be the same one for all invocations
    /// If no [`Revision`] matches the given prefix, Ok(None) is returned.
    fn rev_from_node_prefix(
        &self,
        idx: &impl RevlogIndex,
        node_prefix: NodePrefix,
    ) -> Result<Option<Revision>, NodeMapError> {
        if node_prefix == NULL_NODE {
            // This ensures we don't count this trivial case as a query
            return Ok(Some(NULL_REVISION));
        }

        // First check if we have it in cache
        let (prev_misses, partial_lookup) =
            match &*self.state.read().expect("propagate the panic") {
                RevlogNodeMapState::Persistent(node_tree) => {
                    return node_tree.find_bin(idx, node_prefix);
                }
                RevlogNodeMapState::InMemory {
                    misses,
                    tree,
                    smallest_cached_rev: _,
                } => {
                    let partial_lookup = tree.find_bin(idx, node_prefix)?;
                    if node_prefix.nybbles_len() == NULL_NODE.nybbles_len()
                        && let Some(rev) = partial_lookup
                    {
                        // In-memory cache hit of a full node
                        return Ok(Some(rev));
                    }
                    // In-memory cache miss, update the counter.
                    let prev_misses = misses.fetch_add(1, Ordering::Relaxed);
                    // The nodemap is not fully populated, so we can't give
                    // back a prefix answer without scanning the full index.
                    (prev_misses, partial_lookup)
                }
            };

        // Cache miss: the tree is lazily built for performance reason, so look
        // for a match in the index
        if prev_misses <= 3 {
            // Don't cache revisions we visit yet
            let noop_visit = |_, _| {};

            let opt =
                idx.rev_from_prefix(node_prefix, noop_visit, None, None)?;
            if let Some((node, rev)) = opt {
                // Only cache the exact revision we've asked for
                self.insert(idx, &node, rev)?;
            }
            return Ok(opt.map(|(_, rev)| rev));
        }

        // This revlog is getting queried often: cache every rev we visit
        let mut state = self.state.write().expect("propagate the panic");
        match state.deref_mut() {
            RevlogNodeMapState::Persistent(_) => {
                unreachable!("in a partial state")
            }
            RevlogNodeMapState::InMemory {
                misses: _,
                tree,
                smallest_cached_rev,
            } => {
                let start_rev = *smallest_cached_rev;
                let visit = |node, rev| {
                    tree.insert(idx, &node, rev).expect("rev must be valid");
                    // remember where we stopped to not insert top-most
                    // revisions again
                    *smallest_cached_rev = Some(rev);
                };
                let node_rev_pair = idx.rev_from_prefix(
                    node_prefix,
                    visit,
                    start_rev,
                    partial_lookup,
                )?;
                match node_rev_pair {
                    Some((_node, revision)) => Ok(Some(revision)),
                    None => Ok(None),
                }
            }
        }
    }

    /// Empty the nodemap and return a pair of (`changed`, `new_data`), where
    /// `changed` is the number of bytes from the readonly part that have been
    /// masked by the new data (i.e. data added after what was on disk at load
    /// time).
    pub fn incremental_data(&self) -> (usize, Vec<u8>) {
        let mut state = self.state.write().expect("propagate the panic");
        let tree = match state.deref_mut() {
            RevlogNodeMapState::InMemory {
                misses,
                tree,
                smallest_cached_rev,
            } => {
                *misses = 0.into();
                *smallest_cached_rev = None;
                tree
            }
            RevlogNodeMapState::Persistent(tree) => tree,
        };
        let tree = std::mem::take(tree);
        let masked_blocks = tree.masked_readonly_blocks();
        let (_, data) = tree.into_readonly_and_added_bytes();
        let changed =
            masked_blocks * std::mem::size_of::<super::nodemap::Block>();
        (changed, data)
    }

    /// Empty the nodemap and if it's persistent, reload it from scratch.
    pub fn invalidate(
        &self,
        idx: &impl RevlogIndex,
    ) -> Result<(), NodeMapError> {
        let mut state = self.state.write().expect("propagate the panic");
        match state.deref_mut() {
            RevlogNodeMapState::InMemory {
                misses,
                tree,
                smallest_cached_rev,
            } => {
                *misses = 0.into();
                *smallest_cached_rev = None;
                // Don't reload if it's in-memory, we don't know future access
                // patterns.
                tree.invalidate_all();
                Ok(())
            }
            RevlogNodeMapState::Persistent(tree) => {
                tree.invalidate_all();
                tree.catch_up_to_index(idx, NULL_REVISION)
            }
        }
    }

    /// Internal constructor.
    ///
    /// The [`NodeTree`] must be fully populated, or there will be false
    /// negatives.
    fn from_nodetree_option(
        node_tree_opt: Option<NodeTree>,
        index_file: PathBuf,
    ) -> Self {
        let state = match node_tree_opt {
            Some(node_tree) => RevlogNodeMapState::Persistent(node_tree),
            None => RevlogNodeMapState::InMemory {
                misses: 0.into(),
                tree: Default::default(),
                smallest_cached_rev: None,
            },
        };
        Self { index_file, state: RwLock::new(state) }
    }
}

impl NodeMap for RevlogNodeMap {
    fn find_bin(
        &self,
        idx: &impl RevlogIndex,
        prefix: NodePrefix,
    ) -> Result<Option<Revision>, NodeMapError> {
        self.rev_from_node_prefix(idx, prefix)
    }

    fn unique_prefix_len_bin(
        &self,
        idx: &impl RevlogIndex,
        node_prefix: NodePrefix,
    ) -> Result<Option<usize>, NodeMapError> {
        let mut state = self.state.write().expect("propagate the panic");
        let state = state.deref_mut();
        match state {
            RevlogNodeMapState::InMemory {
                misses: _,
                tree,
                smallest_cached_rev,
            } => {
                // We need to fully populate the tree to answer this question
                tree.catch_up_to_index(idx, NULL_REVISION)?;
                *smallest_cached_rev = Some(NULL_REVISION);
                tree.unique_prefix_len_bin(idx, node_prefix)
            }
            RevlogNodeMapState::Persistent(tree) => {
                // The persistent nodemap should have been kept up to date
                tree.unique_prefix_len_bin(idx, node_prefix)
            }
        }
    }
}

/// Given two delta targeting the same base, find the affected window
///
/// This return the start and end offset of section in "base" affected by a
/// change in any of the two deltas. Assume that at least one of the delta is
/// non-empty.
pub(super) fn affected_range<'a, P>(
    left: &super::patch::Delta<'a, P>,
    right: &super::patch::Delta<'a, P>,
) -> Option<(u32, u32)>
where
    P: DeltaPiece<'a>,
{
    match (&left.chunks[..], &right.chunks[..]) {
        ([], []) => None, // both delta chain cancelled themself out eventually
        ([], chain) => Some((chain[0].start(), chain[chain.len() - 1].end())),
        (chain, []) => Some((chain[0].start(), chain[chain.len() - 1].end())),
        (old_chain, new_chain) => {
            let start = old_chain[0].start().min(new_chain[0].start());
            let end = old_chain[old_chain.len() - 1]
                .end()
                .max(new_chain[new_chain.len() - 1].end());
            Some((start, end))
        }
    }
}

type UncompressedChunkCache =
    RwLock<LruMap<Revision, RawData, ByTotalChunksSize>>;

type ForeignBytes = Arc<dyn Deref<Target = [u8]> + Send + Sync>;

#[derive(Clone)]
enum CachedBytes {
    Foreign(ForeignBytes),
    Native(RawData),
}

impl std::ops::Deref for CachedBytes {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        match self {
            Self::Foreign(data) => data,
            Self::Native(data) => data,
        }
    }
}

/// The revision and data for the last revision we've seen. Speeds up
/// a lot of sequential operations of the revlog.
///
/// The data is not just bytes since it can come from Python and we want to
/// avoid copies if possible.
#[derive(Clone)]
pub struct SingleRevisionCache {
    pub rev: Revision,
    data: CachedBytes,
}

impl SingleRevisionCache {
    pub(super) fn as_delta_base(&self) -> (Revision, &[u8]) {
        match &self.data {
            CachedBytes::Foreign(data) => (self.rev, data.as_ref()),
            CachedBytes::Native(data) => (self.rev, data.as_ref()),
        }
    }

    /// return a RawData if available
    pub(super) fn as_data(&self) -> RawData {
        match &self.data {
            CachedBytes::Foreign(data) => {
                let data: &[u8] = data;
                RawData::from(data)
            }
            CachedBytes::Native(data) => data.clone(),
        }
    }
}

impl std::ops::Deref for SingleRevisionCache {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        &self.data
    }
}

/// A way of progressively filling a buffer with revision data, then return
/// that buffer. Used to abstract away Python-allocated code to reduce copying
/// for performance reasons.
pub trait RevisionBuffer {
    /// The owned buffer type to return
    type Target;
    /// Copies the slice into the buffer
    fn extend_from_slice(&mut self, slice: &[u8]);
    /// Returns the now finished owned buffer
    fn finish(self) -> Self::Target;
}

/// A simple vec-based buffer. This is uselessly complicated for the pure Rust
/// case, but it's the price to pay for Python compatibility.
#[derive(Debug)]
pub(super) struct CoreRevisionBuffer {
    buf: Vec<u8>,
}

impl CoreRevisionBuffer {
    pub fn new() -> Self {
        Self { buf: vec![] }
    }

    #[inline]
    pub fn resize(&mut self, size: usize) {
        self.buf.reserve_exact(size - self.buf.capacity());
    }
}

impl RevisionBuffer for CoreRevisionBuffer {
    type Target = Vec<u8>;

    #[inline]
    fn extend_from_slice(&mut self, slice: &[u8]) {
        self.buf.extend_from_slice(slice);
    }

    #[inline]
    fn finish(self) -> Self::Target {
        self.buf
    }
}

/// Calculate the hash of a revision given its data and its parents.
pub fn hash(
    data: &[u8],
    p1_hash: &[u8],
    p2_hash: &[u8],
) -> [u8; NODE_BYTES_LENGTH] {
    let mut hasher = Sha1::new();
    let (a, b) = (p1_hash, p2_hash);
    if a > b {
        hasher.update(b);
        hasher.update(a);
    } else {
        hasher.update(a);
        hasher.update(b);
    }
    hasher.update(data);
    *hasher.finalize().as_ref()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NODE_0: &[u8; 40] = b"abcdabcdabcdabcdabcdabcdabcdabcdabcdabcd";
    //                                                 different here ^^
    const NODE_1: &[u8; 40] = b"abcdabcdabcdabcdabcdabcdabcdabcdabcdabee";

    struct FakeIndex([Node; 2]);

    impl FakeIndex {
        fn new() -> Self {
            Self([
                Node::from_hex(NODE_0).unwrap(),
                Node::from_hex(NODE_1).unwrap(),
            ])
        }
    }

    impl RevlogIndex for FakeIndex {
        fn len(&self) -> usize {
            2
        }

        fn node(&self, rev: Revision) -> &Node {
            &self.0[rev.0 as usize]
        }
    }

    /// Tests that the [`RevlogNodeMap`] behaves correctly when partially built
    /// in-memory
    #[test]
    fn test_revlog_nodemap_basic() {
        let idx = FakeIndex::new();
        let nodemap = RevlogNodeMap::from_nodetree_option(None, PathBuf::new());
        // Test exact match first, to populate the nodemap and make sure...
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(NODE_0).unwrap()
            ),
            Ok(Some(Revision(0)))
        );
        // ... no partial match from an in-memory index without scanning the
        // whole thing.
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(b"abcd").unwrap()
            ),
            Err(NodeMapError::MultipleResults)
        );
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(
                    // unambiguous prefix (removed the last byte)
                    b"abcdabcdabcdabcdabcdabcdabcdabcdabcdabc"
                )
                .unwrap()
            ),
            Ok(Some(Revision(0)))
        );
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(b"abcde").unwrap()
            ),
            Ok(None)
        );
        // Test other exact match
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(NODE_1).unwrap()
            ),
            Ok(Some(Revision(1)))
        );
        // Test full node not matching
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(
                    b"abcdabcdabcdabcdabcdabcdabcdabcdabcdabaa"
                )
                .unwrap()
            ),
            Ok(None)
        );
    }

    /// Test that we don't confuse previous full matches with an unambiguous
    /// prefix
    #[test]
    fn test_revlog_nodemap_prefix() {
        let idx = FakeIndex::new();
        let nodemap = RevlogNodeMap::from_nodetree_option(None, PathBuf::new());
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(NODE_0).unwrap()
            ),
            Ok(Some(Revision(0)))
        );
        assert_eq!(
            nodemap.rev_from_node_prefix(
                &idx,
                NodePrefix::from_hex(
                    // Missing the last character, but still unambiguous
                    b"abcdabcdabcdabcdabcdabcdabcdabcdabcdabe"
                )
                .unwrap()
            ),
            Ok(Some(Revision(1)))
        );
    }
}
