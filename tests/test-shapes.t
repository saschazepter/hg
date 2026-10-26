#require rust

Setup the repo
  $ hg init server
  $ cd server

Check that server shapes config errors display correctly
--------------------------------------------------------

  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "base"
  > paths = ["secret"]
  > EOF
  $ hg admin::narrow-server --store-profile-fingerprints
  config error: shard name 'base' is reserved
  [30]

  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > [[profiles]]
  > name = "typo"
  > includes = ["fooo"]
  > EOF
  $ hg admin::narrow-server --store-profile-fingerprints
  config error: profile 'typo' includes unknown name 'fooo'
  [30]

An unknown version is reported as unknown

  $ cat > .hg/store/server-sharding <<EOF
  > version = 99
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > EOF
  $ hg admin::narrow-server --store-profile-fingerprints
  config error: unknown `server-sharding` version '99'
  [30]

An unknown version with unknown fields is reported as unknown

  $ cat > .hg/store/server-sharding <<EOF
  > version = 99
  > new-field = true
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > EOF
  $ hg admin::narrow-server --store-profile-fingerprints
  config error: unknown `server-sharding` version '99'
  [30]

Normal cases
------------

Setup the server shapes config
  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "secrets"
  > paths = ["secret"]
  > read-write-access = []
  > [[shards]]
  > name = "other-secret-files"
  > paths = ["foo/bar/other-secret"]
  > read-write-access = ["security", "foo-team"]
  > 
  > [[profiles]]
  > name = "default"
  > includes = ["base"]
  > public = true
  > [[profiles]]
  > name = "internal-secrets"  # Test a private shape
  > includes = ["secrets", "other-secret"]
  > [[profiles]]
  > name = "full-manual"
  > includes = ["base", "internal-secrets"]
  > public = true
  > [[profiles]]
  > name = "other-secret"
  > includes = ["other-secret-files"]
  > public = true
  > EOF

Check that the fingerprints match between semantically identical shapes and
that shards not declared as shapes (here "secret") is not listed

  $ hg admin::narrow-server --store-profile-fingerprints
  shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512 default
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full-manual
  shape01-8e958ffc18c18371e8df8a32b75213316d8984cbe0a0cb14637c71564a9fd553 other-secret

  $ hg admin::narrow-server --store-profile-fingerprints -Tjson
  [
   {
    "fingerprint": "shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512",
    "name": "default"
   },
   {
    "fingerprint": "shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545",
    "name": "full"
   },
   {
    "fingerprint": "shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545",
    "name": "full-manual"
   },
   {
    "fingerprint": "shape01-8e958ffc18c18371e8df8a32b75213316d8984cbe0a0cb14637c71564a9fd553",
    "name": "other-secret"
   }
  ]


Listing the access of every shard
---------------------------------

List the read-write-access of every shard by shard id, including the implicit
shards. It is listed for external systems, it is not enforced by Mercurial.

  $ hg admin::narrow-server --store-shards
  shard01-061330ec0246e218f25cbe1bec82cf7e6a6cfc022c9a8520de41e2d5431569da
  shard01-3711ce3253a35e53b8fb7ff93a0da0e483254f17ce1f5034ba9860d7f6f6d895
  shard01-6edbd548038d51c90e4d3167524c82c2dff501ae3b39ab574fe26cd618a49db0 read-write-access=
  shard01-c491fc7f4780d490a8156c3888e591101acc71f30f6a0481a2e1b44b5e69ccb6 read-write-access=foo-team,security
  $ hg admin::narrow-server --store-shards -Tjson
  [
   {
    "shard_id": "shard01-061330ec0246e218f25cbe1bec82cf7e6a6cfc022c9a8520de41e2d5431569da"
   },
   {
    "shard_id": "shard01-3711ce3253a35e53b8fb7ff93a0da0e483254f17ce1f5034ba9860d7f6f6d895"
   },
   {
    "read_write_access": [],
    "shard_id": "shard01-6edbd548038d51c90e4d3167524c82c2dff501ae3b39ab574fe26cd618a49db0"
   },
   {
    "read_write_access": ["foo-team", "security"],
    "shard_id": "shard01-c491fc7f4780d490a8156c3888e591101acc71f30f6a0481a2e1b44b5e69ccb6"
   }
  ]

