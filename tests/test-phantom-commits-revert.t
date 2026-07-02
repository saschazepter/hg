#require rust

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > phantom_commits=
  > 
  > [phantom_commits]
  > bookmark = phantom
  > ai-user = ai
  > EOF

Set up repo
-----------

  $ hg init repo1
  $ cd repo1
  $ hg bookmark b1
  $ cat << EOF > .hgignore
  > syntax: glob
  > *.ignore
  > EOF
  $ hg ci -qAm "add .hgignore"
  $ touch file
  $ hg commit -qAm "add file"
  $ echo A > file
  $ hg commit -m "A"
  $ echo B > file
  $ hg commit -m "B"
  $ echo C > file
  $ hg commit -m "C"

  $ hg log -T '{rev}: {desc}\n'
  4: C
  3: B
  2: A
  1: add file
  0: add .hgignore

Helpers
-------

Helper to reset state to make each test independent
  $ reset_changes() {
  >   hg update -qr 4 --clean
  >   hg bookmark b1 --force
  >   hg purge --no-confirm --all
  > }

Test required flags
-------------------

  $ hg phantom-commits::revert
  abort: the -r/--rev flag is required
  [10]

Test basic behavior
-------------------

Invalid revision (not wdir parent or active phantom commit)
  $ hg phantom-commits::revert -r 0
  abort: * is invalid for phantom-commits::revert (glob)
  [255]

No-op revert
  $ hg phantom-commits::revert -r .
  $ hg status

Create a phantom commit
  $ echo change > file
  $ hg create-phantom-commit -q --message test

Revert to the last phantom commit (no-op)
  $ hg phantom-commits::revert -r phantom
  $ cat file
  change

Revert to the working directory parent
  $ hg phantom-commits::revert -r .
  reverting file

The file is reverted
  $ cat file
  C

The phantom bookmark was deleted
  $ hg debug::phantom-commits

  $ reset_changes

Test revert after adding
------------------------

Add some files and then revert
  $ touch untracked
  $ touch tracked
  $ hg add tracked
  $ hg phantom-commits::revert -r .
  forgetting tracked
  removing file tracked
  removing file untracked

It's as if we just ran `rm tracked untracked`, the dirstate is unchanged
  $ hg status
  ! tracked

But after addremove we have a clean status
  $ hg addremove
  removing tracked
  $ hg status

  $ reset_changes

Test revert after removing
--------------------------

Remove some files and then revert
  $ rm file
  $ hg rm .hgignore
  $ hg phantom-commits::revert -r .
  reverting file
  undeleting .hgignore

It's as if we just restored the files, the dirstate is unchanged
  $ hg status
  R .hgignore

But after addremove we have a clean status
  $ hg addremove
  adding .hgignore
  $ hg status

  $ reset_changes

Test reverting untracked content
--------------------------------

  $ echo 1 > untracked
  $ hg create-phantom-commit -q --message test
  $ first=$(hg log -r phantom -T "{node}")
  $ echo 2 > untracked
  $ hg create-phantom-commit -q --message test
  $ hg phantom-commits::revert -r $first
  adding untracked
  $ cat untracked
  1

  $ reset_changes

Test --dry-run flag
-------------------

  $ echo change > file
  $ touch untracked
  $ hg phantom-commits::revert -r . --dry-run
  reverting file
  removing file untracked
  $ hg status
  M file
  ? untracked

  $ reset_changes

Test --addremove flag
---------------------

  $ touch untracked
  $ rm file
  $ hg create-phantom-commit -q --message test

By default, it leaves the dirstate alone
  $ hg phantom-commits::revert -r phantom
  removing file
  adding untracked
  $ hg status
  ! file
  ? untracked

With --addremove, it tracks the changes in the dirstate
  $ hg phantom-commits::revert -r phantom --addremove
  removing file
  adding untracked
  $ hg status
  A untracked
  R file

  $ reset_changes

Test size limit
---------------

  $ cp $HGRCPATH $TESTTMP/hgrc.backup
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > unknown-files.size-limit=50
  > EOF

