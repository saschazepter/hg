  $ cat >> $HGRCPATH << EOF
  > [phases]
  > # public changeset are not obsolete
  > publish=false
  > [ui]
  > logtemplate="{rev}:{node|short} ({phase}{if(obsolete, ' *{obsolete}*')}{if(instabilities, ' {instabilities}')}) [{tags} {bookmarks}] {desc|firstline}{if(obsfate, " [{join(obsfate, "; ")}]")}\n"
  > EOF
  $ mkcommit() {
  >    echo "$1" > "$1"
  >    hg add "$1"
  >    hg ci -m "add $1"
  > }
  $ getid() {
  >    hg log -T "{node}\n" --hidden -r "desc('$1')"
  > }

  $ cat > debugkeys.py <<EOF
  > def reposetup(ui, repo):
  >     class debugkeysrepo(repo.__class__):
  >         def listkeys(self, namespace):
  >             ui.write(b'listkeys %s\n' % (namespace,))
  >             return super(debugkeysrepo, self).listkeys(namespace)
  > 
  >     if repo.local():
  >         repo.__class__ = debugkeysrepo
  > EOF

  $ hg init tmpa
  $ cd tmpa
  $ mkcommit kill_me

Checking that the feature is properly disabled

  $ hg debugobsolete -d '0 0' `getid kill_me` -u babar
  abort: creating obsolete markers is not enabled on this repo
  [255]

Enabling it

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution=exchange
  > evolution.createmarkers=True
  > EOF

Killing a single changeset without replacement

  $ hg debugobsolete 0
  abort: changeset references must be full hexadecimal node identifiers
  [10]
  $ hg debugobsolete '00'
  abort: changeset references must be full hexadecimal node identifiers
  [10]
  $ hg debugobsolete -d '0 0' `getid kill_me` -u babar
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete
  97b7c2d76b1845ed3eb988cd612611e72406cef0 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'babar'}

(test that mercurial is not confused)

  $ hg up null --quiet # having 0 as parent prevents it to be hidden
  $ hg tip
  -1:000000000000 (public) [tip ] 
  $ hg up --hidden tip --quiet
  updated to hidden changeset 97b7c2d76b18
  (hidden revision '97b7c2d76b18' is pruned)

Killing a single changeset with itself should fail
(simple local safeguard)

  $ hg debugobsolete `getid kill_me` `getid kill_me`
  abort: bad obsmarker input: in-marker cycle with 97b7c2d76b1845ed3eb988cd612611e72406cef0
  [255]

  $ cd ..

Killing a single changeset with replacement
(and testing the format option)

  $ hg init tmpb
  $ cd tmpb
  $ mkcommit a
  $ mkcommit b
  $ mkcommit original_c
  $ hg up "desc('b')"
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit new_c
  created new head
  $ hg log -r 'hidden()' --template '{rev}:{node|short} {desc}\n' --hidden
  $ hg debugobsolete --config format.obsstore-version=0 --flag 12 `getid original_c`  `getid new_c` -d '121 120'
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -r 'hidden()' --template '{rev}:{node|short} {desc}\n' --hidden
  2:245bde4270cd add original_c
  $ hg debugrevlog -cd
  # rev p1rev p2rev start   end deltastart base   p1   p2 rawsize totalsize compression heads chainlen
      0    -1    -1     0    59          0    0    0    0      58        58           0     1        0
      1     0    -1    59   118         59   59    0    0      58       116           0     1        0
      2     1    -1   118   193        118  118   59    0      76       192           0     1        0 (no-zstd !)
      3     1    -1   193   260        193  193   59    0      66       258           0     2        0 (no-zstd !)
      2     1    -1   118   195        118  118   59    0      76       192           0     1        0 (zstd !)
      3     1    -1   195   262        195  195   59    0      66       258           0     2        0 (zstd !)
  $ hg debugobsolete
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}

(check for version number of the obsstore)

  $ dd bs=1 count=1 if=.hg/store/obsstore 2>/dev/null
  \x00 (no-eol) (esc)

do it again (it read the obsstore before adding new changeset)

  $ hg up '.^'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit new_2_c
  created new head
  $ hg debugobsolete -d '1337 0' `getid new_c` `getid new_2_c`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}

Register two markers with a missing node

  $ hg up '.^'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit new_3_c
  created new head
  $ hg debugobsolete -d '1338 0' `getid new_2_c` 1337133713371337133713371337133713371337
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete -d '1339 0' 1337133713371337133713371337133713371337 `getid new_3_c`
  1 new obsolescence markers
  $ hg debugobsolete
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}

Test the --index option of debugobsolete command
  $ hg debugobsolete --index
  0 245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  1 cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  2 ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  3 1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}

Refuse pathological nullid successors
  $ hg debugobsolete -d '9001 0' 1337133713371337133713371337133713371337 0000000000000000000000000000000000000000
  transaction abort!
  rollback completed
  abort: bad obsolescence marker detected: invalid successors nullid
  [255]

Check that graphlog detect that a changeset is obsolete:

  $ hg log -G
  @  5:5601fb93a350 (draft) [tip ] add new_3_c
  |
  o  1:7c3bad9141dc (draft) [ ] add b
  |
  o  0:1f0dee641bb7 (draft) [ ] add a
  

check that heads does not report them

  $ hg heads
  5:5601fb93a350 (draft) [tip ] add new_3_c
  $ hg heads --hidden
  5:5601fb93a350 (draft) [tip ] add new_3_c

check that summary does not report them

  $ hg init ../sink
  $ echo '[paths]' >> .hg/hgrc
  $ echo 'default=../sink' >> .hg/hgrc
  $ hg summary --remote
  parent: 5:5601fb93a350 tip
   add new_3_c
  branch: default
  commit: (clean)
  update: (current)
  phases: 3 draft
  remote: 3 outgoing

  $ hg summary --remote --hidden
  parent: 5:5601fb93a350 tip
   add new_3_c
  branch: default
  commit: (clean)
  update: (current)
  phases: 6 draft
  remote: 3 outgoing

check that various commands work well with filtering

  $ hg tip
  5:5601fb93a350 (draft) [tip ] add new_3_c
  $ hg log -r 6
  abort: unknown revision '6'
  [10]
  $ hg log -r 4
  abort: hidden revision '4' was rewritten as: 5601fb93a350
  (use --hidden to access hidden revisions)
  [10]
  $ hg debugrevspec 'rev(6)'
  $ hg debugrevspec 'rev(4)'
  $ hg debugrevspec 'null'
  -1

Check that public changeset are not accounted as obsolete:

  $ hg --hidden phase --public 2
  1 new phase-divergent changesets
  $ hg log -G
  @  5:5601fb93a350 (draft phase-divergent) [tip ] add new_3_c
  |
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  
  $ hg log -r 'unstable()'
  5:5601fb93a350 (draft phase-divergent) [tip ] add new_3_c


And that bumped changeset are detected
--------------------------------------

If we didn't filtered obsolete changesets out, 3 and 4 would show up too. Also
note that the bumped changeset (5:5601fb93a350) is not a direct successor of
the public changeset

  $ hg log --hidden -r 'phasedivergent()'
  5:5601fb93a350 (draft phase-divergent) [tip ] add new_3_c

And that we can't push bumped changeset

  $ hg push ../tmpa -r 0 --force #(make repo related)
  pushing to ../tmpa
  searching for changes
  warning: repository is unrelated
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  $ hg push ../tmpa
  pushing to ../tmpa
  searching for changes
  abort: push includes phase-divergent changeset: 5601fb93a350!
  [255]

