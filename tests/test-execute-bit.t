#require execbit

  $ hg init repo
  $ cd repo
  $ echo a > a
  $ hg ci -Am'not executable'
  adding a

  $ chmod +x a
  $ hg ci -m'executable'
  $ hg id
  79abf14474dc tip

Make sure we notice the change of mode if the cached size == -1:

  $ hg rm a
  $ hg revert -r 0 a
  $ hg debugstate
  n   0         -1 unset               a
  $ hg status
  M a

  $ hg up 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg id
  d69afc33ff8a
  $ test -x a && echo executable -- bad || echo not executable -- good
  not executable -- good

#if unix-permissions

Executable file permissions follow the umask during update. The Python update path
creates an executable file with mode 0775 under umask 0002.

  $ hg up -q null
  $ (umask 0002; hg up -q 1 --config rust.update-from-null=false --config rust.update-from-clean=false)
  $ f --mode a
  a: mode=775

The Rust update-from-null path should behave the same way.

#if rust
  $ hg up -q null
  $ (umask 0002; hg up -q 1 --config rust.update-from-null=true)
  $ f --mode a
  a: mode=775
#endif

#endif

