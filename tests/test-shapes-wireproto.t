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
  > version = 1
  > [[shards]]
  > name = "secrets"
  > paths = ["secret"]
  > [[shards]]
  > name = "other-secret-files"
  > paths = ["foo/bar/other-secret"]
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
  $ hg admin::narrow-server --store-sharding-update -f $TESTTMP/starting-shapes --override-reshape-and-reshard-check


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
  > advertise-store-shapes=no
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
  > advertise-store-shapes=yes
  > EOF

Test error cases
----------------

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     names eval:[b'unknown-shape']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: store profile not found on remote: 'unknown-shape'
  [10]

  $ hg debugwireproto --localssh << EOF
  > command store_shape
  >     # try a shard
  >     names eval:[b'secrets']
  > EOF
  creating ssh peer from handshake results
  sending store_shape command
  abort: store profile not found on remote: 'secrets'
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
  abort: fingerprint mismatch for the store shape of 'default'
  (server: [shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512], client: shape00-ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)
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
      ShapeFingerprint(version=1, digest=b'\x8e\x95\x8f\xfc\x18\xc1\x83q\xe8\xdf\x8a2\xb7R\x131m\x89\x84\xcb\xe0\xa0\xcb\x14c|qVJ\x9f\xd5S')
    ],
    [
      set([
        ShardFingerprint(version=1, digest=b'7\x11\xce2S\xa3^S\xb8\xfb\x7f\xf9:\r\xa0\xe4\x83%O\x17\xce\x1fP4\xba\x98`\xd7\xf6\xf6\xd8\x95'),
        ShardFingerprint(version=1, digest=b'\xc4\x91\xfc\x7fG\x80\xd4\x90\xa8\x15l8\x88\xe5\x91\x10\x1a\xccq\xf3\x0fj\x04\x81\xa2\xe1\xb4K^i\xcc\xb6')
      ])
    ],
    (
      set([
        b'path:.hgeol',
        b'path:.hgignore',
        b'path:.hglfs',
        b'path:.hgsigs',
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
      ShapeFingerprint(version=1, digest=b'\xb0\xd3N\xda\x1d\xf9\x8b\x87\x1c|\xcbrT\xb6\x11\x87\xa6\xa7\xea\xb6\x1b\xc3D\xe9\x8c.Pz\xb6^\x15\x12')
    ],
    [
      set([
        ShardFingerprint(version=1, digest=b'\x06\x130\xec\x02F\xe2\x18\xf2\\\xbe\x1b\xec\x82\xcf~jl\xfc\x02,\x9a\x85 \xdeA\xe2\xd5C\x15i\xda'),
        ShardFingerprint(version=1, digest=b'7\x11\xce2S\xa3^S\xb8\xfb\x7f\xf9:\r\xa0\xe4\x83%O\x17\xce\x1fP4\xba\x98`\xd7\xf6\xf6\xd8\x95')
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
      ShapeFingerprint(version=1, digest=b'\x0c\xa8Q\xef|\xda\x7f\xb1\x82Bd\xb2\x0f\xf0\x0fQ\xc6\x17U\xbb\x91\xee\x12\xf5\xf9\x0cV8k?\x99\xf4')
    ],
    [
      set([
        ShardFingerprint(version=1, digest=b'\x06\x130\xec\x02F\xe2\x18\xf2\\\xbe\x1b\xec\x82\xcf~jl\xfc\x02,\x9a\x85 \xdeA\xe2\xd5C\x15i\xda'),
        ShardFingerprint(version=1, digest=b'7\x11\xce2S\xa3^S\xb8\xfb\x7f\xf9:\r\xa0\xe4\x83%O\x17\xce\x1fP4\xba\x98`\xd7\xf6\xf6\xd8\x95'),
        ShardFingerprint(version=1, digest=b'\xc4\x91\xfc\x7fG\x80\xd4\x90\xa8\x15l8\x88\xe5\x91\x10\x1a\xccq\xf3\x0fj\x04\x81\xa2\xe1\xb4K^i\xcc\xb6')
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
  abort: store profile not found on remote: 'unknown-shape'
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
  abort: store profile not found on remote: 'unknown-shape'
  [10]

Test a valid shape

  $ $POLICY hg clone $remote_url narrow-clone $remote_cmd --store-shape default --quiet
  $ cd narrow-clone

Check that we track the correct paths
  $ hg tracked
  I path:.
  X path:foo/bar/other-secret
  X path:secret
  $ cat .hg/store/store-shape
  0
  default
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

Test narrow clone with a composite shape
========================================

Comma-separated names in `--store-shape` clone their composite shape.

  $ cd $TESTTMP

An unknown name is reported by itself
-------------------------------------

  $ $POLICY hg clone $remote_url composite-clone $remote_cmd --store-shape default,unknown-shape
  abort: store profile not found on remote: 'unknown-shape'
  [10]

Names are checked before anything is sent
-----------------------------------------

  $ $POLICY hg clone $remote_url composite-clone $remote_cmd --store-shape default,Babar
  abort: invalid store profile name 'Babar'
  (only lowercase alphanumeric, hyphen or dot are accepted)
  [10]

The composite shape covers every file either shape covers
---------------------------------------------------------

  $ $POLICY hg clone $remote_url composite-clone $remote_cmd --store-shape other-secret,default --quiet

  $ hg -R composite-clone tracked
  I path:.
  X path:secret
  $ hg -R composite-clone files | grep other-secret
  composite-clone/foo/bar/other-secret/secret-file
  composite-clone/foo/bar/other-secret/secret-file2

Both names are recorded and kept when pulling
---------------------------------------------

  $ cat composite-clone/.hg/store/store-shape
  0
  default,other-secret
  $ hg -R composite-clone admin::narrow-client --store-shape-fingerprint
  shape01-0ca851ef7cda7fb1824264b20ff00f51c61755bb91ee12f5f90c56386b3f99f4

  $ hg -R composite-clone pull
  pulling from $TESTTMP/server (local !)
  pulling from ssh://user@dummy/server (no-local !)
  searching for changes
  no changes found

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
  >     store_shape_with_fingerprint default,,other-secret:shape01-0000000000000000000000000000000000000000000000000000000000000000
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
  >     store_shape_with_fingerprint default,unknown-shape:shape01-0000000000000000000000000000000000000000000000000000000000000000
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: abort: store profile not found on remote: 'unknown-shape'

The fingerprint must be the one of the composite shape
------------------------------------------------------

  $ hg debugwireproto --localssh << EOF
  > command getbundle
  >     source pull
  >     store_shape_with_fingerprint default,other-secret:shape01-0000000000000000000000000000000000000000000000000000000000000000
  > EOF
  creating ssh peer from handshake results
  sending getbundle command
  response: <mercurial.changegroup.cg1unpacker object at 0x*> (glob)
  remote: abort: fingerprint mismatch for the store shape of 'default,other-secret'
  remote: (server: shape01-0ca851ef7cda7fb1824264b20ff00f51c61755bb91ee12f5f90c56386b3f99f4, client: shape01-0000000000000000000000000000000000000000000000000000000000000000)

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
  > version = 1
  > [[shards]]
  > name = "secrets"
  > paths = ["secret"]
  > [[shards]]
  > name = "other-secret-files"
  > paths = ["foo/bar/other-secret"]
  > 
  > [[profiles]]
  > name = "default"
  > includes = ["base", "secrets", "other-secret"]
  > public = true
  > [[profiles]]
  > name = "full-manual"
  > includes = ["base", "secrets", "other-secret"]
  > public = true
  > [[profiles]]
  > name = "other-secret"
  > includes = ["other-secret-files"]
  > public = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-clear-previous
  cleared 0 saved server-sharding
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/new-shapes --override-fingerprint-change-check

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: fingerprint mismatch for the store shape of 'default'
  (server: shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: fingerprint mismatch for the store shape of 'default'
  abort: pull failed on remote
  (server: shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
  [100]
#endif

Check that a shape being removed is detected
--------------------------------------------

Update the server shapes to remove the shape
  $ cat > $TESTTMP/new-shapes <<EOF
  > version = 1
  > [[shards]]
  > name = "dir1"
  > paths = ["dir1"]
  > [[profiles]]
  > name = "from-file"
  > includes = ["dir1"]
  > public = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/new-shapes --override-reshape-and-reshard-check

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: store profile not found on remote: 'default'
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: store profile not found on remote: 'default'
  abort: pull failed on remote
  [100]
#endif

Reset the shapes, clearing the config the resharding above saved
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-clear-previous
  cleared 1 saved server-sharding
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/starting-shapes --override-reshape-and-reshard-check

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
  > version = 1
  > [[shards]]
  > name = "secrets"
  > paths = ["secret"]
  > [[shards]]
  > name = "other-secret-files"
  > paths = ["foo/bar/other-secret"]
  > 
  > [[profiles]]
  > name = "default"
  > includes = ["base", "secrets", "other-secret"]
  > public = true
  > [[profiles]]
  > name = "full-manual"
  > includes = ["base", "secrets", "other-secret"]
  > public = true
  > [[profiles]]
  > name = "other-secret"
  > includes = ["other-secret-files"]
  > public = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-clear-previous
  cleared 1 saved server-sharding
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/new-shapes --override-fingerprint-change-check

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: fingerprint mismatch for the store shape of 'default'
  (server: shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: fingerprint mismatch for the store shape of 'default'
  abort: pull failed on remote
  (server: shape01-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545, client: shape01-b0d34eda1df98b871c7ccb7254b61187a6a7eab61bc344e98c2e507ab65e1512)
  [100]
#endif

Check that a shape being removed is detected
--------------------------------------------

Update the server shapes to remove the shape
  $ cat > $TESTTMP/new-shapes <<EOF
  > version = 1
  > [[shards]]
  > name = "dir1"
  > paths = ["dir1"]
  > [[profiles]]
  > name = "from-file"
  > includes = ["dir1"]
  > public = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/new-shapes --override-reshape-and-reshard-check

#if local
  $ hg pull
  pulling from $TESTTMP/server
  searching for changes
  abort: store profile not found on remote: 'default'
  [255]
#else
  $ hg pull
  pulling from ssh://user@dummy/server
  searching for changes
  remote: abort: store profile not found on remote: 'default'
  abort: pull failed on remote
  [100]
#endif

Reset the shapes, clearing the config the resharding above saved
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-clear-previous
  cleared 1 saved server-sharding
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/starting-shapes --override-reshape-and-reshard-check

Check that a server without store shape support is refused
----------------------------------------------------------

#if no-local
A server without the Rust extensions cannot compute store shapes.

  $ cat > $TESTTMP/pure-server-hg.sh << EOF
  > #!/bin/sh
  > HGMODULEPOLICY=py
  > export HGMODULEPOLICY
  > hg "\$@"
  > EOF
  $ chmod +x $TESTTMP/pure-server-hg.sh
  $ hg pull --remotecmd $TESTTMP/pure-server-hg.sh
  pulling from ssh://user@dummy/server
  searching for changes
  abort: server does not support store shapes
  (this repository has the store shape of 'default')
  [100]

A server without the narrow extension does not support narrow at all.

  $ cat > $TESTTMP/no-narrow.rc << EOF
  > [extensions]
  > narrow=!
  > EOF
  $ cat > $TESTTMP/no-narrow-server-hg.sh << EOF
  > #!/bin/sh
  > HGRCPATH="\$HGRCPATH:$TESTTMP/no-narrow.rc"
  > export HGRCPATH
  > hg "\$@"
  > EOF
  $ chmod +x $TESTTMP/no-narrow-server-hg.sh
  $ hg pull --remotecmd $TESTTMP/no-narrow-server-hg.sh
  pulling from ssh://user@dummy/server
  searching for changes
  abort: server does not support narrow, but client has a store shape
  [100]
#endif

A server can also choose not to advertise store shapes.

  $ cat > $TESTTMP/no-store-shapes.rc << EOF
  > [experimental]
  > advertise-store-shapes=no
  > EOF
  $ HGRCPATH="$HGRCPATH:$TESTTMP/no-store-shapes.rc" hg pull
  pulling from $TESTTMP/server (local !)
  pulling from ssh://user@dummy/server (no-local !)
  searching for changes
  abort: server does not support store shapes
  (this repository has the store shape of 'default')
  [100]


Test widening/narrowing
=======================

#if no-local

(It does not make sense to widen/narrow a repo from itself)

Cannot use other arguments than `--store-shape`
----------------------------------------

  $ hg tracked --addinclude foobar
  abort: only `--store-shape` is supported
  (this repository has a store shape)
  [20]
  $ hg tracked --addinclude foobar --store-shape full-manual
  abort: cannot specify both --store-shape and --addinclude
  [10]
  $ hg tracked --removeexclude foobar
  abort: only `--store-shape` is supported
  (this repository has a store shape)
  [20]

Expected errors with the wrong shape name
-----------------------------------------

  $ hg tracked --store-shape unknown-shape
  comparing with ssh://user@dummy/server
  abort: store profile not found on remote: 'unknown-shape'
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

Names of a composite shape are checked before anything is sent
--------------------------------------------------------------

  $ hg tracked --store-shape default,Babar
  abort: invalid store profile name 'Babar'
  (only lowercase alphanumeric, hyphen or dot are accepted)
  [10]

A composite shape tracks the union
----------------------------------

  $ hg tracked --store-shape default,other-secret
  comparing with ssh://user@dummy/server
  searching for changes
  looking for local changes to affected paths
  deleting data/foo/bar/other-secret/secret-file.i
  deleting data/foo/bar/other-secret/secret-file2.i
  deleting unwanted files from working copy
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 10 changes to 8 files

  $ hg tracked
  I path:.
  X path:secret
  $ cat .hg/store/store-shape
  0
  default,other-secret
  $ hg cat foo/bar/other-secret/secret-file
  new secret contents
  $ hg cat file1
  file1 contents
  new contents

Switching to a shape with the same fingerprint
----------------------------------------------

If profile names have changed but the shape fingerprint hasn't, we update the store-shape
file even though there is nothing to widen or narrow.

  $ cp $TESTTMP/starting-shapes $TESTTMP/alias-shapes
  $ cat >> $TESTTMP/alias-shapes <<EOF
  > [[profiles]]
  > name = "default-and-other-secret"
  > includes = ["default", "other-secret"]
  > public = true
  > EOF
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-clear-previous
  cleared 1 saved server-sharding
  $ hg -R $TESTTMP/server admin::narrow-server --store-sharding-update -f $TESTTMP/alias-shapes

  $ hg tracked --store-shape default-and-other-secret
  comparing with ssh://user@dummy/server
  nothing to widen or narrow
  $ cat .hg/store/store-shape
  0
  default-and-other-secret

A repo without a store-shape file gets one
------------------------------------------

When the patterns don't match the shape, narrowing or widening writes the file.

  $ rm -f .hg/store/store-shape
  $ hg tracked --store-shape default
  comparing with ssh://user@dummy/server
  searching for changes
  looking for local changes to affected paths
  deleting data/foo/bar/other-secret/secret-file.i
  deleting data/foo/bar/other-secret/secret-file2.i
  deleting unwanted files from working copy
  $ cat .hg/store/store-shape 2>/dev/null
  0
  default

When the patterns already match the shape, we just write the file.

  $ rm -f .hg/store/store-shape
  $ hg tracked --store-shape default
  comparing with ssh://user@dummy/server
  nothing to widen or narrow
  $ cat .hg/store/store-shape 2>/dev/null || echo "no store-shape file"
  0
  default

Clone using narrowspec, then run `tracked` with profiles of the same shape. We write the
file without narrowing or widening.

  $ cd $TESTTMP
  $ hg clone $remote_url narrow-to-profiles $remote_cmd --quiet --narrow \
  >   --include path: --exclude path:secret --exclude path:foo/bar/other-secret
  $ cd narrow-to-profiles
  $ hg tracked
  I path:
  X path:foo/bar/other-secret
  X path:secret
  $ hg tracked --store-shape default
  comparing with ssh://user@dummy/server
  nothing to widen or narrow
  $ cat .hg/store/store-shape 2>/dev/null
  0
  default

Changing the shape afterwards only fetches the difference.

  $ hg tracked
  I path:
  X path:foo/bar/other-secret
  X path:secret
  $ hg tracked --store-shape default,other-secret
  comparing with ssh://user@dummy/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 5 changes to 2 files
  $ hg tracked
  I path:.
  X path:secret

Excluding a path under an already excluded directory is redundant. A narrowspec with such
an exclude still covers the same files.

  $ cd $TESTTMP
  $ hg clone $remote_url nested-exclude-clone $remote_cmd --quiet --narrow \
  >   --exclude path:secret --exclude path:secret/nested \
  >   --exclude path:foo/bar/other-secret
  $ cd nested-exclude-clone
  $ hg tracked
  I path:.
  X path:foo/bar/other-secret
  X path:secret
  X path:secret/nested
  $ hg tracked --store-shape default
  comparing with ssh://user@dummy/server
  nothing to widen or narrow
  $ cat .hg/store/store-shape 2>/dev/null
  0
  default

#endif
