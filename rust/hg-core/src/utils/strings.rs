/// Returns a short representation of a user name or email address.
pub fn short_user(user: &[u8]) -> &[u8] {
    let mut str = user;
    if let Some(i) = memchr::memchr(b'@', str) {
        str = &str[..i];
    }
    if let Some(i) = memchr::memchr(b'<', str) {
        str = &str[i + 1..];
    }
    if let Some(i) = memchr::memchr(b' ', str) {
        str = &str[..i];
    }
    if let Some(i) = memchr::memchr(b'.', str) {
        str = &str[..i];
    }
    str
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_short_user() {
        assert_eq!(short_user(b""), b"");
        assert_eq!(short_user(b"Name"), b"Name");
        assert_eq!(short_user(b"First Last"), b"First");
        assert_eq!(short_user(b"First Last <user@example.com>"), b"user");
        assert_eq!(short_user(b"First Last <user.name@example.com>"), b"user");
    }
}
