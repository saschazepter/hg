#testcases python-client rust-client
#testcases ssh local
#require rust

#if local python-client

Can't test local with Python since it acts as its own server
  $ exit 80
#endif

Setup the repo
  $ hg init server
  $ cd server

Setup the server shapes config
  $ cat > $TESTTMP/starting-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "default"
  > requires = ["base"]
  > shape = true
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
  $ hg admin::narrow-server --shape-update -f $TESTTMP/starting-shapes


Add files
  $ mkdir -p foo/bar/other-secret secret dir1
  $ touch file1 file2 file3 foo/file1 foo/file2 foo/bar/other-secret/secret-file foo/bar/other-secret/secret-file2 dir1/file1 secret/secret-file secret/secret-file2
  $ echo "file1 contents" > file1
  $ echo "secret!" > secret/secret-file
  $ hg commit -Aqm0
  $ hg rm secret
  removing secret/secret-file
  removing secret/secret-file2
  $ hg commit -Aqm1

Test the `store_shapes` wireproto command
=========================================

Enable the narrow extension to enable the wireproto capability
  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > narrow=
  > EOF

First disable support so we test old client behavior

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > advertise-shapes=no
  > EOF

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     name unknown-shape
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: cannot use store shapes; remote repository does not support the 'exp-shape-1' capability
  [255]


Restore support

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > advertise-shapes=yes
  > EOF

Test error cases
----------------

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     name unknown-shape
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: shape not found on remote: 'unknown-shape'
  [10]

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     # try a shard
  >     name secrets
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: shape not found on remote: 'secrets'
  [10]

Test valid cases
----------------

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     # valid shape
  >     name other-secret
  > command store_shape
  >     # valid shape
  >     name default
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  response: (
    set([
      b'path:.hgignore',
      b'path:.hgsub',
      b'path:.hgsubstate',
      b'path:.hgtags',
      b'path:foo/bar/other-secret'
    ]),
    set([
      b'path:.'
    ])
  )
  sending store_shape command
  response: (
    set([
      b'path:.'
    ]),
    set([
      b'path:foo/bar/other-secret',
      b'path:secret'
    ])
  )

Test narrow clone with `--store-shape`
--------------------------------

  $ cat > $TESTTMP/server-hg.sh << EOF
  > #!/bin/sh
  > HGMODULEPOLICY=rust+c
  > export HGMODULEPOLICY
  > hg "\$@"
  > EOF
  $ chmod +x $TESTTMP/server-hg.sh

#if python-client
  $ POLICY="env HGMODULEPOLICY=py"
#else
  $ POLICY="env HGMODULEPOLICY=rust+c"
#endif


#if ssh
  $ hg serve -p $HGPORT -d --pid-file=$TESTTMP/hg.pid -E $TESTTMP/server-errors.log
  $ cat $TESTTMP/hg.pid >> $DAEMON_PIDS
  $ remote_url="ssh://user@dummy/server"
  $ remote_cmd="--remotecmd=$TESTTMP/server-hg.sh"
#else
  $ remote_url="server"
#endif

  $ cd ..

Test the error case

  $ $POLICY hg clone $remote_url narrow-clone $remote_cmd --shape unknown-shape
  abort: shape not found on remote: 'unknown-shape'
  [10]

Test a valid shape

  $ $POLICY hg clone $remote_url narrow-clone $remote_cmd --shape default --quiet
  $ cd narrow-clone

Check that we track the correct paths
  $ hg tracked
  I path:.
  X path:foo/bar/other-secret
  X path:secret
  $ hg files
  dir1/file1
  file1
  file2
  file3
  foo/file1
  foo/file2

Check that a removed file outside the shape is not available
  $ hg cat secret/secret-file
  [1]

Check that a file outside the shape is not available
  $ hg cat foo/bar/other-secret/secret-file
  [1]

Check that a file inside the shape is available
  $ hg cat file1
  file1 contents

Test pull
=========

First create something to pull

  $ cd $TESTTMP/server
  $ echo "new contents" >> file1
  $ echo "new secret contents" >> foo/bar/other-secret/secret-file
  $ hg commit -Aqm2
  $ cd $TESTTMP/narrow-clone

Check that pulling works
------------------------

  $ hg pull
  pulling from $TESTTMP/server (local !)
  pulling from ssh://user@dummy/server (no-local !)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 18db1f1f143d
  (run 'hg update' to get a working copy)

  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

You still can't access a removed file outside the shape
  $ hg cat secret/secret-file
  [1]

Nor the existing file that was updated outside the shape
  $ hg cat foo/bar/other-secret/secret-file
  [1]

Check that the file has been updated
  $ hg cat file1
  file1 contents
  new contents