Fixing "bumped" situation
We need to create a clone of 5 and add a special marker with a flag

  $ hg summary
  parent: 5:5601fb93a350 tip (phase-divergent)
   add new_3_c
  branch: default
  commit: (clean)
  update: 1 new changesets, 2 branch heads (merge)
  phases: 1 draft
  phase-divergent: 1 changesets
  $ hg up '5^'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg revert -ar 5
  adding new_3_c
  $ hg ci -m 'add n3w_3_c'
  created new head
  $ hg debugobsolete -d '1338 0' --flags 1 `getid new_3_c` `getid n3w_3_c`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -r 'phasedivergent()'
  $ hg log -G
  @  6:6f9641995072 (draft) [tip ] add n3w_3_c
  |
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  

Basic exclusive testing

  $ hg log -G --hidden
  @  6:6f9641995072 (draft) [tip ] add n3w_3_c
  |
  | x  5:5601fb93a350 (draft *obsolete*) [ ] add new_3_c [rewritten as 6:6f9641995072]
  |/
  | x  4:ca819180edb9 (draft *obsolete*) [ ] add new_2_c [rewritten as 5:5601fb93a350]
  |/
  | x  3:cdbce2fbb163 (draft *obsolete*) [ ] add new_c [rewritten as 4:ca819180edb9]
  |/
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  
  $ hg debugobsolete --rev 6f9641995072
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  $ hg debugobsolete --rev 6f9641995072 --exclusive
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  $ hg debugobsolete --rev 5601fb93a350 --hidden
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  $ hg debugobsolete --rev 5601fb93a350 --hidden --exclusive
  $ hg debugobsolete --rev 5601fb93a350+6f9641995072 --hidden --exclusive
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}

  $ cd ..

Revision 0 is hidden
--------------------

  $ hg init rev0hidden
  $ cd rev0hidden

  $ mkcommit kill0
  $ hg up -q null
  $ hg debugobsolete `getid kill0`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ mkcommit a
  $ mkcommit b

Should pick the first visible revision as "repo" node

  $ hg archive ../archive-null
  $ cat ../archive-null/.hg_archival.txt
  repo: 1f0dee641bb7258c56bd60e93edfa2405381c41e
  node: 7c3bad9141dcb46ff89abf5f61856facd56e476c
  branch: default
  latesttag: null
  latesttagdistance: 2
  changessincelatesttag: 2


  $ cd ..

Can disable transaction summary report

  $ hg init transaction-summary
  $ cd transaction-summary
  $ mkcommit a
  $ mkcommit b
  $ hg up -q null
  $ hg --config experimental.evolution.report-instabilities=false debugobsolete `getid a`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ cd ..

Exchange Test
============================

Destination repo does not have any data
---------------------------------------

Simple incoming test

  $ hg init tmpc
  $ cd tmpc
  $ hg incoming ../tmpb
  comparing with ../tmpb
  0:1f0dee641bb7 (public) [ ] add a
  1:7c3bad9141dc (public) [ ] add b
  2:245bde4270cd (public) [ ] add original_c
  6:6f9641995072 (draft) [tip ] add n3w_3_c

Try to pull markers while testing pull --confirm
(extinct changeset are excluded but marker are pushed)

  $ hg pull ../tmpb --confirm --config ui.interactive=true <<EOF
  > n
  > EOF
  pulling from ../tmpb
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  adding 4 changesets with 4 changes to 4 files (+1 heads)
  5 new obsolescence markers
  new changesets 1f0dee641bb7:6f9641995072 (1 drafts)
  accept incoming changes (yn)? n
  transaction abort!
  rollback completed
  abort: user aborted
  [255]
  $ HGPLAIN=1 hg pull ../tmpb --confirm --config ui.interactive=true <<EOF
  > n
  > EOF
  pulling from ../tmpb
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  adding 4 changesets with 4 changes to 4 files (+1 heads)
  5 new obsolescence markers
  new changesets 1f0dee641bb7:6f9641995072 (1 drafts)
  accept incoming changes (yn)? n
  transaction abort!
  rollback completed
  abort: user aborted
  [255]
  $ hg pull ../tmpb --confirm --config ui.interactive=true <<EOF
  > y
  > EOF
  pulling from ../tmpb
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  adding 4 changesets with 4 changes to 4 files (+1 heads)
  5 new obsolescence markers
  new changesets 1f0dee641bb7:6f9641995072 (1 drafts)
  accept incoming changes (yn)? y
  added 4 changesets with 4 changes to 4 files (+1 heads)
  5 new obsolescence markers
  new changesets 1f0dee641bb7:6f9641995072 (1 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg debugobsolete
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}

Rollback//Transaction support

  $ hg debugobsolete -d '1340 0' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  1 new obsolescence markers
  $ hg debugobsolete
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0 (Thu Jan 01 00:22:20 1970 +0000) {'user': 'test'}
  $ hg rollback -n
  repository tip rolled back to revision 3 (undo debugobsolete)
  $ hg rollback
  repository tip rolled back to revision 3 (undo debugobsolete)
  $ hg debugobsolete
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}

  $ cd ..

Try to push markers

  $ hg init tmpd
  $ hg -R tmpb push tmpd
  pushing to tmpd
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 4 files (+1 heads)
  5 new obsolescence markers
  $ hg -R tmpd debugobsolete | sort
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}

Check obsolete keys are exchanged only if source has an obsolete store

  $ hg init empty
  $ hg --config extensions.debugkeys=debugkeys.py -R empty push tmpd
  pushing to tmpd
  listkeys phases
  listkeys bookmarks
  no changes found
  listkeys phases
  [1]

clone support
(markers are copied and extinct changesets are included to allow hardlinks)

  $ hg clone tmpb clone-dest
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R clone-dest log -G --hidden
  @  6:6f9641995072 (draft) [tip ] add n3w_3_c
  |
  | x  5:5601fb93a350 (draft *obsolete*) [ ] add new_3_c [rewritten as 6:6f9641995072]
  |/
  | x  4:ca819180edb9 (draft *obsolete*) [ ] add new_2_c [rewritten as 5:5601fb93a350]
  |/
  | x  3:cdbce2fbb163 (draft *obsolete*) [ ] add new_c [rewritten as 4:ca819180edb9]
  |/
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  
  $ hg -R clone-dest debugobsolete
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}


Destination repo have existing data
---------------------------------------

On pull

  $ hg init tmpe
  $ cd tmpe
  $ hg debugobsolete -d '1339 0' 1339133913391339133913391339133913391339 ca819180edb99ed25ceafb3e9584ac287e240b00
  1 new obsolescence markers
  $ hg pull ../tmpb
  pulling from ../tmpb
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 4 files (+1 heads)
  5 new obsolescence markers
  new changesets 1f0dee641bb7:6f9641995072 (1 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg debugobsolete
  1339133913391339133913391339133913391339 ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}


On push

  $ hg push ../tmpc
  pushing to ../tmpc
  searching for changes
  no changes found
  1 new obsolescence markers
  [1]
  $ hg -R ../tmpc debugobsolete
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  1339133913391339133913391339133913391339 ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}

