#require rust

Setup the repo
  $ hg init server
  $ cd server

Normal cases
------------

Setup the server shapes config
  $ cat > .hg/store/server-shapes <<EOF
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
-----------------------------------------

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
