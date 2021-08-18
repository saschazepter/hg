hg debuginstall
  $ hg debuginstall
  checking encoding (ascii)...
  checking Python executable (*) (glob)
  checking Python implementation (*) (glob)
  checking Python version (2.*) (glob) (no-py3 !)
  checking Python version (3.*) (glob) (py3 !)
  checking Python lib (.*[Ll]ib.*)... (re) (no-pyoxidizer !)
  checking Python lib (.*pyoxidizer.*)... (re) (pyoxidizer !)
  checking Python security support (*) (glob)
    TLS 1.2 not supported by Python install; network connections lack modern security (?)
    SNI not supported by Python install; may have connectivity issues with some servers (?)
  checking Rust extensions \((installed|missing)\) (re)
  checking Mercurial version (*) (glob)
  checking Mercurial custom build (*) (glob)
  checking module policy (*) (glob)
  checking installed modules (*mercurial)... (glob)
  checking registered compression engines (*zlib*) (glob)
  checking available compression engines (*zlib*) (glob)
  checking available compression engines for wire protocol (*zlib*) (glob)
  checking "re2" regexp engine \((available|missing)\) (re)
  checking templates (*mercurial?templates)... (glob) (no-pyoxidizer !)
  checking templates (*app?templates)... (glob) (pyoxidizer !)
  checking default template (*mercurial?templates?map-cmdline.default) (glob) (no-pyoxidizer !)
  checking default template (*app?templates?map-cmdline.default) (glob) (pyoxidizer !)
  checking commit editor... (*) (glob)
  checking username (test)
  no problems detected

hg debuginstall JSON
  $ hg debuginstall -Tjson | sed 's|\\\\|\\|g'
  [
   {
    "compengines": ["bz2", "bz2truncated", "none", "zlib"*], (glob)
    "compenginesavail": ["bz2", "bz2truncated", "none", "zlib"*], (glob)
    "compenginesserver": [*"zlib"*], (glob)
    "defaulttemplate": "*mercurial?templates?map-cmdline.default", (glob) (no-pyoxidizer !)
    "defaulttemplate": "*app?templates?map-cmdline.default", (glob) (pyoxidizer !)
    "defaulttemplateerror": null,
    "defaulttemplatenotfound": "default",
    "editor": "*", (glob)
    "editornotfound": false,
    "encoding": "ascii",
    "encodingerror": null,
    "extensionserror": null, (no-pure !)
    "hgmodulepolicy": "*", (glob)
    "hgmodules": "*mercurial", (glob)
    "hgver": "*", (glob)
    "hgverextra": "*", (glob)
    "problems": 0,
    "pythonexe": "*", (glob)
    "pythonimplementation": "*", (glob)
    "pythonlib": "*", (glob)
    "pythonsecurity": [*], (glob)
    "pythonver": "*.*.*", (glob)
    "re2": (true|false), (re)
    "templatedirs": "*mercurial?templates", (glob) (no-pyoxidizer !)
    "templatedirs": "*app?templates", (glob) (pyoxidizer !)
    "username": "test",
    "usernameerror": null,
    "vinotfound": false
   }
  ]

hg debuginstall with no username
  $ HGUSER= hg debuginstall
  checking encoding (ascii)...
  checking Python executable (*) (glob)
  checking Python implementation (*) (glob)
  checking Python version (2.*) (glob) (no-py3 !)
  checking Python version (3.*) (glob) (py3 !)
  checking Python lib (.*[Ll]ib.*)... (re) (no-pyoxidizer !)
  checking Python lib (.*pyoxidizer.*)... (re) (pyoxidizer !)
  checking Python security support (*) (glob)
    TLS 1.2 not supported by Python install; network connections lack modern security (?)
    SNI not supported by Python install; may have connectivity issues with some servers (?)
  checking Rust extensions \((installed|missing)\) (re)
  checking Mercurial version (*) (glob)
  checking Mercurial custom build (*) (glob)
  checking module policy (*) (glob)
  checking installed modules (*mercurial)... (glob)
  checking registered compression engines (*zlib*) (glob)
  checking available compression engines (*zlib*) (glob)
  checking available compression engines for wire protocol (*zlib*) (glob)
  checking "re2" regexp engine \((available|missing)\) (re)
  checking templates (*mercurial?templates)... (glob) (no-pyoxidizer !)
  checking templates (*app?templates)... (glob) (pyoxidizer !)
  checking default template (*mercurial?templates?map-cmdline.default) (glob) (no-pyoxidizer !)
  checking default template (*app?templates?map-cmdline.default) (glob) (pyoxidizer !)
  checking commit editor... (*) (glob)
  checking username...
   no username supplied
   (specify a username in your configuration file)
  1 problems detected, please check your install!
  [1]

hg debuginstall with invalid encoding
  $ HGENCODING=invalidenc hg debuginstall | grep encoding
  checking encoding (invalidenc)...
   unknown encoding: invalidenc

exception message in JSON

  $ HGENCODING=invalidenc HGUSER= hg debuginstall -Tjson | grep error
    "defaulttemplateerror": null,
    "encodingerror": "unknown encoding: invalidenc",
    "extensionserror": null, (no-pure !)
    "usernameerror": "no username supplied",

