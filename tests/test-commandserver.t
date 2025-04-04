#require no-rhg no-chg

XXX-RHG this test hangs if `hg` is really `rhg`. This was hidden by the use of
`alias hg=rhg` by run-tests.py. With such alias removed, this test is revealed
buggy. This need to be resolved sooner than later.

XXX-CHG this test hangs if `hg` is really `chg`. This was hidden by the use of
`alias hg=chg` by run-tests.py. With such alias removed, this test is revealed
buggy. This need to be resolved sooner than later.

#if windows
  $ PYTHONPATH="$TESTDIR/../contrib;$PYTHONPATH"
#else
  $ PYTHONPATH="$TESTDIR/../contrib:$PYTHONPATH"
#endif
  $ export PYTHONPATH

typical client does not want echo-back messages, so test without it:

  $ grep -v '^promptecho ' < $HGRCPATH >> $HGRCPATH.new
  $ mv $HGRCPATH.new $HGRCPATH

  $ hg init repo
  $ cd repo

  >>> import os
  >>> import sys
  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def hellomessage(server):
  ...     ch, data = readchannel(server)
  ...     bprint(b'%c, %r' % (ch, data))
  ...     # run an arbitrary command to make sure the next thing the server
  ...     # sends isn't part of the hello message
  ...     runcommand(server, [b'id'])
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand id
  000000000000 tip

  >>> from hgclient import check
  >>> @check
  ... def unknowncommand(server):
  ...     server.stdin.write(b'unknowncommand\n')
  abort: unknown command unknowncommand

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def checkruncommand(server):
  ...     # hello block
  ...     readchannel(server)
  ... 
  ...     # no args
  ...     runcommand(server, [])
  ... 
  ...     # global options
  ...     runcommand(server, [b'id', b'--quiet'])
  ... 
  ...     # make sure global options don't stick through requests
  ...     runcommand(server, [b'id'])
  ... 
  ...     # --config
  ...     runcommand(server, [b'id', b'--config', b'ui.quiet=True'])
  ... 
  ...     # make sure --config doesn't stick
  ...     runcommand(server, [b'id'])
  ... 
  ...     # negative return code should be masked
  ...     runcommand(server, [b'id', b'-runknown'])
  *** runcommand 
  Mercurial Distributed SCM
  
  basic commands:
  
   add           add the specified files on the next commit
   annotate      show changeset information by line for each file
   clone         make a copy of an existing repository
   commit        commit the specified files or all outstanding changes
   diff          diff repository (or selected files)
   export        dump the header and diffs for one or more changesets
   forget        forget the specified files on the next commit
   init          create a new repository in the given directory
   log           show revision history of entire repository or files
   merge         merge another revision into working directory
   pull          pull changes from the specified source
   push          push changes to the specified destination
   remove        remove the specified files on the next commit
   serve         start stand-alone webserver
   status        show changed files in the working directory
   summary       summarize working directory state
   update        update working directory (or switch revisions)
  
  (use 'hg help' for the full list of commands or 'hg -v' for details)
  *** runcommand id --quiet
  000000000000
  *** runcommand id
  000000000000 tip
  *** runcommand id --config ui.quiet=True
  000000000000
  *** runcommand id
  000000000000 tip
  *** runcommand id -runknown
  abort: unknown revision 'unknown'
   [10]

  >>> from hgclient import bprint, check, readchannel
  >>> @check
  ... def inputeof(server):
  ...     readchannel(server)
  ...     server.stdin.write(b'runcommand\n')
  ...     # close stdin while server is waiting for input
  ...     server.stdin.close()
  ... 
  ...     # server exits with 1 if the pipe closed while reading the command
  ...     bprint(b'server exit code =', b'%d' % server.wait())
  server exit code = 1

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def serverinput(server):
  ...     readchannel(server)
  ... 
  ...     patch = b"""
  ... # HG changeset patch
  ... # User test
  ... # Date 0 0
  ... # Node ID c103a3dec114d882c98382d684d8af798d09d857
  ... # Parent  0000000000000000000000000000000000000000
  ... 1
  ... 
  ... diff -r 000000000000 -r c103a3dec114 a
  ... --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  ... +++ b/a	Thu Jan 01 00:00:00 1970 +0000
  ... @@ -0,0 +1,1 @@
  ... +1
  ... """
  ... 
  ...     runcommand(server, [b'import', b'-'], input=stringio(patch))
  ...     runcommand(server, [b'log'])
  *** runcommand import -
  applying patch from stdin
  *** runcommand log
  changeset:   0:eff892de26ec
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  

check strict parsing of early options:

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> os.environ['HGPLAIN'] = '+strictflags'
  >>> @check
  ... def cwd(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'log', b'-b', b'--config=alias.log=!echo pwned',
  ...                         b'default'])
  *** runcommand log -b --config=alias.log=!echo pwned default
  abort: unknown revision '--config=alias.log=!echo pwned'
   [10]

