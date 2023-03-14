
#require no-reposimplestore no-chg

initial setup

  $ hg init server
  $ cat >> server/.hg/hgrc << EOF
  > [extensions]
  > clonebundles =
  > 
  > [clone-bundles]
  > auto-generate.on-change = yes
  > auto-generate.formats = v2
  > upload-command = cp "\$HGCB_BUNDLE_PATH" "$TESTTMP"/final-upload/
  > delete-command = rm -f "$TESTTMP/final-upload/\$HGCB_BASENAME"
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

Older bundles are cleaned up with more pushes
---------------------------------------------

  $ touch faz
  $ hg -q commit -A -m 'add faz'
  $ touch fuz
  $ hg -q commit -A -m 'add fuz'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  clone-bundles: deleting bundle full-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg (glob)
  6 changesets found
  added 2 changesets with 2 changes to 2 files
  clone-bundles: starting bundle generation: v2

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-6_revs-b1010e95ea00_tip-*_txn.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  full-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Test conditions to get them generated
=====================================

Check ratio

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > trigger.below-bundled-ratio = 0.5
  > EOF
  $ touch far
  $ hg -q commit -A -m 'add far'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-6_revs-b1010e95ea00_tip-*_txn.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  full-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Check absolute number of revisions

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > trigger.revs = 2
  > EOF
  $ touch bur
  $ hg -q commit -A -m 'add bur'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  clone-bundles: deleting bundle full-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  8 changesets found
  added 1 changesets with 1 changes to 1 files
  clone-bundles: starting bundle generation: v2
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-8_revs-8353e8af1306_tip-*_txn.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  full-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

(that one would not generate new bundles)

  $ touch tur
  $ hg -q commit -A -m 'add tur'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-8_revs-8353e8af1306_tip-*_txn.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  full-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Test generation through the dedicated command
=============================================

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > auto-generate.on-change = no
  > EOF

Check the command can generate content when needed
--------------------------------------------------

Do a push that makes the condition fulfilled,
Yet it should not automatically generate a bundle with
"auto-generate.on-change" not set.

  $ touch quoi
  $ hg -q commit -A -m 'add quoi'

  $ pre_push_manifest=`cat ../server/.hg/clonebundles.manifest|f --sha256 | sed 's/.*=//' | cat`
  $ pre_push_upload=`ls -1 ../final-upload|f --sha256 | sed 's/.*=//' | cat`
  $ ls -1 ../server/.hg/tmp-bundles

  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files

  $ post_push_manifest=`cat ../server/.hg/clonebundles.manifest|f --sha256 | sed 's/.*=//' | cat`
  $ post_push_upload=`ls -1 ../final-upload|f --sha256 | sed 's/.*=//' | cat`
  $ ls -1 ../server/.hg/tmp-bundles
  $ test "$pre_push_manifest" = "$post_push_manifest"
  $ test "$pre_push_upload" = "$post_push_upload"

Running the command should detect the stale bundles, and do the full automatic
generation logic.

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: deleting bundle full-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  clone-bundles: starting bundle generation: v2
  10 changesets found
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  full-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Check the command cleans up older bundles when possible
-------------------------------------------------------

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: deleting bundle full-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Nothing is generated when the bundles are sufficiently up to date
-----------------------------------------------------------------

  $ touch feur
  $ hg -q commit -A -m 'add feur'

  $ pre_push_manifest=`cat ../server/.hg/clonebundles.manifest|f --sha256 | sed 's/.*=//' | cat`
  $ pre_push_upload=`ls -1 ../final-upload|f --sha256 | sed 's/.*=//' | cat`
  $ ls -1 ../server/.hg/tmp-bundles

  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files

  $ post_push_manifest=`cat ../server/.hg/clonebundles.manifest|f --sha256 | sed 's/.*=//' | cat`
  $ post_push_upload=`ls -1 ../final-upload|f --sha256 | sed 's/.*=//' | cat`
  $ ls -1 ../server/.hg/tmp-bundles
  $ test "$pre_push_manifest" = "$post_push_manifest"
  $ test "$pre_push_upload" = "$post_push_upload"

  $ hg -R ../server/ admin::clone-bundles-refresh

  $ post_refresh_manifest=`cat ../server/.hg/clonebundles.manifest|f --sha256 | sed 's/.*=//' | cat`
  $ post_refresh_upload=`ls -1 ../final-upload|f --sha256 | sed 's/.*=//' | cat`
  $ ls -1 ../server/.hg/tmp-bundles
  $ test "$pre_push_manifest" = "$post_refresh_manifest"
  $ test "$pre_push_upload" = "$post_refresh_upload"

Test modification of configuration
==================================

Testing that later runs adapt to configuration changes even if the repository is
unchanged.

adding more formats
-------------------

bundle for added formats should be generated

change configuration

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > auto-generate.formats = v1, v2
  > EOF

refresh the bundles

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: starting bundle generation: v1
  11 changesets found

the bundle for the "new" format should have been added

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=v1 REQUIRESNI=true (glob)
  file:/*/$TESTTMP/final-upload/full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Changing the ratio
------------------

Changing the ratio to something that would have triggered a bundle during the last push.

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > trigger.below-bundled-ratio = 0.95
  > EOF

refresh the bundles

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: starting bundle generation: v2
  11 changesets found


the "outdated' bundle should be refreshed

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=v1 REQUIRESNI=true (glob)
  file:/*/$TESTTMP/final-upload/full-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=v2 REQUIRESNI=true (glob)
  $ ls -1 ../final-upload
  full-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  full-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles
