Set up a repo

  $ cat <<EOF >> $HGRCPATH
  > [ui]
  > interactive = true
  > [extensions]
  > record =
  > EOF

  $ hg init a
  $ cd a

Select no files

  $ touch empty-rw
  $ hg add empty-rw

  $ hg record --config ui.interactive=false
  abort: running non-interactively, use commit instead
  [255]
  $ hg commit -i --config ui.interactive=false
  abort: running non-interactively
  [10]
  $ hg commit -i empty-rw<<EOF
  > n
  > EOF
  diff --git a/empty-rw b/empty-rw
  new file mode 100644
  abort: empty commit message
  [10]

  $ hg tip -p
  changeset:   -1:000000000000
  tag:         tip
  user:        
  date:        Thu Jan 01 00:00:00 1970 +0000
  
  

Select files but no hunks

  $ hg commit -i  empty-rw<<EOF
  > y
  > n
  > EOF
  diff --git a/empty-rw b/empty-rw
  new file mode 100644
  abort: empty commit message
  [10]

  $ hg tip -p
  changeset:   -1:000000000000
  tag:         tip
  user:        
  date:        Thu Jan 01 00:00:00 1970 +0000
  
  

Abort for untracked

  $ touch untracked
  $ hg commit -i -m should-fail empty-rw untracked
  abort: untracked: file not tracked!
  [10]
  $ rm untracked

Record empty file

  $ hg commit -i -d '0 0' -m empty empty-rw<<EOF
  > y
  > EOF
  diff --git a/empty-rw b/empty-rw
  new file mode 100644

  $ hg tip -p
  changeset:   0:c0708cf4e46e
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     empty
  
  

Summary shows we updated to the new cset

  $ hg summary
  parent: 0:c0708cf4e46e tip
   empty
  branch: default
  commit: (clean)
  update: (current)
  phases: 1 draft

Rename empty file

  $ hg mv empty-rw empty-rename
  $ hg commit -i -d '1 0' -m rename<<EOF
  > y
  > EOF
  diff --git a/empty-rw b/empty-rename
  rename from empty-rw
  rename to empty-rename
  examine changes to 'empty-rw' and 'empty-rename'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   1:d695e8dcb197
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     rename
  
  

Copy empty file

  $ hg cp empty-rename empty-copy
  $ hg commit -i -d '2 0' -m copy<<EOF
  > y
  > EOF
  diff --git a/empty-rename b/empty-copy
  copy from empty-rename
  copy to empty-copy
  examine changes to 'empty-rename' and 'empty-copy'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   2:1d4b90bea524
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:02 1970 +0000
  summary:     copy
  
  

Delete empty file

  $ hg rm empty-copy
  $ hg commit -i -d '3 0' -m delete<<EOF
  > y
  > EOF
  diff --git a/empty-copy b/empty-copy
  deleted file mode 100644
  examine changes to 'empty-copy'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   3:b39a238f01a1
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:03 1970 +0000
  summary:     delete
  
  

Add binary file

  $ hg bundle --type v1 --base -2 tip.bundle
  1 changesets found
  $ hg add tip.bundle
  $ hg commit -i -d '4 0' -m binary<<EOF
  > y
  > EOF
  diff --git a/tip.bundle b/tip.bundle
  new file mode 100644
  this is a binary file
  examine changes to 'tip.bundle'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   4:ad816da3711e
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     binary
  
  diff -r b39a238f01a1 -r ad816da3711e tip.bundle
  Binary file tip.bundle has changed
  

Change binary file

  $ hg bundle --base -2 --type v1 tip.bundle
  1 changesets found
  $ hg commit -i -d '5 0' -m binary-change<<EOF
  > y
  > EOF
  diff --git a/tip.bundle b/tip.bundle
  this modifies a binary file (all or nothing)
  examine changes to 'tip.bundle'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   5:dccd6f3eb485
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:05 1970 +0000
  summary:     binary-change
  
  diff -r ad816da3711e -r dccd6f3eb485 tip.bundle
  Binary file tip.bundle has changed
  

Rename and change binary file

  $ hg mv tip.bundle top.bundle
  $ hg bundle --base -2 --type v1 top.bundle
  1 changesets found
  $ hg commit -i -d '6 0' -m binary-change-rename<<EOF
  > y
  > EOF
  diff --git a/tip.bundle b/top.bundle
  rename from tip.bundle
  rename to top.bundle
  this modifies a binary file (all or nothing)
  examine changes to 'tip.bundle' and 'top.bundle'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   6:7fa44105f5b3
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     binary-change-rename
  
  diff -r dccd6f3eb485 -r 7fa44105f5b3 tip.bundle
  Binary file tip.bundle has changed
  diff -r dccd6f3eb485 -r 7fa44105f5b3 top.bundle
  Binary file top.bundle has changed
  