detect outgoing obsolete and unstable
---------------------------------------


  $ hg log -G
  o  3:6f9641995072 (draft) [tip ] add n3w_3_c
  |
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  
  $ hg up 'desc("n3w_3_c")'
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ mkcommit original_d
  $ mkcommit original_e
  $ hg debugobsolete --record-parents `getid original_d` -d '0 0'
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new orphan changesets
  $ hg log -r 'unstable()'
  5:cda648ca50f5 (draft orphan) [tip ] add original_e
  $ hg debugobsolete | grep `getid original_d`
  94b33453f93bdb8d457ef9b770851a618bf413e1 0 {6f96419950729f3671185b847352890f074f7557} (Thu Jan 01 00:00:00 1970 +0000) {'user': 'test'}
  $ hg log -r 'obsolete()'
  4:94b33453f93b (draft *obsolete*) [ ] add original_d [pruned]
  $ hg summary
  parent: 5:cda648ca50f5 tip (orphan)
   add original_e
  branch: default
  commit: (clean)
  update: 1 new changesets, 2 branch heads (merge)
  phases: 3 draft
  orphan: 1 changesets
  $ hg log -G -r '::orphan()'
  @  5:cda648ca50f5 (draft orphan) [tip ] add original_e
  |
  x  4:94b33453f93b (draft *obsolete*) [ ] add original_d [pruned]
  |
  o  3:6f9641995072 (draft) [ ] add n3w_3_c
  |
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  

refuse to push obsolete changeset

  $ hg push ../tmpc/ -r 'desc("original_d")'
  pushing to ../tmpc/
  searching for changes
  abort: push includes obsolete changeset: 94b33453f93b!
  [255]

refuse to push unstable changeset

  $ hg push ../tmpc/
  pushing to ../tmpc/
  searching for changes
  abort: push includes orphan changeset: cda648ca50f5!
  [255]

with --force it will work anyway

  $ hg push ../tmpc/ --force
  pushing to ../tmpc/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  1 new obsolescence markers
  1 new orphan changesets

if the orphan changeset is already on the server, pushing should work

  $ hg push ../tmpc/
  pushing to ../tmpc/
  searching for changes
  no changes found
  [1]

Test that extinct changeset are properly detected

  $ hg log -r 'extinct()'

Don't try to push extinct changeset

  $ hg init ../tmpf
  $ hg out  ../tmpf
  comparing with ../tmpf
  searching for changes
  0:1f0dee641bb7 (public) [ ] add a
  1:7c3bad9141dc (public) [ ] add b
  2:245bde4270cd (public) [ ] add original_c
  3:6f9641995072 (draft) [ ] add n3w_3_c
  4:94b33453f93b (draft *obsolete*) [ ] add original_d [pruned]
  5:cda648ca50f5 (draft orphan) [tip ] add original_e
  $ hg push ../tmpf -f # -f because be push unstable too
  pushing to ../tmpf
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 6 changes to 6 files (+1 heads)
  7 new obsolescence markers
  1 new orphan changesets

no warning displayed

  $ hg push ../tmpf
  pushing to ../tmpf
  searching for changes
  no changes found
  [1]

Do not warn about new head when the new head is a successors of a remote one

  $ hg log -G
  @  5:cda648ca50f5 (draft orphan) [tip ] add original_e
  |
  x  4:94b33453f93b (draft *obsolete*) [ ] add original_d [pruned]
  |
  o  3:6f9641995072 (draft) [ ] add n3w_3_c
  |
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  
  $ hg up -q 'desc(n3w_3_c)'
  $ mkcommit obsolete_e
  created new head
  $ hg debugobsolete `getid 'original_e'` `getid 'obsolete_e'` \
  > -u 'test <test@example.net>'
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg outgoing ../tmpf # parasite hg outgoing testin
  comparing with ../tmpf
  searching for changes
  6:3de5eca88c00 (draft) [tip ] add obsolete_e
  $ hg push ../tmpf
  pushing to ../tmpf
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  1 new obsolescence markers
  obsoleted 1 changesets

test relevance computation
---------------------------------------

Checking simple case of "marker relevance".


Reminder of the repo situation

  $ hg log --hidden --graph
  @  6:3de5eca88c00 (draft) [tip ] add obsolete_e
  |
  | x  5:cda648ca50f5 (draft *obsolete*) [ ] add original_e [rewritten as 6:3de5eca88c00 by test <test@example.net>]
  | |
  | x  4:94b33453f93b (draft *obsolete*) [ ] add original_d [pruned]
  |/
  o  3:6f9641995072 (draft) [ ] add n3w_3_c
  |
  | o  2:245bde4270cd (public) [ ] add original_c
  |/
  o  1:7c3bad9141dc (public) [ ] add b
  |
  o  0:1f0dee641bb7 (public) [ ] add a
  

List of all markers

  $ hg debugobsolete
  1339133913391339133913391339133913391339 ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}
  94b33453f93bdb8d457ef9b770851a618bf413e1 0 {6f96419950729f3671185b847352890f074f7557} (Thu Jan 01 00:00:00 1970 +0000) {'user': 'test'}
  cda648ca50f50482b7055c0b0c4c117bba6733d9 3de5eca88c00aa039da7399a220f4a5221faa585 0 (*) {'user': 'test <test@example.net>'} (glob)

List of changesets with no chain

  $ hg debugobsolete --hidden --rev ::2

List of changesets that are included on marker chain

  $ hg debugobsolete --hidden --rev 6
  cda648ca50f50482b7055c0b0c4c117bba6733d9 3de5eca88c00aa039da7399a220f4a5221faa585 0 (*) {'user': 'test <test@example.net>'} (glob)

List of changesets with a longer chain, (including a pruned children)

  $ hg debugobsolete --hidden --rev 3
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  1339133913391339133913391339133913391339 ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  94b33453f93bdb8d457ef9b770851a618bf413e1 0 {6f96419950729f3671185b847352890f074f7557} (Thu Jan 01 00:00:00 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}

List of both

  $ hg debugobsolete --hidden --rev 3::6
  1337133713371337133713371337133713371337 5601fb93a350734d935195fee37f4054c529ff39 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  1339133913391339133913391339133913391339 ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:19 1970 +0000) {'user': 'test'}
  245bde4270cd1072a27757984f9cda8ba26f08ca cdbce2fbb16313928851e97e0d85413f3f7eb77f C (Thu Jan 01 00:00:01 1970 -0002) {'user': 'test'}
  5601fb93a350734d935195fee37f4054c529ff39 6f96419950729f3671185b847352890f074f7557 1 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  94b33453f93bdb8d457ef9b770851a618bf413e1 0 {6f96419950729f3671185b847352890f074f7557} (Thu Jan 01 00:00:00 1970 +0000) {'user': 'test'}
  ca819180edb99ed25ceafb3e9584ac287e240b00 1337133713371337133713371337133713371337 0 (Thu Jan 01 00:22:18 1970 +0000) {'user': 'test'}
  cda648ca50f50482b7055c0b0c4c117bba6733d9 3de5eca88c00aa039da7399a220f4a5221faa585 0 (*) {'user': 'test <test@example.net>'} (glob)
  cdbce2fbb16313928851e97e0d85413f3f7eb77f ca819180edb99ed25ceafb3e9584ac287e240b00 0 (Thu Jan 01 00:22:17 1970 +0000) {'user': 'test'}

