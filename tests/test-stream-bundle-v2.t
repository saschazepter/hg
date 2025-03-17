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
  > [ui]
  > portablefilenames=abort
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
  > D  # D/ba"r=<deleted>
  > |
  > C  # C/ba"r=faz
  > |
  > B  # B/blu=fuz
  > |
  > A
  > EOF

  $ hg bundle -a --type="none-v2;stream=$stream_version" bundle.hg
  $ hg debugbundle bundle.hg
  Stream params: {}
  stream2 -- {bytecount: 1908, filecount: 14, requirements: generaldelta%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 no-zstd !)
  stream2 -- {bytecount: 1911, filecount: 14, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 zstd no-rust !)
  stream2 -- {bytecount: 2103, filecount: 16, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 rust !)
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
  stream2 -- {bytecount: 1908, filecount: 14, requirements: generaldelta%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 no-zstd !)
  stream2 -- {bytecount: 1911, filecount: 14, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 zstd no-rust !)
  stream2 -- {bytecount: 2103, filecount: 16, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True) (stream-v2 rust !)
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

  $ hg serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS

  $ cd ..


Requirements filtering
======================


Unknown requirements
--------------------

Stream bundle spec with unknown requirements should be filtered out

  $ cat > main/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/bundle.hg BUNDLESPEC=none-v2;stream=$stream_version;requirements%3Drevlogv42
  > EOF


  $ hg clone -U http://localhost:$HGPORT stream-clone-unsupported-requirements
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 7 changes to 7 files
  new changesets 426bada5c675:92165ab525bf (5 drafts)

known requirements
------------------

