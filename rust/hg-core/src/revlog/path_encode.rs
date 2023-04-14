use sha1::{Digest, Sha1};

#[derive(PartialEq, Debug)]
#[allow(non_camel_case_types)]
#[allow(clippy::upper_case_acronyms)]
enum path_state {
    START, /* first byte of a path component */
    A,     /* "AUX" */
    AU,
    THIRD, /* third of a 3-byte sequence, e.g. "AUX", "NUL" */
    C,     /* "CON" or "COMn" */
    CO,
    COMLPT, /* "COM" or "LPT" */
    COMLPTn,
    L,
    LP,
    N,
    NU,
    P, /* "PRN" */
    PR,
    LDOT, /* leading '.' */
    DOT,  /* '.' in a non-leading position */
    H,    /* ".h" */
    HGDI, /* ".hg", ".d", or ".i" */
    SPACE,
    DEFAULT, /* byte of a path component after the first */
}

/* state machine for dir-encoding */
#[allow(non_camel_case_types)]
#[allow(clippy::upper_case_acronyms)]
enum dir_state {
    DDOT,
    DH,
    DHGDI,
    DDEFAULT,
}

trait Sink {
    fn write_byte(&mut self, c: u8);
    fn write_bytes(&mut self, c: &[u8]);
}

fn inset(bitset: &[u32; 8], c: u8) -> bool {
    bitset[(c as usize) >> 5] & (1 << (c & 31)) != 0
}

const MAXENCODE: usize = 4096 * 4;

struct DestArr<const N: usize> {
    buf: [u8; N],
    pub len: usize,
}

impl<const N: usize> DestArr<N> {
    pub fn create() -> Self {
        DestArr {
            buf: [0; N],
            len: 0,
        }
    }

    pub fn contents(&self) -> &[u8] {
        &self.buf[..self.len]
    }
}

impl<const N: usize> Sink for DestArr<N> {
    fn write_byte(&mut self, c: u8) {
        self.buf[self.len] = c;
        self.len += 1;
    }

    fn write_bytes(&mut self, src: &[u8]) {
        self.buf[self.len..self.len + src.len()].copy_from_slice(src);
        self.len += src.len();
    }
}

struct MeasureDest {
    pub len: usize,
}

impl Sink for Vec<u8> {
    fn write_byte(&mut self, c: u8) {
        self.push(c)
    }

    fn write_bytes(&mut self, src: &[u8]) {
        self.extend_from_slice(src)
    }
}

impl MeasureDest {
    fn create() -> Self {
        Self { len: 0 }
    }
}

impl Sink for MeasureDest {
    fn write_byte(&mut self, _c: u8) {
        self.len += 1;
    }

    fn write_bytes(&mut self, src: &[u8]) {
        self.len += src.len();
    }
}

fn hexencode(dest: &mut impl Sink, c: u8) {
    let hexdigit = b"0123456789abcdef";
    dest.write_byte(hexdigit[(c as usize) >> 4]);
    dest.write_byte(hexdigit[(c as usize) & 15]);
}

/* 3-byte escape: tilde followed by two hex digits */
fn escape3(dest: &mut impl Sink, c: u8) {
    dest.write_byte(b'~');
    hexencode(dest, c);
}

