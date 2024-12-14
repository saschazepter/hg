use pyo3::prelude::*;
use pyo3_sharedref::*;

#[pyclass]
struct Owner {
    string: PySharedRefCell<String>,
}

#[pymethods]
impl Owner {
    #[new]
    fn new(s: String) -> Self {
        Self {
            string: PySharedRefCell::new(s),
        }
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

/// "leak" in the sense of `UnsafePyLeaked` the `string` data field,
/// taking care of all the boilerplate
fn leak_string(owner: &Bound<'_, Owner>) -> UnsafePyLeaked<&'static String> {
    let cell = &owner.borrow().string;
    let shared_ref = unsafe { cell.borrow(owner) };
    shared_ref.leak_immutable()
}

fn try_leak_string(
    owner: &Bound<'_, Owner>,
) -> Result<UnsafePyLeaked<&'static String>, TryLeakError> {
    let cell = &owner.borrow().string;
    let shared_ref = unsafe { cell.borrow(owner) };
    shared_ref.try_leak_immutable()
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
    let cell = &owner.borrow_mut().string;
    let shared_ref = unsafe { cell.borrow(owner) };
    f(&mut shared_ref.borrow_mut());
}

#[test]
fn test_leaked_borrow() -> PyResult<()> {
    with_setup(|py, owner| {
        let leaked = leak_string(owner);
        let leaked_ref = unsafe { leaked.try_borrow(py) }.unwrap();
        assert_eq!(*leaked_ref, "new");
        Ok(())
    })
}

#[test]
fn test_leaked_borrow_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        let leaked = leak_string(owner);
        let mut leaked_iter = unsafe { leaked.map(py, |s| s.chars()) };
        let mut leaked_ref =
            unsafe { leaked_iter.try_borrow_mut(py) }.unwrap();
        assert_eq!(leaked_ref.next(), Some('n'));
        assert_eq!(leaked_ref.next(), Some('e'));
        assert_eq!(leaked_ref.next(), Some('w'));
        assert_eq!(leaked_ref.next(), None);
        Ok(())
    })
}

#[test]
fn test_leaked_borrow_after_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        let leaked = leak_string(owner);
        mutate_string(owner, String::clear);
        assert!(unsafe { leaked.try_borrow(py) }.is_err());
        Ok(())
    })
}

#[test]
fn test_leaked_borrow_mut_after_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        let leaked = leak_string(owner);
        let mut leaked_iter = unsafe { leaked.map(py, |s| s.chars()) };

        mutate_string(owner, String::clear);
        assert!(unsafe { leaked_iter.try_borrow_mut(py) }.is_err());
        Ok(())
    })
}

#[test]
#[should_panic(expected = "map() over invalidated leaked reference")]
fn test_leaked_map_after_mut() {
    with_setup(|py, owner| {
        let leaked = leak_string(owner);
        mutate_string(owner, String::clear);
        let _leaked_iter = unsafe { leaked.map(py, |s| s.chars()) };
        Ok(())
    })
    .expect("should already have panicked")
}

/// run `try_borrow_mut` on the `string` field and assert it is not an error
///
/// Simply returning the `Result` is not possible, because that is
/// returning a reference to data owned by the function
fn assert_try_borrow_string_mut_ok(owner: &Bound<'_, Owner>) {
    let cell = &owner.borrow().string;
    let shared_ref = unsafe { cell.borrow(owner) };
    assert!(shared_ref.try_borrow_mut().is_ok());
}

fn assert_try_borrow_string_mut_err(owner: &Bound<'_, Owner>) {
    let cell = &owner.borrow().string;
    let shared_ref = unsafe { cell.borrow(owner) };
    assert!(shared_ref.try_borrow_mut().is_err());
}

fn assert_try_borrow_string_err(owner: &Bound<'_, Owner>) {
    let cell = &owner.borrow().string;
    let shared_ref = unsafe { cell.borrow(owner) };
    assert!(shared_ref.try_borrow().is_err());
}

#[test]
fn test_try_borrow_mut_while_leaked_ref() -> PyResult<()> {
    with_setup(|py, owner| {
        assert_try_borrow_string_mut_ok(owner);
        let leaked = leak_string(owner);
        {
            let _leaked_ref = unsafe { leaked.try_borrow(py) }.unwrap();
            assert_try_borrow_string_mut_err(owner);
            {
                let _leaked_ref2 = unsafe { leaked.try_borrow(py) }.unwrap();
                assert_try_borrow_string_mut_err(owner);
            }
            assert_try_borrow_string_mut_err(owner);
        }
        assert_try_borrow_string_mut_ok(owner);
        Ok(())
    })
}

#[test]
fn test_try_borrow_mut_while_leaked_ref_mut() -> PyResult<()> {
    with_setup(|py, owner| {
        assert_try_borrow_string_mut_ok(owner);
        let leaked = leak_string(owner);
        let mut leaked_iter = unsafe { leaked.map(py, |s| s.chars()) };
        {
            let _leaked_ref =
                unsafe { leaked_iter.try_borrow_mut(py) }.unwrap();
            assert_try_borrow_string_mut_err(owner);
        }
        assert_try_borrow_string_mut_ok(owner);
        Ok(())
    })
}

#[test]
fn test_try_leak_while_borrow_mut() -> PyResult<()> {
    with_setup(|_py, owner| {
        let cell = &owner.borrow().string;
        let shared_ref = unsafe { cell.borrow(owner) };
        let _mut_ref = shared_ref.borrow_mut();

        assert!(try_leak_string(owner).is_err());
        Ok(())
    })
}

#[test]
#[should_panic(expected = "already mutably borrowed")]
fn test_leak_while_borrow_mut() {
    with_setup(|_py, owner| {
        let cell = &owner.borrow().string;
        let shared_ref = unsafe { cell.borrow(owner) };
        let _mut_ref = shared_ref.borrow_mut();

        leak_string(owner);
        Ok(())
    })
    .expect("should already have panicked")
}

#[test]
fn test_try_borrow_mut_while_borrow() -> PyResult<()> {
    with_setup(|_py, owner| {
        let cell = &owner.borrow().string;
        let shared_ref = unsafe { cell.borrow(owner) };
        let _ref = shared_ref.borrow();

        assert_try_borrow_string_mut_err(owner);
        Ok(())
    })
}

#[test]
#[should_panic(expected = "already borrowed")]
fn test_borrow_mut_while_borrow() {
    with_setup(|_py, owner| {
        let cell = &owner.borrow().string;
        let shared_ref = unsafe { cell.borrow(owner) };
        let _ref = shared_ref.borrow();

        let shared_ref2 = unsafe { cell.borrow(owner) };
        let _mut_ref = shared_ref2.borrow_mut();
        Ok(())
    })
    .expect("should already have panicked")
}

#[test]
fn test_try_borrow_while_borrow_mut() -> PyResult<()> {
    with_setup(|_py, owner| {
        let cell = &owner.borrow().string;
        let shared_ref = unsafe { cell.borrow(owner) };
        let _mut_ref = shared_ref.borrow_mut();

        assert_try_borrow_string_err(owner);
        Ok(())
    })
}

#[test]
#[should_panic(expected = "already mutably borrowed")]
fn test_borrow_while_borrow_mut() {
    with_setup(|_py, owner| {
        let cell = &owner.borrow().string;
        let shared_ref = unsafe { cell.borrow(owner) };
        let _mut_ref = shared_ref.borrow_mut();

        let shared_ref2 = unsafe { cell.borrow(owner) };
        let _ref = shared_ref2.borrow();
        Ok(())
    })
    .expect("should already have panicked")
}
