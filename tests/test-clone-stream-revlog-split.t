Test stream cloning while a revlog split happens
------------------------------------------------

#testcases stream-bundle2-v2 stream-bundle2-v3

#if stream-bundle2-v3
  $ cat << EOF >> $HGRCPATH
  > [experimental]
  > stream-v3 = yes
  > EOF
#endif

setup a repository for tests
----------------------------

  $ cat >> $HGRCPATH << EOF
  > [format]
  > # skip compression to make it easy to trigger a split
  > revlog-compression=none
  > [phases]
  > publish=no
  > EOF

  $ hg init server
  $ cd server
  $ file="some-file"
  $ printf '%20d' '1' > $file
  $ hg commit -Aqma
  $ printf '%1024d' '1' > $file
  $ hg commit -Aqmb
  $ printf '%20d' '1' > $file
  $ hg commit -Aqmc

check the revlog is inline

  $ f -s .hg/store/data/some-file*
  .hg/store/data/some-file.i: size=1259
  $ hg debug-revlog-index some-file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 ed70cecbc103 000000000000 000000000000
       1       1 7241018db64c ed70cecbc103 000000000000
       2       2 fa1120531cc1 7241018db64c 000000000000
  $ cd ..

setup synchronisation file

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
(we don't need this wait point)
  $ touch $HG_TEST_STREAM_WALKED_FILE_2


Test stream-clone raced by a revlog-split
=========================================

Test stream-clone where the file is split right after the lock section is done

Start the server

  $ hg serve -R server \
  >   -p $HGPORT1 -d --error errors.log --pid-file=hg.pid \
  >   --config extensions.stream_steps="$RUNTESTDIR/testlib/ext-stream-clone-steps.py"
  $ cat hg.pid >> $DAEMON_PIDS

Start a client doing a streaming clone

  $ ( \
  >    hg clone --debug --stream -U http://localhost:$HGPORT1 \
  >    clone-while-split --config worker.backgroundclose=0 > client.log 2>&1; \
  >    touch "$HG_TEST_STREAM_WALKED_FILE_5" \
  > ) &

Wait for the server to be done collecting data

  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_3

trigger a split

  $ dd if=/dev/zero of=server/$file bs=1k count=128 > /dev/null 2>&1
  $ hg -R server ci -m "triggering a split" --config ui.timeout.warn=-1

unlock the stream generation

  $ touch $HG_TEST_STREAM_WALKED_FILE_4

wait for the client to be done cloning.

  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_5

Check everything is fine

  $ cat client.log
  using http://localhost:$HGPORT1/
  sending capabilities command
  query 1; heads
  sending batch command
  streaming all changes
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "stream2" (params: 3 mandatory) supported (stream-bundle2-v2 !)
  bundle2-input-part: "stream3-exp" (params: 1 mandatory) supported (stream-bundle2-v3 !)
  applying stream bundle
  8 files to transfer, 2.11 KB of data (stream-bundle2-v2 no-rust !)
  10 files to transfer, 2.29 KB of data (stream-bundle2-v2 rust !)
  adding [s] data/some-file.i (1.23 KB) (stream-bundle2-v2 !)
  7 entries to transfer (stream-bundle2-v3 !)
  adding [s] data/some-file.d (1.04 KB) (stream-bundle2-v3 !)
  adding [s] data/some-file.i (192 bytes) (stream-bundle2-v3 !)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (348 bytes)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-88698448.nd (128 bytes) (rust !)
  adding [s] 00changelog.d (189 bytes)
  adding [s] 00changelog.i (192 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (24 bytes)
  updating the branch cache
  stream-cloned 9 files / 2.11 KB in * seconds (* */sec) (glob) (no-rust stream-bundle2-v3 !)
  stream-cloned 11 files / 2.29 KB in * seconds (* */sec) (glob) (rust stream-bundle2-v3 !)
  bundle2-input-part: total payload size 2285 (stream-bundle2-v2 no-rust !)
  bundle2-input-part: total payload size 2518 (stream-bundle2-v2 rust !)
  bundle2-input-part: total payload size 2313 (stream-bundle2-v3 no-rust !)
  bundle2-input-part: total payload size 2546 (stream-bundle2-v3 rust !)
  stream-cloned 8 files / 2.11 KB in * seconds (* */sec) (glob) (no-rust stream-bundle2-v2 !)
  stream-cloned 10 files / 2.29 KB in * seconds (* */sec) (glob) (rust stream-bundle2-v2 !)
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-bundle: 2 parts total
  checking for updated bookmarks
  updating the branch cache
  (sent 3 HTTP requests and * bytes; received * bytes in responses) (glob)
  $ tail -2 errors.log
  $ hg -R clone-while-split verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 3 changesets with 3 changes to 1 files
  $ hg -R clone-while-split tip
  changeset:   2:dbd9854c38a6
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     c
  
  $ hg -R clone-while-split debug-revlog-index some-file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 ed70cecbc103 000000000000 000000000000
       1       1 7241018db64c ed70cecbc103 000000000000
       2       2 fa1120531cc1 7241018db64c 000000000000
  $ hg -R server phase --rev 'all()'
  0: draft
  1: draft
  2: draft
  3: draft
  $ hg -R clone-while-split phase --rev 'all()'
  0: draft
  1: draft
  2: draft

subsequent pull work

  $ hg -R clone-while-split pull
  pulling from http://localhost:$HGPORT1/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets df05c6cb1406 (1 drafts)
  (run 'hg update' to get a working copy)

  $ hg -R clone-while-split debug-revlog-index some-file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 ed70cecbc103 000000000000 000000000000
       1       1 7241018db64c ed70cecbc103 000000000000
       2       2 fa1120531cc1 7241018db64c 000000000000
       3       3 a631378adaa3 fa1120531cc1 000000000000
  $ hg -R clone-while-split verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 4 changesets with 4 changes to 1 files
