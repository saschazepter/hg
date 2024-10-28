=====================================================
test behavior of the `internal` phase around bundling
=====================================================

Long story short, internal changeset are internal implementation details and
they should never leave the repository. Hence, they should never be in a
bundle.

Setup
=====

  $ cat << EOF >> $HGRCPATH
  > [ui]
  > logtemplate="{node|short} [{phase}] {desc|firstline}"
  > EOF


  $ hg init reference-repo --config format.use-internal-phase=yes
  $ cd reference-repo
  $ echo a > a
  $ hg add a
  $ hg commit -m "a"
  $ echo b > b
  $ hg add b
  $ hg commit -m "b"
  $ echo b > c
  $ hg add c
  $ hg commit -m "c"
  $ hg log -G
  @  07f0cc02c068 [draft] c
  |
  o  d2ae7f538514 [draft] b
  |
  o  cb9a9f314b8b [draft] a
  
  $ hg up ".^"
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved

do a shelve

  $ touch a_file.txt
  $ hg shelve -A
  adding a_file.txt
  shelved as default
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg log -G --hidden
  o  2ec3cf310d86 [internal] changes to: b
  |
  | o  07f0cc02c068 [draft] c
  |/
  @  d2ae7f538514 [draft] b
  |
  o  cb9a9f314b8b [draft] a
  
  $ shelved_node=`hg log --rev tip --hidden -T '{node|short}'`

add more changeset above it

  $ hg up 'desc(a)'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo d > d
  $ hg add d
  $ hg commit -m "d"
  created new head
  $ echo d > e
  $ hg add e
  $ hg commit -m "e"
  $ hg up null
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg log -G
  o  636bc07920e3 [draft] e
  |
  o  980f7dc84c29 [draft] d
  |
  | o  07f0cc02c068 [draft] c
  | |
  | o  d2ae7f538514 [draft] b
  |/
  o  cb9a9f314b8b [draft] a
  
  $ hg log -G --hidden
  o  636bc07920e3 [draft] e
  |
  o  980f7dc84c29 [draft] d
  |
  | o  2ec3cf310d86 [internal] changes to: b
  | |
  | | o  07f0cc02c068 [draft] c
  | |/
  | o  d2ae7f538514 [draft] b
  |/
  o  cb9a9f314b8b [draft] a
  
  $ cd ..

backup bundle from strip
========================

strip an ancestors of the internal changeset
--------------------------------------------

  $ cp -aR reference-repo strip-ancestor
  $ cd strip-ancestor

The internal change is stripped, yet it should be skipped from the backup bundle.

  $ hg log -G
  o  636bc07920e3 [draft] e
  |
  o  980f7dc84c29 [draft] d
  |
  | o  07f0cc02c068 [draft] c
  | |
  | o  d2ae7f538514 [draft] b
  |/
  o  cb9a9f314b8b [draft] a
  
  $ hg debugstrip 'desc(b)'
  saved backup bundle to $TESTTMP/strip-ancestor/.hg/strip-backup/d2ae7f538514-59bd8bc3-backup.hg

The change should be either gone or hidden

  $ hg log -G
  o  636bc07920e3 [draft] e
  |
  o  980f7dc84c29 [draft] d
  |
  o  cb9a9f314b8b [draft] a
  

