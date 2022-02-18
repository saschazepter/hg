setup

  $ cat > myextension.py <<EOF
  > from mercurial import error, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'crash', [], b'hg crash')
  > def crash(ui, *args, **kwargs):
  >     raise Exception("oops")
  > @command(b'abortcmd', [], b'hg abortcmd')
  > def abort(ui, *args, **kwargs):
  >     raise error.Abort(b"oops")
  > EOF
  $ abspath=`pwd`/myextension.py

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > blackbox=
  > mock=$TESTDIR/mockblackbox.py
  > mq=
  > myextension=$TESTTMP/myextension.py
  > [alias]
  > confuse = log --limit 3
  > so-confusing = confuse --style compact
  > EOF

  $ hg init blackboxtest
  $ cd blackboxtest

command, exit codes, and duration

  $ echo a > a
  $ hg add a
  $ hg blackbox --config blackbox.dirty=True
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> init blackboxtest exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> add a
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> add a exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000+ (5000)> blackbox --config *blackbox.dirty=True* (glob)

failure exit code
  $ rm ./.hg/blackbox.log
  $ hg add non-existent
  non-existent: $ENOENT$
  [1]
  $ hg blackbox
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> add non-existent
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> add non-existent exited 1 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox

abort exit code
  $ rm ./.hg/blackbox.log
  $ hg abortcmd 2> /dev/null
  [255]
  $ hg blackbox -l 2
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> abortcmd exited 255 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox -l 2

unhandled exception
  $ rm ./.hg/blackbox.log
#if chg
 (chg exits 255 because it fails to receive an exit code)
  $ hg crash 2>/dev/null
  [255]
#else
 (hg exits 1 because Python default exit code for uncaught exception is 1)
  $ hg crash 2>/dev/null
  [1]
#endif
  $ hg blackbox -l 2
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> crash exited 1 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox -l 2

alias expansion is logged
  $ rm ./.hg/blackbox.log
  $ hg confuse
  $ hg blackbox
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> confuse
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> alias 'confuse' expands to 'log --limit 3'
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> confuse exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox

recursive aliases work correctly
  $ rm ./.hg/blackbox.log
  $ hg so-confusing
  $ hg blackbox
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> so-confusing
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> alias 'so-confusing' expands to 'confuse --style compact'
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> alias 'confuse' expands to 'log --limit 3'
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> so-confusing exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox

custom date format
  $ rm ./.hg/blackbox.log
  $ hg --config blackbox.date-format='%Y-%m-%d @ %H:%M:%S' \
  >    --config devel.default-date='1334347993 0' --traceback status
  A a
  $ hg blackbox
  2012-04-13 @ 20:13:13 bob @0000000000000000000000000000000000000000 (5000)> --config *blackbox.date-format=%Y-%m-%d @ %H:%M:%S* --config *devel.default-date=1334347993 0* --traceback status (glob)
  2012-04-13 @ 20:13:13 bob @0000000000000000000000000000000000000000 (5000)> --config *blackbox.date-format=%Y-%m-%d @ %H:%M:%S* --config *devel.default-date=1334347993 0* --traceback status exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox

incoming change tracking

create two heads to verify that we only see one change in the log later
  $ hg commit -ma
  $ hg up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo b > b
  $ hg commit -Amb
  adding b
  created new head

clone, commit, pull
  $ hg clone . ../blackboxtest2
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo c > c
  $ hg commit -Amc
  adding c
  $ cd ../blackboxtest2
  $ hg pull
  pulling from $TESTTMP/blackboxtest
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets d02f48003e62
  (run 'hg update' to get a working copy)
  $ hg blackbox -l 6
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> wrote branch cache (served) with 1 labels and 2 nodes
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> updated branch cache (served.hidden) in * seconds (glob)
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> wrote branch cache (served.hidden) with 1 labels and 2 nodes
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> 1 incoming changes - new heads: d02f48003e62
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> pull exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> blackbox -l 6