check that "histedit --commands=-" can read rules from the input channel:

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def serverinput(server):
  ...     readchannel(server)
  ...     rules = b'pick eff892de26ec\n'
  ...     runcommand(server, [b'histedit', b'0', b'--commands=-',
  ...                         b'--config', b'extensions.histedit='],
  ...                input=stringio(rules))
  *** runcommand histedit 0 --commands=- --config extensions.histedit=

check that --cwd doesn't persist between requests:

  $ mkdir foo
  $ touch foo/bar
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def cwd(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'--cwd', b'foo', b'st', b'bar'])
  ...     runcommand(server, [b'st', b'foo/bar'])
  *** runcommand --cwd foo st bar
  ? bar
  *** runcommand st foo/bar
  ? foo/bar

  $ rm foo/bar


check that local configs for the cached repo aren't inherited when -R is used:

  $ cat <<EOF >> .hg/hgrc
  > [ui]
  > foo = bar
  > EOF

#if no-extraextensions

  >>> from hgclient import check, readchannel, runcommand, sep
  >>> @check
  ... def localhgrc(server):
  ...     readchannel(server)
  ... 
  ...     # the cached repo local hgrc contains ui.foo=bar, so showconfig should
  ...     # show it
  ...     runcommand(server, [b'showconfig'], outfilter=sep)
  ... 
  ...     # but not for this repo
  ...     runcommand(server, [b'init', b'foo'])
  ...     runcommand(server, [b'-R', b'foo', b'showconfig', b'ui', b'defaults'])
  *** runcommand showconfig
  bundle.mainreporoot=$TESTTMP/repo
  chgserver.idletimeout=60
  devel.all-warnings=true
  devel.default-date=0 0
  extensions.fsmonitor= (fsmonitor !)
  format.use-dirstate-v2=1 (dirstate-v2 !)
  largefiles.usercache=$TESTTMP/.cache/largefiles
  lfs.usercache=$TESTTMP/.cache/lfs
  ui.slash=True
  ui.interactive=False
  ui.detailed-exit-code=True
  ui.merge=internal:merge
  ui.mergemarkers=detailed
  ui.ssh=* (glob)
  ui.timeout.warn=15
  ui.foo=bar
  ui.nontty=true
  web.address=localhost
  web\.ipv6=(?:True|False) (re)
  web.server-header=testing stub value
  *** runcommand init foo
  *** runcommand -R foo showconfig ui defaults
  ui.slash=True
  ui.interactive=False
  ui.detailed-exit-code=True
  ui.merge=internal:merge
  ui.mergemarkers=detailed
  ui.ssh=* (glob)
  ui.timeout.warn=15
  ui.nontty=true
#endif

  $ rm -R foo

#if windows
  $ PYTHONPATH="$TESTTMP/repo;$PYTHONPATH"
#else
  $ PYTHONPATH="$TESTTMP/repo:$PYTHONPATH"
#endif

  $ cat <<EOF > hook.py
  > import sys
  > from hgclient import bprint
  > def hook(**args):
  >     bprint(b'hook talking')
  >     bprint(b'now try to read something: %r' % sys.stdin.read())
  > EOF

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def hookoutput(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'--config',
  ...                         b'hooks.pre-identify=python:hook.hook',
  ...                         b'id'],
  ...                input=stringio(b'some input'))
  *** runcommand --config hooks.pre-identify=python:hook.hook id
  eff892de26ec tip
  hook talking
  now try to read something: ''

