Test basic extension support

Setting PYTHONPATH can confuse virtual env (sigh) so we have to be careful when
we update it. In addition, we have to handle the case where PYTHON is not
already defined. So we create a "correct and ready to use" variable for the
place where we need to touch it later in the tests.

We preventively export PYTHONPATH otherwise setting it in later command won't
be inherited by the Mercurial process.

#if py311
  $ PYTHONPATH_PREFIX="`$PYTHON -P -c \"import os, sys; print(os.pathsep.join(sys.path+['']))\"`"
#else
Python <= 3.10 does not have the -P option
  $ PYTHONPATH_PREFIX="`$PYTHON -c \"import os, sys; print(os.pathsep.join([p for p in sys.path if p]+['']))\"`"
#endif
  $ export PYTHONPATH_PREFIX
  $ export PYTHONPATH

  $ cat > foobar.py <<EOF
  > import os
  > from mercurial import commands, exthelper, registrar
  > 
  > eh = exthelper.exthelper()
  > eh.configitem(b'tests', b'foo', default=b"Foo")
  > 
  > uisetup = eh.finaluisetup
  > uipopulate = eh.finaluipopulate
  > reposetup = eh.finalreposetup
  > cmdtable = eh.cmdtable
  > configtable = eh.configtable
  > 
  > @eh.uisetup
  > def _uisetup(ui):
  >     ui.debug(b"uisetup called [debug]\\n")
  >     ui.write(b"uisetup called\\n")
  >     ui.status(b"uisetup called [status]\\n")
  >     ui.flush()
  > @eh.uipopulate
  > def _uipopulate(ui):
  >     ui._populatecnt = getattr(ui, "_populatecnt", 0) + 1
  >     ui.write(b"uipopulate called (%d times)\n" % ui._populatecnt)
  > @eh.reposetup
  > def _reposetup(ui, repo):
  >     ui.write(b"reposetup called for %s\\n" % os.path.basename(repo.root))
  >     ui.write(b"ui %s= repo.ui\\n" % (ui == repo.ui and b"=" or b"!"))
  >     ui.flush()
  > @eh.command(b'foo', [], b'hg foo')
  > def foo(ui, *args, **kwargs):
  >     foo = ui.config(b'tests', b'foo')
  >     ui.write(foo)
  >     ui.write(b"\\n")
  > @eh.command(b'bar', [], b'hg bar', norepo=True)
  > def bar(ui, *args, **kwargs):
  >     ui.write(b"Bar\\n")
  > EOF
  $ abspath=`pwd`/foobar.py

  $ mkdir barfoo
  $ cp foobar.py barfoo/__init__.py
  $ barfoopath=`pwd`/barfoo

  $ hg init a
  $ cd a
  $ echo foo > file
  $ hg add file
  $ hg commit -m 'add file'

  $ echo '[extensions]' >> $HGRCPATH
  $ echo "foobar = $abspath" >> $HGRCPATH
  $ hg foo
  uisetup called
  uisetup called [status]
  uipopulate called (1 times)
  uipopulate called (1 times)
  uipopulate called (1 times)
  reposetup called for a
  ui == repo.ui
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  reposetup called for a (chg !)
  ui == repo.ui (chg !)
  Foo
  $ hg foo --quiet
  uisetup called (no-chg !)
  uipopulate called (1 times)
  uipopulate called (1 times)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times)
  reposetup called for a
  ui == repo.ui
  Foo
  $ hg foo --debug
  uisetup called [debug] (no-chg !)
  uisetup called (no-chg !)
  uisetup called [status] (no-chg !)
  uipopulate called (1 times)
  uipopulate called (1 times)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times)
  reposetup called for a
  ui == repo.ui
  Foo

  $ cd ..
  $ hg clone a b
  uisetup called (no-chg !)
  uisetup called [status] (no-chg !)
  uipopulate called (1 times)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times)
  reposetup called for a
  ui == repo.ui
  uipopulate called (1 times)
  uipopulate called (1 times)
  reposetup called for b
  ui == repo.ui
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg bar
  uisetup called (no-chg !)
  uisetup called [status] (no-chg !)
  uipopulate called (1 times)
  uipopulate called (1 times) (chg !)
  Bar
  $ echo 'foobar = !' >> $HGRCPATH

module/__init__.py-style

  $ echo "barfoo = $barfoopath" >> $HGRCPATH
  $ cd a
  $ hg foo
  uisetup called
  uisetup called [status]
  uipopulate called (1 times)
  uipopulate called (1 times)
  uipopulate called (1 times)
  reposetup called for a
  ui == repo.ui
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  uipopulate called (1 times) (chg !)
  reposetup called for a (chg !)
  ui == repo.ui (chg !)
  Foo
  $ echo 'barfoo = !' >> $HGRCPATH

Check that extensions are loaded in phases:

  $ cat > foo.py <<EOF
  > import os
  > from mercurial import exthelper
  > from mercurial.utils import procutil
  > 
  > def write(msg):
  >     procutil.stdout.write(msg)
  >     procutil.stdout.flush()
  > 
  > name = os.path.basename(__file__).rsplit('.', 1)[0]
  > bytesname = name.encode('utf-8')
  > write(b"1) %s imported\n" % bytesname)
  > eh = exthelper.exthelper()
  > @eh.uisetup
  > def _uisetup(ui):
  >     write(b"2) %s uisetup\n" % bytesname)
  > @eh.extsetup
  > def _extsetup(ui):
  >     write(b"3) %s extsetup\n" % bytesname)
  > @eh.uipopulate
  > def _uipopulate(ui):
  >     write(b"4) %s uipopulate\n" % bytesname)
  > @eh.reposetup
  > def _reposetup(ui, repo):
  >     write(b"5) %s reposetup\n" % bytesname)
  > 
  > extsetup = eh.finalextsetup
  > reposetup = eh.finalreposetup
  > uipopulate = eh.finaluipopulate
  > uisetup = eh.finaluisetup
  > revsetpredicate = eh.revsetpredicate
  > 
  > # custom predicate to check registration of functions at loading
  > from mercurial import (
  >     smartset,
  > )
  > @eh.revsetpredicate(bytesname, safe=True) # safe=True for query via hgweb
  > def custompredicate(repo, subset, x):
  >     return smartset.baseset([r for r in subset if r in {0}])
  > EOF

  $ cp foo.py bar.py
  $ echo 'foo = foo.py' >> $HGRCPATH
  $ echo 'bar = bar.py' >> $HGRCPATH

Check normal command's load order of extensions and registration of functions

 On chg server, extension should be first set up by the server. Then
 object-level setup should follow in the worker process.

  $ hg log -r "foo() and bar()" -q
  1) foo imported
  1) bar imported
  2) foo uisetup
  2) bar uisetup
  3) foo extsetup
  3) bar extsetup
  4) foo uipopulate
  4) bar uipopulate
  4) foo uipopulate
  4) bar uipopulate
  4) foo uipopulate
  4) bar uipopulate
  5) foo reposetup
  5) bar reposetup
  4) foo uipopulate (chg !)
  4) bar uipopulate (chg !)
  4) foo uipopulate (chg !)
  4) bar uipopulate (chg !)
  4) foo uipopulate (chg !)
  4) bar uipopulate (chg !)
  4) foo uipopulate (chg !)
  4) bar uipopulate (chg !)
  4) foo uipopulate (chg !)
  4) bar uipopulate (chg !)
  5) foo reposetup (chg !)
  5) bar reposetup (chg !)
  0:c24b9ac61126

Check hgweb's load order of extensions and registration of functions

  $ cat > hgweb.cgi <<EOF
  > #!$PYTHON
  > from mercurial import demandimport; demandimport.enable()
  > from mercurial.hgweb import hgweb
  > from mercurial.hgweb import wsgicgi
  > application = hgweb(b'.', b'test repo')
  > wsgicgi.launch(application)
  > EOF
  $ . "$TESTDIR/cgienv"

  $ PATH_INFO='/' SCRIPT_NAME='' "$PYTHON" hgweb.cgi \
  >    | grep '^[0-9]) ' # ignores HTML output
  1) foo imported
  1) bar imported
  2) foo uisetup
  2) bar uisetup
  3) foo extsetup
  3) bar extsetup
  4) foo uipopulate
  4) bar uipopulate
  4) foo uipopulate
  4) bar uipopulate
  5) foo reposetup
  5) bar reposetup

(check that revset predicate foo() and bar() are available)

#if msys
  $ PATH_INFO='//shortlog'
#else
  $ PATH_INFO='/shortlog'
#endif
  $ export PATH_INFO
  $ SCRIPT_NAME='' QUERY_STRING='rev=foo() and bar()' "$PYTHON" hgweb.cgi \
  >     | grep '<a href="/rev/[0-9a-z]*">'
     <a href="/rev/c24b9ac61126">add file</a>

  $ echo 'foo = !' >> $HGRCPATH
  $ echo 'bar = !' >> $HGRCPATH

