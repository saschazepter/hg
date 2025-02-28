//! A layer of lower-level revlog functionality to encapsulate most of the
//! IO work and expensive operations.
use std::{
    borrow::Cow,
    io::{ErrorKind, Seek, SeekFrom, Write},
    ops::Deref,
    path::PathBuf,
    sync::{Arc, Mutex, RwLock},
};

use schnellru::{ByMemoryUsage, LruMap};
use sha1::{Digest, Sha1};

use crate::{
    errors::{HgError, IoResultExt},
    exit_codes,
    transaction::Transaction,
    vfs::Vfs,
};

use super::{
    compression::{
        uncompressed_zstd_data, CompressionConfig, Compressor, NoneCompressor,
        ZlibCompressor, ZstdCompressor, ZLIB_BYTE, ZSTD_BYTE,
    },
    file_io::{DelayedBuffer, FileHandle, RandomAccessFile, WriteHandles},
    index::{Index, IndexHeader, INDEX_ENTRY_SIZE},
    node::{NODE_BYTES_LENGTH, NULL_NODE},
    options::{RevlogDataConfig, RevlogDeltaConfig, RevlogFeatureConfig},
    BaseRevision, Node, Revision, RevlogEntry, RevlogError, RevlogIndex,
    UncheckedRevision, NULL_REVISION, NULL_REVLOG_ENTRY_FLAGS,
};

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
    #[allow(unused)]
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
    pub last_revision_cache: Mutex<Option<SingleRevisionCache>>,
    /// The [`Compressor`] that this revlog uses by default to compress data.
    /// This does not mean that this revlog uses this compressor for reading
    /// data, as different revisions may have different compression modes.
    compressor: Mutex<Box<dyn Compressor>>,
}

impl InnerRevlog {
    pub fn new(
        vfs: Box<dyn Vfs>,
        index: Index,
        index_file: PathBuf,
        data_file: PathBuf,
        data_config: RevlogDataConfig,
        delta_config: RevlogDeltaConfig,
        feature_config: RevlogFeatureConfig,
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
                |_factor| RwLock::new(LruMap::with_memory_budget(65536)),
            );

        let inline = index.is_inline();
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