Clean hook cached version
  $ rm hook.py*
  $ rm -Rf __pycache__

  $ echo a >> a
  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def outsidechanges(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'status'])
  ...     os.system('hg ci -Am2')
  ...     runcommand(server, [b'tip'])
  ...     runcommand(server, [b'status'])
  *** runcommand status
  M a
  *** runcommand tip
  changeset:   1:d3a0a68be6de
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     2
  
  *** runcommand status

  >>> import os
  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def bookmarks(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'bookmarks'])
  ... 
  ...     # changes .hg/bookmarks
  ...     os.system('hg bookmark -i bm1')
  ...     os.system('hg bookmark -i bm2')
  ...     runcommand(server, [b'bookmarks'])
  ... 
  ...     # changes .hg/bookmarks.current
  ...     os.system('hg upd bm1 -q')
  ...     runcommand(server, [b'bookmarks'])
  ... 
  ...     runcommand(server, [b'bookmarks', b'bm3'])
  ...     f = open('a', 'ab')
  ...     f.write(b'a\n') and None
  ...     f.close()
  ...     runcommand(server, [b'commit', b'-Amm'])
  ...     runcommand(server, [b'bookmarks'])
  ...     bprint(b'')
  *** runcommand bookmarks
  no bookmarks set
  *** runcommand bookmarks
     bm1                       1:d3a0a68be6de
     bm2                       1:d3a0a68be6de
  *** runcommand bookmarks
   * bm1                       1:d3a0a68be6de
     bm2                       1:d3a0a68be6de
  *** runcommand bookmarks bm3
  *** runcommand commit -Amm
  *** runcommand bookmarks
     bm1                       1:d3a0a68be6de
     bm2                       1:d3a0a68be6de
   * bm3                       2:aef17e88f5f0
  

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def tagscache(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'id', b'-t', b'-r', b'0'])
  ...     os.system('hg tag -r 0 foo')
  ...     runcommand(server, [b'id', b'-t', b'-r', b'0'])
  *** runcommand id -t -r 0
  
  *** runcommand id -t -r 0
  foo

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def setphase(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'phase', b'-r', b'.'])
  ...     os.system('hg phase -r . -p')
  ...     runcommand(server, [b'phase', b'-r', b'.'])
  *** runcommand phase -r .
  3: draft
  *** runcommand phase -r .
  3: public

  $ echo a >> a
  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def rollback(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'phase', b'-r', b'.', b'-p'])
  ...     runcommand(server, [b'commit', b'-Am.'])
  ...     runcommand(server, [b'rollback'])
  ...     runcommand(server, [b'phase', b'-r', b'.'])
  ...     bprint(b'')
  *** runcommand phase -r . -p
  no phases changed
  *** runcommand commit -Am.
  *** runcommand rollback
  repository tip rolled back to revision 3 (undo commit)
  working directory now based on revision 3
  *** runcommand phase -r .
  3: public
  

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def branch(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'branch'])
  ...     os.system('hg branch foo')
  ...     runcommand(server, [b'branch'])
  ...     os.system('hg branch default')
  *** runcommand branch
  default
  marked working directory as branch foo
  (branches are permanent and global, did you want a bookmark?)
  *** runcommand branch
  foo
  marked working directory as branch default
  (branches are permanent and global, did you want a bookmark?)

  $ touch .hgignore
  >>> import os
  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def hgignore(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'commit', b'-Am.'])
  ...     f = open('ignored-file', 'ab')
  ...     f.write(b'') and None
  ...     f.close()
  ...     f = open('.hgignore', 'ab')
  ...     f.write(b'ignored-file')
  ...     f.close()
  ...     runcommand(server, [b'status', b'-i', b'-u'])
  ...     bprint(b'')
  *** runcommand commit -Am.
  adding .hgignore
  *** runcommand status -i -u
  I ignored-file
  

cache of non-public revisions should be invalidated on repository change
(issue4855):

  >>> import os
  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def phasesetscacheaftercommit(server):
  ...     readchannel(server)
  ...     # load _phasecache._phaserevs and _phasesets
  ...     runcommand(server, [b'log', b'-qr', b'draft()'])
  ...     # create draft commits by another process
  ...     for i in range(5, 7):
  ...         f = open('a', 'ab')
  ...         f.seek(0, os.SEEK_END)
  ...         f.write(b'a\n') and None
  ...         f.close()
  ...         os.system('hg commit -Aqm%d' % i)
  ...     # new commits should be listed as draft revisions
  ...     runcommand(server, [b'log', b'-qr', b'draft()'])
  ...     bprint(b'')
  *** runcommand log -qr draft()
  4:7966c8e3734d
  *** runcommand log -qr draft()
  4:7966c8e3734d
  5:41f6602d1c4f
  6:10501e202c35
  

  >>> import os
  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def phasesetscacheafterstrip(server):
  ...     readchannel(server)
  ...     # load _phasecache._phaserevs and _phasesets
  ...     runcommand(server, [b'log', b'-qr', b'draft()'])
  ...     # strip cached revisions by another process
  ...     os.system('hg --config extensions.strip= strip -q 5')
  ...     # shouldn't abort by "unknown revision '6'"
  ...     runcommand(server, [b'log', b'-qr', b'draft()'])
  ...     bprint(b'')
  *** runcommand log -qr draft()
  4:7966c8e3734d
  5:41f6602d1c4f
  6:10501e202c35
  *** runcommand log -qr draft()
  4:7966c8e3734d
  

