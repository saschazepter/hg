//! Helpers around revlog compression

use std::cell::RefCell;
use std::collections::HashSet;
use std::io::Read;

use flate2::bufread::ZlibEncoder;
use flate2::read::ZlibDecoder;

use crate::config::Config;
use crate::errors::HgError;
use crate::exit_codes;

use super::corrupted;
use super::RevlogError;

/// Header byte used to identify ZSTD-compressed data
pub const ZSTD_BYTE: u8 = b'\x28';
/// Header byte used to identify Zlib-compressed data
pub const ZLIB_BYTE: u8 = b'x';

const ZSTD_DEFAULT_LEVEL: u8 = 3;
const ZLIB_DEFAULT_LEVEL: u8 = 6;
/// The length of data below which we don't even try to compress it when using
/// Zstandard.
const MINIMUM_LENGTH_ZSTD: usize = 50;
/// The length of data below which we don't even try to compress it when using
/// Zlib.
const MINIMUM_LENGTH_ZLIB: usize = 44;

/// Defines the available compression engines and their options.
#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum CompressionConfig {
    Zlib {
        /// Between 0 and 9 included
        level: u8,
    },
    Zstd {
        /// Between 0 and 22 included
        level: u8,
        /// Never used in practice for now
        threads: u8,
    },
    /// No compression is performed
    None,
}

impl CompressionConfig {
    pub fn new(
        config: &Config,
        requirements: &HashSet<String>,
    ) -> Result<Self, HgError> {
        let mut new = Self::default();

        let zlib_level = config.get_u32(b"storage", b"revlog.zlib.level")?;
        let zstd_level = config.get_u32(b"storage", b"revlog.zstd.level")?;

        for requirement in requirements {
            if requirement.starts_with("revlog-compression-")
                || requirement.starts_with("exp-compression-")
            {
                let split = &mut requirement.splitn(3, '-');
                split.next();
                split.next();
                new = match split.next().unwrap() {
                    "zstd" => CompressionConfig::zstd(zstd_level)?,
                    e => {
                        return Err(HgError::UnsupportedFeature(format!(
                            "Unsupported compression engine '{e}'"
                        )))
                    }
                };
            }
        }
        if let Some(level) = zlib_level {
            if matches!(new, CompressionConfig::Zlib { .. }) {
                new.set_level(level as usize)?;
            }
        }
        Ok(new)
    }

    /// Sets the level of the current compression engine
    pub fn set_level(&mut self, new_level: usize) -> Result<(), HgError> {
        match self {
            CompressionConfig::Zlib { level } => {
                if new_level > 9 {
                    return Err(HgError::abort(
                        format!(
                            "invalid compression zlib compression level {}, \
                            expected between 0 and 9 included",
                            new_level
                        ),
                        exit_codes::ABORT,
                        None,
                    ));
                }
                *level = new_level as u8;
            }
            CompressionConfig::Zstd { level, .. } => {
                if new_level > 22 {
                    return Err(HgError::abort(
                        format!(
                            "invalid compression zstd compression level {}, \
                            expected between 0 and 22 included",
                            new_level
                        ),
                        exit_codes::ABORT,
                        None,
                    ));
                }
                *level = new_level as u8;
            }
            CompressionConfig::None => {}
        }
        Ok(())
    }

    /// Return a ZSTD compression config
    pub fn zstd(
        zstd_level: Option<u32>,
    ) -> Result<CompressionConfig, HgError> {
        let mut engine = CompressionConfig::Zstd {
            level: ZSTD_DEFAULT_LEVEL,
            threads: 0,
        };
        if let Some(level) = zstd_level {
            engine.set_level(level as usize)?;
        }
        Ok(engine)
    }
}

impl Default for CompressionConfig {
    fn default() -> Self {
        Self::Zlib {
            level: ZLIB_DEFAULT_LEVEL,
        }
    }
}

/// A high-level trait to define compressors that should be able to compress
/// and decompress arbitrary bytes.
pub trait Compressor: Send {
    /// Returns a new [`Vec`] with the compressed data.
    /// Should return `Ok(None)` if compression does not apply (e.g. too small)
    fn compress(
        &mut self,
        data: &[u8],
    ) -> Result<Option<Vec<u8>>, RevlogError>;
    /// Returns a new [`Vec`] with the decompressed data.
    fn decompress(&self, data: &[u8]) -> Result<Vec<u8>, RevlogError>;
}

/// A compressor that does nothing (useful in tests)
pub struct NoneCompressor;

impl Compressor for NoneCompressor {
    fn compress(
        &mut self,
        _data: &[u8],
    ) -> Result<Option<Vec<u8>>, RevlogError> {
        Ok(None)
    }

    fn decompress(&self, data: &[u8]) -> Result<Vec<u8>, RevlogError> {
        Ok(data.to_owned())
    }
}

/// A compressor for Zstandard
pub struct ZstdCompressor {
    /// Level of compression to use
    level: u8,
    /// How many threads are used (not implemented yet)
    threads: u8,
    /// The underlying zstd compressor
    compressor: zstd::bulk::Compressor<'static>,
}

impl ZstdCompressor {
    pub fn new(level: u8, threads: u8) -> Self {
        Self {
            level,
            threads,
            compressor: zstd::bulk::Compressor::new(level.into())
                .expect("invalid zstd arguments"),
        }
    }
}

impl Compressor for ZstdCompressor {
    fn compress(
        &mut self,
        data: &[u8],
    ) -> Result<Option<Vec<u8>>, RevlogError> {
        if self.threads != 0 {
            // TODO use a zstd builder + zstd cargo feature to support this
            unimplemented!("zstd parallel compression is not implemented");
        }
        if data.len() < MINIMUM_LENGTH_ZSTD {
            return Ok(None);
        }
        let level = self.level as i32;
        if data.len() <= 1000000 {
            let compressed = self.compressor.compress(data).map_err(|e| {
                corrupted(format!("revlog compress error: {}", e))
            })?;
            Ok(if compressed.len() < data.len() {
                Some(compressed)
            } else {
                None
            })
        } else {
            Ok(Some(zstd::stream::encode_all(data, level).map_err(
                |e| corrupted(format!("revlog compress error: {}", e)),
            )?))
        }
    }

    fn decompress(&self, data: &[u8]) -> Result<Vec<u8>, RevlogError> {
        zstd::stream::decode_all(data).map_err(|e| {
            corrupted(format!("revlog decompress error: {}", e)).into()
        })
    }
}

/// A compressor for Zlib
pub struct ZlibCompressor {
    /// Level of compression to use
    level: flate2::Compression,
}

impl ZlibCompressor {
    pub fn new(level: u8) -> Self {
        Self {
            level: flate2::Compression::new(level.into()),
        }
    }
}

impl Compressor for ZlibCompressor {
    fn compress(
        &mut self,
        data: &[u8],
    ) -> Result<Option<Vec<u8>>, RevlogError> {
        assert!(!data.is_empty());
        if data.len() < MINIMUM_LENGTH_ZLIB {
            return Ok(None);
        }
        let mut buf = Vec::with_capacity(data.len());
        ZlibEncoder::new(data, self.level)
            .read_to_end(&mut buf)
            .map_err(|e| corrupted(format!("revlog compress error: {}", e)))?;

        Ok(if buf.len() < data.len() {
            buf.shrink_to_fit();
            Some(buf)
        } else {
            None
        })
    }

    fn decompress(&self, data: &[u8]) -> Result<Vec<u8>, RevlogError> {
        let mut decoder = ZlibDecoder::new(data);
        // TODO reuse the allocation somehow?
        let mut buf = vec![];
        decoder.read_to_end(&mut buf).map_err(|e| {
            corrupted(format!("revlog decompress error: {}", e))
        })?;
        Ok(buf)
    }
}