List of all markers in JSON

  $ hg debugobsolete -Tjson
  [
   {
    "date": [1339, 0],
    "flag": 0,
    "metadata": {"user": "test"},
    "prednode": "1339133913391339133913391339133913391339",
    "succnodes": ["ca819180edb99ed25ceafb3e9584ac287e240b00"]
   },
   {
    "date": [1339, 0],
    "flag": 0,
    "metadata": {"user": "test"},
    "prednode": "1337133713371337133713371337133713371337",
    "succnodes": ["5601fb93a350734d935195fee37f4054c529ff39"]
   },
   {
    "date": [121, 120],
    "flag": 12,
    "metadata": {"user": "test"},
    "prednode": "245bde4270cd1072a27757984f9cda8ba26f08ca",
    "succnodes": ["cdbce2fbb16313928851e97e0d85413f3f7eb77f"]
   },
   {
    "date": [1338, 0],
    "flag": 1,
    "metadata": {"user": "test"},
    "prednode": "5601fb93a350734d935195fee37f4054c529ff39",
    "succnodes": ["6f96419950729f3671185b847352890f074f7557"]
   },
   {
    "date": [1338, 0],
    "flag": 0,
    "metadata": {"user": "test"},
    "prednode": "ca819180edb99ed25ceafb3e9584ac287e240b00",
    "succnodes": ["1337133713371337133713371337133713371337"]
   },
   {
    "date": [1337, 0],
    "flag": 0,
    "metadata": {"user": "test"},
    "prednode": "cdbce2fbb16313928851e97e0d85413f3f7eb77f",
    "succnodes": ["ca819180edb99ed25ceafb3e9584ac287e240b00"]
   },
   {
    "date": [0, 0],
    "flag": 0,
    "metadata": {"user": "test"},
    "parentnodes": ["6f96419950729f3671185b847352890f074f7557"],
    "prednode": "94b33453f93bdb8d457ef9b770851a618bf413e1",
    "succnodes": []
   },
   {
    "date": *, (glob)
    "flag": 0,
    "metadata": {"user": "test <test@example.net>"},
    "prednode": "cda648ca50f50482b7055c0b0c4c117bba6733d9",
    "succnodes": ["3de5eca88c00aa039da7399a220f4a5221faa585"]
   }
  ]

Template keywords

  $ hg debugobsolete -r6 -T '{succnodes % "{node|short}"} {date|shortdate}\n'
  3de5eca88c00 ????-??-?? (glob)
  $ hg debugobsolete -r6 -T '{join(metadata % "{key}={value}", " ")}\n'
  user=test <test@example.net>
  $ hg debugobsolete -r6 -T '{metadata}\n{metadata}\n'
  'user': 'test <test@example.net>'
  'user': 'test <test@example.net>'
  $ hg debugobsolete -r6 -T '{succnodes}\n{succnodes}\n'
  3de5eca88c00aa039da7399a220f4a5221faa585
  3de5eca88c00aa039da7399a220f4a5221faa585
  $ hg debugobsolete -r6 -T '{flag} {get(metadata, "user")}\n'
  0 test <test@example.net>

Test the debug output for exchange
----------------------------------

  $ hg pull ../tmpb --config 'experimental.obsmarkers-exchange-debug=True' # bundle2
  pulling from ../tmpb
  searching for changes
  no changes found
  obsmarker-exchange: 346 bytes received

check hgweb does not explode
====================================

  $ hg unbundle $TESTDIR/bundles/hgweb+obs.hg
  adding changesets
  adding manifests
  adding file changes
  added 62 changesets with 63 changes to 9 files (+60 heads)
  new changesets 50c51b361e60:c15e9edfca13 (62 drafts)
  (2 other changesets obsolete on arrival)
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ for node in `hg log -r 'desc(babar_)' --template '{node}\n'`;
  > do
  >    hg debugobsolete $node
  > done
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg up tip
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

#if serve

  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

check changelog view

  $ get-with-headers.py --headeronly localhost:$HGPORT 'shortlog/'
  200 Script output follows

check graph view

  $ get-with-headers.py --headeronly localhost:$HGPORT 'graph'
  200 Script output follows

check filelog view

  $ get-with-headers.py --headeronly localhost:$HGPORT 'log/'`hg log -r . -T "{node}"`/'babar'
  200 Script output follows

check filelog view for hidden commits (obsolete ones are hidden here)

  $ get-with-headers.py localhost:$HGPORT 'log/'`hg log -r . -T "{node}"`/'babar' | grep obsolete
  [1]

  $ get-with-headers.py --headeronly localhost:$HGPORT 'rev/68'
  200 Script output follows
  $ get-with-headers.py --headeronly localhost:$HGPORT 'rev/67'
  404 Not Found
  [1]

check that web.view config option:

  $ killdaemons.py hg.pid
  $ cat >> .hg/hgrc << EOF
  > [web]
  > view=all
  > EOF
  $ wait
  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ get-with-headers.py --headeronly localhost:$HGPORT 'rev/67'
  200 Script output follows
  $ killdaemons.py hg.pid

Checking _enable=False warning if obsolete marker exists

  $ echo '[experimental]' >> $HGRCPATH
  $ echo "evolution=" >> $HGRCPATH
  $ hg log -r tip
  68:c15e9edfca13 (draft) [tip ] add celestine

reenable for later test

  $ echo '[experimental]' >> $HGRCPATH
  $ echo "evolution.exchange=True" >> $HGRCPATH
  $ echo "evolution.createmarkers=True" >> $HGRCPATH

  $ rm access.log errors.log
#endif

Several troubles on the same changeset (create an unstable and bumped and content-divergent changeset)

  $ hg debugobsolete `getid obsolete_e`
  1 new obsolescence markers
  obsoleted 1 changesets
  2 new orphan changesets
  $ hg debugobsolete `getid original_c` `getid babar`
  1 new obsolescence markers
  1 new phase-divergent changesets
  2 new content-divergent changesets
  $ hg log --config ui.logtemplate= -r 'phasedivergent() and orphan() and contentdivergent()'
  changeset:   7:50c51b361e60
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  instability: orphan, phase-divergent, content-divergent
  summary:     add babar
  
test the "obsolete" templatekw

  $ hg log -r 'obsolete()'
  6:3de5eca88c00 (draft *obsolete*) [ ] add obsolete_e [pruned]

test the "troubles" templatekw

  $ hg log -r 'phasedivergent() and orphan()'
  7:50c51b361e60 (draft orphan phase-divergent content-divergent) [ ] add babar

test the default cmdline template

  $ hg log -T default -r 'phasedivergent()'
  changeset:   7:50c51b361e60
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  instability: orphan, phase-divergent, content-divergent
  summary:     add babar
  
  $ hg log -T default -r 'obsolete()'
  changeset:   6:3de5eca88c00
  parent:      3:6f9641995072
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  obsolete:    pruned
  summary:     add obsolete_e
  