we must not cause a failure if we cannot write to the log

  $ hg rollback
  repository tip rolled back to revision 1 (undo pull)

  $ mv .hg/blackbox.log .hg/blackbox.log-
  $ mkdir .hg/blackbox.log
  $ hg --debug incoming
  warning: cannot write to blackbox.log: * (glob)
  comparing with $TESTTMP/blackboxtest
  query 1; heads
  searching for changes
  all local changesets known remotely
  changeset:   2:d02f48003e62c24e2659d97d30f2a83abe5d5d51
  tag:         tip
  phase:       draft
  parent:      1:6563da9dcf87b1949716e38ff3e3dfaa3198eb06
  parent:      -1:0000000000000000000000000000000000000000
  manifest:    2:ab9d46b053ebf45b7996f2922b9893ff4b63d892
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  files+:      c
  extra:       branch=default
  description:
  c
  
  
  $ hg pull
  pulling from $TESTTMP/blackboxtest
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets d02f48003e62
  (run 'hg update' to get a working copy)

a failure reading from the log is fatal

  $ hg blackbox -l 3
  abort: *$TESTTMP/blackboxtest2/.hg/blackbox.log* (glob)
  [255]

  $ rmdir .hg/blackbox.log
  $ mv .hg/blackbox.log- .hg/blackbox.log