Check "from __future__ import absolute_import" support for external libraries

(import-checker.py reports issues for some of heredoc python code
fragments below, because import-checker.py does not know test specific
package hierarchy. NO_CHECK_* should be used as a limit mark of
heredoc, in order to make import-checker.py ignore them. For
simplicity, all python code fragments below are generated with such
limit mark, regardless of importing module or not.)


  $ mkdir $TESTTMP/libroot
  $ echo "s = 'libroot/ambig.py'" > $TESTTMP/libroot/ambig.py
  $ mkdir $TESTTMP/libroot/mod
  $ touch $TESTTMP/libroot/mod/__init__.py
  $ echo "s = 'libroot/mod/ambig.py'" > $TESTTMP/libroot/mod/ambig.py

  $ cat > $TESTTMP/libroot/mod/ambigabs.py <<NO_CHECK_EOF
  > import ambig # should load "libroot/ambig.py"
  > s = ambig.s
  > NO_CHECK_EOF
  $ cat > loadabs.py <<NO_CHECK_EOF
  > import mod.ambigabs as ambigabs
  > def extsetup(ui):
  >     print('ambigabs.s=%s' % ambigabs.s, flush=True)
  > NO_CHECK_EOF
  $ (PYTHONPATH=${PYTHONPATH_PREFIX}${TESTTMP}/libroot; hg --config extensions.loadabs=loadabs.py root)
  ambigabs.s=libroot/ambig.py
  $TESTTMP/a

Check absolute/relative import of extension specific modules

  $ mkdir $TESTTMP/extroot
  $ cat > $TESTTMP/extroot/bar.py <<NO_CHECK_EOF
  > s = b'this is extroot.bar'
  > NO_CHECK_EOF
  $ mkdir $TESTTMP/extroot/sub1
  $ cat > $TESTTMP/extroot/sub1/__init__.py <<NO_CHECK_EOF
  > s = b'this is extroot.sub1.__init__'
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extroot/sub1/baz.py <<NO_CHECK_EOF
  > s = b'this is extroot.sub1.baz'
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extroot/__init__.py <<NO_CHECK_EOF
  > s = b'this is extroot.__init__'
  > from . import foo
  > def extsetup(ui):
  >     ui.write(b'(extroot) ', foo.func(), b'\n')
  >     ui.flush()
  > NO_CHECK_EOF

  $ cat > $TESTTMP/extroot/foo.py <<NO_CHECK_EOF
  > # test absolute import
  > buf = []
  > def func():
  >     # "not locals" case
  >     import extroot.bar
  >     buf.append(b'import extroot.bar in func(): %s' % extroot.bar.s)
  >     return b'\n(extroot) '.join(buf)
  > # b"fromlist == ('*',)" case
  > from extroot.bar import *
  > buf.append(b'from extroot.bar import *: %s' % s)
  > # "not fromlist" and "if '.' in name" case
  > import extroot.sub1.baz
  > buf.append(b'import extroot.sub1.baz: %s' % extroot.sub1.baz.s)
  > # "not fromlist" and NOT "if '.' in name" case
  > import extroot
  > buf.append(b'import extroot: %s' % extroot.s)
  > # NOT "not fromlist" and NOT "level != -1" case
  > from extroot.bar import s
  > buf.append(b'from extroot.bar import s: %s' % s)
  > NO_CHECK_EOF
  $ (PYTHONPATH=${PYTHONPATH_PREFIX}${TESTTMP}; hg --config extensions.extroot=$TESTTMP/extroot root)
  (extroot) from extroot.bar import *: this is extroot.bar
  (extroot) import extroot.sub1.baz: this is extroot.sub1.baz
  (extroot) import extroot: this is extroot.__init__
  (extroot) from extroot.bar import s: this is extroot.bar
  (extroot) import extroot.bar in func(): this is extroot.bar
  $TESTTMP/a

#if demandimport

Examine whether module loading is delayed until actual referring, even
though module is imported with "absolute_import" feature.

Files below in each packages are used for described purpose:

- "called": examine whether "from MODULE import ATTR" works correctly
- "unused": examine whether loading is delayed correctly
- "used":   examine whether "from PACKAGE import MODULE" works correctly

Package hierarchy is needed to examine whether demand importing works
as expected for "from SUB.PACK.AGE import MODULE".

Setup "external library" to be imported with "absolute_import"
feature.

  $ mkdir -p $TESTTMP/extlibroot/lsub1/lsub2
  $ touch $TESTTMP/extlibroot/__init__.py
  $ touch $TESTTMP/extlibroot/lsub1/__init__.py
  $ touch $TESTTMP/extlibroot/lsub1/lsub2/__init__.py

  $ cat > $TESTTMP/extlibroot/lsub1/lsub2/called.py <<NO_CHECK_EOF
  > def func():
  >     return b"this is extlibroot.lsub1.lsub2.called.func()"
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extlibroot/lsub1/lsub2/unused.py <<NO_CHECK_EOF
  > raise Exception("extlibroot.lsub1.lsub2.unused is loaded unintentionally")
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extlibroot/lsub1/lsub2/used.py <<NO_CHECK_EOF
  > detail = b"this is extlibroot.lsub1.lsub2.used"
  > NO_CHECK_EOF

Setup sub-package of "external library", which causes instantiation of
demandmod in "recurse down the module chain" code path. Relative
importing with "absolute_import" feature isn't tested, because "level
>=1 " doesn't cause instantiation of demandmod.

  $ mkdir -p $TESTTMP/extlibroot/recursedown/abs
  $ cat > $TESTTMP/extlibroot/recursedown/abs/used.py <<NO_CHECK_EOF
  > detail = b"this is extlibroot.recursedown.abs.used"
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extlibroot/recursedown/abs/__init__.py <<NO_CHECK_EOF
  > from extlibroot.recursedown.abs.used import detail
  > NO_CHECK_EOF

  $ mkdir -p $TESTTMP/extlibroot/recursedown/legacy
  $ cat > $TESTTMP/extlibroot/recursedown/legacy/used.py <<NO_CHECK_EOF
  > detail = b"this is extlibroot.recursedown.legacy.used"
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extlibroot/recursedown/legacy/__init__.py <<NO_CHECK_EOF
  > # legacy style (level == -1) import
  > from extlibroot.recursedown.legacy.used import detail
  > NO_CHECK_EOF

  $ cat > $TESTTMP/extlibroot/recursedown/__init__.py <<NO_CHECK_EOF
  > from extlibroot.recursedown.abs import detail as absdetail
  > from .legacy import detail as legacydetail
  > NO_CHECK_EOF

Setup package that re-exports an attribute of its submodule as the same
name. This leaves 'shadowing.used' pointing to 'used.detail', but still
the submodule 'used' should be somehow accessible. (issue5617)

  $ mkdir -p $TESTTMP/extlibroot/shadowing
  $ cat > $TESTTMP/extlibroot/shadowing/used.py <<NO_CHECK_EOF
  > detail = b"this is extlibroot.shadowing.used"
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extlibroot/shadowing/proxied.py <<NO_CHECK_EOF
  > from extlibroot.shadowing.used import detail
  > NO_CHECK_EOF
  $ cat > $TESTTMP/extlibroot/shadowing/__init__.py <<NO_CHECK_EOF
  > from .used import detail as used
  > NO_CHECK_EOF

Setup extension local modules to be imported with "absolute_import"
feature.

  $ mkdir -p $TESTTMP/absextroot/xsub1/xsub2
  $ touch $TESTTMP/absextroot/xsub1/__init__.py
  $ touch $TESTTMP/absextroot/xsub1/xsub2/__init__.py

  $ cat > $TESTTMP/absextroot/xsub1/xsub2/called.py <<NO_CHECK_EOF
  > def func():
  >     return b"this is absextroot.xsub1.xsub2.called.func()"
  > NO_CHECK_EOF
  $ cat > $TESTTMP/absextroot/xsub1/xsub2/unused.py <<NO_CHECK_EOF
  > raise Exception("absextroot.xsub1.xsub2.unused is loaded unintentionally")
  > NO_CHECK_EOF
  $ cat > $TESTTMP/absextroot/xsub1/xsub2/used.py <<NO_CHECK_EOF
  > detail = b"this is absextroot.xsub1.xsub2.used"
  > NO_CHECK_EOF

