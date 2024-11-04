//! Code for parsing default Mercurial config items.
use itertools::Itertools;
use serde::Deserialize;

use crate::{errors::HgError, exit_codes, FastHashMap};

/// Corresponds to the structure of `mercurial/configitems.toml`.
#[derive(Debug, Deserialize)]
pub struct ConfigItems {
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
    section: String,
    /// Name of the item (e.g. `meld.gui`)
    name: String,
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
    alias: Vec<(String, String)>,
    /// Whether the config item is marked as experimental
    #[serde(default)]
    experimental: bool,
    /// The (possibly empty) docstring for the item
    #[serde(default)]
    documentation: String,
    /// Whether the item is part of an in-core extension. This allows us to
    /// hide them if the extension is not enabled, to preserve legacy
    /// behavior.
    #[serde(default)]
    in_core_extension: Option<String>,
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
            section: value.section,
            name: value.name,
            default: raw_default_to_concrete(
                value.default_type,
                value.default,
            )?,
            priority: if value.generic {
                Some(value.priority)
            } else {
                None
            },
            alias: value.alias,
            experimental: value.experimental,
            documentation: value.documentation,
            in_core_extension: value.in_core_extension,
        })
    }
}

impl DefaultConfigItem {
    fn is_generic(&self) -> bool {
        self.priority.is_some()
    }

    pub fn in_core_extension(&self) -> Option<&str> {
        self.in_core_extension.as_deref()
    }

    pub fn section(&self) -> &str {
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
                        value.section,
                        value.name
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
                        value.section,
                        value.name
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
                        value.section,
                        value.name
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'bool', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(
                        toml::Value::Boolean(b),
                    ) => Ok(Some(*b)),
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
                        value.section,
                        value.name
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'u32', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(
                        toml::Value::Integer(b),
                    ) => {
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
                        value.section,
                        value.name
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'u64', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(
                        toml::Value::Integer(b),
                    ) => {
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
                        value.section,
                        value.name
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'i64', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(
                        toml::Value::Integer(b),
                    ) => Ok(Some(*b)),
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
                        value.section,
                        value.name
                    ),
                    exit_codes::ABORT,
                    Some(format!(
                        "asked for 'f64', type of default is '{}'",
                        default.type_str()
                    )),
                );
                match default {
                    DefaultConfigItemType::Primitive(toml::Value::Float(
                        b,
                    )) => Ok(Some(*b)),
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
            DefaultConfigItemType::Primitive(primitive) => {
                primitive.type_str()
            }
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
    suffix: String,
    default: Option<DefaultConfigItemType>,
    priority: Option<isize>,
    #[serde(default)]
    alias: Vec<(String, String)>,
    #[serde(default)]
    experimental: bool,
    #[serde(default)]
    documentation: String,
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
            name: application
                .prefix
                .map(|prefix| format!("{}.{}", prefix, self.suffix))
                .unwrap_or(self.suffix),
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
            suffix: value.suffix,
            default: raw_default_to_concrete(
                value.default_type,
                value.default,
            )?,
            priority: if value.generic {
                Some(value.priority)
            } else {
                None
            },
            alias: value.alias,
            experimental: value.experimental,
            documentation: value.documentation,
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
                ))
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
                        ))
                    }
                }))
            }
            None => {
                return Err(HgError::abort(
                    "lazy_module should have a default value".to_string(),
                    exit_codes::ABORT,
                    Some("Check 'mercurial/configitems.toml'".into()),
                ))
            }
        },
        Some(invalid) => {
            return Err(HgError::abort(
                format!("invalid default_type '{}'", invalid),
                exit_codes::ABORT,
                Some("Check 'mercurial/configitems.toml'".into()),
            ))
        }
    })
}

#[derive(Debug, Clone, Deserialize)]
struct TemplateApplication {
    template: String,
    section: String,
    #[serde(default)]
    prefix: Option<String>,
}

/// Represents the (dynamic) set of default core Mercurial config items from
/// `mercurial/configitems.toml`.
#[derive(Clone, Debug, Default)]
pub struct DefaultConfig {
    /// Mapping of section -> (mapping of name -> item)
    items: FastHashMap<String, FastHashMap<String, DefaultConfigItem>>,
}

impl DefaultConfig {
    pub fn empty() -> DefaultConfig {
        Self {
            items: Default::default(),
        }
    }

    /// Returns `Self`, given the contents of `mercurial/configitems.toml`
    #[logging_timer::time("trace")]
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
                None => return Err(
                    HgError::abort(
                        format!(
                            "template application refers to undefined template '{}'",
                            application.template
                        ),
                        exit_codes::ABORT,
                        Some("Check 'mercurial/configitems.toml'".into())
                    )
                ),
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

        let items = flat_items.into_iter().fold(
            FastHashMap::default(),
            |mut acc, item| {
                acc.entry(item.section.to_owned())
                    .or_insert_with(|| {
                        let mut section = FastHashMap::default();
                        section.insert(item.name.to_owned(), item.to_owned());
                        section
                    })
                    .insert(item.name.to_owned(), item);
                acc
            },
        );

        Ok(Self { items })
    }

    /// Return the default config item that matches `section` and `item`.
    pub fn get(
        &self,
        section: &[u8],
        item: &[u8],
    ) -> Option<&DefaultConfigItem> {
        // Core items must be valid UTF-8
        let section = String::from_utf8_lossy(section);
        let section_map = self.items.get(section.as_ref())?;
        let item_name_lossy = String::from_utf8_lossy(item);
        match section_map.get(item_name_lossy.as_ref()) {
            Some(item) => Some(item),
            None => {
                for generic_item in section_map
                    .values()
                    .filter(|item| item.is_generic())
                    .sorted_by_key(|item| match item.priority {
                        Some(priority) => (priority, &item.name),
                        _ => unreachable!(),
                    })
                {
                    if regex::bytes::Regex::new(&generic_item.name)
                        .expect("invalid regex in configitems")
                        .is_match(item)
                    {
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
    use crate::config::config_items::{
        DefaultConfigItem, DefaultConfigItemType,
    };

    use super::DefaultConfig;

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
}