thread_local! {
  // seems fine to [unwrap] here: this can only fail due to memory allocation
  // failing, and it's normal for that to cause panic.
  static ZSTD_DECODER : RefCell<zstd::bulk::Decompressor<'static>> =
      RefCell::new(zstd::bulk::Decompressor::new().ok().unwrap());
}

/// Util to wrap the reuse of a zstd decoder while controlling its buffer size.
fn zstd_decompress_to_buffer(
    bytes: &[u8],
    buf: &mut Vec<u8>,
) -> Result<usize, std::io::Error> {
    ZSTD_DECODER
        .with(|decoder| decoder.borrow_mut().decompress_to_buffer(bytes, buf))
}

/// Specialized revlog decompression to use less memory for deltas while
/// keeping performance acceptable.
pub(super) fn uncompressed_zstd_data(
    bytes: &[u8],
    is_delta: bool,
    uncompressed_len: i32,
) -> Result<Vec<u8>, HgError> {
    let cap = uncompressed_len.max(0) as usize;
    if is_delta {
        // [cap] is usually an over-estimate of the space needed because
        // it's the length of delta-decoded data, but we're interested
        // in the size of the delta.
        // This means we have to [shrink_to_fit] to avoid holding on
        // to a large chunk of memory, but it also means we must have a
        // fallback branch, for the case when the delta is longer than
        // the original data (surprisingly, this does happen in practice)
        let mut buf = Vec::with_capacity(cap);
        match zstd_decompress_to_buffer(bytes, &mut buf) {
            Ok(_) => buf.shrink_to_fit(),
            Err(_) => {
                buf.clear();
                zstd::stream::copy_decode(bytes, &mut buf)
                    .map_err(|e| corrupted(e.to_string()))?;
            }
        };
        Ok(buf)
    } else {
        let mut buf = Vec::with_capacity(cap);
        let len = zstd_decompress_to_buffer(bytes, &mut buf)
            .map_err(|e| corrupted(e.to_string()))?;
        if len != uncompressed_len as usize {
            Err(corrupted("uncompressed length does not match"))
        } else {
            Ok(buf)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LARGE_TEXT: &[u8] = b"
    Patali Dirapata, Cromda Cromda Ripalo, Pata Pata, Ko Ko Ko
    Bokoro Dipoulito, Rondi Rondi Pepino, Pata Pata, Ko Ko Ko
    Emana Karassoli, Loucra Loucra Nonponto, Pata Pata, Ko Ko Ko.";

    #[test]
    fn test_zlib_compressor() {
        // Can return `Ok(None)`
        let mut compressor = ZlibCompressor::new(1);
        assert_eq!(compressor.compress(b"too small").unwrap(), None);

        // Compression returns bytes
        let compressed_with_1 =
            compressor.compress(LARGE_TEXT).unwrap().unwrap();
        assert!(compressed_with_1.len() < LARGE_TEXT.len());
        // Round trip works
        assert_eq!(
            compressor.decompress(&compressed_with_1).unwrap(),
            LARGE_TEXT
        );

        // Compression levels mean something
        let mut compressor = ZlibCompressor::new(9);
        // Compression returns bytes
        let compressed = compressor.compress(LARGE_TEXT).unwrap().unwrap();
        assert!(compressed.len() < compressed_with_1.len());
    }

    #[test]
    fn test_zstd_compressor() {
        // Can return `Ok(None)`
        let mut compressor = ZstdCompressor::new(1, 0);
        assert_eq!(compressor.compress(b"too small").unwrap(), None);

        // Compression returns bytes
        let compressed_with_1 =
            compressor.compress(LARGE_TEXT).unwrap().unwrap();
        assert!(compressed_with_1.len() < LARGE_TEXT.len());
        // Round trip works
        assert_eq!(
            compressor.decompress(&compressed_with_1).unwrap(),
            LARGE_TEXT
        );

        // Compression levels mean something
        let mut compressor = ZstdCompressor::new(22, 0);
        // Compression returns bytes
        let compressed = compressor.compress(LARGE_TEXT).unwrap().unwrap();
        assert!(compressed.len() < compressed_with_1.len());
    }
}
