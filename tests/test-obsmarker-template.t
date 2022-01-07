This test file test the various templates related to obsmarkers.

Global setup
============

  $ . $TESTDIR/testlib/obsmarker-common.sh
  $ cat >> $HGRCPATH <<EOF
  > [ui]
  > interactive = true
  > [phases]
  > publish=False
  > [experimental]
  > evolution=true
  > evolution.allowdivergence=true
  > [templates]
  > obsfatesuccessors = "{if(successors, " as ")}{join(successors, ", ")}"
  > obsfateverb = "{obsfateverb(successors, markers)}"
  > obsfateoperations = "{if(obsfateoperations(markers), " using {join(obsfateoperations(markers), ", ")}")}"
  > obsfateusers = "{if(obsfateusers(markers), " by {join(obsfateusers(markers), ", ")}")}"
  > obsfatedate = "{if(obsfatedate(markers), "{ifeq(min(obsfatedate(markers)), max(obsfatedate(markers)), " (at {min(obsfatedate(markers))|isodate})", " (between {min(obsfatedate(markers))|isodate} and {max(obsfatedate(markers))|isodate})")}")}"
  > obsfatetempl = "{obsfateverb}{obsfateoperations}{obsfatesuccessors}{obsfateusers}{obsfatedate}; "
  > [alias]
  > tlog = log -G -T '{node|short}\
  >     \n  Predecessors: {predecessors}\
  >     \n  semi-colon: {join(predecessors, "; ")}\
  >     \n  json: {predecessors|json}\
  >     \n  map: {join(predecessors % "{rev}:{node}", " ")}\
  >     \n  Successors: {successorssets}\
  >     \n  multi-line: {join(successorssets, "\n  multi-line: ")}\
  >     \n  json: {successorssets|json}\n'
  > fatelog = log -G -T '{node|short}\n{if(succsandmarkers, "  Obsfate: {succsandmarkers % "{obsfatetempl}"} \n" )}'
  > fatelogjson = log -G -T '{node|short}\n{if(succsandmarkers, "  Obsfate: {succsandmarkers|json}\n")}'
  > fatelogkw = log -G -T '{node|short}\n{if(obsfate, "{obsfate % "  Obsfate: {fate}\n"}")}'
  > EOF

Test templates on amended commit
================================