Setup extension local modules to examine whether demand importing
works as expected in "level > 1" case.

  $ cat > $TESTTMP/absextroot/relimportee.py <<NO_CHECK_EOF
  > detail = b"this is absextroot.relimportee"
  > NO_CHECK_EOF
  $ cat > $TESTTMP/absextroot/xsub1/xsub2/relimporter.py <<NO_CHECK_EOF
  > from mercurial import pycompat
  > from ... import relimportee
  > detail = b"this relimporter imports %r" % (
  >     pycompat.bytestr(relimportee.detail))
  > NO_CHECK_EOF

Setup modules, which actually import extension local modules at
runtime.

  $ cat > $TESTTMP/absextroot/absolute.py << NO_CHECK_EOF
  > 
  > # import extension local modules absolutely (level = 0)
  > from absextroot.xsub1.xsub2 import used, unused
  > from absextroot.xsub1.xsub2.called import func
  > 
  > def getresult():
  >     result = []
  >     result.append(used.detail)
  >     result.append(func())
  >     return result
  > NO_CHECK_EOF

  $ cat > $TESTTMP/absextroot/relative.py << NO_CHECK_EOF
  > 
  > # import extension local modules relatively (level == 1)
  > from .xsub1.xsub2 import used, unused
  > from .xsub1.xsub2.called import func
  > 
  > # import a module, which implies "importing with level > 1"
  > from .xsub1.xsub2 import relimporter
  > 
  > def getresult():
  >     result = []
  >     result.append(used.detail)
  >     result.append(func())
  >     result.append(relimporter.detail)
  >     return result
  > NO_CHECK_EOF

Setup main procedure of extension.

  $ cat > $TESTTMP/absextroot/__init__.py <<NO_CHECK_EOF
  > from mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > 
  > # "absolute" and "relative" shouldn't be imported before actual
  > # command execution, because (1) they import same modules, and (2)
  > # preceding import (= instantiate "demandmod" object instead of
  > # real "module" object) might hide problem of succeeding import.
  > 
  > @command(b'showabsolute', [], norepo=True)
  > def showabsolute(ui, *args, **opts):
  >     from absextroot import absolute
  >     ui.write(b'ABS: %s\n' % b'\nABS: '.join(absolute.getresult()))
  > 
  > @command(b'showrelative', [], norepo=True)
  > def showrelative(ui, *args, **opts):
  >     from . import relative
  >     ui.write(b'REL: %s\n' % b'\nREL: '.join(relative.getresult()))
  > 
  > # import modules from external library
  > from extlibroot.lsub1.lsub2 import used as lused, unused as lunused
  > from extlibroot.lsub1.lsub2.called import func as lfunc
  > from extlibroot.recursedown import absdetail, legacydetail
  > from extlibroot.shadowing import proxied
  > 
  > def uisetup(ui):
  >     result = []
  >     result.append(lused.detail)
  >     result.append(lfunc())
  >     result.append(absdetail)
  >     result.append(legacydetail)
  >     result.append(proxied.detail)
  >     ui.write(b'LIB: %s\n' % b'\nLIB: '.join(result))
  > NO_CHECK_EOF

Examine module importing.

  $ (PYTHONPATH=${PYTHONPATH_PREFIX}${TESTTMP}; hg --config extensions.absextroot=$TESTTMP/absextroot showabsolute)
  LIB: this is extlibroot.lsub1.lsub2.used
  LIB: this is extlibroot.lsub1.lsub2.called.func()
  LIB: this is extlibroot.recursedown.abs.used
  LIB: this is extlibroot.recursedown.legacy.used
  LIB: this is extlibroot.shadowing.used
  ABS: this is absextroot.xsub1.xsub2.used
  ABS: this is absextroot.xsub1.xsub2.called.func()

  $ (PYTHONPATH=${PYTHONPATH_PREFIX}${TESTTMP}; hg --config extensions.absextroot=$TESTTMP/absextroot showrelative)
  LIB: this is extlibroot.lsub1.lsub2.used
  LIB: this is extlibroot.lsub1.lsub2.called.func()
  LIB: this is extlibroot.recursedown.abs.used
  LIB: this is extlibroot.recursedown.legacy.used
  LIB: this is extlibroot.shadowing.used
  REL: this is absextroot.xsub1.xsub2.used
  REL: this is absextroot.xsub1.xsub2.called.func()
  REL: this relimporter imports 'this is absextroot.relimportee'

Examine whether sub-module is imported relatively as expected.

See also issue5208 for detail about example case on Python 3.x.

  $ f -q $TESTTMP/extlibroot/lsub1/lsub2/notexist.py
  $TESTTMP/extlibroot/lsub1/lsub2/notexist.py: file not found

  $ cat > $TESTTMP/notexist.py <<NO_CHECK_EOF
  > text = 'notexist.py at root is loaded unintentionally\n'
  > NO_CHECK_EOF

  $ cat > $TESTTMP/checkrelativity.py <<NO_CHECK_EOF
  > from mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > 
  > # demand import avoids failure of importing notexist here, but only on
  > # Python 2.
  > import extlibroot.lsub1.lsub2.notexist
  > 
  > @command(b'checkrelativity', [], norepo=True)
  > def checkrelativity(ui, *args, **opts):
  >     try:
  >         ui.write(extlibroot.lsub1.lsub2.notexist.text)
  >         return 1 # unintentional success
  >     except ImportError:
  >         pass # intentional failure
  > NO_CHECK_EOF

Python 3's lazy importer verifies modules exist before returning the lazy
module stub. Our custom lazy importer for Python 2 always returns a stub.

  $ (PYTHONPATH=${PYTHONPATH_PREFIX}${TESTTMP}; hg --config extensions.checkrelativity=$TESTTMP/checkrelativity.py checkrelativity) || true
  *** failed to import extension "checkrelativity" from $TESTTMP/checkrelativity.py: No module named 'extlibroot.lsub1.lsub2.notexist'
  hg: unknown command 'checkrelativity'
  (use 'hg help' for a list of commands)

#endif

(Here, module importing tests are finished. Therefore, use other than
NO_CHECK_* limit mark for heredoc python files, in order to apply
import-checker.py or so on their contents)

Make sure a broken uisetup doesn't globally break hg:
  $ cat > $TESTTMP/baduisetup.py <<EOF
  > def uisetup(ui):
  >     1 / 0
  > EOF

Even though the extension fails during uisetup, hg is still basically usable:
  $ hg --config extensions.baduisetup=$TESTTMP/baduisetup.py version
  Traceback (most recent call last):
    File "*/mercurial/extensions.py", line *, in _runuisetup (glob) (no-pyoxidizer !)
    File "mercurial.extensions", line *, in _runuisetup (glob) (pyoxidizer !)
      uisetup(ui)
      ~~~~~~~^^^^ (py313 !)
    File "$TESTTMP/baduisetup.py", line 2, in uisetup
      1 / 0
      ~~^~~ (py311 !)
  ZeroDivisionError: * by zero (glob)
  *** failed to set up extension baduisetup: * by zero (glob)
  Mercurial Distributed SCM (version *) (glob)
  (see https://mercurial-scm.org for more information)
  
  Copyright (C) 2005-* Olivia Mackall and others (glob)
  This is free software; see the source for copying conditions. There is NO
  warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  $ cd ..

hide outer repo
  $ hg init

  $ cat > empty.py <<EOF
  > '''empty cmdtable
  > '''
  > cmdtable = {}
  > EOF
  $ emptypath=`pwd`/empty.py
  $ echo "empty = $emptypath" >> $HGRCPATH
  $ hg help empty
  empty extension - empty cmdtable
  
  no commands defined


  $ echo 'empty = !' >> $HGRCPATH

  $ cat > debugextension.py <<EOF
  > '''only debugcommands
  > '''
  > from mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'debugfoobar', [], b'hg debugfoobar')
  > def debugfoobar(ui, repo, *args, **opts):
  >     "yet another debug command"
  > @command(b'foo', [], b'hg foo')
  > def foo(ui, repo, *args, **opts):
  >     """yet another foo command
  >     This command has been DEPRECATED since forever.
  >     """
  > EOF
  $ debugpath=`pwd`/debugextension.py
  $ echo "debugextension = $debugpath" >> $HGRCPATH

  $ hg help debugextension
  hg debugextensions
  
  show information about active extensions
  
  options:
  
   -T --template TEMPLATE display with template
  
  (some details hidden, use --verbose to show complete help)


  $ hg --verbose help debugextension
  hg debugextensions
  
  show information about active extensions
  
  options:
  
   -T --template TEMPLATE display with template
  
  global options ([+] can be repeated):
  
   -R --repository REPO      repository root directory or name of overlay bundle
                             file
      --cwd DIR              change working directory
   -y --noninteractive       do not prompt, automatically pick the first choice
                             for all prompts
   -q --quiet                suppress output
   -v --verbose              enable additional output
      --color TYPE           when to colorize (boolean, always, auto, never, or
                             debug)
      --config CONFIG [+]    set/override config option (use
                             'section.name=value')
      --config-file HGRC [+] load config file to set/override config options
      --debug                enable debugging output
      --debugger             start debugger
      --encoding ENCODE      set the charset encoding (default: ascii)
      --encodingmode MODE    set the charset encoding mode (default: strict)
      --traceback            always print a traceback on exception
      --time                 time how long the command takes
      --profile              print command execution profile
      --version              output version information and exit
   -h --help                 display help and exit
      --hidden               consider hidden changesets
      --pager TYPE           when to paginate (boolean, always, auto, or never)
                             (default: auto)






  $ hg --debug help debugextension
  hg debugextensions
  
  show information about active extensions
  
  options:
  
   -T --template TEMPLATE display with template
  
  global options ([+] can be repeated):
  
   -R --repository REPO      repository root directory or name of overlay bundle
                             file
      --cwd DIR              change working directory
   -y --noninteractive       do not prompt, automatically pick the first choice
                             for all prompts
   -q --quiet                suppress output
   -v --verbose              enable additional output
      --color TYPE           when to colorize (boolean, always, auto, never, or
                             debug)
      --config CONFIG [+]    set/override config option (use
                             'section.name=value')
      --config-file HGRC [+] load config file to set/override config options
      --debug                enable debugging output
      --debugger             start debugger
      --encoding ENCODE      set the charset encoding (default: ascii)
      --encodingmode MODE    set the charset encoding mode (default: strict)
      --traceback            always print a traceback on exception
      --time                 time how long the command takes
      --profile              print command execution profile
      --version              output version information and exit
   -h --help                 display help and exit
      --hidden               consider hidden changesets
      --pager TYPE           when to paginate (boolean, always, auto, or never)
                             (default: auto)





  $ echo 'debugextension = !' >> $HGRCPATH

