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
  $ hg admin::narrow-server --shape-update -f $TESTTMP/starting-shapes --override-reshape-and-reshard-check


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
  >     names eval:[b'unknown-shape']
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
  >     names eval:[b'unknown-shape']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: shape not found on remote: 'unknown-shape'
  [10]

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     # try a shard
  >     names eval:[b'secrets']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: shape not found on remote: 'secrets'
  [10]

The fingerprint sent alongside a shape must be well formed

  $ hg debugwireproto --localssh << EOF
  > command getbundle
  >     source pull
  >     store_shape_with_fingerprint default:garbage
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: abort: invalid store shape fingerprint: 'garbage'

Hex, but too short is also caught

  $ hg debugwireproto --localssh << EOF
  > command getbundle
  >     source pull
  >     store_shape_with_fingerprint default:abab
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: abort: invalid store shape fingerprint: 'abab'

The client checks that it computes the same fingerprint as the server for the
patterns it receives. Simulate a divergence by making the client compute a
bogus fingerprint.

  $ cat > $TESTTMP/bogus-fingerprint.py << EOF
  > from mercurial import shape
  > def bogus(includes, excludes):
  >     return shape.ShapeFingerprint(0, b'\xff' * 32)
  > shape.fingerprint_for_patterns = bogus
  > EOF

  $ hg debugwireproto --localssh --config extensions.bogus=$TESTTMP/bogus-fingerprint.py << EOF
  > command store_shape
  >     names eval:[b'default']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: fingerprint mismatch for shape 'default'
  (server: [shape00-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512], client: shape00-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
  [255]

Test valid cases
----------------

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     # valid shape
  >     names eval:[b'other-secret']
  > command store_shape
  >     # valid shape
  >     names eval:[b'default']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  response: (
    [
      ShapeFingerprint(version=0, digest=b'9\x8b)@\xefLx\xce\xa5(\t\xbeK\xcda\x0bo\x1c\xf3\x90\x88p\xa3&L\x02N\xa8\xf0\xbb\x97\xd6')
    ],
    [
      set([
        ShardFingerprint(version=0, digest=b'\x19g\xbf\xea\x8ed \x11\x11\x0bw\x17\xd5\xa6\x8a\xcd\xcaF\xee=\xb5\xede\x92\x86\x01\x02=\x0c`\xcb\x1d'),
        ShardFingerprint(version=0, digest=b'\xc4\x91\xfc\x7fG\x80\xd4\x90\xa8\x15l8\x88\xe5\x91\x10\x1a\xccq\xf3\x0fj\x04\x81\xa2\xe1\xb4K^i\xcc\xb6')
      ])
    ],
    (
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
  )
  sending store_shape command
  response: (
    [
      ShapeFingerprint(version=0, digest=b'\xb0\xd3N\xda\x1d\xf9\x8b\x87\x1c|\xcbrT\xb6\x11\x87\xa6\xa7\xea\xb6\x1b\xc3D\xe9\x8c.Pz\xb6^\x15\x12')
    ],
    [
      set([
        ShardFingerprint(version=0, digest=b'\x19g\xbf\xea\x8ed \x11\x11\x0bw\x17\xd5\xa6\x8a\xcd\xcaF\xee=\xb5\xede\x92\x86\x01\x02=\x0c`\xcb\x1d'),
        ShardFingerprint(version=0, digest=b"O\x0f(Id\xa6\xb4y\xf7\xa0\x06>\xb0\x1bz\xff\x91'\xd2|+\n\x87$\x89\x9f\xf33?\xbb\xa6g")
      ])
    ],
    (
      set([
        b'path:.'
      ]),
      set([
        b'path:foo/bar/other-secret',
        b'path:secret'
      ])
    )
  )

Test composite shapes
---------------------

Comma-separated names designate a composite shape, whatever their order

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     names eval:[b'other-secret', b'default']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  response: (
    [
      ShapeFingerprint(version=0, digest=b'\x0c\xa8Q\xef|\xda\x7f\xb1\x82Bd\xb2\x0f\xf0\x0fQ\xc6\x17U\xbb\x91\xee\x12\xf5\xf9\x0cV8k?\x99\xf4')
    ],
    [
      set([
        ShardFingerprint(version=0, digest=b'\x19g\xbf\xea\x8ed \x11\x11\x0bw\x17\xd5\xa6\x8a\xcd\xcaF\xee=\xb5\xede\x92\x86\x01\x02=\x0c`\xcb\x1d'),
        ShardFingerprint(version=0, digest=b"O\x0f(Id\xa6\xb4y\xf7\xa0\x06>\xb0\x1bz\xff\x91'\xd2|+\n\x87$\x89\x9f\xf33?\xbb\xa6g"),
        ShardFingerprint(version=0, digest=b'\xc4\x91\xfc\x7fG\x80\xd4\x90\xa8\x15l8\x88\xe5\x91\x10\x1a\xccq\xf3\x0fj\x04\x81\xa2\xe1\xb4K^i\xcc\xb6')
      ])
    ],
    (
      set([
        b'path:.'
      ]),
      set([
        b'path:secret'
      ])
    )
  )

Only the name that is not found is reported

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     names eval:[b'default', b'unknown-shape']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: shape not found on remote: 'unknown-shape'
  [10]

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

  $ $POLICY hg clone $remote_url narrow-clone $remote_cmd --store-shape unknown-shape
  abort: shape not found on remote: 'unknown-shape'
  [10]

Test a valid shape

  $ $POLICY hg clone $remote_url narrow-clone $remote_cmd --store-shape default --quiet
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

Test `getbundle` with a composite shape
=======================================

Comma-separated names in `store_shape_with_fingerprint` designate their
composite shape, with the same checks as for a single shape.

  $ cd $TESTTMP/server

Names must not be empty
-----------------------

  $ hg debugwireproto --localssh << EOF
  > command getbundle
  >     source pull
  >     store_shape_with_fingerprint default,,other-secret:shape00-0000000000000000000000000000000000000000000000000000000000000000
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: config error: shard names must not be empty

An unknown name is reported by itself
-------------------------------------

  $ hg debugwireproto --localssh << EOF
  > command getbundle
  >     source pull
  >     store_shape_with_fingerprint default,unknown-shape:shape00-0000000000000000000000000000000000000000000000000000000000000000
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: abort: shape not found on remote: 'unknown-shape'

The fingerprint must be the one of the composite shape
------------------------------------------------------

  $ hg debugwireproto --localssh << EOF
  > command getbundle
  >     source pull
  >     store_shape_with_fingerprint default,other-secret:shape00-0000000000000000000000000000000000000000000000000000000000000000
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: abort: fingerprint mismatch for shape 'default,other-secret'
  remote: (server: shape00-0ca851ef7cda7fb1824264b20ff00f51c61755bb91ee12f5f90c56386b3f99f4, client: shape00-0000000000000000000000000000000000000000000000000000000000000000)

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
  $ hg -R $TESTTMP/server admin::narrow-server --shape-clear-previous
  cleared 0 saved server-shapes
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes --override-fingerprint-change-check

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: fingerprint mismatch for shape 'default'
  (server: shape00-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape00-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: fingerprint mismatch for shape 'default'
  abort: pull failed on remote
  (server: shape00-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape00-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
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
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes --override-reshape-and-reshard-check

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

Reset the shapes, clearing the config the resharding above saved
  $ hg -R $TESTTMP/server admin::narrow-server --shape-clear-previous
  cleared 1 saved server-shapes
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/starting-shapes --override-reshape-and-reshard-check

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
  $ hg -R $TESTTMP/server admin::narrow-server --shape-clear-previous
  cleared 1 saved server-shapes
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes --override-fingerprint-change-check

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: fingerprint mismatch for shape 'default'
  (server: shape00-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape00-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: fingerprint mismatch for shape 'default'
  abort: pull failed on remote
  (server: shape00-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape00-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
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
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/new-shapes --override-reshape-and-reshard-check

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

Reset the shapes, clearing the config the resharding above saved
  $ hg -R $TESTTMP/server admin::narrow-server --shape-clear-previous
  cleared 1 saved server-shapes
  $ hg -R $TESTTMP/server admin::narrow-server --shape-update -f $TESTTMP/starting-shapes --override-reshape-and-reshard-check


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
