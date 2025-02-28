// Copyright (c) 2019 Raphaël Gomès <rgomes@octobus.net>,
//                    Yuya Nishihara <yuya@tcha.org>
//               2024 Georges Racinet <georges.racinet@cloudcrane.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to
// deal in the Software without restriction, including without limitation the
// rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
// sell copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.

//! Utility to share Rust reference across Python objects.

use pyo3::exceptions::PyRuntimeError;
use pyo3::prelude::*;

use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{
    RwLock, RwLockReadGuard, RwLockWriteGuard, TryLockError, TryLockResult,
};

/// A mutable memory location shareable immutably across Python objects.
///
/// This data structure is meant to be used as a field in a Python class
/// definition.
/// It provides interior mutability in a way that allows it to be immutably
/// referenced by other Python objects defined in Rust than its owner, in
/// a more general form than references to the whole data.
/// These immutable references are stored in the referencing Python objects as
/// [`SharedByPyObject`] fields.
///
/// The primary use case is to implement a Python iterator over a Rust
/// iterator: since a Python object cannot hold a lifetime-bound object,
/// `Iter<'a, T>` cannot be a data field of the Python iterator object.
/// While `&'a T` can be replaced with [`std::sync::Arc`], this is typically
/// not suited for more complex objects that are created from such references
/// and re-expose the lifetime on their types, such as iterators.
/// The [`PyShareableRef::share_immutable()`] and
/// [`SharedByPyObject::map()`] methods provide a way around this issue.
///
/// [`PyShareable`] is [`Sync`]. It works internally with locks and
/// a "generation" counter that keeps track of mutations.
///
/// [`PyShareable`] is merely a data struct to be stored in its
/// owner Python object.
/// Any further operation will be performed through [`PyShareableRef`], which
/// is a lifetime-bound reference to the [`PyShareable`].
///
/// # Example
///
/// ```
/// use pyo3::prelude::*;
/// use pyo3_sharedref::*;
///
/// use pyo3::ffi::c_str;
/// use pyo3::types::PyDictMethods;
/// use pyo3::types::{PyDict, PyTuple};
/// use std::collections::{hash_set::Iter as IterHashSet, HashSet};
/// use pyo3::exceptions::PyRuntimeError;
/// use std::ffi::CStr;
/// use std::vec::Vec;
///
/// #[pyclass(sequence)]
/// struct Set {
///     rust_set: PyShareable<HashSet<i32>>,
/// }
///
/// #[pymethods]
/// impl Set {
///     #[new]
///     fn new(values: &Bound<'_, PyTuple>) -> PyResult<Self> {
///         let as_vec = values.extract::<Vec<i32>>()?;
///         let s: HashSet<_> = as_vec.iter().copied().collect();
///         Ok(Self { rust_set: s.into() })
///     }
///
///     fn __iter__(slf: &Bound<'_, Self>) -> SetIterator {
///         SetIterator::new(slf)
///     }
///
///     fn add(slf: &Bound<'_, Self>, i: i32) -> PyResult<()> {
///         let rust_set = &slf.borrow().rust_set;
///         let shared_ref = unsafe { rust_set.borrow_with_owner(slf) };
///         let mut set_ref = shared_ref.write();
///         set_ref.insert(i);
///         Ok(())
///     }
/// }
///
/// #[pyclass]
/// struct SetIterator {
///     rust_iter: SharedByPyObject<IterHashSet<'static, i32>>,
/// }
///
/// #[pymethods]
/// impl SetIterator {
///     #[new]
///     fn new(s: &Bound<'_, Set>) -> Self {
///         let py = s.py();
///         let rust_set = &s.borrow().rust_set;
///         let iter = unsafe { rust_set.share_map(s, |o| o.iter()) };
///         Self {
///             rust_iter: iter.into(),
///         }
///     }
///
///     fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
///         slf
///     }
///
///     fn __next__(mut slf: PyRefMut<'_, Self>) -> PyResult<Option<i32>> {
///         let py = slf.py();
///         let shared = &mut slf.rust_iter;
///         let mut inner = unsafe { shared.try_borrow_mut(py) }?;
///         Ok(inner.next().copied())
///     }
/// }
///
/// /// a shortcut similar  to `[pyo3::py_run!]`, allowing inspection of PyErr
/// fn py_run(statement: &CStr, locals: &Bound<'_, PyDict>) -> PyResult<()> {
///     locals.py().run(statement, None, Some(locals))
/// }
///
/// # pyo3::prepare_freethreaded_python();
/// Python::with_gil(|py| {
///     let tuple = PyTuple::new(py, vec![2, 1, 2])?;
///     let set = Bound::new(py, Set::new(&tuple)?)?;
///     let iter = Bound::new(py, Set::__iter__(&set))?;
///     let locals = PyDict::new(py);
///     locals.set_item("rust_set", set).unwrap();
///     locals.set_item("rust_iter", iter).unwrap();
///
///     /// iterating on our Rust set just works
///     py_run(
///         c_str!("assert sorted(i for i in rust_iter) == [1, 2]"),
///         &locals,
///     )?;
///
///     /// however, if any mutation occurs on the Rust set, the iterator
///     /// becomes invalid. Attempts to use it raise `RuntimeError`.
///     py_run(c_str!("rust_set.add(3)"), &locals)?;
///     let err = py_run(c_str!("next(rust_iter)"), &locals).unwrap_err();
///
///     let exc_repr = format!("{:?}", err.value(py));
///     assert_eq!(
///         exc_repr,
///         "RuntimeError('Cannot access to shared reference after mutation')"
///     );
/// # Ok::<(), PyErr>(())
/// })
/// # .expect("This example should not return an error");
/// ```
///
/// The borrow rules are enforced dynamically in a similar manner to the
/// Python iterator.
///
/// [`PyShareable`] is merely a data struct to be stored in a Python object.
/// Any further operation will be performed through [PyShareableRef], which is
/// a lifetime-bound reference to the [`PyShareable`].
#[derive(Debug)]
pub struct PyShareable<T: ?Sized> {
    state: PySharedState,
    data: RwLock<T>,
}