Asking for help about a deprecated extension should do something useful:

  $ hg help glog
  'glog' is provided by the following extension:
  
      graphlog      command to view revision graphs from a shell (DEPRECATED)
  
  (use 'hg help extensions' for information on enabling extensions)

Extension module help vs command help:

  $ echo 'extdiff =' >> $HGRCPATH
  $ hg help extdiff
  hg extdiff [OPT]... [FILE]...
  
  use external program to diff repository (or selected files)
  
  Show differences between revisions for the specified files, using an external
  program. The default program used is diff, with default options "-Npru".
  
  To select a different program, use the -p/--program option. The program will
  be passed the names of two directories to compare, unless the --per-file
  option is specified (see below). To pass additional options to the program,
  use -o/--option. These will be passed before the names of the directories or
  files to compare.
  
  The --from, --to, and --change options work the same way they do for 'hg
  diff'.
  
  The --per-file option runs the external program repeatedly on each file to
  diff, instead of once on two directories. By default, this happens one by one,
  where the next file diff is open in the external program only once the
  previous external program (for the previous file diff) has exited. If the
  external program has a graphical interface, it can open all the file diffs at
  once instead of one by one. See 'hg help -e extdiff' for information about how
  to tell Mercurial that a given program has a graphical interface.
  
  The --confirm option will prompt the user before each invocation of the
  external program. It is ignored if --per-file isn't specified.
  
  (use 'hg help -e extdiff' to show help for the extdiff extension)
  
  options ([+] can be repeated):
  
   -p --program CMD         comparison program to run
   -o --option OPT [+]      pass option to comparison program
      --from REV1           revision to diff from
      --to REV2             revision to diff to
   -c --change REV          change made by revision
      --per-file            compare each file instead of revision snapshots
      --confirm             prompt user before each external program invocation
      --patch               compare patches for two revisions
   -I --include PATTERN [+] include names matching the given patterns
   -X --exclude PATTERN [+] exclude names matching the given patterns
   -S --subrepos            recurse into subrepositories
  
  (some details hidden, use --verbose to show complete help)










  $ hg help --extension extdiff
  extdiff extension - command to allow external programs to compare revisions
  
  The extdiff Mercurial extension allows you to use external programs to compare
  revisions, or revision with working directory. The external diff programs are
  called with a configurable set of options and two non-option arguments: paths
  to directories containing snapshots of files to compare.
  
  If there is more than one file being compared and the "child" revision is the
  working directory, any modifications made in the external diff program will be
  copied back to the working directory from the temporary directory.
  
  The extdiff extension also allows you to configure new diff commands, so you
  do not need to type 'hg extdiff -p kdiff3' always.
  
    [extdiff]
    # add new command that runs GNU diff(1) in 'context diff' mode
    cdiff = gdiff -Nprc5
    ## or the old way:
    #cmd.cdiff = gdiff
    #opts.cdiff = -Nprc5
  
    # add new command called meld, runs meld (no need to name twice).  If
    # the meld executable is not available, the meld tool in [merge-tools]
    # will be used, if available
    meld =
  
    # add new command called vimdiff, runs gvimdiff with DirDiff plugin
    # (see http://www.vim.org/scripts/script.php?script_id=102) Non
    # English user, be sure to put "let g:DirDiffDynamicDiffText = 1" in
    # your .vimrc
    vimdiff = gvim -f "+next" \
              "+execute 'DirDiff' fnameescape(argv(0)) fnameescape(argv(1))"
  
  Tool arguments can include variables that are expanded at runtime:
  
    $parent1, $plabel1 - filename, descriptive label of first parent
    $child,   $clabel  - filename, descriptive label of child revision
    $parent2, $plabel2 - filename, descriptive label of second parent
    $root              - repository root
    $parent is an alias for $parent1.
  
  The extdiff extension will look in your [diff-tools] and [merge-tools]
  sections for diff tool arguments, when none are specified in [extdiff].
  
    [extdiff]
    kdiff3 =
  
    [diff-tools]
    kdiff3.diffargs=--L1 '$plabel1' --L2 '$clabel' $parent $child
  
  If a program has a graphical interface, it might be interesting to tell
  Mercurial about it. It will prevent the program from being mistakenly used in
  a terminal-only environment (such as an SSH terminal session), and will make
  'hg extdiff --per-file' open multiple file diffs at once instead of one by one
  (if you still want to open file diffs one by one, you can use the --confirm
  option).
  
  Declaring that a tool has a graphical interface can be done with the "gui"
  flag next to where "diffargs" are specified:
  
    [diff-tools]
    kdiff3.diffargs=--L1 '$plabel1' --L2 '$clabel' $parent $child
    kdiff3.gui = true
  
  You can use -I/-X and list of file or directory names like normal 'hg diff'
  command. The extdiff extension makes snapshots of only needed files, so
  running the external diff program will actually be pretty fast (at least
  faster than having to compare the entire tree).
  
  list of commands:
  
   extdiff       use external program to diff repository (or selected files)
  
  (use 'hg help -v -e extdiff' to show built-in aliases and global options)
















  $ echo 'extdiff = !' >> $HGRCPATH

Test help topic with same name as extension

  $ cat > multirevs.py <<EOF
  > from mercurial import commands, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > """multirevs extension
  > Big multi-line module docstring."""
  > @command(b'multirevs', [], b'ARG', norepo=True)
  > def multirevs(ui, repo, arg, *args, **opts):
  >     """multirevs command"""
  > EOF
  $ echo "multirevs = multirevs.py" >> $HGRCPATH

  $ hg help multirevs | tail
        used):
  
          hg update :@
  
      - Show diff between tags 1.3 and 1.5 (this works because the first and the
        last revisions of the revset are used):
  
          hg diff -r 1.3::1.5
  
  use 'hg help -c multirevs' to see help for the multirevs command






  $ hg help -c multirevs
  hg multirevs ARG
  
  multirevs command
  
  (some details hidden, use --verbose to show complete help)



  $ hg multirevs
  hg multirevs: invalid arguments
  hg multirevs ARG
  
  multirevs command
  
  (use 'hg multirevs -h' to show more help)
  [10]



  $ echo "multirevs = !" >> $HGRCPATH

Issue811: Problem loading extensions twice (by site and by user)

  $ cat <<EOF >> $HGRCPATH
  > mq =
  > strip =
  > hgext.mq =
  > hgext/mq =
  > EOF

Show extensions:
(note that mq force load strip, also checking it's not loaded twice)

#if no-extraextensions
  $ hg debugextensions
  mq
  strip
#endif

For extensions, which name matches one of its commands, help
message should ask '-v -e' to get list of built-in aliases
along with extension help itself

  $ mkdir $TESTTMP/d
  $ cat > $TESTTMP/d/dodo.py <<EOF
  > """
  > This is an awesome 'dodo' extension. It does nothing and
  > writes 'Foo foo'
  > """
  > from mercurial import commands, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'dodo', [], b'hg dodo')
  > def dodo(ui, *args, **kwargs):
  >     """Does nothing"""
  >     ui.write(b"I do nothing. Yay\\n")
  > @command(b'foofoo', [], b'hg foofoo')
  > def foofoo(ui, *args, **kwargs):
  >     """Writes 'Foo foo'"""
  >     ui.write(b"Foo foo\\n")
  > EOF
  $ dodopath=$TESTTMP/d/dodo.py

  $ echo "dodo = $dodopath" >> $HGRCPATH