Create another commit

  $ cd $TESTTMP/server
  $ echo "newer contents" >> file1
  $ echo "newer secret contents" >> foo/bar/other-secret/secret-file
  $ hg commit -Aqm3
  $ cd $TESTTMP/narrow-clone

Check that a pattern only mismatch is detected
-----------------------------------------------

Update the server shapes to change the fingerprint of this shape
  $ cat > $TESTTMP/new-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "default"
  > requires = ["base", "secrets"]
  > shape = true
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
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: fingerprint mismatch for shape 'default'
    server: 'a51b6c5dbfb838215a64a972c8c297233be7731e12f566dee567fd17ef0cd5c5'
    client: '00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea'
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: fingerprint mismatch for shape 'default'
    server: 'a51b6c5dbfb838215a64a972c8c297233be7731e12f566dee567fd17ef0cd5c5'
    client: '00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea'
  abort: pull failed on remote
  [100]
#endif

Check that a shape being removed is detected
--------------------------------------------

Update the server shapes to remove the shape
  $ cat > $TESTTMP/new-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "from-file"
  > paths = ["dir1"]
  > shape = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: shape not found on remote: 'default'
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: shape not found on remote: 'default'
  abort: pull failed on remote
  [100]
#endif

Reset the shapes
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/starting-shapes

Create another commit to pull
  $ cd $TESTTMP/server
  $ echo "newer contents" >> file1
  $ echo "newer secret contents" >> foo/bar/other-secret/secret-file
  $ hg commit -Aqm3
  $ cd $TESTTMP/narrow-clone

Check that a pattern only mismatch is detected
-----------------------------------------------

Update the server shapes to change the fingerprint of this shape
  $ cat > $TESTTMP/new-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "default"
  > requires = ["base", "secrets"]
  > shape = true
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
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: fingerprint mismatch for shape 'default'
    server: 'a51b6c5dbfb838215a64a972c8c297233be7731e12f566dee567fd17ef0cd5c5'
    client: '00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea'
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: fingerprint mismatch for shape 'default'
    server: 'a51b6c5dbfb838215a64a972c8c297233be7731e12f566dee567fd17ef0cd5c5'
    client: '00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea'
  abort: pull failed on remote
  [100]
#endif

Check that a shape being removed is detected
--------------------------------------------

Update the server shapes to remove the shape
  $ cat > $TESTTMP/new-shapes <<EOF
  > version = 0
  > [[shards]]
  > name = "from-file"
  > paths = ["dir1"]
  > shape = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: shape not found on remote: 'default'
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: shape not found on remote: 'default'
  abort: pull failed on remote
  [100]
#endif

Reset the shapes
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/starting-shapes


Test widening/narrowing
=======================

#if no-local

(It does not make sense to widen/narrow a repo from itself)

Cannot use other arguments than `--store-shape`
----------------------------------------

  $ hg tracked --addinclude foobar
  abort: only `--store-shape` is supported
  (this repository has a narrow shape)
  [20]
  $ hg tracked --addinclude foobar --store-shape full-manual
  abort: cannot specify both --store-shape and --addinclude
  [10]
  $ hg tracked --removeexclude foobar
  abort: only `--store-shape` is supported
  (this repository has a narrow shape)
  [20]

Expected errors with the wrong shape name
-----------------------------------------

  $ hg tracked --store-shape unknown-shape
  comparing with ssh://user@dummy/server
  abort: shape not found on remote: 'unknown-shape'
  [10]

Actual widening succeeds
------------------------

  $ hg tracked --store-shape full-manual
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 5 changes to 4 files
  $ hg cat foo/bar/other-secret/secret-file
  new secret contents

Narrowing also succeeds
-----------------------

  $ hg tracked --store-shape default
  comparing with ssh://user@dummy/server
  searching for changes
  looking for local changes to affected paths
  deleting data/foo/bar/other-secret/secret-file.i
  deleting data/foo/bar/other-secret/secret-file2.i
  deleting data/secret/secret-file.i
  deleting data/secret/secret-file2.i
  deleting unwanted files from working copy
  $ hg cat foo/bar/other-secret/secret-file
  [1]

Widening and narrowing at the same time succeeds
------------------------------------------------

  $ hg tracked --store-shape other-secret
  comparing with ssh://user@dummy/server
  searching for changes
  looking for local changes to affected paths
  deleting data/dir1/file1.i
  deleting data/file1.i
  deleting data/file2.i
  deleting data/file3.i
  deleting data/foo/file1.i
  deleting data/foo/file2.i
  deleting unwanted files from working copy
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 3 changes to 2 files
  $ hg cat foo/bar/other-secret/secret-file
  new secret contents
  $ hg cat file1
  [1]

#endif
