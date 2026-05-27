//! # PyO3 Types
//!
//! This doc provides guidance on using PyO3 types in `hg-pyo3`.
//!
//! ## Overview
//!
//! This section is a primer on PyO3 types. For more information, see
//! https://pyo3.rs/latest/types.
//!
//! * [`Python<'py>`] is a token indicating you have the GIL.
//! * [`Py<T>`] is a raw pointer to a Python object.
//! * [`Bound<'py, T>`] is [`Py<T>`] bundled with a [`Python<'py>`] for
//!   convenience, so that you don't have to pass `py` to methods.
//!     * You can convert betweem them with [`Py::bind`] and [`Bound::unbind`].
//!     * Both [`Py`] and [`Bound`] can be cloned, which increments a refcount.
//!     * It's preferred to take parameters as `&Bound` instead of `Bound` to
//!       avoid incrementing and decrementing the refcount.
//! * Given a [`Bound<'py, T>`] there are a few ways to access the `T`:
//!     * If it's a frozen class, just use [`Bound::get`] to get `&T`.
//!     * Otherwise, you can use [`Bound::borrow`] to get a [`PyRef`], or
//!       [`Bound::as_borrowed`] to get a [`Borrowed`].
//! * A [`PyRef`] is just a wrapper around [`Bound`], but there is a TODO
//!   comment in the source saying to make it based on [`Borrowed`] instead.
//! * [`Borrowed<'a, 'py, T>`] is like `&Bound` but it's one pointer instead of
//!   a pointer-to-pointer. It's considered "advanced" and rarely used.
//! * Most `hg-pyo3` code should use [`Py`] and [`Bound`]. Use [`PyRef`] only
//!   when necessary, and don't use [`Borrowed`] at all.
//!
//! ## Guidelines
//!
//! ### Classes
//!
//! When defining a PyO3 class, prefer to make it `frozen`. This may become the
//! default in a future version. It means that if you want any interior
//! mutability, you have to do it yourself with something like atomics, mutexes,
//! or [`pyo3_sharedref::PyShareable`].
//!
//! ```
//! #[pyclass(name = "Foo", frozen)]
//! struct PyFoo {
//!   // ...
//! }
//! ```
//!
//! To store Python objects in the class, you must use [`Py`], for example
//! [`Py<PyAny>`] or [`Py<PyBytes>`].
//!
//! For more information, see https://pyo3.rs/latest/class.
//!
//! ### Self
//!
//! * Prefer to use `&self` if it works.
//! * Use `slf: &Bound<'_, Self>` if you need direct access to the [`Bound`],
//!   for example to use [`pyo3_sharedref::PyShareable`].
//!
//! ### Parameters
//!
//! * Often, you can just use the Rust type:
//!     * For primitives, take `bool`, `i32`, `usize`, etc.
//!     * For bytes, take `&[u8]`.
//! * For other types, prefer `&Bound<'_, T>`:
//!     * For an arbitrary Python object: `&Bound<'_, PyAny>`.
//!     * For bytes (with access to Python methods): `&Bound<'_, PyBytes>`.
//!     * For a `pyclass` called `C`, take `&Bound<'_, C>`.
//! * Usually lifetimes can be inferred, but if not, use `'py` everywhere.
//! * You can always add `py: Python<'py>` as the first argument.
//!     * You can also use [`Bound::py`] to get the `py` from any [`Bound`]
//!       value. This is okay on `slf`, but otherwise prefer taking an explicit
//!       `py` instead of picking a `Bound` parameter at random.
//!
//! ### Return values
//!
//! Often, you can just use the Rust type:
//!
//! * For primitives, return `bool`, `i32`, `usize`, etc.
//! * For bytes (if you're okay with copying to Python), return `Vec<u8>`.
//! * For other types, prefer [`Py<T>`].
//! * For an arbitrary Python object, use [`Py<PyAny>`].

// Import for references in docs.
#[expect(unused_imports)]
use pyo3::prelude::*;