    /// Return an entry for the null revision
    pub fn make_null_entry(&self) -> RevlogEntry {
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
    ) -> Result<RevlogEntry, RevlogError> {
        if rev == NULL_REVISION {
            return Ok(self.make_null_entry());
        }
        let index_entry = self
            .index
            .get_entry(rev)
            .ok_or_else(|| RevlogError::InvalidRevision(rev.to_string()))?;
        let p1 =
            self.index.check_revision(index_entry.p1()).ok_or_else(|| {
                RevlogError::corrupted(format!(
                    "p1 for rev {} is invalid",
                    rev
                ))
            })?;
        let p2 =
            self.index.check_revision(index_entry.p2()).ok_or_else(|| {
                RevlogError::corrupted(format!(
                    "p2 for rev {} is invalid",
                    rev
                ))
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
    ) -> Result<RevlogEntry, RevlogError> {
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
        self.index.start(
            rev,
            &self
                .index
                .get_entry(rev)
                .unwrap_or_else(|| self.index.make_null_entry()),
        )
    }

    /// The length of the data chunk for this revision
    #[inline(always)]
    pub fn data_compressed_length(&self, rev: Revision) -> usize {
        self.index
            .get_entry(rev)
            .unwrap_or_else(|| self.index.make_null_entry())
            .compressed_len() as usize
    }

    /// The end of the data chunk for this revision
    #[inline(always)]
    pub fn data_end(&self, rev: Revision) -> usize {
        self.data_start(rev) + self.data_compressed_length(rev)
    }

    /// Return the delta parent of the given revision
    pub fn delta_parent(&self, rev: Revision) -> Revision {
        let base = self
            .index
            .get_entry(rev)
            .unwrap()
            .base_revision_or_base_of_delta_chain();
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
    ) -> Result<Cow<[u8]>, RevlogError> {
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
            ZSTD_BYTE => {
                Ok(ZstdCompressor::new(0, 0).decompress(data)?.into())
            }
            b'\0' => Ok(data.into()),
            b'u' => Ok((&data[1..]).into()),
            other => Err(HgError::UnsupportedFeature(format!(
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
            let start_entry = self
                .index
                .get_entry(start_rev)
                .expect("null revision segment");
            self.index.start(start_rev, &start_entry)
        };
        let end_entry = self
            .index
            .get_entry(end_rev)
            .expect("null revision segment");
        let end = self.index.start(end_rev, &end_entry)
            + self.data_compressed_length(end_rev);

        let length = end - start;

        // XXX should we use mmap instead of doing this for platforms that
        // support madvise/populate?
        Ok((start, self.segment_file.read_chunk(start, length)?))
    }

    /// Return the uncompressed raw data for `rev`
    pub fn chunk_for_rev(&self, rev: Revision) -> Result<Arc<[u8]>, HgError> {
        if let Some(Ok(mut cache)) = self
            .uncompressed_chunk_cache
            .as_ref()
            .map(|c| c.try_write())
        {
            if let Some(chunk) = cache.get(&rev) {
                return Ok(chunk.clone());
            }
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
        let uncompressed: Arc<[u8]> = Arc::from(uncompressed.into_owned());
        if let Some(Ok(mut cache)) = self
            .uncompressed_chunk_cache
            .as_ref()
            .map(|c| c.try_write())
        {
            cache.insert(rev, uncompressed.clone());
        }
        Ok(uncompressed)
    }

    /// Execute `func` within a read context for the data file, meaning that
    /// the read handle will be taken and discarded after the operation.
    pub fn with_read<R>(
        &self,
        func: impl FnOnce() -> Result<R, RevlogError>,
    ) -> Result<R, RevlogError> {
        self.enter_reading_context()?;
        let res = func();
        self.exit_reading_context();
        res.map_err(Into::into)
    }

    /// `pub` only for use in hg-cpython
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

    /// `pub` only for use in hg-cpython
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
        let mut mutex_guard = self
            .last_revision_cache
            .lock()
            .expect("lock should not be held");
        let cached_rev = if let Some((_node, rev, data)) = &*mutex_guard {
            Some((*rev, data.deref().as_ref()))
        } else {
            None
        };
        if let (Some(size), Some(Ok(mut cache))) = (
            raw_size,
            self.uncompressed_chunk_cache
                .as_ref()
                .map(|c| c.try_write()),
        ) {
            // Dynamically update the uncompressed_chunk_cache size to the
            // largest revision we've seen in this revlog.
            // Do it *before* restoration in case the current revision
            // is the largest.
            let factor = self
                .data_config
                .uncompressed_cache_factor
                .expect("cache should not exist without factor");
            let candidate_size = (size as f64 * factor) as usize;
            let limiter_mut = cache.limiter_mut();
            if candidate_size > limiter_mut.max_memory_usage() {
                std::mem::swap(
                    limiter_mut,
                    &mut ByMemoryUsage::new(candidate_size),
                );
            }
        }
        entry.rawdata(cached_rev, get_buffer)?;
        // drop cache to save memory, the caller is expected to update
        // the revision cache after validating the text
        mutex_guard.take();
        Ok(())
    }

    /// Only `pub` for `hg-cpython`.
    /// Obtain decompressed raw data for the specified revisions that are
    /// assumed to be in ascending order.
    ///
    /// Returns a list with decompressed data for each requested revision.
    #[doc(hidden)]
    pub fn chunks(
        &self,
        revs: Vec<Revision>,
        target_size: Option<u64>,
    ) -> Result<Vec<Arc<[u8]>>, RevlogError> {
        if revs.is_empty() {
            return Ok(vec![]);
        }
        let mut fetched_revs = vec![];
        let mut chunks = Vec::with_capacity(revs.len());

        match self.uncompressed_chunk_cache.as_ref() {
            Some(cache) => {
                if let Ok(mut cache) = cache.try_write() {
                    for rev in revs.iter() {
                        match cache.get(rev) {
                            Some(hit) => chunks.push((*rev, hit.to_owned())),
                            None => fetched_revs.push(*rev),
                        }
                    }
                } else {
                    fetched_revs = revs
                }
            }
            None => fetched_revs = revs,
        }

        let already_cached = chunks.len();

        let sliced_chunks = if fetched_revs.is_empty() {
            vec![]
        } else if !self.data_config.with_sparse_read || self.is_inline() {
            vec![fetched_revs]
        } else {
            self.slice_chunk(&fetched_revs, target_size)?
        };

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
                    let bytes = &data[chunk_start - offset..][..chunk_length];
                    let chunk = if !bytes.is_empty() && bytes[0] == ZSTD_BYTE {
                        // If we're using `zstd`, we want to try a more
                        // specialized decompression
                        let entry = self.index.get_entry(*rev).unwrap();
                        let is_delta = entry
                            .base_revision_or_base_of_delta_chain()
                            != (*rev).into();
                        let uncompressed = uncompressed_zstd_data(
                            bytes,
                            is_delta,
                            entry.uncompressed_len(),
                        )?;
                        Cow::Owned(uncompressed)
                    } else {
                        // Otherwise just fallback to generic decompression.
                        self.decompress(bytes)?
                    };

                    chunks.push((*rev, chunk.into()));
                }
            }
            Ok(())
        })?;

        if let Some(Ok(mut cache)) = self
            .uncompressed_chunk_cache
            .as_ref()
            .map(|c| c.try_write())
        {
            for (rev, chunk) in chunks.iter().skip(already_cached) {
                cache.insert(*rev, chunk.clone());
            }
        }
        // Use stable sort here since it's *mostly* sorted
        chunks.sort_by(|a, b| a.0.cmp(&b.0));
        Ok(chunks.into_iter().map(|(_r, chunk)| chunk).collect())
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
    pub fn slice_chunk(
        &self,
        revs: &[Revision],
        target_size: Option<u64>,
    ) -> Result<Vec<Vec<Revision>>, RevlogError> {
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
                self.slice_chunk_to_size(&chunk, target_size)?
                    .into_iter()
                    .map(ToOwned::to_owned),
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

        let nothing_to_do = target_size
            .map(|size| full_span <= size as usize)
            .unwrap_or(true);

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
            let chunk =
                self.trim_chunk(revs, start_rev_idx, Some(end_rev_idx));
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
        let e1 = self.index.get_entry(p1);
        let h1 = match e1 {
            Some(ref entry) => entry.hash(),
            None => &NULL_NODE,
        };
        let e2 = self.index.get_entry(p2);
        let h2 = match e2 {
            Some(ref entry) => entry.hash(),
            None => &NULL_NODE,
        };

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
        self.enter_writing_context(data_end, transaction)
            .inspect_err(|_| {
                self.exit_writing_context();
            })?;
        let res = func();
        self.exit_writing_context();
        Ok(res)
    }

    /// `pub` only for use in hg-cpython
    #[doc(hidden)]
    pub fn exit_writing_context(&mut self) {
        self.writing_handles.take();
        self.segment_file.writing_handle.get().map(|h| h.take());
        self.segment_file.reading_handle.get().map(|h| h.take());
    }

    /// `pub` only for use in hg-cpython
    #[doc(hidden)]
    pub fn python_writing_handles(&self) -> Option<&WriteHandles> {
        self.writing_handles.as_ref()
    }

    /// `pub` only for use in hg-cpython
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
        let data_handle = if !self.is_inline() {
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
                Err(e) => match e {
                    HgError::IoError { error, context } => {
                        if error.kind() != ErrorKind::NotFound {
                            return Err(HgError::IoError { error, context });
                        }
                        self.vfs.create(&self.data_file, true)?
                    }
                    e => return Err(e),
                },
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
            index_handle: index_handle.clone(),
            data_handle: data_handle.clone(),
        });
        *self
            .segment_file
            .reading_handle
            .get_or_default()
            .borrow_mut() = if self.is_inline() {
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
                Ok(
                    if let Some(delayed_buffer) = self.delayed_buffer.as_ref()
                    {
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
                    },
                )
            }
            Err(e) => match e {
                HgError::IoError { error, context } => {
                    if error.kind() != ErrorKind::NotFound {
                        return Err(HgError::IoError { error, context });
                    };
                    if let Some(delayed_buffer) = self.delayed_buffer.as_ref()
                    {
                        FileHandle::new_delayed(
                            dyn_clone::clone_box(&*self.vfs),
                            &self.index_file,
                            true,
                            delayed_buffer.clone(),
                        )
                    } else {
                        FileHandle::new(
                            dyn_clone::clone_box(&*self.vfs),
                            &self.index_file,
                            true,
                            true,
                        )
                    }
                }
                e => Err(e),
            },
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
        new_data_file_handle
            .set_len(0)
            .when_writing_file(&self.data_file)?;

