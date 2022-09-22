use crate::utils::files::get_bytes_from_os_string;
use std::env;

/// Keeps information on whether plain mode is active.
///
/// Plain mode means that all configuration variables which affect
/// the behavior and output of Mercurial should be
/// ignored. Additionally, the output should be stable,
/// reproducible and suitable for use in scripts or applications.
///
/// The only way to trigger plain mode is by setting either the
/// `HGPLAIN' or `HGPLAINEXCEPT' environment variables.
///
/// The return value can either be
/// - False if HGPLAIN is not set, or feature is in HGPLAINEXCEPT
/// - False if feature is disabled by default and not included in HGPLAIN
/// - True otherwise
#[derive(Clone)]
pub struct PlainInfo {
    is_plain: bool,
    except: Vec<Vec<u8>>,
}

impl PlainInfo {
    fn plain_except(except: Vec<Vec<u8>>) -> Self {
        PlainInfo {
            is_plain: true,
            except,
        }
    }

    pub fn empty() -> PlainInfo {
        PlainInfo {
            is_plain: false,
            except: vec![],
        }
    }

    pub fn from_env() -> PlainInfo {
        if let Some(except) = env::var_os("HGPLAINEXCEPT") {
            PlainInfo::plain_except(
                get_bytes_from_os_string(except)
                    .split(|&byte| byte == b',')
                    .map(|x| x.to_vec())
                    .collect(),
            )
        } else {
            PlainInfo {
                is_plain: env::var_os("HGPLAIN").is_some(),
                except: vec![],
            }
        }
    }

    pub fn is_feature_plain(&self, feature: &str) -> bool {
        return self.is_plain
            && !self
                .except
                .iter()
                .any(|exception| exception.as_slice() == feature.as_bytes());
    }

    pub fn is_plain(&self) -> bool {
        self.is_plain
    }

    pub fn plainalias(&self) -> bool {
        self.is_feature_plain("alias")
    }
    pub fn plainrevsetalias(&self) -> bool {
        self.is_feature_plain("revsetalias")
    }
    pub fn plaintemplatealias(&self) -> bool {
        self.is_feature_plain("templatealias")
    }
    pub fn plaintweakdefaults(&self) -> bool {
        self.is_feature_plain("tweakdefaults")
    }
}
