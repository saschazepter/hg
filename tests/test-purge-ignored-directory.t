skip ignored directories if -i or --all not specified

  $ hg init t
  $ cd t
  $ echo 'ignored' > .hgignore
  $ hg ci -qA -m init -d'2 0'
  $ mkdir ignored

The better behavior here is the non-rust behavior, which is to keep
the directory and only delete it when -i or --all is given.

  $ hg purge -v --no-confirm
  removing directory ignored (known-bad-output rust !)
