
#require no-reposimplestore no-chg

initial setup

  $ hg init server
  $ cat >> server/.hg/hgrc << EOF
  > [extensions]
  > clonebundles =
  > 
  > [clone-bundles]
  > auto-generate.on-change = yes
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

Test bundles are not generated if formats are not given
=======================================================

  $ touch noformats
  $ hg -q commit -A -m 'add noformats'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  clone-bundle auto-generate enabled, but no formats specified: disabling generation
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ test -f ../server/.hg/clonebundles.manifest
  [1]
  $ hg debugstrip -r tip
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/client/.hg/strip-backup/4823cdad4f38-4b2c3b65-backup.hg
  $ hg --cwd ../server debugstrip -r tip
  saved backup bundle to $TESTTMP/server/.hg/strip-backup/4823cdad4f38-4b2c3b65-backup.hg
  clone-bundle auto-generate enabled, but no formats specified: disabling generation
  clone-bundle auto-generate enabled, but no formats specified: disabling generation

Test bundles are generated on push
==================================

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > auto-generate.formats = v2
  > EOF
  $ touch foo
  $ hg -q commit -A -m 'add foo'
  $ touch bar
  $ hg -q commit -A -m 'add bar'

Test that the HGCB_BUNDLE_BASENAME variable behaves as expected when unquoted.
#if no-windows
  $ hg clone ../server '../embed-"-name/server'
  updating to branch default
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cp ../server/.hg/hgrc '../embed-"-name/server/.hg/hgrc'

  $ mv ../final-upload/ ../final-upload.bak/
  $ mkdir ../final-upload/

  $ hg push --config paths.default='../embed-"-name/server'
  pushing to $TESTTMP/embed-"-name/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  2 changesets found
  cp: cannot stat ''\''$TESTTMP/embed-"-name/server/.hg/tmp-bundles/full-bzip2-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg'\''': $ENOENT$ (glob)
  abort: command returned status 1: cp "$HGCB_BUNDLE_PATH" "$TESTTMP"/final-upload/
  added 2 changesets with 2 changes to 2 files
  clone-bundles: starting bundle generation: bzip2-v2

Restore the original upload directory for windows test consistency
  $ rm -r ../final-upload/
  $ mv ../final-upload.bak/ ../final-upload/
#endif

  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  2 changesets found
  added 2 changesets with 2 changes to 2 files
  clone-bundles: starting bundle generation: bzip2-v2
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg (glob)
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
  clone-bundles: starting bundle generation: bzip2-v2

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-4_revs-6427147b985a_tip-*_txn.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg (glob)
  full-bzip2-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
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
  clone-bundles: deleting bundle full-bzip2-v2-2_revs-aaff8d2ffbbf_tip-*_txn.hg (glob)
  6 changesets found
  added 2 changesets with 2 changes to 2 files
  clone-bundles: starting bundle generation: bzip2-v2

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
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
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
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
  clone-bundles: deleting bundle full-bzip2-v2-4_revs-6427147b985a_tip-*_txn.hg (glob)
  8 changesets found
  added 1 changesets with 1 changes to 1 files
  clone-bundles: starting bundle generation: bzip2-v2
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-8_revs-8353e8af1306_tip-*_txn.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  full-bzip2-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
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
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-8_revs-8353e8af1306_tip-*_txn.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  full-bzip2-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
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
  clone-bundles: deleting bundle full-bzip2-v2-6_revs-b1010e95ea00_tip-*_txn.hg (glob)
  clone-bundles: starting bundle generation: bzip2-v2
  10 changesets found
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  full-bzip2-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Check the command cleans up older bundles when possible
-------------------------------------------------------

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: deleting bundle full-bzip2-v2-8_revs-8353e8af1306_tip-*_txn.hg (glob)
  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
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
  clone-bundles: starting bundle generation: bzip2-v1
  11 changesets found

the bundle for the "new" format should have been added

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 (glob)
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
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
  clone-bundles: starting bundle generation: bzip2-v2
  11 changesets found


the "outdated' bundle should be refreshed

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 (glob)
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Test more command options
=========================

bundle clearing
---------------

  $ hg -R ../server/ admin::clone-bundles-clear
  clone-bundles: deleting bundle full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  clone-bundles: deleting bundle full-bzip2-v2-10_revs-3b6f57f17d70_tip-*_acbr.hg (glob)
  clone-bundles: deleting bundle full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)

Nothing should remain

  $ cat ../server/.hg/clonebundles.manifest
  $ ls -1 ../final-upload
  $ ls -1 ../server/.hg/tmp-bundles

background generation
---------------------

generate bundle using background subprocess
(since we are in devel mode, the command will still wait for the background
process to end)

  $ hg -R ../server/ admin::clone-bundles-refresh --background
  11 changesets found
  11 changesets found
  clone-bundles: starting bundle generation: bzip2-v1
  clone-bundles: starting bundle generation: bzip2-v2