Prepare a file that will cross the limit, and a file that's already over it
  >>> open("cross-limit", "wb").write(b"x" * 50)
  50
  >>> open("over-limit", "wb").write(b"x" * 51)
  51
  $ hg create-phantom-commit -q --message test
  phantom_commits: ignoring 'over-limit' (51 bytes) since it exceeds size limit (50 bytes)

Cross the limit after the phantom commit
  >>> open("cross-limit", "wb").write(b"x" * 51)
  51

This reverts cross-limit since it's in the phantom commit, but it doesn't purge
over-limit since we have no idea if it was there or not when the phantom commit
was created.
  $ hg phantom-commits::revert -r phantom
  adding cross-limit
  $ f --size cross-limit over-limit
  cross-limit: size=50
  over-limit: size=51

  $ reset_changes
  $ mv $TESTTMP/hgrc.backup $HGRCPATH

Test revert after committing
----------------------------

This might be allowed in the future, but it would require some more thought.
(Do we also revert the active bookmark? Or do we create a new commit?)

Cannot revert to old phantom commit after committing
  $ echo change1 > file
  $ hg create-phantom-commit -q --message test --ai
  $ rev=$(hg log -r phantom -T "{node}")
  $ hg commit -qm test
  $ hg phantom-commits::revert -r $rev
  abort: * is invalid for phantom-commits::revert (glob)
  [255]

  $ reset_changes

Test reverting back and forth
-----------------------------

Create two phantom commits
  $ echo change1 > file
  $ hg create-phantom-commit -q --message test
  $ first=$(hg log -r phantom -T "{node}")
  $ echo change2 > file
  $ hg create-phantom-commit -q --message test
  $ second=$(hg log -r phantom -T "{node}")
  $ hg debug::phantom-commits
  #1 5f4d87303616 1970-01-01T00:00:00+0000 test
  #2 bcc7b017519a 1970-01-01T00:00:00+0000 test

Revert to the first one
  $ hg phantom-commits::revert -r $first
  reverting file
  $ cat file
  change1
  $ hg debug::phantom-commits
  #1 5f4d87303616 1970-01-01T00:00:00+0000 test

Reverting back to the second one
  $ hg phantom-commits::revert -r $second
  reverting file
  $ cat file
  change2
  $ hg debug::phantom-commits
  #1 5f4d87303616 1970-01-01T00:00:00+0000 test
  #2 bcc7b017519a 1970-01-01T00:00:00+0000 test

  $ reset_changes

Test all file statuses
----------------------

This section tests all combinations of file statuses when reverting.
Files are named like XY where X is status code when we create the phantom commit
and Y is the status code just before we revert to the phantom commit.

Touch files with first letter C (clean), M (modified), R (removed), and
D (for "!", missing) before committing, since they must start out tracked.
  $ touch CC CM CR CD
  $ touch MC MM MR MD
  $ touch RC RM RR RD
  $ touch DC DM DR DD
  $ hg ci -qAm base

Touch files with first letter A (added) and U (for "?", unknown) after
committing, since they must start out untracked.
  $ touch AC AA AU AD
  $ touch UC UA UU UD

Do the first letter
  $ echo change | tee M* > /dev/null
  $ hg rm R*
  $ rm D*
  $ hg add A*
  $ hg status
  M MC
  M MD
  M MM
  M MR
  A AA
  A AC
  A AD
  A AU
  R RC
  R RD
  R RM
  R RR
  ! DC
  ! DD
  ! DM
  ! DR
  ? UA
  ? UC
  ? UD
  ? UU

Create the phantom commit
  $ hg create-phantom-commit -q --message test
  ignoring stale phantom bookmark phantom (*) (glob)
  $ rev=$(hg log -r phantom -T "{node}")