Test setup
----------

  $ hg init $TESTTMP/templates-local-amend
  $ cd $TESTTMP/templates-local-amend
  $ mkcommit ROOT
  $ mkcommit A0
  $ echo 42 >> A0
  $ hg commit --amend -m "A1" --config devel.default-date="1234567890 0"
  $ hg commit --amend -m "A2" --config devel.default-date="987654321 0" --config devel.user.obsmarker=test2

  $ hg log --hidden -G
  @  changeset:   3:d004c8f274b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | x  changeset:   2:a468dc9b3633
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:d004c8f274b9 by test2
  |    summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:a468dc9b3633
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Check templates
---------------
  $ hg up 'desc(A0)' --hidden
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' was rewritten as: d004c8f274b9)

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  o  d004c8f274b9
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 3:d004c8f274b9
  |      multi-line: 3:d004c8f274b9
  |      json: [["d004c8f274b9ec480a47a93c10dac5eee63adb78"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  d004c8f274b9
  |
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test, test2 (between 2001-04-19 04:25 +0000 and 2009-02-13 23:31 +0000);
  o  ea207398892e
  

  $ hg fatelogkw
  o  d004c8f274b9
  |
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test, test2
  o  ea207398892e
  

  $ hg log -G --config command-templates.log=
  o  changeset:   3:d004c8f274b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | @  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:d004c8f274b9 by test, test2
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

  $ hg log -G -T "default"
  o  changeset:   3:d004c8f274b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | @  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:d004c8f274b9 by test, test2
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ hg up 'desc(A1)' --hidden
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset a468dc9b3633
  (hidden revision 'a468dc9b3633' was rewritten as: d004c8f274b9)

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  o  d004c8f274b9
  |    Predecessors: 2:a468dc9b3633
  |    semi-colon: 2:a468dc9b3633
  |    json: ["a468dc9b36338b14fdb7825f55ce3df4e71517ad"]
  |    map: 2:a468dc9b36338b14fdb7825f55ce3df4e71517ad
  |    Successors:
  |    multi-line:
  |    json: []
  | @  a468dc9b3633
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 3:d004c8f274b9
  |      multi-line: 3:d004c8f274b9
  |      json: [["d004c8f274b9ec480a47a93c10dac5eee63adb78"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  d004c8f274b9
  |
  | @  a468dc9b3633
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test2 (at 2001-04-19 04:25 +0000);
  o  ea207398892e
  
Predecessors template should show all the predecessors as we force their display
with --hidden
  $ hg tlog --hidden
  o  d004c8f274b9
  |    Predecessors: 2:a468dc9b3633
  |    semi-colon: 2:a468dc9b3633
  |    json: ["a468dc9b36338b14fdb7825f55ce3df4e71517ad"]
  |    map: 2:a468dc9b36338b14fdb7825f55ce3df4e71517ad
  |    Successors:
  |    multi-line:
  |    json: []
  | @  a468dc9b3633
  |/     Predecessors: 1:471f378eab4c
  |      semi-colon: 1:471f378eab4c
  |      json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |      map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |      Successors: 3:d004c8f274b9
  |      multi-line: 3:d004c8f274b9
  |      json: [["d004c8f274b9ec480a47a93c10dac5eee63adb78"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:a468dc9b3633
  |      multi-line: 2:a468dc9b3633
  |      json: [["a468dc9b36338b14fdb7825f55ce3df4e71517ad"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog --hidden
  o  d004c8f274b9
  |
  | @  a468dc9b3633
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test2 (at 2001-04-19 04:25 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:a468dc9b3633 by test (at 2009-02-13 23:31 +0000);
  o  ea207398892e
  

Predecessors template shouldn't show anything as all obsolete commit are not
visible.
  $ hg up 'desc(A2)'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg tlog
  @  d004c8f274b9
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg tlog --hidden
  @  d004c8f274b9
  |    Predecessors: 2:a468dc9b3633
  |    semi-colon: 2:a468dc9b3633
  |    json: ["a468dc9b36338b14fdb7825f55ce3df4e71517ad"]
  |    map: 2:a468dc9b36338b14fdb7825f55ce3df4e71517ad
  |    Successors:
  |    multi-line:
  |    json: []
  | x  a468dc9b3633
  |/     Predecessors: 1:471f378eab4c
  |      semi-colon: 1:471f378eab4c
  |      json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |      map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |      Successors: 3:d004c8f274b9
  |      multi-line: 3:d004c8f274b9
  |      json: [["d004c8f274b9ec480a47a93c10dac5eee63adb78"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:a468dc9b3633
  |      multi-line: 2:a468dc9b3633
  |      json: [["a468dc9b36338b14fdb7825f55ce3df4e71517ad"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  @  d004c8f274b9
  |
  o  ea207398892e
  

  $ hg fatelog --hidden
  @  d004c8f274b9
  |
  | x  a468dc9b3633
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test2 (at 2001-04-19 04:25 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:a468dc9b3633 by test (at 2009-02-13 23:31 +0000);
  o  ea207398892e
  
  $ hg fatelogjson --hidden
  @  d004c8f274b9
  |
  | x  a468dc9b3633
  |/     Obsfate: [{"markers": [["a468dc9b36338b14fdb7825f55ce3df4e71517ad", ["d004c8f274b9ec480a47a93c10dac5eee63adb78"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test2"]], [987654321.0, 0], null]], "successors": ["d004c8f274b9ec480a47a93c10dac5eee63adb78"]}]
  | x  471f378eab4c
  |/     Obsfate: [{"markers": [["471f378eab4c5e25f6c77f785b27c936efb22874", ["a468dc9b36338b14fdb7825f55ce3df4e71517ad"], 0, [["ef1", "9"], ["operation", "amend"], ["user", "test"]], [1234567890.0, 0], null]], "successors": ["a468dc9b36338b14fdb7825f55ce3df4e71517ad"]}]
  o  ea207398892e
  

Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  @  d004c8f274b9
  |
  | x  a468dc9b3633
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:a468dc9b3633
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  @  d004c8f274b9
  |
  | x  a468dc9b3633
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test2
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:a468dc9b3633
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  @  d004c8f274b9
  |
  | x  a468dc9b3633
  |/     Obsfate: rewritten using amend as 3:d004c8f274b9 by test2 (at 2001-04-19 04:25 +0000)
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:a468dc9b3633 by test (at 2009-02-13 23:31 +0000)
  o  ea207398892e
  

  $ hg log -G -T "default" --hidden
  @  changeset:   3:d004c8f274b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | x  changeset:   2:a468dc9b3633
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:d004c8f274b9 by test2
  |    summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:a468dc9b3633
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ hg log -G -T "default" --hidden -v
  @  changeset:   3:d004c8f274b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       A0
  |  description:
  |  A2
  |
  |
  | x  changeset:   2:a468dc9b3633
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:d004c8f274b9 by test2 (at 2001-04-19 04:25 +0000)
  |    files:       A0
  |    description:
  |    A1
  |
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:a468dc9b3633 by test (at 2009-02-13 23:31 +0000)
  |    files:       A0
  |    description:
  |    A0
  |
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     files:       ROOT
     description:
     ROOT
  
  
Test templates with splitted commit
===================================

  $ hg init $TESTTMP/templates-local-split
  $ cd $TESTTMP/templates-local-split
  $ mkcommit ROOT
  $ echo 42 >> a
  $ echo 43 >> b
  $ hg commit -A -m "A0"
  adding a
  adding b
  $ hg log --hidden -G
  @  changeset:   1:471597cad322
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
# Simulate split
  $ hg up -r "desc(ROOT)"
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo 42 >> a
  $ hg commit -A -m "A0"
  adding a
  created new head
  $ echo 43 >> b
  $ hg commit -A -m "A0"
  adding b
  $ hg debugobsolete `getid "1"` `getid "2"` `getid "3"`
  1 new obsolescence markers
  obsoleted 1 changesets

  $ hg log --hidden -G
  @  changeset:   3:f257fde29c7a
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   2:337fec4d2edc
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  | x  changeset:   1:471597cad322
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    split as 2:337fec4d2edc, 3:f257fde29c7a
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Check templates
---------------

  $ hg up 'obsolete()' --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471597cad322
  (hidden revision '471597cad322' was split as: 337fec4d2edc, f257fde29c7a)

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  o  f257fde29c7a
  |    Predecessors: 1:471597cad322
  |    semi-colon: 1:471597cad322
  |    json: ["471597cad322d1f659bb169751be9133dad92ef3"]
  |    map: 1:471597cad322d1f659bb169751be9133dad92ef3
  |    Successors:
  |    multi-line:
  |    json: []
  o  337fec4d2edc
  |    Predecessors: 1:471597cad322
  |    semi-colon: 1:471597cad322
  |    json: ["471597cad322d1f659bb169751be9133dad92ef3"]
  |    map: 1:471597cad322d1f659bb169751be9133dad92ef3
  |    Successors:
  |    multi-line:
  |    json: []
  | @  471597cad322
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:337fec4d2edc 3:f257fde29c7a
  |      multi-line: 2:337fec4d2edc 3:f257fde29c7a
  |      json: [["337fec4d2edcf0e7a467e35f818234bc620068b5", "f257fde29c7a847c9b607f6e958656d0df0fb15c"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  f257fde29c7a
  |
  o  337fec4d2edc
  |
  | @  471597cad322
  |/     Obsfate: split as 2:337fec4d2edc, 3:f257fde29c7a by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up f257fde29c7a
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

Predecessors template should not show a predecessor as it's not displayed in
the log
  $ hg tlog
  @  f257fde29c7a
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  337fec4d2edc
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

Predecessors template should show both predecessors as we force their display
with --hidden
  $ hg tlog --hidden
  @  f257fde29c7a
  |    Predecessors: 1:471597cad322
  |    semi-colon: 1:471597cad322
  |    json: ["471597cad322d1f659bb169751be9133dad92ef3"]
  |    map: 1:471597cad322d1f659bb169751be9133dad92ef3
  |    Successors:
  |    multi-line:
  |    json: []
  o  337fec4d2edc
  |    Predecessors: 1:471597cad322
  |    semi-colon: 1:471597cad322
  |    json: ["471597cad322d1f659bb169751be9133dad92ef3"]
  |    map: 1:471597cad322d1f659bb169751be9133dad92ef3
  |    Successors:
  |    multi-line:
  |    json: []
  | x  471597cad322
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:337fec4d2edc 3:f257fde29c7a
  |      multi-line: 2:337fec4d2edc 3:f257fde29c7a
  |      json: [["337fec4d2edcf0e7a467e35f818234bc620068b5", "f257fde29c7a847c9b607f6e958656d0df0fb15c"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog --hidden
  @  f257fde29c7a
  |
  o  337fec4d2edc
  |
  | x  471597cad322
  |/     Obsfate: split as 2:337fec4d2edc, 3:f257fde29c7a by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg fatelogjson --hidden
  @  f257fde29c7a
  |
  o  337fec4d2edc
  |
  | x  471597cad322
  |/     Obsfate: [{"markers": [["471597cad322d1f659bb169751be9133dad92ef3", ["337fec4d2edcf0e7a467e35f818234bc620068b5", "f257fde29c7a847c9b607f6e958656d0df0fb15c"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["337fec4d2edcf0e7a467e35f818234bc620068b5", "f257fde29c7a847c9b607f6e958656d0df0fb15c"]}]
  o  ea207398892e
  
Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  @  f257fde29c7a
  |
  o  337fec4d2edc
  |
  | x  471597cad322
  |/     Obsfate: split as 2:337fec4d2edc, 3:f257fde29c7a
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  @  f257fde29c7a
  |
  o  337fec4d2edc
  |
  | x  471597cad322
  |/     Obsfate: split as 2:337fec4d2edc, 3:f257fde29c7a
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  @  f257fde29c7a
  |
  o  337fec4d2edc
  |
  | x  471597cad322
  |/     Obsfate: split as 2:337fec4d2edc, 3:f257fde29c7a by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  

  $ hg log -G -T "default" --hidden
  @  changeset:   3:f257fde29c7a
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   2:337fec4d2edc
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  | x  changeset:   1:471597cad322
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    split as 2:337fec4d2edc, 3:f257fde29c7a
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test templates with folded commit
=================================

Test setup
----------

  $ hg init $TESTTMP/templates-local-fold
  $ cd $TESTTMP/templates-local-fold
  $ mkcommit ROOT
  $ mkcommit A0
  $ mkcommit B0
  $ hg log --hidden -G
  @  changeset:   2:0dec01379d3b
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     B0
  |
  o  changeset:   1:471f378eab4c
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Simulate a fold
  $ hg up -r "desc(ROOT)"
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo "A0" > A0
  $ echo "B0" > B0
  $ hg commit -A -m "C0"
  adding A0
  adding B0
  created new head
  $ hg debugobsolete `getid "desc(A0)"` `getid "desc(C0)"`
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new orphan changesets
  $ hg debugobsolete `getid "desc(B0)"` `getid "desc(C0)"`
  1 new obsolescence markers
  obsoleted 1 changesets

  $ hg log --hidden -G
  @  changeset:   3:eb5a0daa2192
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  | x  changeset:   2:0dec01379d3b
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten as 3:eb5a0daa2192
  | |  summary:     B0
  | |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten as 3:eb5a0daa2192
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Check templates
---------------

  $ hg up 'desc(A0)' --hidden
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' was rewritten as: eb5a0daa2192)

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  o  eb5a0daa2192
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 3:eb5a0daa2192
  |      multi-line: 3:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  eb5a0daa2192
  |
  | @  471f378eab4c
  |/     Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(B0)' --hidden
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 0dec01379d3b
  (hidden revision '0dec01379d3b' was rewritten as: eb5a0daa2192)

Predecessors template should show both predecessors as they should be both
displayed
  $ hg tlog
  o  eb5a0daa2192
  |    Predecessors: 2:0dec01379d3b 1:471f378eab4c
  |    semi-colon: 2:0dec01379d3b; 1:471f378eab4c
  |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", "471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  0dec01379d3b
  | |    Predecessors:
  | |    semi-colon:
  | |    json: []
  | |    map:
  | |    Successors: 3:eb5a0daa2192
  | |    multi-line: 3:eb5a0daa2192
  | |    json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 3:eb5a0daa2192
  |      multi-line: 3:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  eb5a0daa2192
  |
  | @  0dec01379d3b
  | |    Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(C0)'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

Predecessors template should not show predecessors as they are not displayed in
the log
  $ hg tlog
  @  eb5a0daa2192
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []
Predecessors template should show both predecessors as we force their display
with --hidden
  $ hg tlog --hidden
  @  eb5a0daa2192
  |    Predecessors: 2:0dec01379d3b 1:471f378eab4c
  |    semi-colon: 2:0dec01379d3b; 1:471f378eab4c
  |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", "471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | x  0dec01379d3b
  | |    Predecessors:
  | |    semi-colon:
  | |    json: []
  | |    map:
  | |    Successors: 3:eb5a0daa2192
  | |    multi-line: 3:eb5a0daa2192
  | |    json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 3:eb5a0daa2192
  |      multi-line: 3:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog --hidden
  @  eb5a0daa2192
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  

  $ hg fatelogjson --hidden
  @  eb5a0daa2192
  |
  | x  0dec01379d3b
  | |    Obsfate: [{"markers": [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]}]
  | x  471f378eab4c
  |/     Obsfate: [{"markers": [["471f378eab4c5e25f6c77f785b27c936efb22874", ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]}]
  o  ea207398892e
  
Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  @  eb5a0daa2192
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:eb5a0daa2192
  | x  471f378eab4c
  |/     Obsfate: rewritten as 3:eb5a0daa2192
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  @  eb5a0daa2192
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:eb5a0daa2192
  | x  471f378eab4c
  |/     Obsfate: rewritten as 3:eb5a0daa2192
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  @  eb5a0daa2192
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000)
  | x  471f378eab4c
  |/     Obsfate: rewritten as 3:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  
  $ hg log -G -T "default" --hidden
  @  changeset:   3:eb5a0daa2192
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  | x  changeset:   2:0dec01379d3b
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten as 3:eb5a0daa2192
  | |  summary:     B0
  | |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten as 3:eb5a0daa2192
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test templates with divergence
==============================

Test setup
----------

  $ hg init $TESTTMP/templates-local-divergence
  $ cd $TESTTMP/templates-local-divergence
  $ mkcommit ROOT
  $ mkcommit A0
  $ hg commit --amend -m "A1"
  $ hg log --hidden -G
  @  changeset:   2:fdf9bde5129a
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:fdf9bde5129a
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ hg update --hidden 'desc(A0)'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' was rewritten as: fdf9bde5129a)
  $ hg commit --amend -m "A2"
  2 new content-divergent changesets
  $ hg log --hidden -G
  @  changeset:   3:65b757b745b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     A2
  |
  | *  changeset:   2:fdf9bde5129a
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    instability: content-divergent
  |    summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:fdf9bde5129a
  |    obsolete:    rewritten using amend as 3:65b757b745b9
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ hg commit --amend -m 'A3'
  $ hg log --hidden -G
  @  changeset:   4:019fadeab383
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     A3
  |
  | x  changeset:   3:65b757b745b9
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 4:019fadeab383
  |    summary:     A2
  |
  | *  changeset:   2:fdf9bde5129a
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    instability: content-divergent
  |    summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:fdf9bde5129a
  |    obsolete:    rewritten using amend as 3:65b757b745b9
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Check templates
---------------

  $ hg up 'desc(A0)' --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' has diverged)

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  *  019fadeab383
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | *  fdf9bde5129a
  |/     Predecessors: 1:471f378eab4c
  |      semi-colon: 1:471f378eab4c
  |      json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |      map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |      Successors:
  |      multi-line:
  |      json: []
  | @  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:fdf9bde5129a; 4:019fadeab383
  |      multi-line: 2:fdf9bde5129a
  |      multi-line: 4:019fadeab383
  |      json: [["fdf9bde5129a28d4548fadd3f62b265cdd3b7a2e"], ["019fadeab383f6699fa83ad7bdb4d82ed2c0e5ab"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []
  $ hg fatelog
  *  019fadeab383
  |
  | *  fdf9bde5129a
  |/
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a by test (at 1970-01-01 00:00 +0000); rewritten using amend as 4:019fadeab383 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(A1)'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

Predecessors template should not show predecessors as they are not displayed in
the log
  $ hg tlog
  *  019fadeab383
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  | @  fdf9bde5129a
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors:
  |      multi-line:
  |      json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  *  019fadeab383
  |
  | @  fdf9bde5129a
  |/
  o  ea207398892e
  
Predecessors template should the predecessors as we force their display with
--hidden
  $ hg tlog --hidden
  *  019fadeab383
  |    Predecessors: 3:65b757b745b9
  |    semi-colon: 3:65b757b745b9
  |    json: ["65b757b745b935093c87a2bccd877521cccffcbd"]
  |    map: 3:65b757b745b935093c87a2bccd877521cccffcbd
  |    Successors:
  |    multi-line:
  |    json: []
  | x  65b757b745b9
  |/     Predecessors: 1:471f378eab4c
  |      semi-colon: 1:471f378eab4c
  |      json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |      map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |      Successors: 4:019fadeab383
  |      multi-line: 4:019fadeab383
  |      json: [["019fadeab383f6699fa83ad7bdb4d82ed2c0e5ab"]]
  | @  fdf9bde5129a
  |/     Predecessors: 1:471f378eab4c
  |      semi-colon: 1:471f378eab4c
  |      json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |      map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |      Successors:
  |      multi-line:
  |      json: []
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:fdf9bde5129a; 3:65b757b745b9
  |      multi-line: 2:fdf9bde5129a
  |      multi-line: 3:65b757b745b9
  |      json: [["fdf9bde5129a28d4548fadd3f62b265cdd3b7a2e"], ["65b757b745b935093c87a2bccd877521cccffcbd"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog --hidden
  *  019fadeab383
  |
  | x  65b757b745b9
  |/     Obsfate: rewritten using amend as 4:019fadeab383 by test (at 1970-01-01 00:00 +0000);
  | @  fdf9bde5129a
  |/
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a by test (at 1970-01-01 00:00 +0000); rewritten using amend as 3:65b757b745b9 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  

  $ hg fatelogjson --hidden
  *  019fadeab383
  |
  | x  65b757b745b9
  |/     Obsfate: [{"markers": [["65b757b745b935093c87a2bccd877521cccffcbd", ["019fadeab383f6699fa83ad7bdb4d82ed2c0e5ab"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test"]], [0.0, 0], null]], "successors": ["019fadeab383f6699fa83ad7bdb4d82ed2c0e5ab"]}]
  | @  fdf9bde5129a
  |/
  | x  471f378eab4c
  |/     Obsfate: [{"markers": [["471f378eab4c5e25f6c77f785b27c936efb22874", ["fdf9bde5129a28d4548fadd3f62b265cdd3b7a2e"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test"]], [0.0, 0], null]], "successors": ["fdf9bde5129a28d4548fadd3f62b265cdd3b7a2e"]}, {"markers": [["471f378eab4c5e25f6c77f785b27c936efb22874", ["65b757b745b935093c87a2bccd877521cccffcbd"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test"]], [0.0, 0], null]], "successors": ["65b757b745b935093c87a2bccd877521cccffcbd"]}]
  o  ea207398892e
  

Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  *  019fadeab383
  |
  | x  65b757b745b9
  |/     Obsfate: rewritten using amend as 4:019fadeab383
  | @  fdf9bde5129a
  |/
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a
  |      Obsfate: rewritten using amend as 3:65b757b745b9
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  *  019fadeab383
  |
  | x  65b757b745b9
  |/     Obsfate: rewritten using amend as 4:019fadeab383
  | @  fdf9bde5129a
  |/
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a
  |      Obsfate: rewritten using amend as 3:65b757b745b9
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  *  019fadeab383
  |
  | x  65b757b745b9
  |/     Obsfate: rewritten using amend as 4:019fadeab383 by test (at 1970-01-01 00:00 +0000)
  | @  fdf9bde5129a
  |/
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a by test (at 1970-01-01 00:00 +0000)
  |      Obsfate: rewritten using amend as 3:65b757b745b9 by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  
  $ hg log -G -T "default" --hidden
  *  changeset:   4:019fadeab383
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     A3
  |
  | x  changeset:   3:65b757b745b9
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 4:019fadeab383
  |    summary:     A2
  |
  | @  changeset:   2:fdf9bde5129a
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    instability: content-divergent
  |    summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:fdf9bde5129a
  |    obsolete:    rewritten using amend as 3:65b757b745b9
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test templates with amended + folded commit
===========================================

Test setup
----------

  $ hg init $TESTTMP/templates-local-amend-fold
  $ cd $TESTTMP/templates-local-amend-fold
  $ mkcommit ROOT
  $ mkcommit A0
  $ mkcommit B0
  $ hg commit --amend -m "B1"
  $ hg log --hidden -G
  @  changeset:   3:b7ea6d14e664
  |  tag:         tip
  |  parent:      1:471f378eab4c
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     B1
  |
  | x  changeset:   2:0dec01379d3b
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:b7ea6d14e664
  |    summary:     B0
  |
  o  changeset:   1:471f378eab4c
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
# Simulate a fold
  $ hg up -r "desc(ROOT)"
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo "A0" > A0
  $ echo "B0" > B0
  $ hg commit -A -m "C0"
  adding A0
  adding B0
  created new head
  $ hg debugobsolete `getid "desc(A0)"` `getid "desc(C0)"`
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new orphan changesets
  $ hg debugobsolete `getid "desc(B1)"` `getid "desc(C0)"`
  1 new obsolescence markers
  obsoleted 1 changesets

  $ hg log --hidden -G
  @  changeset:   4:eb5a0daa2192
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  | x  changeset:   3:b7ea6d14e664
  | |  parent:      1:471f378eab4c
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten as 4:eb5a0daa2192
  | |  summary:     B1
  | |
  | | x  changeset:   2:0dec01379d3b
  | |/   user:        test
  | |    date:        Thu Jan 01 00:00:00 1970 +0000
  | |    obsolete:    rewritten using amend as 3:b7ea6d14e664
  | |    summary:     B0
  | |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten as 4:eb5a0daa2192
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Check templates
---------------

  $ hg up 'desc(A0)' --hidden
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' was rewritten as: eb5a0daa2192)

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  o  eb5a0daa2192
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 4:eb5a0daa2192
  |      multi-line: 4:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  eb5a0daa2192
  |
  | @  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(B0)' --hidden
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 0dec01379d3b
  (hidden revision '0dec01379d3b' was rewritten as: eb5a0daa2192)

Predecessors template should both predecessors as they are visible
  $ hg tlog
  o  eb5a0daa2192
  |    Predecessors: 2:0dec01379d3b 1:471f378eab4c
  |    semi-colon: 2:0dec01379d3b; 1:471f378eab4c
  |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", "471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  0dec01379d3b
  | |    Predecessors:
  | |    semi-colon:
  | |    json: []
  | |    map:
  | |    Successors: 4:eb5a0daa2192
  | |    multi-line: 4:eb5a0daa2192
  | |    json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 4:eb5a0daa2192
  |      multi-line: 4:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  eb5a0daa2192
  |
  | @  0dec01379d3b
  | |    Obsfate: rewritten using amend as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(B1)' --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset b7ea6d14e664
  (hidden revision 'b7ea6d14e664' was rewritten as: eb5a0daa2192)

Predecessors template should both predecessors as they are visible
  $ hg tlog
  o  eb5a0daa2192
  |    Predecessors: 1:471f378eab4c 3:b7ea6d14e664
  |    semi-colon: 1:471f378eab4c; 3:b7ea6d14e664
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874", "b7ea6d14e664bdc8922221f7992631b50da3fb07"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874 3:b7ea6d14e664bdc8922221f7992631b50da3fb07
  |    Successors:
  |    multi-line:
  |    json: []
  | @  b7ea6d14e664
  | |    Predecessors:
  | |    semi-colon:
  | |    json: []
  | |    map:
  | |    Successors: 4:eb5a0daa2192
  | |    multi-line: 4:eb5a0daa2192
  | |    json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 4:eb5a0daa2192
  |      multi-line: 4:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  eb5a0daa2192
  |
  | @  b7ea6d14e664
  | |    Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(C0)'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

Predecessors template should show no predecessors as they are both non visible
  $ hg tlog
  @  eb5a0daa2192
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  @  eb5a0daa2192
  |
  o  ea207398892e
  
Predecessors template should show all predecessors as we force their display
with --hidden
  $ hg tlog --hidden
  @  eb5a0daa2192
  |    Predecessors: 1:471f378eab4c 3:b7ea6d14e664
  |    semi-colon: 1:471f378eab4c; 3:b7ea6d14e664
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874", "b7ea6d14e664bdc8922221f7992631b50da3fb07"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874 3:b7ea6d14e664bdc8922221f7992631b50da3fb07
  |    Successors:
  |    multi-line:
  |    json: []
  | x  b7ea6d14e664
  | |    Predecessors: 2:0dec01379d3b
  | |    semi-colon: 2:0dec01379d3b
  | |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  | |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  | |    Successors: 4:eb5a0daa2192
  | |    multi-line: 4:eb5a0daa2192
  | |    json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  | | x  0dec01379d3b
  | |/     Predecessors:
  | |      semi-colon:
  | |      json: []
  | |      map:
  | |      Successors: 3:b7ea6d14e664
  | |      multi-line: 3:b7ea6d14e664
  | |      json: [["b7ea6d14e664bdc8922221f7992631b50da3fb07"]]
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 4:eb5a0daa2192
  |      multi-line: 4:eb5a0daa2192
  |      json: [["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog --hidden
  @  eb5a0daa2192
  |
  | x  b7ea6d14e664
  | |    Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  | | x  0dec01379d3b
  | |/     Obsfate: rewritten using amend as 3:b7ea6d14e664 by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  

  $ hg fatelogjson --hidden
  @  eb5a0daa2192
  |
  | x  b7ea6d14e664
  | |    Obsfate: [{"markers": [["b7ea6d14e664bdc8922221f7992631b50da3fb07", ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]}]
  | | x  0dec01379d3b
  | |/     Obsfate: [{"markers": [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", ["b7ea6d14e664bdc8922221f7992631b50da3fb07"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test"]], [0.0, 0], null]], "successors": ["b7ea6d14e664bdc8922221f7992631b50da3fb07"]}]
  | x  471f378eab4c
  |/     Obsfate: [{"markers": [["471f378eab4c5e25f6c77f785b27c936efb22874", ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["eb5a0daa21923bbf8caeb2c42085b9e463861fd0"]}]
  o  ea207398892e
  

Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  @  eb5a0daa2192
  |
  | x  b7ea6d14e664
  | |    Obsfate: rewritten as 4:eb5a0daa2192
  | | x  0dec01379d3b
  | |/     Obsfate: rewritten using amend as 3:b7ea6d14e664
  | x  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  @  eb5a0daa2192
  |
  | x  b7ea6d14e664
  | |    Obsfate: rewritten as 4:eb5a0daa2192
  | | x  0dec01379d3b
  | |/     Obsfate: rewritten using amend as 3:b7ea6d14e664
  | x  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  @  eb5a0daa2192
  |
  | x  b7ea6d14e664
  | |    Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000)
  | | x  0dec01379d3b
  | |/     Obsfate: rewritten using amend as 3:b7ea6d14e664 by test (at 1970-01-01 00:00 +0000)
  | x  471f378eab4c
  |/     Obsfate: rewritten as 4:eb5a0daa2192 by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  
  $ hg log -G -T "default" --hidden
  @  changeset:   4:eb5a0daa2192
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  | x  changeset:   3:b7ea6d14e664
  | |  parent:      1:471f378eab4c
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten as 4:eb5a0daa2192
  | |  summary:     B1
  | |
  | | x  changeset:   2:0dec01379d3b
  | |/   user:        test
  | |    date:        Thu Jan 01 00:00:00 1970 +0000
  | |    obsolete:    rewritten using amend as 3:b7ea6d14e664
  | |    summary:     B0
  | |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten as 4:eb5a0daa2192
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test template with pushed and pulled obs markers
================================================

Test setup
----------

  $ hg init $TESTTMP/templates-local-remote-markers-1
  $ cd $TESTTMP/templates-local-remote-markers-1
  $ mkcommit ROOT
  $ mkcommit A0
  $ hg clone $TESTTMP/templates-local-remote-markers-1 $TESTTMP/templates-local-remote-markers-2
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd $TESTTMP/templates-local-remote-markers-2
  $ hg log --hidden -G
  @  changeset:   1:471f378eab4c
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ cd $TESTTMP/templates-local-remote-markers-1
  $ hg commit --amend -m "A1"
  $ hg commit --amend -m "A2"
  $ hg log --hidden -G
  @  changeset:   3:7a230b46bf61
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | x  changeset:   2:fdf9bde5129a
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 3:7a230b46bf61
  |    summary:     A1
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:fdf9bde5129a
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ cd $TESTTMP/templates-local-remote-markers-2
  $ hg pull
  pulling from $TESTTMP/templates-local-remote-markers-1
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 1 files (+1 heads)
  2 new obsolescence markers
  obsoleted 1 changesets
  new changesets 7a230b46bf61 (1 drafts)
  (run 'hg heads' to see heads)
  $ hg log --hidden -G
  o  changeset:   2:7a230b46bf61
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | @  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:7a230b46bf61
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

  $ hg debugobsolete
  471f378eab4c5e25f6c77f785b27c936efb22874 fdf9bde5129a28d4548fadd3f62b265cdd3b7a2e 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  fdf9bde5129a28d4548fadd3f62b265cdd3b7a2e 7a230b46bf61e50b30308c6cfd7bd1269ef54702 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}

Check templates
---------------

Predecessors template should show current revision as it is the working copy
  $ hg tlog
  o  7a230b46bf61
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:7a230b46bf61
  |      multi-line: 2:7a230b46bf61
  |      json: [["7a230b46bf61e50b30308c6cfd7bd1269ef54702"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  7a230b46bf61
  |
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:7a230b46bf61 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up 'desc(A2)'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved

Predecessors template should show no predecessors as they are non visible
  $ hg tlog
  @  7a230b46bf61
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  @  7a230b46bf61
  |
  o  ea207398892e
  
Predecessors template should show all predecessors as we force their display
with --hidden
  $ hg tlog --hidden
  @  7a230b46bf61
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | x  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 2:7a230b46bf61
  |      multi-line: 2:7a230b46bf61
  |      json: [["7a230b46bf61e50b30308c6cfd7bd1269ef54702"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog --hidden
  @  7a230b46bf61
  |
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:7a230b46bf61 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  

Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  @  7a230b46bf61
  |
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:7a230b46bf61
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  @  7a230b46bf61
  |
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:7a230b46bf61
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  @  7a230b46bf61
  |
  | x  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:7a230b46bf61 by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  
  $ hg log -G -T "default" --hidden
  @  changeset:   2:7a230b46bf61
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A2
  |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:7a230b46bf61
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test template with obsmarkers cycle
===================================

Test setup
----------

  $ hg init $TESTTMP/templates-local-cycle
  $ cd $TESTTMP/templates-local-cycle
  $ mkcommit ROOT
  $ mkcommit A0
  $ mkcommit B0
  $ hg up -r 0
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ mkcommit C0
  created new head

Create the cycle

  $ hg debugobsolete `getid "desc(A0)"` `getid "desc(B0)"`
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new orphan changesets
  $ hg debugobsolete `getid "desc(B0)"` `getid "desc(C0)"`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid "desc(B0)"` `getid "desc(A0)"`
  1 new obsolescence markers

Check templates
---------------

  $ hg tlog
  @  f897c6137566
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  @  f897c6137566
  |
  o  ea207398892e
  

  $ hg up -r "desc(B0)" --hidden
  2 files updated, 0 files merged, 1 files removed, 0 files unresolved
  updated to hidden changeset 0dec01379d3b
  (hidden revision '0dec01379d3b' is pruned)
  $ hg tlog
  o  f897c6137566
  |    Predecessors: 2:0dec01379d3b
  |    semi-colon: 2:0dec01379d3b
  |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  |    Successors:
  |    multi-line:
  |    json: []
  | @  0dec01379d3b
  | |    Predecessors: 1:471f378eab4c
  | |    semi-colon: 1:471f378eab4c
  | |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  | |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  | |    Successors: 3:f897c6137566; 1:471f378eab4c
  | |    multi-line: 3:f897c6137566
  | |    multi-line: 1:471f378eab4c
  | |    json: [["f897c6137566320b081514b4c7227ecc3d384b39"], ["471f378eab4c5e25f6c77f785b27c936efb22874"]]
  | x  471f378eab4c
  |/     Predecessors: 2:0dec01379d3b
  |      semi-colon: 2:0dec01379d3b
  |      json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  |      map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  |      Successors: 2:0dec01379d3b
  |      multi-line: 2:0dec01379d3b
  |      json: [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  f897c6137566
  |
  | @  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566 by test (at 1970-01-01 00:00 +0000); rewritten as 1:471f378eab4c by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  

  $ hg up -r "desc(A0)" --hidden
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg tlog
  o  f897c6137566
  |    Predecessors: 1:471f378eab4c
  |    semi-colon: 1:471f378eab4c
  |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  |    Successors:
  |    multi-line:
  |    json: []
  | @  471f378eab4c
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors:
  |      multi-line:
  |      json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  f897c6137566
  |
  | @  471f378eab4c
  |/     Obsfate: pruned;
  o  ea207398892e
  

  $ hg up -r "desc(ROOT)" --hidden
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg tlog
  o  f897c6137566
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  @  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  o  f897c6137566
  |
  @  ea207398892e
  

  $ hg tlog --hidden
  o  f897c6137566
  |    Predecessors: 2:0dec01379d3b
  |    semi-colon: 2:0dec01379d3b
  |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  |    Successors:
  |    multi-line:
  |    json: []
  | x  0dec01379d3b
  | |    Predecessors: 1:471f378eab4c
  | |    semi-colon: 1:471f378eab4c
  | |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  | |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  | |    Successors: 3:f897c6137566; 1:471f378eab4c
  | |    multi-line: 3:f897c6137566
  | |    multi-line: 1:471f378eab4c
  | |    json: [["f897c6137566320b081514b4c7227ecc3d384b39"], ["471f378eab4c5e25f6c77f785b27c936efb22874"]]
  | x  471f378eab4c
  |/     Predecessors: 2:0dec01379d3b
  |      semi-colon: 2:0dec01379d3b
  |      json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  |      map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  |      Successors: 2:0dec01379d3b
  |      multi-line: 2:0dec01379d3b
  |      json: [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]]
  @  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566
  | |    Obsfate: rewritten as 1:471f378eab4c
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b
  @  ea207398892e
  
  $ hg fatelogkw --hidden
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566
  | |    Obsfate: rewritten as 1:471f378eab4c
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b
  @  ea207398892e
  
  $ hg fatelogkw --hidden -v
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566 by test (at 1970-01-01 00:00 +0000)
  | |    Obsfate: rewritten as 1:471f378eab4c by test (at 1970-01-01 00:00 +0000)
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b by test (at 1970-01-01 00:00 +0000)
  @  ea207398892e
  
  $ hg log -G -T "default" --hidden
  o  changeset:   3:f897c6137566
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  | x  changeset:   2:0dec01379d3b
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten as 3:f897c6137566
  | |  obsolete:    rewritten as 1:471f378eab4c
  | |  summary:     B0
  | |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten as 2:0dec01379d3b
  |    summary:     A0
  |
  @  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test template with split + divergence with cycles
=================================================

  $ hg log -G
  o  changeset:   3:f897c6137566
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  @  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Create a commit with three files
  $ touch A B C
  $ hg commit -A -m "Add A,B,C" A B C

Split it
  $ hg up 3
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ touch A
  $ hg commit -A -m "Add A,B,C" A
  created new head

  $ touch B
  $ hg commit -A -m "Add A,B,C" B

  $ touch C
  $ hg commit -A -m "Add A,B,C" C

  $ hg log -G
  @  changeset:   7:ba2ed02b0c9a
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     Add A,B,C
  |
  o  changeset:   6:4a004186e638
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     Add A,B,C
  |
  o  changeset:   5:dd800401bd8c
  |  parent:      3:f897c6137566
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     Add A,B,C
  |
  | o  changeset:   4:9bd10a0775e4
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     Add A,B,C
  |
  o  changeset:   3:f897c6137566
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
  $ hg debugobsolete `getid "4"` `getid "5"` `getid "6"` `getid "7"`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G
  @  changeset:   7:ba2ed02b0c9a
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     Add A,B,C
  |
  o  changeset:   6:4a004186e638
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     Add A,B,C
  |
  o  changeset:   5:dd800401bd8c
  |  parent:      3:f897c6137566
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     Add A,B,C
  |
  o  changeset:   3:f897c6137566
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Diverge one of the splitted commit

  $ hg up 6
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg commit --amend -m "Add only B"
  1 new orphan changesets

  $ hg up 6 --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit --amend -m "Add B only"
  4 new content-divergent changesets

  $ hg log -G
  @  changeset:   9:0b997eb7ceee
  |  tag:         tip
  |  parent:      5:dd800401bd8c
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     Add B only
  |
  | *  changeset:   8:b18bc8331526
  |/   parent:      5:dd800401bd8c
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    instability: content-divergent
  |    summary:     Add only B
  |
  | *  changeset:   7:ba2ed02b0c9a
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  instability: orphan, content-divergent
  | |  summary:     Add A,B,C
  | |
  | x  changeset:   6:4a004186e638
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 8:b18bc8331526
  |    obsolete:    rewritten using amend as 9:0b997eb7ceee
  |    summary:     Add A,B,C
  |
  *  changeset:   5:dd800401bd8c
  |  parent:      3:f897c6137566
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     Add A,B,C
  |
  o  changeset:   3:f897c6137566
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Check templates
---------------

  $ hg tlog
  @  0b997eb7ceee
  |    Predecessors: 6:4a004186e638
  |    semi-colon: 6:4a004186e638
  |    json: ["4a004186e63889f20cb16434fcbd72220bd1eace"]
  |    map: 6:4a004186e63889f20cb16434fcbd72220bd1eace
  |    Successors:
  |    multi-line:
  |    json: []
  | *  b18bc8331526
  |/     Predecessors: 6:4a004186e638
  |      semi-colon: 6:4a004186e638
  |      json: ["4a004186e63889f20cb16434fcbd72220bd1eace"]
  |      map: 6:4a004186e63889f20cb16434fcbd72220bd1eace
  |      Successors:
  |      multi-line:
  |      json: []
  | *  ba2ed02b0c9a
  | |    Predecessors:
  | |    semi-colon:
  | |    json: []
  | |    map:
  | |    Successors:
  | |    multi-line:
  | |    json: []
  | x  4a004186e638
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 8:b18bc8331526; 9:0b997eb7ceee
  |      multi-line: 8:b18bc8331526
  |      multi-line: 9:0b997eb7ceee
  |      json: [["b18bc8331526a22cbb1801022bd1555bf291c48b"], ["0b997eb7ceeee06200a02f8aab185979092d514e"]]
  *  dd800401bd8c
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  f897c6137566
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []
  $ hg fatelog
  @  0b997eb7ceee
  |
  | *  b18bc8331526
  |/
  | *  ba2ed02b0c9a
  | |
  | x  4a004186e638
  |/     Obsfate: rewritten using amend as 8:b18bc8331526 by test (at 1970-01-01 00:00 +0000); rewritten using amend as 9:0b997eb7ceee by test (at 1970-01-01 00:00 +0000);
  *  dd800401bd8c
  |
  o  f897c6137566
  |
  o  ea207398892e
  
  $ hg tlog --hidden
  @  0b997eb7ceee
  |    Predecessors: 6:4a004186e638
  |    semi-colon: 6:4a004186e638
  |    json: ["4a004186e63889f20cb16434fcbd72220bd1eace"]
  |    map: 6:4a004186e63889f20cb16434fcbd72220bd1eace
  |    Successors:
  |    multi-line:
  |    json: []
  | *  b18bc8331526
  |/     Predecessors: 6:4a004186e638
  |      semi-colon: 6:4a004186e638
  |      json: ["4a004186e63889f20cb16434fcbd72220bd1eace"]
  |      map: 6:4a004186e63889f20cb16434fcbd72220bd1eace
  |      Successors:
  |      multi-line:
  |      json: []
  | *  ba2ed02b0c9a
  | |    Predecessors: 4:9bd10a0775e4
  | |    semi-colon: 4:9bd10a0775e4
  | |    json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  | |    map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  | |    Successors:
  | |    multi-line:
  | |    json: []
  | x  4a004186e638
  |/     Predecessors: 4:9bd10a0775e4
  |      semi-colon: 4:9bd10a0775e4
  |      json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  |      map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  |      Successors: 8:b18bc8331526; 9:0b997eb7ceee
  |      multi-line: 8:b18bc8331526
  |      multi-line: 9:0b997eb7ceee
  |      json: [["b18bc8331526a22cbb1801022bd1555bf291c48b"], ["0b997eb7ceeee06200a02f8aab185979092d514e"]]
  *  dd800401bd8c
  |    Predecessors: 4:9bd10a0775e4
  |    semi-colon: 4:9bd10a0775e4
  |    json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  |    map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  |    Successors:
  |    multi-line:
  |    json: []
  | x  9bd10a0775e4
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 5:dd800401bd8c 6:4a004186e638 7:ba2ed02b0c9a
  |      multi-line: 5:dd800401bd8c 6:4a004186e638 7:ba2ed02b0c9a
  |      json: [["dd800401bd8c79d815329277739e433e883f784e", "4a004186e63889f20cb16434fcbd72220bd1eace", "ba2ed02b0c9a56b9fdbc4e79c7e57866984d8a1f"]]
  o  f897c6137566
  |    Predecessors: 2:0dec01379d3b
  |    semi-colon: 2:0dec01379d3b
  |    json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  |    map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  |    Successors:
  |    multi-line:
  |    json: []
  | x  0dec01379d3b
  | |    Predecessors: 1:471f378eab4c
  | |    semi-colon: 1:471f378eab4c
  | |    json: ["471f378eab4c5e25f6c77f785b27c936efb22874"]
  | |    map: 1:471f378eab4c5e25f6c77f785b27c936efb22874
  | |    Successors: 3:f897c6137566; 1:471f378eab4c
  | |    multi-line: 3:f897c6137566
  | |    multi-line: 1:471f378eab4c
  | |    json: [["f897c6137566320b081514b4c7227ecc3d384b39"], ["471f378eab4c5e25f6c77f785b27c936efb22874"]]
  | x  471f378eab4c
  |/     Predecessors: 2:0dec01379d3b
  |      semi-colon: 2:0dec01379d3b
  |      json: ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]
  |      map: 2:0dec01379d3be6318c470ead31b1fe7ae7cb53d5
  |      Successors: 2:0dec01379d3b
  |      multi-line: 2:0dec01379d3b
  |      json: [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]]
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []
  $ hg fatelog --hidden
  @  0b997eb7ceee
  |
  | *  b18bc8331526
  |/
  | *  ba2ed02b0c9a
  | |
  | x  4a004186e638
  |/     Obsfate: rewritten using amend as 8:b18bc8331526 by test (at 1970-01-01 00:00 +0000); rewritten using amend as 9:0b997eb7ceee by test (at 1970-01-01 00:00 +0000);
  *  dd800401bd8c
  |
  | x  9bd10a0775e4
  |/     Obsfate: split as 5:dd800401bd8c, 6:4a004186e638, 7:ba2ed02b0c9a by test (at 1970-01-01 00:00 +0000);
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566 by test (at 1970-01-01 00:00 +0000); rewritten as 1:471f378eab4c by test (at 1970-01-01 00:00 +0000);
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg fatelogjson --hidden
  @  0b997eb7ceee
  |
  | *  b18bc8331526
  |/
  | *  ba2ed02b0c9a
  | |
  | x  4a004186e638
  |/     Obsfate: [{"markers": [["4a004186e63889f20cb16434fcbd72220bd1eace", ["b18bc8331526a22cbb1801022bd1555bf291c48b"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test"]], [0.0, 0], null]], "successors": ["b18bc8331526a22cbb1801022bd1555bf291c48b"]}, {"markers": [["4a004186e63889f20cb16434fcbd72220bd1eace", ["0b997eb7ceeee06200a02f8aab185979092d514e"], 0, [["ef1", "1"], ["operation", "amend"], ["user", "test"]], [0.0, 0], null]], "successors": ["0b997eb7ceeee06200a02f8aab185979092d514e"]}]
  *  dd800401bd8c
  |
  | x  9bd10a0775e4
  |/     Obsfate: [{"markers": [["9bd10a0775e478708cada5f176ec6de654359ce7", ["dd800401bd8c79d815329277739e433e883f784e", "4a004186e63889f20cb16434fcbd72220bd1eace", "ba2ed02b0c9a56b9fdbc4e79c7e57866984d8a1f"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["dd800401bd8c79d815329277739e433e883f784e", "4a004186e63889f20cb16434fcbd72220bd1eace", "ba2ed02b0c9a56b9fdbc4e79c7e57866984d8a1f"]}]
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: [{"markers": [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", ["f897c6137566320b081514b4c7227ecc3d384b39"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["f897c6137566320b081514b4c7227ecc3d384b39"]}, {"markers": [["0dec01379d3be6318c470ead31b1fe7ae7cb53d5", ["471f378eab4c5e25f6c77f785b27c936efb22874"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["471f378eab4c5e25f6c77f785b27c936efb22874"]}]
  | x  471f378eab4c
  |/     Obsfate: [{"markers": [["471f378eab4c5e25f6c77f785b27c936efb22874", ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"], 0, [["user", "test"]], [0.0, 0], null]], "successors": ["0dec01379d3be6318c470ead31b1fe7ae7cb53d5"]}]
  o  ea207398892e
  
  $ hg up --hidden 4
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 9bd10a0775e4
  (hidden revision '9bd10a0775e4' has diverged)
  $ hg rebase -r 7 -d 8 --config extensions.rebase=
  rebasing 7:ba2ed02b0c9a "Add A,B,C"
  $ hg tlog
  *  eceed8f98ffc
  |    Predecessors: 4:9bd10a0775e4
  |    semi-colon: 4:9bd10a0775e4
  |    json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  |    map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  |    Successors:
  |    multi-line:
  |    json: []
  | *  0b997eb7ceee
  | |    Predecessors: 4:9bd10a0775e4
  | |    semi-colon: 4:9bd10a0775e4
  | |    json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  | |    map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  | |    Successors:
  | |    multi-line:
  | |    json: []
  * |  b18bc8331526
  |/     Predecessors: 4:9bd10a0775e4
  |      semi-colon: 4:9bd10a0775e4
  |      json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  |      map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  |      Successors:
  |      multi-line:
  |      json: []
  *  dd800401bd8c
  |    Predecessors: 4:9bd10a0775e4
  |    semi-colon: 4:9bd10a0775e4
  |    json: ["9bd10a0775e478708cada5f176ec6de654359ce7"]
  |    map: 4:9bd10a0775e478708cada5f176ec6de654359ce7
  |    Successors:
  |    multi-line:
  |    json: []
  | @  9bd10a0775e4
  |/     Predecessors:
  |      semi-colon:
  |      json: []
  |      map:
  |      Successors: 5:dd800401bd8c 9:0b997eb7ceee 10:eceed8f98ffc; 5:dd800401bd8c 8:b18bc8331526 10:eceed8f98ffc
  |      multi-line: 5:dd800401bd8c 9:0b997eb7ceee 10:eceed8f98ffc
  |      multi-line: 5:dd800401bd8c 8:b18bc8331526 10:eceed8f98ffc
  |      json: [["dd800401bd8c79d815329277739e433e883f784e", "0b997eb7ceeee06200a02f8aab185979092d514e", "eceed8f98ffc4186032e29a6542ab98888ebf68d"], ["dd800401bd8c79d815329277739e433e883f784e", "b18bc8331526a22cbb1801022bd1555bf291c48b", "eceed8f98ffc4186032e29a6542ab98888ebf68d"]]
  o  f897c6137566
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

  $ hg fatelog
  *  eceed8f98ffc
  |
  | *  0b997eb7ceee
  | |
  * |  b18bc8331526
  |/
  *  dd800401bd8c
  |
  | @  9bd10a0775e4
  |/     Obsfate: split using amend, rebase as 5:dd800401bd8c, 9:0b997eb7ceee, 10:eceed8f98ffc by test (at 1970-01-01 00:00 +0000); split using amend, rebase as 5:dd800401bd8c, 8:b18bc8331526, 10:eceed8f98ffc by test (at 1970-01-01 00:00 +0000);
  o  f897c6137566
  |
  o  ea207398892e
  
Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  *  eceed8f98ffc
  |
  | *  0b997eb7ceee
  | |
  * |  b18bc8331526
  |/
  | x  ba2ed02b0c9a
  | |    Obsfate: rewritten using rebase as 10:eceed8f98ffc
  | x  4a004186e638
  |/     Obsfate: rewritten using amend as 8:b18bc8331526
  |      Obsfate: rewritten using amend as 9:0b997eb7ceee
  *  dd800401bd8c
  |
  | @  9bd10a0775e4
  |/     Obsfate: split as 5:dd800401bd8c, 6:4a004186e638, 7:ba2ed02b0c9a
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566
  | |    Obsfate: rewritten as 1:471f378eab4c
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  *  eceed8f98ffc
  |
  | *  0b997eb7ceee
  | |
  * |  b18bc8331526
  |/
  | x  ba2ed02b0c9a
  | |    Obsfate: rewritten using rebase as 10:eceed8f98ffc
  | x  4a004186e638
  |/     Obsfate: rewritten using amend as 8:b18bc8331526
  |      Obsfate: rewritten using amend as 9:0b997eb7ceee
  *  dd800401bd8c
  |
  | @  9bd10a0775e4
  |/     Obsfate: split as 5:dd800401bd8c, 6:4a004186e638, 7:ba2ed02b0c9a
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566
  | |    Obsfate: rewritten as 1:471f378eab4c
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  *  eceed8f98ffc
  |
  | *  0b997eb7ceee
  | |
  * |  b18bc8331526
  |/
  | x  ba2ed02b0c9a
  | |    Obsfate: rewritten using rebase as 10:eceed8f98ffc by test (at 1970-01-01 00:00 +0000)
  | x  4a004186e638
  |/     Obsfate: rewritten using amend as 8:b18bc8331526 by test (at 1970-01-01 00:00 +0000)
  |      Obsfate: rewritten using amend as 9:0b997eb7ceee by test (at 1970-01-01 00:00 +0000)
  *  dd800401bd8c
  |
  | @  9bd10a0775e4
  |/     Obsfate: split as 5:dd800401bd8c, 6:4a004186e638, 7:ba2ed02b0c9a by test (at 1970-01-01 00:00 +0000)
  o  f897c6137566
  |
  | x  0dec01379d3b
  | |    Obsfate: rewritten as 3:f897c6137566 by test (at 1970-01-01 00:00 +0000)
  | |    Obsfate: rewritten as 1:471f378eab4c by test (at 1970-01-01 00:00 +0000)
  | x  471f378eab4c
  |/     Obsfate: rewritten as 2:0dec01379d3b by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  
  $ hg log -G -T "default" --hidden
  *  changeset:   10:eceed8f98ffc
  |  tag:         tip
  |  parent:      8:b18bc8331526
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     Add A,B,C
  |
  | *  changeset:   9:0b997eb7ceee
  | |  parent:      5:dd800401bd8c
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  instability: content-divergent
  | |  summary:     Add B only
  | |
  * |  changeset:   8:b18bc8331526
  |/   parent:      5:dd800401bd8c
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    instability: content-divergent
  |    summary:     Add only B
  |
  | x  changeset:   7:ba2ed02b0c9a
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten using rebase as 10:eceed8f98ffc
  | |  summary:     Add A,B,C
  | |
  | x  changeset:   6:4a004186e638
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 8:b18bc8331526
  |    obsolete:    rewritten using amend as 9:0b997eb7ceee
  |    summary:     Add A,B,C
  |
  *  changeset:   5:dd800401bd8c
  |  parent:      3:f897c6137566
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  instability: content-divergent
  |  summary:     Add A,B,C
  |
  | @  changeset:   4:9bd10a0775e4
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    split as 5:dd800401bd8c, 6:4a004186e638, 7:ba2ed02b0c9a
  |    summary:     Add A,B,C
  |
  o  changeset:   3:f897c6137566
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     C0
  |
  | x  changeset:   2:0dec01379d3b
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  obsolete:    rewritten as 3:f897c6137566
  | |  obsolete:    rewritten as 1:471f378eab4c
  | |  summary:     B0
  | |
  | x  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten as 2:0dec01379d3b
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test templates with pruned commits
==================================

Test setup
----------

  $ hg init $TESTTMP/templates-local-prune
  $ cd $TESTTMP/templates-local-prune
  $ mkcommit ROOT
  $ mkcommit A0
  $ hg debugobsolete --record-parent `getid "."`
  1 new obsolescence markers
  obsoleted 1 changesets

Check output
------------

  $ hg up "desc(A0)" --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg tlog
  @  471f378eab4c
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []
  $ hg fatelog
  @  471f378eab4c
  |    Obsfate: pruned by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
Test templates with multiple pruned commits
===========================================

Test setup
----------

  $ hg init $TESTTMP/multiple-local-prune
  $ cd $TESTTMP/multiple-local-prune
  $ mkcommit ROOT
  $ mkcommit A0
  $ hg commit --amend -m "A1"
  $ hg debugobsolete --record-parent `getid "."`
  1 new obsolescence markers
  obsoleted 1 changesets

  $ hg up -r "desc(A0)" --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' is pruned)
  $ hg commit --amend -m "A2"
  $ hg debugobsolete --record-parent `getid "."`
  1 new obsolescence markers
  obsoleted 1 changesets

Check output
------------

  $ hg up "desc(A0)" --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471f378eab4c
  (hidden revision '471f378eab4c' is pruned)
  $ hg tlog
  @  471f378eab4c
  |    Predecessors:
  |    semi-colon:
  |    json: []
  |    map:
  |    Successors:
  |    multi-line:
  |    json: []
  o  ea207398892e
       Predecessors:
       semi-colon:
       json: []
       map:
       Successors:
       multi-line:
       json: []

# todo: the obsfate output is not ideal
  $ hg fatelog
  @  471f378eab4c
  |    Obsfate: pruned;
  o  ea207398892e
  
  $ hg fatelog --hidden
  x  65b757b745b9
  |    Obsfate: pruned by test (at 1970-01-01 00:00 +0000);
  | x  fdf9bde5129a
  |/     Obsfate: pruned by test (at 1970-01-01 00:00 +0000);
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a by test (at 1970-01-01 00:00 +0000); rewritten using amend as 3:65b757b745b9 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  x  65b757b745b9
  |    Obsfate: pruned
  | x  fdf9bde5129a
  |/     Obsfate: pruned
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a
  |      Obsfate: rewritten using amend as 3:65b757b745b9
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  x  65b757b745b9
  |    Obsfate: pruned
  | x  fdf9bde5129a
  |/     Obsfate: pruned
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a
  |      Obsfate: rewritten using amend as 3:65b757b745b9
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  x  65b757b745b9
  |    Obsfate: pruned by test (at 1970-01-01 00:00 +0000)
  | x  fdf9bde5129a
  |/     Obsfate: pruned by test (at 1970-01-01 00:00 +0000)
  | @  471f378eab4c
  |/     Obsfate: rewritten using amend as 2:fdf9bde5129a by test (at 1970-01-01 00:00 +0000)
  |      Obsfate: rewritten using amend as 3:65b757b745b9 by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  

  $ hg log -G -T "default" --hidden
  x  changeset:   3:65b757b745b9
  |  tag:         tip
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  obsolete:    pruned
  |  summary:     A2
  |
  | x  changeset:   2:fdf9bde5129a
  |/   parent:      0:ea207398892e
  |    user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    pruned
  |    summary:     A1
  |
  | @  changeset:   1:471f378eab4c
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    rewritten using amend as 2:fdf9bde5129a
  |    obsolete:    rewritten using amend as 3:65b757b745b9
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Check that {negrev} shows usable negative revisions despite hidden commits

  $ hg log -G -T "{negrev}\n"
  @  -3
  |
  o  -4
  

  $ hg log -G -T "{negrev}\n" --hidden
  x  -1
  |
  | x  -2
  |/
  | @  -3
  |/
  o  -4
  

Test templates with splitted and pruned commit
==============================================

  $ hg init $TESTTMP/templates-local-split-prune
  $ cd $TESTTMP/templates-local-split-prune
  $ mkcommit ROOT
  $ echo 42 >> a
  $ echo 43 >> b
  $ hg commit -A -m "A0"
  adding a
  adding b
  $ hg log --hidden -G
  @  changeset:   1:471597cad322
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
# Simulate split
  $ hg up -r "desc(ROOT)"
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo 42 >> a
  $ hg commit -A -m "A1"
  adding a
  created new head
  $ echo 43 >> b
  $ hg commit -A -m "A2"
  adding b
  $ hg debugobsolete `getid "1"` `getid "2"` `getid "3"`
  1 new obsolescence markers
  obsoleted 1 changesets

# Simulate prune
  $ hg debugobsolete --record-parent `getid "."`
  1 new obsolescence markers
  obsoleted 1 changesets

  $ hg log --hidden -G
  @  changeset:   3:0d0ef4bdf70e
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  obsolete:    pruned
  |  summary:     A2
  |
  o  changeset:   2:617adc3a144c
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A1
  |
  | x  changeset:   1:471597cad322
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    split as 2:617adc3a144c, 3:0d0ef4bdf70e
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  
Check templates
---------------

  $ hg up 'desc("A0")' --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 471597cad322
  (hidden revision '471597cad322' was rewritten as: 617adc3a144c)

# todo: the obsfate output is not ideal
  $ hg fatelog
  o  617adc3a144c
  |
  | @  471597cad322
  |/     Obsfate: rewritten as 2:617adc3a144c by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg up -r 'desc("A2")' --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 0d0ef4bdf70e
  (hidden revision '0d0ef4bdf70e' is pruned)

  $ hg fatelog --hidden
  @  0d0ef4bdf70e
  |    Obsfate: pruned by test (at 1970-01-01 00:00 +0000);
  o  617adc3a144c
  |
  | x  471597cad322
  |/     Obsfate: split as 2:617adc3a144c, 3:0d0ef4bdf70e by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  

Check other fatelog implementations
-----------------------------------

  $ hg fatelogkw --hidden -q
  @  0d0ef4bdf70e
  |    Obsfate: pruned
  o  617adc3a144c
  |
  | x  471597cad322
  |/     Obsfate: split as 2:617adc3a144c, 3:0d0ef4bdf70e
  o  ea207398892e
  
  $ hg fatelogkw --hidden
  @  0d0ef4bdf70e
  |    Obsfate: pruned
  o  617adc3a144c
  |
  | x  471597cad322
  |/     Obsfate: split as 2:617adc3a144c, 3:0d0ef4bdf70e
  o  ea207398892e
  
  $ hg fatelogkw --hidden -v
  @  0d0ef4bdf70e
  |    Obsfate: pruned by test (at 1970-01-01 00:00 +0000)
  o  617adc3a144c
  |
  | x  471597cad322
  |/     Obsfate: split as 2:617adc3a144c, 3:0d0ef4bdf70e by test (at 1970-01-01 00:00 +0000)
  o  ea207398892e
  
  $ hg log -G -T "default" --hidden
  @  changeset:   3:0d0ef4bdf70e
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  obsolete:    pruned
  |  summary:     A2
  |
  o  changeset:   2:617adc3a144c
  |  parent:      0:ea207398892e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     A1
  |
  | x  changeset:   1:471597cad322
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    obsolete:    split as 2:617adc3a144c, 3:0d0ef4bdf70e
  |    summary:     A0
  |
  o  changeset:   0:ea207398892e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     ROOT
  

Test metadata encoding (issue5754)
==================================

  $ hg init $TESTTMP/metadata-encoding
  $ cd $TESTTMP/metadata-encoding
  $ cat <<'EOF' >> .hg/hgrc
  > [extensions]
  > amend =
  > EOF
  $ "$PYTHON" <<'EOF'
  > with open('test1', 'wb') as f:
  >    f.write(b't\xe8st1') and None
  > with open('test2', 'wb') as f:
  >    f.write(b't\xe8st2') and None
  > EOF
  $ mkcommit ROOT
  $ ( HGENCODING=latin-1 HGUSER="`cat test1`" mkcommit A0 )
  $ echo 42 >> A0
  $ HGENCODING=latin-1 hg amend -m "A1" --note "`cat test2`"
  $ HGENCODING=latin-1 hg amend -m "A2" \
  > --config devel.user.obsmarker="`cat test2`"
  $ mkcommit B0
  $ HGENCODING=latin-1 hg debugobsolete -u "`cat test2`" "`getid 'desc(B0)'`"
  1 new obsolescence markers
  obsoleted 1 changesets

metadata should be stored in UTF-8, and debugobsolete doesn't decode it to
local encoding since the command is supposed to show unmodified content:

  $ HGENCODING=latin-1 hg debugobsolete
  5f66a482f0bb2fcaccfc215554ad5eb9f40b50f5 718c0d00cee1429bdb73064e0d88908c601507a8 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '9', 'note': 't\xc3\xa8st2', 'operation': 'amend', 'user': 'test'}
  718c0d00cee1429bdb73064e0d88908c601507a8 1132562159b35bb27e1d6b80c80ee94a1659a4da 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 't\xc3\xa8st2'}
  8f82db6f991db367fdbb3b6dba5e187ecc3ebd96 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 't\xc3\xa8st2'}

metadata should be converted back to local encoding when displaying:

  $ HGENCODING=latin-1 hg fatelog --hidden
  @  8f82db6f991d
  |    Obsfate: pruned by t\xe8st2 (at 1970-01-01 00:00 +0000); (esc)
  o  1132562159b3
  |
  | x  718c0d00cee1
  |/     Obsfate: rewritten using amend as 3:1132562159b3 by t\xe8st2 (at 1970-01-01 00:00 +0000); (esc)
  | x  5f66a482f0bb
  |/     Obsfate: rewritten using amend as 2:718c0d00cee1 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ HGENCODING=utf-8 hg fatelog --hidden
  @  8f82db6f991d
  |    Obsfate: pruned by t\xc3\xa8st2 (at 1970-01-01 00:00 +0000); (esc)
  o  1132562159b3
  |
  | x  718c0d00cee1
  |/     Obsfate: rewritten using amend as 3:1132562159b3 by t\xc3\xa8st2 (at 1970-01-01 00:00 +0000); (esc)
  | x  5f66a482f0bb
  |/     Obsfate: rewritten using amend as 2:718c0d00cee1 by test (at 1970-01-01 00:00 +0000);
  o  ea207398892e
  
  $ hg log -G -T "{negrev}\n"
  @  -1
  |
  o  -2
  |
  o  -5
  