path variables are expanded (~ is the same as $TESTTMP)
  $ mkdir tools
  $ touch tools/testeditor.exe
#if execbit
  $ chmod 755 tools/testeditor.exe
#endif
  $ HGEDITOR="~/tools/testeditor.exe" hg debuginstall
  checking encoding (ascii)...
  checking Python executable (*) (glob)
  checking Python implementation (*) (glob)
  checking Python version (2.*) (glob) (no-py3 !)
  checking Python version (3.*) (glob) (py3 !)
  checking Python lib (.*[Ll]ib.*)... (re) (no-pyoxidizer !)
  checking Python lib (.*pyoxidizer.*)... (re) (pyoxidizer !)
  checking Python security support (*) (glob)
    TLS 1.2 not supported by Python install; network connections lack modern security (?)
    SNI not supported by Python install; may have connectivity issues with some servers (?)
  checking Rust extensions \((installed|missing)\) (re)
  checking Mercurial version (*) (glob)
  checking Mercurial custom build (*) (glob)
  checking module policy (*) (glob)
  checking installed modules (*mercurial)... (glob)
  checking registered compression engines (*zlib*) (glob)
  checking available compression engines (*zlib*) (glob)
  checking available compression engines for wire protocol (*zlib*) (glob)
  checking "re2" regexp engine \((available|missing)\) (re)
  checking templates (*mercurial?templates)... (glob) (no-pyoxidizer !)
  checking templates (*app?templates)... (glob) (pyoxidizer !)
  checking default template (*mercurial?templates?map-cmdline.default) (glob) (no-pyoxidizer !)
  checking default template (*app?templates?map-cmdline.default) (glob) (pyoxidizer !)
  checking commit editor... ($TESTTMP/tools/testeditor.exe)
  checking username (test)
  no problems detected

print out the binary post-shlexsplit in the error message when commit editor is
not found (this is intentionally using backslashes to mimic a windows usecase).
  $ HGEDITOR="c:\foo\bar\baz.exe -y -z" hg debuginstall
  checking encoding (ascii)...
  checking Python executable (*) (glob)
  checking Python implementation (*) (glob)
  checking Python version (2.*) (glob) (no-py3 !)
  checking Python version (3.*) (glob) (py3 !)
  checking Python lib (.*[Ll]ib.*)... (re) (no-pyoxidizer !)
  checking Python lib (.*pyoxidizer.*)... (re) (pyoxidizer !)
  checking Python security support (*) (glob)
    TLS 1.2 not supported by Python install; network connections lack modern security (?)
    SNI not supported by Python install; may have connectivity issues with some servers (?)
  checking Rust extensions \((installed|missing)\) (re)
  checking Mercurial version (*) (glob)
  checking Mercurial custom build (*) (glob)
  checking module policy (*) (glob)
  checking installed modules (*mercurial)... (glob)
  checking registered compression engines (*zlib*) (glob)
  checking available compression engines (*zlib*) (glob)
  checking available compression engines for wire protocol (*zlib*) (glob)
  checking "re2" regexp engine \((available|missing)\) (re)
  checking templates (*mercurial?templates)... (glob) (no-pyoxidizer !)
  checking templates (*app?templates)... (glob) (pyoxidizer !)
  checking default template (*mercurial?templates?map-cmdline.default) (glob) (no-pyoxidizer !)
  checking default template (*app?templates?map-cmdline.default) (glob) (pyoxidizer !)
  checking commit editor... (c:\foo\bar\baz.exe) (windows !)
   Can't find editor 'c:\foo\bar\baz.exe' in PATH (windows !)
  checking commit editor... (c:foobarbaz.exe) (no-windows !)
   Can't find editor 'c:foobarbaz.exe' in PATH (no-windows !)
   (specify a commit editor in your configuration file)
  checking username (test)
  1 problems detected, please check your install!
  [1]

debuginstall extension support
  $ hg debuginstall --config extensions.fsmonitor= --config fsmonitor.watchman_exe=false | grep atchman
  fsmonitor checking for watchman binary... (false)
   watchman binary missing or broken: warning: Watchman unavailable: watchman exited with code 1
Verify the json works too:
  $ hg debuginstall --config extensions.fsmonitor= --config fsmonitor.watchman_exe=false -Tjson | grep atchman
    "fsmonitor-watchman": "false",
    "fsmonitor-watchman-error": "warning: Watchman unavailable: watchman exited with code 1",

Verify that Mercurial is installable with pip. Note that this MUST be
the last test in this file, because we do some nasty things to the
shell environment in order to make the virtualenv work reliably.

On Python 3, we use the venv module, which is part of the standard library.
But some Linux distros strip out this module's functionality involving pip,
so we have to look for the ensurepip module, which these distros strip out
completely.
On Python 2, we use the 3rd party virtualenv module, if available.

  $ cd $TESTTMP
  $ unset PYTHONPATH

#if py3 ensurepip network-io no-pyoxidizer
  $ "$PYTHON" -m venv installenv >> pip.log