Make sure that user is asked to enter '-v -e' to get list of built-in aliases
  $ hg help -e dodo
  dodo extension -
  
  This is an awesome 'dodo' extension. It does nothing and writes 'Foo foo'
  
  list of commands:
  
   dodo          Does nothing
   foofoo        Writes 'Foo foo'
  
  (use 'hg help -v -e dodo' to show built-in aliases and global options)

Make sure that '-v -e' prints list of built-in aliases along with
extension help itself
  $ hg help -v -e dodo
  dodo extension -
  
  This is an awesome 'dodo' extension. It does nothing and writes 'Foo foo'
  
  list of commands:
  
   dodo          Does nothing
   foofoo        Writes 'Foo foo'
  
  global options ([+] can be repeated):
  
   -R --repository REPO      repository root directory or name of overlay bundle
                             file
      --cwd DIR              change working directory
   -y --noninteractive       do not prompt, automatically pick the first choice
                             for all prompts
   -q --quiet                suppress output
   -v --verbose              enable additional output
      --color TYPE           when to colorize (boolean, always, auto, never, or
                             debug)
      --config CONFIG [+]    set/override config option (use
                             'section.name=value')
      --config-file HGRC [+] load config file to set/override config options
      --debug                enable debugging output
      --debugger             start debugger
      --encoding ENCODE      set the charset encoding (default: ascii)
      --encodingmode MODE    set the charset encoding mode (default: strict)
      --traceback            always print a traceback on exception
      --time                 time how long the command takes
      --profile              print command execution profile
      --version              output version information and exit
   -h --help                 display help and exit
      --hidden               consider hidden changesets
      --pager TYPE           when to paginate (boolean, always, auto, or never)
                             (default: auto)

Make sure that single '-v' option shows help and built-ins only for 'dodo' command
  $ hg help -v dodo
  hg dodo
  
  Does nothing
  
  (use 'hg help -e dodo' to show help for the dodo extension)
  
  options:
  
    --mq operate on patch repository
  
  global options ([+] can be repeated):
  
   -R --repository REPO      repository root directory or name of overlay bundle
                             file
      --cwd DIR              change working directory
   -y --noninteractive       do not prompt, automatically pick the first choice
                             for all prompts
   -q --quiet                suppress output
   -v --verbose              enable additional output
      --color TYPE           when to colorize (boolean, always, auto, never, or
                             debug)
      --config CONFIG [+]    set/override config option (use
                             'section.name=value')
      --config-file HGRC [+] load config file to set/override config options
      --debug                enable debugging output
      --debugger             start debugger
      --encoding ENCODE      set the charset encoding (default: ascii)
      --encodingmode MODE    set the charset encoding mode (default: strict)
      --traceback            always print a traceback on exception
      --time                 time how long the command takes
      --profile              print command execution profile
      --version              output version information and exit
   -h --help                 display help and exit
      --hidden               consider hidden changesets
      --pager TYPE           when to paginate (boolean, always, auto, or never)
                             (default: auto)

In case when extension name doesn't match any of its commands,
help message should ask for '-v' to get list of built-in aliases
along with extension help
  $ cat > $TESTTMP/d/dudu.py <<EOF
  > """
  > This is an awesome 'dudu' extension. It does something and
  > also writes 'Beep beep'
  > """
  > from mercurial import commands, registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'something', [], b'hg something')
  > def something(ui, *args, **kwargs):
  >     """Does something"""
  >     ui.write(b"I do something. Yaaay\\n")
  > @command(b'beep', [], b'hg beep')
  > def beep(ui, *args, **kwargs):
  >     """Writes 'Beep beep'"""
  >     ui.write(b"Beep beep\\n")
  > EOF
  $ dudupath=$TESTTMP/d/dudu.py

  $ echo "dudu = $dudupath" >> $HGRCPATH

  $ hg help -e dudu
  dudu extension -
  
  This is an awesome 'dudu' extension. It does something and also writes 'Beep
  beep'
  
  list of commands:
  
   beep          Writes 'Beep beep'
   something     Does something
  
  (use 'hg help -v dudu' to show built-in aliases and global options)

In case when extension name doesn't match any of its commands,
help options '-v' and '-v -e' should be equivalent
  $ hg help -v dudu
  dudu extension -
  
  This is an awesome 'dudu' extension. It does something and also writes 'Beep
  beep'
  
  list of commands:
  
   beep          Writes 'Beep beep'
   something     Does something
  
  global options ([+] can be repeated):
  
   -R --repository REPO      repository root directory or name of overlay bundle
                             file
      --cwd DIR              change working directory
   -y --noninteractive       do not prompt, automatically pick the first choice
                             for all prompts
   -q --quiet                suppress output
   -v --verbose              enable additional output
      --color TYPE           when to colorize (boolean, always, auto, never, or
                             debug)
      --config CONFIG [+]    set/override config option (use
                             'section.name=value')
      --config-file HGRC [+] load config file to set/override config options
      --debug                enable debugging output
      --debugger             start debugger
      --encoding ENCODE      set the charset encoding (default: ascii)
      --encodingmode MODE    set the charset encoding mode (default: strict)
      --traceback            always print a traceback on exception
      --time                 time how long the command takes
      --profile              print command execution profile
      --version              output version information and exit
   -h --help                 display help and exit
      --hidden               consider hidden changesets
      --pager TYPE           when to paginate (boolean, always, auto, or never)
                             (default: auto)

  $ hg help -v -e dudu
  dudu extension -
  
  This is an awesome 'dudu' extension. It does something and also writes 'Beep
  beep'
  
  list of commands:
  
   beep          Writes 'Beep beep'
   something     Does something
  
  global options ([+] can be repeated):
  
   -R --repository REPO      repository root directory or name of overlay bundle
                             file
      --cwd DIR              change working directory
   -y --noninteractive       do not prompt, automatically pick the first choice
                             for all prompts
   -q --quiet                suppress output
   -v --verbose              enable additional output
      --color TYPE           when to colorize (boolean, always, auto, never, or
                             debug)
      --config CONFIG [+]    set/override config option (use
                             'section.name=value')
      --config-file HGRC [+] load config file to set/override config options
      --debug                enable debugging output
      --debugger             start debugger
      --encoding ENCODE      set the charset encoding (default: ascii)
      --encodingmode MODE    set the charset encoding mode (default: strict)
      --traceback            always print a traceback on exception
      --time                 time how long the command takes
      --profile              print command execution profile
      --version              output version information and exit
   -h --help                 display help and exit
      --hidden               consider hidden changesets
      --pager TYPE           when to paginate (boolean, always, auto, or never)
                             (default: auto)

Disabled extension commands:

  $ ORGHGRCPATH=$HGRCPATH
  $ HGRCPATH=
  $ export HGRCPATH
  $ hg help email
  'email' is provided by the following extension:
  
      patchbomb     command to send changesets as (a series of) patch emails
  
  (use 'hg help extensions' for information on enabling extensions)


  $ hg qdel
  hg: unknown command 'qdel'
  'qdelete' is provided by the following extension:
  
      mq            manage a stack of patches
  
  (use 'hg help extensions' for information on enabling extensions)
  [255]


  $ hg churn
  hg: unknown command 'churn'
  'churn' is provided by the following extension:
  
      churn         command to display statistics about repository history
  
  (use 'hg help extensions' for information on enabling extensions)
  [255]