Add plain file

  $ for i in 1 2 3 4 5 6 7 8 9 10; do
  >     echo $i >> plain
  > done

  $ hg add plain
  $ hg commit -i -d '7 0' -m plain plain<<EOF
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  new file mode 100644
  @@ -0,0 +1,10 @@
  +1
  +2
  +3
  +4
  +5
  +6
  +7
  +8
  +9
  +10
  record this change to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  
  $ hg tip -p
  changeset:   7:11fb457c1be4
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:07 1970 +0000
  summary:     plain
  
  diff -r 7fa44105f5b3 -r 11fb457c1be4 plain
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/plain	Thu Jan 01 00:00:07 1970 +0000
  @@ -0,0 +1,10 @@
  +1
  +2
  +3
  +4
  +5
  +6
  +7
  +8
  +9
  +10
  
Modify end of plain file with username unset

  $ echo 11 >> plain
  $ unset HGUSER
  $ hg commit -i --config ui.username= -d '8 0' -m end plain
  abort: no username supplied
  (use 'hg config --edit' to set your username)
  [255]


Modify end of plain file, also test that diffopts are accounted for

  $ HGUSER="test"
  $ export HGUSER
  $ hg commit -i --config diff.showfunc=true -d '8 0' -m end plain <<EOF
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  1 hunks, 1 lines changed
  @@ -8,3 +8,4 @@
   8
   9
   10
  +11
  record this change to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  

Modify end of plain file, no EOL

  $ hg tip --template '{node}' >> plain
  $ hg commit -i -d '9 0' -m noeol plain <<EOF
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  1 hunks, 1 lines changed
  @@ -9,3 +9,4 @@
   9
   10
   11
  +7264f99c5f5ff3261504828afa4fb4d406c3af54
  \ No newline at end of file
  record this change to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  