Stream bundle spec with known requirements should be filtered out



  $ cat > main/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/bundle.hg BUNDLESPEC=none-v2;stream=$stream_version;requirements%3Dsparserevlog,revlogv1
  > EOF

  $ hg clone -U http://localhost:$HGPORT stream-clone-supported-requirements
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  * to transfer* (glob)
  stream-cloned * in * seconds (*/sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found


known but irrelevant requirements
---------------------------------

As fncache and dotencode are abstracted by the vfs, they don't actually matters for streamclone

  $ cat > main/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/bundle.hg BUNDLESPEC=none-v2;stream=$stream_version;requirements%3Dshare-safe
  > http://localhost:$HGPORT1/bundle.hg BUNDLESPEC=none-v2;stream=$stream_version;requirements%3Dshare-safe,fncache,dotencode
  > EOF

  $ hg clone -U http://localhost:$HGPORT stream-clone-ignorable-requirements
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  * to transfer* (glob)
  stream-cloned * in * seconds (*/sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found



Test that we can apply the bundle as a stream clone bundle
==========================================================

  $ cat > main/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/bundle.hg BUNDLESPEC=`hg debugbundle --spec main/bundle.hg`
  > EOF


#if stream-v2
  $ hg clone http://localhost:$HGPORT stream-clone-implicit --debug
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "stream2" (params: 3 mandatory) supported
  applying stream bundle
  14 files to transfer, 1.86 KB of data (no-rust no-zstd !)
  14 files to transfer, 1.87 KB of data (no-rust zstd !)
  16 files to transfer, 2.05 KB of data (rust !)
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] data/ba"r.i (68 bytes)
  adding [s] data/blu.i (68 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (649 bytes) (no-zstd !)
  adding [s] 00manifest.i (652 bytes) (zstd no-rust !)
  adding [s] 00manifest.i (654 bytes) (zstd rust !)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (128 bytes) (rust !)
  adding [s] 00changelog.d (289 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  bundle2-input-part: total payload size 2099 (no-rust no-zstd !)
  bundle2-input-part: total payload size 2102 (no-rust zstd !)
  bundle2-input-part: total payload size 2337 (rust !)
  stream-cloned 14 files / 1.86 KB in * seconds (* */sec) (glob) (no-rust no-zstd !)
  stream-cloned 14 files / 1.87 KB in * seconds (* */sec) (glob) (no-rust zstd !)
  stream-cloned 16 files / 2.05 KB in * seconds (* */sec) (glob) (rust !)
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
   ancestor: 000000000000, local: 000000000000+, remote: 92165ab525bf (no-rust !)
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
   blu: remote created -> g (no-rust !)
  getting blu (no-rust !)
  6 files updated, 0 files merged, 0 files removed, 0 files unresolved
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
  14 files to transfer, 1.86 KB of data (no-rust no-zstd !)
  14 files to transfer, 1.87 KB of data (no-rust zstd !)
  16 files to transfer, 2.05 KB of data (rust !)
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] data/ba"r.i (68 bytes)
  adding [s] data/blu.i (68 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (649 bytes) (no-zstd !)
  adding [s] 00manifest.i (652 bytes) (zstd no-rust !)
  adding [s] 00manifest.i (654 bytes) (zstd rust !)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (128 bytes) (rust !)
  adding [s] 00changelog.d (289 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  bundle2-input-part: total payload size 2099 (no-rust no-zstd !)
  bundle2-input-part: total payload size 2102 (no-rust zstd !)
  bundle2-input-part: total payload size 2337 (rust !)
  stream-cloned 14 files / 1.86 KB in * seconds (* */sec) (glob) (no-rust no-zstd !)
  stream-cloned 14 files / 1.87 KB in * seconds (* */sec) (glob) (no-rust zstd !)
  stream-cloned 16 files / 2.05 KB in * seconds (* */sec) (glob) (rust !)
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
   ancestor: 000000000000, local: 000000000000+, remote: 92165ab525bf (no-rust !)
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
   blu: remote created -> g (no-rust !)
  getting blu (no-rust !)
  6 files updated, 0 files merged, 0 files removed, 0 files unresolved
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
  13 entries to transfer
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] data/ba"r.i (68 bytes)
  adding [s] data/blu.i (68 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (649 bytes) (no-zstd !)
  adding [s] 00manifest.i (652 bytes) (zstd no-rust !)
  adding [s] 00manifest.i (654 bytes) (zstd rust !)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (128 bytes) (rust !)
  adding [s] 00changelog.d (289 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  stream-cloned 14 files / 1.86 KB in * seconds (* */sec) (glob) (no-rust no-zstd !)
  stream-cloned 14 files / 1.87 KB in * seconds (* */sec) (glob) (no-rust zstd !)
  bundle2-input-part: total payload size 2113 (no-rust no-zstd !)
  bundle2-input-part: total payload size 2116 (no-rust zstd !)
  stream-cloned 16 files / 2.05 KB in * seconds (* */sec) (glob) (rust !)
  bundle2-input-part: total payload size 2351 (rust !)
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
   ancestor: 000000000000, local: 000000000000+, remote: 92165ab525bf (no-rust !)
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
   blu: remote created -> g (no-rust !)
  getting blu (no-rust !)
  6 files updated, 0 files merged, 0 files removed, 0 files unresolved
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
  13 entries to transfer
  starting 4 threads for background file closing (?)
  starting 4 threads for background file closing (?)
  adding [s] data/A.i (66 bytes)
  adding [s] data/B.i (66 bytes)
  adding [s] data/C.i (66 bytes)
  adding [s] data/D.i (66 bytes)
  adding [s] data/E.i (66 bytes)
  adding [s] data/ba"r.i (68 bytes)
  adding [s] data/blu.i (68 bytes)
  adding [s] phaseroots (43 bytes)
  adding [s] 00manifest.i (649 bytes) (no-zstd !)
  adding [s] 00manifest.i (652 bytes) (zstd no-rust !)
  adding [s] 00manifest.i (654 bytes) (zstd rust !)
  adding [s] 00changelog.n (62 bytes) (rust !)
  adding [s] 00changelog-b875dfc5.nd (128 bytes) (rust !)
  adding [s] 00changelog.d (289 bytes)
  adding [s] 00changelog.i (320 bytes)
  adding [c] branch2-served (94 bytes)
  adding [c] rbc-names-v2 (7 bytes)
  adding [c] rbc-revs-v2 (40 bytes)
  stream-cloned 14 files / 1.86 KB in * seconds (* */sec) (glob) (no-rust no-zstd !)
  stream-cloned 14 files / 1.87 KB in * seconds (* */sec) (glob) (no-rust zstd !)
  bundle2-input-part: total payload size 2113 (no-rust no-zstd !)
  bundle2-input-part: total payload size 2116 (no-rust zstd !)
  stream-cloned 16 files / 2.05 KB in * seconds (* */sec) (glob) (rust !)
  bundle2-input-part: total payload size 2351 (rust !)
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
   ancestor: 000000000000, local: 000000000000+, remote: 92165ab525bf (no-rust !)
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
   blu: remote created -> g (no-rust !)
  getting blu (no-rust !)
  6 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

#endif