Disabled extensions:

  $ hg help churn
  churn extension - command to display statistics about repository history
  
  (use 'hg help extensions' for information on enabling extensions)

  $ hg help patchbomb
  patchbomb extension - command to send changesets as (a series of) patch emails
  
  The series is started off with a "[PATCH 0 of N]" introduction, which
  describes the series as a whole.
  
  Each patch email has a Subject line of "[PATCH M of N] ...", using the first
  line of the changeset description as the subject text. The message contains
  two or three body parts:
  
  - The changeset description.
  - [Optional] The result of running diffstat on the patch.
  - The patch itself, as generated by 'hg export'.
  
  Each message refers to the first in the series using the In-Reply-To and
  References headers, so they will show up as a sequence in threaded mail and
  news readers, and in mail archives.
  
  To configure other defaults, add a section like this to your configuration
  file:
  
    [email]
    from = My Name <my@email>
    to = recipient1, recipient2, ...
    cc = cc1, cc2, ...
    bcc = bcc1, bcc2, ...
    reply-to = address1, address2, ...
  
  Use "[patchbomb]" as configuration section name if you need to override global
  "[email]" address settings.
  
  Then you can use the 'hg email' command to mail a series of changesets as a
  patchbomb.
  
  You can also either configure the method option in the email section to be a
  sendmail compatible mailer or fill out the [smtp] section so that the
  patchbomb extension can automatically send patchbombs directly from the
  commandline. See the [email] and [smtp] sections in hgrc(5) for details.
  
  By default, 'hg email' will prompt for a "To" or "CC" header if you do not
  supply one via configuration or the command line.  You can override this to
  never prompt by configuring an empty value:
  
    [email]
    cc =
  
  You can control the default inclusion of an introduction message with the
  "patchbomb.intro" configuration option. The configuration is always
  overwritten by command line flags like --intro and --desc:
  
    [patchbomb]
    intro=auto   # include introduction message if more than 1 patch (default)
    intro=never  # never include an introduction message
    intro=always # always include an introduction message
  
  You can specify a template for flags to be added in subject prefixes. Flags
  specified by --flag option are exported as "{flags}" keyword:
  
    [patchbomb]
    flagtemplate = "{separate(' ',
                              ifeq(branch, 'default', '', branch|upper),
                              flags)}"
  
  You can set patchbomb to always ask for confirmation by setting
  "patchbomb.confirm" to true.
  
  (use 'hg help extensions' for information on enabling extensions)


Help can find unimported extensions
-----------------------------------

XXX-PYOXIDIZER since the frozen binary does not have source directory tree,
this make the checking for actual file under `hgext` a bit complicated. In
addition these tests do some strange dance to ensure some other module are the
first in `sys.path` (since the current install path is always in front
otherwise) that are fragile and that does not match reality in the field. So
for now we disable this test untill a deeper rework of that logic is done.

#if no-pyoxidizer

Broken disabled extension and command:

  $ mkdir hgext
  $ echo > hgext/__init__.py
  $ cat > hgext/broken.py <<NO_CHECK_EOF
  > "broken extension'
  > NO_CHECK_EOF
  $ cat > path.py <<EOF
  > import os
  > import sys
  > sys.path.insert(0, os.environ['HGEXTPATH'])
  > EOF
  $ HGEXTPATH=`pwd`
  $ export HGEXTPATH

  $ hg --config extensions.path=./path.py help broken
  broken extension - (no help text available)
  
  (use 'hg help extensions' for information on enabling extensions)


  $ cat > hgext/forest.py <<EOF
  > cmdtable = None
  > @command()
  > def f():
  >     pass
  > @command(123)
  > def g():
  >     pass
  > EOF
  $ hg --config extensions.path=./path.py help foo
  abort: no such help topic: foo
  (try 'hg help --keyword foo')
  [255]

#endif

---

  $ cat > throw.py <<EOF
  > from mercurial import commands, registrar, util
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > class Bogon(Exception): pass
  > # NB: version should be bytes; simulating extension not ported to py3
  > __version__ = '1.0.0'
  > @command(b'throw', [], b'hg throw', norepo=True)
  > def throw(ui, **opts):
  >     """throws an exception"""
  >     raise Bogon()
  > EOF

Test extension without proper byteification of key attributes doesn't crash when
accessed.

  $ hg version -v --config extensions.throw=throw.py | grep '^ '
    throw  external  1.0.0

No declared supported version, extension complains:
  $ hg --config extensions.throw=throw.py throw 2>&1 | grep -E '^\*\*'
  ** Unknown exception encountered with possibly-broken third-party extension "throw" 1.0.0
  ** which supports versions unknown of Mercurial.
  ** Please disable "throw" and try your action again.
  ** If that fixes the bug please report it to the extension author.
  ** Python * (glob)
  ** Mercurial Distributed SCM * (glob)
  ** Extensions loaded: throw 1.0.0

empty declaration of supported version, extension complains (but doesn't choke if
the value is improperly a str instead of bytes):
  $ echo "testedwith = ''" >> throw.py
  $ hg --config extensions.throw=throw.py throw 2>&1 | grep -E '^\*\*'
  ** Unknown exception encountered with possibly-broken third-party extension "throw" 1.0.0
  ** which supports versions unknown of Mercurial.
  ** Please disable "throw" and try your action again.
  ** If that fixes the bug please report it to the extension author.
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: throw 1.0.0

If the extension specifies a buglink, show that (but don't choke if the value is
improperly a str instead of bytes):
  $ echo 'buglink = "http://example.com/bts"' >> throw.py
  $ rm -f throw.pyc throw.pyo
  $ rm -Rf __pycache__
  $ hg --config extensions.throw=throw.py throw 2>&1 | grep -E '^\*\*'
  ** Unknown exception encountered with possibly-broken third-party extension "throw" 1.0.0
  ** which supports versions unknown of Mercurial.
  ** Please disable "throw" and try your action again.
  ** If that fixes the bug please report it to http://example.com/bts
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: throw 1.0.0

If the extensions declare outdated versions, accuse the older extension first:
  $ echo "from mercurial import util" >> older.py
  $ echo "util.version = lambda:b'2.2'" >> older.py
  $ echo "testedwith = b'1.9.3'" >> older.py
  $ echo "testedwith = b'2.1.1'" >> throw.py
  $ rm -f throw.pyc throw.pyo
  $ rm -Rf __pycache__
  $ hg --config extensions.throw=throw.py --config extensions.older=older.py \
  >   throw 2>&1 | grep -E '^\*\*'
  ** Unknown exception encountered with possibly-broken third-party extension "older" (version N/A)
  ** which supports versions 1.9 of Mercurial.
  ** Please disable "older" and try your action again.
  ** If that fixes the bug please report it to the extension author.
  ** Python * (glob)
  ** Mercurial Distributed SCM (version 2.2)
  ** Extensions loaded: older, throw 1.0.0

One extension only tested with older, one only with newer versions:
  $ echo "util.version = lambda:b'2.1'" >> older.py
  $ rm -f older.pyc older.pyo
  $ rm -Rf __pycache__
  $ hg --config extensions.throw=throw.py --config extensions.older=older.py \
  >   throw 2>&1 | grep -E '^\*\*'
  ** Unknown exception encountered with possibly-broken third-party extension "older" (version N/A)
  ** which supports versions 1.9 of Mercurial.
  ** Please disable "older" and try your action again.
  ** If that fixes the bug please report it to the extension author.
  ** Python * (glob)
  ** Mercurial Distributed SCM (version 2.1)
  ** Extensions loaded: older, throw 1.0.0

Older extension is tested with current version, the other only with newer:
  $ echo "util.version = lambda:b'1.9.3'" >> older.py
  $ rm -f older.pyc older.pyo
  $ rm -Rf __pycache__
  $ hg --config extensions.throw=throw.py --config extensions.older=older.py \
  >   throw 2>&1 | grep -E '^\*\*'
  ** Unknown exception encountered with possibly-broken third-party extension "throw" 1.0.0
  ** which supports versions 2.1 of Mercurial.
  ** Please disable "throw" and try your action again.
  ** If that fixes the bug please report it to http://example.com/bts
  ** Python * (glob)
  ** Mercurial Distributed SCM (version 1.9.3)
  ** Extensions loaded: older, throw 1.0.0

Ability to point to a different point
  $ hg --config extensions.throw=throw.py --config extensions.older=older.py \
  >   --config ui.supportcontact='Your Local Goat Lenders' throw 2>&1 | grep -E '^\*\*'
  ** unknown exception encountered, please report by visiting
  ** Your Local Goat Lenders
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: older, throw 1.0.0

Declare the version as supporting this hg version, show regular bts link:
  $ hgver=`hg debuginstall -T '{hgver}'`
  $ echo 'testedwith = """'"$hgver"'"""' >> throw.py
  $ if [ -z "$hgver" ]; then
  >   echo "unable to fetch a mercurial version. Make sure __version__ is correct";
  > fi
  $ rm -f throw.pyc throw.pyo
  $ rm -Rf __pycache__
  $ hg --config extensions.throw=throw.py throw 2>&1 | grep -E '^\*\*'
  ** unknown exception encountered, please report by visiting
  ** https://mercurial-scm.org/wiki/BugTracker
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: throw 1.0.0

Patch version is ignored during compatibility check
  $ echo "testedwith = b'3.2'" >> throw.py
  $ echo "util.version = lambda:b'3.2.2'" >> throw.py
  $ rm -f throw.pyc throw.pyo
  $ rm -Rf __pycache__
  $ hg --config extensions.throw=throw.py throw 2>&1 | grep -E '^\*\*'
  ** unknown exception encountered, please report by visiting
  ** https://mercurial-scm.org/wiki/BugTracker
  ** Python * (glob)
  ** Mercurial Distributed SCM (*) (glob)
  ** Extensions loaded: throw 1.0.0

