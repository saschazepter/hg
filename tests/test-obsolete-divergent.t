Test file dedicated to testing the divergent troubles from obsolete changeset.

This is the most complex troubles from far so we isolate it in a dedicated
file.

Enable obsolete

  $ cat >> $HGRCPATH << EOF
  > [ui]
  > logtemplate = {rev}:{node|short} {desc}{if(obsfate, " [{join(obsfate, "; ")}]")}\n
  > [experimental]
  > evolution.createmarkers=True
  > [extensions]
  > drawdag=$TESTDIR/drawdag.py
  > [alias]
  > debugobsolete = debugobsolete -d '0 0'
  > [phases]
  > publish=False
  > [templates]
  > wuentryshort = '{instability}:{if(divergentnodes, " ")}{divergentnodes} {reason} {node|shortest}\n'
  > whyunstableshort = '{whyunstable % wuentryshort}'
  > wuentryshorter = '{instability}:{divergentnodes % " {node|shortest} ({phase})"} {reason} {node|shortest}\n'
  > whyunstableshorter = '{whyunstable % wuentryshorter}'
  > EOF


  $ mkcommit() {
  >    echo "$1" > "$1"
  >    hg add "$1"
  >    hg ci -m "$1"
  > }
  $ getid() {
  >    hg log --hidden -r "desc('$1')" -T '{node}\n'
  > }

setup repo

  $ hg init reference
  $ cd reference
  $ mkcommit base
  $ mkcommit A_0
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit A_1
  created new head
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit A_2
  created new head
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ cd ..


  $ newcase() {
  >    hg clone -u 0 -q reference $1
  >    cd $1
  > }

direct divergence
-----------------

A_1 have two direct and divergent successors A_1 and A_1

  $ newcase direct
  $ hg debugobsolete `getid A_0` `getid A_1`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_0` `getid A_2`
  1 new obsolescence markers
  2 new content-divergent changesets
  $ hg log -G --hidden
  *  3:392fd25390da A_2
  |
  | *  2:82623d38b9ba A_1
  |/
  | x  1:007dc284c1f8 A_0 [rewritten as 2:82623d38b9ba; rewritten as 3:392fd25390da]
  |/
  @  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ hg log -r 'contentdivergent()'
  2:82623d38b9ba A_1
  3:392fd25390da A_2
  $ hg log -r 'unstable()'
  2:82623d38b9ba A_1
  3:392fd25390da A_2
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da

check that mercurial refuse to push

  $ hg init ../other
  $ hg push ../other
  pushing to ../other
  searching for changes
  abort: push includes content-divergent changeset: 392fd25390da!
  [255]

  $ cd ..


indirect divergence with known changeset
-------------------------------------------

  $ newcase indirect_known
  $ hg debugobsolete `getid A_0` `getid A_1`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_0` `getid A_2`
  1 new obsolescence markers
  2 new content-divergent changesets
  $ mkcommit A_3
  created new head
  $ hg debugobsolete `getid A_2` `getid A_3`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G --hidden
  @  4:01f36c5a8fda A_3
  |
  | x  3:392fd25390da A_2 [rewritten as 4:01f36c5a8fda]
  |/
  | *  2:82623d38b9ba A_1
  |/
  | x  1:007dc284c1f8 A_0 [rewritten as 2:82623d38b9ba; rewritten as 3:392fd25390da]
  |/
  o  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      01f36c5a8fda
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      01f36c5a8fda
  01f36c5a8fda
      01f36c5a8fda
  $ hg log -r 'contentdivergent()'
  2:82623d38b9ba A_1
  4:01f36c5a8fda A_3
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  82623d38b9ba
      82623d38b9ba
  01f36c5a8fda
      01f36c5a8fda
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  01f36c5a8fda
      01f36c5a8fda
  $ cd ..


indirect divergence with known changeset
-------------------------------------------

  $ newcase indirect_unknown
  $ hg debugobsolete `getid A_0` aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa `getid A_1`
  1 new obsolescence markers
  $ hg debugobsolete `getid A_0` `getid A_2`
  1 new obsolescence markers
  2 new content-divergent changesets
  $ hg log -G --hidden
  *  3:392fd25390da A_2
  |
  | *  2:82623d38b9ba A_1
  |/
  | x  1:007dc284c1f8 A_0 [rewritten as 2:82623d38b9ba; rewritten as 3:392fd25390da]
  |/
  @  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ hg log -r 'contentdivergent()'
  2:82623d38b9ba A_1
  3:392fd25390da A_2
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ cd ..

