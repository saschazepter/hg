=============================================================
Test aborting transactions with devel.debug.abort-transaction
=============================================================

Set up a base repo with one changeset

  $ hg init base
  $ touch base/a
  $ hg -R base commit -qAm 0

The tests in this file use the following approach:

1. Run a command that does a transaction, like `hg commit`
2. Abort the transaction or cause it to fail in some way
3. Run `hg recover` to recover from an abandoned transaction,
or to demonstrate that there is no abandoned transaction
4. Run `hg log` and `hg status` to show the final state

Test post-finalize abort
------------------------

If we abort at post-finalize, hg should roll back the transaction.
This just raises error.Abort, so it's similar to what would happen
if an unexpected error occurred at this point.

  $ hg clone -q base post-finalize-abort
  $ cd post-finalize-abort
  $ echo change > a
  $ hg commit -m change --config devel.debug.abort-transaction=post-finalize
  transaction abort!
  rollback completed
  abort: requested abort at post-finalize
  [255]
  $ hg recover
  no interrupted transaction available
  [1]

The change is uncommitted in the working copy
  $ hg log -T '{rev}: {desc}\n'
  0: 0
  $ hg status
  M a

  $ cd ..


#if no-windows

Test post-finalize SIGTERM
--------------------------

If we send SIGTERM, it causes an abort, so this behaves similarly to
"Test post-finalize abort" (hg should roll back the transaction).


  $ hg clone -q base post-finalize-sigterm
  $ cd post-finalize-sigterm
  $ echo change > a
  $ hg commit -m change --config devel.debug.abort-transaction=post-finalize \
  >   --config devel.debug.abort-transaction:method=sigterm
  transaction abort!
  rollback completed
  killed!
  [255]
  $ hg recover
  no interrupted transaction available
  [1]

The change is uncommitted in the working copy
  $ hg log -T '{rev}: {desc}\n'
  0: 0
  $ hg status
  M a

  $ cd ..

#endif

Test post-finalize SIGKILL
--------------------------

If we send SIGKILL at post-finalize, hg should leave an abandoned transaction on
disk. We can recover from that by running `hg recover`.

  $ hg clone -q base post-finalize-sigkill
  $ cd post-finalize-sigkill
  $ echo change > a
  $ hg commit -m change --config devel.debug.abort-transaction=post-finalize \
  >   --config devel.debug.abort-transaction:method=sigkill || echo exit=$?
  *Killed* (glob) (no-chg !)
  exit=137 (no-chg !)
  exit=255 (chg !)
  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)

The change is uncommitted in the working copy
  $ hg log -T '{rev}: {desc}\n'
  0: 0
  $ hg status
  M a

  $ cd ..
