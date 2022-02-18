=============================
Test distributed obsolescence
=============================

This file test various cases where data (changeset, phase, obsmarkers) is
added to the repository in a specific order. Usually, this order is unlikely
to happen in the local case but can easily happen in the distributed case.

  $ unset HGUSER
  $ unset EMAIL
  $ . $TESTDIR/testlib/obsmarker-common.sh
  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > rebase =
  > [experimental]
  > evolution = all
  > [phases]
  > publish = False
  > [command-templates]
  > log = {rev}:{node|short} {desc}{if(obsfate, " [{join(obsfate, "; ")}]")}\n
  > EOF

Check distributed chain building
================================

Test case where a changeset is marked as a successor of another local
changeset while the successor has already been obsoleted remotely.

The chain of evolution should seamlessly connect and all but the new version
(created remotely) should be seen as obsolete.

Initial setup

  $ mkdir distributed-chain-building
  $ cd distributed-chain-building
  $ hg init server
  $ cd server
  $ cat << EOF >> .hg/hgrc
  > [ui]
  > username = server
  > EOF
  $ mkcommit ROOT
  $ mkcommit c_A0
  $ hg up 'desc("ROOT")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit c_A1
  created new head
  $ hg up 'desc("ROOT")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit c_B0
  created new head
  $ hg debugobsolete `getid 'desc("c_A0")'` `getid 'desc("c_A1")'`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G --hidden -v
  @  3:e5d7dda7cd28 c_B0
  |
  | o  2:7f6b0a6f5c25 c_A1
  |/
  | x  1:e1b46f0f979f c_A0 [rewritten as 2:7f6b0a6f5c25 by server (at 1970-01-01 00:00 +0000)]
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  e1b46f0f979f52748347ff8729c59f2ef56e6fe2 7f6b0a6f5c25345a83870963efd827c1798a5959 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}
  $ cd ..

duplicate the repo for the client:

  $ cp -R server client
  $ cat << EOF >> client/.hg/hgrc
  > [paths]
  > default = ../server/
  > [ui]
  > username = client
  > EOF

server side: create new revision on the server (obsoleting another one)

  $ cd server
  $ hg up 'desc("ROOT")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit c_B1
  created new head
  $ hg debugobsolete `getid 'desc("c_B0")'` `getid 'desc("c_B1")'`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G
  @  4:391a2bf12b1b c_B1
  |
  | o  2:7f6b0a6f5c25 c_A1
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg log -G --hidden -v
  @  4:391a2bf12b1b c_B1
  |
  | x  3:e5d7dda7cd28 c_B0 [rewritten as 4:391a2bf12b1b by server (at 1970-01-01 00:00 +0000)]
  |/
  | o  2:7f6b0a6f5c25 c_A1
  |/
  | x  1:e1b46f0f979f c_A0 [rewritten as 2:7f6b0a6f5c25 by server (at 1970-01-01 00:00 +0000)]
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  e1b46f0f979f52748347ff8729c59f2ef56e6fe2 7f6b0a6f5c25345a83870963efd827c1798a5959 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}
  e5d7dda7cd28e6b3f79437e5b8122a38ece0255c 391a2bf12b1b8b05a72400ae36b26d50a091dc22 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}
  $ cd ..

client side: create a marker between two common changesets
(client is not aware of the server activity yet)

  $ cd client
  $ hg debugobsolete `getid 'desc("c_A1")'` `getid 'desc("c_B0")'`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg log -G
  @  3:e5d7dda7cd28 c_B0
  |
  o  0:e82fb8d02bbf ROOT
  
  $ hg log -G --hidden -v
  @  3:e5d7dda7cd28 c_B0
  |
  | x  2:7f6b0a6f5c25 c_A1 [rewritten as 3:e5d7dda7cd28 by client (at 1970-01-01 00:00 +0000)]
  |/
  | x  1:e1b46f0f979f c_A0 [rewritten as 2:7f6b0a6f5c25 by server (at 1970-01-01 00:00 +0000)]
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  e1b46f0f979f52748347ff8729c59f2ef56e6fe2 7f6b0a6f5c25345a83870963efd827c1798a5959 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}
  7f6b0a6f5c25345a83870963efd827c1798a5959 e5d7dda7cd28e6b3f79437e5b8122a38ece0255c 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'client'}

