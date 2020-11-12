#require serve

creating 'remote

  $ hg init remote
  $ cd remote
  $ hg unbundle "$TESTDIR/bundles/remote.hg"
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets bfaf4b5cbf01:916f1afdef90 (9 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Starting server

  $ hg serve -p $HGPORT -E ../error.log -d --pid-file=../hg1.pid
  $ cd ..
  $ cat hg1.pid >> $DAEMON_PIDS

clone remote via stream

  $ for i in 0 1 2 3 4 5 6 7 8; do
  >    hg clone -r "$i" http://localhost:$HGPORT/ test-"$i"
  >    if cd test-"$i"; then
  >       hg verify
  >       cd ..
  >    fi
  > done
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets bfaf4b5cbf01
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 1 changesets with 1 changes to 1 files
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets bfaf4b5cbf01:21f32785131f
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 1 files
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  new changesets bfaf4b5cbf01:4ce51a113780
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 3 changes to 1 files
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 1 files
  new changesets bfaf4b5cbf01:93ee6ab32777
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 4 changes to 1 files
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  new changesets bfaf4b5cbf01:c70afb1ee985
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 1 files
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  new changesets bfaf4b5cbf01:f03ae5a9b979
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 3 changes to 1 files
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 5 changes to 2 files
  new changesets bfaf4b5cbf01:095cb14b1b4d
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 5 changes to 2 files
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 6 changes to 3 files
  new changesets bfaf4b5cbf01:faa2e4234c7a
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 5 changesets with 6 changes to 3 files
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 2 files
  new changesets bfaf4b5cbf01:916f1afdef90
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 5 changesets with 5 changes to 2 files
  $ cd test-8
  $ hg pull ../test-7
  pulling from ../test-7
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 2 changes to 3 files (+1 heads)
  new changesets c70afb1ee985:faa2e4234c7a
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 9 changesets with 7 changes to 4 files
  $ cd ..
  $ cd test-1
  $ hg pull -r 4 http://localhost:$HGPORT/
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 0 files (+1 heads)
  new changesets c70afb1ee985
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 2 changes to 1 files
  $ hg pull http://localhost:$HGPORT/
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 5 changes to 4 files
  new changesets 4ce51a113780:916f1afdef90
  (run 'hg update' to get a working copy)
  $ cd ..
  $ cd test-2
  $ hg pull -r 5 http://localhost:$HGPORT/
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 0 changes to 0 files (+1 heads)
  new changesets c70afb1ee985:f03ae5a9b979
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 5 changesets with 3 changes to 1 files
  $ hg pull http://localhost:$HGPORT/
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 4 files
  new changesets 93ee6ab32777:916f1afdef90
  (run 'hg update' to get a working copy)
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 9 changesets with 7 changes to 4 files
  $ cd ..

no default destination if url has no path:

  $ hg clone http://localhost:$HGPORT/
  abort: empty destination path is not valid
  [10]

  $ cat error.log