cache of phase roots should be invalidated on strip (issue3827):

  >>> import os
  >>> from hgclient import check, readchannel, runcommand, sep
  >>> @check
  ... def phasecacheafterstrip(server):
  ...     readchannel(server)
  ... 
  ...     # create new head, 5:731265503d86
  ...     runcommand(server, [b'update', b'-C', b'0'])
  ...     f = open('a', 'ab')
  ...     f.write(b'a\n') and None
  ...     f.close()
  ...     runcommand(server, [b'commit', b'-Am.', b'a'])
  ...     runcommand(server, [b'log', b'-Gq'])
  ... 
  ...     # make it public; draft marker moves to 4:7966c8e3734d
  ...     runcommand(server, [b'phase', b'-p', b'.'])
  ...     # load _phasecache.phaseroots
  ...     runcommand(server, [b'phase', b'.'], outfilter=sep)
  ... 
  ...     # strip 1::4 outside server
  ...     os.system('hg -q --config extensions.mq= strip 1')
  ... 
  ...     # shouldn't raise "7966c8e3734d: no node!"
  ...     runcommand(server, [b'branches'])
  *** runcommand update -C 0
  1 files updated, 0 files merged, 2 files removed, 0 files unresolved
  (leaving bookmark bm3)
  *** runcommand commit -Am. a
  created new head
  *** runcommand log -Gq
  @  5:731265503d86
  |
  | o  4:7966c8e3734d
  | |
  | o  3:b9b85890c400
  | |
  | o  2:aef17e88f5f0
  | |
  | o  1:d3a0a68be6de
  |/
  o  0:eff892de26ec
  
  *** runcommand phase -p .
  *** runcommand phase .
  5: public
  *** runcommand branches
  default                        1:731265503d86

in-memory cache must be reloaded if transaction is aborted. otherwise
changelog and manifest would have invalid node:

  $ echo a >> a
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def txabort(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'commit', b'--config', b'hooks.pretxncommit=false',
  ...                         b'-mfoo'])
  ...     runcommand(server, [b'verify'])
  *** runcommand commit --config hooks.pretxncommit=false -mfoo
  transaction abort!
  rollback completed
  abort: pretxncommit hook exited with status 1
   [40]
  *** runcommand verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 1 files
  $ hg revert --no-backup -aq

  $ cat >> .hg/hgrc << EOF
  > [experimental]
  > evolution.createmarkers=True
  > EOF

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def obsolete(server):
  ...     readchannel(server)
  ... 
  ...     runcommand(server, [b'up', b'null'])
  ...     runcommand(server, [b'phase', b'-df', b'tip'])
  ...     cmd = 'hg debugobsolete `hg log -r tip --template {node}`'
  ...     if os.name == 'nt':
  ...         cmd = 'sh -c "%s"' % cmd # run in sh, not cmd.exe
  ...     os.system(cmd)
  ...     runcommand(server, [b'log', b'--hidden'])
  ...     runcommand(server, [b'log'])
  *** runcommand up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  *** runcommand phase -df tip
  1 new obsolescence markers
  obsoleted 1 changesets
  *** runcommand log --hidden
  changeset:   1:731265503d86
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  obsolete:    pruned
  summary:     .
  
  changeset:   0:eff892de26ec
  bookmark:    bm1
  bookmark:    bm2
  bookmark:    bm3
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  
  *** runcommand log
  changeset:   0:eff892de26ec
  bookmark:    bm1
  bookmark:    bm2
  bookmark:    bm3
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  

  $ cat <<EOF >> .hg/hgrc
  > [extensions]
  > mq =
  > EOF

  >>> import os
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def mqoutsidechanges(server):
  ...     readchannel(server)
  ... 
  ...     # load repo.mq
  ...     runcommand(server, [b'qapplied'])
  ...     os.system('hg qnew 0.diff')
  ...     # repo.mq should be invalidated
  ...     runcommand(server, [b'qapplied'])
  ... 
  ...     runcommand(server, [b'qpop', b'--all'])
  ...     os.system('hg qqueue --create foo')
  ...     # repo.mq should be recreated to point to new queue
  ...     runcommand(server, [b'qqueue', b'--active'])
  *** runcommand qapplied
  *** runcommand qapplied
  0.diff
  *** runcommand qpop --all
  popping 0.diff
  patch queue now empty
  *** runcommand qqueue --active
  foo

  $ cat <<'EOF' > ../dbgui.py
  > import os
  > import sys
  > from mercurial import commands, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b"debuggetpass", norepo=True)
  > def debuggetpass(ui):
  >     ui.write(b"%s\n" % ui.getpass())
  > @command(b"debugprompt", norepo=True)
  > def debugprompt(ui):
  >     ui.write(b"%s\n" % ui.prompt(b"prompt:"))
  > @command(b"debugpromptchoice", norepo=True)
  > def debugpromptchoice(ui):
  >     msg = b"promptchoice (y/n)? $$ &Yes $$ &No"
  >     ui.write(b"%d\n" % ui.promptchoice(msg))
  > @command(b"debugreadstdin", norepo=True)
  > def debugreadstdin(ui):
  >     ui.write(b"read: %r\n" % sys.stdin.read(1))
  > @command(b"debugwritestdout", norepo=True)
  > def debugwritestdout(ui):
  >     os.write(1, b"low-level stdout fd and\n")
  >     sys.stdout.write("stdout should be redirected to stderr\n")
  >     sys.stdout.flush()
  > EOF
  $ cat <<EOF >> .hg/hgrc
  > [extensions]
  > dbgui = ../dbgui.py
  > EOF

  >>> from hgclient import check, readchannel, runcommand, stringio
  >>> @check
  ... def getpass(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'debuggetpass', b'--config',
  ...                         b'ui.interactive=True'],
  ...                input=stringio(b'1234\n'))
  ...     runcommand(server, [b'debuggetpass', b'--config',
  ...                         b'ui.interactive=True'],
  ...                input=stringio(b'\n'))
  ...     runcommand(server, [b'debuggetpass', b'--config',
  ...                         b'ui.interactive=True'],
  ...                input=stringio(b''))
  ...     runcommand(server, [b'debugprompt', b'--config',
  ...                         b'ui.interactive=True'],
  ...                input=stringio(b'5678\n'))
  ...     runcommand(server, [b'debugprompt', b'--config',
  ...                         b'ui.interactive=True'],
  ...                input=stringio(b'\nremainder\nshould\nnot\nbe\nread\n'))
  ...     runcommand(server, [b'debugreadstdin'])
  ...     runcommand(server, [b'debugwritestdout'])
  *** runcommand debuggetpass --config ui.interactive=True
  password: 1234
  *** runcommand debuggetpass --config ui.interactive=True
  password: 
  *** runcommand debuggetpass --config ui.interactive=True
  password: abort: response expected
   [255]
  *** runcommand debugprompt --config ui.interactive=True
  prompt: 5678
  *** runcommand debugprompt --config ui.interactive=True
  prompt: y
  *** runcommand debugreadstdin
  read: ''
  *** runcommand debugwritestdout
  low-level stdout fd and
  stdout should be redirected to stderr


