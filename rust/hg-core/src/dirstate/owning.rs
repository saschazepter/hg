use self_cell::self_cell;
use stable_deref_trait::StableDeref;

use super::DirstateError;
use super::dirstate_map::DirstateIdentity;
use super::dirstate_map::DirstateMap;
use crate::DirstateParents;
use crate::segmented_bytes::SegmentedBytes;

self_cell!(
    /// Keep a `DirstateMap<'owner>` next to the `owner` logical buffer that it
    /// borrows.
    pub struct OwningDirstateMap {
        owner: SegmentedBytes,
        #[covariant]
        dependent: DirstateMap,
    }
);

impl OwningDirstateMap {
    pub fn new_empty(identity: Option<DirstateIdentity>) -> Self {
        let on_disk = SegmentedBytes::empty();

        OwningDirstateMap::new(on_disk, |_| {
            let mut empty = DirstateMap::empty();
            empty.identity = identity;
            empty
        })
    }

    pub fn new_v1<OnDisk>(
        on_disk: OnDisk,
        identity: Option<DirstateIdentity>,
    ) -> Result<(Self, DirstateParents), DirstateError>
    where
        OnDisk: StableDeref<Target = [u8]> + Send + Sync + 'static,
    {
        let on_disk = SegmentedBytes::from_single_extent(on_disk);
        let mut parents = DirstateParents::NULL;

        Ok((
            OwningDirstateMap::try_new(on_disk, |bytes| {
                let bytes = bytes.as_slice();
                DirstateMap::new_v1(bytes, identity).map(|(dmap, p)| {
                    parents = p.unwrap_or(DirstateParents::NULL);
                    dmap
                })
            })?,
            parents,
        ))
    }

    pub fn new_v2<OnDisk>(
        on_disk: OnDisk,
        data_size: usize,
        metadata: &[u8],
        uuid: Vec<u8>,
        identity: Option<DirstateIdentity>,
    ) -> Result<Self, DirstateError>
    where
        OnDisk: StableDeref<Target = [u8]> + Send + Sync + 'static,
    {
        let on_disk = SegmentedBytes::from_single_extent(on_disk);

        OwningDirstateMap::try_new(on_disk, |bytes| {
            let bytes = bytes.as_slice();
            DirstateMap::new_v2(bytes, data_size, metadata, uuid, identity)
        })
    }

    pub fn with_dmap_mut<R>(
        &mut self,
        f: impl FnOnce(&mut DirstateMap) -> R,
    ) -> R {
        self.with_dependent_mut(|_owner, dmap| f(dmap))
    }

    pub fn get_map(&self) -> &DirstateMap<'_> {
        self.borrow_dependent()
    }

    pub fn to_vec(&self) -> Vec<u8> {
        self.borrow_owner().to_vec()
    }

    pub fn old_uuid(&self) -> Option<&[u8]> {
        self.get_map().old_uuid.as_deref()
    }

    pub fn old_identity(&self) -> Option<DirstateIdentity> {
        self.get_map().identity
    }

    pub fn old_data_size(&self) -> usize {
        self.get_map().old_data_size
    }
}
