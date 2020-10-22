Tests rebasing with part of the rebase set already in the
destination (issue5422)

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > rebase=
  > drawdag=$TESTDIR/drawdag.py
  > 
  > [experimental]
  > evolution.createmarkers=True
  > evolution.allowunstable=True
  > 
  > [alias]
  > tglog = log -G --template "{rev}: {node|short} {desc}"
  > EOF

  $ rebasewithdag() {
  >   N=`"$PYTHON" -c "print($N+1)"`
  >   hg init repo$N && cd repo$N
  >   hg debugdrawdag
  >   hg rebase "$@" > _rebasetmp
  >   r=$?
  >   grep -v 'saved backup bundle' _rebasetmp
  >   [ $r -eq 0 ] && hg tglog
  >   cd ..
  >   return $r
  > }

Rebase two commits, of which one is already in the right place

  $ rebasewithdag -r C+D -d B <<EOF
  > C
  > |
  > B D
  > |/
  > A
  > EOF
  rebasing 2:b18e25de2cf5 D "D"
  already rebased 3:26805aba1e60 C tip "C"
  o  4: fe3b4c6498fa D
  |
  | o  3: 26805aba1e60 C
  |/
  | x  2: b18e25de2cf5 D
  | |
  o |  1: 112478962961 B
  |/
  o  0: 426bada5c675 A
  
Can collapse commits even if one is already in the right place

  $ rebasewithdag --collapse -r C+D -d B <<EOF
  > C
  > |
  > B D
  > |/
  > A
  > EOF
  rebasing 2:b18e25de2cf5 D "D"
  rebasing 3:26805aba1e60 C tip "C"
  o  4: a2493f4ace65 Collapsed revision
  |  * D
  |  * C
  | x  3: 26805aba1e60 C
  |/
  | x  2: b18e25de2cf5 D
  | |
  o |  1: 112478962961 B
  |/
  o  0: 426bada5c675 A
  
Abort doesn't lose the commits that were already in the right place

  $ hg init abort
  $ cd abort
  $ hg debugdrawdag <<EOF
  > C
  > |
  > B D  # B/file = B
  > |/   # D/file = D
  > A
  > EOF
  $ hg rebase -r C+D -d B
  rebasing 2:ef8c0fe0897b D "D"
  merging file
  warning: conflicts while merging file! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]
  $ hg rebase --abort
  rebase aborted
  $ hg tglog
  o  3: 79f6d6ab7b14 C
  |
  | o  2: ef8c0fe0897b D
  | |
  o |  1: 594087dbaf71 B
  |/
  o  0: 426bada5c675 A
  
  $ cd ..

Rebase with "holes". The commits after the hole should end up on the parent of
the hole (B below), not on top of the destination (A).

  $ rebasewithdag -r B+D -d A <<EOF
  > D
  > |
  > C
  > |
  > B
  > |
  > A
  > EOF
  already rebased 1:112478962961 B "B"
  rebasing 3:f585351a92f8 D tip "D"
  o  4: 1e6da8103bc7 D
  |
  | x  3: f585351a92f8 D
  | |
  | o  2: 26805aba1e60 C
  |/
  o  1: 112478962961 B
  |
  o  0: 426bada5c675 A
  
