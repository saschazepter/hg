use std::sync::OnceLock;
use std::sync::atomic::AtomicU32;
use std::sync::atomic::Ordering;

/// Store the umask for the whole process since it's expensive to get.
static UMASK: OnceLock<AtomicU32> = OnceLock::new();

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
        AtomicU32::new(u32::from(mask) & 0o777)
    });
}

/// Update the cached umask. Used by the chg server, whose clients each have
/// their own umask (see `mercurial.util.setumask`).
///
/// Panics if called before `initialize`.
pub fn set_umask(mask: u32) {
    UMASK.get().unwrap().store(mask & 0o777, Ordering::Relaxed);
}

pub fn get_umask() -> u32 {
    // The original plan was to drop this `initialize` call, and thus have
    // `get_umask` safely crash if it's used without `initialize`.
    // However, that makes it awkward to write tests, since all tests that
    // exercise this function need to call `initialize` at the beginning.
    // We're sacrificing a little bit of safety for convenience here,
    initialize();
    UMASK.get().unwrap().load(Ordering::Relaxed)
}