client side: pull from the server
(the new successors should take over)

  $ hg up 'desc("ROOT")'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg pull --debug --confirm --config ui.interactive=True << EOF
  > n
  > EOF
  pulling from $TESTTMP/distributed-chain-building/server
  query 1; heads
  searching for changes
  taking quick initial sample
  query 2; still undecided: 1, sample size is: 1
  2 total queries in *.*s (glob)
  1 changesets found
  list of changesets:
  391a2bf12b1b8b05a72400ae36b26d50a091dc22
  listing keys for "bookmarks"
  bundle2-output-bundle: "HG20", 4 parts total
  bundle2-output-part: "changegroup" (params: 1 mandatory 1 advisory) streamed payload
  bundle2-output-part: "listkeys" (params: 1 mandatory) empty payload
  bundle2-output-part: "obsmarkers" streamed payload
  bundle2-output-part: "phase-heads" 48 bytes payload
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "changegroup" (params: 1 mandatory 1 advisory) supported
  adding changesets
  add changeset 391a2bf12b1b
  adding manifests
  adding file changes
  adding c_B1 revisions
  bundle2-input-part: total payload size 485
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: "obsmarkers" supported
  bundle2-input-part: total payload size 143
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 48
  bundle2-input-bundle: 4 parts total
  checking for updated bookmarks
  adding 1 changesets with 1 changes to 1 files (+1 heads)
  1 new obsolescence markers
  obsoleting 1 changesets
  new changesets 391a2bf12b1b (1 drafts)
  accept incoming changes (yn)? n
  transaction abort!
  rollback completed
  abort: user aborted
  [255]

  $ hg pull --confirm --config ui.interactive=True << EOF
  > y
  > EOF
  pulling from $TESTTMP/distributed-chain-building/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  adding 1 changesets with 1 changes to 1 files (+1 heads)
  1 new obsolescence markers
  obsoleting 1 changesets
  new changesets 391a2bf12b1b (1 drafts)
  accept incoming changes (yn)? y
  added 1 changesets with 1 changes to 1 files (+1 heads)
  1 new obsolescence markers
  obsoleted 1 changesets
  new changesets 391a2bf12b1b (1 drafts)
  (run 'hg heads' to see heads)
  $ hg log -G
  o  4:391a2bf12b1b c_B1
  |
  @  0:e82fb8d02bbf ROOT
  
  $ hg log -G --hidden -v
  o  4:391a2bf12b1b c_B1
  |
  | x  3:e5d7dda7cd28 c_B0 [rewritten as 4:391a2bf12b1b by server (at 1970-01-01 00:00 +0000)]
  |/
  | x  2:7f6b0a6f5c25 c_A1 [rewritten as 3:e5d7dda7cd28 by client (at 1970-01-01 00:00 +0000)]
  |/
  | x  1:e1b46f0f979f c_A0 [rewritten as 2:7f6b0a6f5c25 by server (at 1970-01-01 00:00 +0000)]
  |/
  @  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  e1b46f0f979f52748347ff8729c59f2ef56e6fe2 7f6b0a6f5c25345a83870963efd827c1798a5959 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}
  7f6b0a6f5c25345a83870963efd827c1798a5959 e5d7dda7cd28e6b3f79437e5b8122a38ece0255c 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'client'}
  e5d7dda7cd28e6b3f79437e5b8122a38ece0255c 391a2bf12b1b8b05a72400ae36b26d50a091dc22 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}

server side: receive client push
(the other way around, pushing to the server, the obsolete changesets stay
obsolete on the server side but the marker is sent out.)

  $ hg rollback
  repository tip rolled back to revision 3 (undo pull)
  $ hg push -f
  pushing to $TESTTMP/distributed-chain-building/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 0 changes to 1 files
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg -R ../server/ log -G
  @  4:391a2bf12b1b c_B1
  |
  o  0:e82fb8d02bbf ROOT
  
  $ hg -R ../server/ log -G --hidden -v
  @  4:391a2bf12b1b c_B1
  |
  | x  3:e5d7dda7cd28 c_B0 [rewritten as 4:391a2bf12b1b by server (at 1970-01-01 00:00 +0000)]
  |/
  | x  2:7f6b0a6f5c25 c_A1 [rewritten as 3:e5d7dda7cd28 by client (at 1970-01-01 00:00 +0000)]
  |/
  | x  1:e1b46f0f979f c_A0 [rewritten as 2:7f6b0a6f5c25 by server (at 1970-01-01 00:00 +0000)]
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  e1b46f0f979f52748347ff8729c59f2ef56e6fe2 7f6b0a6f5c25345a83870963efd827c1798a5959 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'server'}
  7f6b0a6f5c25345a83870963efd827c1798a5959 e5d7dda7cd28e6b3f79437e5b8122a38ece0255c 0 (Thu Jan 01 00:00:00 1970 +0000) {'user': 'client'}
  $ cd ..

