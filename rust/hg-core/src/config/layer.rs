// layer.rs
//
// Copyright 2020
//      Valentin Gatien-Baron,
//      Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use std::collections::HashMap;
use std::path::Path;
use std::path::PathBuf;

use format_bytes::format_bytes;
use format_bytes::write_bytes;
use format_bytes::DisplayBytes;
use indexmap::IndexMap;
use lazy_static::lazy_static;
use regex::bytes::Regex;

use crate::errors::HgError;
use crate::exit_codes::CONFIG_ERROR_ABORT;
use crate::exit_codes::CONFIG_PARSE_ERROR_ABORT;
use crate::utils::files::get_bytes_from_path;
use crate::utils::files::get_path_from_bytes;

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

    /// Parse `--config` CLI arguments and return a layer if there’s any
    pub(crate) fn parse_cli_args(
        cli_config_args: impl IntoIterator<Item = impl AsRef<[u8]>>,
    ) -> Result<Option<Self>, ConfigError> {
        fn parse_one(arg: &[u8]) -> Option<(Vec<u8>, Vec<u8>, Vec<u8>)> {
            use crate::utils::strings::SliceExt;

            let (section_and_item, value) = arg.split_2(b'=')?;
            let (section, item) = section_and_item.trim().split_2(b'.')?;
            Some((section.to_owned(), item.to_owned(), value.trim().to_owned()))
        }

        let mut layer = Self::new(ConfigOrigin::CommandLine);
        for arg in cli_config_args {
            let arg = arg.as_ref();
            if let Some((section, item, value)) = parse_one(arg) {
                layer.add(section, item, value, None);
            } else {
                Err(HgError::abort(
                    format!(
                        "abort: malformed --config option: '{}' \
                    (use --config section.name=value)",
                        String::from_utf8_lossy(arg),
                    ),
                    CONFIG_PARSE_ERROR_ABORT,
                    None,
                ))?
            }
        }
        if layer.sections.is_empty() {
            Ok(None)
        } else {
            Ok(Some(layer))
        }
    }

    /// Returns whether this layer comes from `--config` CLI arguments
    pub(crate) fn is_from_command_line(&self) -> bool {
        matches!(self.origin, ConfigOrigin::CommandLine)
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
            .or_default()
            .insert(item, ConfigValue { bytes: value, line });
    }

    /// Returns the config value in `<section>.<item>` if it exists
    pub fn get(&self, section: &[u8], item: &[u8]) -> Option<&ConfigValue> {
        self.sections.get(section)?.get(item)
    }

    /// Returns the keys defined in the given section
    pub fn iter_keys(&self, section: &[u8]) -> impl Iterator<Item = &[u8]> {
        self.sections
            .get(section)
            .into_iter()
            .flat_map(|section| section.keys().map(|vec| &**vec))
    }

    /// Returns the (key, value) pairs defined in the given section from
    /// lowest to highest precedence.
    pub fn iter_section<'layer>(
        &'layer self,
        section: &[u8],
    ) -> impl Iterator<Item = (&'layer [u8], &'layer [u8])> {
        self.sections
            .get(section)
            .into_iter()
            .flat_map(|section| section.iter().map(|(k, v)| (&**k, &*v.bytes)))
    }

    /// Returns whether any key is defined in the given section
    pub fn has_non_empty_section(&self, section: &[u8]) -> bool {
        self.sections.get(section).is_some_and(|section| !section.is_empty())
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

        let mut lines_iter = data.split(|b| *b == b'\n').enumerate().peekable();
        let mut section = b"".to_vec();

        while let Some((index, bytes)) = lines_iter.next() {
            let line = Some(index + 1);
            if let Some(m) = INCLUDE_RE.captures(bytes) {
                let filename_bytes = &m[1];
                let filename_bytes =
                    crate::utils::strings::expand_vars(filename_bytes);
                // `Path::parent` only fails for the root directory,
                // which `src` can’t be since we’ve managed to open it as a
                // file.
                let dir = src
                    .parent()
                    .expect("Path::parent fail on a file we’ve read");
                // `Path::join` with an absolute argument correctly ignores the
                // base path
                let filename = dir.join(get_path_from_bytes(&filename_bytes));
                match std::fs::read(&filename) {
                    Ok(data) => {
                        layers.push(current_layer);
                        layers.extend(Self::parse(&filename, &data)?);
                        current_layer =
                            Self::new(ConfigOrigin::File(src.to_owned()));
                    }
                    Err(error) => {
                        if error.kind() != std::io::ErrorKind::NotFound {
                            return Err(ConfigParseError {
                                origin: ConfigOrigin::File(src.to_owned()),
                                line,
                                message: format_bytes!(
                                    b"cannot include {} ({})",
                                    filename_bytes,
                                    format_bytes::Utf8(error)
                                ),
                            }
                            .into());
                        }
                    }
                }
            } else if EMPTY_RE.captures(bytes).is_some() {
            } else if let Some(m) = SECTION_RE.captures(bytes) {
                section = m[1].to_vec();
            } else if let Some(m) = ITEM_RE.captures(bytes) {
                let item = m[1].to_vec();
                let mut value = m[2].to_vec();
                loop {
                    match lines_iter.peek() {
                        None => break,
                        Some((_, v)) => {
                            if COMMENT_RE.captures(v).is_some() {
                            } else if CONT_RE.captures(v).is_some() {
                                value.extend(b"\n");
                                value.extend(&m[1]);
                            } else {
                                break;
                            }
                        }
                    };
                    lines_iter.next();
                }
                current_layer.add(section.clone(), item, value, line);
            } else if let Some(m) = UNSET_RE.captures(bytes) {
                if let Some(map) = current_layer.sections.get_mut(&section) {
                    map.shift_remove(&m[1]);
                }
            } else {
                let message = if bytes.starts_with(b" ") {
                    format_bytes!(b"unexpected leading whitespace: {}", bytes)
                } else {
                    bytes.to_owned()
                };
                return Err(ConfigParseError {
                    origin: ConfigOrigin::File(src.to_owned()),
                    line,
                    message,
                }
                .into());
            }
        }
        if !current_layer.is_empty() {
            layers.push(current_layer);
        }
        Ok(layers)
    }
}

