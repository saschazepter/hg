=============================================================
Rebasing a merge must keep the filelog ancestry of both sides
=============================================================

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > rebase=
  > [phases]
  > publish=False
  > EOF

  $ hg init repo1
  $ cd repo1

Change a file in "default" and in "dev" and then merge

  $ printf 'a\nb\nc\nd\ne\nf\ng\n' > f
  $ hg ci -Aqm 'base'

  $ printf 'a-default\nb\nc\nd\ne\nf\ng\n' > f
  $ hg ci -qm 'default: change the first line'

  $ hg up -q 0
  $ printf 'a\nb\nc\nd\ne\nf\ng-dev\n' > f
  $ hg ci -qm 'dev: change the last line'

  $ hg up -q 1
  $ hg merge -q 2
  $ hg ci -qm 'default: merge dev'

The merge creates a filenode with two parents

  $ hg debugindex f
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 e7f741756072 000000000000 000000000000
       1       1 d5071b2f4759 e7f741756072 000000000000
       2       2 d5e55be20c50 e7f741756072 000000000000
       3       3 6a5497802a89 d5071b2f4759 d5e55be20c50

Annotate works correctly for lines added on both sides of the merge

  $ hg annotate f
  1: a-default
  0: b
  0: c
  0: d
  0: e
  0: f
  2: g-dev

Make a copy for the second test below

  $ cd ..
  $ hg clone -q repo1 repo2

Rebase the merge (file unchanged)
---------------------------------

Now another changeset lands on "default" without touching f,
and we rebase the merge.

  $ cd repo1
  $ hg up -q 1
  $ echo stuff > other
  $ hg ci -Aqm 'default: unrelated change'
  $ hg rebase -q -r 3 -d 4
  $ hg log -G --template "{rev}: {node|short} '{desc}'\n"
  o    4: 78f4d39eaf91 'default: merge dev'
  |\
  | @  3: 7da032ef483b 'default: unrelated change'
  | |
  o |  2: e04e8438e532 'dev: change the last line'
  | |
  | o  1: e60d22330540 'default: change the first line'
  |/
  o  0: fcf660dfd7a3 'base'
  

The rebased merge must keep both parents in the filelog

  $ hg debugindex f
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 e7f741756072 000000000000 000000000000
       1       1 d5071b2f4759 e7f741756072 000000000000
       2       2 d5e55be20c50 e7f741756072 000000000000
       3       4 6a5497802a89 d5071b2f4759 d5e55be20c50

  $ hg annotate -r 4 f
  1: a-default
  0: b
  0: c
  0: d
  0: e
  0: f
  2: g-dev

  $ cd ..

Rebase the merge (file changed)
-------------------------------

Now another changeset lands on "default" that changes f,
and we rebase the merge.

  $ cd repo2
  $ hg up -q 1
  $ printf 'a-default\nb\nc\nd-default\ne\nf\ng\n' > f
  $ hg ci -qm 'default: change the middle line'
  $ hg rebase -q -r 3 -d 4
  $ hg log -G --template "{rev}: {node|short} '{desc}'\n"
  o    4: 0a99544c5e23 'default: merge dev'
  |\
  | @  3: c81ae926c65a 'default: change the middle line'
  | |
  o |  2: e04e8438e532 'dev: change the last line'
  | |
  | o  1: e60d22330540 'default: change the first line'
  |/
  o  0: fcf660dfd7a3 'base'
  

The rebased merge must keep both parents in the filelog

  $ hg debugindex f
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 e7f741756072 000000000000 000000000000
       1       1 d5071b2f4759 e7f741756072 000000000000
       2       2 d5e55be20c50 e7f741756072 000000000000
       3       3 836ba97f6a05 d5071b2f4759 000000000000
       4       4 ab9bea552b0b 836ba97f6a05 d5e55be20c50

  $ hg annotate -r 4 f
  1: a-default
  0: b
  0: c
  3: d-default
  0: e
  0: f
  2: g-dev

  $ cd ..