Check getting changesets after getting the markers
=================================================

This test case covers the scenario where commits are received -after- we
received some obsolescence markers turning them obsolete.

For example, we pull some successors from a repository (with associated
predecessors marker chain) and then later we pull some intermediate
precedessors changeset from another repository. Obsolescence markers must
apply to the intermediate changeset. They have to be obsolete (and hidden).

Avoiding pulling the changeset in the first place is a tricky decision because
there could be non-obsolete ancestors that need to be pulled, but the
discovery cannot currently find these (this is not the case in this tests). In
addition, we could also have to pull the changeset because they have children.
In this case, they would not be hidden (yet) because of the orphan descendant,
but they would still have to be obsolete. (This is not tested in this case
either).

  $ mkdir distributed-chain-building
  $ cd distributed-chain-building
  $ hg init server
  $ cd server
  $ cat << EOF >> .hg/hgrc
  > [ui]
  > username = server
  > EOF
  $ mkcommit ROOT
  $ cd ..
  $ hg clone server repo-Alice
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat << EOF >> repo-Alice/.hg/hgrc
  > [ui]
  > username = alice
  > EOF
  $ hg clone server repo-Bob
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat << EOF >> repo-Bob/.hg/hgrc
  > [ui]
  > username = bob
  > EOF
  $ hg clone server repo-Celeste
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat << EOF >> repo-Celeste/.hg/hgrc
  > [ui]
  > username = celeste
  > EOF

Create some changesets locally

  $ cd repo-Alice
  $ mkcommit c_A0
  $ mkcommit c_B0
  $ cd ..

Bob pulls from Alice and rewrites them

  $ cd repo-Bob
  $ hg pull ../repo-Alice
  pulling from ../repo-Alice
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets d33b0a3a6464:ef908e42ce65 (2 drafts)
  (run 'hg update' to get a working copy)
  $ hg up 'desc("c_A")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit --amend -m 'c_A1'
  1 new orphan changesets
  $ hg rebase -r 'desc("c_B0")' -d . # no easy way to rewrite the message with the rebase
  rebasing 2:ef908e42ce65 "c_B0"
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit --amend -m 'c_B1'
  $ hg log -G
  @  5:956063ac4557 c_B1
  |
  o  3:5b5708a437f2 c_A1
  |
  o  0:e82fb8d02bbf ROOT
  
  $ hg log -G --hidden -v
  @  5:956063ac4557 c_B1
  |
  | x  4:5ffb9e311b35 c_B0 [rewritten using amend as 5:956063ac4557 by bob (at 1970-01-01 00:00 +0000)]
  |/
  o  3:5b5708a437f2 c_A1
  |
  | x  2:ef908e42ce65 c_B0 [rewritten using rebase as 4:5ffb9e311b35 by bob (at 1970-01-01 00:00 +0000)]
  | |
  | x  1:d33b0a3a6464 c_A0 [rewritten using amend as 3:5b5708a437f2 by bob (at 1970-01-01 00:00 +0000)]
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  d33b0a3a64647d79583526be8107802b1f9fedfa 5b5708a437f27665db42c5a261a539a1bcb2a8c2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  ef908e42ce65ef57f970d799acaddde26f58a4cc 5ffb9e311b35f6ab6f76f667ca5d6e595645481b 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'bob'}
  5ffb9e311b35f6ab6f76f667ca5d6e595645481b 956063ac4557828781733b2d5677a351ce856f59 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  $ cd ..

Celeste pulls from Bob and rewrites them again

  $ cd repo-Celeste
  $ hg pull ../repo-Bob
  pulling from ../repo-Bob
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  3 new obsolescence markers
  new changesets 5b5708a437f2:956063ac4557 (2 drafts)
  (run 'hg update' to get a working copy)
  $ hg up 'desc("c_A")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit --amend -m 'c_A2'
  1 new orphan changesets
  $ hg rebase -r 'desc("c_B1")' -d . # no easy way to rewrite the message with the rebase
  rebasing 2:956063ac4557 "c_B1"
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg commit --amend -m 'c_B2'
  $ hg log -G
  @  5:77ae25d99ff0 c_B2
  |
  o  3:9866d64649a5 c_A2
  |
  o  0:e82fb8d02bbf ROOT
  
  $ hg log -G --hidden -v
  @  5:77ae25d99ff0 c_B2
  |
  | x  4:3cf8de21cc22 c_B1 [rewritten using amend as 5:77ae25d99ff0 by celeste (at 1970-01-01 00:00 +0000)]
  |/
  o  3:9866d64649a5 c_A2
  |
  | x  2:956063ac4557 c_B1 [rewritten using rebase as 4:3cf8de21cc22 by celeste (at 1970-01-01 00:00 +0000)]
  | |
  | x  1:5b5708a437f2 c_A1 [rewritten using amend as 3:9866d64649a5 by celeste (at 1970-01-01 00:00 +0000)]
  |/
  o  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  5ffb9e311b35f6ab6f76f667ca5d6e595645481b 956063ac4557828781733b2d5677a351ce856f59 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  d33b0a3a64647d79583526be8107802b1f9fedfa 5b5708a437f27665db42c5a261a539a1bcb2a8c2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  ef908e42ce65ef57f970d799acaddde26f58a4cc 5ffb9e311b35f6ab6f76f667ca5d6e595645481b 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'bob'}
  5b5708a437f27665db42c5a261a539a1bcb2a8c2 9866d64649a5d9c5991fe119c7b2c33898114e10 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  956063ac4557828781733b2d5677a351ce856f59 3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'celeste'}
  3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 77ae25d99ff07889e181126b1171b94bec8e5227 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}

