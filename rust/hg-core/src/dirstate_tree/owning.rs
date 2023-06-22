use crate::{DirstateError, DirstateParents};

use super::dirstate_map::DirstateMap;
use self_cell::self_cell;
use std::ops::Deref;

self_cell!(
    /// Keep a `DirstateMap<'owner>` next to the `owner` buffer that it
    /// borrows.
    pub struct OwningDirstateMap {
        owner: Box<dyn Deref<Target = [u8]> + Send>,
        #[covariant]
        dependent: DirstateMap,
    }
);

impl OwningDirstateMap {
    pub fn new_empty<OnDisk>(on_disk: OnDisk) -> Self
    where
        OnDisk: Deref<Target = [u8]> + Send + 'static,
    {
        let on_disk = Box::new(on_disk);

        OwningDirstateMap::new(on_disk, |bytes| DirstateMap::empty(bytes))
    }

    pub fn new_v1<OnDisk>(
        on_disk: OnDisk,
        identity: Option<u64>,
    ) -> Result<(Self, DirstateParents), DirstateError>
    where
        OnDisk: Deref<Target = [u8]> + Send + 'static,
    {
        let on_disk = Box::new(on_disk);
        let mut parents = DirstateParents::NULL;

        Ok((
            OwningDirstateMap::try_new(on_disk, |bytes| {
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
        identity: Option<u64>,
    ) -> Result<Self, DirstateError>
    where
        OnDisk: Deref<Target = [u8]> + Send + 'static,
    {
        let on_disk = Box::new(on_disk);

        OwningDirstateMap::try_new(on_disk, |bytes| {
            DirstateMap::new_v2(bytes, data_size, metadata, uuid, identity)
        })
    }

    pub fn with_dmap_mut<R>(
        &mut self,
        f: impl FnOnce(&mut DirstateMap) -> R,
    ) -> R {
        self.with_dependent_mut(|_owner, dmap| f(dmap))
    }

    pub fn get_map(&self) -> &DirstateMap {
        self.borrow_dependent()
    }

    pub fn on_disk(&self) -> &[u8] {
        self.borrow_owner()
    }

    pub fn old_uuid(&self) -> Option<&[u8]> {
        self.get_map().old_uuid.as_deref()
    }

    pub fn old_identity(&self) -> Option<u64> {
        self.get_map().identity
    }

    pub fn old_data_size(&self) -> usize {
        self.get_map().old_data_size
    }
}