impl<T: 'static> PyShareable<T> {
    /// Borrows the shared data and its state, keeping a reference
    /// on the owner Python object.
    ///
    /// # Safety
    ///
    /// The `data` must be owned by the `owner`. Otherwise, calling
    /// `share_immutable()` on the shared ref would create an invalid
    /// reference.
    pub unsafe fn borrow_with_owner<'py>(
        &'py self,
        owner: &'py Bound<'py, PyAny>,
    ) -> PyShareableRef<'py, T> {
        PyShareableRef {
            owner,
            state: &self.state,
            data: &self.data,
        }
    }

    /// Share for other Python objects
    ///
    /// # Safety
    ///
    /// The `data` must be owned by the `owner`. Otherwise, the resulting
    /// [`SharedByPyObject`] would contain an invalid reference.
    pub unsafe fn share<'py>(
        &'py self,
        owner: &'py Bound<'py, PyAny>,
    ) -> SharedByPyObject<&'static T> {
        self.borrow_with_owner(owner).share_immutable()
    }

    /// Share for other Python objects, transforming the inner data
    /// with a closure
    ///
    /// # Safety
    ///
    /// The `data` must be owned by the `owner`. Otherwise, the resulting
    /// [`SharedByPyObject`] would contain an invalid reference.
    pub unsafe fn share_map<'py, U>(
        &'py self,
        owner: &'py Bound<'py, PyAny>,
        f: impl FnOnce(&'static T) -> U,
    ) -> SharedByPyObject<U> {
        self.share(owner).map(owner.py(), f)
    }

    /// # Safety
    ///
    /// The `data` must be owned by the `owner`. Otherwise, the resulting
    /// [`SharedByPyObject`] would contain an invalid reference.
    pub unsafe fn try_share<'py>(
        &'py self,
        owner: &'py Bound<'py, PyAny>,
    ) -> Result<SharedByPyObject<&'static T>, TryShareError> {
        self.borrow_with_owner(owner).try_share_immutable()
    }

    /// # Safety
    ///
    /// The `data` must be owned by the `owner`. Otherwise, the resulting
    /// [`SharedByPyObject`] would contain an invalid reference.
    pub unsafe fn try_share_map<'py, U>(
        &'py self,
        owner: &'py Bound<'py, PyAny>,
        f: impl FnOnce(&'static T) -> U,
    ) -> Result<SharedByPyObject<U>, TryShareError> {
        Ok(self.try_share(owner)?.map(owner.py(), f))
    }
}

impl<T> From<T> for PyShareable<T> {
    fn from(value: T) -> Self {
        Self {
            state: PySharedState::new(),
            data: value.into(),
        }
    }
}

/// Errors that can happen in `share_immutable()`
#[derive(Debug, PartialEq, Eq)]
pub enum TryShareError {
    /// The inner lock is poisoned and we do not want to implement recovery
    InnerLockPoisoned,
    /// The inner lock would block and we are expecting to take it immediately
    InnerLockWouldBlock,
}

impl<T> From<TryLockError<T>> for TryShareError {
    fn from(e: TryLockError<T>) -> Self {
        match e {
            TryLockError::Poisoned(_) => Self::InnerLockPoisoned,
            TryLockError::WouldBlock => Self::InnerLockWouldBlock,
        }
    }
}

/// A reference to [`PyShareable`] and its legit owner Python object.
///
/// This is a lifetime-bound reference to the [PyShareable] data field,
/// and could be created by an automatically generated accessor when
/// we make one.
pub struct PyShareableRef<'py, T: 'py + ?Sized> {
    owner: &'py Bound<'py, PyAny>,
    state: &'py PySharedState,
    data: &'py RwLock<T>, // TODO perhaps this needs Pin
}

impl<'py, T: ?Sized> PyShareableRef<'py, T> {
    /// Take the lock on the wrapped value for read-only operations.
    ///
    /// # Panics
    ///
    /// Panics if the lock is currently held for write operations.
    pub fn read(&self) -> RwLockReadGuard<'py, T> {
        self.try_read().expect("already mutably borrowed")
    }

    /// Immutably borrows the wrapped value, returning an error if the value
    /// is currently mutably borrowed.
    pub fn try_read(&self) -> TryLockResult<RwLockReadGuard<'py, T>> {
        // state isn't involved since
        // - data.try_read() would fail if self is mutably borrowed,
        // - and data.try_write() would fail while self is borrowed.
        self.data.try_read()
    }

    /// Take the lock on the wrapped value for write operations.
    ///
    /// Any existing shared references will be invalidated.
    ///
    /// # Panics
    ///
    /// Panics if the lock is currently held.
    pub fn write(&self) -> RwLockWriteGuard<'py, T> {
        self.try_write().expect("already borrowed")
    }

    /// Mutably borrows the wrapped value, returning an error if the value
    /// is currently borrowed.
    pub fn try_write(&self) -> TryLockResult<RwLockWriteGuard<'py, T>> {
        // the value may be immutably borrowed through SharedByPyObject
        if self.state.current_borrow_count(self.py()) > 0 {
            // propagate borrow-by-shared state to data to get BorrowMutError
            let _dummy = self.data.read();
            let _unused = self.data.try_write()?;
            unreachable!("BorrowMutError should have been returned");
        }

        let data_ref = self.data.try_write()?;
        self.state.increment_generation(self.py());
        Ok(data_ref)
    }

    /// Creates an immutable reference which is not bound to lifetime.
    ///
    /// # Panics
    ///
    /// Panics if the value is currently mutably borrowed.
    pub fn share_immutable(&self) -> SharedByPyObject<&'static T> {
        self.try_share_immutable()
            .expect("already mutably borrowed")
    }

    /// Creates an immutable reference which is not bound to lifetime,
    /// returning an error if the value is currently mutably borrowed.
    pub fn try_share_immutable(
        &self,
    ) -> Result<SharedByPyObject<&'static T>, TryShareError> {
        // make sure self.data isn't mutably borrowed; otherwise the
        // generation number wouldn't be trusted.
        let data_ref = self.try_read()?;

        // keep reference to the owner so the data and state are alive,
        // but the data pointer can be invalidated by write().
        // the state wouldn't since it is immutable.
        let state_ptr: *const PySharedState = self.state;
        let data_ptr: *const T = &*data_ref;
        Ok(SharedByPyObject::<&'static T> {
            owner: self.owner.clone().unbind(),
            state: unsafe { &*state_ptr },
            generation: self.state.current_generation(self.py()),
            data: unsafe { &*data_ptr },
        })
    }

    /// Retrieve the GIL handle
    fn py(&self) -> Python<'py> {
        // Since this is a smart pointer implying the GIL lifetime,
        // we might as well use `assume_gil_acquired`, but the method
        // of `Bound` does it for us.
        self.owner.py()
    }
}

