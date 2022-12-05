==========================================================
Test various things around delta computation within revlog
==========================================================


basic setup
-----------

  $ cat << EOF >> $HGRCPATH
  > [debug]
  > revlog.debug-delta=yes
  > EOF
  $ cat << EOF >> sha256line.py
  > # a way to quickly produce file of significant size and poorly compressable content.
  > import hashlib
  > import sys
  > for line in sys.stdin:
  >     print(hashlib.sha256(line.encode('utf8')).hexdigest())
  > EOF

  $ hg init base-repo
  $ cd base-repo

create a "large" file

  $ $TESTDIR/seq.py 1000 | $PYTHON $TESTTMP/sha256line.py > my-file.txt
  $ hg add my-file.txt
  $ hg commit -m initial-commit
  DBG-DELTAS: FILELOG:my-file.txt: rev=0: delta-base=0 * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)

Add more change at the end of the file

  $ $TESTDIR/seq.py 1001 1200 | $PYTHON $TESTTMP/sha256line.py >> my-file.txt
  $ hg commit -m "large-change"
  DBG-DELTAS: FILELOG:my-file.txt: rev=1: delta-base=0 * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)

Add small change at the start

  $ hg up 'desc("initial-commit")' --quiet
  $ mv my-file.txt foo
  $ echo "small change at the start" > my-file.txt
  $ cat foo >> my-file.txt
  $ rm foo
  $ hg commit -m "small-change"
  DBG-DELTAS: FILELOG:my-file.txt: rev=2: delta-base=0 * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  created new head


  $ hg log -r 'head()' -T '{node}\n' >> ../base-heads.nodes
  $ hg log -r 'desc("initial-commit")' -T '{node}\n' >> ../initial.node
  $ hg log -r 'desc("small-change")' -T '{node}\n' >> ../small.node
  $ hg log -r 'desc("large-change")' -T '{node}\n' >> ../large.node
  $ cd ..

Check delta find policy and result for merge on commit
======================================================

Check that delta of merge pick best of the two parents
------------------------------------------------------

As we check against both parents, the one with the largest change should
produce the smallest delta and be picked.

  $ hg clone base-repo test-parents --quiet
  $ hg -R test-parents update 'nodefromfile("small.node")' --quiet
  $ hg -R test-parents merge 'nodefromfile("large.node")' --quiet

The delta base is the "large" revision as it produce a smaller delta.

  $ hg -R test-parents commit -m "merge from small change"
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=1 * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)

Check that the behavior tested above can we disabled
----------------------------------------------------

We disable the checking of both parent at the same time. The `small` change,
that produce a less optimal delta, should be picked first as it is "closer" to
the new commit.

  $ hg clone base-repo test-no-parents --quiet
  $ hg -R test-no-parents update 'nodefromfile("small.node")' --quiet
  $ hg -R test-no-parents merge 'nodefromfile("large.node")' --quiet

The delta base is the "large" revision as it produce a smaller delta.

  $ hg -R test-no-parents commit -m "merge from small change" \
  > --config storage.revlog.optimize-delta-parent-choice=no
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)


Check delta-find policy and result when unbundling
==================================================

Build a bundle with all delta built against p1

  $ hg bundle -R test-parents --all --config devel.bundle.delta=p1 all-p1.hg
  4 changesets found

Default policy of trusting delta from the bundle
------------------------------------------------

Keeping the `p1` delta used in the bundle is sub-optimal for storage, but
strusting in-bundle delta is faster to apply.

  $ hg init bundle-default
  $ hg -R bundle-default unbundle all-p1.hg --quiet
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=0: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=1: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=2: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)

(confirm the file revision are in the same order, 2 should be smaller than 1)

  $ hg -R bundle-default debugdata my-file.txt 2 | wc -l
  \s*1001 (re)
  $ hg -R bundle-default debugdata my-file.txt 1 | wc -l
  \s*1200 (re)

explicitly enabled
------------------

Keeping the `p1` delta used in the bundle is sub-optimal for storage, but
strusting in-bundle delta is faster to apply.

  $ hg init bundle-reuse-enabled
  $ hg -R bundle-reuse-enabled unbundle all-p1.hg --quiet \
  > --config storage.revlog.reuse-external-delta-parent=yes
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=0: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=1: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=2: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)

(confirm the file revision are in the same order, 2 should be smaller than 1)

  $ hg -R bundle-reuse-enabled debugdata my-file.txt 2 | wc -l
  \s*1001 (re)
  $ hg -R bundle-reuse-enabled debugdata my-file.txt 1 | wc -l
  \s*1200 (re)

explicitly disabled
-------------------

Not reusing the delta-base from the parent means we the delta will be made
against the "best" parent. (so not the same as the previous two)

  $ hg init bundle-reuse-disabled
  $ hg -R bundle-reuse-disabled unbundle all-p1.hg --quiet \
  > --config storage.revlog.reuse-external-delta-parent=no
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=0: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=1: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=2: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=1 * (glob)

(confirm the file revision are in the same order, 2 should be smaller than 1)

  $ hg -R bundle-reuse-disabled debugdata my-file.txt 2 | wc -l
  \s*1001 (re)
  $ hg -R bundle-reuse-disabled debugdata my-file.txt 1 | wc -l
  \s*1200 (re)
