use hg::config::Config;
use hg::repo::Repo;

use crate::error::CommandError;

pub struct RepoInvocation {
    pub repo: Repo,
}
impl RepoInvocation {
    pub fn new() -> Result<Self, CommandError> {
        let repo = Repo::find(&Config::empty(), None)?;
        Ok(Self { repo })
    }
}
