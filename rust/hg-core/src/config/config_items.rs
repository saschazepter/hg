//! Code for parsing default Mercurial config items.
use format_bytes::format_bytes;
use serde::Deserialize;

use crate::FastHashMap;
use crate::errors::HgError;
use crate::exit_codes;

/// Corresponds to the structure of `mercurial/configitems.toml`.
#[derive(Debug, Deserialize)]
struct ConfigItems {
    items: Vec<DefaultConfigItem>,
    templates: FastHashMap<String, Vec<TemplateItem>>,
    #[serde(rename = "template-applications")]
    template_applications: Vec<TemplateApplication>,
}

/// Corresponds to a config item declaration in `mercurial/configitems.toml`.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(try_from = "RawDefaultConfigItem")]
pub struct DefaultConfigItem {
    /// Section of the config the item is in (e.g. `[merge-tools]`)
    section: Vec<u8>,
    /// Name of the item (e.g. `meld.gui`)
    name: Vec<u8>,
    /// Default value (can be dynamic, see [`DefaultConfigItemType`])
    default: Option<DefaultConfigItemType>,
    /// If the config option is generic (e.g. `merge-tools.*`), defines
    /// the priority of this item relative to other generic items.
    /// If we're looking for `<pattern>`, then all generic items within the
    /// same section will be sorted by order of priority, and the first
    /// regex match against `name` is returned.
    #[serde(default)]
    priority: Option<isize>,
    /// Aliases, if any. Each alias is a tuple of `(section, name)` for each
    /// option that is aliased to this one.
    #[serde(default)]
    alias: Vec<(Vec<u8>, Vec<u8>)>,
    /// Whether the config item is marked as experimental
    #[serde(default)]
    experimental: bool,
    /// The (possibly empty) docstring for the item
    #[serde(default)]
    documentation: Vec<u8>,
    /// Whether the item is part of an in-core extension. This allows us to
    /// hide them if the extension is not enabled, to preserve legacy
    /// behavior.
    #[serde(default)]
    in_core_extension: Option<Vec<u8>>,
}

/// Corresponds to the raw (i.e. on disk) structure of config items. Used as
/// an intermediate step in deserialization.
#[derive(Clone, Debug, Deserialize)]
struct RawDefaultConfigItem {
    section: String,
    name: String,
    default: Option<toml::Value>,
    #[serde(rename = "default-type")]
    default_type: Option<String>,
    #[serde(default)]
    priority: isize,
    #[serde(default)]
    generic: bool,
    #[serde(default)]
    alias: Vec<(String, String)>,
    #[serde(default)]
    experimental: bool,
    #[serde(default)]
    documentation: String,
    #[serde(default)]
    in_core_extension: Option<String>,
}

impl TryFrom<RawDefaultConfigItem> for DefaultConfigItem {
    type Error = HgError;

    fn try_from(value: RawDefaultConfigItem) -> Result<Self, Self::Error> {
        Ok(Self {
            section: value.section.into_bytes(),
            name: value.name.into_bytes(),
            default: raw_default_to_concrete(
                value.default_type,
                value.default,
            )?,
            priority: if value.generic {
                Some(value.priority)
            } else {
                None
            },
            alias: value
                .alias
                .into_iter()
                .map(|(section, name)| {
                    (section.into_bytes(), name.into_bytes())
                })
                .collect(),
            experimental: value.experimental,
            documentation: value.documentation.into_bytes(),
            in_core_extension: value.in_core_extension.map(String::into_bytes),
        })
    }
}

impl DefaultConfigItem {
    fn is_generic(&self) -> bool {
        self.priority.is_some()
    }

    pub fn in_core_extension(&self) -> Option<&[u8]> {
        self.in_core_extension.as_deref()
    }

    pub fn section(&self) -> &[u8] {
        self.section.as_ref()
    }
}

impl<'a> TryFrom<&'a DefaultConfigItem> for Option<&'a str> {
    type Error = HgError;

    fn try_from(
        value: &'a DefaultConfigItem,
    ) -> Result<Option<&'a str>, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for '&str', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::String(
                        s,
                    )) => Ok(Some(s)),
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

impl<'a> TryFrom<&'a DefaultConfigItem> for Option<&'a [u8]> {
    type Error = HgError;

    fn try_from(
        value: &'a DefaultConfigItem,
    ) -> Result<Option<&'a [u8]>, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for bytes, type of default is '{}', \
                        which cannot be interpreted as bytes",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(p) => {
                        Ok(p.as_str().map(str::as_bytes))
                    }
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