test the obsolete labels

  $ hg log --config ui.logtemplate= --color=debug -r 'phasedivergent()'
  [log.changeset changeset.draft changeset.unstable instability.orphan instability.phase-divergent instability.content-divergent|changeset:   7:50c51b361e60]
  [log.user|user:        test]
  [log.date|date:        Thu Jan 01 00:00:00 1970 +0000]
  [log.instability|instability: orphan, phase-divergent, content-divergent]
  [log.summary|summary:     add babar]
  

  $ hg log -T default -r 'phasedivergent()' --color=debug
  [log.changeset changeset.draft changeset.unstable instability.orphan instability.phase-divergent instability.content-divergent|changeset:   7:50c51b361e60]
  [log.user|user:        test]
  [log.date|date:        Thu Jan 01 00:00:00 1970 +0000]
  [log.instability|instability: orphan, phase-divergent, content-divergent]
  [log.summary|summary:     add babar]
  

  $ hg log --config ui.logtemplate= --color=debug -r "obsolete()"
  [log.changeset changeset.draft changeset.obsolete|changeset:   6:3de5eca88c00]
  [log.parent changeset.draft|parent:      3:6f9641995072]
  [log.user|user:        test]
  [log.date|date:        Thu Jan 01 00:00:00 1970 +0000]
  [log.obsfate|obsolete:    pruned]
  [log.summary|summary:     add obsolete_e]
  

  $ hg log -T default -r 'obsolete()' --color=debug
  [log.changeset changeset.draft changeset.obsolete|changeset:   6:3de5eca88c00]
  [log.parent changeset.draft|parent:      3:6f9641995072]
  [log.user|user:        test]
  [log.date|date:        Thu Jan 01 00:00:00 1970 +0000]
  [log.obsfate|obsolete:    pruned]
  [log.summary|summary:     add obsolete_e]
  

test summary output

  $ hg up -r 'phasedivergent() and orphan()'
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg summary
  parent: 7:50c51b361e60  (orphan, phase-divergent, content-divergent)
   add babar
  branch: default
  commit: (clean)
  update: 2 new changesets (update)
  phases: 4 draft
  orphan: 2 changesets
  content-divergent: 2 changesets
  phase-divergent: 1 changesets
  $ hg up -r 'obsolete()'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg summary
  parent: 6:3de5eca88c00  (obsolete)
   add obsolete_e
  branch: default
  commit: (clean)
  update: 3 new changesets (update)
  phases: 4 draft
  orphan: 2 changesets
  content-divergent: 2 changesets
  phase-divergent: 1 changesets

test debugwhyunstable output

  $ hg debugwhyunstable 50c51b361e60
  orphan: obsolete parent 3de5eca88c00aa039da7399a220f4a5221faa585
  phase-divergent: immutable predecessor 245bde4270cd1072a27757984f9cda8ba26f08ca
  content-divergent: 6f96419950729f3671185b847352890f074f7557 (draft) predecessor 245bde4270cd1072a27757984f9cda8ba26f08ca

test whyunstable template keyword

  $ hg log -r 50c51b361e60 -T '{whyunstable}\n'
  orphan: obsolete parent 3de5eca88c00
  phase-divergent: immutable predecessor 245bde4270cd
  content-divergent: 3:6f9641995072 (draft) predecessor 245bde4270cd
  $ hg log -r 50c51b361e60 -T '{whyunstable % "{instability}: {reason} {node|shortest}\n"}'
  orphan: obsolete parent 3de5
  phase-divergent: immutable predecessor 245b
  content-divergent: predecessor 245b

#if serve

  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

check obsolete changeset

  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(obsolete())&style=paper' | grep '<span class="obsolete">'
     <span class="phase">draft</span> <span class="obsolete">obsolete</span> 
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(obsolete())&style=coal' | grep '<span class="obsolete">'
     <span class="phase">draft</span> <span class="obsolete">obsolete</span> 
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(obsolete())&style=gitweb' | grep '<span class="logtags">'
    <span class="logtags"><span class="phasetag" title="draft">draft</span> <span class="obsoletetag" title="obsolete">obsolete</span> </span>
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(obsolete())&style=monoblue' | grep '<span class="logtags">'
          <span class="logtags"><span class="phasetag" title="draft">draft</span> <span class="obsoletetag" title="obsolete">obsolete</span> </span>
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(obsolete())&style=spartan' | grep 'class="obsolete"'
  <th class="obsolete">obsolete:</th>
  <td class="obsolete">pruned by &#116;&#101;&#115;&#116; <span class="age">Thu, 01 Jan 1970 00:00:00 +0000</span></td>

check changeset with instabilities

  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(phasedivergent())&style=paper' | grep '<span class="instability">'
     <span class="phase">draft</span> <span class="instability">orphan</span> <span class="instability">phase-divergent</span> <span class="instability">content-divergent</span> 
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(phasedivergent())&style=coal' | grep '<span class="instability">'
     <span class="phase">draft</span> <span class="instability">orphan</span> <span class="instability">phase-divergent</span> <span class="instability">content-divergent</span> 
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(phasedivergent())&style=gitweb' | grep '<span class="logtags">'
    <span class="logtags"><span class="phasetag" title="draft">draft</span> <span class="instabilitytag" title="orphan">orphan</span> <span class="instabilitytag" title="phase-divergent">phase-divergent</span> <span class="instabilitytag" title="content-divergent">content-divergent</span> </span>
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(phasedivergent())&style=monoblue' | grep '<span class="logtags">'
          <span class="logtags"><span class="phasetag" title="draft">draft</span> <span class="instabilitytag" title="orphan">orphan</span> <span class="instabilitytag" title="phase-divergent">phase-divergent</span> <span class="instabilitytag" title="content-divergent">content-divergent</span> </span>
  $ get-with-headers.py localhost:$HGPORT 'log?rev=first(phasedivergent())&style=spartan' | grep 'class="unstable"'
  <th class="unstable">unstable:</th>
  <td class="unstable">orphan:  obsolete parent <a href="/rev/3de5eca88c00?style=spartan">3de5eca88c00</a></td>
  <th class="unstable">unstable:</th>
  <td class="unstable">phase-divergent:  immutable predecessor <a href="/rev/245bde4270cd?style=spartan">245bde4270cd</a></td>
  <th class="unstable">unstable:</th>
  <td class="unstable">content-divergent: <a href="/rev/6f9641995072?style=spartan">6f9641995072</a> (draft) predecessor <a href="/rev/245bde4270cd?style=spartan">245bde4270cd</a></td>

check explanation for an orphan, phase-divergent and content-divergent changeset

  $ get-with-headers.py localhost:$HGPORT 'rev/50c51b361e60?style=paper' | egrep '(orphan|phase-divergent|content-divergent):'
   <td>orphan:  obsolete parent <a href="/rev/3de5eca88c00?style=paper">3de5eca88c00</a><br>
  phase-divergent:  immutable predecessor <a href="/rev/245bde4270cd?style=paper">245bde4270cd</a><br>
  content-divergent: <a href="/rev/6f9641995072?style=paper">6f9641995072</a> (draft) predecessor <a href="/rev/245bde4270cd?style=paper">245bde4270cd</a></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/50c51b361e60?style=coal' | egrep '(orphan|phase-divergent|content-divergent):'
   <td>orphan:  obsolete parent <a href="/rev/3de5eca88c00?style=coal">3de5eca88c00</a><br>
  phase-divergent:  immutable predecessor <a href="/rev/245bde4270cd?style=coal">245bde4270cd</a><br>
  content-divergent: <a href="/rev/6f9641995072?style=coal">6f9641995072</a> (draft) predecessor <a href="/rev/245bde4270cd?style=coal">245bde4270cd</a></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/50c51b361e60?style=gitweb' | egrep '(orphan|phase-divergent|content-divergent):'
  <td>orphan:  obsolete parent <a class="list" href="/rev/3de5eca88c00?style=gitweb">3de5eca88c00</a></td>
  <td>phase-divergent:  immutable predecessor <a class="list" href="/rev/245bde4270cd?style=gitweb">245bde4270cd</a></td>
  <td>content-divergent: <a class="list" href="/rev/6f9641995072?style=gitweb">6f9641995072</a> (draft) predecessor <a class="list" href="/rev/245bde4270cd?style=gitweb">245bde4270cd</a></td>
  $ get-with-headers.py localhost:$HGPORT 'rev/50c51b361e60?style=monoblue' | egrep '(orphan|phase-divergent|content-divergent):'
  <dd>orphan:  obsolete parent <a href="/rev/3de5eca88c00?style=monoblue">3de5eca88c00</a></dd>
  <dd>phase-divergent:  immutable predecessor <a href="/rev/245bde4270cd?style=monoblue">245bde4270cd</a></dd>
  <dd>content-divergent: <a href="/rev/6f9641995072?style=monoblue">6f9641995072</a> (draft) predecessor <a href="/rev/245bde4270cd?style=monoblue">245bde4270cd</a></dd>
  $ get-with-headers.py localhost:$HGPORT 'rev/50c51b361e60?style=spartan' | egrep '(orphan|phase-divergent|content-divergent):'
  <td class="unstable">orphan:  obsolete parent <a href="/rev/3de5eca88c00?style=spartan">3de5eca88c00</a></td>
  <td class="unstable">phase-divergent:  immutable predecessor <a href="/rev/245bde4270cd?style=spartan">245bde4270cd</a></td>
  <td class="unstable">content-divergent: <a href="/rev/6f9641995072?style=spartan">6f9641995072</a> (draft) predecessor <a href="/rev/245bde4270cd?style=spartan">245bde4270cd</a></td>

  $ killdaemons.py

  $ rm hg.pid access.log errors.log