/// The shared state between Python and Rust
///
/// `PySharedState` is owned by `PyShareable`, and is shared across its
/// derived references. The consistency of these references are guaranteed
/// as follows:
///
/// - The immutability of `PycCass` object fields. Any mutation of
///   [`PyShareable`] is allowed only through its `write()`.
/// - The `py: Python<'_>` token, which makes sure that any data access is
///   synchronized by the GIL.
/// - The underlying `RefCell`, which prevents `PyShareable` value from being
///   directly borrowed or shared while it is mutably borrowed.
/// - The `borrow_count`, which is the number of references borrowed from
///   `SharedByPyObject`. Just like `RefCell`, mutation is prohibited while
///   `SharedByPyObject` is borrowed.
/// - The `generation` counter, which increments on `write()`.
///   `SharedByPyObject`
#[derive(Debug)]
struct PySharedState {
    // The counter variable could be Cell<usize> since any operation on
    // PySharedState is synchronized by the GIL, but being "atomic" makes
    // PySharedState inherently Sync. The ordering requirement doesn't
    // matter thanks to the GIL. That's why Ordering::Relaxed is used
    // everywhere.
    /// The number of immutable references borrowed through shared reference.
    borrow_count: AtomicUsize,
    /// The mutation counter of the underlying value.
    generation: AtomicUsize,
}

impl PySharedState {
    const fn new() -> PySharedState {
        PySharedState {
            borrow_count: AtomicUsize::new(0),
            generation: AtomicUsize::new(0),
        }
    }

    fn current_borrow_count(&self, _py: Python) -> usize {
        self.borrow_count.load(Ordering::Relaxed)
    }

    fn increase_borrow_count(&self, _py: Python) {
        // this wraps around if there are more than usize::MAX borrowed
        // references, which shouldn't happen due to memory limit.
        self.borrow_count.fetch_add(1, Ordering::Relaxed);
    }

    fn decrease_borrow_count(&self, _py: Python) {
        let prev_count = self.borrow_count.fetch_sub(1, Ordering::Relaxed);
        assert!(prev_count > 0);
    }

    fn current_generation(&self, _py: Python) -> usize {
        self.generation.load(Ordering::Relaxed)
    }

    fn increment_generation(&self, py: Python) {
        assert_eq!(self.current_borrow_count(py), 0);
        // this wraps around to the same value if mutably borrowed
        // usize::MAX times, which wouldn't happen in practice.
        self.generation.fetch_add(1, Ordering::Relaxed);
    }
}

/// Helper to keep the borrow count updated while the shared object is
/// immutably borrowed without using the `RwLock` interface.
struct BorrowPyShared<'a> {
    py: Python<'a>,
    state: &'a PySharedState,
}

impl<'a> BorrowPyShared<'a> {
    fn new(py: Python<'a>, state: &'a PySharedState) -> BorrowPyShared<'a> {
        state.increase_borrow_count(py);
        BorrowPyShared { py, state }
    }
}

impl<'a> Drop for BorrowPyShared<'a> {
    fn drop(&mut self) {
        self.state.decrease_borrow_count(self.py);
    }
}

/// An immutable reference to [`PyShareable`] value, not bound to lifetime.
///
/// The reference will be invalidated once the original value is mutably
/// borrowed.
///
/// # Safety
///
/// Even though [`SharedByPyObject`] tries to enforce the real lifetime of the
/// underlying object, the object having the artificial `'static` lifetime
/// may be exposed to your Rust code. You must be careful to not make a bare
/// reference outlive the actual object lifetime.
///
/// See [`Self::try_borrow_mut()`] for an example of the kind of trouble that
/// can arise.
pub struct SharedByPyObject<T: ?Sized> {
    owner: PyObject,
    state: &'static PySharedState,
    /// Generation counter of data `T` captured when SharedByPyObject is
    /// created.
    generation: usize,
    /// Underlying data of artificial lifetime, which is valid only when
    /// state.generation == self.generation.
    data: T,
}

// DO NOT implement Deref or DerefMut for SharedByPyObject<T>! Dereferencing
// SharedByPyObject without taking Python GIL wouldn't be safe. Also, the
// underling reference is invalid if generation != state.generation.
static_assertions_next::assert_impl!(
    for(T) SharedByPyObject<T>: !Deref
);

static_assertions_next::assert_impl!(
    for(T) SharedByPyObject<T>: !DerefMut
);