Record showfunc should preserve function across sections

  $ cat > f1.py <<NO_CHECK_EOF
  > def annotate(ui, repo, *pats, **opts):
  >     """show changeset information by line for each file
  > 
  >     List changes in files, showing the revision id responsible for
  >     each line.
  > 
  >     This command is useful for discovering when a change was made and
  >     by whom.
  > 
  >     If you include -f/-u/-d, the revision number is suppressed unless
  >     you also include -the revision number is suppressed unless
  >     you also include -n.
  > 
  >     Without the -a/--text option, annotate will avoid processing files
  >     it detects as binary. With -a, annotate will annotate the file
  >     anyway, although the results will probably be neither useful
  >     nor desirable.
  > 
  >     Returns 0 on success.
  >     """
  >     return 0
  > def archive(ui, repo, dest, **opts):
  >     '''create an unversioned archive of a repository revision
  > 
  >     By default, the revision used is the parent of the working
  >     directory; use -r/--rev to specify a different revision.
  > 
  >     The archive type is automatically detected based on file
  >     extension (to override, use -t/--type).
  > 
  >     .. container:: verbose
  > 
  >     Valid types are:
  > NO_CHECK_EOF
  $ hg add f1.py
  $ hg commit -m funcs
  $ cat > f1.py <<NO_CHECK_EOF
  > def annotate(ui, repo, *pats, **opts):
  >     """show changeset information by line for each file
  > 
  >     List changes in files, showing the revision id responsible for
  >     each line
  > 
  >     This command is useful for discovering when a change was made and
  >     by whom.
  > 
  >     Without the -a/--text option, annotate will avoid processing files
  >     it detects as binary. With -a, annotate will annotate the file
  >     anyway, although the results will probably be neither useful
  >     nor desirable.
  > 
  >     Returns 0 on success.
  >     """
  >     return 0
  > def archive(ui, repo, dest, **opts):
  >     '''create an unversioned archive of a repository revision
  > 
  >     By default, the revision used is the parent of the working
  >     directory; use -r/--rev to specify a different revision.
  > 
  >     The archive type is automatically detected based on file
  >     extension (or override using -t/--type).
  > 
  >     .. container:: verbose
  > 
  >     Valid types are:
  > NO_CHECK_EOF
  $ hg commit -i -m interactive <<EOF
  > y
  > y
  > y
  > y
  > EOF
  diff --git a/f1.py b/f1.py
  3 hunks, 6 lines changed
  examine changes to 'f1.py'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -2,8 +2,8 @@ def annotate(ui, repo, *pats, **opts):
       """show changeset information by line for each file
   
       List changes in files, showing the revision id responsible for
  -    each line.
  +    each line
   
       This command is useful for discovering when a change was made and
       by whom.
   
  record change 1/3 to 'f1.py'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -6,11 +6,7 @@ def annotate(ui, repo, *pats, **opts):
   
       This command is useful for discovering when a change was made and
       by whom.
   
  -    If you include -f/-u/-d, the revision number is suppressed unless
  -    you also include -the revision number is suppressed unless
  -    you also include -n.
  -
       Without the -a/--text option, annotate will avoid processing files
       it detects as binary. With -a, annotate will annotate the file
       anyway, although the results will probably be neither useful
  record change 2/3 to 'f1.py'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -26,7 +22,7 @@ def archive(ui, repo, dest, **opts):
       directory; use -r/--rev to specify a different revision.
   
       The archive type is automatically detected based on file
  -    extension (to override, use -t/--type).
  +    extension (or override using -t/--type).
   
       .. container:: verbose
   
  record change 3/3 to 'f1.py'?
  (enter ? for help) [Ynesfdaq?] y
  

Modify end of plain file, add EOL

  $ echo >> plain
  $ echo 1 > plain2
  $ hg add plain2
  $ hg commit -i -d '10 0' -m eol plain plain2 <<EOF
  > y
  > y
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  1 hunks, 1 lines changed
  @@ -9,4 +9,4 @@
   9
   10
   11
  -7264f99c5f5ff3261504828afa4fb4d406c3af54
  \ No newline at end of file
  +7264f99c5f5ff3261504828afa4fb4d406c3af54
  record change 1/2 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  
  diff --git a/plain2 b/plain2
  new file mode 100644
  @@ -0,0 +1,1 @@
  +1
  record change 2/2 to 'plain2'?
  (enter ? for help) [Ynesfdaq?] y
  
Modify beginning, trim end, record both, add another file to test
changes numbering

  $ rm plain
  $ for i in 2 2 3 4 5 6 7 8 9 10; do
  >   echo $i >> plain
  > done
  $ echo 2 >> plain2

  $ hg commit -i -d '10 0' -m begin-and-end plain plain2 <<EOF
  > y
  > y
  > y
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  2 hunks, 3 lines changed
  @@ -1,4 +1,4 @@
  -1
  +2
   2
   3
   4
  record change 1/3 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -8,5 +8,3 @@
   8
   9
   10
  -11
  -7264f99c5f5ff3261504828afa4fb4d406c3af54
  record change 2/3 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  
  diff --git a/plain2 b/plain2
  1 hunks, 1 lines changed
  @@ -1,1 +1,2 @@
   1
  +2
  record change 3/3 to 'plain2'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   13:f941910cff62
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:10 1970 +0000
  summary:     begin-and-end
  
  diff -r 33abe24d946c -r f941910cff62 plain
  --- a/plain	Thu Jan 01 00:00:10 1970 +0000
  +++ b/plain	Thu Jan 01 00:00:10 1970 +0000
  @@ -1,4 +1,4 @@
  -1
  +2
   2
   3
   4
  @@ -8,5 +8,3 @@
   8
   9
   10
  -11
  -7264f99c5f5ff3261504828afa4fb4d406c3af54
  diff -r 33abe24d946c -r f941910cff62 plain2
  --- a/plain2	Thu Jan 01 00:00:10 1970 +0000
  +++ b/plain2	Thu Jan 01 00:00:10 1970 +0000
  @@ -1,1 +1,2 @@
   1
  +2
  

Trim beginning, modify end

  $ rm plain
  > for i in 4 5 6 7 8 9 10.new; do
  >   echo $i >> plain
  > done

Record end

  $ hg commit -i -d '11 0' -m end-only plain <<EOF
  > n
  > y
  > EOF
  diff --git a/plain b/plain
  2 hunks, 4 lines changed
  @@ -1,9 +1,6 @@
  -2
  -2
  -3
   4
   5
   6
   7
   8
   9
  record change 1/2 to 'plain'?
  (enter ? for help) [Ynesfdaq?] n
  
  @@ -4,7 +1,7 @@
   4
   5
   6
   7
   8
   9
  -10
  +10.new
  record change 2/2 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   14:4915f538659b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:11 1970 +0000
  summary:     end-only
  
  diff -r f941910cff62 -r 4915f538659b plain
  --- a/plain	Thu Jan 01 00:00:10 1970 +0000
  +++ b/plain	Thu Jan 01 00:00:11 1970 +0000
  @@ -7,4 +7,4 @@
   7
   8
   9
  -10
  +10.new
  

Record beginning

  $ hg commit -i -d '12 0' -m begin-only plain <<EOF
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  1 hunks, 3 lines changed
  @@ -1,6 +1,3 @@
  -2
  -2
  -3
   4
   5
   6
  record this change to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   15:1b1f93d4b94b
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:12 1970 +0000
  summary:     begin-only
  
  diff -r 4915f538659b -r 1b1f93d4b94b plain
  --- a/plain	Thu Jan 01 00:00:11 1970 +0000
  +++ b/plain	Thu Jan 01 00:00:12 1970 +0000
  @@ -1,6 +1,3 @@
  -2
  -2
  -3
   4
   5
   6
  

Add to beginning, trim from end

  $ rm plain
  $ for i in 1 2 3 4 5 6 7 8 9; do
  >  echo $i >> plain
  > done

Record end

  $ hg commit -i --traceback -d '13 0' -m end-again plain<<EOF
  > n
  > y
  > EOF
  diff --git a/plain b/plain
  2 hunks, 4 lines changed
  @@ -1,6 +1,9 @@
  +1
  +2
  +3
   4
   5
   6
   7
   8
   9
  record change 1/2 to 'plain'?
  (enter ? for help) [Ynesfdaq?] n
  
  @@ -1,7 +4,6 @@
   4
   5
   6
   7
   8
   9
  -10.new
  record change 2/2 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  

Add to beginning, middle, end

  $ rm plain
  $ for i in 1 2 3 4 5 5.new 5.reallynew 6 7 8 9 10 11; do
  >   echo $i >> plain
  > done

Record beginning, middle, and test that format-breaking diffopts are ignored

  $ hg commit -i --config diff.noprefix=True -d '14 0' -m middle-only plain <<EOF
  > y
  > y
  > n
  > EOF
  diff --git a/plain b/plain
  3 hunks, 7 lines changed
  @@ -1,2 +1,5 @@
  +1
  +2
  +3
   4
   5
  record change 1/3 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,6 +4,8 @@
   4
   5
  +5.new
  +5.reallynew
   6
   7
   8
   9
  record change 2/3 to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -3,4 +8,6 @@
   6
   7
   8
   9
  +10
  +11
  record change 3/3 to 'plain'?
  (enter ? for help) [Ynesfdaq?] n
  

  $ hg tip -p
  changeset:   17:41cf3f5c55ae
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:14 1970 +0000
  summary:     middle-only
  
  diff -r a69d252246e1 -r 41cf3f5c55ae plain
  --- a/plain	Thu Jan 01 00:00:13 1970 +0000
  +++ b/plain	Thu Jan 01 00:00:14 1970 +0000
  @@ -1,5 +1,10 @@
  +1
  +2
  +3
   4
   5
  +5.new
  +5.reallynew
   6
   7
   8
  

Record end

  $ hg commit -i -d '15 0' -m end-only plain <<EOF
  > y
  > y
  > EOF
  diff --git a/plain b/plain
  1 hunks, 2 lines changed
  @@ -9,3 +9,5 @@
   7
   8
   9
  +10
  +11
  record this change to 'plain'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   18:58a72f46bc24
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:15 1970 +0000
  summary:     end-only
  
  diff -r 41cf3f5c55ae -r 58a72f46bc24 plain
  --- a/plain	Thu Jan 01 00:00:14 1970 +0000
  +++ b/plain	Thu Jan 01 00:00:15 1970 +0000
  @@ -9,3 +9,5 @@
   7
   8
   9
  +10
  +11
  
Interactive commit can name a directory instead of files (issue6131)

  $ mkdir subdir
  $ echo a > subdir/a
  $ hg ci -d '16 0' -i subdir -Amsubdir <<EOF
  > y
  > y
  > EOF
  adding subdir/a
  diff --git a/subdir/a b/subdir/a
  new file mode 100644
  examine changes to 'subdir/a'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -0,0 +1,1 @@
  +a
  record this change to 'subdir/a'?
  (enter ? for help) [Ynesfdaq?] y
  
  $ cd subdir

  $ echo a >> a
  $ hg commit -i -d '16 0' -m subdir-change a <<EOF
  > y
  > y
  > EOF
  diff --git a/subdir/a b/subdir/a
  1 hunks, 1 lines changed
  @@ -1,1 +1,2 @@
   a
  +a
  record this change to 'subdir/a'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip -p
  changeset:   20:e0f6b99f6c49
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:16 1970 +0000
  summary:     subdir-change
  
  diff -r abd26b51de37 -r e0f6b99f6c49 subdir/a
  --- a/subdir/a	Thu Jan 01 00:00:16 1970 +0000
  +++ b/subdir/a	Thu Jan 01 00:00:16 1970 +0000
  @@ -1,1 +1,2 @@
   a
  +a
  

  $ echo a > f1
  $ echo b > f2
  $ hg add f1 f2

  $ hg ci -mz -d '17 0'

  $ echo a >> f1
  $ echo b >> f2

Help, quit

  $ hg commit -i <<EOF
  > ?
  > q
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] ?
  
  y - yes, record this change
  n - no, skip this change
  e - edit this change manually
  s - skip remaining changes to this file
  f - record remaining changes to this file
  d - done, skip remaining changes and files
  a - record all changes to all remaining files
  q - quit, recording no changes
  ? - ? (display help)
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] q
  
  abort: user quit
  [250]

Patterns

  $ hg commit -i 'glob:f*' << EOF
  > y
  > n
  > y
  > n
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,1 +1,2 @@
   a
  +a
  record change 1/2 to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] n
  
  diff --git a/subdir/f2 b/subdir/f2
  1 hunks, 1 lines changed
  examine changes to 'subdir/f2'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,1 +1,2 @@
   b
  +b
  record change 2/2 to 'subdir/f2'?
  (enter ? for help) [Ynesfdaq?] n
  
  no changes to record
  [1]

#if gettext

Test translated help message

str.lower() instead of encoding.lower(str) on translated message might
make message meaningless, because some encoding uses 0x41(A) - 0x5a(Z)
as the second or later byte of multi-byte character.

For example, "\x8bL\x98^" (translation of "record" in ja_JP.cp932)
contains 0x4c (L). str.lower() replaces 0x4c(L) by 0x6c(l) and this
replacement makes message meaningless.

This tests that translated help message is lower()-ed correctly.

  $ LANGUAGE=ja
  $ export LANGUAGE

  $ cat > $TESTTMP/escape.py <<EOF
  > from mercurial import (
  >     pycompat,
  > )
  > from mercurial.utils import (
  >     procutil,
  > )
  > def escape(c):
  >     o = ord(c)
  >     if o < 0x80:
  >         return c
  >     else:
  >         return br'\x%02x' % o # escape char setting MSB
  > for l in procutil.stdin:
  >     procutil.stdout.write(
  >         b''.join(escape(c) for c in pycompat.iterbytestr(l)))
  > EOF

  $ hg commit -i --encoding cp932 2>&1 <<EOF | "$PYTHON" $TESTTMP/escape.py | grep '^y - '
  > ?
  > q
  > EOF
  y - \x82\xb1\x82\xcc\x95\xcf\x8dX\x82\xf0\x8bL\x98^(yes)

  $ LANGUAGE=
#endif

Skip

  $ hg commit -i <<EOF
  > s
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] s
  
  diff --git a/subdir/f2 b/subdir/f2
  1 hunks, 1 lines changed
  examine changes to 'subdir/f2'?
  (enter ? for help) [Ynesfdaq?] abort: response expected
  [255]

No

  $ hg commit -i <<EOF
  > n
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] n
  
  diff --git a/subdir/f2 b/subdir/f2
  1 hunks, 1 lines changed
  examine changes to 'subdir/f2'?
  (enter ? for help) [Ynesfdaq?] abort: response expected
  [255]

f, quit

  $ hg commit -i <<EOF
  > f
  > q
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] f
  
  diff --git a/subdir/f2 b/subdir/f2
  1 hunks, 1 lines changed
  examine changes to 'subdir/f2'?
  (enter ? for help) [Ynesfdaq?] q
  
  abort: user quit
  [250]

s, all

  $ hg commit -i -d '18 0' -mx <<EOF
  > s
  > a
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] s
  
  diff --git a/subdir/f2 b/subdir/f2
  1 hunks, 1 lines changed
  examine changes to 'subdir/f2'?
  (enter ? for help) [Ynesfdaq?] a
  

  $ hg tip -p
  changeset:   22:6afbbefacf35
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:18 1970 +0000
  summary:     x
  
  diff -r b73c401c693c -r 6afbbefacf35 subdir/f2
  --- a/subdir/f2	Thu Jan 01 00:00:17 1970 +0000
  +++ b/subdir/f2	Thu Jan 01 00:00:18 1970 +0000
  @@ -1,1 +1,2 @@
   b
  +b
  

f

  $ hg commit -i -d '19 0' -my <<EOF
  > f
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] f
  

  $ hg tip -p
  changeset:   23:715028a33949
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:19 1970 +0000
  summary:     y
  
  diff -r 6afbbefacf35 -r 715028a33949 subdir/f1
  --- a/subdir/f1	Thu Jan 01 00:00:18 1970 +0000
  +++ b/subdir/f1	Thu Jan 01 00:00:19 1970 +0000
  @@ -1,1 +1,2 @@
   a
  +a
  

#if execbit

Preserve chmod +x

  $ chmod +x f1
  $ echo a >> f1
  $ hg commit -i -d '20 0' -mz <<EOF
  > y
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  old mode 100644
  new mode 100755
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,2 +1,3 @@
   a
   a
  +a
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip --config diff.git=True -p
  changeset:   24:db967c1e5884
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:20 1970 +0000
  summary:     z
  
  diff --git a/subdir/f1 b/subdir/f1
  old mode 100644
  new mode 100755
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -1,2 +1,3 @@
   a
   a
  +a
  

Preserve execute permission on original

  $ echo b >> f1
  $ hg commit -i -d '21 0' -maa <<EOF
  > y
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,4 @@
   a
   a
   a
  +b
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip --config diff.git=True -p
  changeset:   25:88903aef81c3
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:21 1970 +0000
  summary:     aa
  
  diff --git a/subdir/f1 b/subdir/f1
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -1,3 +1,4 @@
   a
   a
   a
  +b
  

Preserve chmod -x

  $ chmod -x f1
  $ echo c >> f1
  $ hg commit -i -d '22 0' -mab <<EOF
  > y
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  old mode 100755
  new mode 100644
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -2,3 +2,4 @@ a
   a
   a
   b
  +c
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip --config diff.git=True -p
  changeset:   26:7af84b6cf560
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:22 1970 +0000
  summary:     ab
  
  diff --git a/subdir/f1 b/subdir/f1
  old mode 100755
  new mode 100644
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -2,3 +2,4 @@
   a
   a
   b
  +c
  

#else

Slightly bogus tests to get almost same repo structure as when x bit is used
- but with different hashes.

Mock "Preserve chmod +x"

  $ echo a >> f1
  $ hg commit -i -d '20 0' -mz <<EOF
  > y
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,2 +1,3 @@
   a
   a
  +a
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip --config diff.git=True -p
  changeset:   24:c26cfe2c4eb0
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:20 1970 +0000
  summary:     z
  
  diff --git a/subdir/f1 b/subdir/f1
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -1,2 +1,3 @@
   a
   a
  +a
  

Mock "Preserve execute permission on original"

  $ echo b >> f1
  $ hg commit -i -d '21 0' -maa <<EOF
  > y
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,4 @@
   a
   a
   a
  +b
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip --config diff.git=True -p
  changeset:   25:a48d2d60adde
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:21 1970 +0000
  summary:     aa
  
  diff --git a/subdir/f1 b/subdir/f1
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -1,3 +1,4 @@
   a
   a
   a
  +b
  

Mock "Preserve chmod -x"

  $ chmod -x f1
  $ echo c >> f1
  $ hg commit -i -d '22 0' -mab <<EOF
  > y
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -2,3 +2,4 @@ a
   a
   a
   b
  +c
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg tip --config diff.git=True -p
  changeset:   26:5cc89ae210fa
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:22 1970 +0000
  summary:     ab
  
  diff --git a/subdir/f1 b/subdir/f1
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -2,3 +2,4 @@
   a
   a
   b
  +c
  

#endif

  $ cd ..


Abort early when a merge is in progress

  $ hg up 4
  1 files updated, 0 files merged, 7 files removed, 0 files unresolved

  $ touch iwillmergethat
  $ hg add iwillmergethat

  $ hg branch thatbranch
  marked working directory as branch thatbranch
  (branches are permanent and global, did you want a bookmark?)

  $ hg ci -m'new head'

  $ hg up default
  7 files updated, 0 files merged, 2 files removed, 0 files unresolved

  $ hg merge thatbranch
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)

  $ hg commit -i -m'will abort'
  abort: cannot partially commit a merge (use "hg commit" instead)
  [10]

  $ hg up -C
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved

Editing patch (and ignoring trailing text)

  $ cat > editor.sh << '__EOF__'
  > sed -e 7d -e '5s/^-/ /' -e '/^# ---/i\
  > trailing\nditto' "$1" > tmp
  > mv tmp "$1"
  > __EOF__
  $ cat > editedfile << '__EOF__'
  > This is the first line
  > This is the second line
  > This is the third line
  > __EOF__
  $ hg add editedfile
  $ hg commit -medit-patch-1
  $ cat > editedfile << '__EOF__'
  > This line has changed
  > This change will be committed
  > This is the third line
  > __EOF__
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg commit -i -d '23 0' -medit-patch-2 <<EOF
  > y
  > e
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 2 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
  -This is the first line
  -This is the second line
  +This line has changed
  +This change will be committed
   This is the third line
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  $ cat editedfile
  This line has changed
  This change will be committed
  This is the third line
  $ hg cat -r tip editedfile
  This is the first line
  This change will be committed
  This is the third line
  $ hg revert editedfile

Trying to edit patch for whole file

  $ echo "This is the fourth line" >> editedfile
  $ hg commit -i <<EOF
  > e
  > q
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 1 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  cannot edit patch for whole file
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] q
  
  abort: user quit
  [250]
  $ hg revert editedfile

Removing changes from patch

  $ sed -e '3s/third/second/' -e '2s/will/will not/' -e 1d editedfile > tmp
  $ mv tmp editedfile
  $ echo "This line has been added" >> editedfile
  $ cat > editor.sh << '__EOF__'
  > sed -e 's/^[-+]/ /' "$1" > tmp
  > mv tmp "$1"
  > __EOF__
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg commit -i <<EOF
  > y
  > e
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 3 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
  -This is the first line
  -This change will be committed
  -This is the third line
  +This change will not be committed
  +This is the second line
  +This line has been added
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  no changes to record
  [1]
  $ cat editedfile
  This change will not be committed
  This is the second line
  This line has been added
  $ hg cat -r tip editedfile
  This is the first line
  This change will be committed
  This is the third line
  $ hg revert editedfile

Invalid patch

  $ sed -e '3s/third/second/' -e '2s/will/will not/' -e 1d editedfile > tmp
  $ mv tmp editedfile
  $ echo "This line has been added" >> editedfile
  $ cat > editor.sh << '__EOF__'
  > sed s/This/That/ "$1" > tmp
  > mv tmp "$1"
  > __EOF__
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg commit -i <<EOF
  > y
  > e
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 3 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
  -This is the first line
  -This change will be committed
  -This is the third line
  +This change will not be committed
  +This is the second line
  +This line has been added
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  patching file editedfile
  Hunk #1 FAILED at 0
  1 out of 1 hunks FAILED -- saving rejects to file editedfile.rej
  abort: patch failed to apply
  [20]
  $ cat editedfile
  This change will not be committed
  This is the second line
  This line has been added
  $ hg cat -r tip editedfile
  This is the first line
  This change will be committed
  This is the third line
  $ cat editedfile.rej
  --- editedfile
  +++ editedfile
  @@ -1,3 +1,3 @@
  -That is the first line
  -That change will be committed
  -That is the third line
  +That change will not be committed
  +That is the second line
  +That line has been added

Malformed patch - error handling

  $ cat > editor.sh << '__EOF__'
  > sed -e '/^@/p' "$1" > tmp
  > mv tmp "$1"
  > __EOF__
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg commit -i <<EOF
  > y
  > e
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 3 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
  -This is the first line
  -This change will be committed
  -This is the third line
  +This change will not be committed
  +This is the second line
  +This line has been added
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  abort: error parsing patch: unhandled transition: range -> range
  [10]

Exiting editor with status 1, ignores the edit but does not stop the recording
session

  $ HGEDITOR=false hg commit -i <<EOF
  > y
  > e
  > n
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 3 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
  -This is the first line
  -This change will be committed
  -This is the third line
  +This change will not be committed
  +This is the second line
  +This line has been added
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  editor exited with exit code 1
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] n
  
  no changes to record
  [1]


random text in random positions is still an error

  $ cat > editor.sh << '__EOF__'
  > sed -e '/^@/i\
  > other' "$1" > tmp
  > mv tmp "$1"
  > __EOF__
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg commit -i <<EOF
  > y
  > e
  > EOF
  diff --git a/editedfile b/editedfile
  1 hunks, 3 lines changed
  examine changes to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,3 @@
  -This is the first line
  -This change will be committed
  -This is the third line
  +This change will not be committed
  +This is the second line
  +This line has been added
  record this change to 'editedfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  abort: error parsing patch: unhandled transition: file -> other
  [10]

  $ hg up -C
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

With win32text

  $ echo '[extensions]' >> .hg/hgrc
  $ echo 'win32text = ' >> .hg/hgrc
  $ echo '[decode]' >> .hg/hgrc
  $ echo '** = cleverdecode:' >> .hg/hgrc
  $ echo '[encode]' >> .hg/hgrc
  $ echo '** = cleverencode:' >> .hg/hgrc
  $ echo '[patch]' >> .hg/hgrc
  $ echo 'eol = crlf' >> .hg/hgrc

Ignore win32text deprecation warning for now:

  $ echo '[win32text]' >> .hg/hgrc
  $ echo 'warn = no' >> .hg/hgrc

  $ echo d >> subdir/f1
  $ hg commit -i -d '24 0' -mw1 <<EOF
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -3,3 +3,4 @@ a
   a
   b
   c
  +d
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  

  $ hg status -A subdir/f1
  C subdir/f1
  $ hg tip -p
  changeset:   30:* (glob)
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:24 1970 +0000
  summary:     w1
  
  diff -r ???????????? -r ???????????? subdir/f1 (glob)
  --- a/subdir/f1	Thu Jan 01 00:00:23 1970 +0000
  +++ b/subdir/f1	Thu Jan 01 00:00:24 1970 +0000
  @@ -3,3 +3,4 @@
   a
   b
   c
  +d
  


Test --user when ui.username not set
  $ unset HGUSER
  $ echo e >> subdir/f1
  $ hg commit -i  --config ui.username= -d '8 0' --user xyz -m "user flag" <<EOF
  > y
  > y
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  1 hunks, 1 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -4,3 +4,4 @@ a
   b
   c
   d
  +e
  record this change to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  $ hg status -A subdir/f1
  C subdir/f1
  $ hg log --template '{author}\n' -l 1
  xyz
  $ HGUSER="test"
  $ export HGUSER


Moving files

  $ hg update -C .
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg mv plain plain3
  $ echo somechange >> plain3
  $ hg commit -i -d '23 0' -mmoving_files << EOF
  > y
  > y
  > EOF
  diff --git a/plain b/plain3
  rename from plain
  rename to plain3
  1 hunks, 1 lines changed
  examine changes to 'plain' and 'plain3'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -11,3 +11,4 @@
   9
   10
   11
  +somechange
  record this change to 'plain3'?
  (enter ? for help) [Ynesfdaq?] y
  

Rename file but discard edits

  $ echo content > new-file
  $ hg add -q new-file
  $ hg commit -qm 'new file'
  $ hg mv new-file renamed-file
  $ echo new-content >> renamed-file
  $ hg commit -i -d '24 0' -m content-rename<<EOF
  > y
  > n
  > EOF
  diff --git a/new-file b/renamed-file
  rename from new-file
  rename to renamed-file
  1 hunks, 1 lines changed
  examine changes to 'new-file' and 'renamed-file'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,1 +1,2 @@
   content
  +new-content
  record this change to 'renamed-file'?
  (enter ? for help) [Ynesfdaq?] n
  
  $ hg status
  M renamed-file
  ? editedfile.orig
  ? editedfile.rej
  ? editor.sh
  $ hg diff
  diff -r * renamed-file (glob)
  --- a/renamed-file	Thu Jan 01 00:00:24 1970 +0000
  +++ b/renamed-file	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,1 +1,2 @@
   content
  +new-content

The #if execbit block above changes the hash here on some systems
  $ hg status -A plain3
  C plain3
  $ hg tip
  changeset:   34:* (glob)
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:24 1970 +0000
  summary:     content-rename
  
Editing patch of newly added file

  $ hg update -C .
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat > editor.sh << '__EOF__'
  > cat "$1"  | sed "s/first/very/g"  > tt
  > mv tt  "$1"
  > __EOF__
  $ cat > newfile << '__EOF__'
  > This is the first line
  > This is the second line
  > This is the third line
  > __EOF__
  $ hg add newfile
  $ HGEDITOR="\"sh\" \"`pwd`/editor.sh\"" hg commit -i -d '25 0' -medit-patch-new <<EOF
  > y
  > e
  > EOF
  diff --git a/newfile b/newfile
  new file mode 100644
  examine changes to 'newfile'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -0,0 +1,3 @@
  +This is the first line
  +This is the second line
  +This is the third line
  record this change to 'newfile'?
  (enter ? for help) [Ynesfdaq?] e
  
  $ hg cat -r tip newfile
  This is the very line
  This is the second line
  This is the third line

  $ cat newfile
  This is the first line
  This is the second line
  This is the third line

Add new file from within a subdirectory
  $ hg update -C .
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ mkdir folder
  $ cd folder
  $ echo "foo" > bar
  $ hg add bar
  $ hg commit -i -d '26 0' -mnewfilesubdir  <<EOF
  > y
  > y
  > EOF
  diff --git a/folder/bar b/folder/bar
  new file mode 100644
  examine changes to 'folder/bar'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -0,0 +1,1 @@
  +foo
  record this change to 'folder/bar'?
  (enter ? for help) [Ynesfdaq?] y
  
The #if execbit block above changes the hashes here on some systems
  $ hg tip -p
  changeset:   36:* (glob)
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:26 1970 +0000
  summary:     newfilesubdir
  
  diff -r * -r * folder/bar (glob)
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/folder/bar	Thu Jan 01 00:00:26 1970 +0000
  @@ -0,0 +1,1 @@
  +foo
  
  $ cd ..

  $ hg status -A folder/bar
  C folder/bar

Clear win32text configuration before size/timestamp sensitive test

  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > win32text = !
  > [decode]
  > ** = !
  > [encode]
  > ** = !
  > [patch]
  > eol = strict
  > EOF
  $ hg update -q -C null
  $ hg update -q -C tip

Test that partially committed file is still treated as "modified",
even if none of mode, size and timestamp is changed on the filesystem
(see also issue4583).

  $ cat > subdir/f1 <<EOF
  > A
  > a
  > a
  > b
  > c
  > d
  > E
  > EOF
  $ hg diff --git subdir/f1
  diff --git a/subdir/f1 b/subdir/f1
  --- a/subdir/f1
  +++ b/subdir/f1
  @@ -1,7 +1,7 @@
  -a
  +A
   a
   a
   b
   c
   d
  -e
  +E

  $ touch -t 200001010000 subdir/f1

  $ cat >> .hg/hgrc <<EOF
  > # emulate invoking patch.internalpatch() at 2000-01-01 00:00
  > [fakepatchtime]
  > fakenow = 200001010000
  > 
  > [extensions]
  > fakepatchtime = $TESTDIR/fakepatchtime.py
  > EOF
  $ hg commit -i -m 'commit subdir/f1 partially' <<EOF
  > y
  > y
  > n
  > EOF
  diff --git a/subdir/f1 b/subdir/f1
  2 hunks, 2 lines changed
  examine changes to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,6 +1,6 @@
  -a
  +A
   a
   a
   b
   c
   d
  record change 1/2 to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -2,6 +2,6 @@
   a
   a
   b
   c
   d
  -e
  +E
  record change 2/2 to 'subdir/f1'?
  (enter ? for help) [Ynesfdaq?] n
  
  $ cat >> .hg/hgrc <<EOF
  > [extensions]
  > fakepatchtime = !
  > EOF

  $ hg debugstate | grep ' subdir/f1$'
  n   0         -1 unset               subdir/f1
  $ hg status -A subdir/f1
  M subdir/f1

Test commands.commit.interactive.unified=0

  $ hg init $TESTTMP/b
  $ cd $TESTTMP/b
  $ cat > foo <<EOF
  > 1
  > 2
  > 3
  > 4
  > 5
  > EOF
  $ hg ci -qAm initial
  $ cat > foo <<EOF
  > 1
  > change1
  > 2
  > 3
  > change2
  > 4
  > 5
  > EOF
  $ printf 'y\ny\ny\n' | hg ci -im initial --config commands.commit.interactive.unified=0
  diff --git a/foo b/foo
  2 hunks, 2 lines changed
  examine changes to 'foo'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,0 +2,1 @@
  +change1
  record change 1/2 to 'foo'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -3,0 +5,1 @@
  +change2
  record change 2/2 to 'foo'?
  (enter ? for help) [Ynesfdaq?] y
  
  $ cd $TESTTMP

Test diff.ignoreblanklines=1

  $ hg init c
  $ cd c
  $ cat > foo <<EOF
  > 1
  > 2
  > 3
  > 4
  > 5
  > EOF
  $ hg ci -qAm initial
  $ cat > foo <<EOF
  > 1
  > 
  > 2
  > 3
  > change2
  > 4
  > 5
  > EOF
  $ printf 'y\ny\ny\n' | hg ci -im initial --config diff.ignoreblanklines=1
  diff --git a/foo b/foo
  2 hunks, 2 lines changed
  examine changes to 'foo'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -1,3 +1,4 @@
   1
  +
   2
   3
  record change 1/2 to 'foo'?
  (enter ? for help) [Ynesfdaq?] y
  
  @@ -2,4 +3,5 @@
   2
   3
  +change2
   4
   5
  record change 2/2 to 'foo'?
  (enter ? for help) [Ynesfdaq?] y
  