impl TryFrom<&DefaultConfigItem> for Option<bool> {
    type Error = HgError;

    fn try_from(value: &DefaultConfigItem) -> Result<Self, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'bool', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::Boolean(
                        b,
                    )) => Ok(Some(*b)),
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

impl TryFrom<&DefaultConfigItem> for Option<u32> {
    type Error = HgError;

    fn try_from(value: &DefaultConfigItem) -> Result<Self, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'u32', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::Integer(
                        b,
                    )) => {
                        Ok(Some((*b).try_into().expect("TOML integer to u32")))
                    }
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

impl TryFrom<&DefaultConfigItem> for Option<u64> {
    type Error = HgError;

    fn try_from(value: &DefaultConfigItem) -> Result<Self, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'u64', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::Integer(
                        b,
                    )) => {
                        Ok(Some((*b).try_into().expect("TOML integer to u64")))
                    }
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

impl TryFrom<&DefaultConfigItem> for Option<i64> {
    type Error = HgError;

    fn try_from(value: &DefaultConfigItem) -> Result<Self, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'i64', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::Integer(
                        b,
                    )) => Ok(Some(*b)),
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

impl TryFrom<&DefaultConfigItem> for Option<f64> {
    type Error = HgError;

    fn try_from(value: &DefaultConfigItem) -> Result<Self, Self::Error> {
        match &value.default {
            Some(default) => {
                let err = HgError::abort(
                    format!(
                        "programming error: wrong query on config item '{}.{}'",
                        String::from_utf8_lossy(&value.section),
                        String::from_utf8_lossy(&value.name)
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'f64', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::Float(b)) => {
                        Ok(Some(*b))
                    }
                    _ => Err(err),
                }
            }
            None => Ok(None),
        }
    }
}

/// Allows abstracting over more complex default values than just primitives.
/// The former `configitems.py` contained some dynamic code that is encoded
/// in this enum.
#[derive(Debug, PartialEq, Clone, Deserialize)]
pub enum DefaultConfigItemType {
    /// Some primitive type (string, integer, boolean)
    Primitive(toml::Value),
    /// A dynamic value that will be given by the code at runtime
    Dynamic,
    /// An lazily-returned array (possibly only relevant in the Python impl)
    /// Example: `lambda: [b"zstd", b"zlib"]`
    Lambda(Vec<String>),
    /// For now, a special case for `web.encoding` that points to the
    /// `encoding.encoding` module in the Python impl so that local encoding
    /// is correctly resolved at runtime
    LazyModule(String),
    ListType,
}

impl DefaultConfigItemType {
    pub fn type_str(&self) -> &str {
        match self {
            DefaultConfigItemType::Primitive(primitive) => primitive.type_str(),
            DefaultConfigItemType::Dynamic => "dynamic",
            DefaultConfigItemType::Lambda(_) => "lambda",
            DefaultConfigItemType::LazyModule(_) => "lazy_module",
            DefaultConfigItemType::ListType => "list_type",
        }
    }
}

/// Most of the fields are shared with [`DefaultConfigItem`].
#[derive(Debug, Clone, Deserialize)]
#[serde(try_from = "RawTemplateItem")]
struct TemplateItem {
    suffix: Vec<u8>,
    default: Option<DefaultConfigItemType>,
    priority: Option<isize>,
    #[serde(default)]
    alias: Vec<(Vec<u8>, Vec<u8>)>,
    #[serde(default)]
    experimental: bool,
    #[serde(default)]
    documentation: Vec<u8>,
}

/// Corresponds to the raw (i.e. on disk) representation of a template item.
/// Used as an intermediate step in deserialization.
#[derive(Clone, Debug, Deserialize)]
struct RawTemplateItem {
    suffix: String,
    default: Option<toml::Value>,
    #[serde(rename = "default-type")]
    default_type: Option<String>,
    #[serde(default)]
    priority: isize,
    #[serde(default)]
    generic: bool,
    #[serde(default)]
    alias: Vec<(String, String)>,
    #[serde(default)]
    experimental: bool,
    #[serde(default)]
    documentation: String,
}

impl TemplateItem {
    fn into_default_item(
        self,
        application: TemplateApplication,
    ) -> DefaultConfigItem {
        DefaultConfigItem {
            section: application.section,
            name: match application.prefix {
                Some(prefix) => {
                    format_bytes!(b"{}.{}", prefix, self.suffix)
                }
                None => self.suffix,
            },
            default: self.default,
            priority: self.priority,
            alias: self.alias,
            experimental: self.experimental,
            documentation: self.documentation,
            in_core_extension: None,
        }
    }
}