Celeste now pushes to the server

(note: it would be enough to just have direct Celeste -> Alice exchange here.
However using a central server seems more common)

  $ hg push
  pushing to $TESTTMP/distributed-chain-building/distributed-chain-building/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  6 new obsolescence markers
  $ cd ..

Now Alice pulls from the server, then from Bob

Alice first retrieves the new evolution of its changesets and associated markers
from the server (note: could be from Celeste directly)

  $ cd repo-Alice
  $ hg up 'desc(ROOT)'
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg pull
  pulling from $TESTTMP/distributed-chain-building/distributed-chain-building/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 2 files (+1 heads)
  6 new obsolescence markers
  obsoleted 2 changesets
  new changesets 9866d64649a5:77ae25d99ff0 (2 drafts)
  (run 'hg heads' to see heads)
  $ hg debugobsolete
  3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 77ae25d99ff07889e181126b1171b94bec8e5227 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5b5708a437f27665db42c5a261a539a1bcb2a8c2 9866d64649a5d9c5991fe119c7b2c33898114e10 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5ffb9e311b35f6ab6f76f667ca5d6e595645481b 956063ac4557828781733b2d5677a351ce856f59 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  956063ac4557828781733b2d5677a351ce856f59 3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'celeste'}
  d33b0a3a64647d79583526be8107802b1f9fedfa 5b5708a437f27665db42c5a261a539a1bcb2a8c2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  ef908e42ce65ef57f970d799acaddde26f58a4cc 5ffb9e311b35f6ab6f76f667ca5d6e595645481b 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'bob'}

Then, she pulls from Bob, pulling predecessors of the changeset she has
already pulled. The changesets are not obsoleted in the Bob repo yet. Their
successors do not exist in Bob repository yet.

  $ hg pull ../repo-Bob
  pulling from ../repo-Bob
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 2 files (+1 heads)
  (2 other changesets obsolete on arrival)
  (run 'hg heads' to see heads)
  $ hg log -G
  o  4:77ae25d99ff0 c_B2
  |
  o  3:9866d64649a5 c_A2
  |
  @  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 77ae25d99ff07889e181126b1171b94bec8e5227 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5b5708a437f27665db42c5a261a539a1bcb2a8c2 9866d64649a5d9c5991fe119c7b2c33898114e10 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5ffb9e311b35f6ab6f76f667ca5d6e595645481b 956063ac4557828781733b2d5677a351ce856f59 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  956063ac4557828781733b2d5677a351ce856f59 3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'celeste'}
  d33b0a3a64647d79583526be8107802b1f9fedfa 5b5708a437f27665db42c5a261a539a1bcb2a8c2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  ef908e42ce65ef57f970d799acaddde26f58a4cc 5ffb9e311b35f6ab6f76f667ca5d6e595645481b 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'bob'}