#endif

Test incoming/outcoming with changesets obsoleted remotely, known locally
===============================================================================

This test issue 3805

  $ hg init repo-issue3805
  $ cd repo-issue3805
  $ echo "base" > base
  $ hg ci -Am "base"
  adding base
  $ echo "foo" > foo
  $ hg ci -Am "A"
  adding foo
  $ hg clone . ../other-issue3805
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo "bar" >> foo
  $ hg ci --amend
  $ cd ../other-issue3805
  $ hg log -G
  @  1:29f0c6921ddd (draft) [tip ] A
  |
  o  0:d20a80d4def3 (draft) [ ] base
  
  $ hg log -G -R ../repo-issue3805
  @  2:323a9c3ddd91 (draft) [tip ] A
  |
  o  0:d20a80d4def3 (draft) [ ] base
  
  $ hg incoming
  comparing with $TESTTMP/tmpe/repo-issue3805
  searching for changes
  2:323a9c3ddd91 (draft) [tip ] A
  $ hg incoming --bundle ../issue3805.hg
  comparing with $TESTTMP/tmpe/repo-issue3805
  searching for changes
  2:323a9c3ddd91 (draft) [tip ] A
  $ hg outgoing
  comparing with $TESTTMP/tmpe/repo-issue3805
  searching for changes
  1:29f0c6921ddd (draft) [tip ] A

#if serve

  $ hg serve -R ../repo-issue3805 -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ hg incoming http://localhost:$HGPORT
  comparing with http://localhost:$HGPORT/
  searching for changes
  2:323a9c3ddd91 (draft) [tip ] A
  $ hg outgoing http://localhost:$HGPORT
  comparing with http://localhost:$HGPORT/
  searching for changes
  1:29f0c6921ddd (draft) [tip ] A

  $ killdaemons.py

#endif

This test issue 3814

(nothing to push but locally hidden changeset)

  $ cd ..
  $ hg init repo-issue3814
  $ cd repo-issue3805
  $ hg push -r 323a9c3ddd91 ../repo-issue3814
  pushing to ../repo-issue3814
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  1 new obsolescence markers
  $ hg out ../repo-issue3814
  comparing with ../repo-issue3814
  searching for changes
  no changes found
  [1]

Test that a local tag blocks a changeset from being hidden

  $ hg tag -l visible -r 1 --hidden
  $ hg log -G
  @  2:323a9c3ddd91 (draft) [tip ] A
  |
  | x  1:29f0c6921ddd (draft *obsolete*) [visible ] A [rewritten using amend as 2:323a9c3ddd91]
  |/
  o  0:d20a80d4def3 (draft) [ ] base
  
Test that removing a local tag does not cause some commands to fail

  $ hg tag -l -r tip tiptag
  $ hg tags
  tiptag                             2:323a9c3ddd91
  tip                                2:323a9c3ddd91
  visible                            1:29f0c6921ddd
  $ hg --config extensions.strip= strip -r tip --no-backup
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg tags
  visible                            1:29f0c6921ddd
  tip                                1:29f0c6921ddd

Test bundle overlay onto hidden revision

  $ cd ..
  $ hg init repo-bundleoverlay
  $ cd repo-bundleoverlay
  $ echo "A" > foo
  $ hg ci -Am "A"
  adding foo
  $ echo "B" >> foo
  $ hg ci -m "B"
  $ hg up 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo "C" >> foo
  $ hg ci -m "C"
  created new head
  $ hg log -G
  @  2:c186d7714947 (draft) [tip ] C
  |
  | o  1:44526ebb0f98 (draft) [ ] B
  |/
  o  0:4b34ecfb0d56 (draft) [ ] A
  

  $ hg clone -r1 . ../other-bundleoverlay
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets 4b34ecfb0d56:44526ebb0f98 (2 drafts)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd ../other-bundleoverlay
  $ echo "B+" >> foo
  $ hg ci --amend -m "B+"
  $ hg log -G --hidden
  @  2:b7d587542d40 (draft) [tip ] B+
  |
  | x  1:44526ebb0f98 (draft *obsolete*) [ ] B [rewritten using amend as 2:b7d587542d40]
  |/
  o  0:4b34ecfb0d56 (draft) [ ] A
  

#if repobundlerepo
  $ hg incoming ../repo-bundleoverlay --bundle ../bundleoverlay.hg
  comparing with ../repo-bundleoverlay
  searching for changes
  1:44526ebb0f98 (draft) [ ] B
  2:c186d7714947 (draft) [tip ] C
  $ hg log -G -R ../bundleoverlay.hg
  o  3:c186d7714947 (draft) [tip ] C
  |
  | @  2:b7d587542d40 (draft) [ ] B+
  |/
  o  0:4b34ecfb0d56 (draft) [ ] A
  
#endif

#if serve

Test issue 4506

  $ cd ..
  $ hg init repo-issue4506
  $ cd repo-issue4506
  $ echo "0" > foo
  $ hg add foo
  $ hg ci -m "content-0"

  $ hg up null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo "1" > bar
  $ hg add bar
  $ hg ci -m "content-1"
  created new head
  $ hg up 0
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg graft 1
  grafting 1:1c9eddb02162 "content-1" (tip)

  $ hg debugobsolete `hg log -r1 -T'{node}'` `hg log -r2 -T'{node}'`
  1 new obsolescence markers
  obsoleted 1 changesets

  $ hg serve -n test -p $HGPORT -d --pid-file=hg.pid -A access.log -E errors.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ get-with-headers.py --headeronly localhost:$HGPORT 'rev/1'
  404 Not Found
  [1]
  $ get-with-headers.py --headeronly localhost:$HGPORT 'file/tip/bar'
  200 Script output follows
  $ get-with-headers.py --headeronly localhost:$HGPORT 'annotate/tip/bar'
  200 Script output follows

  $ killdaemons.py

#endif

