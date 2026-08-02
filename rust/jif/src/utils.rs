use hg::config::Config;
use hg::repo::Repo;

pub struct RepoInvocation {
    pub repo: Repo,
}
impl RepoInvocation {
    pub fn new() -> Self {
        let repo = Repo::find(&Config::empty(), None).unwrap();
        Self { repo }
    }
}

impl Default for RepoInvocation {
    fn default() -> Self {
        Self::new()
    }
}
