use std::sync::OnceLock;

/// Store the umask for the whole process since it's expensive to get.
static UMASK: OnceLock<u32> = OnceLock::new();

pub fn get_umask() -> u32 {
    *UMASK.get_or_init(|| unsafe {
        // TODO is there any way of getting the umask without temporarily
        // setting it? Doesn't this affect all threads in this tiny window?
        let mask = libc::umask(0);
        libc::umask(mask);
        #[allow(clippy::useless_conversion)]
        (mask & 0o777).into()
    })
}
