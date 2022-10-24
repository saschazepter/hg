// config.rs
//
// Copyright 2020
//      Valentin Gatien-Baron,
//      Raphaël Gomès <rgomes@octobus.net>
//
// This software may be used and distributed according to the terms of the
// GNU General Public License version 2 or any later version.

use super::layer;
use super::values;
use crate::config::layer::{
    ConfigError, ConfigLayer, ConfigOrigin, ConfigValue,
};
use crate::config::plain_info::PlainInfo;
use crate::utils::files::get_bytes_from_os_str;
use format_bytes::{write_bytes, DisplayBytes};
use std::collections::HashSet;
use std::env;
use std::fmt;
use std::path::{Path, PathBuf};
use std::str;

use crate::errors::{HgResultExt, IoResultExt};

/// Holds the config values for the current repository
/// TODO update this docstring once we support more sources
#[derive(Clone)]
pub struct Config {
    layers: Vec<layer::ConfigLayer>,
    plain: PlainInfo,
}

impl DisplayBytes for Config {
    fn display_bytes(
        &self,
        out: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        for (index, layer) in self.layers.iter().rev().enumerate() {
            write_bytes!(
                out,
                b"==== Layer {} (trusted: {}) ====\n{}",
                index,
                if layer.trusted {
                    &b"yes"[..]
                } else {
                    &b"no"[..]
                },
                layer
            )?;
        }
        Ok(())
    }
}

pub enum ConfigSource {
    /// Absolute path to a config file
    AbsPath(PathBuf),
    /// Already parsed (from the CLI, env, Python resources, etc.)
    Parsed(layer::ConfigLayer),
}

#[derive(Debug)]
pub struct ConfigValueParseError {
    pub origin: ConfigOrigin,
    pub line: Option<usize>,
    pub section: Vec<u8>,
    pub item: Vec<u8>,
    pub value: Vec<u8>,
    pub expected_type: &'static str,
}

impl fmt::Display for ConfigValueParseError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        // TODO: add origin and line number information, here and in
        // corresponding python code
        write!(
            f,
            "config error: {}.{} is not a {} ('{}')",
            String::from_utf8_lossy(&self.section),
            String::from_utf8_lossy(&self.item),
            self.expected_type,
            String::from_utf8_lossy(&self.value)
        )
    }
}

/// Returns true if the config item is disabled by PLAIN or PLAINEXCEPT
fn should_ignore(plain: &PlainInfo, section: &[u8], item: &[u8]) -> bool {
    // duplication with [_applyconfig] in [ui.py],
    if !plain.is_plain() {
        return false;
    }
    if section == b"alias" {
        return plain.plainalias();
    }
    if section == b"revsetalias" {
        return plain.plainrevsetalias();
    }
    if section == b"templatealias" {
        return plain.plaintemplatealias();
    }
    if section == b"ui" {
        let to_delete: &[&[u8]] = &[
            b"debug",
            b"fallbackencoding",
            b"quiet",
            b"slash",
            b"logtemplate",
            b"message-output",
            b"statuscopies",
            b"style",
            b"traceback",
            b"verbose",
        ];
        return to_delete.contains(&item);
    }
    let sections_to_delete: &[&[u8]] =
        &[b"defaults", b"commands", b"command-templates"];
    return sections_to_delete.contains(&section);
}

impl Config {
    /// The configuration to use when printing configuration-loading errors
    pub fn empty() -> Self {
        Self {
            layers: Vec::new(),
            plain: PlainInfo::empty(),
        }
    }

