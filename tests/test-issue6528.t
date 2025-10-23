===============================================================
Test non-regression on the corruption associated with issue6528
===============================================================

Setup
=====

  $ hg init base-repo
  $ cd base-repo

  $ cat <<EOF > a.txt
  > 1
  > 2
  > 3
  > 4
  > 5
  > 6
  > EOF

  $ hg add a.txt
  $ hg commit -m 'c_base_c - create a.txt'

Modify a.txt

  $ sed -e 's/1/foo/' a.txt > a.tmp; mv a.tmp a.txt
  $ hg commit -m 'c_modify_c - modify a.txt'

Modify and rename a.txt to b.txt

  $ hg up -r "desc('c_base_c')"
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ sed -e 's/6/bar/' a.txt > a.tmp; mv a.tmp a.txt
  $ hg mv a.txt b.txt
  $ hg commit -m 'c_rename_c - rename and modify a.txt to b.txt'
  created new head

Merge each branch

  $ hg merge -r "desc('c_modify_c')"
  merging b.txt and a.txt to b.txt
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m 'c_merge_c: commit merge'

  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea

Check commit Graph

  $ hg log -G
  @    changeset:   3:a1cc2bdca0aa
  |\   tag:         tip
  | |  parent:      2:615c6ccefd15
  | |  parent:      1:373d507f4667
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     c_merge_c: commit merge
  | |
  | o  changeset:   2:615c6ccefd15
  | |  parent:      0:f5a5a568022f
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     c_rename_c - rename and modify a.txt to b.txt
  | |
  o |  changeset:   1:373d507f4667
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     c_modify_c - modify a.txt
  |
  o  changeset:   0:f5a5a568022f
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     c_base_c - create a.txt
  

  $ hg cat -r . b.txt
  foo
  2
  3
  4
  5
  bar
  $ cat b.txt
  foo
  2
  3
  4
  5
  bar
  $ cd ..


Check the lack of corruption
============================

  $ hg clone --pull base-repo cloned
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 2 files
  new changesets f5a5a568022f:a1cc2bdca0aa
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd cloned
  $ hg up -r "desc('c_merge_c')"
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved


Status is buggy, even with debugrebuilddirstate

  $ hg cat -r . b.txt
  foo
  2
  3
  4
  5
  bar
  $ cat b.txt
  foo
  2
  3
  4
  5
  bar
  $ hg status
  $ hg debugrebuilddirstate
  $ hg status

the history was altered

in theory p1/p2 order does not matter but in practice p1 == nullid is used as a
marker that some metadata are present and should be fetched.

  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea

Check commit Graph

  $ hg log -G
  @    changeset:   3:a1cc2bdca0aa
  |\   tag:         tip
  | |  parent:      2:615c6ccefd15
  | |  parent:      1:373d507f4667
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     c_merge_c: commit merge
  | |
  | o  changeset:   2:615c6ccefd15
  | |  parent:      0:f5a5a568022f
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  summary:     c_rename_c - rename and modify a.txt to b.txt
  | |
  o |  changeset:   1:373d507f4667
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     c_modify_c - modify a.txt
  |
  o  changeset:   0:f5a5a568022f
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     c_base_c - create a.txt
  

Test the command that fixes the issue
=====================================

Restore a broken repository with multiple broken revisions and a filename that
would get encoded to test the `report` options.
It's a tarball because unbundle might magically fix the issue later.

  $ cd ..
  $ mkdir repo-to-fix
  $ cd repo-to-fix
  $ tar -xf - < "$TESTDIR"/bundles/issue6528.tar

Check that the issue is present
(It is currently not present with rhg but will be when optimizations are added
to resolve ambiguous files at the end of status without reading their content
if the size differs, and reading the expected size without resolving filelog
deltas where possible.)

  $ hg st
  M D.txt
  M b.txt
  $ hg st --change 2 --copies
  A b.txt
    a.txt
  R a.txt
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000