impl<T: ?Sized> SharedByPyObject<T> {
    // No panicking version of borrow() and borrow_mut() are implemented
    // because the underlying value is supposed to be mutated in Python
    // world, and the Rust library designer can't prevent it.

    /// Immutably borrows the wrapped value.
    ///
    /// Borrowing fails if the underlying reference has been invalidated.
    ///
    /// # Safety
    ///
    /// The lifetime of the innermost object is artificial. Do not obtain and
    /// copy it out of the borrow scope.
    ///
    /// The lifetime of the innermost object is artificial. Do not obtain and
    /// copy it out of the borrow scope. More generally, the returned `&T`
    /// may have a method returning an inner reference, which would typically
    /// be `'static` and not safe without the `owner` Python object, so the
    /// problem might be less obvious than in the example below.
    ///
    /// The following example does compile and illustrates the problem.
    /// In this case, the data is a `Vec<String>` and the leaked reference
    /// `&'static str`, which points to some element of the vector. This
    /// illustrates that the leaks are not necessarily to the whole of the
    /// shared data.
    ///
    /// ```no_run
    /// # use pyo3::prelude::*;
    /// # use pyo3_sharedref::PyShareable;
    /// #[pyclass]
    /// struct Owner {
    ///     value: PyShareable<Vec<String>>
    /// }
    ///
    /// #[pymethods]
    /// impl Owner {
    ///     #[new]
    ///     fn new(s: &str) -> Self {
    ///         let split: Vec<_> = s.split(' ').map(String::from).collect();
    ///         Self { value: split.into() }
    ///     }
    /// }
    ///
    /// const EMPTY: &'static str = "";
    ///
    /// let mut outer = EMPTY;
    /// Python::with_gil(|py| {
    ///     let owner = Bound::new(py, Owner::new("hello")).unwrap();
    ///     let shareable = &owner.borrow().value;
    ///     let shared = unsafe { shareable.share(&owner) };
    ///     {
    ///         let inner = unsafe { shared.try_borrow(py) }.unwrap();
    ///         outer = &inner[0]; // Bad, &'static str does outlive the scope
    ///     }
    /// });
    /// ```
    pub unsafe fn try_borrow<'a>(
        &'a self,
        py: Python<'a>,
    ) -> PyResult<SharedByPyObjectRef<'a, T>> {
        self.validate_generation(py)?;
        Ok(SharedByPyObjectRef {
            _borrow: BorrowPyShared::new(py, self.state),
            data: &self.data,
        })
    }

    /// Mutably borrows the wrapped value.
    ///
    /// Borrowing fails if the underlying reference has been invalidated.
    ///
    /// Typically `T` would be an iterator obtained by the [`Self::map`]
    /// method.
    ///
    /// # Safety
    ///
    /// The lifetime of the innermost object is artificial. Do not obtain and
    /// copy it out of the borrow scope. More generally, the returned `&T`
    /// may have a method returning an inner reference, which would typically
    /// be `'static` and not safe without the `owner` Python object, so the
    /// problem might be less obvious than in the example below.
    ///
    /// The following example does compile and illustrates the problem.
    /// It is very close to the example given in [`Self::try_borrow`] because
    /// the problem does not arise from the mutability of the reference
    /// returned by this function.
    ///
    /// In this case, the data is a `Vec<String>` and the leaked reference
    /// `&'static str`, which points to some element of the vector. This
    /// illustrates that the leaks are not necessarily to the whole of the
    /// shared data.
    ///
    /// ```no_run
    /// # use pyo3::prelude::*;
    /// # use pyo3_sharedref::PyShareable;
    /// #[pyclass]
    /// struct Owner {
    ///     value: PyShareable<Vec<String>>
    /// }
    ///
    /// #[pymethods]
    /// impl Owner {
    ///     #[new]
    ///     fn new(s: &str) -> Self {
    ///         let split: Vec<_> = s.split(' ').map(String::from).collect();
    ///         Self { value: split.into() }
    ///     }
    /// }
    ///
    /// const EMPTY: &'static str = "";
    ///
    /// let mut outer = EMPTY;
    /// Python::with_gil(|py| {
    ///     let owner = Bound::new(py, Owner::new("hello")).unwrap();
    ///     let shareable = &owner.borrow().value;
    ///     let shared = unsafe { shareable.share(&owner) };
    ///     let mut shared_iter = unsafe { shared.map(py, |o| o.iter()) };
    ///     {
    ///         let mut iter = unsafe {
    ///             shared_iter.try_borrow_mut(py)
    ///         }.unwrap();
    ///         let inner = iter.next().unwrap();  // Good, in borrow scope
    ///         outer = inner; // Bad, &'static str does outlive the scope
    ///     }
    /// });
    /// ```
    pub unsafe fn try_borrow_mut<'a>(
        &'a mut self,
        py: Python<'a>,
    ) -> PyResult<SharedByPyObjectRefMut<'a, T>> {
        self.validate_generation(py)?;
        Ok(SharedByPyObjectRefMut {
            _borrow: BorrowPyShared::new(py, self.state),
            data: &mut self.data,
        })
    }

    fn validate_generation(&self, py: Python) -> PyResult<()> {
        if self.state.current_generation(py) == self.generation {
            Ok(())
        } else {
            Err(PyRuntimeError::new_err(
                "Cannot access to shared reference after mutation",
            ))
        }
    }
}

