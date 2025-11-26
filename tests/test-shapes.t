#require rust

Setup the repo
  $ hg init server
  $ cd server

Check that server shapes config errors display correctly
--------------------------------------------------------

  $ cat > .hg/store/server-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "base"
  > paths = ["secret"]
  > EOF
  $ hg admin::narrow-server --shape-fingerprints
  config error: shard name 'base' is reserved
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
  3b2691b22939f5b98ef0f44ca96c5b5a6fa22b1173b4f5fff7044789e2b9dde6 other-secret

  $ hg admin::narrow-server --shape-fingerprints -Tjson
  [
   {
    "fingerprint": "a51b6c5dbfb838215a64a972c8c297233be7731e12f566dee567fd17ef0cd5c5",
    "name": "base"
   },
   {
    "fingerprint": "00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea",
    "name": "full"
   },
   {
    "fingerprint": "00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea",
    "name": "full-manual"
   },
   {
    "fingerprint": "3b2691b22939f5b98ef0f44ca96c5b5a6fa22b1173b4f5fff7044789e2b9dde6",
    "name": "other-secret"
   }
  ]


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
  inc:/.hgignore
  inc:/.hgsub
  inc:/.hgsubstate
  inc:/.hgtags
  inc:/foo/bar/other-secret
  $ hg admin::narrow-server --shape-patterns other-secret -Tjson
  [
   {
    "included": false,
    "path": ""
   },
   {
    "included": true,
    "path": ".hgignore"
   },
   {
    "included": true,
    "path": ".hgsub"
   },
   {
    "included": true,
    "path": ".hgsubstate"
   },
   {
    "included": true,
    "path": ".hgtags"
   },
   {
    "included": true,
    "path": "foo/bar/other-secret"
   }
  ]

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
  path:.hgignore
  path:.hgsub
  path:.hgsubstate
  path:.hgtags
  path:foo/bar/other-secret
  [exclude]
  path:.
  $ hg admin::narrow-server --shape-narrow-patterns other-secret -Tjson
  [
   {
    "included": true,
    "path": ".hgignore"
   },
   {
    "included": true,
    "path": ".hgsub"
   },
   {
    "included": true,
    "path": ".hgsubstate"
   },
   {
    "included": true,
    "path": ".hgtags"
   },
   {
    "included": true,
    "path": "foo/bar/other-secret"
   },
   {
    "included": false,
    "path": "foo/bar/other-secret"
   }
  ]

Test listing files
------------------

We don't have files yet
  $ hg admin::narrow-server --shape-files base

Add files
  $ mkdir -p foo/bar/other-secret secret dir1
  $ touch file1 file2 file3 foo/file1 foo/file2 foo/bar/other-secret/secret-file foo/bar/other-secret/secret-file2 dir1/file1 secret/secret-file secret/secret-file2
  $ hg commit -Aqm0

Test that only matching files are listed
  $ hg admin::narrow-server --shape-files base
  dir1/file1
  file1
  file2
  file3
  foo/file1
  foo/file2
  $ hg admin::narrow-server --shape-files other-secret
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2

  $ hg admin::narrow-server --shape-files base
  dir1/file1
  file1
  file2
  file3
  foo/file1
  foo/file2
  $ hg admin::narrow-server --shape-files full
  dir1/file1
  file1
  file2
  file3
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2
  foo/file1
  foo/file2
  secret/secret-file
  secret/secret-file2
  $ hg admin::narrow-server --shape-files full-manual
  dir1/file1
  file1
  file2
  file3
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2
  foo/file1
  foo/file2
  secret/secret-file
  secret/secret-file2
  $ hg admin::narrow-server --shape-files other-secret
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2

Test hidden files (warning about files not in the working copy anymore)
  $ hg rm secret
  removing secret/secret-file
  removing secret/secret-file2
  $ hg commit -Aqm1
  $ hg admin::narrow-server --shape-files-hidden full
  secret/secret-file
  secret/secret-file2
  $ hg admin::narrow-server --shape-files-hidden full-manual
  secret/secret-file
  secret/secret-file2

We also list hidden files in `--shape-files` (and test color output)
  $ hg admin::narrow-server --shape-files full --color=debug
  [narrow-server.known-path|dir1/file1]
  [narrow-server.known-path|file1]
  [narrow-server.known-path|file2]
  [narrow-server.known-path|file3]
  [narrow-server.known-path|foo/bar/other-secret/secret-file]
  [narrow-server.known-path|foo/bar/other-secret/secret-file2]
  [narrow-server.known-path|foo/file1]
  [narrow-server.known-path|foo/file2]
  [narrow-server.hidden-path|secret/secret-file]
  [narrow-server.hidden-path|secret/secret-file2]
  $ hg admin::narrow-server --shape-files full-manual
  dir1/file1
  file1
  file2
  file3
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2
  foo/file1
  foo/file2
  secret/secret-file
  secret/secret-file2

  $ hg admin::narrow-server --shape-files full -Tjson
  [
   {
    "is_hidden": false,
    "path": "dir1/file1"
   },
   {
    "is_hidden": false,
    "path": "file1"
   },
   {
    "is_hidden": false,
    "path": "file2"
   },
   {
    "is_hidden": false,
    "path": "file3"
   },
   {
    "is_hidden": false,
    "path": "foo/bar/other-secret/secret-file"
   },
   {
    "is_hidden": false,
    "path": "foo/bar/other-secret/secret-file2"
   },
   {
    "is_hidden": false,
    "path": "foo/file1"
   },
   {
    "is_hidden": false,
    "path": "foo/file2"
   },
   {
    "is_hidden": true,
    "path": "secret/secret-file"
   },
   {
    "is_hidden": true,
    "path": "secret/secret-file2"
   }
  ]