    /// Load system and user configuration from various files.
    ///
    /// This is also affected by some environment variables.
    pub fn load_non_repo() -> Result<Self, ConfigError> {
        let mut config = Self::empty();
        let opt_rc_path = env::var_os("HGRCPATH");
        // HGRCPATH replaces system config
        if opt_rc_path.is_none() {
            config.add_system_config()?
        }

        config.add_for_environment_variable("EDITOR", b"ui", b"editor");
        config.add_for_environment_variable("VISUAL", b"ui", b"editor");
        config.add_for_environment_variable("PAGER", b"pager", b"pager");

        // These are set by `run-tests.py --rhg` to enable fallback for the
        // entire test suite. Alternatives would be setting configuration
        // through `$HGRCPATH` but some tests override that, or changing the
        // `hg` shell alias to include `--config` but that disrupts tests that
        // print command lines and check expected output.
        config.add_for_environment_variable(
            "RHG_ON_UNSUPPORTED",
            b"rhg",
            b"on-unsupported",
        );
        config.add_for_environment_variable(
            "RHG_FALLBACK_EXECUTABLE",
            b"rhg",
            b"fallback-executable",
        );

        // HGRCPATH replaces user config
        if opt_rc_path.is_none() {
            config.add_user_config()?
        }
        if let Some(rc_path) = &opt_rc_path {
            for path in env::split_paths(rc_path) {
                if !path.as_os_str().is_empty() {
                    if path.is_dir() {
                        config.add_trusted_dir(&path)?
                    } else {
                        config.add_trusted_file(&path)?
                    }
                }
            }
        }
        Ok(config)
    }

    pub fn load_cli_args(
        &mut self,
        cli_config_args: impl IntoIterator<Item = impl AsRef<[u8]>>,
        color_arg: Option<Vec<u8>>,
    ) -> Result<(), ConfigError> {
        if let Some(layer) = ConfigLayer::parse_cli_args(cli_config_args)? {
            self.layers.push(layer)
        }
        if let Some(arg) = color_arg {
            let mut layer = ConfigLayer::new(ConfigOrigin::CommandLineColor);
            layer.add(b"ui"[..].into(), b"color"[..].into(), arg, None);
            self.layers.push(layer)
        }
        Ok(())
    }

    fn add_trusted_dir(&mut self, path: &Path) -> Result<(), ConfigError> {
        if let Some(entries) = std::fs::read_dir(path)
            .when_reading_file(path)
            .io_not_found_as_none()?
        {
            let mut file_paths = entries
                .map(|result| {
                    result.when_reading_file(path).map(|entry| entry.path())
                })
                .collect::<Result<Vec<_>, _>>()?;
            file_paths.sort();
            for file_path in &file_paths {
                if file_path.extension() == Some(std::ffi::OsStr::new("rc")) {
                    self.add_trusted_file(&file_path)?
                }
            }
        }
        Ok(())
    }

    fn add_trusted_file(&mut self, path: &Path) -> Result<(), ConfigError> {
        if let Some(data) = std::fs::read(path)
            .when_reading_file(path)
            .io_not_found_as_none()?
        {
            self.layers.extend(ConfigLayer::parse(path, &data)?)
        }
        Ok(())
    }

    fn add_for_environment_variable(
        &mut self,
        var: &str,
        section: &[u8],
        key: &[u8],
    ) {
        if let Some(value) = env::var_os(var) {
            let origin = layer::ConfigOrigin::Environment(var.into());
            let mut layer = ConfigLayer::new(origin);
            layer.add(
                section.to_owned(),
                key.to_owned(),
                get_bytes_from_os_str(value),
                None,
            );
            self.layers.push(layer)
        }
    }

    #[cfg(unix)] // TODO: other platforms
    fn add_system_config(&mut self) -> Result<(), ConfigError> {
        let mut add_for_prefix = |prefix: &Path| -> Result<(), ConfigError> {
            let etc = prefix.join("etc").join("mercurial");
            self.add_trusted_file(&etc.join("hgrc"))?;
            self.add_trusted_dir(&etc.join("hgrc.d"))
        };
        let root = Path::new("/");
        // TODO: use `std::env::args_os().next().unwrap()` a.k.a. argv[0]
        // instead? TODO: can this be a relative path?
        let hg = crate::utils::current_exe()?;
        // TODO: this order (per-installation then per-system) matches
        // `systemrcpath()` in `mercurial/scmposix.py`, but
        // `mercurial/helptext/config.txt` suggests it should be reversed
        if let Some(installation_prefix) = hg.parent().and_then(Path::parent) {
            if installation_prefix != root {
                add_for_prefix(&installation_prefix)?
            }
        }
        add_for_prefix(root)?;
        Ok(())
    }