Test version number support in 'hg version':
  $ echo '__version__ = (1, 2, 3)' >> throw.py
  $ rm -f throw.pyc throw.pyo
  $ rm -Rf __pycache__
  $ hg version -v
  Mercurial Distributed SCM (version *) (glob)
  (see https://mercurial-scm.org for more information)
  
  Copyright (C) 2005-* Olivia Mackall and others (glob)
  This is free software; see the source for copying conditions. There is NO
  warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  
  Enabled extensions:
  

  $ hg version -v --config extensions.throw=throw.py
  Mercurial Distributed SCM (version *) (glob)
  (see https://mercurial-scm.org for more information)
  
  Copyright (C) 2005-* Olivia Mackall and others (glob)
  This is free software; see the source for copying conditions. There is NO
  warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  
  Enabled extensions:
  
    throw  external  1.2.3
  $ echo 'getversion = lambda: b"1.twentythree"' >> throw.py
  $ rm -f throw.pyc throw.pyo
  $ rm -Rf __pycache__
  $ hg version -v --config extensions.throw=throw.py --config extensions.strip=
  Mercurial Distributed SCM (version *) (glob)
  (see https://mercurial-scm.org for more information)
  
  Copyright (C) 2005-* Olivia Mackall and others (glob)
  This is free software; see the source for copying conditions. There is NO
  warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  
  Enabled extensions:
  
    strip  internal  
    throw  external  1.twentythree

  $ hg version -q --config extensions.throw=throw.py
  Mercurial Distributed SCM (version *) (glob)

Test template output:

  $ hg version --config extensions.strip= -T'{extensions}'
  strip

Test JSON output of version:

  $ hg version -Tjson
  [
   {
    "extensions": [],
    "ver": "*" (glob)
   }
  ]

  $ hg version --config extensions.throw=throw.py -Tjson
  [
   {
    "extensions": [{"bundled": false, "name": "throw", "ver": "1.twentythree"}],
    "ver": "3.2.2"
   }
  ]

  $ hg version --config extensions.strip= -Tjson
  [
   {
    "extensions": [{"bundled": true, "name": "strip", "ver": null}],
    "ver": "*" (glob)
   }
  ]

Test template output of version:

  $ hg version --config extensions.throw=throw.py --config extensions.strip= \
  > -T'{extensions % "{name}  {pad(ver, 16)}  ({if(bundled, "internal", "external")})\n"}'
  strip                    (internal)
  throw  1.twentythree     (external)

Refuse to load extensions with minimum version requirements

  $ cat > minversion1.py << EOF
  > from mercurial import util
  > util.version = lambda: b'3.5.2'
  > minimumhgversion = b'3.6'
  > EOF
  $ hg --config extensions.minversion=minversion1.py version
  (third party extension minversion requires version 3.6 or newer of Mercurial (current: 3.5.2); disabling)
  Mercurial Distributed SCM (version 3.5.2)
  (see https://mercurial-scm.org for more information)
  
  Copyright (C) 2005-* Olivia Mackall and others (glob)
  This is free software; see the source for copying conditions. There is NO
  warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  $ cat > minversion2.py << EOF
  > from mercurial import util
  > util.version = lambda: b'3.6'
  > minimumhgversion = b'3.7'
  > EOF
  $ hg --config extensions.minversion=minversion2.py version 2>&1 | grep -E '\(third'
  (third party extension minversion requires version 3.7 or newer of Mercurial (current: 3.6); disabling)

Can load version that is only off by point release

  $ cat > minversion2.py << EOF
  > from mercurial import util
  > util.version = lambda: b'3.6.1'
  > minimumhgversion = b'3.6'
  > EOF
  $ hg --config extensions.minversion=minversion3.py version 2>&1 | grep -E '\(third'
  [1]

Can load minimum version identical to current

  $ cat > minversion3.py << EOF
  > from mercurial import util
  > util.version = lambda: b'3.5'
  > minimumhgversion = b'3.5'
  > EOF
  $ hg --config extensions.minversion=minversion3.py version 2>&1 | grep -E '\(third'
  [1]

Don't explode on py3 with a bad version number (both str vs bytes, and not enough
parts)

  $ cat > minversion4.py << EOF
  > from mercurial import util
  > util.version = lambda: b'3.5'
  > minimumhgversion = '3'
  > EOF
  $ hg --config extensions.minversion=minversion4.py version -v
  Mercurial Distributed SCM (version 3.5)
  (see https://mercurial-scm.org for more information)
  
  Copyright (C) 2005-* Olivia Mackall and others (glob)
  This is free software; see the source for copying conditions. There is NO
  warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
  
  Enabled extensions:
  
    minversion  external  

Restore HGRCPATH

  $ HGRCPATH=$ORGHGRCPATH
  $ export HGRCPATH

Commands handling multiple repositories at a time should invoke only
"reposetup()" of extensions enabling in the target repository.

  $ mkdir reposetup-test
  $ cd reposetup-test

  $ cat > $TESTTMP/reposetuptest.py <<EOF
  > from mercurial import extensions
  > def reposetup(ui, repo):
  >     ui.write(b'reposetup() for %s\n' % (repo.root))
  >     ui.flush()
  > EOF
  $ hg init src
  $ echo a > src/a
  $ hg -R src commit -Am '#0 at src/a'
  adding a
  $ echo '[extensions]' >> src/.hg/hgrc
  $ echo '# enable extension locally' >> src/.hg/hgrc
  $ echo "reposetuptest = $TESTTMP/reposetuptest.py" >> src/.hg/hgrc
  $ hg -R src status
  reposetup() for $TESTTMP/reposetup-test/src
  reposetup() for $TESTTMP/reposetup-test/src (chg !)

#if no-extraextensions
  $ hg --cwd src debugextensions
  reposetup() for $TESTTMP/reposetup-test/src
  dodo (untested!)
  dudu (untested!)
  mq
  reposetuptest (untested!)
  strip
#endif

  $ hg clone -U src clone-dst1
  reposetup() for $TESTTMP/reposetup-test/src
  $ hg init push-dst1
  $ hg -q -R src push push-dst1
  reposetup() for $TESTTMP/reposetup-test/src
  $ hg init pull-src1
  $ hg -q -R pull-src1 pull src
  reposetup() for $TESTTMP/reposetup-test/src

  $ cat <<EOF >> $HGRCPATH
  > [extensions]
  > # disable extension globally and explicitly
  > reposetuptest = !
  > EOF
  $ hg clone -U src clone-dst2
  reposetup() for $TESTTMP/reposetup-test/src
  $ hg init push-dst2
  $ hg -q -R src push push-dst2
  reposetup() for $TESTTMP/reposetup-test/src
  $ hg init pull-src2
  $ hg -q -R pull-src2 pull src
  reposetup() for $TESTTMP/reposetup-test/src

  $ cat <<EOF >> $HGRCPATH
  > [extensions]
  > # enable extension globally
  > reposetuptest = $TESTTMP/reposetuptest.py
  > EOF
  $ hg clone -U src clone-dst3
  reposetup() for $TESTTMP/reposetup-test/src
  reposetup() for $TESTTMP/reposetup-test/clone-dst3
  $ hg init push-dst3
  reposetup() for $TESTTMP/reposetup-test/push-dst3
  $ hg -q -R src push push-dst3
  reposetup() for $TESTTMP/reposetup-test/src
  reposetup() for $TESTTMP/reposetup-test/push-dst3
  $ hg init pull-src3
  reposetup() for $TESTTMP/reposetup-test/pull-src3
  $ hg -q -R pull-src3 pull src
  reposetup() for $TESTTMP/reposetup-test/pull-src3
  reposetup() for $TESTTMP/reposetup-test/src

  $ echo '[extensions]' >> src/.hg/hgrc
  $ echo '# disable extension locally' >> src/.hg/hgrc
  $ echo 'reposetuptest = !' >> src/.hg/hgrc
  $ hg clone -U src clone-dst4
  reposetup() for $TESTTMP/reposetup-test/clone-dst4
  $ hg init push-dst4
  reposetup() for $TESTTMP/reposetup-test/push-dst4
  $ hg -q -R src push push-dst4
  reposetup() for $TESTTMP/reposetup-test/push-dst4
  $ hg init pull-src4
  reposetup() for $TESTTMP/reposetup-test/pull-src4
  $ hg -q -R pull-src4 pull src
  reposetup() for $TESTTMP/reposetup-test/pull-src4

disabling in command line overlays with all configuration
  $ hg --config extensions.reposetuptest=! clone -U src clone-dst5
  $ hg --config extensions.reposetuptest=! init push-dst5
  $ hg --config extensions.reposetuptest=! -q -R src push push-dst5
  $ hg --config extensions.reposetuptest=! init pull-src5
  $ hg --config extensions.reposetuptest=! -q -R pull-src5 pull src

  $ cat <<EOF >> $HGRCPATH
  > [extensions]
  > # disable extension globally and explicitly
  > reposetuptest = !
  > EOF
  $ hg init parent
  $ hg init parent/sub1
  $ echo 1 > parent/sub1/1
  $ hg -R parent/sub1 commit -Am '#0 at parent/sub1'
  adding 1
  $ hg init parent/sub2
  $ hg init parent/sub2/sub21
  $ echo 21 > parent/sub2/sub21/21
  $ hg -R parent/sub2/sub21 commit -Am '#0 at parent/sub2/sub21'
  adding 21
  $ cat > parent/sub2/.hgsub <<EOF
  > sub21 = sub21
  > EOF
  $ hg -R parent/sub2 commit -Am '#0 at parent/sub2'
  adding .hgsub
  $ hg init parent/sub3
  $ echo 3 > parent/sub3/3
  $ hg -R parent/sub3 commit -Am '#0 at parent/sub3'
  adding 3
  $ cat > parent/.hgsub <<EOF
  > sub1 = sub1
  > sub2 = sub2
  > sub3 = sub3
  > EOF
  $ hg -R parent commit -Am '#0 at parent'
  adding .hgsub
  $ echo '[extensions]' >> parent/.hg/hgrc
  $ echo '# enable extension locally' >> parent/.hg/hgrc
  $ echo "reposetuptest = $TESTTMP/reposetuptest.py" >> parent/.hg/hgrc
  $ cp parent/.hg/hgrc parent/sub2/.hg/hgrc
  $ hg -R parent status -S -A
  reposetup() for $TESTTMP/reposetup-test/parent
  reposetup() for $TESTTMP/reposetup-test/parent/sub2
  C .hgsub
  C .hgsubstate
  C sub1/1
  C sub2/.hgsub
  C sub2/.hgsubstate
  C sub2/sub21/21
  C sub3/3

  $ cd ..

Prohibit registration of commands that don't use @command (issue5137)

  $ hg init deprecated
  $ cd deprecated

  $ cat <<EOF > deprecatedcmd.py
  > def deprecatedcmd(repo, ui):
  >     pass
  > cmdtable = {
  >     b'deprecatedcmd': (deprecatedcmd, [], b''),
  > }
  > EOF
  $ cat <<EOF > .hg/hgrc
  > [extensions]
  > deprecatedcmd = `pwd`/deprecatedcmd.py
  > mq = !
  > hgext.mq = !
  > hgext/mq = !
  > EOF

  $ hg deprecatedcmd > /dev/null
  *** failed to import extension "deprecatedcmd" from $TESTTMP/deprecated/deprecatedcmd.py: missing attributes: norepo, optionalrepo, inferrepo
  *** (use @command decorator to register 'deprecatedcmd')
  hg: unknown command 'deprecatedcmd'
  (use 'hg help' for a list of commands)
  [10]

 the extension shouldn't be loaded at all so the mq works:

  $ hg qseries --config extensions.mq= > /dev/null
  *** failed to import extension "deprecatedcmd" from $TESTTMP/deprecated/deprecatedcmd.py: missing attributes: norepo, optionalrepo, inferrepo
  *** (use @command decorator to register 'deprecatedcmd')

  $ cd ..

Test synopsis and docstring extending

  $ hg init exthelp
  $ cat > exthelp.py <<EOF
  > from mercurial import commands, extensions
  > def exbookmarks(orig, *args, **opts):
  >     return orig(*args, **opts)
  > def uisetup(ui):
  >     synopsis = b' GREPME [--foo] [-x]'
  >     docstring = '\nGREPME make sure that this is in the help!'
  >     extensions.wrapcommand(commands.table, b'bookmarks', exbookmarks,
  >                            synopsis, docstring)
  > EOF
  $ abspath=`pwd`/exthelp.py
  $ echo '[extensions]' >> $HGRCPATH
  $ echo "exthelp = $abspath" >> $HGRCPATH
  $ cd exthelp
  $ hg help bookmarks | grep GREPME
  hg bookmarks [OPTIONS]... [NAME]... GREPME [--foo] [-x]
  GREPME make sure that this is in the help!
  $ cd ..

Prohibit the use of unicode strings as the default value of options

  $ hg init $TESTTMP/opt-unicode-default

  $ cat > $TESTTMP/test_unicode_default_value.py << EOF
  > from mercurial import registrar
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'dummy', [(b'', b'opt', u'value', u'help')], 'ext [OPTIONS]')
  > def ext(*args, **opts):
  >     print(opts[b'opt'], flush=True)
  > EOF
  $ cat > $TESTTMP/opt-unicode-default/.hg/hgrc << EOF
  > [extensions]
  > test_unicode_default_value = $TESTTMP/test_unicode_default_value.py
  > EOF
  $ hg -R $TESTTMP/opt-unicode-default dummy
  *** failed to import extension "test_unicode_default_value" from $TESTTMP/test_unicode_default_value.py: unicode 'value' found in cmdtable.dummy
  *** (use b'' to make it byte string)
  hg: unknown command 'dummy'
  (did you mean summary?)
  [10]

Check the mandatory extension feature
-------------------------------------

  $ hg init mandatory-extensions
  $ cat > $TESTTMP/mandatory-extensions/.hg/good.py << EOF
  > pass
  > EOF
  $ cat > $TESTTMP/mandatory-extensions/.hg/bad.py << EOF
  > raise RuntimeError("babar")
  > EOF
  $ cat > $TESTTMP/mandatory-extensions/.hg/syntax.py << EOF
  > def (
  > EOF

Check that the good one load :

  $ cat > $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > [extensions]
  > good = $TESTTMP/mandatory-extensions/.hg/good.py
  > EOF

  $ hg -R mandatory-extensions id
  000000000000 tip

Make it mandatory to load

  $ cat >> $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > good:required = yes
  > EOF

  $ hg -R mandatory-extensions id
  000000000000 tip

Check that the bad one does not load

  $ cat >> $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > bad = $TESTTMP/mandatory-extensions/.hg/bad.py
  > EOF

  $ hg -R mandatory-extensions id
  *** failed to import extension "bad" from $TESTTMP/mandatory-extensions/.hg/bad.py: babar
  000000000000 tip

Make it mandatory to load

  $ cat >> $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > bad:required = yes
  > EOF

  $ hg -R mandatory-extensions id
  abort: failed to import extension "bad" from $TESTTMP/mandatory-extensions/.hg/bad.py: babar
  (loading of this extension was required, see `hg help config.extensions` for details)
  [255]

Make it not mandatory to load

  $ cat >> $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > bad:required = no
  > EOF

  $ hg -R mandatory-extensions id
  *** failed to import extension "bad" from $TESTTMP/mandatory-extensions/.hg/bad.py: babar
  000000000000 tip

Same check with the syntax error one

  $ cat >> $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > bad = !
  > syntax = $TESTTMP/mandatory-extensions/.hg/syntax.py
  > syntax:required = yes
  > EOF

  $ hg -R mandatory-extensions id
  abort: failed to import extension "syntax" from $TESTTMP/mandatory-extensions/.hg/syntax.py: invalid syntax (*syntax.py, line 1) (glob)
  (loading of this extension was required, see `hg help config.extensions` for details)
  [255]

Same check with a missing one

  $ cat >> $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > syntax = !
  > syntax:required =
  > missing = foo/bar/baz/I/do/not/exist/
  > missing:required = yes
  > EOF

  $ hg -R mandatory-extensions id
  abort: failed to import extension "missing" from foo/bar/baz/I/do/not/exist/: [Errno 2] $ENOENT$: 'foo/bar/baz/I/do/not/exist'
  (loading of this extension was required, see `hg help config.extensions` for details)
  [255]

Have a "default" setting for the suboption:

  $ cat > $TESTTMP/mandatory-extensions/.hg/hgrc << EOF
  > [extensions]
  > bad = $TESTTMP/mandatory-extensions/.hg/bad.py
  > bad:required = no
  > good = $TESTTMP/mandatory-extensions/.hg/good.py
  > syntax = $TESTTMP/mandatory-extensions/.hg/syntax.py
  > *:required = yes
  > EOF

  $ hg -R mandatory-extensions id
  *** failed to import extension "bad" from $TESTTMP/mandatory-extensions/.hg/bad.py: babar
  abort: failed to import extension "syntax" from $TESTTMP/mandatory-extensions/.hg/syntax.py: invalid syntax (*syntax.py, line 1) (glob)
  (loading of this extension was required, see `hg help config.extensions` for details)
  [255]