        self.with_read(|| -> Result<(), RevlogError> {
            for r in 0..self.index.len() {
                let rev = Revision(r as BaseRevision);
                let rev_segment = self.get_segment_for_revs(rev, rev)?.1;
                new_data_file_handle
                    .write_all(&rev_segment)
                    .when_writing_file(&self.data_file)?;
            }
            new_data_file_handle
                .flush()
                .when_writing_file(&self.data_file)?;
            Ok(())
        })?;

        if let Some(index_path) = new_index_file_path {
            self.index_file = index_path
        }

        let mut new_index_handle = self.vfs.create(&self.index_file, true)?;
        let mut new_data = Vec::with_capacity(self.len() * INDEX_ENTRY_SIZE);
        for r in 0..self.len() {
            let rev = Revision(r as BaseRevision);
            let entry = self.index.entry_binary(rev).unwrap_or_else(|| {
                panic!(
                    "entry {} should exist in {}",
                    r,
                    self.index_file.display()
                )
            });
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
        self.index = Index::new(Box::new(new_data), header)?;
        self.inline = false;

        self.segment_file = RandomAccessFile::new(
            dyn_clone::clone_box(&*self.vfs),
            self.data_file.to_owned(),
        );
        if existing_handles {
            // Switched from inline to conventional, reopen the index
            let new_data_handle = Some(FileHandle::from_file(
                new_data_file_handle,
                dyn_clone::clone_box(&*self.vfs),
                &self.data_file,
            ));
            self.writing_handles = Some(WriteHandles {
                index_handle: self.index_write_handle()?,
                data_handle: new_data_handle.clone(),
            });
            *self
                .segment_file
                .writing_handle
                .get_or_default()
                .borrow_mut() = new_data_handle;
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
        if self.delayed_buffer.is_some() || self.original_index_file.is_some()
        {
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
        match (
            self.delayed_buffer.as_ref(),
            self.original_index_file.as_ref(),
        ) {
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

    /// `pub` only for `hg-cpython`. This is made a different method than
    /// [`Revlog::index`] in case there is a different invariant that pops up
    /// later.
    #[doc(hidden)]
    pub fn shared_index(&self) -> &Index {
        &self.index
    }
}

type UncompressedChunkCache =
    RwLock<LruMap<Revision, Arc<[u8]>, ByMemoryUsage>>;

/// The node, revision and data for the last revision we've seen. Speeds up
/// a lot of sequential operations of the revlog.
///
/// The data is not just bytes since it can come from Python and we want to
/// avoid copies if possible.
type SingleRevisionCache =
    (Node, Revision, Box<dyn Deref<Target = [u8]> + Send>);

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
