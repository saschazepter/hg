  $ hg init

  $ echo a > a
  $ hg ci -Ama
  adding a

  $ hg an a
  0: a

  $ hg --config ui.strict=False an a
  0: a

  $ echo "[ui]" >> $HGRCPATH
  $ echo "strict=True" >> $HGRCPATH

  $ hg an a
  hg: unknown command 'an'
  (use 'hg help' for a list of commands)
  [10]
  $ hg annotate a
  0: a

should succeed - up is an alias, not an abbreviation

  $ hg up
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