impl<T> SharedByPyObject<T> {
    /// Converts the inner value by the given function.
    ///
    /// Typically `T` is a static reference to a collection, and `U` is an
    /// iterator of that collection.
    ///
    /// # Panics
    ///
    /// Panics if the underlying reference has been invalidated.
    ///
    /// This is typically called immediately after the `SharedByPyObject` is
    /// obtained. At this time, the reference must be valid and no panic
    /// would occur.
    ///
    /// # Safety
    ///
    /// The lifetime of the object passed in to the function `f` is artificial.
    /// It's typically a static reference, but is valid only while the
    /// corresponding `SharedByPyObject` is alive. Do not copy it out of the
    /// function call. For example, the following does compile:
    ///
    /// ```no_run
    /// # use pyo3::prelude::*;
    /// # use pyo3_sharedref::PyShareable;
    /// #[pyclass]
    /// struct Owner {
    ///     value: PyShareable<String>
    /// }
    ///
    /// #[pymethods]
    /// impl Owner {
    ///     #[new]
    ///     fn new(s: &str) -> Self {
    ///         Self { value: s.to_owned().into() }
    ///     }
    /// }
    ///
    /// const EMPTY: &'static str = "";
    ///
    /// let mut outer = EMPTY;
    /// Python::with_gil(|py| {
    ///     let owner = Bound::new(py, Owner::new("hello")).unwrap();
    ///     let shareable = &owner.borrow().value;
    ///     let shared = unsafe { shareable.share(&owner) };
    ///
    ///     unsafe { shared.map(py, |o| { outer = o }) };  // Bad
    /// });
    /// ```
    pub unsafe fn map<U>(
        self,
        py: Python,
        f: impl FnOnce(T) -> U,
    ) -> SharedByPyObject<U> {
        // Needs to test the generation value to make sure self.data reference
        // is still intact.
        self.validate_generation(py)
            .expect("map() over invalidated shared reference");

        // f() could make the self.data outlive. That's why map() is unsafe.
        // In order to make this function safe, maybe we'll need a way to
        // temporarily restrict the lifetime of self.data and translate the
        // returned object back to Something<'static>.
        let new_data = f(self.data);
        SharedByPyObject {
            owner: self.owner,
            state: self.state,
            generation: self.generation,
            data: new_data,
        }
    }
}

/// An immutably borrowed reference to a shared value.
pub struct SharedByPyObjectRef<'a, T: 'a + ?Sized> {
    _borrow: BorrowPyShared<'a>,
    data: &'a T,
}

impl<'a, T: ?Sized> Deref for SharedByPyObjectRef<'a, T> {
    type Target = T;

    fn deref(&self) -> &T {
        self.data
    }
}

/// A mutably borrowed reference to a shared value.
pub struct SharedByPyObjectRefMut<'a, T: 'a + ?Sized> {
    _borrow: BorrowPyShared<'a>,
    data: &'a mut T,
}

impl<'a, T: ?Sized> Deref for SharedByPyObjectRefMut<'a, T> {
    type Target = T;

    fn deref(&self) -> &T {
        self.data
    }
}

impl<'a, T: ?Sized> DerefMut for SharedByPyObjectRefMut<'a, T> {
    fn deref_mut(&mut self) -> &mut T {
        self.data
    }
}