Hack: Debian does something a bit different in ensurepip.bootstrap. This makes
it so that pip thinks the 'wheel' wheel is installed so it can build wheels;
when it goes to try, however, it shells out to run `python3 -u <setup.py>`,
that *doesn't* get the 'wheel' wheel, and it fails with an invalid command
'bdist_wheel'. To fix this, we just delete the wheel from where Debian put it in
our virtual env. Then pip doesn't think it's installed and doesn't try to build.
  $ rm installenv/share/python-wheels/wheel-*.whl >/dev/null 2>&1 || true

Note: we use this weird path to run pip and hg to avoid platform differences,
since it's bin on most platforms but Scripts on Windows.
  $ ./installenv/*/pip install $TESTDIR/.. >> pip.log
    Failed building wheel for mercurial (?)
  WARNING: You are using pip version *; however, version * is available. (glob) (?)
  You should consider upgrading via the '$TESTTMP/installenv/bin/python* -m pip install --upgrade pip' command. (glob) (?)
  $ ./installenv/*/hg debuginstall || cat pip.log
  checking encoding (ascii)...
  checking Python executable (*) (glob)
  checking Python implementation (*) (glob)
  checking Python version (3.*) (glob)
  checking Python lib (*)... (glob)
  checking Python security support (*) (glob)
  checking Rust extensions \((installed|missing)\) (re)
  checking Mercurial version (*) (glob)
  checking Mercurial custom build (*) (glob)
  checking module policy (*) (glob)
  checking installed modules (*/mercurial)... (glob)
  checking registered compression engines (*) (glob)
  checking available compression engines (*) (glob)
  checking available compression engines for wire protocol (*) (glob)
  checking "re2" regexp engine \((available|missing)\) (re)
  checking templates ($TESTTMP/installenv/*/site-packages/mercurial/templates)... (glob)
  checking default template ($TESTTMP/installenv/*/site-packages/mercurial/templates/map-cmdline.default) (glob)
  checking commit editor... (*) (glob)
  checking username (test)
  no problems detected
#endif

#if virtualenv no-py3 network-io no-pyoxidizer

Note: --no-site-packages is the default for all versions enabled by hghave

  $ "$PYTHON" -m virtualenv installenv >> pip.log
  DEPRECATION: Python 2.7 will reach the end of its life on January 1st, 2020. Please upgrade your Python as Python 2.7 won't be maintained after that date. A future version of pip will drop support for Python 2.7. (?)
  DEPRECATION: Python 2.7 will reach the end of its life on January 1st, 2020. Please upgrade your Python as Python 2.7 won't be maintained after that date. A future version of pip will drop support for Python 2.7. More details about Python 2 support in pip, can be found at https://pip.pypa.io/en/latest/development/release-process/#python-2-support (?)

Note: we use this weird path to run pip and hg to avoid platform differences,
since it's bin on most platforms but Scripts on Windows.
  $ ./installenv/*/pip install $TESTDIR/.. >> pip.log
  DEPRECATION: Python 2.7 will reach the end of its life on January 1st, 2020. Please upgrade your Python as Python 2.7 won't be maintained after that date. A future version of pip will drop support for Python 2.7. (?)
  DEPRECATION: Python 2.7 will reach the end of its life on January 1st, 2020. Please upgrade your Python as Python 2.7 won't be maintained after that date. A future version of pip will drop support for Python 2.7. More details about Python 2 support in pip, can be found at https://pip.pypa.io/en/latest/development/release-process/#python-2-support (?)
  DEPRECATION: Python 2.7 reached the end of its life on January 1st, 2020. Please upgrade your Python as Python 2.7 is no longer maintained. pip 21.0 will drop support for Python 2.7 in January 2021. More details about Python 2 support in pip can be found at https://pip.pypa.io/en/latest/development/release-process/#python-2-support pip 21.0 will remove support for this functionality. (?)
  $ ./installenv/*/hg debuginstall || cat pip.log
  checking encoding (ascii)...
  checking Python executable (*) (glob)
  checking Python implementation (*) (glob)
  checking Python version (2.*) (glob)
  checking Python lib (*)... (glob)
  checking Python security support (*) (glob)
    TLS 1.2 not supported by Python install; network connections lack modern security (?)
    SNI not supported by Python install; may have connectivity issues with some servers (?)
  checking Rust extensions \((installed|missing)\) (re)
  checking Mercurial version (*) (glob)
  checking Mercurial custom build (*) (glob)
  checking module policy (*) (glob)
  checking installed modules (*/mercurial)... (glob)
  checking registered compression engines (*) (glob)
  checking available compression engines (*) (glob)
  checking available compression engines for wire protocol (*) (glob)
  checking "re2" regexp engine \((available|missing)\) (re)
  checking templates ($TESTTMP/installenv/*/site-packages/mercurial/templates)... (glob)
  checking default template ($TESTTMP/installenv/*/site-packages/mercurial/templates/map-cmdline.default) (glob)
  checking commit editor... (*) (glob)
  checking username (test)
  no problems detected
#endif
