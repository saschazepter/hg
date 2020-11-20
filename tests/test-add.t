  $ hg init a
  $ cd a
  $ echo a > a
  $ hg add -n
  adding a
  $ hg st
  ? a
  $ hg add
  adding a
  $ hg st
  A a
  $ hg forget a
  $ hg add
  adding a
  $ hg forget a
  $ hg add --color debug
  [ui.addremove.added ui.status|adding a]
  $ hg st
  A a
  $ mkdir dir
  $ cd dir
  $ hg add ../a
  ../a already tracked!
  $ cd ..

  $ echo b > b
  $ hg add -n b
  $ hg st
  A a
  ? b
  $ hg add b
  $ hg st
  A a
  A b

should fail

  $ hg add b
  b already tracked!
  $ hg st
  A a
  A b

#if no-windows
  $ echo foo > con.xml
  $ hg --config ui.portablefilenames=jump add con.xml
  config error: ui.portablefilenames value is invalid ('jump')
  [30]
  $ hg --config ui.portablefilenames=abort add con.xml
  abort: filename contains 'con', which is reserved on Windows: con.xml
  [10]
  $ hg st
  A a
  A b
  ? con.xml
  $ hg add con.xml
  warning: filename contains 'con', which is reserved on Windows: con.xml
  $ hg st
  A a
  A b
  A con.xml
  $ hg forget con.xml
  $ rm con.xml
#endif

#if eol-in-paths
  $ echo bla > 'hello:world'
  $ hg --config ui.portablefilenames=abort add
  adding hello:world
  abort: filename contains ':', which is reserved on Windows: 'hello:world'
  [10]
  $ hg st
  A a
  A b
  ? hello:world
  $ hg --config ui.portablefilenames=ignore add
  adding hello:world
  $ hg st
  A a
  A b
  A hello:world
#endif

  $ hg ci -m 0 --traceback

  $ hg log -r "heads(. or wdir() & file('**'))"
  changeset:   0:* (glob)
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0
  
should fail

  $ hg add a
  a already tracked!

  $ echo aa > a
  $ hg ci -m 1
  $ hg up 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo aaa > a
  $ hg ci -m 2
  created new head

  $ hg merge
  merging a
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges or 'hg merge --abort' to abandon
  [1]
  $ hg st
  M a
  ? a.orig

wdir doesn't cause a crash, and can be dynamically selected if dirty

  $ hg log -r "heads(. or wdir() & file('**'))"
  changeset:   2147483647:ffffffffffff
  parent:      2:* (glob)
  parent:      1:* (glob)
  user:        test
  date:        * (glob)
  
should fail

  $ hg add a
  a already tracked!
  $ hg st
  M a
  ? a.orig
  $ hg resolve -m a
  (no more unresolved files)
  $ hg ci -m merge

Issue683: peculiarity with hg revert of an removed then added file

  $ hg forget a
  $ hg add a
  $ hg st
  ? a.orig
  $ hg rm a
  $ hg st
  R a
  ? a.orig
  $ echo a > a
  $ hg add a
  $ hg st
  M a
  ? a.orig

excluded file shouldn't be added even if it is explicitly specified

  $ hg add a.orig -X '*.orig'
  $ hg st
  M a
  ? a.orig

Forgotten file can be added back (as either clean or modified)

  $ hg forget b
  $ hg add b
  $ hg st -A b
  C b
  $ hg forget b
  $ echo modified > b
  $ hg add b
  $ hg st -A b
  M b
  $ hg revert -qC b

  $ hg add c && echo "unexpected addition of missing file"
  c: * (glob)
  [1]
  $ echo c > c
  $ hg add d c && echo "unexpected addition of missing file"
  d: * (glob)
  [1]
  $ hg st
  M a
  A c
  ? a.orig
  $ hg up -C
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

forget and get should have the right order: added but missing dir should be
forgotten before file with same name is added

  $ echo file d > d
  $ hg add d
  $ hg ci -md
  $ hg rm d
  $ mkdir d
  $ echo a > d/a
  $ hg add d/a
  $ rm -r d
  $ hg up -C
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat d
  file d

