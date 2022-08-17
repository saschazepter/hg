skip ignored directories if -i or --all not specified

  $ hg init t
  $ cd t
  $ echo 'ignored' > .hgignore
  $ hg ci -qA -m init -d'2 0'
  $ mkdir ignored
  $ ls
  ignored
  $ hg purge -v --no-confirm
  $ ls
  ignored
