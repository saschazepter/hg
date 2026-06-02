A repo with unknown revlogv2 requirement string cannot be opened

  $ hg init invalidreq
  $ cd invalidreq
  $ echo exp-revlogv2.unknown >> .hg/requires
  $ hg log
  abort: repository requires features unknown to this Mercurial: exp-revlogv2.unknown
  (see https://mercurial-scm.org/wiki/MissingRequirement for more information)
  [255]
  $ cd ..

Can create and open repo with revlog v2 requirement

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > revlogv2 = enable-unstable-format-and-corrupt-my-data
  > [storage]
  > fileindex.slow-path=allow
  > EOF

  $ hg init new-repo
  $ cd new-repo
  $ hg debugrequires | grep revlogv2
  exp-revlogv2.2
  dirstate-v2 (dirstate-v2 !)

  $ hg log

Unknown flags to revlog are rejected

  >>> with open('.hg/store/00changelog.i', 'wb') as fh:
  ...     fh.write(b'\xff\x00\xde\xad') and None

  $ hg log
  abort: unknown flags (0xff00) in version 57005 revlog 00changelog
  [50]

  $ cd ..

Writing a simple revlog v2 works

  $ hg init simple
  $ cd simple
  $ touch foo
  $ hg -q commit -A -m initial

  $ hg log
  changeset:   0:96ee1d7354c4
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     initial
  

Header written as expected

  $ f --hexdump --bytes 4 .hg/store/00manifest.i
  .hg/store/00manifest.i:
  0000: 00 00 de ad                                     |....|

  $ f --hexdump --bytes 4 .hg/store/data/foo.i
  .hg/store/data/foo.i:
  0000: 00 00 de ad                                     |....|

Bundle use a compatible changegroup format
------------------------------------------

  $ hg bundle --all ../basic.hg
  1 changesets found
  $ hg debugbundle --spec ../basic.hg
  bzip2-v2

The expected files are generated
--------------------------------

We should have have:
- a docket
- a index file with a unique name
- a data file

  $ ls .hg/store/00changelog* .hg/store/00manifest*
  .hg/store/00changelog-43c37dde.i01
  .hg/store/00changelog-5e69c5d1.sda
  .hg/store/00changelog-619c4819.dat
  .hg/store/00changelog-6594c487.str
  .hg/store/00changelog-69d069c3.ist
  .hg/store/00changelog-e2c9362a.i02
  .hg/store/00changelog-ea337809.cgf
  .hg/store/00changelog.i
  .hg/store/00manifest-539ee172.sda
  .hg/store/00manifest-7f2eb713.dat
  .hg/store/00manifest-88163688.i01
  .hg/store/00manifest-9b3fc813.i02
  .hg/store/00manifest-a2b86225.lkr
  .hg/store/00manifest.i

Local clone works
-----------------

  $ hg clone . ../cloned-repo
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg tip | tee ../tip-new
  changeset:   0:96ee1d7354c4
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     initial
  
  $ hg tip -R ../cloned-repo | tee ../tip-cloned
  changeset:   0:96ee1d7354c4
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     initial
  

The two repository should be identical, this diff MUST be empty

  $ cmp ../tip-new ../tip-cloned || diff -U8 ../tip-new ../tip-cloned


hg verify should be happy
-------------------------

  $ hg verify -q

  $ hg verify -R ../cloned-repo -q


Link revs are properly tracked
=============================

Store a file with multiple version of itself

  $ echo babar > foo
  $ hg -q commit -m first-left
  $ hg up --quiet '.~1'
  $ echo babar > foo
  $ hg -q commit -m first-right
  $ echo celeste > foo
  $ hg -q commit -m second-right
  $ hg up 'desc("first-left")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo celeste > foo
  $ hg -q commit -m second-left
  $ hg up --quiet 'desc(initial)'
  $ echo babar > foo
  $ hg -q commit -m first-middle
  $ echo celeste > foo
  $ hg -q commit -m second-middle
  $ hg up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg log -Gv
  o  changeset:   6:bdd5c2bd9da1
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       foo
  |  description:
  |  second-middle
  |
  |
  o  changeset:   5:abfa5d7b3859
  |  parent:      0:96ee1d7354c4
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  files:       foo
  |  description:
  |  first-middle
  |
  |
  | o  changeset:   4:1817c66e5efc
  | |  parent:      1:3cd31802617e
  | |  user:        test
  | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | |  files:       foo
  | |  description:
  | |  second-left
  | |
  | |
  | | o  changeset:   3:5e3d11883c7b
  | | |  user:        test
  | | |  date:        Thu Jan 01 00:00:00 1970 +0000
  | | |  files:       foo
  | | |  description:
  | | |  second-right
  | | |
  | | |
  +---o  changeset:   2:fa1eb91ce219
  | |    parent:      0:96ee1d7354c4
  | |    user:        test
  | |    date:        Thu Jan 01 00:00:00 1970 +0000
  | |    files:       foo
  | |    description:
  | |    first-right
  | |
  | |
  | o  changeset:   1:3cd31802617e
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    files:       foo
  |    description:
  |    first-left
  |
  |
  o  changeset:   0:96ee1d7354c4
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     files:       foo
     description:
     initial
  
  

  $ hg log -G --rev 'desc("second-left")' foo --follow
  o  changeset:   4:1817c66e5efc
  |  parent:      1:3cd31802617e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     second-left
  |
  o  changeset:   1:3cd31802617e
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     first-left
  |
  o  changeset:   0:96ee1d7354c4
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  
  $ hg log -G --rev 'desc("second-right")' foo --follow
  o  changeset:   3:5e3d11883c7b
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     second-right
  |
  o  changeset:   2:fa1eb91ce219
  |  parent:      0:96ee1d7354c4
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     first-right
  |
  o  changeset:   0:96ee1d7354c4
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  
  $ hg log -G --rev 'desc("second-middle")' foo --follow
  o  changeset:   6:bdd5c2bd9da1
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     second-middle
  |
  o  changeset:   5:abfa5d7b3859
  |  parent:      0:96ee1d7354c4
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     first-middle
  |
  o  changeset:   0:96ee1d7354c4
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initial
  

Checking on disk data
.....................

The recorded data should make sense.

  $ hg debug::link-revs -m
  0: 0 (0)
    - 0
  1: 1 (5)
    - 5
    - 2
    - 1
  2: 3 (6)
    - 6
    - 4
    - 3
  $ hg debug::link-revs --dump-raw -m
  0: 0 0
  1: 1 1
  2: 2 1
  3: 3 3
  4: 4 3
  5: 5 2
  6: 6 4

  $ hg debug::link-revs foo
  0: 0 (0)
    - 0
  1: 1 (5)
    - 5
    - 2
    - 1
  2: 3 (6)
    - 6
    - 4
    - 3
  $ hg debug::link-revs --dump-raw foo
  0: 0 0
  1: 1 1
  2: 2 1
  3: 3 3
  4: 4 3
  5: 5 2
  6: 6 4
