
#require no-reposimplestore no-chg

initial setup

  $ hg init server
  $ cat >> server/.hg/hgrc << EOF
  > [extensions]
  > clonebundles =
  > 
  > [clone-bundles]
  > auto-generate.formats = v2
  > upload-command = cp "\$HGCB_BUNDLE_PATH" "$TESTTMP"/final-upload/
  > url-template = file://$TESTTMP/final-upload/{basename}
  > 
  > [devel]
  > debug.clonebundles=yes
  > EOF

  $ mkdir final-upload
  $ hg clone server client
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd client

Test bundles are generated on push
==================================

  $ touch foo
  $ hg -q commit -A -m 'add foo'
  $ touch bar
  $ hg -q commit -A -m 'add bar'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  2 changesets found
  added 2 changesets with 2 changes to 2 files
  clone-bundles: starting bundle generation: v2
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Newer bundles are generated with more pushes
--------------------------------------------

  $ touch baz
  $ hg -q commit -A -m 'add baz'
  $ touch buz
  $ hg -q commit -A -m 'add buz'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  4 changesets found
  added 2 changesets with 2 changes to 2 files
  clone-bundles: starting bundle generation: v2

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-4_revs-6427147b985a_tip-*_txn.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg (glob)
  full-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles
