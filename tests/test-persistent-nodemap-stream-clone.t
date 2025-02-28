=======================================================
Test the persistent on-disk nodemap during stream-clone
=======================================================

#testcases stream-v2 stream-v3

#if stream-v3
  $ cat << EOF >> $HGRCPATH
  > [experimental]
  > stream-v3=yes
  > EOF
#endif

Setup
=====

#if no-rust

  $ cat << EOF >> $HGRCPATH
  > [format]
  > use-persistent-nodemap=yes
  > [devel]
  > persistent-nodemap=yes
  > [storage]
  > # to avoid spamming the test
  > revlog.persistent-nodemap.slow-path=allow
  > EOF

#endif

Recreate the same repo as in `test-persistent-nodemap.t`

  $ hg init test-repo --config storage.revlog.persistent-nodemap.slow-path=allow
  $ hg -R test-repo debugbuilddag .+5000 --new-file

stream clone
============

The persistent nodemap should exist after a streaming clone

Simple case
-----------

No race condition

  $ hg clone -U --stream ssh://user@dummy/test-repo stream-clone --debug | grep -E '00(changelog|manifest)'
  adding [s] 00manifest.n (62 bytes)
  adding [s] 00manifest-*.nd (118 KB) (glob)
  adding [s] 00manifest.d (4?? KB) (glob)
  adding [s] 00manifest.i (313 KB)
  adding [s] 00changelog.n (62 bytes)
  adding [s] 00changelog-*.nd (118 KB) (glob)
  adding [s] 00changelog.d (3?? KB) (glob)
  adding [s] 00changelog.i (313 KB)
  $ ls -1 stream-clone/.hg/store/ | grep -E '00(changelog|manifest)(\.n|-.*\.nd)'
  00changelog-*.nd (glob)
  00changelog.n
  00manifest-*.nd (glob)
  00manifest.n
  $ hg -R stream-clone debugnodemap --metadata
  uid: * (glob)
  tip-rev: 5000
  tip-node: 6b02b8c7b96654c25e86ba69eda198d7e6ad8b3c
  data-length: 121088
  data-unused: 0
  data-unused: 0.000%
  $ hg verify -R stream-clone
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 5001 changesets with 5001 changes to 5001 files

new data appened
-----------------

Other commit happening on the server during the stream clone

setup the step-by-step stream cloning

  $ HG_TEST_STREAM_WALKED_FILE_1="$TESTTMP/sync_file_walked_1"
  $ export HG_TEST_STREAM_WALKED_FILE_1
  $ HG_TEST_STREAM_WALKED_FILE_2="$TESTTMP/sync_file_walked_2"
  $ export HG_TEST_STREAM_WALKED_FILE_2
  $ HG_TEST_STREAM_WALKED_FILE_3="$TESTTMP/sync_file_walked_3"
  $ export HG_TEST_STREAM_WALKED_FILE_3
  $ HG_TEST_STREAM_WALKED_FILE_4="$TESTTMP/sync_file_walked_4"
  $ export HG_TEST_STREAM_WALKED_FILE_4
  $ HG_TEST_STREAM_WALKED_FILE_5="$TESTTMP/sync_file_walked_5"
  $ export HG_TEST_STREAM_WALKED_FILE_5
  $ cat << EOF >> test-repo/.hg/hgrc
  > [extensions]
  > steps=$RUNTESTDIR/testlib/ext-stream-clone-steps.py
  > EOF
