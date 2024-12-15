use pyo3::prelude::*;
use pyo3_sharedref::*;

#[pyclass]
struct Owner {
    string: PyShareable<String>,
}

#[pymethods]
impl Owner {
    #[new]
    fn new(s: String) -> Self {
        Self { string: s.into() }
    }
}

fn with_setup(
    test: impl FnOnce(Python<'_>, &Bound<'_, Owner>) -> PyResult<()>,
) -> PyResult<()> {
    pyo3::prepare_freethreaded_python();
    Python::with_gil(|py| {
        let owner = Bound::new(py, Owner::new("new".to_owned()))?;
        test(py, &owner)
    })
}

/// "leak" in the sense of `SharedByPyObject` the `string` data field,
/// taking care of all the boilerplate
fn share_string(
    owner: &Bound<'_, Owner>,
) -> SharedByPyObject<&'static String> {
    let shareable = &owner.borrow().string;
    unsafe { shareable.share(owner) }
}

fn try_share_string(
    owner: &Bound<'_, Owner>,
) -> Result<SharedByPyObject<&'static String>, TryShareError> {
    let shareable = &owner.borrow().string;
    unsafe { shareable.try_share(owner) }
}

/// Mutate the `string` field of `owner` as would be done from Python code
///
/// This is to simulate normal mutation of the owner object from
/// the Python interpreter. This could be replaced by methods of [`Owner`]
/// (wih closure replaced by a small fixed operations)
/// and perhaps will, once we are done converting the original tests
/// from rust-cpython
fn mutate_string<'py>(
    owner: &'py Bound<'py, Owner>,
    f: impl FnOnce(&mut String),
) -> () {
    let shareable = &owner.borrow_mut().string;
    let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
    f(&mut shared_ref.write());
}

#[test]
fn test_shared_borrow() -> PyResult<()> {
    with_setup(|py, owner| {
        let shared = share_string(owner);
        let shared_ref = unsafe { shared.try_borrow(py) }.unwrap();
        assert_eq!(*shared_ref, "new");
        Ok(())
    })
}

#[test]
fn test_shared_borrow_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        let shared = share_string(owner);
        let mut shared_iter = unsafe { shared.map(py, |s| s.chars()) };
        let mut shared_ref =
            unsafe { shared_iter.try_borrow_mut(py) }.unwrap();
        assert_eq!(shared_ref.next(), Some('n'));
        assert_eq!(shared_ref.next(), Some('e'));
        assert_eq!(shared_ref.next(), Some('w'));
        assert_eq!(shared_ref.next(), None);
        Ok(())
    })
}

#[test]
fn test_shared_borrow_after_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        let shared = share_string(owner);
        mutate_string(owner, String::clear);
        assert!(unsafe { shared.try_borrow(py) }.is_err());
        Ok(())
    })
}

#[test]
fn test_shared_borrow_mut_after_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        let shared = share_string(owner);
        let mut shared_iter = unsafe { shared.map(py, |s| s.chars()) };

        mutate_string(owner, String::clear);
        assert!(unsafe { shared_iter.try_borrow_mut(py) }.is_err());
        Ok(())
    })
}

#[test]
#[should_panic(expected = "map() over invalidated shared reference")]
fn test_shared_map_after_mut() {
    with_setup(|py, owner| {
        let shared = share_string(owner);
        mutate_string(owner, String::clear);
        let _shared_iter = unsafe { shared.map(py, |s| s.chars()) };
        Ok(())
    })
    .expect("should already have panicked")
}

/// run `try_borrow_mut` on the `string` field and assert it is not an error
///
/// Simply returning the `Result` is not possible, because that is
/// returning a reference to data owned by the function
fn assert_try_write_string_ok(owner: &Bound<'_, Owner>) {
    let shareable = &owner.borrow().string;
    let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
    assert!(shared_ref.try_write().is_ok());
}

fn assert_try_write_string_err(owner: &Bound<'_, Owner>) {
    let shareable = &owner.borrow().string;
    let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
    assert!(shared_ref.try_write().is_err());
}

fn assert_try_read_string_err(owner: &Bound<'_, Owner>) {
    let shareable = &owner.borrow().string;
    let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
    assert!(shared_ref.try_read().is_err());
}

#[test]
fn test_try_write_while_shared_ref() -> PyResult<()> {
    with_setup(|py, owner| {
        assert_try_write_string_ok(owner);
        let shared = share_string(owner);
        {
            let _shared_ref = unsafe { shared.try_borrow(py) }.unwrap();
            assert_try_write_string_err(owner);
            {
                let _shared_ref2 = unsafe { shared.try_borrow(py) }.unwrap();
                assert_try_write_string_err(owner);
            }
            assert_try_write_string_err(owner);
        }
        assert_try_write_string_ok(owner);
        Ok(())
    })
}

#[test]
fn test_try_write_while_shared_ref_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        assert_try_write_string_ok(owner);
        let shared = share_string(owner);
        let mut shared_iter = unsafe { shared.map(py, |s| s.chars()) };
        {
            let _shared_ref =
                unsafe { shared_iter.try_borrow_mut(py) }.unwrap();
            assert_try_write_string_err(owner);
        }
        assert_try_write_string_ok(owner);
        Ok(())
    })
}

#[test]
fn test_try_share_while_write() -> PyResult<()> {
    with_setup(|_py, owner| {
        let shareable = &owner.borrow().string;
        let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
        let _mut_ref = shared_ref.write();

        assert!(try_share_string(owner).is_err());
        Ok(())
    })
}

#[test]
#[should_panic(expected = "already mutably borrowed")]
fn test_share_while_write() {
    with_setup(|_py, owner| {
        let shareable = &owner.borrow().string;
        let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
        let _mut_ref = shared_ref.write();

        share_string(owner);
        Ok(())
    })
    .expect("should already have panicked")
}

#[test]
fn test_try_write_while_borrow() -> PyResult<()> {
    with_setup(|_py, owner| {
        let shareable = &owner.borrow().string;
        let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
        let _ref = shared_ref.read();

        assert_try_write_string_err(owner);
        Ok(())
    })
}

#[test]
#[should_panic(expected = "already borrowed")]
fn test_write_while_borrow() {
    with_setup(|_py, owner| {
        let shareable = &owner.borrow().string;
        let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
        let _ref = shared_ref.read();

        let shared_ref2 = unsafe { shareable.borrow_with_owner(owner) };
        let _mut_ref = shared_ref2.write();
        Ok(())
    })
    .expect("should already have panicked")
}

#[test]
fn test_try_borrow_while_write() -> PyResult<()> {
    with_setup(|_py, owner| {
        let shareable = &owner.borrow().string;
        let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
        let _mut_ref = shared_ref.write();

        assert_try_read_string_err(owner);
        Ok(())
    })
}

#[test]
#[should_panic(expected = "already mutably borrowed")]
fn test_borrow_while_write() {
    with_setup(|_py, owner| {
        let shareable = &owner.borrow().string;
        let shared_ref = unsafe { shareable.borrow_with_owner(owner) };
        let _mut_ref = shared_ref.write();

        let shared_ref2 = unsafe { shareable.borrow_with_owner(owner) };
        let _ref = shared_ref2.read();
        Ok(())
    })
    .expect("should already have panicked")
}
