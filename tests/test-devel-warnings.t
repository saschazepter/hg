
  $ cat << EOF > buggylocking.py
  > """A small extension that tests our developer warnings
  > """
  > 
  > from mercurial import error, registrar, repair, util
  > 
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > 
  > @command(b'buggylocking', [], '')
  > def buggylocking(ui, repo):
  >     lo = repo.lock()
  >     wl = repo.wlock()
  >     wl.release()
  >     lo.release()
  > 
  > @command(b'buggytransaction', [], '')
  > def buggylocking(ui, repo):
  >     tr = repo.transaction(b'buggy')
  >     # make sure we rollback the transaction as we don't want to rely on the__del__
  >     tr.release()
  > 
  > @command(b'properlocking', [], '')
  > def properlocking(ui, repo):
  >     """check that reentrance is fine"""
  >     wl = repo.wlock()
  >     lo = repo.lock()
  >     tr = repo.transaction(b'proper')
  >     tr2 = repo.transaction(b'proper')
  >     lo2 = repo.lock()
  >     wl2 = repo.wlock()
  >     wl2.release()
  >     lo2.release()
  >     tr2.close()
  >     tr.close()
  >     lo.release()
  >     wl.release()
  > 
  > @command(b'nowaitlocking', [], '')
  > def nowaitlocking(ui, repo):
  >     lo = repo.lock()
  >     wl = repo.wlock(wait=False)
  >     wl.release()
  >     lo.release()
  > 
  > @command(b'no-wlock-write', [], '')
  > def nowlockwrite(ui, repo):
  >     with repo.vfs(b'branch', b'a'):
  >         pass
  > 
  > @command(b'no-lock-write', [], '')
  > def nolockwrite(ui, repo):
  >     with repo.svfs(b'fncache', b'a'):
  >         pass
  > 
  > @command(b'stripintr', [], '')
  > def stripintr(ui, repo):
  >     lo = repo.lock()
  >     tr = repo.transaction(b'foobar')
  >     try:
  >         repair.strip(repo.ui, repo, [repo[b'.'].node()])
  >     finally:
  >         lo.release()
  > @command(b'oldanddeprecated', [], '')
  > def oldanddeprecated(ui, repo):
  >     """test deprecation warning API"""
  >     def foobar(ui):
  >         ui.deprecwarn(b'foorbar is deprecated, go shopping', b'42.1337')
  >     foobar(ui)
  > @command(b'nouiwarning', [], '')
  > def nouiwarning(ui, repo):
  >     util.nouideprecwarn(b'this is a test', b'13.37')
  > @command(b'programmingerror', [], '')
  > def programmingerror(ui, repo):
  >     raise error.ProgrammingError(b'something went wrong', hint=b'try again')
  > EOF

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > buggylocking=$TESTTMP/buggylocking.py
  > mock=$TESTDIR/mockblackbox.py
  > blackbox=
  > [devel]
  > all-warnings=1
  > [blackbox]
  > track = command, commandexception, commandfinish, develwarn
  > EOF

  $ hg init lock-checker
  $ cd lock-checker
  $ hg buggylocking
  devel-warn: "wlock" acquired after "lock" at: $TESTTMP/buggylocking.py:* (buggylocking) (glob)
  $ cat << EOF >> $HGRCPATH
  > [devel]
  > all=0
  > check-locks=1
  > EOF
  $ hg buggylocking
  devel-warn: "wlock" acquired after "lock" at: $TESTTMP/buggylocking.py:* (buggylocking) (glob)