Same tests, but change coming from a bundle
(testing with a bundle is interesting because absolutely no discovery or
decision is made in that case, so receiving the changesets are not an option).

  $ hg rollback
  repository tip rolled back to revision 4 (undo pull)
  $ hg log -G
  o  4:77ae25d99ff0 c_B2
  |
  o  3:9866d64649a5 c_A2
  |
  @  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 77ae25d99ff07889e181126b1171b94bec8e5227 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5b5708a437f27665db42c5a261a539a1bcb2a8c2 9866d64649a5d9c5991fe119c7b2c33898114e10 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5ffb9e311b35f6ab6f76f667ca5d6e595645481b 956063ac4557828781733b2d5677a351ce856f59 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  956063ac4557828781733b2d5677a351ce856f59 3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'celeste'}
  d33b0a3a64647d79583526be8107802b1f9fedfa 5b5708a437f27665db42c5a261a539a1bcb2a8c2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  ef908e42ce65ef57f970d799acaddde26f58a4cc 5ffb9e311b35f6ab6f76f667ca5d6e595645481b 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'bob'}
  $ hg -R ../repo-Bob bundle ../step-1.hg
  searching for changes
  2 changesets found
  $ hg unbundle ../step-1.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 2 files (+1 heads)
  (2 other changesets obsolete on arrival)
  (run 'hg heads' to see heads)
  $ hg log -G
  o  4:77ae25d99ff0 c_B2
  |
  o  3:9866d64649a5 c_A2
  |
  @  0:e82fb8d02bbf ROOT
  
  $ hg log -G --hidden -v
  x  6:956063ac4557 c_B1 [rewritten using amend, rebase as 4:77ae25d99ff0 by celeste (at 1970-01-01 00:00 +0000)]
  |
  x  5:5b5708a437f2 c_A1 [rewritten using amend as 3:9866d64649a5 by celeste (at 1970-01-01 00:00 +0000)]
  |
  | o  4:77ae25d99ff0 c_B2
  | |
  | o  3:9866d64649a5 c_A2
  |/
  | x  2:ef908e42ce65 c_B0 [rewritten using amend, rebase as 6:956063ac4557 by bob (at 1970-01-01 00:00 +0000)]
  | |
  | x  1:d33b0a3a6464 c_A0 [rewritten using amend as 5:5b5708a437f2 by bob (at 1970-01-01 00:00 +0000)]
  |/
  @  0:e82fb8d02bbf ROOT
  
  $ hg debugobsolete
  3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 77ae25d99ff07889e181126b1171b94bec8e5227 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5b5708a437f27665db42c5a261a539a1bcb2a8c2 9866d64649a5d9c5991fe119c7b2c33898114e10 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'celeste'}
  5ffb9e311b35f6ab6f76f667ca5d6e595645481b 956063ac4557828781733b2d5677a351ce856f59 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  956063ac4557828781733b2d5677a351ce856f59 3cf8de21cc2282186857d2266eb6b1f9cb85ecf3 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'celeste'}
  d33b0a3a64647d79583526be8107802b1f9fedfa 5b5708a437f27665db42c5a261a539a1bcb2a8c2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'bob'}
  ef908e42ce65ef57f970d799acaddde26f58a4cc 5ffb9e311b35f6ab6f76f667ca5d6e595645481b 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'rebase', 'user': 'bob'}


Same tests, but with --rev, this prevent regressing case where `hg pull --rev
X` has to process a X that is filtered locally.

  $ hg rollback
  repository tip rolled back to revision 4 (undo unbundle)
  $ hg pull ../repo-Bob --rev 956063ac4557
  pulling from ../repo-Bob
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 2 files (+1 heads)
  (2 other changesets obsolete on arrival)
  (run 'hg heads' to see heads)

With --update

  $ hg rollback
  repository tip rolled back to revision 4 (undo pull)
  $ hg pull ../repo-Bob --rev 956063ac4557 --update
  pulling from ../repo-Bob
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 2 files (+1 heads)
  (2 other changesets obsolete on arrival)
  abort: cannot update to target: filtered revision '6'
  [10]

  $ cd ..

Test pull report consistency
============================

obsolete but visible should be reported
---------------------------------------

Setup

  $ hg init repo-a
  $ cat << EOF >> repo-a/.hg/hgrc
  > [ui]
  > username=test
  > EOF
  $ cd repo-a
  $ hg debugbuilddag ..
  $ hg debugobsolete `getid tip`
  1 new obsolescence markers
  obsoleted 1 changesets
  $ cd ../
  $ hg clone --pull repo-a repo-b
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files
  new changesets 1ea73414a91b (1 drafts)
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R repo-a up tip --hidden
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updated to hidden changeset 66f7d451a68b
  (hidden revision '66f7d451a68b' is pruned)
  $ hg -R repo-a branch foo
  marked working directory as branch foo
  (branches are permanent and global, did you want a bookmark?)
  $ hg -R repo-a commit -m foo
  1 new orphan changesets

Actual test
(BROKEN)

  $ hg -R repo-b pull
  pulling from $TESTTMP/distributed-chain-building/distributed-chain-building/repo-a
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files
  1 new obsolescence markers
  1 new orphan changesets
  new changesets 66f7d451a68b:95d586532b49 (2 drafts)
  (run 'hg update' to get a working copy)