impl DisplayBytes for ConfigLayer {
    fn display_bytes(
        &self,
        out: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        let mut sections: Vec<_> = self.sections.iter().collect();
        sections.sort_by(|e0, e1| e0.0.cmp(e1.0));

        for (section, items) in sections.into_iter() {
            let mut items: Vec<_> = items.iter().collect();
            items.sort_by(|e0, e1| e0.0.cmp(e1.0));

            for (item, config_entry) in items {
                write_bytes!(
                    out,
                    b"{}.{}={} # {}\n",
                    section,
                    item,
                    &config_entry.bytes,
                    &self.origin,
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
/// Uses [`IndexMap`] to preserve insertion order.
pub type ConfigItem = IndexMap<Vec<u8>, ConfigValue>;

#[derive(Clone, Debug, PartialEq)]
pub struct ConfigValue {
    /// The raw bytes of the value (be it from the CLI, env or from a file)
    pub bytes: Vec<u8>,
    /// Only present if the value comes from a file, 1-indexed.
    pub line: Option<usize>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ConfigOrigin {
    /// From a configuration file
    File(PathBuf),
    /// From [ui.tweakdefaults]
    Tweakdefaults,
    /// From a `--config` CLI argument
    CommandLine,
    /// From a `--color` CLI argument
    CommandLineColor,
    /// From environment variables like `$PAGER` or `$EDITOR`
    Environment(Vec<u8>),
    /// From configitems.toml
    Defaults,
    /* TODO extensions
     * TODO Python resources?
     * Others? */
}

impl DisplayBytes for ConfigOrigin {
    fn display_bytes(
        &self,
        out: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        match self {
            ConfigOrigin::File(p) => out.write_all(&get_bytes_from_path(p)),
            ConfigOrigin::CommandLine => out.write_all(b"--config"),
            ConfigOrigin::CommandLineColor => out.write_all(b"--color"),
            ConfigOrigin::Environment(e) => write_bytes!(out, b"${}", e),
            ConfigOrigin::Tweakdefaults => {
                write_bytes!(out, b"ui.tweakdefaults")
            }
            ConfigOrigin::Defaults => write_bytes!(out, b"configitems.toml"),
        }
    }
}

#[derive(Debug)]
pub struct ConfigParseError {
    pub origin: ConfigOrigin,
    pub line: Option<usize>,
    pub message: Vec<u8>,
}

impl From<ConfigParseError> for HgError {
    fn from(error: ConfigParseError) -> Self {
        let ConfigParseError { origin, line, message } = error;
        let line_message = if let Some(line_number) = line {
            format_bytes!(b":{}", line_number.to_string().into_bytes())
        } else {
            Vec::new()
        };
        HgError::abort(
            String::from_utf8_lossy(&format_bytes!(
                b"config error at {}{}: {}",
                origin,
                line_message,
                message
            ))
            .to_string(),
            CONFIG_ERROR_ABORT,
            None,
        )
    }
}

#[derive(Debug, derive_more::From)]
pub enum ConfigError {
    Parse(ConfigParseError),
    Other(HgError),
}

impl From<ConfigError> for HgError {
    fn from(error: ConfigError) -> Self {
        match error {
            ConfigError::Parse(config_parse_error) => {
                Self::from(config_parse_error)
            }
            ConfigError::Other(hg_error) => hg_error,
        }
    }
}

fn make_regex(pattern: &'static str) -> Regex {
    Regex::new(pattern).expect("expected a valid regex")
}