Dry-run the fix
  $ hg debug-repair-issue6528 --dry-run
  found affected revision 1 for file 'D.txt'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'
  $ hg st
  M D.txt
  M b.txt
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000

Test the --paranoid option
  $ hg debug-repair-issue6528 --dry-run --paranoid
  found affected revision 1 for file 'D.txt'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'
  $ hg st
  M D.txt
  M b.txt
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000

Run the fix
  $ hg debug-repair-issue6528  --paranoid
  found affected revision 1 for file 'D.txt'
  repaired revision 1 of 'filelog data/D.txt.i'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'
  repaired revision 1 of 'filelog data/b.txt.i'
  repaired revision 3 of 'filelog data/b.txt.i'

Check that the fix worked and that running it twice does nothing
  $ hg st
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb
  $ hg debug-repair-issue6528  --paranoid
  no affected revisions were found
  $ hg st
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb

Try the using the report options
--------------------------------

  $ cd ..
  $ mkdir repo-to-fix-report
  $ cd repo-to-fix
  $ tar -xf - < "$TESTDIR"/bundles/issue6528.tar

  $ hg debug-repair-issue6528 --to-report $TESTTMP/report.txt --paranoid
  found affected revision 1 for file 'D.txt'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'
  $ cat $TESTTMP/report.txt
  2a80419dfc31d7dfb308ac40f3f138282de7d73b D.txt
  a58b36ad6b6545195952793099613c2116f3563b,ea4f2f2463cca5b29ddf3461012b8ce5c6dac175 b.txt

  $ hg debug-repair-issue6528 --from-report $TESTTMP/report.txt --dry-run
  loading report file '$TESTTMP/report.txt'
  found affected revision 1 for filelog 'D.txt'
  found affected revision 1 for filelog 'b.txt'
  found affected revision 3 for filelog 'b.txt'
  $ hg st
  M D.txt
  M b.txt
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000

  $ hg debug-repair-issue6528 --from-report $TESTTMP/report.txt
  loading report file '$TESTTMP/report.txt'
  found affected revision 1 for filelog 'D.txt'
  repaired revision 1 of 'filelog data/D.txt.i'
  found affected revision 1 for filelog 'b.txt'
  found affected revision 3 for filelog 'b.txt'
  repaired revision 1 of 'filelog data/b.txt.i'
  repaired revision 3 of 'filelog data/b.txt.i'
  $ hg st
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb

Check that the revision is not "fixed" again

  $ hg debug-repair-issue6528 --from-report $TESTTMP/report.txt
  loading report file '$TESTTMP/report.txt'
  revision 2a80419dfc31d7dfb308ac40f3f138282de7d73b of file 'D.txt' is not affected
  no affected revisions were found for 'D.txt'
  revision a58b36ad6b6545195952793099613c2116f3563b of file 'b.txt' is not affected
  revision ea4f2f2463cca5b29ddf3461012b8ce5c6dac175 of file 'b.txt' is not affected
  no affected revisions were found for 'b.txt'
  $ hg st
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb

Try it with a non-inline revlog
-------------------------------

  $ cd ..
  $ mkdir $TESTTMP/ext
  $ cat << EOF > $TESTTMP/ext/small_inline.py
  > from mercurial import revlog
  > revlog._maxinline = 8
  > EOF

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > small_inline=$TESTTMP/ext/small_inline.py
  > EOF

  $ mkdir repo-to-fix-not-inline
  $ cd repo-to-fix-not-inline
  $ tar -xf - < "$TESTDIR"/bundles/issue6528.tar
  $ echo b >> b.txt
  $ hg commit -qm "inline -> separate" --traceback
  $ find .hg -name *b.txt.d
  .hg/store/data/b.txt.d

Status is correct, but the problem is still there, in the earlier revision
  $ hg st
  $ hg up 3
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg st
  M b.txt
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000
       4       8 db234885e2fe ea4f2f2463cc 000000000000
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000
       2       8 65aecc89bb5d 2a80419dfc31 000000000000

