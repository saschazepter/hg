use std::sync::OnceLock;

/// Store the umask for the whole process since it's expensive to get.
static UMASK: OnceLock<u32> = OnceLock::new();

/// Cache the process umask.
///
/// Call this during process initialization, before spawning threads or
/// performing concurrent filesystem operations.
pub fn initialize() {
    let _ = UMASK.get_or_init(|| unsafe {
        // TODO is there any way of getting the umask without temporarily
        // setting it? Doesn't this affect all threads in this tiny window?
        let mask = libc::umask(0);
        libc::umask(mask);
        #[allow(clippy::useless_conversion)]
        (mask & 0o777).into()
    });
}

pub fn get_umask() -> u32 {
    // The original plan was to drop this `initialize` call, and thus have
    // `get_umask` safely crash if it's used without `initialize`.
    // However, that makes it awkward to write tests, since all tests that
    // exercise this function need to call `initialize` at the beginning.
    // We're sacrificing a little bit of safety for convenience here,
    initialize();
    *UMASK.get().unwrap()
}
