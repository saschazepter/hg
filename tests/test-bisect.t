  $ hg init repo
  $ cd repo

committing changes

  $ count=0
  $ echo > a
  $ while test $count -lt 32 ; do
  >     echo 'a' >> a
  >     test $count -eq 0 && hg add
  >     hg ci -m "msg $count" -d "$count 0"
  >     count=`expr $count + 1`
  > done
  adding a


  $ hg log -G
  @  changeset:   31:58c80a7c8a40
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:31 1970 +0000
  |  summary:     msg 31
  |
  o  changeset:   30:ed2d2f24b11c
  |  user:        test
  |  date:        Thu Jan 01 00:00:30 1970 +0000
  |  summary:     msg 30
  |
  o  changeset:   29:b5bd63375ab9
  |  user:        test
  |  date:        Thu Jan 01 00:00:29 1970 +0000
  |  summary:     msg 29
  |
  o  changeset:   28:8e0c2264c8af
  |  user:        test
  |  date:        Thu Jan 01 00:00:28 1970 +0000
  |  summary:     msg 28
  |
  o  changeset:   27:288867a866e9
  |  user:        test
  |  date:        Thu Jan 01 00:00:27 1970 +0000
  |  summary:     msg 27
  |
  o  changeset:   26:3efc6fd51aeb
  |  user:        test
  |  date:        Thu Jan 01 00:00:26 1970 +0000
  |  summary:     msg 26
  |
  o  changeset:   25:02a84173a97a
  |  user:        test
  |  date:        Thu Jan 01 00:00:25 1970 +0000
  |  summary:     msg 25
  |
  o  changeset:   24:10e0acd3809e
  |  user:        test
  |  date:        Thu Jan 01 00:00:24 1970 +0000
  |  summary:     msg 24
  |
  o  changeset:   23:5ec79163bff4
  |  user:        test
  |  date:        Thu Jan 01 00:00:23 1970 +0000
  |  summary:     msg 23
  |
  o  changeset:   22:06c7993750ce
  |  user:        test
  |  date:        Thu Jan 01 00:00:22 1970 +0000
  |  summary:     msg 22
  |
  o  changeset:   21:e5db6aa3fe2a
  |  user:        test
  |  date:        Thu Jan 01 00:00:21 1970 +0000
  |  summary:     msg 21
  |
  o  changeset:   20:7128fb4fdbc9
  |  user:        test
  |  date:        Thu Jan 01 00:00:20 1970 +0000
  |  summary:     msg 20
  |
  o  changeset:   19:52798545b482
  |  user:        test
  |  date:        Thu Jan 01 00:00:19 1970 +0000
  |  summary:     msg 19
  |
  o  changeset:   18:86977a90077e
  |  user:        test
  |  date:        Thu Jan 01 00:00:18 1970 +0000
  |  summary:     msg 18
  |
  o  changeset:   17:03515f4a9080
  |  user:        test
  |  date:        Thu Jan 01 00:00:17 1970 +0000
  |  summary:     msg 17
  |
  o  changeset:   16:a2e6ea4973e9
  |  user:        test
  |  date:        Thu Jan 01 00:00:16 1970 +0000
  |  summary:     msg 16
  |
  o  changeset:   15:e7fa0811edb0
  |  user:        test
  |  date:        Thu Jan 01 00:00:15 1970 +0000
  |  summary:     msg 15
  |
  o  changeset:   14:ce8f0998e922
  |  user:        test
  |  date:        Thu Jan 01 00:00:14 1970 +0000
  |  summary:     msg 14
  |
  o  changeset:   13:9d7d07bc967c
  |  user:        test
  |  date:        Thu Jan 01 00:00:13 1970 +0000
  |  summary:     msg 13
  |
  o  changeset:   12:1941b52820a5
  |  user:        test
  |  date:        Thu Jan 01 00:00:12 1970 +0000
  |  summary:     msg 12
  |
  o  changeset:   11:7b4cd9578619
  |  user:        test
  |  date:        Thu Jan 01 00:00:11 1970 +0000
  |  summary:     msg 11
  |
  o  changeset:   10:7c5eff49a6b6
  |  user:        test
  |  date:        Thu Jan 01 00:00:10 1970 +0000
  |  summary:     msg 10
  |
  o  changeset:   9:eb44510ef29a
  |  user:        test
  |  date:        Thu Jan 01 00:00:09 1970 +0000
  |  summary:     msg 9
  |
  o  changeset:   8:453eb4dba229
  |  user:        test
  |  date:        Thu Jan 01 00:00:08 1970 +0000
  |  summary:     msg 8
  |
  o  changeset:   7:03750880c6b5
  |  user:        test
  |  date:        Thu Jan 01 00:00:07 1970 +0000
  |  summary:     msg 7
  |
  o  changeset:   6:a3d5c6fdf0d3
  |  user:        test
  |  date:        Thu Jan 01 00:00:06 1970 +0000
  |  summary:     msg 6
  |
  o  changeset:   5:7874a09ea728
  |  user:        test
  |  date:        Thu Jan 01 00:00:05 1970 +0000
  |  summary:     msg 5
  |
  o  changeset:   4:9b2ba8336a65
  |  user:        test
  |  date:        Thu Jan 01 00:00:04 1970 +0000
  |  summary:     msg 4
  |
  o  changeset:   3:b53bea5e2fcb
  |  user:        test
  |  date:        Thu Jan 01 00:00:03 1970 +0000
  |  summary:     msg 3
  |
  o  changeset:   2:db07c04beaca
  |  user:        test
  |  date:        Thu Jan 01 00:00:02 1970 +0000
  |  summary:     msg 2
  |
  o  changeset:   1:5cd978ea5149
  |  user:        test
  |  date:        Thu Jan 01 00:00:01 1970 +0000
  |  summary:     msg 1
  |
  o  changeset:   0:b99c7b9c8e11
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     msg 0
  

  $ hg up -C
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