Run the fix on the non-inline revlog
  $ hg debug-repair-issue6528  --paranoid
  found affected revision 1 for file 'D.txt'
  repaired revision 1 of 'filelog data/D.txt.i'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'
  repaired revision 1 of 'filelog data/b.txt.i'
  repaired revision 3 of 'filelog data/b.txt.i'

Check that it worked
  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed
       4       8 db234885e2fe ea4f2f2463cc 000000000000
  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb
       2       8 65aecc89bb5d 2a80419dfc31 000000000000
  $ hg debug-repair-issue6528  --paranoid
  no affected revisions were found
  $ hg st

  $ cd ..

Applying a bad bundle should fix it on the fly
----------------------------------------------

from a v1 bundle
~~~~~~~~~~~~~~~~

  $ hg debugbundle  --spec "$TESTDIR"/bundles/issue6528.hg-v1
  bzip2-v1

  $ hg init unbundle-v1
  $ cd unbundle-v1

  $ hg unbundle "$TESTDIR"/bundles/issue6528.hg-v1
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 12 changes to 4 files
  new changesets f5a5a568022f:3beabb508514 (8 drafts)
  (run 'hg update' to get a working copy)

Check that revision were fixed on the fly

  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed

  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb

That we don't see the symptoms of the bug

  $ hg up -- -1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg status

And that the repair command does not find anything to fix

  $ hg debug-repair-issue6528  --paranoid
  no affected revisions were found

  $ cd ..

from a v2 bundle
~~~~~~~~~~~~~~~~

  $ hg debugbundle --spec "$TESTDIR"/bundles/issue6528.hg-v2
  bzip2-v2

  $ hg init unbundle-v2
  $ cd unbundle-v2

  $ hg unbundle "$TESTDIR"/bundles/issue6528.hg-v2
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 12 changes to 4 files
  new changesets f5a5a568022f:3beabb508514 (8 drafts)
  (run 'hg update' to get a working copy)

Check that revision were fixed on the fly

  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 000000000000 05b806ebe5ea
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 000000000000 216a5fe8b8ed

  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 000000000000 2a8d3833f2fb

That we don't see the symptoms of the bug

  $ hg up -- -1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg status

And that the repair command does not find anything to fix

  $ hg debug-repair-issue6528  --paranoid
  no affected revisions were found

  $ cd ..

A config option can disable the fixing of the bad bundle on the fly
-------------------------------------------------------------------



from a v1 bundle
~~~~~~~~~~~~~~~~

  $ hg debugbundle  --spec "$TESTDIR"/bundles/issue6528.hg-v1
  bzip2-v1

  $ hg init unbundle-v1-no-fix
  $ cd unbundle-v1-no-fix

  $ hg unbundle "$TESTDIR"/bundles/issue6528.hg-v1 --config storage.revlog.issue6528.fix-incoming=no
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 12 changes to 4 files
  new changesets f5a5a568022f:3beabb508514 (8 drafts)
  (run 'hg update' to get a working copy)

Check that revision were not fixed on the fly

  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000

  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000

That we do see the symptoms of the bug

  $ hg up -- -1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg status
  M D.txt
  M b.txt

And that the repair command find issue to fix.

  $ hg debug-repair-issue6528 --dry-run  --paranoid
  found affected revision 1 for file 'D.txt'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'

  $ cd ..

from a v2 bundle
~~~~~~~~~~~~~~~~

  $ hg debugbundle --spec "$TESTDIR"/bundles/issue6528.hg-v2
  bzip2-v2

  $ hg init unbundle-v2-no-fix
  $ cd unbundle-v2-no-fix

  $ hg unbundle "$TESTDIR"/bundles/issue6528.hg-v2 --config storage.revlog.issue6528.fix-incoming=no
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 12 changes to 4 files
  new changesets f5a5a568022f:3beabb508514 (8 drafts)
  (run 'hg update' to get a working copy)

