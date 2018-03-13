#require lfs-test-server

  $ LFS_LISTEN="tcp://:$HGPORT"
  $ LFS_HOST="localhost:$HGPORT"
  $ LFS_PUBLIC=1
  $ export LFS_LISTEN LFS_HOST LFS_PUBLIC
#if no-windows
  $ lfs-test-server &> lfs-server.log &
  $ echo $! >> $DAEMON_PIDS
#else
  $ cat >> $TESTTMP/spawn.py <<EOF
  > import os
  > import subprocess
  > import sys
  > 
  > for path in os.environ["PATH"].split(os.pathsep):
  >     exe = os.path.join(path, 'lfs-test-server.exe')
  >     if os.path.exists(exe):
  >         with open('lfs-server.log', 'wb') as out:
  >             p = subprocess.Popen(exe, stdout=out, stderr=out)
  >             sys.stdout.write('%s\n' % p.pid)
  >             sys.exit(0)
  > sys.exit(1)
  > EOF
  $ $PYTHON $TESTTMP/spawn.py >> $DAEMON_PIDS
#endif

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > lfs=
  > [lfs]
  > url=http://foo:bar@$LFS_HOST/
  > track=all()
  > EOF

  $ hg init repo1
  $ cd repo1
  $ echo THIS-IS-LFS > a
  $ hg commit -m a -A a

A push can be serviced directly from the usercache if it isn't in the local
store.

  $ hg init ../repo2
  $ mv .hg/store/lfs .hg/store/lfs_
  $ hg push ../repo2 --debug
  http auth: user foo, password ***
  pushing to ../repo2
  http auth: user foo, password ***
  query 1; heads
  searching for changes
  1 total queries in *s (glob)
  listing keys for "phases"
  checking for updated bookmarks
  listing keys for "bookmarks"
  lfs: computing set of blobs to upload
  lfs: uploading 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b (12 bytes)
  lfs: processed: 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b
  lfs: uploaded 1 files (12 bytes)
  1 changesets found
  list of changesets:
  99a7098854a3984a5c9eab0fc7a2906697b7cb5c
  bundle2-output-bundle: "HG20", 4 parts total
  bundle2-output-part: "replycaps" 191 bytes payload
  bundle2-output-part: "check:heads" streamed payload
  bundle2-output-part: "changegroup" (params: 1 mandatory) streamed payload
  bundle2-output-part: "phase-heads" 24 bytes payload
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "replycaps" supported
  bundle2-input-part: total payload size 191
  bundle2-input-part: "check:heads" supported
  bundle2-input-part: total payload size 20
  bundle2-input-part: "changegroup" (params: 1 mandatory) supported
  adding changesets
  add changeset 99a7098854a3
  adding manifests
  adding file changes
  adding a revisions
  added 1 changesets with 1 changes to 1 files
  calling hook pretxnchangegroup.lfs: hgext.lfs.checkrequireslfs
  bundle2-input-part: total payload size 617
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 3 parts total
  updating the branch cache
  bundle2-output-bundle: "HG20", 1 parts total
  bundle2-output-part: "reply:changegroup" (advisory) (params: 0 advisory) empty payload
  bundle2-input-bundle: no-transaction
  bundle2-input-part: "reply:changegroup" (advisory) (params: 0 advisory) supported
  bundle2-input-bundle: 0 parts total
  listing keys for "phases"
  $ mv .hg/store/lfs_ .hg/store/lfs

Clear the cache to force a download
  $ rm -rf `hg config lfs.usercache`
  $ cd ../repo2
  $ hg update tip --debug
  http auth: user foo, password ***
  resolving manifests
   branchmerge: False, force: False, partial: False
   ancestor: 000000000000, local: 000000000000+, remote: 99a7098854a3
  lfs: downloading 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b (12 bytes)
  lfs: adding 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b to the usercache
  lfs: processed: 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b
   a: remote created -> g
  getting a
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