run commandserver in commandserver, which is silly but should work:

  >>> from hgclient import bprint, check, readchannel, runcommand, stringio
  >>> @check
  ... def nested(server):
  ...     bprint(b'%c, %r' % readchannel(server))
  ...     class nestedserver(object):
  ...         stdin = stringio(b'getencoding\n')
  ...         stdout = stringio()
  ...     runcommand(server, [b'serve', b'--cmdserver', b'pipe'],
  ...                output=nestedserver.stdout, input=nestedserver.stdin)
  ...     nestedserver.stdout.seek(0)
  ...     bprint(b'%c, %r' % readchannel(nestedserver))  # hello
  ...     bprint(b'%c, %r' % readchannel(nestedserver))  # getencoding
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand serve --cmdserver pipe
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  r, '*' (glob)


start without repository:

  $ cd ..

  >>> from hgclient import bprint, check, readchannel, runcommand
  >>> @check
  ... def hellomessage(server):
  ...     ch, data = readchannel(server)
  ...     bprint(b'%c, %r' % (ch, data))
  ...     # run an arbitrary command to make sure the next thing the server
  ...     # sends isn't part of the hello message
  ...     runcommand(server, [b'id'])
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand id
  abort: there is no Mercurial repository here (.hg not found)
   [10]

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def startwithoutrepo(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'init', b'repo2'])
  ...     runcommand(server, [b'id', b'-R', b'repo2'])
  *** runcommand init repo2
  *** runcommand id -R repo2
  000000000000 tip


don't fall back to cwd if invalid -R path is specified (issue4805):

  $ cd repo
  $ hg serve --cmdserver pipe -R ../nonexistent
  abort: repository ../nonexistent not found
  [255]
  $ cd ..


#if no-windows

option to not shutdown on SIGINT:

  $ cat <<'EOF' > dbgint.py
  > import os
  > import signal
  > import time
  > from mercurial import commands, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b"debugsleep", norepo=True)
  > def debugsleep(ui):
  >     time.sleep(1)
  > @command(b"debugsuicide", norepo=True)
  > def debugsuicide(ui):
  >     os.kill(os.getpid(), signal.SIGINT)
  >     time.sleep(1)
  > EOF

  >>> import signal
  >>> import time
  >>> from hgclient import checkwith, readchannel, runcommand
  >>> @checkwith(extraargs=[b'--config', b'cmdserver.shutdown-on-interrupt=False',
  ...                       b'--config', b'extensions.dbgint=dbgint.py'])
  ... def nointr(server):
  ...     readchannel(server)
  ...     server.send_signal(signal.SIGINT)  # server won't be terminated
  ...     time.sleep(1)
  ...     runcommand(server, [b'debugsleep'])
  ...     server.send_signal(signal.SIGINT)  # server won't be terminated
  ...     runcommand(server, [b'debugsleep'])
  ...     runcommand(server, [b'debugsuicide'])  # command can be interrupted
  ...     server.send_signal(signal.SIGTERM)  # server will be terminated
  ...     time.sleep(1)
  *** runcommand debugsleep
  *** runcommand debugsleep
  *** runcommand debugsuicide
  interrupted!
  killed!
   [255]

#endif