Test heads computation on pending index changes with obsolescence markers
  $ cd ..
  $ cat >$TESTTMP/test_extension.py  << EOF
  > from __future__ import absolute_import
  > from mercurial.i18n import _
  > from mercurial import cmdutil, pycompat, registrar
  > from mercurial.utils import stringutil
  > 
  > cmdtable = {}
  > command = registrar.command(cmdtable)
  > @command(b"amendtransient",[], _(b'hg amendtransient [rev]'))
  > def amend(ui, repo, *pats, **opts):
  >   opts['message'] = b'Test'
  >   opts['logfile'] = None
  >   cmdutil.amend(ui, repo, repo[b'.'], {}, pats, opts)
  >   ui.write(b'%s\n' % stringutil.pprint(repo.changelog.headrevs()))
  > EOF
  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > testextension=$TESTTMP/test_extension.py
  > EOF
  $ hg init repo-issue-nativerevs-pending-changes
  $ cd repo-issue-nativerevs-pending-changes
  $ mkcommit a
  $ mkcommit b
  $ hg up ".^"
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo aa > a
  $ hg amendtransient
  1 new orphan changesets
  [1, 2]

Test cache consistency for the visible filter
1) We want to make sure that the cached filtered revs are invalidated when
bookmarks change
  $ cd ..
  $ cat >$TESTTMP/test_extension.py  << EOF
  > from __future__ import absolute_import, print_function
  > import weakref
  > from mercurial import (
  >   bookmarks,
  >   cmdutil,
  >   extensions,
  >   repoview,
  > )
  > def _bookmarkchanged(orig, bkmstoreinst, *args, **kwargs):
  >  reporef = weakref.ref(bkmstoreinst._repo)
  >  def trhook(tr):
  >   repo = reporef()
  >   hidden1 = repoview.computehidden(repo)
  >   hidden = repoview.filterrevs(repo, b'visible')
  >   if sorted(hidden1) != sorted(hidden):
  >     print("cache inconsistency")
  >  bkmstoreinst._repo.currenttransaction().addpostclose(b'test_extension', trhook)
  >  orig(bkmstoreinst, *args, **kwargs)
  > def extsetup(ui):
  >   extensions.wrapfunction(bookmarks.bmstore, '_recordchange',
  >                           _bookmarkchanged)
  > EOF

  $ hg init repo-cache-inconsistency
  $ cd repo-issue-nativerevs-pending-changes
  $ mkcommit a
  a already tracked!
  $ mkcommit b
  $ hg id
  13bedc178fce tip
  $ echo "hello" > b
  $ hg commit --amend -m "message"
  $ hg book bookb -r 13bedc178fce --hidden
  bookmarking hidden changeset 13bedc178fce
  (hidden revision '13bedc178fce' was rewritten as: a9b1f8652753)
  $ hg log -r 13bedc178fce
  4:13bedc178fce (draft *obsolete*) [ bookb] add b [rewritten using amend as 5:a9b1f8652753]
  $ hg book -d bookb
  $ hg log -r 13bedc178fce
  abort: hidden revision '13bedc178fce' was rewritten as: a9b1f8652753
  (use --hidden to access hidden revisions)
  [10]

Empty out the test extension, as it isn't compatible with later parts
of the test.
  $ echo > $TESTTMP/test_extension.py

Test ability to pull changeset with locally applying obsolescence markers
(issue4945)

  $ cd ..
  $ hg init issue4845
  $ cd issue4845

  $ echo foo > f0
  $ hg add f0
  $ hg ci -m '0'
  $ echo foo > f1
  $ hg add f1
  $ hg ci -m '1'
  $ echo foo > f2
  $ hg add f2
  $ hg ci -m '2'

  $ echo bar > f2
  $ hg commit --amend --config experimental.evolution.createmarkers=True
  $ hg log -G
  @  3:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  o  0:a78f55e5508c (draft) [ ] 0
  
  $ hg log -G --hidden
  @  3:b0551702f918 (draft) [tip ] 2
  |
  | x  2:e008cf283490 (draft *obsolete*) [ ] 2 [rewritten using amend as 3:b0551702f918]
  |/
  o  1:e016b03fd86f (draft) [ ] 1
  |
  o  0:a78f55e5508c (draft) [ ] 0
  

  $ hg strip --hidden -r 2 --config extensions.strip= --config devel.strip-obsmarkers=no
  saved backup bundle to $TESTTMP/tmpe/issue4845/.hg/strip-backup/e008cf283490-ede36964-backup.hg
  $ hg debugobsolete
  e008cf2834908e5d6b0f792a9d4b0e2272260fb8 b0551702f918510f01ae838ab03a463054c67b46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}
  $ hg log -G
  @  2:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  o  0:a78f55e5508c (draft) [ ] 0
  
  $ hg log -G --hidden
  @  2:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  o  0:a78f55e5508c (draft) [ ] 0
  
  $ hg debugbundle .hg/strip-backup/e008cf283490-*-backup.hg
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 1, version: 02} (mandatory: True)
      e008cf2834908e5d6b0f792a9d4b0e2272260fb8
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      e008cf2834908e5d6b0f792a9d4b0e2272260fb8 draft

#if repobundlerepo
  $ hg pull .hg/strip-backup/e008cf283490-*-backup.hg
  pulling from .hg/strip-backup/e008cf283490-ede36964-backup.hg
  searching for changes
  no changes found
#endif
  $ hg debugobsolete
  e008cf2834908e5d6b0f792a9d4b0e2272260fb8 b0551702f918510f01ae838ab03a463054c67b46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}
  $ hg log -G
  @  2:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  o  0:a78f55e5508c (draft) [ ] 0
  
  $ hg log -G --hidden
  @  2:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  o  0:a78f55e5508c (draft) [ ] 0
  

Testing that strip remove markers:

  $ hg strip -r 1 --config extensions.strip=
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/tmpe/issue4845/.hg/strip-backup/e016b03fd86f-65ede734-backup.hg
  $ hg debugobsolete
  $ hg log -G
  @  0:a78f55e5508c (draft) [tip ] 0
  
  $ hg log -G --hidden
  @  0:a78f55e5508c (draft) [tip ] 0
  
  $ hg debugbundle .hg/strip-backup/e016b03fd86f-*-backup.hg
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 2, version: 02} (mandatory: True)
      e016b03fd86fcccc54817d120b90b751aaf367d6
      b0551702f918510f01ae838ab03a463054c67b46
  cache:rev-branch-cache -- {} (mandatory: False)
  obsmarkers -- {} (mandatory: True)
      version: 1 (92 bytes)
      e008cf2834908e5d6b0f792a9d4b0e2272260fb8 b0551702f918510f01ae838ab03a463054c67b46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}
  phase-heads -- {} (mandatory: True)
      b0551702f918510f01ae838ab03a463054c67b46 draft

  $ hg unbundle .hg/strip-backup/e016b03fd86f-*-backup.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  1 new obsolescence markers
  new changesets e016b03fd86f:b0551702f918 (2 drafts)
  (run 'hg update' to get a working copy)
  $ hg debugobsolete | sort
  e008cf2834908e5d6b0f792a9d4b0e2272260fb8 b0551702f918510f01ae838ab03a463054c67b46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}
  $ hg log -G
  o  2:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  @  0:a78f55e5508c (draft) [ ] 0
  
  $ hg log -G --hidden
  o  2:b0551702f918 (draft) [tip ] 2
  |
  o  1:e016b03fd86f (draft) [ ] 1
  |
  @  0:a78f55e5508c (draft) [ ] 0
  


