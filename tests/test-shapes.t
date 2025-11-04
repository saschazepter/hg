#require rust

Setup the repo
  $ hg init server
  $ cd server

Check for server shapes config errors
-------------------------------------

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "base"
  > paths = ["secret"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard name 'base' is reserved
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "full"
  > paths = ["secret"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard name 'full' is reserved
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "myshard"
  > paths = ["secret"]
  > [[shards]]
  > name = "myshard2"
  > paths = ["secret"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: path 'secret' is in two separate shards
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 999
  > [[shards]]
  > name = "myshard"
  > paths = ["secret"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: unknown server-shapes version 999
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "duplicate"
  > paths = ["secret"]
  > [[shards]]
  > name = "duplicate"
  > paths = ["otherpath"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard 'duplicate' defined twice
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "too-little"
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard 'too-little' needs one of `paths` or `requires`
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "recursive"
  > requires = ["recursive"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard 'recursive' creates a cycle with 'recursive'
  [30]

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "cyclic1"
  > requires = ["cyclic2"]
  > [[shards]]
  > name = "cyclic2"
  > requires = ["cyclic1"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard 'cyclic2' creates a cycle with 'cyclic1'
  [30]

Normal cases
------------

Setup the server shapes config
  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "secrets"
  > requires = ["other-secret"]
  > paths = ["secret"]
  > [[shards]]
  > name = "full-manual"
  > requires = ["base", "secrets"]
  > shape = true
  > [[shards]]
  > name = "other-secret"
  > paths = ["foo/bar/other-secret"]
  > shape = true
  > EOF

Check that the fingerprints match between semantically identical shapes and
that shards not declared as shapes (here "secret") is not listed

  $ hg admin::narrow-server --shape-fingerprints
  a51b6c5dbfb838215a64a972c8c297233be7731e12f566dee567fd17ef0cd5c5 base
  00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea full
  00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea full-manual
  7933c8969f86272e8bf29d3554b29372dc6a9c756e651847256078c35bb6a038 other-secret

Check that we generate the correct narrow patterns for every shape

  $ hg admin::narrow-server --shape-patterns base
  inc:/
  exc:/foo/bar/other-secret
  exc:/secret
  $ hg admin::narrow-server --shape-patterns full
  inc:/
  $ hg admin::narrow-server --shape-patterns full-manual
  inc:/
  $ hg admin::narrow-server --shape-patterns other-secret
  exc:/
  inc:/foo/bar/other-secret

Test the legacy narrow patterns option

  $ hg admin::narrow-server --shape-narrow-patterns base
  [include]
  path:.
  [exclude]
  path:foo/bar/other-secret
  path:secret
  $ hg admin::narrow-server --shape-narrow-patterns full
  [include]
  path:.
  $ hg admin::narrow-server --shape-narrow-patterns full-manual
  [include]
  path:.
  $ hg admin::narrow-server --shape-narrow-patterns other-secret
  [include]
  path:foo/bar/other-secret
  [exclude]
  path:.