Check that we generate the correct narrow patterns for every shape

  $ hg admin::narrow-server --store-shape-patterns default
  inc:/
  exc:/foo/bar/other-secret
  exc:/secret
  $ hg admin::narrow-server --store-shape-patterns full
  inc:/
  $ hg admin::narrow-server --store-shape-patterns full-manual
  inc:/
  $ hg admin::narrow-server --store-shape-patterns other-secret
  exc:/
  inc:/.hgeol
  inc:/.hgignore
  inc:/.hglfs
  inc:/.hgsigs
  inc:/.hgsub
  inc:/.hgsubstate
  inc:/.hgtags
  inc:/foo/bar/other-secret
  $ hg admin::narrow-server --store-shape-patterns other-secret -Tjson
  [
   {
    "included": false,
    "path": ""
   },
   {
    "included": true,
    "path": ".hgeol"
   },
   {
    "included": true,
    "path": ".hgignore"
   },
   {
    "included": true,
    "path": ".hglfs"
   },
   {
    "included": true,
    "path": ".hgsigs"
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

Comma-separated names designate their composite shape
-----------------------------------------------------

  $ hg admin::narrow-server --store-shape-patterns other-secret,default
  inc:/
  exc:/secret

  $ hg admin::narrow-server --store-shape-patterns default,zz
  abort: store profile 'zz' not found
  [255]

  $ hg admin::narrow-server --store-shape-patterns default,Babar
  abort: invalid store profile name 'Babar'
  (only lowercase alphanumeric, hyphen or dot are accepted)
  [10]

  $ hg admin::narrow-server --store-shape-patterns default,
  abort: store profile names must not be empty
  [10]

Test the legacy narrow patterns option

  $ hg admin::narrow-server --store-shape-narrow-patterns default
  [exclude]
  path:foo/bar/other-secret
  path:secret
  $ hg admin::narrow-server --store-shape-narrow-patterns full
  $ hg admin::narrow-server --store-shape-narrow-patterns full-manual
  $ hg admin::narrow-server --store-shape-narrow-patterns other-secret
  [include]
  path:.hgeol
  path:.hgignore
  path:.hglfs
  path:.hgsigs
  path:.hgsub
  path:.hgsubstate
  path:.hgtags
  path:foo/bar/other-secret
  $ hg admin::narrow-server --store-shape-narrow-patterns other-secret -Tjson
  [
   {
    "included": true,
    "path": ".hgeol"
   },
   {
    "included": true,
    "path": ".hgignore"
   },
   {
    "included": true,
    "path": ".hglfs"
   },
   {
    "included": true,
    "path": ".hgsigs"
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


Test that the generated narrow patterns actually work
-----------------------------------------------------

One including the root

  $ hg admin::narrow-server --store-profile-fingerprints | grep default
  shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512 default
  $ hg admin::narrow-server --store-shape-narrow-patterns default > ../shape.npt
  $ hg --config extensions.narrow= clone --narrow --narrowspec ../shape.npt . ../clone-test-1
  reading narrowspec from '$TESTTMP/server/../shape.npt'
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg --config extensions.narrow= -R ../clone-test-1 admin::narrow-client --store-shape-fingerprint
  shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512

One excluding the root

  $ hg admin::narrow-server --store-profile-fingerprints | grep other-secret
  shape01-8e958ffc18c18371e8df8a32b75213316d8984cbe0a0cb14637c71564a9fd553 other-secret
  $ hg admin::narrow-server --store-shape-narrow-patterns other-secret > ../shape.npt
  $ hg --config extensions.narrow= clone --narrow --narrowspec ../shape.npt . ../clone-test-2
  reading narrowspec from '$TESTTMP/server/../shape.npt'
  no changes found
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg --config extensions.narrow= -R ../clone-test-2 admin::narrow-client --store-shape-fingerprint
  shape01-8e958ffc18c18371e8df8a32b75213316d8984cbe0a0cb14637c71564a9fd553


Test listing files
------------------

We don't have files yet
  $ hg admin::narrow-server --store-shape-files default

Add files
  $ mkdir -p foo/bar/other-secret secret dir1
  $ touch file1 file2 file3 foo/file1 foo/file2 foo/bar/other-secret/secret-file foo/bar/other-secret/secret-file2 dir1/file1 secret/secret-file secret/secret-file2
  $ hg commit -Aqm0

Test that only matching files are listed
  $ hg admin::narrow-server --store-shape-files default
  dir1/file1
  file1
  file2
  file3
  foo/file1
  foo/file2
  $ hg admin::narrow-server --store-shape-files other-secret
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2

  $ hg admin::narrow-server --store-shape-files default
  dir1/file1
  file1
  file2
  file3
  foo/file1
  foo/file2
  $ hg admin::narrow-server --store-shape-files full
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
  $ hg admin::narrow-server --store-shape-files full-manual
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
  $ hg admin::narrow-server --store-shape-files other-secret
  foo/bar/other-secret/secret-file
  foo/bar/other-secret/secret-file2

Test hidden files (warning about files not in the working copy anymore)
  $ hg rm secret
  removing secret/secret-file
  removing secret/secret-file2
  $ hg commit -Aqm1
  $ hg admin::narrow-server --store-shape-files-hidden full
  secret/secret-file
  secret/secret-file2
  $ hg admin::narrow-server --store-shape-files-hidden full-manual
  secret/secret-file
  secret/secret-file2

We also list hidden files in `--store-shape-files` (and test color output)
  $ hg admin::narrow-server --store-shape-files full --color=debug
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
  $ hg admin::narrow-server --store-shape-files full-manual
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

  $ hg admin::narrow-server --store-shape-files full -Tjson
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

Test updating the shapes file
-----------------------------

  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > EOF

Update from file, adding a new shape that depends on the existing shard

  $ cp .hg/store/server-sharding ../new-shapes
  $ cat >> ../new-shapes <<EOF
  > [[profiles]]
  > name = "from-file"
  > includes = ["foo"]
  > public = true
  > EOF
  $ hg admin::narrow-server --store-sharding-update -f ../new-shapes
  $ cat .hg/store/server-sharding
  # Do not edit this file by hand!
  # Use `hg admin::narrow-server --store-sharding-update` instead,
  # which will ensure the update is made safely.
  version = 1
  [[shards]]
  name = "foo"
  paths = ["foo"]
  [[profiles]]
  name = "from-file"
  includes = ["foo"]
  public = true
  $ hg admin::narrow-server --store-profile-fingerprints
  shape01-2c9550754270e8898934090a45089201c6388211b5df36c6458aafebe46c7642 from-file
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full

Fail if `-f` is a path that does not exist

  $ hg admin::narrow-server --store-sharding-update -f ../does-not-exist
  abort: can't read file '../does-not-exist': $ENOENT$
  [10]

Without `-f`, the editor is opened on the current contents

  $ HGEDITOR=cat hg admin::narrow-server --store-sharding-update
  # Do not edit this file by hand!
  # Use `hg admin::narrow-server --store-sharding-update` instead,
  # which will ensure the update is made safely.
  version = 1
  [[shards]]
  name = "foo"
  paths = ["foo"]
  [[profiles]]
  name = "from-file"
  includes = ["foo"]
  public = true

Updating to invalid contents is not allowed

  $ echo 'invalid contents' > ../invalid-shapes
  $ hg admin::narrow-server --store-sharding-update -f ../invalid-shapes
  config error: error parsing `server-sharding`:
  TOML parse error at line 1, column 9
    |
  1 | invalid contents
    |         ^
  key with no value, expected `=`
  
  [30]

  $ hg admin::narrow-server --store-profile-fingerprints
  shape01-2c9550754270e8898934090a45089201c6388211b5df36c6458aafebe46c7642 from-file
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full

Test that an update either reshapes or reshards, not both
---------------------------------------------------------

  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > EOF

Adding a new shard together with a new shape that uses it is not a safe update. The new
bundles need to be generated from the new shards before we are ready to add the new shape.

  $ cp .hg/store/server-sharding ../new-shapes
  $ cat >> ../new-shapes <<EOF
  > [[shards]]
  > name = "dir1"
  > paths = ["dir1"]
  > [[profiles]]
  > name = "new-shape"
  > includes = ["dir1"]
  > public = true
  > EOF
  $ hg admin::narrow-server --store-sharding-update -f ../new-shapes
  abort: cannot reshape and reshard in the same update
  store profiles changed: "new-shape"
  shards changed: "base", "dir1"
  (see 'hg help "narrow.updating the store sharding configuration"' for how to split this in two updates)
  [10]

Passing `--override-reshape-and-reshard-check` allows the update anyways

  $ hg admin::narrow-server --store-sharding-update -f ../new-shapes --override-reshape-and-reshard-check
  $ hg admin::narrow-server --store-profile-fingerprints
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full
  shape01-35ad59de419852b021828685618bdab6905fdaf17b60664011aa735e6a8e08df new-shape

Test that a shape keeps its fingerprint
---------------------------------------

Attempting to change `new-shape` fails because its fingerprint would change

  $ cat > ../new-shapes <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > [[shards]]
  > name = "dir1"
  > paths = ["dir1"]
  > [[profiles]]
  > name = "new-shape"
  > includes = ["foo"]
  > public = true
  > EOF
  $ hg admin::narrow-server --store-sharding-update -f ../new-shapes
  abort: won't change the fingerprint of existing store profiles: "new-shape"
  (see 'hg help "narrow.updating the store sharding configuration"' for how to publish this as a new store profile)
  [10]

Reshaping is refused while a previous config is still saved

  $ cp .hg/store/server-sharding ../added-shape
  $ cat >> ../added-shape <<EOF
  > [[profiles]]
  > name = "foo-shape"
  > includes = ["foo"]
  > public = true
  > EOF
  $ hg admin::narrow-server --store-sharding-update -f ../added-shape
  abort: cannot reshape yet: 1 previous server-sharding still saved
  store profiles changed: "foo-shape"
  (see 'hg help "narrow.updating the store sharding configuration"' for how to clear the saved configs)
  [10]

Passing `--override-saved-configs-check` allows the update anyways

  $ hg admin::narrow-server --store-sharding-update -f ../added-shape --override-saved-configs-check
  $ hg admin::narrow-server --store-profile-fingerprints | grep foo-shape
  shape01-2c9550754270e8898934090a45089201c6388211b5df36c6458aafebe46c7642 foo-shape

Clear the config saved by the resharding above, so that the reshaping below is
only exercising the fingerprint check

  $ hg admin::narrow-server --store-sharding-clear-previous
  cleared 1 saved server-sharding

Passing `--override-fingerprint-change-check` allows the update anyways

  $ hg admin::narrow-server --store-sharding-update -f ../new-shapes --override-fingerprint-change-check
  $ hg admin::narrow-server --store-profile-fingerprints
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full
  shape01-2c9550754270e8898934090a45089201c6388211b5df36c6458aafebe46c7642 new-shape

Resharding saves previous configs
---------------------------------

  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > [[profiles]]
  > name = "shape"
  > includes = ["foo"]
  > public = true
  > EOF
  $ rm -f .hg/store/server-sharding-previous-*

Reshard by adding a new shard nested under `foo`

  $ cat > ../new-shapes <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > [[shards]]
  > name = "nested"
  > paths = ["foo/nested"]
  > [[profiles]]
  > name = "shape"
  > includes = ["foo", "nested"]
  > public = true
  > EOF
  $ hg admin::narrow-server --store-sharding-update -f ../new-shapes

The previous config is saved in a separate file, named by the list of saved
configs

  $ cat .hg/store/server-sharding-previous-list
  server-sharding-previous-* (no-eol) (glob)
  $ cat .hg/store/`cat .hg/store/server-sharding-previous-list`
  version = 1
  [[shards]]
  name = "foo"
  paths = ["foo"]
  [[profiles]]
  name = "shape"
  includes = ["foo"]
  public = true

Clearing drops the saved configs and empties the list

  $ saved=`cat .hg/store/server-sharding-previous-list`
  $ hg admin::narrow-server --store-sharding-clear-previous
  cleared 1 saved server-sharding
  $ cat .hg/store/server-sharding-previous-list
  $ test -f .hg/store/$saved
  [1]

Clearing again is a no op

  $ hg admin::narrow-server --store-sharding-clear-previous
  cleared 0 saved server-sharding

Test behavior of concurrent updates
-----------------------------------

  $ cat > .hg/store/server-sharding <<EOF
  > version = 1
  > [[shards]]
  > name = "foo"
  > paths = ["foo"]
  > EOF

  $ cp .hg/store/server-sharding ../new-shapes
  $ cat >> ../new-shapes <<EOF
  > [[profiles]]
  > name = "new-shape"
  > includes = ["foo"]
  > public = true
  > EOF

  $ cp .hg/store/server-sharding ../concurrent-update
  $ cat >> ../concurrent-update <<EOF
  > [[profiles]]
  > name = "concurrent"
  > includes = ["foo"]
  > public = true
  > EOF

Start an update and hold it in the editor

  $ cat > ../blocking-editor.sh <<EOF
  > cat ../new-shapes > "\$1"
  > "$RUNTESTDIR/testlib/wait-on-file" 10 "$TESTTMP/editor-continue" "$TESTTMP/editor-waiting"
  > EOF
  $ HGEDITOR="sh ../blocking-editor.sh" hg admin::narrow-server --store-sharding-update \
  > > ../editor-update.out 2>&1 &
  $ $RUNTESTDIR/testlib/wait-on-file 10 $TESTTMP/editor-waiting

The sharding lock is held for the whole update, so a second update fails

  $ hg admin::narrow-server --store-sharding-update -f ../concurrent-update
  abort: store sharding config of $TESTTMP/server: timed out waiting for lock held by * (glob)
  [20]

Read-only commands emit a warning
  $ hg admin::narrow-server --store-profile-fingerprints
  warning: the store sharding config is currently being updated (lock held by *) (glob)
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full

Nothing was written, the first update still owns the file

  $ cat .hg/store/server-sharding
  version = 1
  [[shards]]
  name = "foo"
  paths = ["foo"]

Letting the first update finish applies it

  $ touch $TESTTMP/editor-continue
  $ wait
  $ cat ../editor-update.out
  $ cat .hg/store/server-sharding
  # Do not edit this file by hand!
  # Use `hg admin::narrow-server --store-sharding-update` instead,
  # which will ensure the update is made safely.
  version = 1
  [[shards]]
  name = "foo"
  paths = ["foo"]
  [[profiles]]
  name = "new-shape"
  includes = ["foo"]
  public = true

The lock is released afterwards, so now another update can now go through

  $ hg admin::narrow-server --store-sharding-update -f ../concurrent-update
  $ hg admin::narrow-server --store-profile-fingerprints
  shape01-2c9550754270e8898934090a45089201c6388211b5df36c6458aafebe46c7642 concurrent
  shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full