(we don't need this wait point)
  $ touch $HG_TEST_STREAM_WALKED_FILE_2

Check and record file state beforehand

  $ f --size test-repo/.hg/store/00changelog*
  test-repo/.hg/store/00changelog-*.nd: size=121088 (glob)
  test-repo/.hg/store/00changelog.d: size=3????? (glob)
  test-repo/.hg/store/00changelog.i: size=320064
  test-repo/.hg/store/00changelog.n: size=62
  $ hg -R test-repo debugnodemap --metadata | tee server-metadata.txt
  uid: * (glob)
  tip-rev: 5000
  tip-node: 6b02b8c7b96654c25e86ba69eda198d7e6ad8b3c
  data-length: 121088
  data-unused: 0
  data-unused: 0.000%

Prepare a commit

  $ echo foo >> test-repo/foo
  $ hg -R test-repo/ add test-repo/foo

Do a mix of clone and commit at the same time so that the file listed on disk differ at actual transfer time.

  $ (hg clone -U --stream ssh://user@dummy/test-repo stream-clone-race-1 --debug 2>> clone-output | grep -E '00(changelog|manifest)' >> clone-output; touch $HG_TEST_STREAM_WALKED_FILE_5) &
  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_3
  $ hg -R test-repo/ commit -m foo
  created new head
  $ touch $HG_TEST_STREAM_WALKED_FILE_4
  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_5
  $ cat clone-output
  adding [s] 00manifest.n (62 bytes)
  adding [s] 00manifest-*.nd (118 KB) (glob)
  adding [s] 00manifest.d (4?? KB) (glob)
  adding [s] 00manifest.i (313 KB)
  adding [s] 00changelog.n (62 bytes)
  adding [s] 00changelog-*.nd (118 KB) (glob)
  adding [s] 00changelog.d (36? KB) (glob)
  adding [s] 00changelog.i (313 KB)

Check the result state

  $ f --size stream-clone-race-1/.hg/store/00changelog*
  stream-clone-race-1/.hg/store/00changelog-*.nd: size=121088 (glob)
  stream-clone-race-1/.hg/store/00changelog.d: size=3????? (glob)
  stream-clone-race-1/.hg/store/00changelog.i: size=320064
  stream-clone-race-1/.hg/store/00changelog.n: size=62

  $ hg -R stream-clone-race-1 debugnodemap --metadata | tee client-metadata.txt
  uid: * (glob)
  tip-rev: 5000
  tip-node: 6b02b8c7b96654c25e86ba69eda198d7e6ad8b3c
  data-length: 121088
  data-unused: 0
  data-unused: 0.000%
  $ hg verify -R stream-clone-race-1
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 5001 changesets with 5001 changes to 5001 files

We get a usable nodemap, so no rewrite would be needed and the metadata should be identical
(ie: the following diff should be empty)

This isn't the case for the `no-rust` `no-pure` implementation as it use a very minimal nodemap implementation that unconditionnaly rewrite the nodemap "all the time".

#if no-rust no-pure
  $ diff -u server-metadata.txt client-metadata.txt
  --- server-metadata.txt	* (glob)
  +++ client-metadata.txt	* (glob)
  @@ -1,4 +1,4 @@
  -uid: * (glob)
  +uid: * (glob)
   tip-rev: 5000
   tip-node: 6b02b8c7b96654c25e86ba69eda198d7e6ad8b3c
   data-length: 121088
  [1]
#else
  $ diff -u server-metadata.txt client-metadata.txt
#endif


Clean up after the test.

  $ rm -f "$HG_TEST_STREAM_WALKED_FILE_3"
  $ rm -f "$HG_TEST_STREAM_WALKED_FILE_4"
  $ rm -f "$HG_TEST_STREAM_WALKED_FILE_5"

full regeneration
-----------------

A full nodemap is generated

(ideally this test would append enough data to make sure the nodemap data file
get changed, however to make thing simpler we will force the regeneration for
this test.

Check the initial state

  $ f --size test-repo/.hg/store/00changelog*
  test-repo/.hg/store/00changelog-*.nd: size=121??? (glob)
  test-repo/.hg/store/00changelog.d: size=3????? (glob)
  test-repo/.hg/store/00changelog.i: size=320128
  test-repo/.hg/store/00changelog.n: size=62
  $ hg -R test-repo debugnodemap --metadata | tee server-metadata-2.txt
  uid: * (glob)
  tip-rev: 5001
  tip-node: e63c23eaa88ae77967edcf4ea194d31167c478b0
  data-length: 121408 (pure !)
  data-unused: 256 (pure !)
  data-unused: 0.211% (pure !)
  data-length: 121408 (rust !)
  data-unused: 256 (rust !)
  data-unused: 0.211% (rust !)
  data-length: 121152 (no-pure no-rust !)
  data-unused: 0 (no-pure no-rust !)
  data-unused: 0.000% (no-pure no-rust !)

Performe the mix of clone and full refresh of the nodemap, so that the files
(and filenames) are different between listing time and actual transfer time.

  $ (hg clone -U --stream ssh://user@dummy/test-repo stream-clone-race-2 --debug 2>> clone-output-2 | grep -E '00(changelog|manifest)' >> clone-output-2; touch $HG_TEST_STREAM_WALKED_FILE_5) &
  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_3
  $ rm test-repo/.hg/store/00changelog.n
  $ rm test-repo/.hg/store/00changelog-*.nd
  $ hg -R test-repo/ debugupdatecache
  $ touch $HG_TEST_STREAM_WALKED_FILE_4
  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_5

(note: the stream clone code wronly pick the `undo.` files)

  $ cat clone-output-2
  adding [s] 00manifest.n (62 bytes)
  adding [s] 00manifest-*.nd (118 KB) (glob)
  adding [s] 00manifest.d (4?? KB) (glob)
  adding [s] 00manifest.i (313 KB)
  adding [s] 00changelog.n (62 bytes)
  adding [s] 00changelog-*.nd (11? KB) (glob)
  adding [s] 00changelog.d (3?? KB) (glob)
  adding [s] 00changelog.i (313 KB)

Check the result.

  $ f --size stream-clone-race-2/.hg/store/00changelog*
  stream-clone-race-2/.hg/store/00changelog-*.nd: size=1????? (glob)
  stream-clone-race-2/.hg/store/00changelog.d: size=3????? (glob)
  stream-clone-race-2/.hg/store/00changelog.i: size=320128
  stream-clone-race-2/.hg/store/00changelog.n: size=62

  $ hg -R stream-clone-race-2 debugnodemap --metadata | tee client-metadata-2.txt
  uid: * (glob)
  tip-rev: 5001
  tip-node: e63c23eaa88ae77967edcf4ea194d31167c478b0
  data-length: 121408 (pure !)
  data-unused: 256 (pure !)
  data-unused: 0.211% (pure !)
  data-length: 121408 (rust !)
  data-unused: 256 (rust !)
  data-unused: 0.211% (rust !)
  data-length: 121152 (no-pure no-rust !)
  data-unused: 0 (no-pure no-rust !)
  data-unused: 0.000% (no-pure no-rust !)
  $ hg verify -R stream-clone-race-2
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 5002 changesets with 5002 changes to 5002 files

We get a usable nodemap, so no rewrite would be needed and the metadata should be identical
(ie: the following diff should be empty)

This isn't the case for the `no-rust` `no-pure` implementation as it use a very minimal nodemap implementation that unconditionnaly rewrite the nodemap "all the time".

#if no-rust no-pure
  $ diff -u server-metadata-2.txt client-metadata-2.txt
  --- server-metadata-2.txt	* (glob)
  +++ client-metadata-2.txt	* (glob)
  @@ -1,4 +1,4 @@
  -uid: * (glob)
  +uid: * (glob)
   tip-rev: 5001
   tip-node: e63c23eaa88ae77967edcf4ea194d31167c478b0
   data-length: 121152
  [1]
#else
  $ diff -u server-metadata-2.txt client-metadata-2.txt
#endif

Clean up after the test

  $ rm -f $HG_TEST_STREAM_WALKED_FILE_3
  $ rm -f $HG_TEST_STREAM_WALKED_FILE_4
  $ rm -f $HG_TEST_STREAM_WALKED_FILE_5