bisect test

  $ hg bisect -r
  $ hg bisect -b
  $ hg status -v
  # The repository is in an unfinished *bisect* state.
  
  # To mark the changeset good:    hg bisect --good
  # To mark the changeset bad:     hg bisect --bad
  # To abort:                      hg bisect --reset
  
  $ hg status -v --config commands.status.skipstates=bisect
  $ hg summary
  parent: 31:58c80a7c8a40 tip
   msg 31
  branch: default
  commit: (clean)
  update: (current)
  phases: 32 draft
  $ hg bisect -g 1
  Testing changeset 16:a2e6ea4973e9 "msg 16" (30 changesets remaining, ~4 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  Testing changeset 23:5ec79163bff4 "msg 23" (15 changesets remaining, ~3 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

skip

  $ hg bisect -s
  Testing changeset 24:10e0acd3809e "msg 24" (15 changesets remaining, ~3 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  Testing changeset 27:288867a866e9 "msg 27" (7 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  Testing changeset 29:b5bd63375ab9 "msg 29" (4 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -b
  Testing changeset 28:8e0c2264c8af "msg 28" (2 changesets remaining, ~1 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  The first bad revision is:
  changeset:   29:b5bd63375ab9
  user:        test
  date:        Thu Jan 01 00:00:29 1970 +0000
  summary:     msg 29
  

mark revsets instead of single revs

  $ hg bisect -r
  $ hg bisect -b "0::3"
  $ hg bisect -s "13::16"
  $ hg bisect -g "26::tip"
  Testing changeset 12:1941b52820a5 "msg 12" (23 changesets remaining, ~4 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat .hg/bisect.state
  bad b99c7b9c8e11558adef3fad9af211c58d46f325b
  bad 5cd978ea51499179507ee7b6f340d2dbaa401185
  bad db07c04beaca44cf24832541e7f4a2346a95275b
  bad b53bea5e2fcb30d3e00bd3409507a5659ce0fd8b
  current 1941b52820a544549596820a8ae006842b0e2c64
  good 3efc6fd51aeb8594398044c6c846ca59ae021203
  good 288867a866e9adb7a29880b66936c874b80f4651
  good 8e0c2264c8af790daf3585ada0669d93dee09c83
  good b5bd63375ab9a290419f2024b7f4ee9ea7ce90a8
  good ed2d2f24b11c368fa8aa0da9f4e1db580abade59
  good 58c80a7c8a4025a94cedaf7b4a4e3124e8909a96
  skip 9d7d07bc967ca98ad0600c24953fd289ad5fa991
  skip ce8f0998e922c179e80819d5066fbe46e2998784
  skip e7fa0811edb063f6319531f0d0a865882138e180
  skip a2e6ea4973e9196ddd3386493b0c214b41fd97d3

bisect reverse test

  $ hg bisect -r
  $ hg bisect -b null
  $ hg bisect -g tip
  Testing changeset 15:e7fa0811edb0 "msg 15" (32 changesets remaining, ~5 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  Testing changeset 7:03750880c6b5 "msg 7" (16 changesets remaining, ~4 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

skip

  $ hg bisect -s
  Testing changeset 6:a3d5c6fdf0d3 "msg 6" (16 changesets remaining, ~4 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  Testing changeset 2:db07c04beaca "msg 2" (7 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  Testing changeset 0:b99c7b9c8e11 "msg 0" (3 changesets remaining, ~1 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -b
  Testing changeset 1:5cd978ea5149 "msg 1" (2 changesets remaining, ~1 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  The first good revision is:
  changeset:   1:5cd978ea5149
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     msg 1
  

  $ hg bisect -r
  $ hg bisect -g tip
  $ hg bisect -b tip
  abort: inconsistent state, 31:58c80a7c8a40 is good and bad
  [255]

  $ hg bisect -r
  $ hg bisect -g null
  $ hg bisect -bU tip
  Testing changeset 15:e7fa0811edb0 "msg 15" (32 changesets remaining, ~5 tests)
  $ hg id
  5cd978ea5149


Issue1228: hg bisect crashes when you skip the last rev in bisection
Issue1182: hg bisect exception

  $ hg bisect -r
  $ hg bisect -b 4
  $ hg bisect -g 0
  Testing changeset 2:db07c04beaca "msg 2" (4 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Testing changeset 1:5cd978ea5149 "msg 1" (4 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Testing changeset 3:b53bea5e2fcb "msg 3" (4 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Due to skipped revisions, the first bad revision could be any of:
  changeset:   1:5cd978ea5149
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     msg 1
  
  changeset:   2:db07c04beaca
  user:        test
  date:        Thu Jan 01 00:00:02 1970 +0000
  summary:     msg 2
  
  changeset:   3:b53bea5e2fcb
  user:        test
  date:        Thu Jan 01 00:00:03 1970 +0000
  summary:     msg 3
  
  changeset:   4:9b2ba8336a65
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     msg 4
  


reproduce non converging bisect, issue1182

  $ hg bisect -r
  $ hg bisect -g 0
  $ hg bisect -b 2
  Testing changeset 1:5cd978ea5149 "msg 1" (2 changesets remaining, ~1 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Due to skipped revisions, the first bad revision could be any of:
  changeset:   1:5cd978ea5149
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     msg 1
  
  changeset:   2:db07c04beaca
  user:        test
  date:        Thu Jan 01 00:00:02 1970 +0000
  summary:     msg 2
  


test no action

  $ hg bisect -r
  $ hg bisect
  abort: cannot bisect (no known good revisions)
  [20]


reproduce AssertionError, issue1445

  $ hg bisect -r
  $ hg bisect -b 6
  $ hg bisect -g 0
  Testing changeset 3:b53bea5e2fcb "msg 3" (6 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Testing changeset 2:db07c04beaca "msg 2" (6 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Testing changeset 4:9b2ba8336a65 "msg 4" (6 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Testing changeset 1:5cd978ea5149 "msg 1" (6 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -s
  Testing changeset 5:7874a09ea728 "msg 5" (6 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect -g
  The first bad revision is:
  changeset:   6:a3d5c6fdf0d3
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     msg 6
  
  $ hg log -r "bisect(good)"
  changeset:   0:b99c7b9c8e11
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     msg 0
  
  changeset:   5:7874a09ea728
  user:        test
  date:        Thu Jan 01 00:00:05 1970 +0000
  summary:     msg 5
  
  $ hg log -r "bisect(bad)"
  changeset:   6:a3d5c6fdf0d3
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     msg 6
  
  $ hg log -r "bisect(current)"
  changeset:   5:7874a09ea728
  user:        test
  date:        Thu Jan 01 00:00:05 1970 +0000
  summary:     msg 5
  
  $ hg log -r "bisect(skip)"
  changeset:   1:5cd978ea5149
  user:        test
  date:        Thu Jan 01 00:00:01 1970 +0000
  summary:     msg 1
  
  changeset:   2:db07c04beaca
  user:        test
  date:        Thu Jan 01 00:00:02 1970 +0000
  summary:     msg 2
  
  changeset:   3:b53bea5e2fcb
  user:        test
  date:        Thu Jan 01 00:00:03 1970 +0000
  summary:     msg 3
  
  changeset:   4:9b2ba8336a65
  user:        test
  date:        Thu Jan 01 00:00:04 1970 +0000
  summary:     msg 4
  

test legacy bisected() keyword

  $ hg log -r "bisected(bad)"
  changeset:   6:a3d5c6fdf0d3
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     msg 6
  

  $ set +e

test invalid command
assuming that the shell returns 127 if command not found ...

  $ hg bisect -r
  $ hg bisect --command 'exit 127'
  abort: failed to execute exit 127
  [255]


test bisecting command

  $ cat > "$TESTTMP/script.py" <<EOF
  > #!$PYTHON
  > import sys
  > from mercurial import hg, ui as uimod
  > repo = hg.repository(uimod.ui.load(), b'.')
  > if repo[b'.'].rev() < 6:
  >     sys.exit(1)
  > EOF
  $ chmod +x "$TESTTMP/script.py"
  $ hg bisect -r
  $ hg up -qr tip
  $ hg bisect --command "\"$PYTHON\" \"$TESTTMP/script.py\" and some parameters"
  changeset 31:58c80a7c8a40 tip "msg 31": good
  abort: cannot bisect (no known bad revisions)
  [20]
  $ hg up -qr 0
  $ hg bisect --command "\"$PYTHON\" \"$TESTTMP/script.py\" and some parameters"
  changeset 0:b99c7b9c8e11 "msg 0": bad
  changeset 15:e7fa0811edb0 "msg 15": good
  changeset 7:03750880c6b5 "msg 7": good
  changeset 3:b53bea5e2fcb "msg 3": bad
  changeset 5:7874a09ea728 "msg 5": bad
  changeset 6:a3d5c6fdf0d3 "msg 6": good
  The first good revision is:
  changeset:   6:a3d5c6fdf0d3
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     msg 6
  


test bisecting via a command without updating the working dir, and
ensure that the bisect state file is updated before running a test
command

  $ hg update null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ cat > "$TESTTMP/script.sh" <<'EOF'
  > #!/bin/sh
  > test -n "$HG_NODE" || (echo HG_NODE missing; exit 127)
  > current="`hg log -r \"bisect(current)\" --template {node}`"
  > test "$current" = "$HG_NODE" || (echo current is bad: $current; exit 127)
  > rev="`hg log -r $HG_NODE --template {rev}`"
  > test "$rev" -ge 6
  > EOF
  $ chmod +x "$TESTTMP/script.sh"
  $ hg bisect -r
  $ hg bisect --good tip --noupdate
  $ hg bisect --bad 0 --noupdate
  Testing changeset 15:e7fa0811edb0 "msg 15" (31 changesets remaining, ~4 tests)
  $ hg bisect --command "sh \"$TESTTMP/script.sh\" and some params" --noupdate
  changeset 15:e7fa0811edb0 "msg 15": good
  changeset 7:03750880c6b5 "msg 7": good
  changeset 3:b53bea5e2fcb "msg 3": bad
  changeset 5:7874a09ea728 "msg 5": bad
  changeset 6:a3d5c6fdf0d3 "msg 6": good
  The first good revision is:
  changeset:   6:a3d5c6fdf0d3
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     msg 6
  

ensure that we still don't have a working dir

  $ hg parents


test the same case, this time with updating

  $ cat > "$TESTTMP/script.sh" <<'EOF'
  > #!/bin/sh
  > test -n "$HG_NODE" || (echo HG_NODE missing; exit 127)
  > current="`hg log -r \"bisect(current)\" --template {node}`"
  > test "$current" = "$HG_NODE" || (echo current is bad: $current; exit 127)
  > rev="`hg log -r . --template {rev}`"
  > test "$rev" -ge 6
  > EOF
  $ chmod +x "$TESTTMP/script.sh"
  $ hg bisect -r
  $ hg up -qr tip
  $ hg bisect --command "sh \"$TESTTMP/script.sh\" and some params"
  changeset 31:58c80a7c8a40 tip "msg 31": good
  abort: cannot bisect (no known bad revisions)
  [20]
  $ hg up -qr 0
  $ hg bisect --command "sh \"$TESTTMP/script.sh\" and some params"
  changeset 0:b99c7b9c8e11 "msg 0": bad
  changeset 15:e7fa0811edb0 "msg 15": good
  changeset 7:03750880c6b5 "msg 7": good
  changeset 3:b53bea5e2fcb "msg 3": bad
  changeset 5:7874a09ea728 "msg 5": bad
  changeset 6:a3d5c6fdf0d3 "msg 6": good
  The first good revision is:
  changeset:   6:a3d5c6fdf0d3
  user:        test
  date:        Thu Jan 01 00:00:06 1970 +0000
  summary:     msg 6
  
  $ hg graft -q 15
  warning: conflicts while merging a! (edit, then use 'hg resolve --mark')
  abort: unresolved conflicts, can't continue
  (use 'hg resolve' and 'hg graft --continue')
  [1]
  $ hg bisect --reset
  $ hg up -C .
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Check that bisect does not break on obsolete changesets
=========================================================

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution.createmarkers=True
  > EOF

tip is obsolete
---------------------

  $ hg debugobsolete `hg id -T "{node}" -r tip`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg bisect --reset
  $ hg bisect --good 15
  $ hg bisect --bad 30
  Testing changeset 22:06c7993750ce "msg 22" (15 changesets remaining, ~3 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect --command true
  changeset 22:06c7993750ce "msg 22": good
  changeset 26:3efc6fd51aeb "msg 26": good
  changeset 28:8e0c2264c8af "msg 28": good
  changeset 29:b5bd63375ab9 "msg 29": good
  The first bad revision is:
  changeset:   30:ed2d2f24b11c
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:30 1970 +0000
  summary:     msg 30
  

Rewritten commits should not crash

  $ hg co 29
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg revert --all -r 30
  reverting a
  $ hg commit -m 'msg 30 -- fixed'
  created new head
  $ hg debugobsolete `hg id -T "{node}" -r 30` `hg id -T "{node}" -r .`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg bisect
  The first bad revision is:
  changeset:   30:ed2d2f24b11c
  user:        test
  date:        Thu Jan 01 00:00:30 1970 +0000
  obsolete:    rewritten as 32:8a638ebd1122
  summary:     msg 30
  

Log template does not crash

  $ hg log -GTbisect -r 15::
  @  changeset:   32:8a638ebd1122
  |  bisect:      good (implicit)
  |  tag:         tip
  |  parent:      29:b5bd63375ab9
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     msg 30 -- fixed
  |
  o  changeset:   29:b5bd63375ab9
  |  bisect:      good
  |  user:        test
  |  date:        Thu Jan 01 00:00:29 1970 +0000
  |  summary:     msg 29
  |
  o  changeset:   28:8e0c2264c8af
  |  bisect:      good
  |  user:        test
  |  date:        Thu Jan 01 00:00:28 1970 +0000
  |  summary:     msg 28
  |
  o  changeset:   27:288867a866e9
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:27 1970 +0000
  |  summary:     msg 27
  |
  o  changeset:   26:3efc6fd51aeb
  |  bisect:      good
  |  user:        test
  |  date:        Thu Jan 01 00:00:26 1970 +0000
  |  summary:     msg 26
  |
  o  changeset:   25:02a84173a97a
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:25 1970 +0000
  |  summary:     msg 25
  |
  o  changeset:   24:10e0acd3809e
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:24 1970 +0000
  |  summary:     msg 24
  |
  o  changeset:   23:5ec79163bff4
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:23 1970 +0000
  |  summary:     msg 23
  |
  o  changeset:   22:06c7993750ce
  |  bisect:      good
  |  user:        test
  |  date:        Thu Jan 01 00:00:22 1970 +0000
  |  summary:     msg 22
  |
  o  changeset:   21:e5db6aa3fe2a
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:21 1970 +0000
  |  summary:     msg 21
  |
  o  changeset:   20:7128fb4fdbc9
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:20 1970 +0000
  |  summary:     msg 20
  |
  o  changeset:   19:52798545b482
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:19 1970 +0000
  |  summary:     msg 19
  |
  o  changeset:   18:86977a90077e
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:18 1970 +0000
  |  summary:     msg 18
  |
  o  changeset:   17:03515f4a9080
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:17 1970 +0000
  |  summary:     msg 17
  |
  o  changeset:   16:a2e6ea4973e9
  |  bisect:      ignored
  |  user:        test
  |  date:        Thu Jan 01 00:00:16 1970 +0000
  |  summary:     msg 16
  |
  o  changeset:   15:e7fa0811edb0
  |  bisect:      good
  ~  user:        test
     date:        Thu Jan 01 00:00:15 1970 +0000
     summary:     msg 15
  
  $ hg debugobsolete --delete `hg debugobsolete --index -T'{index}\n' | tail -1`
  deleted 1 obsolescence markers

Changeset in the bad:good range is obsolete
---------------------------------------------

  $ hg up 30
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo 'a' >> a
  $ hg ci -m "msg 32" -d "32 0"
  $ hg bisect --reset
  $ hg bisect --good .
  $ hg bisect --bad 25
  Testing changeset 28:8e0c2264c8af "msg 28" (6 changesets remaining, ~2 tests)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg bisect --command true
  changeset 28:8e0c2264c8af "msg 28": good
  changeset 26:3efc6fd51aeb "msg 26": good
  The first good revision is:
  changeset:   26:3efc6fd51aeb
  user:        test
  date:        Thu Jan 01 00:00:26 1970 +0000
  summary:     msg 26
  
Test the validation message when exclusive options are used:

  $ hg bisect -r
  $ hg bisect -b -c false
  abort: --bad and --command are incompatible
  [10]
  $ hg bisect -b -e
  abort: --bad and --extend are incompatible
  [10]
  $ hg bisect -b -g
  abort: --bad and --good are incompatible
  [10]
  $ hg bisect -b -r
  abort: --bad and --reset are incompatible
  [10]
  $ hg bisect -b -s
  abort: --bad and --skip are incompatible
  [10]
  $ hg bisect -c false -e
  abort: --command and --extend are incompatible
  [10]
  $ hg bisect -c false -g
  abort: --command and --good are incompatible
  [10]
  $ hg bisect -c false -r
  abort: --command and --reset are incompatible
  [10]
  $ hg bisect -c false -s
  abort: --command and --skip are incompatible
  [10]
  $ hg bisect -e -g
  abort: --extend and --good are incompatible
  [10]
  $ hg bisect -e -r
  abort: --extend and --reset are incompatible
  [10]
  $ hg bisect -e -s
  abort: --extend and --skip are incompatible
  [10]
  $ hg bisect -g -r
  abort: --good and --reset are incompatible
  [10]
  $ hg bisect -g -s
  abort: --good and --skip are incompatible
  [10]
  $ hg bisect -r -s
  abort: --reset and --skip are incompatible
  [10]