do not take unknown node in account if they are final
-----------------------------------------------------

  $ newcase final-unknown
  $ hg debugobsolete `getid A_0` `getid A_1`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_1` `getid A_2`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_0` bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  1 new obsolescence markers
  $ hg debugobsolete bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb cccccccccccccccccccccccccccccccccccccccc
  1 new obsolescence markers
  $ hg debugobsolete `getid A_1` dddddddddddddddddddddddddddddddddddddddd
  1 new obsolescence markers

  $ hg debugsuccessorssets --hidden 'desc('A_0')'
  007dc284c1f8
      392fd25390da
  $ hg debugsuccessorssets 'desc('A_0')' --closest
  $ hg debugsuccessorssets 'desc('A_0')' --closest --hidden
  007dc284c1f8
      82623d38b9ba

  $ cd ..

divergence that converge again is not divergence anymore
-----------------------------------------------------

  $ newcase converged_divergence
  $ hg debugobsolete `getid A_0` `getid A_1`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_0` `getid A_2`
  1 new obsolescence markers
  2 new content-divergent changesets
  $ mkcommit A_3
  created new head
  $ hg debugobsolete `getid A_1` `getid A_3`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_2` `getid A_3`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G --hidden
  @  4:01f36c5a8fda A_3
  |
  | x  3:392fd25390da A_2 [rewritten as 4:01f36c5a8fda]
  |/
  | x  2:82623d38b9ba A_1 [rewritten as 4:01f36c5a8fda]
  |/
  | x  1:007dc284c1f8 A_0 [rewritten as 2:82623d38b9ba; rewritten as 3:392fd25390da]
  |/
  o  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      01f36c5a8fda
  82623d38b9ba
      01f36c5a8fda
  392fd25390da
      01f36c5a8fda
  01f36c5a8fda
      01f36c5a8fda
  $ hg log -r 'contentdivergent()'
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  01f36c5a8fda
      01f36c5a8fda
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba
      392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  01f36c5a8fda
      01f36c5a8fda
  $ cd ..

split is not divergences
-----------------------------

  $ newcase split
  $ hg debugobsolete `getid A_0` `getid A_1` `getid A_2`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G --hidden
  o  3:392fd25390da A_2
  |
  | o  2:82623d38b9ba A_1
  |/
  | x  1:007dc284c1f8 A_0 [split as 2:82623d38b9ba, 3:392fd25390da]
  |/
  @  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba 392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ hg log -r 'contentdivergent()'
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba 392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da

Even when subsequent rewriting happen

  $ mkcommit A_3
  created new head
  $ hg debugobsolete `getid A_1` `getid A_3`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit A_4
  created new head
  $ hg debugobsolete `getid A_2` `getid A_4`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit A_5
  created new head
  $ hg debugobsolete `getid A_4` `getid A_5`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G --hidden
  @  6:e442cfc57690 A_5
  |
  | x  5:6a411f0d7a0a A_4 [rewritten as 6:e442cfc57690]
  |/
  | o  4:01f36c5a8fda A_3
  |/
  | x  3:392fd25390da A_2 [rewritten as 5:6a411f0d7a0a]
  |/
  | x  2:82623d38b9ba A_1 [rewritten as 4:01f36c5a8fda]
  |/
  | x  1:007dc284c1f8 A_0 [split as 2:82623d38b9ba, 3:392fd25390da]
  |/
  o  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      01f36c5a8fda e442cfc57690
  82623d38b9ba
      01f36c5a8fda
  392fd25390da
      e442cfc57690
  01f36c5a8fda
      01f36c5a8fda
  6a411f0d7a0a
      e442cfc57690
  e442cfc57690
      e442cfc57690
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  01f36c5a8fda
      01f36c5a8fda
  e442cfc57690
      e442cfc57690
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba 392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  01f36c5a8fda
      01f36c5a8fda
  6a411f0d7a0a
      e442cfc57690
  e442cfc57690
      e442cfc57690
  $ hg log -r 'contentdivergent()'

