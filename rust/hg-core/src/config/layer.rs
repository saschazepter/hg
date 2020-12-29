// layer.rs
//
// Copyright 2020
//      Valentin Gatien-Baron,
//      Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use crate::utils::files::{
    get_bytes_from_path, get_path_from_bytes, read_whole_file,
};
use format_bytes::format_bytes;
use lazy_static::lazy_static;
use regex::bytes::Regex;
use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};

lazy_static! {
    static ref SECTION_RE: Regex = make_regex(r"^\[([^\[]+)\]");
    static ref ITEM_RE: Regex = make_regex(r"^([^=\s][^=]*?)\s*=\s*((.*\S)?)");
    /// Continuation whitespace
    static ref CONT_RE: Regex = make_regex(r"^\s+(\S|\S.*\S)\s*$");
    static ref EMPTY_RE: Regex = make_regex(r"^(;|#|\s*$)");
    static ref COMMENT_RE: Regex = make_regex(r"^(;|#)");
    /// A directive that allows for removing previous entries
    static ref UNSET_RE: Regex = make_regex(r"^%unset\s+(\S+)");
    /// A directive that allows for including other config files
    static ref INCLUDE_RE: Regex = make_regex(r"^%include\s+(\S|\S.*\S)\s*$");
}

/// All config values separated by layers of precedence.
/// Each config source may be split in multiple layers if `%include` directives
/// are used.
/// TODO detail the general precedence
#[derive(Clone)]
pub struct ConfigLayer {
    /// Mapping of the sections to their items
    sections: HashMap<Vec<u8>, ConfigItem>,
    /// All sections (and their items/values) in a layer share the same origin
    pub origin: ConfigOrigin,
    /// Whether this layer comes from a trusted user or group
    pub trusted: bool,
}

impl ConfigLayer {
    pub fn new(origin: ConfigOrigin) -> Self {
        ConfigLayer {
            sections: HashMap::new(),
            trusted: true, // TODO check
            origin,
        }
    }

    /// Add an entry to the config, overwriting the old one if already present.
    pub fn add(
        &mut self,
        section: Vec<u8>,
        item: Vec<u8>,
        value: Vec<u8>,
        line: Option<usize>,
    ) {
        self.sections
            .entry(section)
            .or_insert_with(|| HashMap::new())
            .insert(item, ConfigValue { bytes: value, line });
    }

    /// Returns the config value in `<section>.<item>` if it exists
    pub fn get(&self, section: &[u8], item: &[u8]) -> Option<&ConfigValue> {
        Some(self.sections.get(section)?.get(item)?)
    }

    pub fn is_empty(&self) -> bool {
        self.sections.is_empty()
    }

    /// Returns a `Vec` of layers in order of precedence (so, in read order),
    /// recursively parsing the `%include` directives if any.
    pub fn parse(src: &Path, data: &[u8]) -> Result<Vec<Self>, ConfigError> {
        let mut layers = vec![];

        // Discard byte order mark if any
        let data = if data.starts_with(b"\xef\xbb\xbf") {
            &data[3..]
        } else {
            data
        };

        // TODO check if it's trusted
        let mut current_layer = Self::new(ConfigOrigin::File(src.to_owned()));

        let mut lines_iter =
            data.split(|b| *b == b'\n').enumerate().peekable();
        let mut section = b"".to_vec();

        while let Some((index, bytes)) = lines_iter.next() {
            if let Some(m) = INCLUDE_RE.captures(&bytes) {
                let filename_bytes = &m[1];
                let filename_to_include = get_path_from_bytes(&filename_bytes);
                match read_include(&src, &filename_to_include) {
                    (include_src, Ok(data)) => {
                        layers.push(current_layer);
                        layers.extend(Self::parse(&include_src, &data)?);
                        current_layer =
                            Self::new(ConfigOrigin::File(src.to_owned()));
                    }
                    (_, Err(e)) => {
                        return Err(ConfigError::IncludeError {
                            path: filename_to_include.to_owned(),
                            io_error: e,
                        })
                    }
                }
            } else if let Some(_) = EMPTY_RE.captures(&bytes) {
            } else if let Some(m) = SECTION_RE.captures(&bytes) {
                section = m[1].to_vec();
            } else if let Some(m) = ITEM_RE.captures(&bytes) {
                let item = m[1].to_vec();
                let mut value = m[2].to_vec();
                loop {
                    match lines_iter.peek() {
                        None => break,
                        Some((_, v)) => {
                            if let Some(_) = COMMENT_RE.captures(&v) {
                            } else if let Some(_) = CONT_RE.captures(&v) {
                                value.extend(b"\n");
                                value.extend(&m[1]);
                            } else {
                                break;
                            }
                        }
                    };
                    lines_iter.next();
                }
                current_layer.add(
                    section.clone(),
                    item,
                    value,
                    Some(index + 1),
                );
            } else if let Some(m) = UNSET_RE.captures(&bytes) {
                if let Some(map) = current_layer.sections.get_mut(&section) {
                    map.remove(&m[1]);
                }
            } else {
                return Err(ConfigError::Parse {
                    origin: ConfigOrigin::File(src.to_owned()),
                    line: Some(index + 1),
                    bytes: bytes.to_owned(),
                });
            }
        }
        if !current_layer.is_empty() {
            layers.push(current_layer);
        }
        Ok(layers)
    }
}

