#require rust-front no-pure

Module policy of the hg-bin front end
=====================================

The `[policy] rust-pyext` configuration controls the use of the Rust extensions
by the Python code: the front end sets $HGMODULEPOLICY for it, unless the
variable is already set. The test runner sets the variable for some flavors, so
the cases below unset it explicitly.

  $ policy () {
  >   hg debuginstall -T '{hgmodulepolicy}\n'
  > }
  $ cp $HGRCPATH $HGRCPATH.orig

the built-in policy applies without configuration
-------------------------------------------------

  $ (unset HGMODULEPOLICY; policy)
  rust+c (rust !)
  c (no-rust !)

"always" requires the Rust extensions
-------------------------------------

  $ cat >> $HGRCPATH <<EOF
  > [policy]
  > rust-pyext = always
  > EOF
#if rust-ext
  $ (unset HGMODULEPOLICY; policy)
  rust+c
#else
  $ (unset HGMODULEPOLICY; policy)
  abort: this Mercurial installation does not include the Rust extensions
  (policy.rust-pyext is "always", "auto" would skip them)
  [255]
#endif

an existing variable prevails over the configuration
----------------------------------------------------

  $ HGMODULEPOLICY=allow policy
  allow

an empty variable defers to the configuration
---------------------------------------------

#if rust-ext
  $ HGMODULEPOLICY= policy
  rust+c
#else
  $ HGMODULEPOLICY= policy
  abort: this Mercurial installation does not include the Rust extensions
  (policy.rust-pyext is "always", "auto" would skip them)
  [255]
#endif

"never" keeps the Rust extensions out of the policy
---------------------------------------------------

The value written last wins, as in any configuration file.

  $ cat >> $HGRCPATH <<EOF
  > [policy]
  > rust-pyext = never
  > EOF
  $ (unset HGMODULEPOLICY; policy)
  c

"auto" uses the Rust extensions when they are installed
-------------------------------------------------------

  $ cat >> $HGRCPATH <<EOF
  > [policy]
  > rust-pyext = auto
  > EOF
  $ (unset HGMODULEPOLICY; policy)
  rust+c (rust-ext !)
  c (no-rust-ext !)

"default" keeps the built-in policy
-----------------------------------

  $ cat >> $HGRCPATH <<EOF
  > [policy]
  > rust-pyext = default
  > EOF
  $ (unset HGMODULEPOLICY; policy)
  rust+c (rust !)
  c (no-rust !)

an unknown value disables the Rust extensions
---------------------------------------------

  $ cat >> $HGRCPATH <<EOF
  > [policy]
  > rust-pyext = maybe
  > EOF
  $ (unset HGMODULEPOLICY; policy)
  c

repository level configuration is ignored
-----------------------------------------

  $ hg init babar
  $ cd babar
  $ cat >> .hg/hgrc <<EOF
  > [policy]
  > rust-pyext = always
  > EOF
  $ (unset HGMODULEPOLICY; policy)
  c
  $ cd ..

The feature conditions on the output above are checked once the test ran:
restore the configuration they see.

  $ cp $HGRCPATH.orig $HGRCPATH
