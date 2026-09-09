==============================
Test the debug::python command
==============================

These test live in their own files because they don't quite belong anywhere
else.


  $ hg debug::python -- -c "print('babar')"
  babar

  $ hg debug::python << EOF
  > if True:
  >    print("Babar is not dead")
  > EOF
  Babar is not dead

The mercurial we find should be the one we run

  $ py_version=`hg debug::python -- -c "from mercurial.__version__ import version; print(version)"`
  $ hg_version=`hg version --quiet -T '{ver}'`
  $ test "$py_version" = "$hg_version"