/// Defines a Python iterator over a Rust iterator.
///
/// TODO: this is a bit awkward to use, and a better (more complicated)
///     procedural macro would simplify the interface a lot.
///
/// # Parameters
///
/// * `$name` is the identifier to give to the resulting Rust struct.
/// * `$success_type` is the resulting Python object. It can be a bultin type,
///   (e.g., `PyBytes`), or any `PyClass`.
/// * `$owner_type` is the type owning the data
/// * `$owner_attr` is the name of the shareable attribute in `$owner_type`
/// * `$shared_type` is the type wrapped in `SharedByPyObject`, typically
///   `SomeIter<'static>`
/// * `$iter_func` is a function to obtain the Rust iterator from the content
///   of the shareable attribute. It can be a closure.
/// * `$result_func` is a function for converting items returned by the Rust
///   iterator into `PyResult<Option<Py<$success_type>`.
///
/// # Safety
///
/// `$success_func` may take a reference, whose lifetime may be articial.
/// Do not copy it out of the function call (this would be possible only
/// with inner mutability).
///
/// # Example
///
/// The iterator example in [`PyShareable`] can be rewritten as
///
/// ```
/// use pyo3::prelude::*;
/// use pyo3_sharedref::*;
///
/// use pyo3::types::{PyTuple, PyInt};
/// use std::collections::{hash_set::Iter as IterHashSet, HashSet};
/// use std::vec::Vec;
///
/// #[pyclass(sequence)]
/// struct Set {
///     rust_set: PyShareable<HashSet<i32>>,
/// }
///
/// #[pymethods]
/// impl Set {
///     #[new]
///     fn new(values: &Bound<'_, PyTuple>) -> PyResult<Self> {
///         let as_vec = values.extract::<Vec<i32>>()?;
///         let s: HashSet<_> = as_vec.iter().copied().collect();
///         Ok(Self { rust_set: s.into() })
///     }
///
///     fn __iter__(slf: &Bound<'_, Self>) -> PyResult<SetIterator> {
///         SetIterator::new(slf)
///     }
/// }
///
/// py_shared_iterator!(
///    SetIterator,
///    PyInt,
///    Set,
///    rust_set,
///    IterHashSet<'static, i32>,
///    |hash_set| hash_set.iter(),
///    it_next_result
/// );
///
/// fn it_next_result(py: Python, res: &i32) -> PyResult<Option<Py<PyInt>>> {
///     Ok(Some((*res).into_pyobject(py)?.unbind()))
/// }
/// ```
///
/// In the example above, `$result_func` is fairly trivial, and can be replaced
/// by a closure, but things can get more complicated if the Rust
/// iterator itself returns `Result<T, E>` with `T` not implementing
/// `IntoPyObject` and `E` needing to be converted.
/// Also the closure variant is fairly obscure:
///
/// ```ignore
/// py_shared_iterator!(
///    SetIterator,
///    PyInt,
///    Set,
///    rust_set,
///    IterHashSet<'static, i32>,
///    |hash_set| hash_set.iter(),
///    (|py, i: &i32| Ok(Some((*i).into_pyobject(py)?.unbind())))
/// )
/// ```
#[macro_export]
macro_rules! py_shared_iterator {
    (
        $name: ident,
        $success_type: ty,
        $owner_type: ident,
        $owner_attr: ident,
        $shared_type: ty,
        $iter_func: expr,
        $result_func: expr
    ) => {
        #[pyclass]
        pub struct $name {
            inner: pyo3_sharedref::SharedByPyObject<$shared_type>,
        }

        #[pymethods]
        impl $name {
            #[new]
            fn new(owner: &Bound<'_, $owner_type>) -> PyResult<Self> {
                let inner = &owner.borrow().$owner_attr;
                // Safety: the data is indeed owned by `owner`
                let shared_iter =
                    unsafe { inner.share_map(owner, $iter_func) };
                Ok(Self { inner: shared_iter })
            }

            fn __iter__(slf: PyRef<'_, Self>) -> PyRef<'_, Self> {
                slf
            }

            fn __next__(
                mut slf: PyRefMut<'_, Self>,
            ) -> PyResult<Option<Py<$success_type>>> {
                let py = slf.py();
                let shared = &mut slf.inner;
                // Safety: we do not leak references derived from the internal
                // 'static reference.
                let mut inner = unsafe { shared.try_borrow_mut(py) }?;
                match inner.next() {
                    None => Ok(None),
                    Some(res) => $result_func(py, res),
                }
            }
        }
    };
}
