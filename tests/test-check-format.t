#require black test-repo

Black needs the real USERPROFILE in order to run on Windows
#if msys
  $ USERPROFILE="$REALUSERPROFILE"
  $ export USERPROFILE
#endif

  $ . "$TESTDIR/helpers-testrepo.sh"

  $ cd $RUNTESTDIR/..
  $ black --check --diff `testrepohg files 'set:(**.py + grep("^#!.*python")) - mercurial/thirdparty/**'`