    #[cfg(unix)] // TODO: other plateforms
    fn add_user_config(&mut self) -> Result<(), ConfigError> {
        let opt_home = home::home_dir();
        if let Some(home) = &opt_home {
            self.add_trusted_file(&home.join(".hgrc"))?
        }
        let darwin = cfg!(any(target_os = "macos", target_os = "ios"));
        if !darwin {
            if let Some(config_home) = env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .or_else(|| opt_home.map(|home| home.join(".config")))
            {
                self.add_trusted_file(&config_home.join("hg").join("hgrc"))?
            }
        }
        Ok(())
    }

    /// Loads in order, which means that the precedence is the same
    /// as the order of `sources`.
    pub fn load_from_explicit_sources(
        sources: Vec<ConfigSource>,
    ) -> Result<Self, ConfigError> {
        let mut layers = vec![];

        for source in sources.into_iter() {
            match source {
                ConfigSource::Parsed(c) => layers.push(c),
                ConfigSource::AbsPath(c) => {
                    // TODO check if it should be trusted
                    // mercurial/ui.py:427
                    let data = match std::fs::read(&c) {
                        Err(_) => continue, // same as the python code
                        Ok(data) => data,
                    };
                    layers.extend(ConfigLayer::parse(&c, &data)?)
                }
            }
        }

        Ok(Config {
            layers,
            plain: PlainInfo::empty(),
        })
    }

    /// Loads the per-repository config into a new `Config` which is combined
    /// with `self`.
    pub(crate) fn combine_with_repo(
        &self,
        repo_config_files: &[PathBuf],
    ) -> Result<Self, ConfigError> {
        let (cli_layers, other_layers) = self
            .layers
            .iter()
            .cloned()
            .partition(ConfigLayer::is_from_command_line);

        let mut repo_config = Self {
            layers: other_layers,
            plain: PlainInfo::empty(),
        };
        for path in repo_config_files {
            // TODO: check if this file should be trusted:
            // `mercurial/ui.py:427`
            repo_config.add_trusted_file(path)?;
        }
        repo_config.layers.extend(cli_layers);
        Ok(repo_config)
    }

    pub fn apply_plain(&mut self, plain: PlainInfo) {
        self.plain = plain;
    }

