#require unix-permissions no-root no-windows

Prepare

  $ hg init a
  $ echo a > a/a
  $ hg -R a ci -A -m a
  adding a

  $ hg clone a b
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that raising an exception in the release function doesn't cause the lock to choke

  $ cat > testlock.py << EOF
  > from mercurial import error, registrar
  > 
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > 
  > def acquiretestlock(repo, releaseexc):
  >     def unlock():
  >         if releaseexc:
  >             raise error.Abort(b'expected release exception')
  >     l = repo._lock(repo.vfs, b'testlock', False, unlock, None, b'test lock')
  >     return l
  > 
  > @command(b'testlockexc')
  > def testlockexc(ui, repo):
  >     testlock = acquiretestlock(repo, True)
  >     try:
  >         testlock.release()
  >     finally:
  >         try:
  >             testlock = acquiretestlock(repo, False)
  >         except error.LockHeld:
  >             raise error.Abort(b'lockfile on disk even after releasing!')
  >         testlock.release()
  > EOF
  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > testlock=$TESTTMP/testlock.py
  > EOF

  $ hg -R b testlockexc
  abort: expected release exception
  [255]

One process waiting for another

  $ SYNC_FILE_LOCKED="$TESTTMP/sync-file-locked"
  $ export SYNC_FILE_LOCKED
  $ SYNC_FILE_TRYING_LOCK="$TESTTMP/sync-file-trying-lock"
  $ export SYNC_FILE_TRYING_LOCK
  $ cat << EOF > locker.sh
  > $RUNTESTDIR/testlib/wait-on-file 10 $SYNC_FILE_TRYING_LOCK $SYNC_FILE_LOCKED;
  > EOF
  $ cat << EOF > waiter.sh
  > $RUNTESTDIR/testlib/wait-on-file 10 $SYNC_FILE_LOCKED;
  > EOF
  $ clean_sync() {
  >   rm -f "$SYNC_FILE_LOCKED"
  >   rm -f "$SYNC_FILE_TRYING_LOCK"
  > }


  $ clean_sync
  $ echo b > b/b
  $ hg -R b ci -A -m b \
  >   --config hooks.precommit="sh $TESTTMP/locker.sh" \
  >   > stdout &
  $ hg -R b up -q \
  >   --config ui.timeout.warn=0 \
  >   --config hooks.pre-update="sh $TESTTMP/waiter.sh" \
  >   --config devel.lock-wait-sync-file="$SYNC_FILE_TRYING_LOCK" \
  >   > preup-stdout 2> preup-stderr
  $ wait
  $ cat preup-stdout
  $ cat preup-stderr
  waiting for lock on working directory of b held by process '*' on host '*' (glob)
  got lock after * seconds (glob)
  $ cat stdout
  adding b

On processs waiting on another, warning after a long time.

  $ clean_sync
  $ echo b > b/c
  $ hg -R b ci -A -m b \
  >   --config hooks.precommit="sh $TESTTMP/locker.sh" \
  >   > stdout &
  $ hg -R b up -q \
  >   --config hooks.pre-update="sh $TESTTMP/waiter.sh" \
  >   --config devel.lock-wait-sync-file="$SYNC_FILE_TRYING_LOCK" \
  >   --config ui.timeout.warn=250 \
  >   > preup-stdout 2> preup-stderr
  $ wait
  $ cat preup-stdout
  $ cat preup-stderr
  $ cat stdout
  adding c

On processs waiting on another, warning disabled.

  $ clean_sync
  $ echo b > b/d
  $ hg -R b ci -A -m b \
  >   --config hooks.precommit="sh $TESTTMP/locker.sh" \
  >   > stdout &
  $ hg -R b up -q \
  >   --config hooks.pre-update="sh $TESTTMP/waiter.sh" \
  >   --config devel.lock-wait-sync-file="$SYNC_FILE_TRYING_LOCK" \
  >   --config ui.timeout.warn=-1 \
  >   > preup-stdout 2>preup-stderr
  $ wait
  $ cat preup-stdout
  $ cat preup-stderr
  $ cat stdout
  adding d

check we still print debug output

On processs waiting on another, warning after a long time (debug output on)

  $ clean_sync
  $ echo b > b/e
  $ hg -R b ci -A -m b \
  >   --config hooks.precommit="sh $TESTTMP/locker.sh" \
  >   > stdout &
  $ hg -R b up \
  >   --config hooks.pre-update="sh $TESTTMP/waiter.sh" \
  >   --config devel.lock-wait-sync-file="$SYNC_FILE_TRYING_LOCK" \
  >   --config ui.timeout.warn=250 --debug \
  >   > preup-stdout 2>preup-stderr
  $ wait
  $ cat preup-stdout
  running hook pre-update: sh $TESTTMP/waiter.sh
  waiting for lock on working directory of b held by process '*' on host '*' (glob)
  got lock after * seconds (glob)
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat preup-stderr
  $ cat stdout
  adding e

On processs waiting on another, warning disabled, (debug output on)

  $ clean_sync
  $ echo b > b/f
  $ hg -R b ci -A -m b \
  >   --config hooks.precommit="sh $TESTTMP/locker.sh" \
  >   > stdout &
  $ hg -R b up \
  >   --config hooks.pre-update="sh $TESTTMP/waiter.sh" \
  >   --config devel.lock-wait-sync-file="$SYNC_FILE_TRYING_LOCK" \
  >   --config ui.timeout.warn=-1 --debug\
  >   > preup-stdout 2>preup-stderr
  $ wait
  $ cat preup-stdout
  running hook pre-update: sh $TESTTMP/waiter.sh
  waiting for lock on working directory of b held by process '*' on host '*' (glob)
  got lock after * seconds (glob)
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat preup-stderr
  $ cat stdout
  adding f

Pushing to a local read-only repo that can't be locked

  $ chmod 100 a/.hg/store

  $ hg -R b push a
  pushing to a
  searching for changes
  abort: could not lock repository a: $EACCES$
  [20]

  $ chmod 700 a/.hg/store