Check more complex obsolescence graft (with divergence)

  $ mkcommit B_0; hg up 0
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg debugobsolete `getid B_0` `getid A_2`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ mkcommit A_7; hg up 0
  created new head
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit A_8; hg up 0
  created new head
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg debugobsolete `getid A_5` `getid A_7` `getid A_8`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ mkcommit A_9; hg up 0
  created new head
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg debugobsolete `getid A_5` `getid A_9`
  1 new obsolescence markers
  4 new content-divergent changesets
  $ hg log -G --hidden
  *  10:bed64f5d2f5a A_9
  |
  | *  9:14608b260df8 A_8
  |/
  | *  8:7ae126973a96 A_7
  |/
  | x  7:3750ebee865d B_0 [rewritten as 3:392fd25390da]
  | |
  | x  6:e442cfc57690 A_5 [rewritten as 10:bed64f5d2f5a; split as 8:7ae126973a96, 9:14608b260df8]
  |/
  | x  5:6a411f0d7a0a A_4 [rewritten as 6:e442cfc57690]
  |/
  | *  4:01f36c5a8fda A_3
  |/
  | x  3:392fd25390da A_2 [rewritten as 5:6a411f0d7a0a]
  |/
  | x  2:82623d38b9ba A_1 [rewritten as 4:01f36c5a8fda]
  |/
  | x  1:007dc284c1f8 A_0 [split as 2:82623d38b9ba, 3:392fd25390da]
  |/
  @  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      01f36c5a8fda bed64f5d2f5a
      01f36c5a8fda 7ae126973a96 14608b260df8
  82623d38b9ba
      01f36c5a8fda
  392fd25390da
      bed64f5d2f5a
      7ae126973a96 14608b260df8
  01f36c5a8fda
      01f36c5a8fda
  6a411f0d7a0a
      bed64f5d2f5a
      7ae126973a96 14608b260df8
  e442cfc57690
      bed64f5d2f5a
      7ae126973a96 14608b260df8
  3750ebee865d
      bed64f5d2f5a
      7ae126973a96 14608b260df8
  7ae126973a96
      7ae126973a96
  14608b260df8
      14608b260df8
  bed64f5d2f5a
      bed64f5d2f5a
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  01f36c5a8fda
      01f36c5a8fda
  7ae126973a96
      7ae126973a96
  14608b260df8
      14608b260df8
  bed64f5d2f5a
      bed64f5d2f5a
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba 392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  01f36c5a8fda
      01f36c5a8fda
  6a411f0d7a0a
      e442cfc57690
  e442cfc57690
      e442cfc57690
  3750ebee865d
      392fd25390da
  7ae126973a96
      7ae126973a96
  14608b260df8
      14608b260df8
  bed64f5d2f5a
      bed64f5d2f5a
  $ hg log -r 'contentdivergent()'
  4:01f36c5a8fda A_3
  8:7ae126973a96 A_7
  9:14608b260df8 A_8
  10:bed64f5d2f5a A_9

  $ hg log -r bed64f5d2f5a -T '{whyunstable}\n' | sort
  content-divergent: 4:01f36c5a8fda (draft) 8:7ae126973a96 (draft) 9:14608b260df8 (draft) predecessor 007dc284c1f8
  content-divergent: 8:7ae126973a96 (draft) 9:14608b260df8 (draft) predecessor e442cfc57690
  $ hg log -r bed64f5d2f5a -T whyunstableshort | sort
  content-divergent: 4:01f36c5a8fda (draft) 8:7ae126973a96 (draft) 9:14608b260df8 (draft) predecessor 007d
  content-divergent: 8:7ae126973a96 (draft) 9:14608b260df8 (draft) predecessor e442
  $ hg log -r bed64f5d2f5a -T whyunstableshorter | sort
  content-divergent: 01f3 (draft) 7ae1 (draft) 1460 (draft) predecessor 007d
  content-divergent: 7ae1 (draft) 1460 (draft) predecessor e442

