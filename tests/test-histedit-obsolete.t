#testcases abortcommand abortflag

#if abortflag
  $ cat >> $HGRCPATH <<EOF
  > [alias]
  > abort = histedit --abort
  > EOF
#endif

  $ . "$TESTDIR/histedit-helpers.sh"

Enable obsolete

  $ cat >> $HGRCPATH << EOF
  > [ui]
  > logtemplate= {rev}:{node|short} {desc|firstline}
  > [phases]
  > publish=False
  > [experimental]
  > evolution.createmarkers=True
  > evolution.allowunstable=True
  > [extensions]
  > histedit=
  > rebase=
  > EOF

Test that histedit learns about obsolescence not stored in histedit state
  $ hg init boo
  $ cd boo
  $ echo a > a
  $ hg ci -Am a
  adding a
  $ echo a > b
  $ echo a > c
  $ echo a > c
  $ hg ci -Am b
  adding b
  adding c
  $ echo a > d
  $ hg ci -Am c
  adding d
  $ echo "pick `hg log -r 0 -T '{node|short}'`" > plan
  $ echo "pick `hg log -r 2 -T '{node|short}'`" >> plan
  $ echo "edit `hg log -r 1 -T '{node|short}'`" >> plan
  $ hg histedit -r 'all()' --commands plan
  Editing (1b2d564fad96), commit as needed now to split the change
  (to edit 1b2d564fad96, `hg histedit --continue` after making changes)
  [240]
  $ hg st
  A b
  A c
  ? plan
  $ hg commit --amend b
  $ hg histedit --continue
  $ hg log -G
  @  5:46abc7c4d873 b
  |
  o  4:49d44ab2be1b c
  |
  o  0:cb9a9f314b8b a
  
  $ hg debugobsolete
  e72d22b19f8ecf4150ab4f91d0973fd9955d3ddf 49d44ab2be1b67a79127568a67c9c99430633b48 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}
  1b2d564fad96311b45362f17c2aa855150efb35f 46abc7c4d8738e8563e577f7889e1b6db3da4199 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '12', 'operation': 'histedit', 'user': 'test'}
  114f4176969ef342759a8a57e6bccefc4234829b 49d44ab2be1b67a79127568a67c9c99430633b48 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '12', 'operation': 'histedit', 'user': 'test'}

With some node gone missing during the edit.

  $ echo "pick `hg log -r 0 -T '{node|short}'`" > plan
  $ echo "pick `hg log -r 5 -T '{node|short}'`" >> plan
  $ echo "edit `hg log -r 4 -T '{node|short}'`" >> plan
  $ hg histedit -r 'all()' --commands plan
  Editing (49d44ab2be1b), commit as needed now to split the change
  (to edit 49d44ab2be1b, `hg histedit --continue` after making changes)
  [240]
  $ hg st
  A b
  A d
  ? plan
  $ hg commit --amend -X . -m XXXXXX
  $ hg commit --amend -X . -m b2
  $ hg --hidden --config extensions.strip= strip 'desc(XXXXXX)' --no-backup
  $ hg continue
  $ hg log -G
  @  8:273c1f3b8626 c
  |
  o  7:aba7da937030 b2
  |
  o  0:cb9a9f314b8b a
  
  $ hg debugobsolete
  e72d22b19f8ecf4150ab4f91d0973fd9955d3ddf 49d44ab2be1b67a79127568a67c9c99430633b48 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '8', 'operation': 'amend', 'user': 'test'}
  1b2d564fad96311b45362f17c2aa855150efb35f 46abc7c4d8738e8563e577f7889e1b6db3da4199 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '12', 'operation': 'histedit', 'user': 'test'}
  114f4176969ef342759a8a57e6bccefc4234829b 49d44ab2be1b67a79127568a67c9c99430633b48 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '12', 'operation': 'histedit', 'user': 'test'}
  76f72745eac0643d16530e56e2f86e36e40631f1 2ca853e48edbd6453a0674dc0fe28a0974c51b9c 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  2ca853e48edbd6453a0674dc0fe28a0974c51b9c aba7da93703075eec9fb1dbaf143ff2bc1c49d46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '1', 'operation': 'amend', 'user': 'test'}
  49d44ab2be1b67a79127568a67c9c99430633b48 273c1f3b86267ed3ec684bb13af1fa4d6ba56e02 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'histedit', 'user': 'test'}
  46abc7c4d8738e8563e577f7889e1b6db3da4199 aba7da93703075eec9fb1dbaf143ff2bc1c49d46 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '5', 'operation': 'histedit', 'user': 'test'}
  $ cd ..