structured message channel:

  $ cat <<'EOF' >> repo2/.hg/hgrc
  > [ui]
  > # server --config should precede repository option
  > message-output = stdio
  > EOF

  >>> from hgclient import bprint, checkwith, readchannel, runcommand
  >>> @checkwith(extraargs=[b'--config', b'ui.message-output=channel',
  ...                       b'--config', b'cmdserver.message-encodings=foo cbor'])
  ... def verify(server):
  ...     _ch, data = readchannel(server)
  ...     bprint(data)
  ...     runcommand(server, [b'-R', b'repo2', b'verify'])
  capabilities: getencoding runcommand
  encoding: ascii
  message-encoding: cbor
  pid: * (glob)
  pgid: * (glob) (no-windows !)
  *** runcommand -R repo2 verify
  message: '\xa2DdataTchecking changesets\nDtypeFstatus'
  message: '\xa6Ditem@Cpos\xf6EtopicHcheckingEtotal\xf6DtypeHprogressDunit@'
  message: '\xa2DdataSchecking manifests\nDtypeFstatus'
  message: '\xa6Ditem@Cpos\xf6EtopicHcheckingEtotal\xf6DtypeHprogressDunit@'
  message: '\xa2DdataX0crosschecking files in changesets and manifests\nDtypeFstatus'
  message: '\xa6Ditem@Cpos\xf6EtopicMcrosscheckingEtotal\xf6DtypeHprogressDunit@'
  message: '\xa2DdataOchecking files\nDtypeFstatus'
  message: '\xa6Ditem@Cpos\xf6EtopicHcheckingEtotal\xf6DtypeHprogressDunit@'
  message: '\xa2DdataRchecking dirstate\nDtypeFstatus'
  message: '\xa2DdataX/checked 0 changesets with 0 changes to 0 files\nDtypeFstatus'

  >>> from hgclient import checkwith, readchannel, runcommand, stringio
  >>> @checkwith(extraargs=[b'--config', b'ui.message-output=channel',
  ...                       b'--config', b'cmdserver.message-encodings=cbor',
  ...                       b'--config', b'extensions.dbgui=dbgui.py'])
  ... def prompt(server):
  ...     readchannel(server)
  ...     interactive = [b'--config', b'ui.interactive=True']
  ...     runcommand(server, [b'debuggetpass'] + interactive,
  ...                input=stringio(b'1234\n'))
  ...     runcommand(server, [b'debugprompt'] + interactive,
  ...                input=stringio(b'5678\n'))
  ...     runcommand(server, [b'debugpromptchoice'] + interactive,
  ...                input=stringio(b'n\n'))
  *** runcommand debuggetpass --config ui.interactive=True
  message: '\xa3DdataJpassword: Hpassword\xf5DtypeFprompt'
  1234
  *** runcommand debugprompt --config ui.interactive=True
  message: '\xa3DdataGprompt:GdefaultAyDtypeFprompt'
   5678
  *** runcommand debugpromptchoice --config ui.interactive=True
  message: '\xa4Gchoices\x82\x82AyCYes\x82AnBNoDdataTpromptchoice (y/n)? GdefaultAyDtypeFprompt'
   1

bad message encoding:

  $ hg serve --cmdserver pipe --config ui.message-output=channel
  abort: no supported message encodings: 
  [255]
  $ hg serve --cmdserver pipe --config ui.message-output=channel \
  > --config cmdserver.message-encodings='foo bar'
  abort: no supported message encodings: foo bar
  [255]

unix domain socket:

  $ cd repo
  $ hg update -q

