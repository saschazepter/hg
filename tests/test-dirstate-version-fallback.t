  $ cat >> $HGRCPATH << EOF
  > [storage]
  > dirstate-v2.slow-path=allow
  > [format]
  > use-dirstate-v2=no
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

  $ hg debugupgraderepo -q --config format.use-dirstate-v2=1 --run | egrep 'added:|removed:'
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
  $ ls -1 .hg/dirstate*
  .hg/dirstate
  .hg/dirstate.* (glob)

Corrupt the dirstate to see how the errors show up to the user
  $ echo "I ate your data" > .hg/dirstate

  $ hg st
  abort: working directory state appears damaged! (no-rhg !)
  (falling back to dirstate-v1 from v2 also failed) (no-rhg !)
  abort: Too little data for dirstate. (rhg !)
  [255]