#if no-chg no-pyoxidizer
  $ hg buggylocking --traceback
  devel-warn: "wlock" acquired after "lock" at:
   */hg:* in <module> (glob) (?)
   */mercurial/dispatch.py:* in run (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   $TESTTMP/buggylocking.py:* in buggylocking (glob)
#endif
#if chg no-pyoxidizer
  $ hg buggylocking --traceback
  devel-warn: "wlock" acquired after "lock" at:
   */hg:* in <module> (glob) (?)
   */mercurial/dispatch.py:* in run (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py:* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   */mercurial/commands.py:* in serve (glob)
   */mercurial/server.py:* in runservice (glob)
   */mercurial/commandserver.py:* in run (glob)
   */mercurial/commandserver.py:* in _mainloop (glob)
   */mercurial/commandserver.py:* in _acceptnewconnection (glob)
   */mercurial/commandserver.py:* in _runworker (glob)
   */mercurial/commandserver.py:* in _serverequest (glob)
   */mercurial/commandserver.py:* in serve (glob)
   */mercurial/commandserver.py:* in serveone (glob)
   */mercurial/chgserver.py:* in runcommand (glob)
   */mercurial/commandserver.py:* in runcommand (glob)
   */mercurial/commandserver.py:* in _dispatchcommand (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py:* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   $TESTTMP/buggylocking.py:* in buggylocking (glob)
#endif
#if pyoxidizer
  $ hg buggylocking --traceback
  devel-warn: "wlock" acquired after "lock" at:
   <string>:* (glob)
   mercurial.dispatch:* in run (glob)
   mercurial.dispatch:* in dispatch (glob)
   mercurial.dispatch:* in _rundispatch (glob)
   mercurial.dispatch:* in _runcatch (glob)
   mercurial.dispatch:* in _callcatch (glob)
   mercurial.scmutil:* in callcatch (glob)
   mercurial.dispatch:* in _runcatchfunc (glob)
   mercurial.dispatch:* in _dispatch (glob)
   mercurial.dispatch:* in runcommand (glob)
   mercurial.dispatch:* in _runcommand (glob)
   mercurial.dispatch:* in <lambda> (glob)
   mercurial.util:* in check (glob)
   $TESTTMP/buggylocking.py:* in buggylocking (glob)
#endif
  $ hg properlocking
  $ hg nowaitlocking

Writing without lock

  $ hg no-wlock-write
  devel-warn: write with no wlock: "branch" at: $TESTTMP/buggylocking.py:* (nowlockwrite) (glob)

  $ hg no-lock-write
  devel-warn: write with no lock: "fncache" at: $TESTTMP/buggylocking.py:* (nolockwrite) (glob)

Stripping from a transaction

  $ echo a > a
  $ hg add a
  $ hg commit -m a
  $ hg stripintr 2>&1 | egrep -v '^(\*\*|  )'
  Traceback (most recent call last):
  *ProgrammingError: cannot strip from inside a transaction (glob)

  $ hg oldanddeprecated
  devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at: $TESTTMP/buggylocking.py:* (oldanddeprecated) (glob)

#if no-chg no-pyoxidizer
  $ hg oldanddeprecated --traceback
  devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at:
   */hg:* in <module> (glob) (?)
   */mercurial/dispatch.py:* in run (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   $TESTTMP/buggylocking.py:* in oldanddeprecated (glob)
#endif
#if chg no-pyoxidizer
  $ hg oldanddeprecated --traceback
  devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at:
   */hg:* in <module> (glob)
   */mercurial/dispatch.py:* in run (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py:* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   */mercurial/commands.py:* in serve (glob)
   */mercurial/server.py:* in runservice (glob)
   */mercurial/commandserver.py:* in run (glob)
   */mercurial/commandserver.py:* in _mainloop (glob)
   */mercurial/commandserver.py:* in _acceptnewconnection (glob)
   */mercurial/commandserver.py:* in _runworker (glob)
   */mercurial/commandserver.py:* in _serverequest (glob)
   */mercurial/commandserver.py:* in serve (glob)
   */mercurial/commandserver.py:* in serveone (glob)
   */mercurial/chgserver.py:* in runcommand (glob)
   */mercurial/commandserver.py:* in runcommand (glob)
   */mercurial/commandserver.py:* in _dispatchcommand (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py:* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   $TESTTMP/buggylocking.py:* in oldanddeprecated (glob)
#endif
#if pyoxidizer
  $ hg oldanddeprecated --traceback
  devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at:
   <string>:* (glob)
   mercurial.dispatch:* in run (glob)
   mercurial.dispatch:* in dispatch (glob)
   mercurial.dispatch:* in _rundispatch (glob)
   mercurial.dispatch:* in _runcatch (glob)
   mercurial.dispatch:* in _callcatch (glob)
   mercurial.scmutil:* in callcatch (glob)
   mercurial.dispatch:* in _runcatchfunc (glob)
   mercurial.dispatch:* in _dispatch (glob)
   mercurial.dispatch:* in runcommand (glob)
   mercurial.dispatch:* in _runcommand (glob)
   mercurial.dispatch:* in <lambda> (glob)
   mercurial.util:* in check (glob)
   $TESTTMP/buggylocking.py:* in oldanddeprecated (glob)
#endif

#if no-chg no-pyoxidizer
  $ hg blackbox -l 7
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at: $TESTTMP/buggylocking.py:* (oldanddeprecated) (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated --traceback
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at:
   */hg:* in <module> (glob) (?)
   */mercurial/dispatch.py:* in run (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   $TESTTMP/buggylocking.py:* in oldanddeprecated (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated --traceback exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> blackbox -l 7
#endif
#if chg no-pyoxidizer
  $ hg blackbox -l 7
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at: $TESTTMP/buggylocking.py:* (oldanddeprecated) (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated --traceback
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at:
   */hg:* in <module> (glob)
   */mercurial/dispatch.py:* in run (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py:* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   */mercurial/commands.py:* in serve (glob)
   */mercurial/server.py:* in runservice (glob)
   */mercurial/commandserver.py:* in run (glob)
   */mercurial/commandserver.py:* in _mainloop (glob)
   */mercurial/commandserver.py:* in _acceptnewconnection (glob)
   */mercurial/commandserver.py:* in _runworker (glob)
   */mercurial/commandserver.py:* in _serverequest (glob)
   */mercurial/commandserver.py:* in serve (glob)
   */mercurial/commandserver.py:* in serveone (glob)
   */mercurial/chgserver.py:* in runcommand (glob)
   */mercurial/commandserver.py:* in runcommand (glob)
   */mercurial/commandserver.py:* in _dispatchcommand (glob)
   */mercurial/dispatch.py:* in dispatch (glob)
   */mercurial/dispatch.py:* in _rundispatch (glob)
   */mercurial/dispatch.py:* in _runcatch (glob)
   */mercurial/dispatch.py:* in _callcatch (glob)
   */mercurial/scmutil.py:* in callcatch (glob)
   */mercurial/dispatch.py:* in _runcatchfunc (glob)
   */mercurial/dispatch.py:* in _dispatch (glob)
   */mercurial/dispatch.py:* in runcommand (glob)
   */mercurial/dispatch.py:* in _runcommand (glob)
   */mercurial/dispatch.py:* in <lambda> (glob)
   */mercurial/util.py:* in check (glob)
   $TESTTMP/buggylocking.py:* in oldanddeprecated (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated --traceback exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> blackbox -l 7
#endif
#if pyoxidizer
  $ hg blackbox -l 7
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at: $TESTTMP/buggylocking.py:* (oldanddeprecated) (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated --traceback
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> devel-warn: foorbar is deprecated, go shopping
  (compatibility will be dropped after Mercurial-42.1337, update your code.) at:
   <string>:* in <module> (glob)
   mercurial.dispatch:* in run (glob)
   mercurial.dispatch:* in dispatch (glob)
   mercurial.dispatch:* in _rundispatch (glob)
   mercurial.dispatch:* in _runcatch (glob)
   mercurial.dispatch:* in _callcatch (glob)
   mercurial.scmutil* in callcatch (glob)
   mercurial.dispatch:* in _runcatchfunc (glob)
   mercurial.dispatch:* in _dispatch (glob)
   mercurial.dispatch:* in runcommand (glob)
   mercurial.dispatch:* in _runcommand (glob)
   mercurial.dispatch:* in <lambda> (glob)
   mercurial.util:* in check (glob)
   $TESTTMP/buggylocking.py:* in oldanddeprecated (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> oldanddeprecated --traceback exited 0 after * seconds (glob)
  1970-01-01 00:00:00.000 bob @cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b (5000)> blackbox -l 7
#endif

Test programming error failure:

  $ hg buggytransaction 2>&1 | egrep -v '^  '
  ** Unknown exception encountered with possibly-broken third-party extension "buggylocking" (version N/A)
  ** which supports versions unknown of Mercurial.
  ** Please disable "buggylocking" and try your action again.
  ** If that fixes the bug please report it to the extension author.
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: * (glob)
  ** ProgrammingError: transaction requires locking
  Traceback (most recent call last):
  *ProgrammingError: transaction requires locking (glob)

  $ hg programmingerror 2>&1 | egrep -v '^  '
  ** Unknown exception encountered with possibly-broken third-party extension "buggylocking" (version N/A)
  ** which supports versions unknown of Mercurial.
  ** Please disable "buggylocking" and try your action again.
  ** If that fixes the bug please report it to the extension author.
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: * (glob)
  ** ProgrammingError: something went wrong
  ** (try again)
  Traceback (most recent call last):
  *ProgrammingError: something went wrong (glob)

Old style deprecation warning

  $ hg nouiwarning
  $TESTTMP/buggylocking.py:*: DeprecationWarning: this is a test (glob)
  (compatibility will be dropped after Mercurial-13.37, update your code.)
    util.nouideprecwarn(b'this is a test', b'13.37')

(disabled outside of test run)

  $ HGEMITWARNINGS= hg nouiwarning

Test warning on config option access and registration

  $ cat << EOF > ${TESTTMP}/buggyconfig.py
  > """A small extension that tests our developer warnings for config"""
  > 
  > from mercurial import configitems, registrar
  > 
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > 
  > configtable = {}
  > configitem = registrar.configitem(configtable)
  > 
  > configitem(b'test', b'some', default=b'foo')
  > configitem(b'test', b'dynamic', default=configitems.dynamicdefault)
  > configitem(b'test', b'callable', default=list)
  > # overwrite a core config
  > configitem(b'ui', b'quiet', default=False)
  > configitem(b'ui', b'interactive', default=None)
  > 
  > @command(b'buggyconfig')
  > def cmdbuggyconfig(ui, repo):
  >     repo.ui.config(b'ui', b'quiet', True)
  >     repo.ui.config(b'ui', b'interactive', False)
  >     repo.ui.config(b'test', b'some', b'bar')
  >     repo.ui.config(b'test', b'some', b'foo')
  >     repo.ui.config(b'test', b'dynamic', b'some-required-default')
  >     repo.ui.config(b'test', b'dynamic')
  >     repo.ui.config(b'test', b'callable', [])
  >     repo.ui.config(b'test', b'callable', b'foo')
  >     repo.ui.config(b'test', b'unregistered')
  >     repo.ui.config(b'unregistered', b'unregistered')
  > EOF

  $ hg --config "extensions.buggyconfig=${TESTTMP}/buggyconfig.py" buggyconfig
  devel-warn: extension 'buggyconfig' overwrite config item 'ui.interactive' at: */mercurial/extensions.py:* (_loadextra) (glob) (no-pyoxidizer !)
  devel-warn: extension 'buggyconfig' overwrite config item 'ui.quiet' at: */mercurial/extensions.py:* (_loadextra) (glob) (no-pyoxidizer !)
  devel-warn: extension 'buggyconfig' overwrite config item 'ui.interactive' at: mercurial.extensions:* (_loadextra) (glob) (pyoxidizer !)
  devel-warn: extension 'buggyconfig' overwrite config item 'ui.quiet' at: mercurial.extensions:* (_loadextra) (glob) (pyoxidizer !)
  devel-warn: specifying a mismatched default value for a registered config item: 'ui.quiet' 'True' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)
  devel-warn: specifying a mismatched default value for a registered config item: 'ui.interactive' 'False' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)
  devel-warn: specifying a mismatched default value for a registered config item: 'test.some' 'bar' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)
  devel-warn: config item requires an explicit default value: 'test.dynamic' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)
  devel-warn: specifying a mismatched default value for a registered config item: 'test.callable' 'foo' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)
  devel-warn: accessing unregistered config item: 'test.unregistered' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)
  devel-warn: accessing unregistered config item: 'unregistered.unregistered' at: $TESTTMP/buggyconfig.py:* (cmdbuggyconfig) (glob)

  $ cd ..