Base setup for the rest of the testing
======================================

  $ hg init base
  $ cd base

  $ for x in a b c d e f ; do
  >     echo $x > $x
  >     hg add $x
  >     hg ci -m $x
  > done

  $ hg log --graph
  @  5:652413bf663e f
  |
  o  4:e860deea161a e
  |
  o  3:055a42cdd887 d
  |
  o  2:177f92b77385 c
  |
  o  1:d2ae7f538514 b
  |
  o  0:cb9a9f314b8b a
  

  $ HGEDITOR=cat hg histedit 1
  pick d2ae7f538514 1 b
  pick 177f92b77385 2 c
  pick 055a42cdd887 3 d
  pick e860deea161a 4 e
  pick 652413bf663e 5 f
  
  # Edit history between d2ae7f538514 and 652413bf663e
  #
  # Commits are listed from least to most recent
  #
  # You can reorder changesets by reordering the lines
  #
  # Commands:
  #
  #  e, edit = use commit, but allow edits before making new commit
  #  m, mess = edit commit message without changing commit content
  #  p, pick = use commit
  #  b, base = checkout changeset and apply further changesets from there
  #  d, drop = remove commit from history
  #  f, fold = use commit, but combine it with the one above
  #  r, roll = like fold, but discard this commit's description and date
  #
  $ hg histedit 1 --commands - --verbose <<EOF | grep histedit
  > pick 177f92b77385 2 c
  > drop d2ae7f538514 1 b
  > pick 055a42cdd887 3 d
  > fold e860deea161a 4 e
  > pick 652413bf663e 5 f
  > EOF
  [1]
  $ hg log --graph --hidden
  @  10:cacdfd884a93 f
  |
  o  9:59d9f330561f d
  |
  | x  8:b558abc46d09 fold-temp-revision e860deea161a
  | |
  | x  7:96e494a2d553 d
  |/
  o  6:b346ab9a313d c
  |
  | x  5:652413bf663e f
  | |
  | x  4:e860deea161a e
  | |
  | x  3:055a42cdd887 d
  | |
  | x  2:177f92b77385 c
  | |
  | x  1:d2ae7f538514 b
  |/
  o  0:cb9a9f314b8b a
  
  $ hg debugobsolete
  d2ae7f538514cd87c17547b0de4cea71fe1af9fb 0 {cb9a9f314b8b07ba71012fcdbc544b5a4d82ff5b} (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '0', 'operation': 'histedit', 'user': 'test'}
  177f92b773850b59254aa5e923436f921b55483b b346ab9a313db8537ecf96fca3ca3ca984ef3bd7 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'histedit', 'user': 'test'}
  055a42cdd88768532f9cf79daa407fc8d138de9b 59d9f330561fd6c88b1a6b32f0e45034d88db784 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '13', 'operation': 'histedit', 'user': 'test'}
  e860deea161a2f77de56603b340ebbb4536308ae 59d9f330561fd6c88b1a6b32f0e45034d88db784 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '13', 'operation': 'histedit', 'user': 'test'}
  652413bf663ef2a641cab26574e46d5f5a64a55a cacdfd884a9321ec4e1de275ef3949fa953a1f83 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'histedit', 'user': 'test'}
  96e494a2d553dd05902ba1cee1d94d4cb7b8faed 0 {b346ab9a313db8537ecf96fca3ca3ca984ef3bd7} (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '0', 'operation': 'histedit', 'user': 'test'}
  b558abc46d09c30f57ac31e85a8a3d64d2e906e4 0 {96e494a2d553dd05902ba1cee1d94d4cb7b8faed} (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '0', 'operation': 'histedit', 'user': 'test'}


Ensure hidden revision does not prevent histedit
-------------------------------------------------

create an hidden revision

  $ hg histedit 6 --commands - << EOF
  > pick b346ab9a313d 6 c
  > drop 59d9f330561f 7 d
  > pick cacdfd884a93 8 f
  > EOF
  $ hg log --graph
  @  11:c13eb81022ca f
  |
  o  6:b346ab9a313d c
  |
  o  0:cb9a9f314b8b a
  
check hidden revision are ignored (6 have hidden children 7 and 8)

  $ hg histedit 6 --commands - << EOF
  > pick b346ab9a313d 6 c
  > pick c13eb81022ca 8 f
  > EOF



Test that rewriting leaving instability behind is allowed
---------------------------------------------------------------------

  $ hg up '.^'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg log -r 'children(.)'
  11:c13eb81022ca f (no-eol)
  $ hg histedit -r '.' --commands - <<EOF
  > edit b346ab9a313d 6 c
  > EOF
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  Editing (b346ab9a313d), commit as needed now to split the change
  (to edit b346ab9a313d, `hg histedit --continue` after making changes)
  [240]
  $ echo c >> c
  $ hg histedit --continue
  1 new orphan changesets

  $ hg log -r 'orphan()'
  11:c13eb81022ca f (no-eol)

