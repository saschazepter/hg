#require no-reposimplestore

#testcases stream-v2 stream-v3
#testcases threaded sequential

#if threaded
  $ cat << EOF >> $HGRCPATH
  > [worker]
  > parallel-stream-bundle-processing = yes
  > parallel-stream-bundle-processing.num-writer = 2
  > EOF
#else
  $ cat << EOF >> $HGRCPATH
  > [worker]
  > parallel-stream-bundle-processing = no
  > EOF
#endif

#if stream-v2
  $ bundle_format="streamv2"
  $ stream_version="v2"
#endif
#if stream-v3
  $ bundle_format="streamv3-exp"
  $ stream_version="v3-exp"
  $ cat << EOF >> $HGRCPATH
  > [experimental]
  > stream-v3=yes
  > EOF
#endif

Test creating a consuming stream bundle v2 and v3

  $ getmainid() {
  >    hg -R main log --template '{node}\n' --rev "$1"
  > }

  $ cp $HGRCPATH $TESTTMP/hgrc.orig

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution.createmarkers=True
  > evolution.exchange=True
  > bundle2-output-capture=True
  > [ui]
  > logtemplate={rev}:{node|short} {phase} {author} {bookmarks} {desc|firstline}
  > [web]
  > push_ssl = false
  > allow_push = *
  > [phases]
  > publish=False
  > [extensions]
  > drawdag=$TESTDIR/drawdag.py
  > clonebundles=
  > EOF

The extension requires a repo (currently unused)

  $ hg init main
  $ cd main

  $ hg debugdrawdag <<'EOF'
  > E
  > |
  > D
  > |
  > C
  > |
  > B
  > |
  > A
  > EOF

  $ hg bundle -a --type="none-v2;stream=$stream_version" bundle.hg
  $ hg debugbundle bundle.hg
  Stream params: {}
  stream2 -- {bytecount: 1693, filecount: 12, requirements: generaldelta%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 no-zstd !)
  stream2 -- {bytecount: 1693, filecount: 12, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 zstd no-rust !)
  stream2 -- {bytecount: 1819, filecount: 14, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 rust !)
  stream3-exp -- {requirements: generaldelta%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v3 no-zstd !)
  stream3-exp -- {requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v3 zstd no-rust !)
  stream3-exp -- {requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v3 rust !)
  $ hg debugbundle --spec bundle.hg
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlogv1%2Csparserevlog (stream-v2 no-zstd !)
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v2 zstd no-rust !)
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v2 rust !)
  none-v2;stream=v3-exp;requirements%3Dgeneraldelta%2Crevlogv1%2Csparserevlog (stream-v3 no-zstd !)
  none-v2;stream=v3-exp;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v3 zstd no-rust !)
  none-v2;stream=v3-exp;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v3 rust !)

  $ hg bundle -a --type="none-$bundle_format" bundle.hg
  $ hg debugbundle bundle.hg
  Stream params: {}
  stream2 -- {bytecount: 1693, filecount: 12, requirements: generaldelta%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 no-zstd !)
  stream2 -- {bytecount: 1693, filecount: 12, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 zstd no-rust !)
  stream2 -- {bytecount: 1819, filecount: 14, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 rust !)
  stream3-exp -- {requirements: generaldelta%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v3 no-zstd !)
  stream3-exp -- {requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v3 zstd no-rust !)
  stream3-exp -- {requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v3 rust !)
  $ hg debugbundle --spec bundle.hg
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlogv1%2Csparserevlog (stream-v2 no-zstd !)
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v2 zstd no-rust !)
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v2 rust !)
  none-v2;stream=v3-exp;requirements%3Dgeneraldelta%2Crevlogv1%2Csparserevlog (stream-v3 no-zstd !)
  none-v2;stream=v3-exp;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v3 zstd no-rust !)
  none-v2;stream=v3-exp;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog (stream-v3 rust !)

Test that we can apply the bundle as a stream clone bundle

  $ cat > .hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/bundle.hg BUNDLESPEC=`hg debugbundle --spec bundle.hg`
  > EOF

  $ hg serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS

  $ cd ..