Check that revision were not fixed on the fly

  $ hg debugrevlogindex b.txt
     rev linkrev nodeid       p1           p2
       0       2 05b806ebe5ea 000000000000 000000000000
       1       3 a58b36ad6b65 05b806ebe5ea 000000000000
       2       6 216a5fe8b8ed 000000000000 000000000000
       3       7 ea4f2f2463cc 216a5fe8b8ed 000000000000

  $ hg debugrevlogindex D.txt
     rev linkrev nodeid       p1           p2
       0       6 2a8d3833f2fb 000000000000 000000000000
       1       7 2a80419dfc31 2a8d3833f2fb 000000000000

That we do see the symptoms of the bug

  $ hg up -- -1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg status
  M D.txt
  M b.txt

And that the repair command find issue to fix.

  $ hg debug-repair-issue6528 --dry-run  --paranoid
  found affected revision 1 for file 'D.txt'
  found affected revision 1 for file 'b.txt'
  found affected revision 3 for file 'b.txt'

  $ cd ..

Upgrading to explicit meta flags
--------------------------------

  $ hg init upgrade-to-has-meta --config format.exp-use-delta-info-flags=no
  $ cd upgrade-to-has-meta
  $ hg debugformat delta-info-flags
  format-variant                 repo
  delta-info-flags:                no

  $ hg unbundle "$TESTDIR"/bundles/issue6528.hg-v2 --config storage.revlog.issue6528.fix-incoming=no
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 12 changes to 4 files
  new changesets f5a5a568022f:3beabb508514 (8 drafts)
  (run 'hg update' to get a working copy)

Check that revision were not fixed on the fly

  $ hg debugrevlogindex a.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       12      0     -1     -1 38ecb501c5f4
       1 0000       14      1      0     -1 dd95142cd79c
       2 0000       82      4     -1     -1 24eaeb9b60a2
       3 0000       19      5      2     -1 359eaa70a265
  $ hg debugrevlogindex b.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       80      2     -1     -1 05b806ebe5ea
       1 0000       82      3      0     -1 a58b36ad6b65
       2 0000       82      6     -1     -1 216a5fe8b8ed
       3 0000       85      7      2     -1 ea4f2f2463cc

  $ hg debugrevlogindex C.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       12      4     -1     -1 38ecb501c5f4
       1 0000       14      5      0     -1 dd95142cd79c
  $ hg debugrevlogindex D.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       80      6     -1     -1 2a8d3833f2fb
       1 0000       82      7      0     -1 2a80419dfc31

That we do see the symptoms of the bug

  $ hg status --change 2 --copies
  A b.txt
    a.txt
  R a.txt
  $ hg up -- -1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg status
  M D.txt
  M b.txt

Upgrading to a revlog format with explicit meta flag tracking

  $ hg debugupgraderepo --run --config format.exp-use-delta-info-flags=yes --quiet
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     added: exp-delta-info-revlog
  
  processed revlogs:
    - all-filelogs
    - manifest
  
  $ hg debugformat delta-info-flags
  format-variant                 repo
  delta-info-flags:               yes


  $ hg debugrevlogindex a.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0400       12      0     -1     -1 38ecb501c5f4
       1 0780       14      1      0     -1 dd95142cd79c
       2 0c00       82      4     -1     -1 24eaeb9b60a2 (pure !)
       2 0e00       82      4     -1     -1 24eaeb9b60a2 (no-pure !)
       3 0600       19      5      2     -1 359eaa70a265
  $ hg debugrevlogindex b.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0c00       80      2     -1     -1 05b806ebe5ea
       1 0800       82      3      0     -1 a58b36ad6b65
       2 0c00       82      6     -1     -1 216a5fe8b8ed (pure !)
       2 0e00       82      6     -1     -1 216a5fe8b8ed (no-pure !)
       3 0800       85      7      2     -1 ea4f2f2463cc
  $ hg debugrevlogindex C.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0400       12      4     -1     -1 38ecb501c5f4
       1 0780       14      5      0     -1 dd95142cd79c

  $ hg debugrevlogindex D.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0c00       80      6     -1     -1 2a8d3833f2fb
       1 0800       82      7      0     -1 2a80419dfc31