backup bundles get logged

  $ touch d
  $ hg commit -Amd
  adding d
  created new head
  $ hg strip tip
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/blackboxtest2/.hg/strip-backup/*-backup.hg (glob)
  $ hg blackbox -l 6
  1970-01-01 00:00:00.000 bob @73f6ee326b27d820b0472f1a825e3a50f3dc489b (5000)> strip tip
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> saved backup bundle to $TESTTMP/blackboxtest2/.hg/strip-backup/73f6ee326b27-7612e004-backup.hg
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> updated branch cache (immutable) in * seconds (glob)
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> wrote branch cache (immutable) with 1 labels and 2 nodes
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> strip tip exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> blackbox -l 6

extension and python hooks - use the eol extension for a pythonhook

  $ echo '[extensions]' >> .hg/hgrc
  $ echo 'eol=' >> .hg/hgrc
  $ echo '[hooks]' >> .hg/hgrc
  $ echo 'update = echo hooked' >> .hg/hgrc
  $ hg update
  The fsmonitor extension is incompatible with the eol extension and has been disabled. (fsmonitor !)
  hooked
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to "d02f48003e62: c"
  1 other heads for branch "default"
  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > # disable eol, because it is not needed for subsequent tests
  > # (in addition, keeping it requires extra care for fsmonitor)
  > eol=!
  > EOF
  $ hg blackbox -l 5
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> update (no-chg !)
  1970-01-01 00:00:00.000 bob @6563da9dcf87b1949716e38ff3e3dfaa3198eb06 (5000)> pythonhook-preupdate: hgext.eol.preupdate finished in * seconds (glob)
  1970-01-01 00:00:00.000 bob @d02f48003e62c24e2659d97d30f2a83abe5d5d51 (5000)> exthook-update: echo hooked finished in * seconds (glob)
  1970-01-01 00:00:00.000 bob @d02f48003e62c24e2659d97d30f2a83abe5d5d51 (5000)> update exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @d02f48003e62c24e2659d97d30f2a83abe5d5d51 (5000)> serve --no-profile --cmdserver chgunix --address $TESTTMP.chgsock/server.* --daemon-postexec 'chdir:/' (glob) (chg !)
  1970-01-01 00:00:00.000 bob @d02f48003e62c24e2659d97d30f2a83abe5d5d51 (5000)> blackbox -l 5

log rotation

  $ echo '[blackbox]' >> .hg/hgrc
  $ echo 'maxsize = 20 b' >> .hg/hgrc
  $ echo 'maxfiles = 3' >> .hg/hgrc
  $ hg status
  $ hg status
  $ hg status
  $ hg tip -q
  2:d02f48003e62
  $ ls .hg/blackbox.log*
  .hg/blackbox.log
  .hg/blackbox.log.1
  .hg/blackbox.log.2
  $ cd ..

  $ hg init blackboxtest3
  $ cd blackboxtest3
  $ hg blackbox
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> init blackboxtest3 exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> blackbox
  $ mv .hg/blackbox.log .hg/blackbox.log-
  $ mkdir .hg/blackbox.log
  $ sed -e 's/\(.*test1.*\)/#\1/; s#\(.*commit2.*\)#os.rmdir(".hg/blackbox.log")\
  > os.rename(".hg/blackbox.log-", ".hg/blackbox.log")\
  > \1#' $TESTDIR/test-dispatch.py > ../test-dispatch.py
  $ "$PYTHON" $TESTDIR/blackbox-readonly-dispatch.py
  running: --debug add foo
  warning: cannot write to blackbox.log: Is a directory (no-windows !)
  warning: cannot write to blackbox.log: $TESTTMP/blackboxtest3/.hg/blackbox.log: Access is denied (windows !)
  adding foo
  result: 0
  running: --debug commit -m commit1 -d 2000-01-01 foo
  warning: cannot write to blackbox.log: Is a directory (no-windows !)
  warning: cannot write to blackbox.log: $TESTTMP/blackboxtest3/.hg/blackbox.log: Access is denied (windows !)
  committing files:
  foo
  committing manifest
  committing changelog
  updating the branch cache
  committed changeset 0:0e46349438790c460c5c9f7546bfcd39b267bbd2
  result: 0
  running: --debug commit -m commit2 -d 2000-01-02 foo
  committing files:
  foo
  committing manifest
  committing changelog
  updating the branch cache
  committed changeset 1:45589e459b2edfbf3dbde7e01f611d2c1e7453d7
  result: 0
  running: --debug log -r 0
  changeset:   0:0e46349438790c460c5c9f7546bfcd39b267bbd2
  phase:       draft
  parent:      -1:0000000000000000000000000000000000000000
  parent:      -1:0000000000000000000000000000000000000000
  manifest:    0:9091aa5df980aea60860a2e39c95182e68d1ddec
  user:        test
  date:        Sat Jan 01 00:00:00 2000 +0000
  files+:      foo
  extra:       branch=default
  description:
  commit1
  
  
  result: 0
  running: --debug log -r tip
  changeset:   1:45589e459b2edfbf3dbde7e01f611d2c1e7453d7
  tag:         tip
  phase:       draft
  parent:      0:0e46349438790c460c5c9f7546bfcd39b267bbd2
  parent:      -1:0000000000000000000000000000000000000000
  manifest:    1:895aa9b7886f89dd017a6d62524e1f9180b04df9
  user:        test
  date:        Sun Jan 02 00:00:00 2000 +0000
  files:       foo
  extra:       branch=default
  description:
  commit2
  
  
  result: 0
  $ hg blackbox
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> updating the branch cache
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> updated branch cache (served) in * seconds (glob)
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> wrote branch cache (served) with 1 labels and 1 nodes
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> --debug commit -m commit2 -d 2000-01-02 foo exited 0 after *.?? seconds (glob)
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> --debug log -r 0
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> writing .hg/cache/tags2-visible with 0 tags
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> --debug log -r 0 exited 0 after *.?? seconds (glob)
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> --debug log -r tip
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> --debug log -r tip exited 0 after *.?? seconds (glob)
  1970-01-01 00:00:00.000 bob @45589e459b2edfbf3dbde7e01f611d2c1e7453d7 (5000)> blackbox

Skip rotation if the .hg is read-only

#if unix-permissions
  $ chmod -w .hg
  $ hg log -r. -T '{rev}\n' --config blackbox.maxsize=1 --debug
  warning: cannot rename '$TESTTMP/blackboxtest3/.hg/blackbox.log.1' to '$TESTTMP/blackboxtest3/.hg/blackbox.log': Permission denied
  warning: cannot write to blackbox.log: Permission denied
  1
  $ chmod +w .hg
#endif

Test log recursion from dirty status check

  $ cat > ../r.py <<EOF
  > from mercurial import context, error, extensions
  > x=[False]
  > def status(orig, *args, **opts):
  >     args[0].repo().ui.log(b"broken", b"recursion?")
  >     return orig(*args, **opts)
  > def reposetup(ui, repo):
  >     extensions.wrapfunction(context.basectx, 'status', status)
  > EOF
  $ hg id --config extensions.x=../r.py --config blackbox.dirty=True
  45589e459b2e tip

cleanup
  $ cd ..

Test missing log directory, which shouldn't be created automatically

  $ cat <<'EOF' > closeremove.py
  > def reposetup(ui, repo):
  >     class rmrepo(repo.__class__):
  >         def close(self):
  >             super(rmrepo, self).close()
  >             self.ui.debug(b'removing %s\n' % self.vfs.base)
  >             self.vfs.rmtree()
  >     repo.__class__ = rmrepo
  > EOF

  $ hg init gone
  $ cd gone
  $ cat <<'EOF' > .hg/hgrc
  > [extensions]
  > closeremove = ../closeremove.py
  > EOF
  $ hg log --debug
  removing $TESTTMP/gone/.hg
  warning: cannot write to blackbox.log: $ENOENT$ (no-windows !)
  warning: cannot write to blackbox.log: $TESTTMP/gone/.hg/blackbox.log: $ENOTDIR$ (windows !)
  $ cd ..

blackbox should disable itself if track is empty

  $ hg --config blackbox.track= init nothing_tracked
  $ cd nothing_tracked
  $ cat >> .hg/hgrc << EOF
  > [blackbox]
  > track =
  > EOF
  $ hg blackbox
  $ cd $TESTTMP

a '*' entry in blackbox.track is interpreted as log everything

  $ hg --config blackbox.track='*' \
  >    --config blackbox.logsource=True \
  >    init track_star
  $ cd track_star
  $ cat >> .hg/hgrc << EOF
  > [blackbox]
  > logsource = True
  > track = *
  > EOF
(only look for entries with specific logged sources, otherwise this test is
pretty brittle)
  $ hg blackbox | egrep '\[command(finish)?\]'
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000) [commandfinish]> --config *blackbox.track=* --config *blackbox.logsource=True* init track_star exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000) [command]> blackbox
  $ cd $TESTTMP

#if chg

when using chg, blackbox.log should get rotated correctly

  $ cat > $TESTTMP/noop.py << EOF
  > from __future__ import absolute_import
  > import time
  > from mercurial import registrar, scmutil
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'noop')
  > def noop(ui, repo):
  >     pass
  > EOF

  $ hg init blackbox-chg
  $ cd blackbox-chg

  $ cat > .hg/hgrc << EOF
  > [blackbox]
  > maxsize = 500B
  > [extensions]
  > # extension change forces chg to restart
  > noop=$TESTTMP/noop.py
  > EOF

  $ "$PYTHON" -c 'print("a" * 400)' > .hg/blackbox.log
  $ chg noop
  $ chg noop
  $ chg noop
  $ chg noop
  $ chg noop

  $ cat > showsize.py << 'EOF'
  > import os
  > import sys
  > limit = 500
  > for p in sys.argv[1:]:
  >     size = os.stat(p).st_size
  >     if size >= limit:
  >         desc = '>='
  >     else:
  >         desc = '<'
  >     print('%s: %s %d' % (p, desc, limit))
  > EOF

  $ "$PYTHON" showsize.py .hg/blackbox*
  .hg/blackbox.log: < 500
  .hg/blackbox.log.1: >= 500
  .hg/blackbox.log.2: >= 500

  $ cd ..

With chg, blackbox should not create the log file if the repo is gone

  $ hg init repo1
  $ hg --config extensions.a=! -R repo1 log
  $ rm -rf $TESTTMP/repo1
  $ hg --config extensions.a=! init repo1

#endif

blackbox should work if repo.ui.log is not called (issue5518)

  $ cat > $TESTTMP/raise.py << EOF
  > from __future__ import absolute_import
  > from mercurial import registrar, scmutil
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'raise')
  > def raisecmd(*args):
  >     raise RuntimeError('raise')
  > EOF

  $ cat >> $HGRCPATH << EOF
  > [blackbox]
  > track = commandexception
  > [extensions]
  > raise=$TESTTMP/raise.py
  > EOF

  $ hg init $TESTTMP/blackbox-exception-only
  $ cd $TESTTMP/blackbox-exception-only

#if chg
 (chg exits 255 because it fails to receive an exit code)
  $ hg raise 2>/dev/null
  [255]
#else
 (hg exits 1 because Python default exit code for uncaught exception is 1)
  $ hg raise 2>/dev/null
  [1]
#endif

  $ head -1 .hg/blackbox.log
  1970-01-01 00:00:00.000 bob @0000000000000000000000000000000000000000 (5000)> ** Unknown exception encountered with possibly-broken third-party extension "mock" (version N/A)
  $ tail -2 .hg/blackbox.log
  RuntimeError: raise
  