fix the divergence

  $ mkcommit A_A; hg up 0
  created new head
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg debugobsolete `getid A_9` `getid A_A`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_7` `getid A_A`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_8` `getid A_A`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G --hidden
  o  11:a139f71be9da A_A
  |
  | x  10:bed64f5d2f5a A_9 [rewritten as 11:a139f71be9da]
  |/
  | x  9:14608b260df8 A_8 [rewritten as 11:a139f71be9da]
  |/
  | x  8:7ae126973a96 A_7 [rewritten as 11:a139f71be9da]
  |/
  | x  7:3750ebee865d B_0 [rewritten as 3:392fd25390da]
  | |
  | x  6:e442cfc57690 A_5 [rewritten as 10:bed64f5d2f5a; split as 8:7ae126973a96, 9:14608b260df8]
  |/
  | x  5:6a411f0d7a0a A_4 [rewritten as 6:e442cfc57690]
  |/
  | o  4:01f36c5a8fda A_3
  |/
  | x  3:392fd25390da A_2 [rewritten as 5:6a411f0d7a0a]
  |/
  | x  2:82623d38b9ba A_1 [rewritten as 4:01f36c5a8fda]
  |/
  | x  1:007dc284c1f8 A_0 [split as 2:82623d38b9ba, 3:392fd25390da]
  |/
  @  0:d20a80d4def3 base
  
  $ hg debugsuccessorssets --hidden 'all()'
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      01f36c5a8fda a139f71be9da
  82623d38b9ba
      01f36c5a8fda
  392fd25390da
      a139f71be9da
  01f36c5a8fda
      01f36c5a8fda
  6a411f0d7a0a
      a139f71be9da
  e442cfc57690
      a139f71be9da
  3750ebee865d
      a139f71be9da
  7ae126973a96
      a139f71be9da
  14608b260df8
      a139f71be9da
  bed64f5d2f5a
      a139f71be9da
  a139f71be9da
      a139f71be9da
  $ hg debugsuccessorssets 'all()' --closest
  d20a80d4def3
      d20a80d4def3
  01f36c5a8fda
      01f36c5a8fda
  a139f71be9da
      a139f71be9da
  $ hg debugsuccessorssets 'all()' --closest --hidden
  d20a80d4def3
      d20a80d4def3
  007dc284c1f8
      82623d38b9ba 392fd25390da
  82623d38b9ba
      82623d38b9ba
  392fd25390da
      392fd25390da
  01f36c5a8fda
      01f36c5a8fda
  6a411f0d7a0a
      e442cfc57690
  e442cfc57690
      e442cfc57690
  3750ebee865d
      392fd25390da
  7ae126973a96
      a139f71be9da
  14608b260df8
      a139f71be9da
  bed64f5d2f5a
      a139f71be9da
  a139f71be9da
      a139f71be9da
  $ hg log -r 'contentdivergent()'

#if serve

  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid --config web.view=all \
  >   -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

check an obsolete changeset that was rewritten and also split

  $ get-with-headers.py localhost:$HGPORT 'rev/e442cfc57690?style=paper' | egrep 'rewritten|split'
   <td>rewritten as <a href="/rev/bed64f5d2f5a?style=paper">bed64f5d2f5a</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span><br>
  split as <a href="/rev/7ae126973a96?style=paper">7ae126973a96</a> <a href="/rev/14608b260df8?style=paper">14608b260df8</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/e442cfc57690?style=coal' | egrep 'rewritten|split'
   <td>rewritten as <a href="/rev/bed64f5d2f5a?style=coal">bed64f5d2f5a</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span><br>
  split as <a href="/rev/7ae126973a96?style=coal">7ae126973a96</a> <a href="/rev/14608b260df8?style=coal">14608b260df8</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/e442cfc57690?style=gitweb' | egrep 'rewritten|split'
  <td>rewritten as <a class="list" href="/rev/bed64f5d2f5a?style=gitweb">bed64f5d2f5a</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>
  <td>split as <a class="list" href="/rev/7ae126973a96?style=gitweb">7ae126973a96</a> <a class="list" href="/rev/14608b260df8?style=gitweb">14608b260df8</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/e442cfc57690?style=monoblue' | egrep 'rewritten|split'
  <dd>rewritten as <a href="/rev/bed64f5d2f5a?style=monoblue">bed64f5d2f5a</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></dd>
  <dd>split as <a href="/rev/7ae126973a96?style=monoblue">7ae126973a96</a> <a href="/rev/14608b260df8?style=monoblue">14608b260df8</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></dd>
  $ get-with-headers.py localhost:$HGPORT 'rev/e442cfc57690?style=spartan' | egrep 'rewritten|split'
  <td class="obsolete">rewritten as <a href="/rev/bed64f5d2f5a?style=spartan">bed64f5d2f5a</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>
  <td class="obsolete">split as <a href="/rev/7ae126973a96?style=spartan">7ae126973a96</a> <a href="/rev/14608b260df8?style=spartan">14608b260df8</a>  by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>

  $ killdaemons.py

#endif

  $ cd ..


Subset does not diverge
------------------------------

Do not report divergent successors-set if it is a subset of another
successors-set. (report [A,B] not [A] + [A,B])

  $ newcase subset
  $ hg debugobsolete `getid A_0` `getid A_2`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete `getid A_0` `getid A_1` `getid A_2`
  1 new obsolescence markers
  $ hg debugsuccessorssets --hidden 'desc('A_0')'
  007dc284c1f8
      82623d38b9ba 392fd25390da
  $ hg debugsuccessorssets 'desc('A_0')' --closest
  $ hg debugsuccessorssets 'desc('A_0')' --closest --hidden
  007dc284c1f8
      82623d38b9ba 392fd25390da

  $ cd ..

