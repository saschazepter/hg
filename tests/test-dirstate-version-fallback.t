  $ cat >> $HGRCPATH << EOF
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF

Set up a v1 repo

  $ hg init repo
  $ cd repo
  $ echo a > a
  $ hg add a
  $ hg commit -m a
  $ hg debugrequires | grep dirstate
  [1]
  $ ls -1 .hg/dirstate*
  .hg/dirstate

Copy v1 dirstate
  $ cp .hg/dirstate $TESTTMP/dirstate-v1-backup

Upgrade it to v2

  $ hg debugupgraderepo -q --config format.use-dirstate-v2=1 --run | grep added
     added: dirstate-v2
  $ hg debugrequires | grep dirstate
  dirstate-v2
  $ ls -1 .hg/dirstate*
  .hg/dirstate
  .hg/dirstate.* (glob)

Manually reset to dirstate v1 to simulate an incomplete dirstate-v2 upgrade

  $ rm .hg/dirstate*
  $ cp $TESTTMP/dirstate-v1-backup .hg/dirstate

There should be no errors, but a v2 dirstate should be written back to disk
  $ hg st
  abort: dirstate-v2 parse error: when reading docket, Expected at least * bytes, got * (glob) (known-bad-output !)
  [255]
  $ ls -1 .hg/dirstate*
  .hg/dirstate
  .hg/dirstate.* (glob) (missing-correct-output !)