#if unix-socket unix-permissions

  >>> from hgclient import bprint, check, readchannel, runcommand, stringio, unixserver
  >>> server = unixserver(b'.hg/server.sock', b'.hg/server.log')
  >>> def hellomessage(conn):
  ...     ch, data = readchannel(conn)
  ...     bprint(b'%c, %r' % (ch, data))
  ...     runcommand(conn, [b'id'])
  >>> check(hellomessage, server.connect)
  o, 'capabilities: getencoding runcommand\nencoding: *\npid: *' (glob)
  *** runcommand id
  eff892de26ec tip bm1/bm2/bm3
  >>> def unknowncommand(conn):
  ...     readchannel(conn)
  ...     conn.stdin.write(b'unknowncommand\n')
  >>> check(unknowncommand, server.connect)  # error sent to server.log
  >>> def serverinput(conn):
  ...     readchannel(conn)
  ...     patch = b"""
  ... # HG changeset patch
  ... # User test
  ... # Date 0 0
  ... 2
  ... 
  ... diff -r eff892de26ec -r 1ed24be7e7a0 a
  ... --- a/a
  ... +++ b/a
  ... @@ -1,1 +1,2 @@
  ...  1
  ... +2
  ... """
  ...     runcommand(conn, [b'import', b'-'], input=stringio(patch))
  ...     runcommand(conn, [b'log', b'-rtip', b'-q'])
  >>> check(serverinput, server.connect)
  *** runcommand import -
  applying patch from stdin
  *** runcommand log -rtip -q
  2:1ed24be7e7a0
  >>> server.shutdown()

  $ cat .hg/server.log
  listening at .hg/server.sock
  abort: unknown command unknowncommand
  killed!
  $ rm .hg/server.log

 if server crashed before hello, traceback will be sent to 'e' channel as
 last ditch:

  $ cat <<'EOF' > ../earlycrasher.py
  > from mercurial import commandserver, extensions
  > def _serverequest(orig, ui, repo, conn, createcmdserver, prereposetups):
  >     def createcmdserver(*args, **kwargs):
  >         raise Exception('crash')
  >     return orig(ui, repo, conn, createcmdserver, prereposetups)
  > def extsetup(ui):
  >     extensions.wrapfunction(commandserver, '_serverequest', _serverequest)
  > EOF
  $ cat <<EOF >> .hg/hgrc
  > [extensions]
  > earlycrasher = ../earlycrasher.py
  > EOF
  >>> from hgclient import bprint, check, readchannel, unixserver
  >>> server = unixserver(b'.hg/server.sock', b'.hg/server.log')
  >>> def earlycrash(conn):
  ...     while True:
  ...         try:
  ...             ch, data = readchannel(conn)
  ...             for l in data.splitlines(True):
  ...                 if not l.startswith(b'  '):
  ...                     bprint(b'%c, %r' % (ch, l))
  ...         except EOFError:
  ...             break
  >>> check(earlycrash, server.connect)
  e, 'Traceback (most recent call last):\n'
  e, 'Exception: crash\n'
  >>> server.shutdown()

  $ cat .hg/server.log | grep -v '^  '
  listening at .hg/server.sock
  Traceback (most recent call last):
  Exception: crash
  killed!
#endif
#if no-unix-socket

  $ hg serve --cmdserver unix -a .hg/server.sock
  abort: unsupported platform
  [255]

#endif

  $ cd ..

Test that accessing to invalid changelog cache is avoided at
subsequent operations even if repo object is reused even after failure
of transaction (see 0a7610758c42 also)

"hg log" after failure of transaction is needed to detect invalid
cache in repoview: this can't detect by "hg verify" only.

Combination of "finalization" and "empty-ness of changelog" (2 x 2 =
4) are tested, because '00changelog.i' are differently changed in each
cases.

  $ cat > $TESTTMP/failafterfinalize.py <<EOF
  > # extension to abort transaction after finalization forcibly
  > from mercurial import commands, error, extensions, lock as lockmod
  > from mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > configtable = {}
  > configitem = registrar.configitem(configtable)
  > configitem(b'failafterfinalize', b'fail',
  >     default=None,
  > )
  > def fail(tr):
  >     raise error.Abort(b'fail after finalization')
  > def reposetup(ui, repo):
  >     class failrepo(repo.__class__):
  >         def commitctx(self, ctx, error=False, origctx=None):
  >             if self.ui.configbool(b'failafterfinalize', b'fail'):
  >                 # 'sorted()' by ASCII code on category names causes
  >                 # invoking 'fail' after finalization of changelog
  >                 # using "'cl-%i' % id(self)" as category name
  >                 self.currenttransaction().addfinalize(b'zzzzzzzz', fail)
  >             return super(failrepo, self).commitctx(ctx, error, origctx)
  >     repo.__class__ = failrepo
  > EOF

  $ hg init repo3
  $ cd repo3

  $ cat <<EOF >> $HGRCPATH
  > [command-templates]
  > log = {rev} {desc|firstline} ({files})\n
  > 
  > [extensions]
  > failafterfinalize = $TESTTMP/failafterfinalize.py
  > EOF

- test failure with "empty changelog"

  $ echo foo > foo
  $ hg add foo

(failure before finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'commit',
  ...                         b'--config', b'hooks.pretxncommit=false',
  ...                         b'-mfoo'])
  ...     runcommand(server, [b'log'])
  ...     runcommand(server, [b'verify', b'-q'])
  *** runcommand commit --config hooks.pretxncommit=false -mfoo
  transaction abort!
  rollback completed
  abort: pretxncommit hook exited with status 1
   [40]
  *** runcommand log
  *** runcommand verify -q

(failure after finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'commit',
  ...                         b'--config', b'failafterfinalize.fail=true',
  ...                         b'-mfoo'])
  ...     runcommand(server, [b'log'])
  ...     runcommand(server, [b'verify', b'-q'])
  *** runcommand commit --config failafterfinalize.fail=true -mfoo
  transaction abort!
  rollback completed
  abort: fail after finalization
   [255]
  *** runcommand log
  *** runcommand verify -q

- test failure with "not-empty changelog"

  $ echo bar > bar
  $ hg add bar
  $ hg commit -mbar bar