    fn get_parse<'config, T: 'config>(
        &'config self,
        section: &[u8],
        item: &[u8],
        expected_type: &'static str,
        parse: impl Fn(&'config [u8]) -> Option<T>,
    ) -> Result<Option<T>, ConfigValueParseError> {
        match self.get_inner(&section, &item) {
            Some((layer, v)) => match parse(&v.bytes) {
                Some(b) => Ok(Some(b)),
                None => Err(ConfigValueParseError {
                    origin: layer.origin.to_owned(),
                    line: v.line,
                    value: v.bytes.to_owned(),
                    section: section.to_owned(),
                    item: item.to_owned(),
                    expected_type,
                }),
            },
            None => Ok(None),
        }
    }

    /// Returns an `Err` if the first value found is not a valid UTF-8 string.
    /// Otherwise, returns an `Ok(value)` if found, or `None`.
    pub fn get_str(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Result<Option<&str>, ConfigValueParseError> {
        self.get_parse(section, item, "ASCII or UTF-8 string", |value| {
            str::from_utf8(value).ok()
        })
    }

    /// Returns an `Err` if the first value found is not a valid unsigned
    /// integer. Otherwise, returns an `Ok(value)` if found, or `None`.
    pub fn get_u32(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Result<Option<u32>, ConfigValueParseError> {
        self.get_parse(section, item, "valid integer", |value| {
            str::from_utf8(value).ok()?.parse().ok()
        })
    }

    /// Returns an `Err` if the first value found is not a valid file size
    /// value such as `30` (default unit is bytes), `7 MB`, or `42.5 kb`.
    /// Otherwise, returns an `Ok(value_in_bytes)` if found, or `None`.
    pub fn get_byte_size(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Result<Option<u64>, ConfigValueParseError> {
        self.get_parse(section, item, "byte quantity", values::parse_byte_size)
    }

    /// Returns an `Err` if the first value found is not a valid boolean.
    /// Otherwise, returns an `Ok(option)`, where `option` is the boolean if
    /// found, or `None`.
    pub fn get_option(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Result<Option<bool>, ConfigValueParseError> {
        self.get_parse(section, item, "boolean", values::parse_bool)
    }

    /// Returns the corresponding boolean in the config. Returns `Ok(false)`
    /// if the value is not found, an `Err` if it's not a valid boolean.
    pub fn get_bool(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Result<bool, ConfigValueParseError> {
        Ok(self.get_option(section, item)?.unwrap_or(false))
    }

    /// Returns `true` if the extension is enabled, `false` otherwise
    pub fn is_extension_enabled(&self, extension: &[u8]) -> bool {
        let value = self.get(b"extensions", extension);
        match value {
            Some(c) => !c.starts_with(b"!"),
            None => false,
        }
    }

    /// If there is an `item` value in `section`, parse and return a list of
    /// byte strings.
    pub fn get_list(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Option<Vec<Vec<u8>>> {
        self.get(section, item).map(values::parse_list)
    }

    /// Returns the raw value bytes of the first one found, or `None`.
    pub fn get(&self, section: &[u8], item: &[u8]) -> Option<&[u8]> {
        self.get_inner(section, item)
            .map(|(_, value)| value.bytes.as_ref())
    }

    /// Returns the raw value bytes of the first one found, or `None`.
    pub fn get_with_origin(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Option<(&[u8], &ConfigOrigin)> {
        self.get_inner(section, item)
            .map(|(layer, value)| (value.bytes.as_ref(), &layer.origin))
    }

    /// Returns the layer and the value of the first one found, or `None`.
    fn get_inner(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Option<(&ConfigLayer, &ConfigValue)> {
        // Filter out the config items that are hidden by [PLAIN].
        // This differs from python hg where we delete them from the config.
        let should_ignore = should_ignore(&self.plain, &section, &item);
        for layer in self.layers.iter().rev() {
            if !layer.trusted {
                continue;
            }
            //The [PLAIN] config should not affect the defaults.
            //
            // However, PLAIN should also affect the "tweaked" defaults (unless
            // "tweakdefault" is part of "HGPLAINEXCEPT").
            //
            // In practice the tweak-default layer is only added when it is
            // relevant, so we can safely always take it into
            // account here.
            if should_ignore && !(layer.origin == ConfigOrigin::Tweakdefaults)
            {
                continue;
            }
            if let Some(v) = layer.get(&section, &item) {
                return Some((&layer, v));
            }
        }
        None
    }

    /// Return all keys defined for the given section
    pub fn get_section_keys(&self, section: &[u8]) -> HashSet<&[u8]> {
        self.layers
            .iter()
            .flat_map(|layer| layer.iter_keys(section))
            .collect()
    }

    /// Returns whether any key is defined in the given section
    pub fn has_non_empty_section(&self, section: &[u8]) -> bool {
        self.layers
            .iter()
            .any(|layer| layer.has_non_empty_section(section))
    }

    /// Yields (key, value) pairs for everything in the given section
    pub fn iter_section<'a>(
        &'a self,
        section: &'a [u8],
    ) -> impl Iterator<Item = (&[u8], &[u8])> + 'a {
        // TODO: Use `Iterator`’s `.peekable()` when its `peek_mut` is
        // available:
        // https://doc.rust-lang.org/nightly/std/iter/struct.Peekable.html#method.peek_mut
        struct Peekable<I: Iterator> {
            iter: I,
            /// Remember a peeked value, even if it was None.
            peeked: Option<Option<I::Item>>,
        }

        impl<I: Iterator> Peekable<I> {
            fn new(iter: I) -> Self {
                Self { iter, peeked: None }
            }

            fn next(&mut self) {
                self.peeked = None
            }

            fn peek_mut(&mut self) -> Option<&mut I::Item> {
                let iter = &mut self.iter;
                self.peeked.get_or_insert_with(|| iter.next()).as_mut()
            }
        }

        // Deduplicate keys redefined in multiple layers
        let mut keys_already_seen = HashSet::new();
        let mut key_is_new =
            move |&(key, _value): &(&'a [u8], &'a [u8])| -> bool {
                keys_already_seen.insert(key)
            };
        // This is similar to `flat_map` + `filter_map`, except with a single
        // closure that owns `key_is_new` (and therefore the
        // `keys_already_seen` set):
        let mut layer_iters = Peekable::new(
            self.layers
                .iter()
                .rev()
                .map(move |layer| layer.iter_section(section)),
        );
        std::iter::from_fn(move || loop {
            if let Some(pair) = layer_iters.peek_mut()?.find(&mut key_is_new) {
                return Some(pair);
            } else {
                layer_iters.next();
            }
        })
    }

    /// Get raw values bytes from all layers (even untrusted ones) in order
    /// of precedence.
    #[cfg(test)]
    fn get_all(&self, section: &[u8], item: &[u8]) -> Vec<&[u8]> {
        let mut res = vec![];
        for layer in self.layers.iter().rev() {
            if let Some(v) = layer.get(&section, &item) {
                res.push(v.bytes.as_ref());
            }
        }
        res
    }

    // a config layer that's introduced by ui.tweakdefaults
    fn tweakdefaults_layer() -> ConfigLayer {
        let mut layer = ConfigLayer::new(ConfigOrigin::Tweakdefaults);

        let mut add = |section: &[u8], item: &[u8], value: &[u8]| {
            layer.add(
                section[..].into(),
                item[..].into(),
                value[..].into(),
                None,
            );
        };
        // duplication of [tweakrc] from [ui.py]
        add(b"ui", b"rollback", b"False");
        add(b"ui", b"statuscopies", b"yes");
        add(b"ui", b"interface", b"curses");
        add(b"ui", b"relative-paths", b"yes");
        add(b"commands", b"grep.all-files", b"True");
        add(b"commands", b"update.check", b"noconflict");
        add(b"commands", b"status.verbose", b"True");
        add(b"commands", b"resolve.explicit-re-merge", b"True");
        add(b"git", b"git", b"1");
        add(b"git", b"showfunc", b"1");
        add(b"git", b"word-diff", b"1");
        return layer;
    }

    // introduce the tweaked defaults as implied by ui.tweakdefaults
    pub fn tweakdefaults<'a>(&mut self) -> () {
        self.layers.insert(0, Config::tweakdefaults_layer());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use std::fs::File;
    use std::io::Write;

    #[test]
    fn test_include_layer_ordering() {
        let tmpdir = tempfile::tempdir().unwrap();
        let tmpdir_path = tmpdir.path();
        let mut included_file =
            File::create(&tmpdir_path.join("included.rc")).unwrap();

        included_file.write_all(b"[section]\nitem=value1").unwrap();
        let base_config_path = tmpdir_path.join("base.rc");
        let mut config_file = File::create(&base_config_path).unwrap();
        let data =
            b"[section]\nitem=value0\n%include included.rc\nitem=value2\n\
              [section2]\ncount = 4\nsize = 1.5 KB\nnot-count = 1.5\nnot-size = 1 ub";
        config_file.write_all(data).unwrap();

        let sources = vec![ConfigSource::AbsPath(base_config_path)];
        let config = Config::load_from_explicit_sources(sources)
            .expect("expected valid config");

        let (_, value) = config.get_inner(b"section", b"item").unwrap();
        assert_eq!(
            value,
            &ConfigValue {
                bytes: b"value2".to_vec(),
                line: Some(4)
            }
        );

        let value = config.get(b"section", b"item").unwrap();
        assert_eq!(value, b"value2",);
        assert_eq!(
            config.get_all(b"section", b"item"),
            [b"value2", b"value1", b"value0"]
        );

        assert_eq!(config.get_u32(b"section2", b"count").unwrap(), Some(4));
        assert_eq!(
            config.get_byte_size(b"section2", b"size").unwrap(),
            Some(1024 + 512)
        );
        assert!(config.get_u32(b"section2", b"not-count").is_err());
        assert!(config.get_byte_size(b"section2", b"not-size").is_err());
    }
}