stabilise

  $ hg rebase  -r 'orphan()' -d .
  rebasing 11:c13eb81022ca "f"
  $ hg up tip -q

Test dropping of changeset on the top of the stack
-------------------------------------------------------

Nothing is rewritten below, the working directory parent must be change for the
dropped changeset to be hidden.

  $ cd ..
  $ hg clone base droplast
  updating to branch default
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd droplast
  $ hg histedit -r '40db8afa467b' --commands - << EOF
  > pick 40db8afa467b 10 c
  > drop b449568bf7fc 11 f
  > EOF
  $ hg log -G
  @  12:40db8afa467b c
  |
  o  0:cb9a9f314b8b a
  

With rewritten ancestors

  $ echo e > e
  $ hg add e
  $ hg commit -m g
  $ echo f > f
  $ hg add f
  $ hg commit -m h
  $ hg histedit -r '40db8afa467b' --commands - << EOF
  > pick 47a8561c0449 12 g
  > pick 40db8afa467b 10 c
  > drop 1b3b05f35ff0 13 h
  > EOF
  $ hg log -G
  @  17:ee6544123ab8 c
  |
  o  16:269e713e9eae g
  |
  o  0:cb9a9f314b8b a
  
  $ cd ../base



Test phases support
===========================================

Check that histedit respect immutability
-------------------------------------------

  $ cat >> $HGRCPATH << EOF
  > [command-templates]
  > log = {rev}:{node|short} ({phase}) {desc|firstline}\n
  > EOF

  $ hg ph -pv '.^'
  phase changed for 2 changesets
  $ hg log -G
  @  13:b449568bf7fc (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ hg histedit -r '.~2'
  abort: cannot edit public changesets: cb9a9f314b8b, 40db8afa467b
  (see 'hg help phases' for details)
  [10]


Prepare further testing
-------------------------------------------

  $ for x in g h i j k ; do
  >     echo $x > $x
  >     hg add $x
  >     hg ci -m $x
  > done
  $ hg phase --force --secret .~2
  $ hg log -G
  @  18:ee118ab9fa44 (secret) k
  |
  o  17:3a6c53ee7f3d (secret) j
  |
  o  16:b605fb7503f2 (secret) i
  |
  o  15:7395e1ff83bd (draft) h
  |
  o  14:6b70183d2492 (draft) g
  |
  o  13:b449568bf7fc (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ cd ..

simple phase conservation
-------------------------------------------

Resulting changeset should conserve the phase of the original one whatever the
phases.new-commit option is.

New-commit as draft (default)

  $ cp -R base simple-draft
  $ cd simple-draft
  $ hg histedit -r 'b449568bf7fc' --commands - << EOF
  > edit b449568bf7fc 11 f
  > pick 6b70183d2492 12 g
  > pick 7395e1ff83bd 13 h
  > pick b605fb7503f2 14 i
  > pick 3a6c53ee7f3d 15 j
  > pick ee118ab9fa44 16 k
  > EOF
  0 files updated, 0 files merged, 6 files removed, 0 files unresolved
  Editing (b449568bf7fc), commit as needed now to split the change
  (to edit b449568bf7fc, `hg histedit --continue` after making changes)
  [240]
  $ echo f >> f
  $ hg continue
  $ hg log -G
  @  24:12e89af74238 (secret) k
  |
  o  23:636a8687b22e (secret) j
  |
  o  22:ccaf0a38653f (secret) i
  |
  o  21:11a89d1c2613 (draft) h
  |
  o  20:c1dec7ca82ea (draft) g
  |
  o  19:087281e68428 (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ cd ..


New-commit as secret (config)

  $ cp -R base simple-secret
  $ cd simple-secret
  $ cat >> .hg/hgrc << EOF
  > [phases]
  > new-commit=secret
  > EOF
  $ hg histedit -r 'b449568bf7fc' --commands - << EOF
  > edit b449568bf7fc 11 f
  > pick 6b70183d2492 12 g
  > pick 7395e1ff83bd 13 h
  > pick b605fb7503f2 14 i
  > pick 3a6c53ee7f3d 15 j
  > pick ee118ab9fa44 16 k
  > EOF
  0 files updated, 0 files merged, 6 files removed, 0 files unresolved
  Editing (b449568bf7fc), commit as needed now to split the change
  (to edit b449568bf7fc, `hg histedit --continue` after making changes)
  [240]
  $ echo f >> f
  $ hg histedit --continue
  $ hg log -G
  @  24:12e89af74238 (secret) k
  |
  o  23:636a8687b22e (secret) j
  |
  o  22:ccaf0a38653f (secret) i
  |
  o  21:11a89d1c2613 (draft) h
  |
  o  20:c1dec7ca82ea (draft) g
  |
  o  19:087281e68428 (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ cd ..


Changeset reordering
-------------------------------------------

If a secret changeset is put before a draft one, all descendant should be secret.
It seems more important to present the secret phase.

  $ cp -R base reorder
  $ cd reorder
  $ hg histedit -r 'b449568bf7fc' --commands - << EOF
  > pick b449568bf7fc 11 f
  > pick 3a6c53ee7f3d 15 j
  > pick 6b70183d2492 12 g
  > pick b605fb7503f2 14 i
  > pick 7395e1ff83bd 13 h
  > pick ee118ab9fa44 16 k
  > EOF
  $ hg log -G
  @  23:558246857888 (secret) k
  |
  o  22:28bd44768535 (secret) h
  |
  o  21:d5395202aeb9 (secret) i
  |
  o  20:21edda8e341b (secret) g
  |
  o  19:5ab64f3a4832 (secret) j
  |
  o  13:b449568bf7fc (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ cd ..

Changeset folding
-------------------------------------------

Folding a secret changeset with a draft one turn the result secret (again,
better safe than sorry). Folding between same phase changeset still works

Note that there is a few reordering in this series for more extensive test

  $ cp -R base folding
  $ cd folding
  $ cat >> .hg/hgrc << EOF
  > [phases]
  > new-commit=secret
  > EOF
  $ hg histedit -r 'b449568bf7fc' --commands - << EOF
  > pick 7395e1ff83bd 13 h
  > fold b449568bf7fc 11 f
  > pick 6b70183d2492 12 g
  > fold 3a6c53ee7f3d 15 j
  > pick b605fb7503f2 14 i
  > fold ee118ab9fa44 16 k
  > EOF
  $ hg log -G
  @  27:f9daec13fb98 (secret) i
  |
  o  24:49807617f46a (secret) g
  |
  o  21:050280826e04 (draft) h
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ hg co 49807617f46a
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo wat >> wat
  $ hg add wat
  $ hg ci -m 'add wat'
  created new head
  $ hg merge f9daec13fb98
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'merge'
  $ echo not wat > wat
  $ hg ci -m 'modify wat'
  $ hg histedit 050280826e04
  abort: cannot edit history that contains merges
  [20]
  $ cd ..

Check abort behavior
-------------------------------------------

We checks that abort properly clean the repository so the same histedit can be
attempted later.

  $ cp -R base abort
  $ cd abort
  $ hg histedit -r 'b449568bf7fc' --commands - << EOF
  > pick b449568bf7fc 13 f
  > pick 7395e1ff83bd 15 h
  > pick 6b70183d2492 14 g
  > pick b605fb7503f2 16 i
  > roll 3a6c53ee7f3d 17 j
  > edit ee118ab9fa44 18 k
  > EOF
  Editing (ee118ab9fa44), commit as needed now to split the change
  (to edit ee118ab9fa44, `hg histedit --continue` after making changes)
  [240]

#if abortcommand
when in dry-run mode
  $ hg abort --dry-run
  histedit in progress, will be aborted
#endif

  $ hg abort
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/abort/.hg/strip-backup/4dc06258baa6-dff4ef05-backup.hg

  $ hg log -G
  @  18:ee118ab9fa44 (secret) k
  |
  o  17:3a6c53ee7f3d (secret) j
  |
  o  16:b605fb7503f2 (secret) i
  |
  o  15:7395e1ff83bd (draft) h
  |
  o  14:6b70183d2492 (draft) g
  |
  o  13:b449568bf7fc (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ hg histedit -r 'b449568bf7fc' --commands - << EOF --config experimental.evolution.track-operation=1
  > pick b449568bf7fc 13 f
  > pick 7395e1ff83bd 15 h
  > pick 6b70183d2492 14 g
  > pick b605fb7503f2 16 i
  > pick 3a6c53ee7f3d 17 j
  > edit ee118ab9fa44 18 k
  > EOF
  Editing (ee118ab9fa44), commit as needed now to split the change
  (to edit ee118ab9fa44, `hg histedit --continue` after making changes)
  [240]
  $ hg continue --config experimental.evolution.track-operation=1
  $ hg log -G
  @  23:175d6b286a22 (secret) k
  |
  o  22:44ca09d59ae4 (secret) j
  |
  o  21:31747692a644 (secret) i
  |
  o  20:9985cd4f21fa (draft) g
  |
  o  19:4dc06258baa6 (draft) h
  |
  o  13:b449568bf7fc (draft) f
  |
  o  12:40db8afa467b (public) c
  |
  o  0:cb9a9f314b8b (public) a
  
  $ hg debugobsolete --rev .
  ee118ab9fa44ebb86be85996548b5517a39e5093 175d6b286a224c23f192e79a581ce83131a53fa2 0 (Thu Jan 01 00:00:00 1970 +0000) {'ef1': '4', 'operation': 'histedit', 'user': 'test'}
