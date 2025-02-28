
A script that implements uppercasing of specific lines in a file. This
approximates the behavior of code formatters well enough for our tests.

  $ hg init test-repo
  $ cd test-repo

  $ mkdir some
  $ mkdir some/dir
  $ cat > some/dir/uppercase.py <<EOF
  > #!$PYTHON
  > import re
  > import sys
  > from mercurial.utils import procutil
  > procutil.setbinary(sys.stdin)
  > procutil.setbinary(sys.stdout)
  > stdin = getattr(sys.stdin, 'buffer', sys.stdin)
  > stdout = getattr(sys.stdout, 'buffer', sys.stdout)
  > def format(text):
  >   return re.sub(b' +', b' ', text.upper())
  > stdout.write(format(stdin.read()))
  > EOF

  $ chmod +x some/dir/uppercase.py

#if windows
  $ cat > some/dir/uppercase.bat <<EOF
  > @echo off
  > "$PYTHON" "$TESTTMP/test-repo/some/dir/uppercase.py"
  > EOF
#else
  $ mv some/dir/uppercase.py some/dir/uppercase
#endif

  $ echo babar > babar.txt
  $ hg add babar.txt

Using absolute paths

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > fix =
  > [experimental]
  > evolution.createmarkers=True
  > evolution.allowunstable=True
  > [fix]
  > extra-bin-paths=$TESTTMP/test-repo/some/dir/
  > uppercase-whole-file:command=uppercase
  > uppercase-whole-file:pattern=set:**.txt
  > EOF

  $ hg fix --working-dir
  $ cat babar.txt
  BABAR

Using relative paths

  $ cat >> $HGRCPATH <<EOF
  > [fix]
  > extra-bin-paths=./some/dir/
  > EOF

  $ echo celeste > celeste.txt
  $ hg add celeste.txt
  $ hg fix --working-dir
  $ cat celeste.txt
  CELESTE