(failure before finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'commit',
  ...                         b'--config', b'hooks.pretxncommit=false',
  ...                         b'-mfoo', b'foo'])
  ...     runcommand(server, [b'log'])
  ...     runcommand(server, [b'verify', b'-q'])
  *** runcommand commit --config hooks.pretxncommit=false -mfoo foo
  transaction abort!
  rollback completed
  abort: pretxncommit hook exited with status 1
   [40]
  *** runcommand log
  0 bar (bar)
  *** runcommand verify -q

(failure after finalization)

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def abort(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'commit',
  ...                         b'--config', b'failafterfinalize.fail=true',
  ...                         b'-mfoo', b'foo'])
  ...     runcommand(server, [b'log'])
  ...     runcommand(server, [b'verify', b'-q'])
  *** runcommand commit --config failafterfinalize.fail=true -mfoo foo
  transaction abort!
  rollback completed
  abort: fail after finalization
   [255]
  *** runcommand log
  0 bar (bar)
  *** runcommand verify -q

  $ cd ..

Test symlink traversal over cached audited paths:
-------------------------------------------------

#if symlink

set up symlink hell

  $ mkdir merge-symlink-out
  $ hg init merge-symlink
  $ cd merge-symlink
  $ touch base
  $ hg commit -qAm base
  $ ln -s ../merge-symlink-out a
  $ hg commit -qAm 'symlink a -> ../merge-symlink-out'
  $ hg up -q 0
  $ mkdir a
  $ touch a/poisoned
  $ hg commit -qAm 'file a/poisoned'
  $ hg log -G -T '{rev}: {desc}\n'
  @  2: file a/poisoned
  |
  | o  1: symlink a -> ../merge-symlink-out
  |/
  o  0: base
  

try trivial merge after update: cache of audited paths should be discarded,
and the merge should fail (issue5628)

  $ hg up -q null
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def merge(server):
  ...     readchannel(server)
  ...     # audit a/poisoned as a good path
  ...     runcommand(server, [b'up', b'-qC', b'2'])
  ...     runcommand(server, [b'up', b'-qC', b'1'])
  ...     # here a is a symlink, so a/poisoned is bad
  ...     runcommand(server, [b'merge', b'2'])
  *** runcommand up -qC 2
  *** runcommand up -qC 1
  *** runcommand merge 2
  abort: path 'a/poisoned' traverses symbolic link 'a'
   [255]
  $ ls ../merge-symlink-out

cache of repo.auditor should be discarded, so matcher would never traverse
symlinks:

  $ hg up -qC 0
  $ touch ../merge-symlink-out/poisoned
  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def files(server):
  ...     readchannel(server)
  ...     runcommand(server, [b'up', b'-qC', b'2'])
  ...     # audit a/poisoned as a good path
  ...     runcommand(server, [b'files', b'a/poisoned'])
  ...     runcommand(server, [b'up', b'-qC', b'0'])
  ...     runcommand(server, [b'up', b'-qC', b'1'])
  ...     # here 'a' is a symlink, so a/poisoned should be warned
  ...     runcommand(server, [b'files', b'a/poisoned'])
  *** runcommand up -qC 2
  *** runcommand files a/poisoned
  a/poisoned
  *** runcommand up -qC 0
  *** runcommand up -qC 1
  *** runcommand files a/poisoned
  abort: path 'a/poisoned' traverses symbolic link 'a'
   [255]

  $ cd ..

#endif

Test the --config-file behavior (this will be used by SCM Manager to add auth
and proxy info instead of rewriting the repo hgrc file during pulls and
imports).

  $ cat > config-file.rc <<EOF
  > [auth]
  > temporary.schemes = https
  > temporary.prefix = server.org
  > temporary.password = password
  > temporary.username = user
  > EOF

  >>> from hgclient import check, readchannel, runcommand
  >>> @check
  ... def checkruncommand(server):
  ...     # hello block
  ...     readchannel(server)
  ... 
  ...     # no file
  ...     runcommand(server, [b'config', b'auth'])
  ...     # with file
  ...     runcommand(server,
  ...                [b'config', b'auth', b'--config-file', b'config-file.rc'])
  ...     # with file and overriding --config
  ...     runcommand(server,
  ...                [b'config', b'auth', b'--config-file', b'config-file.rc',
  ...                 b'--config', b'auth.temporary.username=cli-user'])
  ...     # previous configs aren't cached
  ...     runcommand(server, [b'config', b'auth'])
  *** runcommand config auth
   [1]
  *** runcommand config auth --config-file config-file.rc
  auth.temporary.schemes=https
  auth.temporary.prefix=server.org
  auth.temporary.password=password
  auth.temporary.username=user
  *** runcommand config auth --config-file config-file.rc --config auth.temporary.username=cli-user
  auth.temporary.schemes=https
  auth.temporary.prefix=server.org
  auth.temporary.password=password
  auth.temporary.username=cli-user
  *** runcommand config auth
   [1]