impl TryFrom<RawTemplateItem> for TemplateItem {
    type Error = HgError;

    fn try_from(value: RawTemplateItem) -> Result<Self, Self::Error> {
        Ok(Self {
            suffix: value.suffix.into_bytes(),
            default: raw_default_to_concrete(
                value.default_type,
                value.default,
            )?,
            priority: if value.generic {
                Some(value.priority)
            } else {
                None
            },
            alias: value
                .alias
                .into_iter()
                .map(|(section, name)| {
                    (section.into_bytes(), name.into_bytes())
                })
                .collect(),
            experimental: value.experimental,
            documentation: value.documentation.into_bytes(),
        })
    }
}

/// Transforms the on-disk string-based representation of complex default types
/// to the concrete [`DefaultconfigItemType`].
fn raw_default_to_concrete(
    default_type: Option<String>,
    default: Option<toml::Value>,
) -> Result<Option<DefaultConfigItemType>, HgError> {
    Ok(match default_type.as_deref() {
        None => default.as_ref().map(|default| {
            DefaultConfigItemType::Primitive(default.to_owned())
        }),
        Some("dynamic") => Some(DefaultConfigItemType::Dynamic),
        Some("list_type") => Some(DefaultConfigItemType::ListType),
        Some("lambda") => match &default {
            Some(default) => Some(DefaultConfigItemType::Lambda(
                default.to_owned().try_into().map_err(|e| {
                    HgError::abort(
                        e.to_string(),
                        exit_codes::ABORT,
                        Some("Check 'mercurial/configitems.toml'".into()),
                    )
                })?,
            )),
            None => {
                return Err(HgError::abort(
                    "lambda defined with no return value".to_string(),
                    exit_codes::ABORT,
                    Some("Check 'mercurial/configitems.toml'".into()),
                ));
            }
        },
        Some("lazy_module") => match &default {
            Some(default) => {
                Some(DefaultConfigItemType::LazyModule(match default {
                    toml::Value::String(module) => module.to_owned(),
                    _ => {
                        return Err(HgError::abort(
                            "lazy_module module name should be a string"
                                .to_string(),
                            exit_codes::ABORT,
                            Some("Check 'mercurial/configitems.toml'".into()),
                        ));
                    }
                }))
            }
            None => {
                return Err(HgError::abort(
                    "lazy_module should have a default value".to_string(),
                    exit_codes::ABORT,
                    Some("Check 'mercurial/configitems.toml'".into()),
                ));
            }
        },
        Some(invalid) => {
            return Err(HgError::abort(
                format!("invalid default_type '{}'", invalid),
                exit_codes::ABORT,
                Some("Check 'mercurial/configitems.toml'".into()),
            ));
        }
    })
}

#[derive(Debug, Clone, Deserialize)]
#[serde(from = "RawTemplateApplication")]
struct TemplateApplication {
    /// Name of the applied template, a purely internal cross-reference
    /// within the TOML file, hence not bytes.
    template: String,
    section: Vec<u8>,
    prefix: Option<Vec<u8>>,
}

/// Corresponds to the raw (i.e. on disk) structure of a template
/// application. Used as an intermediate step in deserialization.
#[derive(Debug, Deserialize)]
struct RawTemplateApplication {
    template: String,
    section: String,
    #[serde(default)]
    prefix: Option<String>,
}

impl From<RawTemplateApplication> for TemplateApplication {
    fn from(value: RawTemplateApplication) -> Self {
        Self {
            template: value.template,
            section: value.section.into_bytes(),
            prefix: value.prefix.map(String::into_bytes),
        }
    }
}

/// The default config items of a single section
///
/// Exists to simplify the plain / generic split of items.
#[derive(Clone, Debug, Default)]
struct DefaultConfigSection {
    /// The plain items (matched by exact name), by name.
    plain: FastHashMap<Vec<u8>, DefaultConfigItem>,
    /// The generic items (matched by regex).
    ///
    /// Sorted by `(priority, name)`, i.e. in matching order.
    generics: Vec<(regex::bytes::Regex, DefaultConfigItem)>,
}

/// Represents the (dynamic) set of default core Mercurial config items from
/// `mercurial/configitems.toml`.
#[derive(Clone, Debug, Default)]
pub struct DefaultConfig {
    /// Mapping of section -> the default items of that section
    items: FastHashMap<Vec<u8>, DefaultConfigSection>,
}