We no longer see the bug

  $ hg status --change 2 --copies
  A b.txt
    a.txt
  R a.txt
  $ hg debugrevlog b.txt | grep flags
  flags  : generaldelta, hasmeta, delta-info
  $ hg debugrevlog D.txt | grep flags
  flags  : generaldelta, hasmeta, delta-info
  $ hg status

Downgrading does not regress

  $ hg debugupgraderepo --run --config format.exp-use-delta-info-flags=no --quiet
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: exp-delta-info-revlog
  
  processed revlogs:
    - all-filelogs
    - manifest
  
  $ hg debugformat delta-info-flags
  format-variant                 repo
  delta-info-flags:                no

  $ hg debugrevlogindex a.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       12      0     -1     -1 38ecb501c5f4
       1 0000       14      1      0     -1 dd95142cd79c
       2 0000       82      4     -1     -1 24eaeb9b60a2
       3 0000       19      5      2     -1 359eaa70a265
  $ hg debugrevlogindex b.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       80      2     -1     -1 05b806ebe5ea
       1 0000       82      3     -1      0 a58b36ad6b65
       2 0000       82      6     -1     -1 216a5fe8b8ed
       3 0000       85      7     -1      2 ea4f2f2463cc

  $ hg debugrevlogindex C.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       12      4     -1     -1 38ecb501c5f4
       1 0000       14      5      0     -1 dd95142cd79c
  $ hg debugrevlogindex D.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0000       80      6     -1     -1 2a8d3833f2fb
       1 0000       82      7     -1      0 2a80419dfc31


  $ hg status --change 2 --copies
  A b.txt
    a.txt
  R a.txt
  $ hg debugrevlog b.txt | grep flags
  flags  : generaldelta
  $ hg debugrevlog D.txt | grep flags
  flags  : generaldelta
  $ hg status


upgrading with fast upgrade

  $ hg debugrequires | grep delta-info
  [1]
  $ hg debugrevlog a.txt | grep flags
  flags  : generaldelta
  $ hg debugrevlog b.txt | grep flags
  flags  : generaldelta
  $ hg debugrevlog C.txt | grep flags
  flags  : generaldelta
  $ hg debugrevlog D.txt | grep flags
  flags  : generaldelta

  $ hg debug::fast-upgrade
  adding has-meta flag filelogs
  adding delta-info flag to filelogs and manifests
  upgraded 5 filelog

  $ hg debugrequires | grep delta-info
  exp-delta-info-revlog
  $ hg debugrevlog a.txt | grep flags
  flags  : generaldelta, hasmeta, delta-info
  $ hg debugrevlog b.txt | grep flags
  flags  : generaldelta, hasmeta, delta-info
  $ hg debugrevlog C.txt | grep flags
  flags  : generaldelta, hasmeta, delta-info
  $ hg debugrevlog D.txt | grep flags
  flags  : generaldelta, hasmeta, delta-info

  $ hg debugrevlogindex a.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0400       12      0     -1     -1 38ecb501c5f4
       1 0400       14      1      0     -1 dd95142cd79c
       2 0c00       82      4     -1     -1 24eaeb9b60a2
       3 0400       19      5      2     -1 359eaa70a265
  $ hg debugrevlogindex b.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0c00       80      2     -1     -1 05b806ebe5ea
       1 0800       82      3      0     -1 a58b36ad6b65
       2 0c00       82      6     -1     -1 216a5fe8b8ed
       3 0800       85      7      2     -1 ea4f2f2463cc
  $ hg debugrevlogindex C.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0400       12      4     -1     -1 38ecb501c5f4
       1 0400       14      5      0     -1 dd95142cd79c

  $ hg debugrevlogindex D.txt --format 1
     rev flag     size   link     p1     p2       nodeid
       0 0c00       80      6     -1     -1 2a8d3833f2fb
       1 0800       82      7      0     -1 2a80419dfc31

  $ hg status --rev 0 --rev tip --copies
  A D.txt
  A b.txt
    a.txt
  R a.txt

  $ cd ..
