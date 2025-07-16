use std::ops::Deref;

/// An owned object that can be borrowed as a byte array,
/// but without the dynamic dispatch overhead involved when
/// accessing the byte array.
use self_cell::self_cell;

/// A byte array representation that supports truncation.
pub trait ByteStoreTrunc: Deref<Target = [u8]> {
    fn truncate(&mut self, new_size: usize);
}

/// Wrapper needed to make the `self_cell!` macro happy.
struct BorrowedBytes<'a> {
    bytes: &'a [u8],
}

self_cell!(
    struct CachedBytes<'w> {
        owner: Box<dyn Deref<Target = [u8]> + Send + Sync + 'w>,
        #[covariant]
        dependent: BorrowedBytes,
    }
);

/// `DynBytes` keeps an owned slice of bytes backed with opaque boxed storage,
///  whose destructor is based on dynamic dispatch.
pub struct DynBytes<'w> {
    // the indirection lets us put a nicer interface on the
    // slightly-ugly thing derived by self_cell
    inner: CachedBytes<'w>,
}

impl DynBytes<'_> {
    pub fn new(store: Box<dyn Deref<Target = [u8]> + Send + Sync>) -> Self {
        Self {
            inner: CachedBytes::new(store, |store| BorrowedBytes {
                bytes: store.deref(),
            }),
        }
    }
}

impl ByteStoreTrunc for DynBytes<'_> {
    fn truncate(&mut self, new_size: usize) {
        self.inner.with_dependent_mut(|_owning, bytes: &mut BorrowedBytes| {
            bytes.bytes = &bytes.bytes[..new_size]
        })
    }
}

impl Deref for DynBytes<'_> {
    type Target = [u8];

    fn deref(&self) -> &Self::Target {
        self.inner.borrow_dependent().bytes
    }
}

impl Default for DynBytes<'_> {
    fn default() -> Self {
        DynBytes::new(Box::<Vec<u8>>::default())
    }
}