When the server has some blobs already

  $ hg mv a b
  $ echo ANOTHER-LARGE-FILE > c
  $ echo ANOTHER-LARGE-FILE2 > d
  $ hg commit -m b-and-c -A b c d
  $ hg push ../repo1 --debug
  http auth: user foo, password ***
  pushing to ../repo1
  http auth: user foo, password ***
  query 1; heads
  searching for changes
  all remote heads known locally
  listing keys for "phases"
  checking for updated bookmarks
  listing keys for "bookmarks"
  listing keys for "bookmarks"
  lfs: computing set of blobs to upload
  lfs: need to transfer 2 objects (39 bytes)
  lfs: uploading 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 (20 bytes)
  lfs: processed: 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19
  lfs: uploading d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 (19 bytes)
  lfs: processed: d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  lfs: uploaded 2 files (39 bytes)
  1 changesets found
  list of changesets:
  dfca2c9e2ef24996aa61ba2abd99277d884b3d63
  bundle2-output-bundle: "HG20", 5 parts total
  bundle2-output-part: "replycaps" 191 bytes payload
  bundle2-output-part: "check:phases" 24 bytes payload
  bundle2-output-part: "check:heads" streamed payload
  bundle2-output-part: "changegroup" (params: 1 mandatory) streamed payload
  bundle2-output-part: "phase-heads" 24 bytes payload
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "replycaps" supported
  bundle2-input-part: total payload size 191
  bundle2-input-part: "check:phases" supported
  bundle2-input-part: total payload size 24
  bundle2-input-part: "check:heads" supported
  bundle2-input-part: total payload size 20
  bundle2-input-part: "changegroup" (params: 1 mandatory) supported
  adding changesets
  add changeset dfca2c9e2ef2
  adding manifests
  adding file changes
  adding b revisions
  adding c revisions
  adding d revisions
  added 1 changesets with 3 changes to 3 files
  bundle2-input-part: total payload size 1315
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 4 parts total
  updating the branch cache
  bundle2-output-bundle: "HG20", 1 parts total
  bundle2-output-part: "reply:changegroup" (advisory) (params: 0 advisory) empty payload
  bundle2-input-bundle: no-transaction
  bundle2-input-part: "reply:changegroup" (advisory) (params: 0 advisory) supported
  bundle2-input-bundle: 0 parts total
  listing keys for "phases"