Use scmutil.cleanupnodes API to create divergence

  $ hg init cleanupnodes
  $ cd cleanupnodes
  $ hg debugdrawdag <<'EOS'
  >   B1  B3 B4
  >   |     \|
  >   A      Z
  > EOS

  $ hg update -q B1
  $ echo 3 >> B
  $ hg commit --amend -m B2
  $ cat > $TESTTMP/scmutilcleanup.py <<EOF
  > from mercurial import registrar, scmutil
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b'cleanup')
  > def cleanup(ui, repo):
  >     def node(expr):
  >         unfi = repo.unfiltered()
  >         rev = unfi.revs(expr).first()
  >         return unfi.changelog.node(rev)
  >     with repo.wlock(), repo.lock(), repo.transaction(b'delayedstrip'):
  >         mapping = {node(b'desc(B1)'): [node(b'desc(B3)')],
  >                    node(b'desc(B3)'): [node(b'desc(B4)')]}
  >         scmutil.cleanupnodes(repo, mapping, b'test')
  > EOF

  $ rm .hg/localtags
  $ hg cleanup --config extensions.t=$TESTTMP/scmutilcleanup.py
  2 new content-divergent changesets
  $ hg log -G -T '{rev}:{node|short} {desc} {instabilities}' -r 'sort(all(), topo)'
  @  5:1a2a9b5b0030 B2 content-divergent
  |
  | *  4:70d5a63ca112 B4 content-divergent
  | |
  | o  1:48b9aae0607f Z
  |
  o  0:426bada5c675 A
  
  $ hg debugobsolete
  a178212c3433c4e77b573f6011e29affb8aefa33 1a2a9b5b0030632400aa78e00388c20f99d3ec44 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  a178212c3433c4e77b573f6011e29affb8aefa33 ad6478fb94ecec98b86daae98722865d494ac561 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '13', 'operation': 'test', 'user': 'test'}
  ad6478fb94ecec98b86daae98722865d494ac561 70d5a63ca112acb3764bc1d7320ca90ea688d671 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '9', 'operation': 'test', 'user': 'test'}

  $ hg debugwhyunstable 1a2a9b5b0030
  content-divergent: 70d5a63ca112acb3764bc1d7320ca90ea688d671 (draft) predecessor a178212c3433c4e77b573f6011e29affb8aefa33

  $ hg log -r 1a2a9b5b0030 -T '{whyunstable}\n'
  content-divergent: 4:70d5a63ca112 (draft) predecessor a178212c3433
  $ hg log -r 1a2a9b5b0030 -T whyunstableshort
  content-divergent: 4:70d5a63ca112 (draft) predecessor a178
  $ hg log -r 1a2a9b5b0030 -T whyunstableshorter
  content-divergent: 70d5 (draft) predecessor a178

#if serve

  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

check explanation for a content-divergent changeset

  $ get-with-headers.py localhost:$HGPORT 'rev/1a2a9b5b0030?style=paper' | grep divergent:
   <td>content-divergent: <a href="/rev/70d5a63ca112?style=paper">70d5a63ca112</a> (draft) predecessor <a href="/rev/a178212c3433?style=paper">a178212c3433</a></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/1a2a9b5b0030?style=coal' | grep divergent:
   <td>content-divergent: <a href="/rev/70d5a63ca112?style=coal">70d5a63ca112</a> (draft) predecessor <a href="/rev/a178212c3433?style=coal">a178212c3433</a></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/1a2a9b5b0030?style=gitweb' | grep divergent:
  <td>content-divergent: <a class="list" href="/rev/70d5a63ca112?style=gitweb">70d5a63ca112</a> (draft) predecessor <a class="list" href="/rev/a178212c3433?style=gitweb">a178212c3433</a></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/1a2a9b5b0030?style=monoblue' | grep divergent:
  <dd>content-divergent: <a href="/rev/70d5a63ca112?style=monoblue">70d5a63ca112</a> (draft) predecessor <a href="/rev/a178212c3433?style=monoblue">a178212c3433</a></dd>
  $ get-with-headers.py localhost:$HGPORT 'rev/1a2a9b5b0030?style=spartan' | grep divergent:
  <td class="unstable">content-divergent: <a href="/rev/70d5a63ca112?style=spartan">70d5a63ca112</a> (draft) predecessor <a href="/rev/a178212c3433?style=spartan">a178212c3433</a></td>

  $ killdaemons.py

#endif