bundles should have been generated

  $ cat ../server/.hg/clonebundles.manifest
  file:/*/$TESTTMP/final-upload/full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 (glob)
  file:/*/$TESTTMP/final-upload/full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../final-upload
  full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  $ ls -1 ../server/.hg/tmp-bundles

Test HTTP URL
=========================

  $ hg -R ../server/ admin::clone-bundles-clear
  clone-bundles: deleting bundle full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  clone-bundles: deleting bundle full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > url-template = https://example.com/final-upload/{basename}
  > EOF
  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: starting bundle generation: bzip2-v1
  11 changesets found
  clone-bundles: starting bundle generation: bzip2-v2
  11 changesets found


bundles should have been generated with the SNIREQUIRED option

  $ cat ../server/.hg/clonebundles.manifest
  https://example.com/final-upload/full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 REQUIRESNI=true (glob)
  https://example.com/final-upload/full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 REQUIRESNI=true (glob)

Test serving them through inline-clone bundle
=============================================

  $ cat >> ../server/.hg/hgrc << EOF
  > [clone-bundles]
  > auto-generate.serve-inline=yes
  > EOF
  $ hg -R ../server/ admin::clone-bundles-clear
  clone-bundles: deleting bundle full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  clone-bundles: deleting bundle full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)

initial generation
------------------


  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: starting bundle generation: bzip2-v1
  11 changesets found
  clone-bundles: starting bundle generation: bzip2-v2
  11 changesets found
  $ cat ../server/.hg/clonebundles.manifest
  peer-bundle-cache://full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 (glob)
  peer-bundle-cache://full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../server/.hg/bundle-cache
  full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  $ ls -1 ../final-upload

Regeneration eventually cleanup the old ones
--------------------------------------------

create more content
  $ touch voit
  $ hg -q commit -A -m 'add voit'
  $ touch ar
  $ hg -q commit -A -m 'add ar'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files

check first regeneration

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: starting bundle generation: bzip2-v1
  13 changesets found
  clone-bundles: starting bundle generation: bzip2-v2
  13 changesets found
  $ cat ../server/.hg/clonebundles.manifest
  peer-bundle-cache://full-bzip2-v1-13_revs-8a81f9be54ea_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 (glob)
  peer-bundle-cache://full-bzip2-v2-13_revs-8a81f9be54ea_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../server/.hg/bundle-cache
  full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-bzip2-v1-13_revs-8a81f9be54ea_tip-*_acbr.hg (glob)
  full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  full-bzip2-v2-13_revs-8a81f9be54ea_tip-*_acbr.hg (glob)
  $ ls -1 ../final-upload

check first regeneration (should cleanup the one before that last)

  $ touch "investi"
  $ hg -q commit -A -m 'add investi'
  $ touch "lesgisla"
  $ hg -q commit -A -m 'add lesgisla'
  $ hg push
  pushing to $TESTTMP/server
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files

  $ hg -R ../server/ admin::clone-bundles-refresh
  clone-bundles: deleting inline bundle full-bzip2-v1-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  clone-bundles: deleting inline bundle full-bzip2-v2-11_revs-4226b1cd5fda_tip-*_acbr.hg (glob)
  clone-bundles: starting bundle generation: bzip2-v1
  15 changesets found
  clone-bundles: starting bundle generation: bzip2-v2
  15 changesets found
  $ cat ../server/.hg/clonebundles.manifest
  peer-bundle-cache://full-bzip2-v1-15_revs-17615b3984c2_tip-*_acbr.hg BUNDLESPEC=bzip2-v1 (glob)
  peer-bundle-cache://full-bzip2-v2-15_revs-17615b3984c2_tip-*_acbr.hg BUNDLESPEC=bzip2-v2 (glob)
  $ ls -1 ../server/.hg/bundle-cache
  full-bzip2-v1-13_revs-8a81f9be54ea_tip-*_acbr.hg (glob)
  full-bzip2-v1-15_revs-17615b3984c2_tip-*_acbr.hg (glob)
  full-bzip2-v2-13_revs-8a81f9be54ea_tip-*_acbr.hg (glob)
  full-bzip2-v2-15_revs-17615b3984c2_tip-*_acbr.hg (glob)
  $ ls -1 ../final-upload

Check the url is correct
------------------------

  $ hg clone -U ssh://user@dummy/server ssh-inline-clone
  applying clone bundle from peer-bundle-cache://full-bzip2-v1-15_revs-17615b3984c2_tip-*_acbr.hg (glob)
  adding changesets
  adding manifests
  adding file changes
  added 15 changesets with 15 changes to 15 files
  finished applying clone bundle
  searching for changes
  no changes found
  15 local changesets published