#if stream-v2
  $ hg clone http://localhost:$HGPORT stream-clone-implicit --debug
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "stream2" (params: 3 mandatory) supported
  applying stream bundle
  12 files to transfer, 1.65 KB of data (no-rust !)
  14 files to transfer, 1.78 KB of data (rust !)
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (584 bytes)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (64 bytes) (rust !)
  adding [s] 00changelog.d (275 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  bundle2-input-part: total payload size 1857 (no-rust !)
  bundle2-input-part: total payload size 2025 (rust !)
  stream-cloned 12 files / 1.65 KB in * seconds (* */sec) (glob) (no-rust !)
  stream-cloned 14 files / 1.78 KB in * seconds (* */sec) (glob) (rust !)
  bundle2-input-bundle: 1 parts total
  updating the branch cache
  finished applying clone bundle
  query 1; heads
  sending batch command
  searching for changes
  all remote heads known locally
  no changes found
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 2 parts total
  checking for updated bookmarks
  updating to branch default
  resolving manifests (no-rust !)
   branchmerge: False, force: False, partial: False (no-rust !)
   ancestor: 000000000000, local: 000000000000+, remote: 9bc730a19041 (no-rust !)
   A: remote created -> g (no-rust !)
  getting A (no-rust !)
   B: remote created -> g (no-rust !)
  getting B (no-rust !)
   C: remote created -> g (no-rust !)
  getting C (no-rust !)
   D: remote created -> g (no-rust !)
  getting D (no-rust !)
   E: remote created -> g (no-rust !)
  getting E (no-rust !)
  5 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

test explicite stream request

(also test unlimited memory usage code path)

  $ hg clone --stream http://localhost:$HGPORT stream-clone-explicit --debug \
  >   --config worker.parallel-stream-bundle-processing.memory-target=-1
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "stream2" (params: 3 mandatory) supported
  applying stream bundle
  12 files to transfer, 1.65 KB of data (no-rust !)
  14 files to transfer, 1.78 KB of data (rust !)
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (584 bytes)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (64 bytes) (rust !)
  adding [s] 00changelog.d (275 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  bundle2-input-part: total payload size 1857 (no-rust !)
  bundle2-input-part: total payload size 2025 (rust !)
  stream-cloned 12 files / 1.65 KB in * seconds (* */sec) (glob) (no-rust !)
  stream-cloned 14 files / 1.78 KB in * seconds (* */sec) (glob) (rust !)
  bundle2-input-bundle: 1 parts total
  updating the branch cache
  finished applying clone bundle
  query 1; heads
  sending batch command
  searching for changes
  all remote heads known locally
  no changes found
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 2 parts total
  checking for updated bookmarks
  updating to branch default
  resolving manifests (no-rust !)
   branchmerge: False, force: False, partial: False (no-rust !)
   ancestor: 000000000000, local: 000000000000+, remote: 9bc730a19041 (no-rust !)
   A: remote created -> g (no-rust !)
  getting A (no-rust !)
   B: remote created -> g (no-rust !)
  getting B (no-rust !)
   C: remote created -> g (no-rust !)
  getting C (no-rust !)
   D: remote created -> g (no-rust !)
  getting D (no-rust !)
   E: remote created -> g (no-rust !)
  getting E (no-rust !)
  5 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

#endif

#if stream-v3
  $ hg clone http://localhost:$HGPORT stream-clone-implicit --debug
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "stream3-exp" (params: 1 mandatory) supported
  applying stream bundle
  11 entries to transfer
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (584 bytes)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (64 bytes) (rust !)
  adding [s] 00changelog.d (275 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  stream-cloned 12 files / 1.65 KB in * seconds (* */sec) (glob) (no-rust !)
  bundle2-input-part: total payload size 1869 (no-rust !)
  stream-cloned 14 files / 1.78 KB in * seconds (* */sec) (glob) (rust !)
  bundle2-input-part: total payload size 2037 (rust !)
  bundle2-input-bundle: 1 parts total
  updating the branch cache
  finished applying clone bundle
  query 1; heads
  sending batch command
  searching for changes
  all remote heads known locally
  no changes found
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 2 parts total
  checking for updated bookmarks
  updating to branch default
  resolving manifests (no-rust !)
   branchmerge: False, force: False, partial: False (no-rust !)
   ancestor: 000000000000, local: 000000000000+, remote: 9bc730a19041 (no-rust !)
   A: remote created -> g (no-rust !)
  getting A (no-rust !)
   B: remote created -> g (no-rust !)
  getting B (no-rust !)
   C: remote created -> g (no-rust !)
  getting C (no-rust !)
   D: remote created -> g (no-rust !)
  getting D (no-rust !)
   E: remote created -> g (no-rust !)
  getting E (no-rust !)
  5 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ hg clone --stream http://localhost:$HGPORT stream-clone-explicit --debug
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "stream3-exp" (params: 1 mandatory) supported
  applying stream bundle
  11 entries to transfer
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (584 bytes)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (64 bytes) (rust !)
  adding [s] 00changelog.d (275 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  stream-cloned 12 files / 1.65 KB in * seconds (* */sec) (glob) (no-rust !)
  bundle2-input-part: total payload size 1869 (no-rust !)
  stream-cloned 14 files / 1.78 KB in * seconds (* */sec) (glob) (rust !)
  bundle2-input-part: total payload size 2037 (rust !)
  bundle2-input-bundle: 1 parts total
  updating the branch cache
  finished applying clone bundle
  query 1; heads
  sending batch command
  searching for changes
  all remote heads known locally
  no changes found
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 2 parts total
  checking for updated bookmarks
  updating to branch default
  resolving manifests (no-rust !)
   branchmerge: False, force: False, partial: False (no-rust !)
   ancestor: 000000000000, local: 000000000000+, remote: 9bc730a19041 (no-rust !)
   A: remote created -> g (no-rust !)
  getting A (no-rust !)
   B: remote created -> g (no-rust !)
  getting B (no-rust !)
   C: remote created -> g (no-rust !)
  getting C (no-rust !)
   D: remote created -> g (no-rust !)
  getting D (no-rust !)
   E: remote created -> g (no-rust !)
  getting E (no-rust !)
  5 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

#endif