fn encode_dir(dest: &mut impl Sink, src: &[u8]) {
    let mut state = dir_state::DDEFAULT;
    let mut i = 0;

    while i < src.len() {
        match state {
            dir_state::DDOT => match src[i] {
                b'd' | b'i' => {
                    state = dir_state::DHGDI;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'h' => {
                    state = dir_state::DH;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                _ => {
                    state = dir_state::DDEFAULT;
                }
            },
            dir_state::DH => {
                if src[i] == b'g' {
                    state = dir_state::DHGDI;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = dir_state::DDEFAULT;
                }
            }
            dir_state::DHGDI => {
                if src[i] == b'/' {
                    dest.write_bytes(b".hg");
                    dest.write_byte(src[i]);
                    i += 1;
                }
                state = dir_state::DDEFAULT;
            }
            dir_state::DDEFAULT => {
                if src[i] == b'.' {
                    state = dir_state::DDOT
                }
                dest.write_byte(src[i]);
                i += 1;
            }
        }
    }
}

fn _encode(
    twobytes: &[u32; 8],
    onebyte: &[u32; 8],
    dest: &mut impl Sink,
    src: &[u8],
    encodedir: bool,
) {
    let mut state = path_state::START;
    let mut i = 0;
    let len = src.len();

    while i < len {
        match state {
            path_state::START => match src[i] {
                b'/' => {
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'.' => {
                    state = path_state::LDOT;
                    escape3(dest, src[i]);
                    i += 1;
                }
                b' ' => {
                    state = path_state::DEFAULT;
                    escape3(dest, src[i]);
                    i += 1;
                }
                b'a' => {
                    state = path_state::A;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'c' => {
                    state = path_state::C;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'l' => {
                    state = path_state::L;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'n' => {
                    state = path_state::N;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'p' => {
                    state = path_state::P;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                _ => {
                    state = path_state::DEFAULT;
                }
            },
            path_state::A => {
                if src[i] == b'u' {
                    state = path_state::AU;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::AU => {
                if src[i] == b'x' {
                    state = path_state::THIRD;
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::THIRD => {
                state = path_state::DEFAULT;
                match src[i] {
                    b'.' | b'/' | b'\0' => escape3(dest, src[i - 1]),
                    _ => i -= 1,
                }
            }
            path_state::C => {
                if src[i] == b'o' {
                    state = path_state::CO;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::CO => {
                if src[i] == b'm' {
                    state = path_state::COMLPT;
                    i += 1;
                } else if src[i] == b'n' {
                    state = path_state::THIRD;
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::COMLPT => {
                if src[i] >= b'1' && src[i] <= b'9' {
                    state = path_state::COMLPTn;
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                    dest.write_byte(src[i - 1]);
                }
            }
            path_state::COMLPTn => {
                state = path_state::DEFAULT;
                match src[i] {
                    b'.' | b'/' | b'\0' => {
                        escape3(dest, src[i - 2]);
                        dest.write_byte(src[i - 1]);
                    }
                    _ => {
                        dest.write_bytes(&src[i - 2..i]);
                    }
                }
            }
            path_state::L => {
                if src[i] == b'p' {
                    state = path_state::LP;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::LP => {
                if src[i] == b't' {
                    state = path_state::COMLPT;
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::N => {
                if src[i] == b'u' {
                    state = path_state::NU;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::NU => {
                if src[i] == b'l' {
                    state = path_state::THIRD;
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::P => {
                if src[i] == b'r' {
                    state = path_state::PR;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::PR => {
                if src[i] == b'n' {
                    state = path_state::THIRD;
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::LDOT => match src[i] {
                b'd' | b'i' => {
                    state = path_state::HGDI;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'h' => {
                    state = path_state::H;
                    dest.write_byte(src[i]);
                    i += 1;
                }
                _ => {
                    state = path_state::DEFAULT;
                }
            },
            path_state::DOT => match src[i] {
                b'/' | b'\0' => {
                    state = path_state::START;
                    dest.write_bytes(b"~2e");
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'd' | b'i' => {
                    state = path_state::HGDI;
                    dest.write_byte(b'.');
                    dest.write_byte(src[i]);
                    i += 1;
                }
                b'h' => {
                    state = path_state::H;
                    dest.write_bytes(b".h");
                    i += 1;
                }
                _ => {
                    state = path_state::DEFAULT;
                    dest.write_byte(b'.');
                }
            },
            path_state::H => {
                if src[i] == b'g' {
                    state = path_state::HGDI;
                    dest.write_byte(src[i]);
                    i += 1;
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::HGDI => {
                if src[i] == b'/' {
                    state = path_state::START;
                    if encodedir {
                        dest.write_bytes(b".hg");
                    }
                    dest.write_byte(src[i]);
                    i += 1
                } else {
                    state = path_state::DEFAULT;
                }
            }
            path_state::SPACE => match src[i] {
                b'/' | b'\0' => {
                    state = path_state::START;
                    dest.write_bytes(b"~20");
                    dest.write_byte(src[i]);
                    i += 1;
                }
                _ => {
                    state = path_state::DEFAULT;
                    dest.write_byte(b' ');
                }
            },
            path_state::DEFAULT => {
                while i != len && inset(onebyte, src[i]) {
                    dest.write_byte(src[i]);
                    i += 1;
                }
                if i == len {
                    break;
                }
                match src[i] {
                    b'.' => {
                        state = path_state::DOT;
                        i += 1
                    }
                    b' ' => {
                        state = path_state::SPACE;
                        i += 1
                    }
                    b'/' => {
                        state = path_state::START;
                        dest.write_byte(b'/');
                        i += 1;
                    }
                    _ => {
                        if inset(onebyte, src[i]) {
                            loop {
                                dest.write_byte(src[i]);
                                i += 1;
                                if !(i < len && inset(onebyte, src[i])) {
                                    break;
                                }
                            }
                        } else if inset(twobytes, src[i]) {
                            let c = src[i];
                            i += 1;
                            dest.write_byte(b'_');
                            dest.write_byte(if c == b'_' {
                                b'_'
                            } else {
                                c + 32
                            });
                        } else {
                            escape3(dest, src[i]);
                            i += 1;
                        }
                    }
                }
            }
        }
    }
    match state {
        path_state::START => (),
        path_state::A => (),
        path_state::AU => (),
        path_state::THIRD => escape3(dest, src[i - 1]),
        path_state::C => (),
        path_state::CO => (),
        path_state::COMLPT => dest.write_byte(src[i - 1]),
        path_state::COMLPTn => {
            escape3(dest, src[i - 2]);
            dest.write_byte(src[i - 1]);
        }
        path_state::L => (),
        path_state::LP => (),
        path_state::N => (),
        path_state::NU => (),
        path_state::P => (),
        path_state::PR => (),
        path_state::LDOT => (),
        path_state::DOT => {
            dest.write_bytes(b"~2e");
        }
        path_state::H => (),
        path_state::HGDI => (),
        path_state::SPACE => {
            dest.write_bytes(b"~20");
        }
        path_state::DEFAULT => (),
    }
}

fn basic_encode(dest: &mut impl Sink, src: &[u8]) {
    let twobytes: [u32; 8] = [0, 0, 0x87ff_fffe, 0, 0, 0, 0, 0];
    let onebyte: [u32; 8] =
        [1, 0x2bff_3bfa, 0x6800_0001, 0x2fff_ffff, 0, 0, 0, 0];
    _encode(&twobytes, &onebyte, dest, src, true)
}

const MAXSTOREPATHLEN: usize = 120;

fn lower_encode(dest: &mut impl Sink, src: &[u8]) {
    let onebyte: [u32; 8] =
        [1, 0x2bff_fbfb, 0xe800_0001, 0x2fff_ffff, 0, 0, 0, 0];
    let lower: [u32; 8] = [0, 0, 0x07ff_fffe, 0, 0, 0, 0, 0];
    for c in src {
        if inset(&onebyte, *c) {
            dest.write_byte(*c)
        } else if inset(&lower, *c) {
            dest.write_byte(*c + 32)
        } else {
            escape3(dest, *c)
        }
    }
}

fn aux_encode(dest: &mut impl Sink, src: &[u8]) {
    let twobytes = [0; 8];
    let onebyte: [u32; 8] = [!0, 0xffff_3ffe, !0, !0, !0, !0, !0, !0];
    _encode(&twobytes, &onebyte, dest, src, false)
}

fn hash_mangle(src: &[u8], sha: &[u8]) -> Vec<u8> {
    let dirprefixlen = 8;
    let maxshortdirslen = 68;

    let last_slash = src.iter().rposition(|b| *b == b'/');
    let basename_start = match last_slash {
        Some(slash) => slash + 1,
        None => 0,
    };
    let basename = &src[basename_start..];
    let ext = match basename.iter().rposition(|b| *b == b'.') {
        None => &[],
        Some(dot) => &basename[dot..],
    };

    let mut dest = Vec::with_capacity(MAXSTOREPATHLEN);
    dest.write_bytes(b"dh/");

    if let Some(last_slash) = last_slash {
        for slice in src[..last_slash].split(|b| *b == b'/') {
            let slice = &slice[..std::cmp::min(slice.len(), dirprefixlen)];
            if dest.len() + slice.len() > maxshortdirslen + 3 {
                break;
            }
            if let Some(last_char) = slice.last() {
                if *last_char == b'.' || *last_char == b' ' {
                    dest.write_bytes(&slice[0..slice.len() - 1]);
                    dest.write_byte(b'_');
                } else {
                    dest.write_bytes(slice);
                }
            };
            dest.write_byte(b'/');
        }
    }

    let used = dest.len() + 40 + ext.len();

    if MAXSTOREPATHLEN > used {
        let slop = MAXSTOREPATHLEN - used;
        let len = std::cmp::min(basename.len(), slop);
        dest.write_bytes(&basename[..len])
    }
    for c in sha {
        hexencode(&mut dest, *c);
    }
    dest.write_bytes(ext);
    dest.shrink_to_fit();
    dest
}

fn hash_encode(src: &[u8]) -> Vec<u8> {
    let mut dired: DestArr<MAXENCODE> = DestArr::create();
    let mut lowered: DestArr<MAXENCODE> = DestArr::create();
    let mut auxed: DestArr<MAXENCODE> = DestArr::create();
    let baselen = (src.len() - 5) * 3;
    if baselen >= MAXENCODE {
        panic!("path_encode::hash_encore: string too long: {}", baselen)
    };
    encode_dir(&mut dired, src);
    let sha = Sha1::digest(dired.contents());
    lower_encode(&mut lowered, &dired.contents()[5..]);
    aux_encode(&mut auxed, lowered.contents());
    hash_mangle(auxed.contents(), &sha)
}

pub fn path_encode(path: &[u8]) -> Vec<u8> {
    let newlen = if path.len() <= MAXSTOREPATHLEN {
        let mut measure = MeasureDest::create();
        basic_encode(&mut measure, path);
        measure.len
    } else {
        return hash_encode(path);
    };
    if newlen <= MAXSTOREPATHLEN {
        if newlen == path.len() {
            path.to_vec()
        } else {
            let mut dest = Vec::with_capacity(newlen);
            basic_encode(&mut dest, path);
            assert!(dest.len() == newlen);
            dest
        }
    } else {
        hash_encode(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::utils::hg_path::HgPathBuf;

    #[test]
    fn test_dirname_ends_with_underscore() {
        let input = b"data/dir1234.foo/ABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJ.i";
        let expected = b"dh/dir1234_/abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij.if2e9ce59e095eff5f8f334dc809e65606a0aa50b.i";
        let res = path_encode(input);
        assert_eq!(
            HgPathBuf::from_bytes(&res),
            HgPathBuf::from_bytes(expected)
        );
    }

    #[test]
    fn test_long_filename_at_root() {
        let input = b"data/ABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJABCDEFGHIJ.i";
        let expected = b"dh/abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij.i708243a2237a7afae259ea3545a72a2ef11c247b.i";
        let res = path_encode(input);
        assert_eq!(
            HgPathBuf::from_bytes(&res),
            HgPathBuf::from_bytes(expected)
        );
    }
}
