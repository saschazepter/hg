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


Check the path.*:pulled-delta-reuse-policy option
==========================================

Get a repository with the bad parent picked and a clone ready to pull the merge

  $ cp -ar bundle-reuse-enabled peer-bad-delta
  $ hg clone peer-bad-delta local-pre-pull --rev `cat large.node` --rev `cat small.node` --quiet
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=0: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=1: delta-base=0 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=2: delta-base=0 * (glob)

Check the parent order for the file

  $ hg -R local-pre-pull debugdata my-file.txt 2 | wc -l
  \s*1001 (re)
  $ hg -R local-pre-pull debugdata my-file.txt 1 | wc -l
  \s*1200 (re)

Pull with no value (so the default)
-----------------------------------

default is to reuse the (bad) delta

  $ cp -ar local-pre-pull local-no-value
  $ hg -R local-no-value pull --quiet
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)

Pull with explicitly the default
--------------------------------

default is to reuse the (bad) delta

  $ cp -ar local-pre-pull local-default
  $ hg -R local-default pull --quiet --config 'paths.default:pulled-delta-reuse-policy=default'
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)

Pull with no-reuse
------------------

We don't reuse the base, so we get a better delta

  $ cp -ar local-pre-pull local-no-reuse
  $ hg -R local-no-reuse pull --quiet --config 'paths.default:pulled-delta-reuse-policy=no-reuse'
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=1 * (glob)

Pull with try-base
------------------

We requested to use the (bad) delta

  $ cp -ar local-pre-pull local-try-base
  $ hg -R local-try-base pull --quiet --config 'paths.default:pulled-delta-reuse-policy=try-base'
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)

Case where we force a "bad" delta to be applied
===============================================

We build a very different file content to force a full snapshot

  $ cp -ar peer-bad-delta peer-bad-delta-with-full
  $ cp -ar local-pre-pull local-pre-pull-full
  $ echo '[paths]' >> local-pre-pull-full/.hg/hgrc
  $ echo 'default=../peer-bad-delta-with-full' >> local-pre-pull-full/.hg/hgrc

  $ hg -R peer-bad-delta-with-full update 'desc("merge")' --quiet
  $ ($TESTDIR/seq.py 2000 2100; $TESTDIR/seq.py 500 510; $TESTDIR/seq.py 3000 3050) \
  > | $PYTHON $TESTTMP/sha256line.py > peer-bad-delta-with-full/my-file.txt
  $ hg -R peer-bad-delta-with-full commit -m 'trigger-full'
  DBG-DELTAS: FILELOG:my-file.txt: rev=4: delta-base=4 * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)

Check that "try-base" behavior challenge the delta
--------------------------------------------------

The bundling process creates a delta against the previous revision, however this
is an invalid chain for the client, so it is not considered and we do a full
snapshot again.

  $ cp -ar local-pre-pull-full local-try-base-full
  $ hg -R local-try-base-full pull --quiet \
  > --config 'paths.default:pulled-delta-reuse-policy=try-base'
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=4: delta-base=4 * (glob)

Check that "forced" behavior do not challenge the delta, even if it is full.
---------------------------------------------------------------------------

A full bundle should be accepted as full bundle without recomputation

  $ cp -ar local-pre-pull-full local-forced-full
  $ hg -R local-forced-full pull --quiet \
  > --config 'paths.default:pulled-delta-reuse-policy=forced'
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=4: delta-base=4 is-cached=1 - search-rounds=0 try-count=0 - delta-type=full   snap-depth=0 - * (glob)

Check that "forced" behavior do not challenge the delta, even if it is bad.
---------------------------------------------------------------------------

The client does not challenge anything and applies the bizarre delta directly.

Note: If the bundling process becomes smarter, this test might no longer work
(as the server won't be sending "bad" deltas anymore) and might need something
more subtle to test this behavior.

  $ hg bundle -R peer-bad-delta-with-full --all --config devel.bundle.delta=p1 all-p1.hg
  5 changesets found
  $ cp -ar local-pre-pull-full local-forced-full-p1
  $ hg -R local-forced-full-p1 pull --quiet \
  > --config 'paths.*:pulled-delta-reuse-policy=forced' all-p1.hg
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: CHANGELOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: MANIFESTLOG: * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=3: delta-base=2 * (glob)
  DBG-DELTAS: FILELOG:my-file.txt: rev=4: delta-base=3 * (glob)
