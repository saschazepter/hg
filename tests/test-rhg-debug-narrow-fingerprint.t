#require rhg

  $ RHG_ON_UNSUPPORTED=abort
  $ export RHG_ON_UNSUPPORTED

This test is going to disappear soon, because this command will not be around
for more than a couple versions (writing this at the end of the 7.2 cycle)

Create some narrowspec files

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

Test the command

  $ hg debug::narrow-fingerprint
  empty narrowspec given
  [255]
  $ cat narrowspec | hg debug::narrow-fingerprint
  shape00-418205b43a896cb47131afe42632fefa1749826d3d2420125ea96403f1cb8fa9
  $ cat narrowspec-same | hg debug::narrow-fingerprint
  shape00-418205b43a896cb47131afe42632fefa1749826d3d2420125ea96403f1cb8fa9
  $ cat narrowspec-different | hg debug::narrow-fingerprint
  shape00-7fb93baea025185c47c2a460552b057db0057ea13f2cda69274758aa2b1d4125