The backup should not include it (as people tend to manipulate these directly)

  $ ls -1 .hg/strip-backup/
  d2ae7f538514-59bd8bc3-backup.hg
  $ hg debugbundle .hg/strip-backup/*.hg
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 2, version: 03} (mandatory: True)
      d2ae7f538514cd87c17547b0de4cea71fe1af9fb
      07f0cc02c06869c81ebf33867edef30554020c0d
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      07f0cc02c06869c81ebf33867edef30554020c0d draft

Shelve should still work

  $ hg unshelve
  unshelving change 'default'
  rebasing shelved changes
  $ hg status
  A a_file.txt

  $ cd ..

strip an unrelated changeset with a lower revnum
------------------------------------------------

  $ cp -aR reference-repo strip-unrelated
  $ cd strip-unrelated

The internal change is not directly stripped, but it is affected by the strip
and it is in the "temporary backup" zone. The zone that needs to be put in a
temporary bundle while we affect data under it.

  $ hg debugstrip 'desc(c)'
  saved backup bundle to $TESTTMP/strip-unrelated/.hg/strip-backup/07f0cc02c068-8fd0515f-backup.hg

The change should be either gone or hidden

  $ hg log -G
  o  636bc07920e3 [draft] e
  |
  o  980f7dc84c29 [draft] d
  |
  | o  d2ae7f538514 [draft] b
  |/
  o  cb9a9f314b8b [draft] a
  
The backup should not include it (as people tend to manipulate these directly)

  $ ls -1 .hg/strip-backup/
  07f0cc02c068-8fd0515f-backup.hg
  $ hg debugbundle .hg/strip-backup/*.hg
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 1, version: 03} (mandatory: True)
      07f0cc02c06869c81ebf33867edef30554020c0d
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      07f0cc02c06869c81ebf33867edef30554020c0d draft

Shelve should still work

  $ hg unshelve
  unshelving change 'default'
  rebasing shelved changes
  $ hg status
  A a_file.txt

  $ cd ..

explicitly strip the internal changeset
---------------------------------------

  $ cp -aR reference-repo strip-explicit
  $ cd strip-explicit

The internal change is directly selected for stripping.

  $ hg debugstrip --hidden $shelved_node

The change should be gone

  $ hg log -G --hidden
  o  636bc07920e3 [draft] e
  |
  o  980f7dc84c29 [draft] d
  |
  | o  07f0cc02c068 [draft] c
  | |
  | o  d2ae7f538514 [draft] b
  |/
  o  cb9a9f314b8b [draft] a
  

We don't need to backup anything

  $ ls -1 .hg/strip-backup/

Shelve should still work

  $ hg unshelve
  unshelving change 'default'
  rebasing shelved changes
  $ hg status
  A a_file.txt

  $ cd ..

Explicitly bundling the internal change
=======================================

  $ cd reference-repo

try to bundle it alone explicitly
---------------------------------

We should not allow it

  $ hg bundle --type v3 --exact --rev $shelved_node --hidden ../internal-01.hg
  abort: cannot bundle internal changesets
  (1 internal changesets selected)
  [255]
  $ hg debugbundle ../internal-01.hg
  abort: $ENOENT$: '../internal-01.hg' (no-windows !)
  abort: ../internal-01.hg: $ENOENT$ (windows !)
  [255]

try to bundle it with other, somewhat explicitly
------------------------------------------------

We should not allow it

  $ hg bundle --type v3 --exact --rev 'desc(b)':: --hidden ../internal-02.hg
  abort: cannot bundle internal changesets
  (1 internal changesets selected)
  [255]
  $ hg debugbundle ../internal-02.hg
  abort: $ENOENT$: '../internal-02.hg' (no-windows !)
  abort: ../internal-02.hg: $ENOENT$ (windows !)
  [255]

bundle visible ancestors
------------------------

This should succeed as the standard filtering is skipping the internal change naturally

  $ hg bundle --type v3 --exact --rev 'desc(b)':: ../internal-03.hg
  2 changesets found
  $ hg debugbundle ../internal-03.hg
  Stream params: {Compression: BZ}
  changegroup -- {nbchanges: 2, version: 03} (mandatory: True)
      d2ae7f538514cd87c17547b0de4cea71fe1af9fb
      07f0cc02c06869c81ebf33867edef30554020c0d
  cache:rev-branch-cache -- {} (mandatory: False)
  phase-heads -- {} (mandatory: True)
      07f0cc02c06869c81ebf33867edef30554020c0d draft

  $ cd ..

