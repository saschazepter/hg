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
  851381269360802254c87a7a6d5b1c45f6b6e7bc62df68a1fb205536b210250a
  $ cat narrowspec-same | hg debug::narrow-fingerprint
  851381269360802254c87a7a6d5b1c45f6b6e7bc62df68a1fb205536b210250a
  $ cat narrowspec-different | hg debug::narrow-fingerprint
  854abbee97d1548a264c537d37381b90436ccedc56d6f92586d3ae1e7cc4d04b