Test that bundles can ship the markers without making them mandatory
for non-obsmarker enabled clients:

  $ hg --config experimental.evolution.bundle-obsmarker=1 --config experimental.evolution.bundle-obsmarker:mandatory=0 bundle --base 0 -r 1:: obslog-bundle.hg
  2 changesets found
  $ hg debugbundle obslog-bundle.hg
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 2, version: 02} (mandatory: True)
      e016b03fd86fcccc54817d120b90b751aaf367d6
      b0551702f918510f01ae838ab03a463054c67b46
  cache:rev-branch-cache -- {} (mandatory: False)
  obsmarkers -- {} (mandatory: False)
      version: 1 (92 bytes)
      e008cf2834908e5d6b0f792a9d4b0e2272260fb8 b0551702f918510f01ae838ab03a463054c67b46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}


Test that 'hg debugobsolete --index --rev' can show indices of obsmarkers when
only a subset of those are displayed (because of --rev option)
  $ hg init doindexrev
  $ cd doindexrev
  $ echo a > a
  $ hg ci -Am a
  adding a
  $ hg ci --amend -m aa
  $ echo b > b
  $ hg ci -Am b
  adding b
  $ hg ci --amend -m bb
  $ echo c > c
  $ hg ci -Am c
  adding c
  $ hg ci --amend -m cc
  $ echo d > d
  $ hg ci -Am d
  adding d
  $ hg ci --amend -m dd --config experimental.evolution.track-operation=1
  $ hg debugobsolete --index --rev "3+7"
  1 6fdef60fcbabbd3d50e9b9cbc2a240724b91a5e1 d27fb9b066076fd921277a4b9e8b9cb48c95bc6a 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  3 4715cf767440ed891755448016c2b8cf70760c30 7ae79c5d60f049c7b0dd02f5f25b9d60aaf7b36d 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  $ hg debugobsolete --index --rev "3+7" -Tjson
  [
   {
    "date": [0, 0],
    "flag": 0,
    "index": 1,
    "metadata": {"ef1": "1", "operation": "amend", "user": "test"},
    "prednode": "6fdef60fcbabbd3d50e9b9cbc2a240724b91a5e1",
    "succnodes": ["d27fb9b066076fd921277a4b9e8b9cb48c95bc6a"]
   },
   {
    "date": [0, 0],
    "flag": 0,
    "index": 3,
    "metadata": {"ef1": "1", "operation": "amend", "user": "test"},
    "prednode": "4715cf767440ed891755448016c2b8cf70760c30",
    "succnodes": ["7ae79c5d60f049c7b0dd02f5f25b9d60aaf7b36d"]
   }
  ]

Test the --delete option of debugobsolete command
  $ hg debugobsolete --index
  0 cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b f9bd49731b0b175e42992a3c8fa6c678b2bc11f1 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  1 6fdef60fcbabbd3d50e9b9cbc2a240724b91a5e1 d27fb9b066076fd921277a4b9e8b9cb48c95bc6a 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  2 1ab51af8f9b41ef8c7f6f3312d4706d870b1fb74 29346082e4a9e27042b62d2da0e2de211c027621 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  3 4715cf767440ed891755448016c2b8cf70760c30 7ae79c5d60f049c7b0dd02f5f25b9d60aaf7b36d 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  $ hg debugobsolete --delete 1 --delete 3
  deleted 2 obsolescence markers
  $ hg debugobsolete
  cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b f9bd49731b0b175e42992a3c8fa6c678b2bc11f1 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  1ab51af8f9b41ef8c7f6f3312d4706d870b1fb74 29346082e4a9e27042b62d2da0e2de211c027621 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}

Test adding changeset after obsmarkers affecting it
(eg: during pull, or unbundle)

  $ mkcommit e
  $ hg bundle -r . --base .~1 ../bundle-2.hg
  1 changesets found
  $ getid .
  $ hg --config extensions.strip= strip -r .
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/tmpe/issue4845/doindexrev/.hg/strip-backup/9bc153528424-ee80edd4-backup.hg
  $ hg debugobsolete 9bc153528424ea266d13e57f9ff0d799dfe61e4b
  1 new obsolescence markers
  $ hg unbundle ../bundle-2.hg
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  (1 other changesets obsolete on arrival)
  (run 'hg update' to get a working copy)
  $ hg log -G
  @  7:7ae79c5d60f0 (draft) [tip ] dd
  |
  | o  6:4715cf767440 (draft) [ ] d
  |/
  o  5:29346082e4a9 (draft) [ ] cc
  |
  o  3:d27fb9b06607 (draft) [ ] bb
  |
  | o  2:6fdef60fcbab (draft) [ ] b
  |/
  o  1:f9bd49731b0b (draft) [ ] aa
  

  $ cd ..

Test issue 5783

  $ hg init issue-5783 --config format.obsstore-version=0
  $ cd issue-5783
  $ touch a.cpp
  $ hg add a.cpp
  $ hg commit -m 'Add a.cpp'
  $ echo 'Hello' > a.cpp
  $ hg amend -n 'Testing::Obsstore' --config format.obsstore-version=0 --config extensions.amend=
  $ touch b.cpp
  $ hg add b.cpp
  $ hg commit -m 'Add b.cpp'
  $ echo 'Hello' > b.cpp
  $ hg amend -n 'Testing::Obsstore2' --config extensions.amend=
  $ hg debugobsolete
  d1b09fe3ad2b2a03e23a72f0c582e29a49570145 1a1a11184d2588af24e767e5335d5d9d07e8c550 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'note': 'Testing::Obsstore', 'operation': 'amend', 'user': 'test'}
  1bfd8e3868f641e048b6667cd672c68932f26d00 79959ca316d5b27ac6be1dd0cfd0843a5b5412eb 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'note': 'Testing::Obsstore2', 'operation': 'amend', 'user': 'test'}
  $ cd ..

Test that pinning of revisions in broken mergestate doesn't cause crash

  $ hg init pinning-broken-mergestate
  $ cd pinning-broken-mergestate
  $ echo a > file
  $ hg ci -Aqm first
Create a pruned commit so pinning comes into play
  $ echo pruned > pruned
  $ hg ci -Aqm pruned
  $ hg co -q 0
  $ hg debugobsolete $(getid pruned)
  1 new obsolescence markers
  obsoleted 1 changesets
Back up changelog, so we can restore it later after causing merge conflicts
with it, thus ending up with mergestate that points to a non-existent commit
  $ cp .hg/store/00changelog.i .hg/store/00changelog.i.first
  $ echo b > file
  $ hg ci -qm second
  $ echo c > file
  $ hg co -m 0
  merging file
  warning: conflicts while merging file! (edit, then use 'hg resolve --mark')
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges
  [1]
  $ mv -f .hg/store/00changelog.i.first .hg/store/00changelog.i
The local node should now point to a non-existent commit
  $ hg debugmergestate
  local (working copy): b73b8c9a4ab4da89a5a35a6f10dfb13edc84ca37
  other (destination): f53e9479dce52f79c923908241fa54f7da90a7ad
  file: file (state "u")
    local path: file (hash 971c419dd609331343dee105fffd0f4608dc0bf2, flags "")
    ancestor path: file (node bc7ebe2d260cff30d2a39a130d84add36216f791)
    other path: file (node b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3)
    extra: ancestorlinknode = b73b8c9a4ab4da89a5a35a6f10dfb13edc84ca37
    extra: merged = yes
We should be able to see the log (without the deleted commit, of course)
  $ hg log -G
  @  0:f53e9479dce5 (draft) [tip ] first
  
  $ cd ..