Test that adding a directory doesn't require case matching (issue4578)
#if icasefs
  $ mkdir -p CapsDir1/CapsDir
  $ echo abc > CapsDir1/CapsDir/AbC.txt
  $ mkdir CapsDir1/CapsDir/SubDir
  $ echo def > CapsDir1/CapsDir/SubDir/Def.txt

  $ hg add capsdir1/capsdir
  adding CapsDir1/CapsDir/AbC.txt
  adding CapsDir1/CapsDir/SubDir/Def.txt

  $ hg forget capsdir1/capsdir/abc.txt

  $ hg forget capsdir1/capsdir
  removing CapsDir1/CapsDir/SubDir/Def.txt

  $ hg add capsdir1
  adding CapsDir1/CapsDir/AbC.txt
  adding CapsDir1/CapsDir/SubDir/Def.txt

  $ hg ci -m "AbCDef" capsdir1/capsdir

  $ hg status -A capsdir1/capsdir
  C CapsDir1/CapsDir/AbC.txt
  C CapsDir1/CapsDir/SubDir/Def.txt

  $ hg files capsdir1/capsdir
  CapsDir1/CapsDir/AbC.txt
  CapsDir1/CapsDir/SubDir/Def.txt

  $ echo xyz > CapsDir1/CapsDir/SubDir/Def.txt
  $ hg ci -m xyz capsdir1/capsdir/subdir/def.txt

  $ hg revert -r '.^' capsdir1/capsdir
  reverting CapsDir1/CapsDir/SubDir/Def.txt

The conditional tests above mean the hash on the diff line differs on Windows
and OS X
  $ hg diff capsdir1/capsdir
  diff -r * CapsDir1/CapsDir/SubDir/Def.txt (glob)
  --- a/CapsDir1/CapsDir/SubDir/Def.txt	Thu Jan 01 00:00:00 1970 +0000
  +++ b/CapsDir1/CapsDir/SubDir/Def.txt	* (glob)
  @@ -1,1 +1,1 @@
  -xyz
  +def

  $ hg mv CapsDir1/CapsDir/abc.txt CapsDir1/CapsDir/ABC.txt
  $ hg ci -m "case changing rename" CapsDir1/CapsDir/AbC.txt CapsDir1/CapsDir/ABC.txt

  $ hg status -A capsdir1/capsdir
  M CapsDir1/CapsDir/SubDir/Def.txt
  C CapsDir1/CapsDir/ABC.txt

  $ hg remove -f 'glob:**.txt' -X capsdir1/capsdir
  $ hg remove -f 'glob:**.txt' -I capsdir1/capsdir
  removing CapsDir1/CapsDir/ABC.txt
  removing CapsDir1/CapsDir/SubDir/Def.txt
#endif

  $ cd ..

test --dry-run mode in forget

  $ hg init testdir_forget
  $ cd testdir_forget
  $ echo foo > foo
  $ hg add foo
  $ hg commit -m "foo"
  $ hg forget foo --dry-run -v
  removing foo
  $ hg diff
  $ hg forget not_exist -n
  not_exist: $ENOENT$
  [1]

  $ cd ..

test --interactive mode in forget

  $ hg init interactiveforget
  $ cd interactiveforget
  $ echo foo > foo
  $ hg commit -qAm "foo"
  $ echo bar > bar
  $ hg commit -qAm "bar"
  $ hg forget foo --dry-run -i
  abort: cannot specify both --dry-run and --interactive
  [10]

  $ hg forget foo --config ui.interactive=True -i << EOF
  > ?
  > n
  > EOF
  forget foo [Ynsa?] ?
  y - yes, forget this file
  n - no, skip this file
  s - skip remaining files
  a - include all remaining files
  ? - ? (display help)
  forget foo [Ynsa?] n

  $ hg forget foo bar --config ui.interactive=True -i << EOF
  > y
  > n
  > EOF
  forget bar [Ynsa?] y
  forget foo [Ynsa?] n
  removing bar
  $ hg status
  R bar
  $ hg up -qC .

  $ hg forget foo bar --config ui.interactive=True -i << EOF
  > s
  > EOF
  forget bar [Ynsa?] s
  $ hg st
  $ hg up -qC .

  $ hg forget foo bar --config ui.interactive=True -i << EOF
  > a
  > EOF
  forget bar [Ynsa?] a
  removing bar
  removing foo
  $ hg status
  R bar
  R foo
  $ hg up -qC .

  $ cd ..
