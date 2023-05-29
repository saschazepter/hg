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


Test stream-clone raced by a revlog-split
=========================================

Test stream-clone where the file is split right after the lock section is done

Start the server

  $ hg serve -R server \
  >   -p $HGPORT1 -d --error errors.log --pid-file=hg.pid \
  >   --config extensions.stream_steps="$RUNTESTDIR/testlib/ext-stream-clone-steps.py"
  $ cat hg.pid >> $DAEMON_PIDS

Start a client doing a streaming clone

  $ (hg clone -q --stream -U http://localhost:$HGPORT1 clone-while-split > client.log 2>&1; touch "$HG_TEST_STREAM_WALKED_FILE_3") &

Wait for the server to be done collecting data

  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_1

trigger a split

  $ dd if=/dev/zero of=server/$file bs=1k count=128 > /dev/null 2>&1
  $ hg -R server ci -m "triggering a split" --config ui.timeout.warn=-1

unlock the stream generation

  $ touch $HG_TEST_STREAM_WALKED_FILE_2

wait for the client to be done cloning.

  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_3

Check everything is fine

  $ cat client.log
  remote: abort: unexpected error: clone could only read 256 bytes from data/some-file.i, but expected 1259 bytes (known-bad-output !)
  abort: pull failed on remote (known-bad-output !)
  $ tail -2 errors.log
  mercurial.error.Abort: clone could only read 256 bytes from data/some-file.i, but expected 1259 bytes (known-bad-output !)
   (known-bad-output !)
  $ hg -R clone-while-split verify
  checking changesets (missing-correct-output !)
  checking manifests (missing-correct-output !)
  crosschecking files in changesets and manifests (missing-correct-output !)
  checking files (missing-correct-output !)
  checking dirstate (missing-correct-output !)
  checked 3 changesets with 3 changes to 1 files (missing-correct-output !)
  abort: repository clone-while-split not found (known-bad-output !)
  [255]
  $ hg -R clone-while-split tip
  changeset:   2:dbd9854c38a6 (missing-correct-output !)
  tag:         tip (missing-correct-output !)
  user:        test (missing-correct-output !)
  date:        Thu Jan 01 00:00:00 1970 +0000 (missing-correct-output !)
  summary:     c (missing-correct-output !)
   (missing-correct-output !)
  abort: repository clone-while-split not found (known-bad-output !)
  [255]
  $ hg -R clone-while-split debug-revlog-index some-file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid (missing-correct-output !)
       0       0 ed70cecbc103 000000000000 000000000000 (missing-correct-output !)
       1       1 7241018db64c ed70cecbc103 000000000000 (missing-correct-output !)
       2       2 fa1120531cc1 7241018db64c 000000000000 (missing-correct-output !)
  abort: repository clone-while-split not found (known-bad-output !)
  [255]

subsequent pull work

  $ hg -R clone-while-split pull
  pulling from http://localhost:$HGPORT1/ (missing-correct-output !)
  searching for changes (missing-correct-output !)
  adding changesets (missing-correct-output !)
  adding manifests (missing-correct-output !)
  adding file changes (missing-correct-output !)
  added 1 changesets with 1 changes to 1 files (missing-correct-output !)
  new changesets df05c6cb1406 (missing-correct-output !)
  (run 'hg update' to get a working copy) (missing-correct-output !)
  abort: repository clone-while-split not found (known-bad-output !)
  [255]

  $ hg -R clone-while-split debug-revlog-index some-file
     rev linkrev       nodeid    p1-nodeid    p2-nodeid (missing-correct-output !)
       0       0 ed70cecbc103 000000000000 000000000000 (missing-correct-output !)
       1       1 7241018db64c ed70cecbc103 000000000000 (missing-correct-output !)
       2       2 fa1120531cc1 7241018db64c 000000000000 (missing-correct-output !)
       3       3 a631378adaa3 fa1120531cc1 000000000000 (missing-correct-output !)
  abort: repository clone-while-split not found (known-bad-output !)
  [255]
  $ hg -R clone-while-split verify
  checking changesets (missing-correct-output !)
  checking manifests (missing-correct-output !)
  crosschecking files in changesets and manifests (missing-correct-output !)
  checking files (missing-correct-output !)
  checking dirstate (missing-correct-output !)
  checked 4 changesets with 4 changes to 1 files (missing-correct-output !)
  abort: repository clone-while-split not found (known-bad-output !)
  [255]