impl DefaultConfig {
    pub fn empty() -> DefaultConfig {
        Self { items: Default::default() }
    }

    /// Returns `Self`, given the contents of `mercurial/configitems.toml`
    #[tracing::instrument(level = "debug", skip_all, name = "configitems.toml")]
    pub fn from_contents(contents: &str) -> Result<Self, HgError> {
        let mut from_file: ConfigItems =
            toml::from_str(contents).map_err(|e| {
                HgError::abort(
                    e.to_string(),
                    exit_codes::ABORT,
                    Some("Check 'mercurial/configitems.toml'".into()),
                )
            })?;

        let mut flat_items = from_file.items;

        for application in from_file.template_applications.drain(..) {
            match from_file.templates.get(&application.template) {
                None => {
                    return Err(HgError::abort(
                        format!(
                            "template application refers to undefined template '{}'",
                            application.template
                        ),
                        exit_codes::ABORT,
                        Some("Check 'mercurial/configitems.toml'".into()),
                    ));
                }
                Some(template_items) => {
                    for template_item in template_items {
                        flat_items.push(
                            template_item
                                .clone()
                                .into_default_item(application.clone()),
                        )
                    }
                }
            };
        }

        let mut items: FastHashMap<Vec<u8>, DefaultConfigSection> =
            FastHashMap::default();
        // Some generic config names like `.*` and `[^:]+` are used multiple
        // times. Measurements showed that caching them is faster than
        // rebuilding.
        let mut compiled: FastHashMap<Vec<u8>, regex::bytes::Regex> =
            FastHashMap::default();
        for item in flat_items {
            let section = items.entry(item.section.clone()).or_default();
            if item.is_generic() {
                let regex = match compiled.get(&item.name) {
                    Some(regex) => regex.clone(),
                    None => {
                        // generic patterns expect rooted matching
                        // (because Python's `re.match` works that way).
                        let pattern = format!(
                            r"^(?:{})",
                            String::from_utf8_lossy(&item.name)
                        );
                        let regex = regex::bytes::RegexBuilder::new(&pattern)
                            .unicode(false) // `.` should match any byte
                            .build()
                            .map_err(|e| {
                                HgError::abort(
                                    format!(
                                        "invalid pattern for config \
                                         item '{}.{}': {}",
                                        String::from_utf8_lossy(&item.section),
                                        String::from_utf8_lossy(&item.name),
                                        e
                                    ),
                                    exit_codes::ABORT,
                                    Some(
                                        "Check 'mercurial/configitems.toml'"
                                            .into(),
                                    ),
                                )
                            })?;
                        compiled.insert(item.name.clone(), regex.clone());
                        regex
                    }
                };
                section.generics.push((regex, item));
            } else {
                section.plain.insert(item.name.clone(), item);
            }
        }
        for section in items.values_mut() {
            section.generics.sort_by(|a, b| {
                (a.1.priority, &a.1.name).cmp(&(b.1.priority, &b.1.name))
            });
        }

        Ok(Self { items })
    }

