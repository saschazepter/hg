=================================
Shape fingerprint of a narrowspec
=================================

This test is going to disappear soon, because this command will not be around
for more than a couple versions (writing this at the end of the 7.2 cycle)

Equivalent narrowspecs
----------------------

Patterns already covered by a parent one do not change the fingerprint.

  $ cat > narrowspec <<EOF
  > [include]
  > path:foo
  > path:foobar
  > [exclude]
  > path:foo/bar
  > EOF

  $ cat > narrowspec-same <<EOF
  > [include]
  > path:foo
  > path:foobar
  > path:foobar/other
  > [exclude]
  > path:foo/bar
  > path:foo/bar/baz
  > EOF

  $ cat > narrowspec-different <<EOF
  > [include]
  > path:foo
  > [exclude]
  > path:foo/bar
  > path:foo/bar/baz
  > EOF

  $ hg debug::narrow-fingerprint < narrowspec
  shape01-418205b43a896cb47131afe42632fefa1749826d3d2420125ea96403f1cb8fa9
  $ hg debug::narrow-fingerprint < narrowspec-same
  shape01-418205b43a896cb47131afe42632fefa1749826d3d2420125ea96403f1cb8fa9
  $ hg debug::narrow-fingerprint < narrowspec-different
  shape01-7fb93baea025185c47c2a460552b057db0057ea13f2cda69274758aa2b1d4125

Excludes take precedence over includes
--------------------------------------

A path both included and excluded (it happens with `--import-rules`) is
excluded: the fingerprint is the one of the narrowspec without that path.

  $ cat > bar-only <<EOF
  > [include]
  > path:bar
  > EOF
  $ cat > foo-bar-minus-foo <<EOF
  > [include]
  > path:foo
  > path:bar
  > [exclude]
  > path:foo
  > EOF

  $ hg debug::narrow-fingerprint < bar-only
  shape01-b109b406b6216c0cadca1000b63cccdcef441c6f88a5a0c2c529bb4376a809ca
  $ hg debug::narrow-fingerprint < foo-bar-minus-foo
  shape01-b109b406b6216c0cadca1000b63cccdcef441c6f88a5a0c2c529bb4376a809ca

Excluding everything that is included gives the fingerprint of an empty shape,
whether through a path or through the root itself.

  $ cat > foo-minus-foo <<EOF
  > [include]
  > path:foo
  > [exclude]
  > path:foo
  > EOF
  $ cat > root-minus-root <<EOF
  > [include]
  > path:
  > [exclude]
  > path:
  > EOF

  $ hg debug::narrow-fingerprint < foo-minus-foo
  shape01-10487d86ce3584e156874ed9b2650e8d772a8d1fdbb1c9111bf7e2fbcab18ccb
  $ hg debug::narrow-fingerprint < root-minus-root
  shape01-10487d86ce3584e156874ed9b2650e8d772a8d1fdbb1c9111bf7e2fbcab18ccb

The "path:" prefix is stripped only once
----------------------------------------

What follows the prefix is a literal path, even when it looks like another
pattern prefix.

  $ cat > path-path-foo <<EOF
  > [include]
  > path:path:foo
  > EOF
  $ cat > path-glob-foo <<EOF
  > [include]
  > path:glob:foo
  > EOF

  $ hg debug::narrow-fingerprint < path-path-foo
  shape01-1218a8880c98b085bc983b5736eb4c1d70878e0b0f94e6f7794c30dee8541df4
  $ hg debug::narrow-fingerprint < path-glob-foo
  shape01-22510134c2e59c0b8fa8cb4fdffbfcbd704606b5590be3d676bc56cbc972bd4a

Narrowspecs that cannot be fingerprinted
----------------------------------------

  $ hg debug::narrow-fingerprint < /dev/null
  abort: empty narrowspec given (no-rhg !)
  empty narrowspec given (rhg !)
  [255]

  $ cat > no-prefix <<EOF
  > [include]
  > foo
  > EOF

  $ hg debug::narrow-fingerprint < no-prefix
  abort: invalid prefix on narrow pattern: foo (no-rhg !)
  (narrow patterns must begin with one of the following: path:, rootfilesin:) (no-rhg !)
  invalid prefix on narrow pattern: foo (rhg !)
  [255]

Only "path:" patterns have a shape.

  $ cat > rootfilesin <<EOF
  > [include]
  > rootfilesin:foo
  > EOF

  $ hg debug::narrow-fingerprint < rootfilesin
  abort: only "path:" patterns can be fingerprinted
  [255]