impl std::fmt::Debug for ConfigLayer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut sections: Vec<_> = self.sections.iter().collect();
        sections.sort_by(|e0, e1| e0.0.cmp(e1.0));

        for (section, items) in sections.into_iter() {
            let mut items: Vec<_> = items.into_iter().collect();
            items.sort_by(|e0, e1| e0.0.cmp(e1.0));

            for (item, config_entry) in items {
                writeln!(
                    f,
                    "{}",
                    String::from_utf8_lossy(&format_bytes!(
                        b"{}.{}={} # {}",
                        section,
                        item,
                        &config_entry.bytes,
                        &self.origin.to_bytes(),
                    ))
                )?
            }
        }
        Ok(())
    }
}

/// Mapping of section item to value.
/// In the following:
/// ```text
/// [ui]
/// paginate=no
/// ```
/// "paginate" is the section item and "no" the value.
pub type ConfigItem = HashMap<Vec<u8>, ConfigValue>;

#[derive(Clone, Debug, PartialEq)]
pub struct ConfigValue {
    /// The raw bytes of the value (be it from the CLI, env or from a file)
    pub bytes: Vec<u8>,
    /// Only present if the value comes from a file, 1-indexed.
    pub line: Option<usize>,
}

#[derive(Clone, Debug)]
pub enum ConfigOrigin {
    /// The value comes from a configuration file
    File(PathBuf),
    /// The value comes from the environment like `$PAGER` or `$EDITOR`
    Environment(Vec<u8>),
    /* TODO cli
     * TODO defaults (configitems.py)
     * TODO extensions
     * TODO Python resources?
     * Others? */
}

impl ConfigOrigin {
    /// TODO use some kind of dedicated trait?
    pub fn to_bytes(&self) -> Vec<u8> {
        match self {
            ConfigOrigin::File(p) => get_bytes_from_path(p),
            ConfigOrigin::Environment(e) => e.to_owned(),
        }
    }
}

#[derive(Debug)]
pub enum ConfigError {
    Parse {
        origin: ConfigOrigin,
        line: Option<usize>,
        bytes: Vec<u8>,
    },
    /// Failed to include a sub config file
    IncludeError {
        path: PathBuf,
        io_error: std::io::Error,
    },
    /// Any IO error that isn't expected
    IO(std::io::Error),
}

impl From<std::io::Error> for ConfigError {
    fn from(e: std::io::Error) -> Self {
        Self::IO(e)
    }
}

fn make_regex(pattern: &'static str) -> Regex {
    Regex::new(pattern).expect("expected a valid regex")
}

/// Includes are relative to the file they're defined in, unless they're
/// absolute.
fn read_include(
    old_src: &Path,
    new_src: &Path,
) -> (PathBuf, io::Result<Vec<u8>>) {
    if new_src.is_absolute() {
        (new_src.to_path_buf(), read_whole_file(&new_src))
    } else {
        let dir = old_src.parent().unwrap();
        let new_src = dir.join(&new_src);
        (new_src.to_owned(), read_whole_file(&new_src))
    }
}
