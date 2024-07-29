  $ hg init repo
  $ cd repo
  $ echo a > a
  $ hg ci -Am0
  adding a

  $ hg -q clone . foo

  $ touch .hg/store/journal

  $ echo foo > a
  $ hg ci -Am0
  abort: abandoned transaction found
  (run 'hg recover' to clean up transaction)
  [255]

  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)

recover, explicit verify

  $ touch .hg/store/journal
  $ hg ci -Am0
  abort: abandoned transaction found
  (run 'hg recover' to clean up transaction)
  [255]
  $ hg recover --verify  -q

recover, no verify

  $ touch .hg/store/journal
  $ hg ci -Am0
  abort: abandoned transaction found
  (run 'hg recover' to clean up transaction)
  [255]
  $ hg recover --no-verify
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)


Check that zero-size journals are correctly aborted:

#if unix-permissions no-root
  $ hg bundle -qa repo.hg
  $ chmod -w foo/.hg/store/00changelog.i

#if rust
  $ hg -R foo unbundle repo.hg
  adding changesets
  transaction abort!
  rollback completed
  abort: abort: when writing $TESTTMP/repo/foo/.hg/store/00changelog.i: $EACCES$
  [50]
#else
  $ hg -R foo unbundle repo.hg
  adding changesets
  transaction abort!
  rollback completed
  abort: $EACCES$: '$TESTTMP/repo/foo/.hg/store/.00changelog.i-*' (glob)
  [255]
#endif

  $ if test -f foo/.hg/store/journal; then echo 'journal exists :-('; fi
#endif