Do the second letter
  $ do_second_letter() {
  > hg revert --all --no-backup --quiet
  > # First letter "_" means did not exist in the phantom commit.
  > touch _A _U
  > echo change | tee *M > /dev/null
  > hg rm *R
  > rm *D AC UC
  > hg add *A
  > }
  $ do_second_letter
  $ hg status
  M CM
  M DM
  M MM
  M RM
  A AA
  A UA
  A _A
  R CR
  R DR
  R MR
  R RR
  ! CD
  ! DD
  ! MD
  ! RD
  ? AU
  ? UU
  ? _U

Revert
  $ hg phantom-commits::revert -r $rev --quiet

The status is now like this:
1. The files _U and _A are gone, and _A is still added so it's missing ("!").
2. If the second letter is A or R, then status stays at that.
3. Otherwise, it's back to the first letter, but A->U and R->D.
  $ hg status
  M MC
  M MD
  M MM
  A AA
  A UA
  R CR
  R DR
  R MR
  R RR
  ! DC
  ! DD
  ! DM
  ! RC
  ! RD
  ! RM
  ! _A
  ? AC
  ? AD
  ? AU
  ? UC
  ? UD
  ? UU

The files that are marked for removal in the dirstate but should exist according
to their first letter, do in fact exist:
  $ ls CR MR
  CR
  MR

If we addremove, then the status matches the first letter but U->A and D->R.
  $ hg addremove -q
  $ hg status
  M MC
  M MD
  M MM
  M MR
  A AA
  A AC
  A AD
  A AU
  A UA
  A UC
  A UD
  A UU
  R DC
  R DD
  R DM
  R DR
  R RC
  R RD
  R RM
  R RR

Revert --addremove behaves like revert + addremove
  $ do_second_letter
  $ hg phantom-commits::revert -r $rev --addremove --quiet
  $ hg status
  M MC
  M MD
  M MM
  M MR
  A AA
  A AC
  A AD
  A AU
  A UA
  A UC
  A UD
  A UU
  R DC
  R DD
  R DM
  R DR
  R RC
  R RD
  R RM
  R RR

  $ hg bookmark -d phantom
  $ reset_changes

Test phantom-last-ai bookmark
-----------------------------

  $ cp $HGRCPATH $TESTTMP/hgrc.backup
  $ cat << EOF >> $HGRCPATH
  > [phantom_commits]
  > last-ai-bookmark=lastai
  > EOF

With no flag, it leaves the bookmark alone
  $ echo change1 > file
  $ hg create-phantom-commit --message test --ai
  in-progress
  revision 86dba96483db787825345498a0584673bd0333e6
  $ hg phantom-commits::revert -r .
  reverting file
  $ hg log -r lastai -T "{node}\n"
  86dba96483db787825345498a0584673bd0333e6

With --delete-last-ai, it deletes the bookmark
  $ hg phantom-commits::revert -r . --delete-last-ai
  $ hg log -r lastai -T "{node}\n"
  abort: unknown revision 'lastai'
  [10]

With --update-last-ai, it deletes the bookmark if there is no earlier AI rev
  $ echo change1 > file
  $ hg create-phantom-commit -q --message test --ai
  $ hg phantom-commits::revert -r . --update-last-ai
  reverting file
  $ hg log -r lastai -T "{node}\n"
  abort: unknown revision 'lastai'
  [10]

With --update-last-ai, it updates to an earlier AI rev if there is one
  $ echo change1 > file
  $ hg create-phantom-commit --message test --ai
  in-progress
  revision 86dba96483db787825345498a0584673bd0333e6
  $ first=$(hg log -r phantom -T "{node}")
  $ echo change2 > file
  $ hg create-phantom-commit --message test
  in-progress
  revision 13e9efd98efbf732089d67126256daac6a75198a
  $ second=$(hg log -r phantom -T "{node}")
  $ hg phantom-commits::revert -r $second --update-last-ai
  $ hg log -r lastai -T "{node}\n"
  86dba96483db787825345498a0584673bd0333e6
  $ hg phantom-commits::revert -r $first --update-last-ai
  reverting file
  $ hg log -r lastai -T "{node}\n"
  86dba96483db787825345498a0584673bd0333e6

  $ reset_changes
  $ mv $TESTTMP/hgrc.backup $HGRCPATH