    /// Return the default config item that matches `section` and `item`.
    pub fn get(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Option<&DefaultConfigItem> {
        let section_config = self.items.get(section)?;
        match section_config.plain.get(item) {
            Some(item) => Some(item),
            None => {
                for (regex, generic_item) in &section_config.generics {
                    if regex.is_match(item) {
                        return Some(generic_item);
                    }
                }
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::DefaultConfig;
    use crate::config::config_items::DefaultConfigItem;
    use crate::config::config_items::DefaultConfigItemType;

    #[test]
    fn test_config_read() {
        let contents = r#"
[[items]]
section = "alias"
name = "abcd.*"
default = 3
generic = true
priority = -1

[[items]]
section = "alias"
name = ".*"
default-type = "dynamic"
generic = true

[[items]]
section = "cmdserver"
name = "track-log"
default-type = "lambda"
default = [ "chgserver", "cmdserver", "repocache",]

[[items]]
section = "chgserver"
name = "idletimeout"
default = 3600

[[items]]
section = "cmdserver"
name = "message-encodings"
default-type = "list_type"

[[items]]
section = "web"
name = "encoding"
default-type = "lazy_module"
default = "encoding.encoding"

[[items]]
section = "command-templates"
name = "graphnode"
alias = [["ui", "graphnodetemplate"]]
documentation = """This is a docstring.
This is another line \
but this is not."""

[[items]]
section = "censor"
name = "policy"
default = "abort"
experimental = true

[[items]]
section = "pager"
name = "attend-.*"
default = true
generic = true

[[items]]
section = "merge-tools"
name = "kdiff3|meld"
default = true
generic = true

[[items]]
section = "merge-tools"
name = '.*\.gui$'
default = false
generic = true

[[template-applications]]
template = "diff-options"
section = "commands"
prefix = "revert.interactive"

[[template-applications]]
template = "diff-options"
section = "diff"

[templates]
[[templates.diff-options]]
suffix = "nodates"
default = false

[[templates.diff-options]]
suffix = "showfunc"
default = false

[[templates.diff-options]]
suffix = "unified"
"#;
        let res = DefaultConfig::from_contents(contents);
        let config = match res {
            Ok(config) => config,
            Err(e) => panic!("{}", e),
        };
        let expected = DefaultConfigItem {
            section: "censor".into(),
            name: "policy".into(),
            default: Some(DefaultConfigItemType::Primitive("abort".into())),
            priority: None,
            alias: vec![],
            experimental: true,
            documentation: "".into(),
            in_core_extension: None,
        };
        assert_eq!(config.get(b"censor", b"policy"), Some(&expected));

        // Test generic priority. The `.*` pattern is wider than `abcd.*`, but
        // `abcd.*` has priority, so it should match first.
        let expected = DefaultConfigItem {
            section: "alias".into(),
            name: "abcd.*".into(),
            default: Some(DefaultConfigItemType::Primitive(3.into())),
            priority: Some(-1),
            alias: vec![],
            experimental: false,
            documentation: "".into(),
            in_core_extension: None,
        };
        assert_eq!(config.get(b"alias", b"abcdsomething"), Some(&expected));

        //... but if it doesn't, we should fallback to `.*`
        let expected = DefaultConfigItem {
            section: "alias".into(),
            name: ".*".into(),
            default: Some(DefaultConfigItemType::Dynamic),
            priority: Some(0),
            alias: vec![],
            experimental: false,
            documentation: "".into(),
            in_core_extension: None,
        };
        assert_eq!(config.get(b"alias", b"something"), Some(&expected));

        // Generic patterns match from the start of the item name, like
        // Python's `re.match`, not anywhere in the name.
        assert!(config.get(b"pager", b"attend-diff").is_some());
        assert!(config.get(b"pager", b"no-attend-diff").is_none());

        // The anchoring applies to all branches of an alternation
        assert!(config.get(b"merge-tools", b"meld").is_some());
        assert!(config.get(b"merge-tools", b"xmeld").is_none());

        // Matching is done on bytes: non-UTF-8 names match like in Python
        assert!(config.get(b"merge-tools", b"caf\xe9.gui").is_some());

        let expected = DefaultConfigItem {
            section: "chgserver".into(),
            name: "idletimeout".into(),
            default: Some(DefaultConfigItemType::Primitive(3600.into())),
            priority: None,
            alias: vec![],
            experimental: false,
            documentation: "".into(),
            in_core_extension: None,
        };
        assert_eq!(config.get(b"chgserver", b"idletimeout"), Some(&expected));

        let expected = DefaultConfigItem {
            section: "cmdserver".into(),
            name: "track-log".into(),
            default: Some(DefaultConfigItemType::Lambda(vec![
                "chgserver".into(),
                "cmdserver".into(),
                "repocache".into(),
            ])),
            priority: None,
            alias: vec![],
            experimental: false,
            documentation: "".into(),
            in_core_extension: None,
        };
        assert_eq!(config.get(b"cmdserver", b"track-log"), Some(&expected));

        let expected = DefaultConfigItem {
            section: "command-templates".into(),
            name: "graphnode".into(),
            default: None,
            priority: None,
            alias: vec![("ui".into(), "graphnodetemplate".into())],
            experimental: false,
            documentation:
                "This is a docstring.\nThis is another line but this is not."
                    .into(),
            in_core_extension: None,
        };
        assert_eq!(
            config.get(b"command-templates", b"graphnode"),
            Some(&expected)
        );
    }

    #[test]
    fn test_invalid_generic_pattern_is_a_loading_error() {
        let contents = r#"
template-applications = []

[[items]]
section = "alias"
name = "invalid(["
generic = true

[templates]
"#;
        assert!(DefaultConfig::from_contents(contents).is_err());
    }
}