Clear the cache to force a download
  $ rm -rf `hg config lfs.usercache`
  $ hg --repo ../repo1 update tip --debug
  http auth: user foo, password ***
  resolving manifests
   branchmerge: False, force: False, partial: False
   ancestor: 99a7098854a3, local: 99a7098854a3+, remote: dfca2c9e2ef2
  lfs: need to transfer 2 objects (39 bytes)
  lfs: downloading 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 (20 bytes)
  lfs: adding 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 to the usercache
  lfs: processed: 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19
  lfs: downloading d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 (19 bytes)
  lfs: adding d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 to the usercache
  lfs: processed: d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
   b: remote created -> g
  getting b
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
   c: remote created -> g
  getting c
  lfs: found d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 in the local lfs store
   d: remote created -> g
  getting d
  lfs: found 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 in the local lfs store
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test a corrupt file download, but clear the cache first to force a download.

  $ rm -rf `hg config lfs.usercache`
  $ cp $TESTTMP/lfs-content/d1/1e/1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 blob
  $ echo 'damage' > $TESTTMP/lfs-content/d1/1e/1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  $ rm ../repo1/.hg/store/lfs/objects/d1/1e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  $ rm ../repo1/*

  $ hg --repo ../repo1 update -C tip --debug
  http auth: user foo, password ***
  resolving manifests
   branchmerge: False, force: True, partial: False
   ancestor: dfca2c9e2ef2+, local: dfca2c9e2ef2+, remote: dfca2c9e2ef2
  lfs: downloading d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 (19 bytes)
  abort: corrupt remote lfs object: d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  [255]

The corrupted blob is not added to the usercache or local store

  $ test -f ../repo1/.hg/store/lfs/objects/d1/1e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  [1]
  $ test -f `hg config lfs.usercache`/d1/1e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  [1]
  $ cp blob $TESTTMP/lfs-content/d1/1e/1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998

Test a corrupted file upload

  $ echo 'another lfs blob' > b
  $ hg ci -m 'another blob'
  $ echo 'damage' > .hg/store/lfs/objects/e6/59058e26b07b39d2a9c7145b3f99b41f797b6621c8076600e9cb7ee88291f0
  $ hg push --debug ../repo1
  http auth: user foo, password ***
  pushing to ../repo1
  http auth: user foo, password ***
  query 1; heads
  searching for changes
  all remote heads known locally
  listing keys for "phases"
  checking for updated bookmarks
  listing keys for "bookmarks"
  listing keys for "bookmarks"
  lfs: computing set of blobs to upload
  lfs: uploading e659058e26b07b39d2a9c7145b3f99b41f797b6621c8076600e9cb7ee88291f0 (17 bytes)
  abort: detected corrupt lfs object: e659058e26b07b39d2a9c7145b3f99b41f797b6621c8076600e9cb7ee88291f0
  (run hg verify)
  [255]

Archive will prefetch blobs in a group

  $ rm -rf .hg/store/lfs `hg config lfs.usercache`
  $ hg archive --debug -r 1 ../archive
  http auth: user foo, password ***
  lfs: need to transfer 3 objects (51 bytes)
  lfs: downloading 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b (12 bytes)
  lfs: adding 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b to the usercache
  lfs: processed: 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b
  lfs: downloading 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 (20 bytes)
  lfs: adding 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 to the usercache
  lfs: processed: 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19
  lfs: downloading d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 (19 bytes)
  lfs: adding d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 to the usercache
  lfs: processed: d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
  lfs: found d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 in the local lfs store
  lfs: found 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 in the local lfs store
  $ find ../archive | sort
  ../archive
  ../archive/.hg_archival.txt
  ../archive/a
  ../archive/b
  ../archive/c
  ../archive/d

Cat will prefetch blobs in a group

  $ rm -rf .hg/store/lfs `hg config lfs.usercache`
  $ hg cat --debug -r 1 a b c
  http auth: user foo, password ***
  lfs: need to transfer 2 objects (31 bytes)
  lfs: downloading 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b (12 bytes)
  lfs: adding 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b to the usercache
  lfs: processed: 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b
  lfs: downloading d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 (19 bytes)
  lfs: adding d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 to the usercache
  lfs: processed: d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
  THIS-IS-LFS
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
  THIS-IS-LFS
  lfs: found d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 in the local lfs store
  ANOTHER-LARGE-FILE

Revert will prefetch blobs in a group

  $ rm -rf .hg/store/lfs
  $ rm -rf `hg config lfs.usercache`
  $ rm *
  $ hg revert --all -r 1 --debug
  http auth: user foo, password ***
  adding a
  reverting b
  reverting c
  reverting d
  lfs: need to transfer 3 objects (51 bytes)
  lfs: downloading 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b (12 bytes)
  lfs: adding 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b to the usercache
  lfs: processed: 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b
  lfs: downloading 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 (20 bytes)
  lfs: adding 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 to the usercache
  lfs: processed: 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19
  lfs: downloading d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 (19 bytes)
  lfs: adding d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 to the usercache
  lfs: processed: d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store
  lfs: found d11e1a642b60813aee592094109b406089b8dff4cb157157f753418ec7857998 in the local lfs store
  lfs: found 37a65ab78d5ecda767e8622c248b5dbff1e68b1678ab0e730d5eb8601ec8ad19 in the local lfs store
  lfs: found 31cf46fbc4ecd458a0943c5b4881f1f5a6dd36c53d6167d5b69ac45149b38e5b in the local lfs store

Check error message when the remote missed a blob:

  $ echo FFFFF > b
  $ hg commit -m b -A b
  $ echo FFFFF >> b
  $ hg commit -m b b
  $ rm -rf .hg/store/lfs
  $ rm -rf `hg config lfs.usercache`
  $ hg update -C '.^' --debug
  http auth: user foo, password ***
  resolving manifests
   branchmerge: False, force: True, partial: False
   ancestor: 62fdbaf221c6+, local: 62fdbaf221c6+, remote: ef0564edf47e
  abort: LFS server error. Remote object for "b" not found:(.*)! (re)
  [255]

Check error message when object does not exist:

  $ cd $TESTTMP
  $ hg init test && cd test
  $ echo "[extensions]" >> .hg/hgrc
  $ echo "lfs=" >> .hg/hgrc
  $ echo "[lfs]" >> .hg/hgrc
  $ echo "threshold=1" >> .hg/hgrc
  $ echo a > a
  $ hg add a
  $ hg commit -m 'test'
  $ echo aaaaa > a
  $ hg commit -m 'largefile'
  $ hg debugdata .hg/store/data/a.i 1 # verify this is no the file content but includes "oid", the LFS "pointer".
  version https://git-lfs.github.com/spec/v1
  oid sha256:bdc26931acfb734b142a8d675f205becf27560dc461f501822de13274fe6fc8a
  size 6
  x-is-binary 0
  $ cd ..
  $ rm -rf `hg config lfs.usercache`

(Restart the server in a different location so it no longer has the content)

  $ $PYTHON $RUNTESTDIR/killdaemons.py $DAEMON_PIDS
  $ rm $DAEMON_PIDS
  $ mkdir $TESTTMP/lfs-server2
  $ cd $TESTTMP/lfs-server2
#if no-windows
  $ lfs-test-server &> lfs-server.log &
  $ echo $! >> $DAEMON_PIDS
#else
  $ $PYTHON $TESTTMP/spawn.py >> $DAEMON_PIDS
#endif

  $ cd $TESTTMP
  $ hg --debug clone test test2
  http auth: user foo, password ***
  linked 6 files
  http auth: user foo, password ***
  updating to branch default
  resolving manifests
   branchmerge: False, force: False, partial: False
   ancestor: 000000000000, local: 000000000000+, remote: d2a338f184a8
  abort: LFS server error. Remote object for "a" not found:(.*)! (re)
  [255]

  $ $PYTHON $RUNTESTDIR/killdaemons.py $DAEMON_PIDS
