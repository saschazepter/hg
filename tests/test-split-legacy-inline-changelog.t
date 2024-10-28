======================================================
Test operation on repository with an inlined changelog
======================================================

Inlined revlog has been a bag of complexity for a long time and the combination
with special transaction logic on the changelog was a long source of bugs
poorly covered by the test suites.

We stopped doing any usage of inlined-revlog for changelog in a93e52f0b6ff,
upgrading legacy inlined version as soon as possible when we see them. However
this Mercurial does not produce such inlined-changelog that case is very poorly
covered in the test suites. This test file aims at covering these cases.

Double checking test data
=========================

We should have a repository around

  $ mkdir sanity-check
  $ cd sanity-check
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -

  $ cd inlined-changelog
  $ hg root
  $TESTTMP/sanity-check/inlined-changelog

The repository should not be corrupted initially

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 1 changesets with 1 changes to 1 files

The changelog of that repository MUST be inlined

  $ hg debugrevlog -c | grep -E '^flags\b'
  flags  : inline

Touching that repository MUST split that inlined changelog

  $ hg branch foo --quiet
  $ hg commit -m foo --quiet
  $ hg debugrevlog -c | grep -E '^flags\b'
  flags  : (none)

  $ cd ../..

Test doing a simple commit
==========================

Simple commit
-------------

  $ mkdir simple-commit
  $ cd simple-commit
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -
  $ cd inlined-changelog
  $ hg up --quiet
  $ hg log -GT '[{rev}] {desc}\n'
  @  [0] first commit
  
  $ echo b > b
  $ hg add b
  $ hg commit -m "second changeset"
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 2 files
  $ hg log -GT '[{rev}] {desc}\n'
  @  [1] second changeset
  |
  o  [0] first commit
  
  $ cd ../..

Simple commit with a pretxn hook configured
-------------------------------------------

Before 6.7.3 this used to delete the changelog index

  $ mkdir pretxnclose-commit
  $ cd pretxnclose-commit
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -
  $ cat >> inlined-changelog/.hg/hgrc <<EOF
  > [hooks]
  > pretxnclose=hg log -r tip -T "pre-txn tip rev: {rev}\n"
  > EOF
  $ cd inlined-changelog
  $ hg up --quiet
  $ hg log -GT '[{rev}] {desc}\n'
  @  [0] first commit
  
  $ echo b > b
  $ hg add b
  $ hg commit -m "second changeset"
  pre-txn tip rev: 1
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 2 files
  $ hg log -GT '[{rev}] {desc}\n'
  @  [1] second changeset
  |
  o  [0] first commit
  
  $ cd ../..

Test pushing to a repository with a repository revlog
=====================================================

Simple local push
-----------------

  $ mkdir simple-local-push
  $ cd simple-local-push
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [0] first commit

  $ hg clone --pull inlined-changelog client
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 827f11bfd362
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client
  $ echo b > b
  $ hg add b
  $ hg commit -m "second changeset"
  $ hg push
  pushing to $TESTTMP/*/inlined-changelog (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ cd ..

  $ hg verify -R inlined-changelog
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 2 files
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [1] second changeset
  [0] first commit
  $ cd ..

Simple local push with a pretxnchangegroup hook
-----------------------------------------------

Before 6.7.3 this used to delete the server changelog

  $ mkdir pretxnchangegroup-local-push
  $ cd pretxnchangegroup-local-push
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -
  $ cat >> inlined-changelog/.hg/hgrc <<EOF
  > [hooks]
  > pretxnchangegroup=hg log -r tip -T "pre-txn tip rev: {rev}\n"
  > EOF
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [0] first commit

  $ hg clone --pull inlined-changelog client
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 827f11bfd362
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client
  $ echo b > b
  $ hg add b
  $ hg commit -m "second changeset"
  $ hg push
  pushing to $TESTTMP/*/inlined-changelog (glob)
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  pre-txn tip rev: 1
  added 1 changesets with 1 changes to 1 files
  $ cd ..

  $ hg verify -R inlined-changelog
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 2 files
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [1] second changeset
  [0] first commit
  $ cd ..

Simple ssh push
-----------------

  $ mkdir simple-ssh-push
  $ cd simple-ssh-push
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [0] first commit

  $ hg clone ssh://user@dummy/"`pwd`"/inlined-changelog client
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 827f11bfd362
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client
  $ echo b > b
  $ hg add b
  $ hg commit -m "second changeset"
  $ hg push
  pushing to ssh://user@dummy/$TESTTMP/simple-ssh-push/inlined-changelog
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  $ cd ..

  $ hg verify -R inlined-changelog
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 2 files
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [1] second changeset
  [0] first commit
  $ cd ..

Simple ssh push with a pretxnchangegroup hook
-----------------------------------------------

Before 6.7.3 this used to delete the server changelog

  $ mkdir pretxnchangegroup-ssh-push
  $ cd pretxnchangegroup-ssh-push
  $ cat "$TESTDIR/bundles/inlined-changelog.tar" |  tar xf -
  $ cat >> inlined-changelog/.hg/hgrc <<EOF
  > [hooks]
  > pretxnchangegroup=hg log -r tip -T "pre-txn tip rev: {rev}\n"
  > EOF
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [0] first commit

  $ hg clone ssh://user@dummy/"`pwd`"/inlined-changelog client
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 827f11bfd362
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client
  $ echo b > b
  $ hg add b
  $ hg commit -m "second changeset"
  $ hg push
  pushing to ssh://user@dummy/$TESTTMP/pretxnchangegroup-ssh-push/inlined-changelog
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: pre-txn tip rev: 1
  remote: added 1 changesets with 1 changes to 1 files
  $ cd ..

  $ hg verify -R inlined-changelog
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 2 changesets with 2 changes to 2 files
  $ hg log -R inlined-changelog -T '[{rev}] {desc}\n'
  [1] second changeset
  [0] first commit
  $ cd ..
