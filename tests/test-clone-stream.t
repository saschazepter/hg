#require serve no-chg

#testcases stream-legacy stream-bundle2-v2 stream-bundle2-v3

#if stream-legacy
  $ cat << EOF >> $HGRCPATH
  > [server]
  > bundle2.stream = no
  > [format]
  > # persistent nodemap is too broken with legacy format,
  > # however client with nodemap support will have better stream support.
  > use-persistent-nodemap=no
  > EOF
#endif
#if stream-bundle2-v3
  $ cat << EOF >> $HGRCPATH
  > [experimental]
  > stream-v3 = yes
  > EOF
#endif

Initialize repository

  $ hg init server
  $ cd server
  $ sh $TESTDIR/testlib/stream_clone_setup.sh
  adding 00changelog-ab349180a0405010.nd
  adding 00changelog.d
  adding 00changelog.i
  adding 00changelog.n
  adding 00manifest.d
  adding 00manifest.i
  adding container/isam-build-centos7/bazel-coverage-generator-sandboxfs-compatibility-0758e3e4f6057904d44399bd666faba9e7f40686.patch
  adding data/foo.d
  adding data/foo.i
  adding data/foo.n
  adding data/undo.babar
  adding data/undo.d
  adding data/undo.foo.d
  adding data/undo.foo.i
  adding data/undo.foo.n
  adding data/undo.i
  adding data/undo.n
  adding data/undo.py
  adding foo.d
  adding foo.i
  adding foo.n
  adding meta/foo.d
  adding meta/foo.i
  adding meta/foo.n
  adding meta/undo.babar
  adding meta/undo.d
  adding meta/undo.foo.d
  adding meta/undo.foo.i
  adding meta/undo.foo.n
  adding meta/undo.i
  adding meta/undo.n
  adding meta/undo.py
  adding savanah/foo.d
  adding savanah/foo.i
  adding savanah/foo.n
  adding savanah/undo.babar
  adding savanah/undo.d
  adding savanah/undo.foo.d
  adding savanah/undo.foo.i
  adding savanah/undo.foo.n
  adding savanah/undo.i
  adding savanah/undo.n
  adding savanah/undo.py
  adding store/C\xc3\xa9lesteVille_is_a_Capital_City (esc)
  adding store/foo.d
  adding store/foo.i
  adding store/foo.n
  adding store/undo.babar
  adding store/undo.d
  adding store/undo.foo.d
  adding store/undo.foo.i
  adding store/undo.foo.n
  adding store/undo.i
  adding store/undo.n
  adding store/undo.py
  adding undo.babar
  adding undo.d
  adding undo.foo.d
  adding undo.foo.i
  adding undo.foo.n
  adding undo.i
  adding undo.n
  adding undo.py

  $ hg --config server.uncompressed=false serve -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

Check local clone
==================

The logic is close enough of uncompressed.
This is present here to reuse the testing around file with "special" names.

  $ hg clone server local-clone
  updating to branch default
  1088 files updated, 0 files merged, 0 files removed, 0 files unresolved

Check that the clone went well

  $ hg verify -R local-clone -q

Check uncompressed
==================

Cannot stream clone when server.uncompressed is set to false
------------------------------------------------------------

When `server.uncompressed` is disabled, the client should fallback to a bundle
based clone with a warning.


  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=stream_out'
  200 Script output follows
  
  1

  $ hg debugcapabilities http://localhost:$HGPORT
  Main capabilities:
    batch
    branchmap
    $USUAL_BUNDLE2_CAPS_SERVER$
    changegroupsubset
    compression=$BUNDLE2_COMPRESSIONS$
    getbundle
    httpheader=1024
    httpmediatype=0.1rx,0.1tx,0.2tx
    known
    lookup
    pushkey
    unbundle=HG10GZ,HG10BZ,HG10UN
    unbundlehash
  Bundle2 capabilities:
    HG20
    bookmarks
    changegroup
      01
      02
      03
    checkheads
      related
    digests
      md5
      sha1
      sha512
    error
      abort
      unsupportedcontent
      pushraced
      pushkey
    hgtagsfnodes
    listkeys
    phases
      heads
    pushkey
    remote-changegroup
      http
      https

  $ hg clone --stream -U http://localhost:$HGPORT server-disabled
  warning: stream clone requested but server has them disabled
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 1088 changes to 1088 files
  new changesets 96ee1d7354c4:5223b5e3265f

  $ killdaemons.py
  $ cd server
  $ hg serve -p $HGPORT -d --pid-file=hg.pid --error errors.txt
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

Basic clone
-----------

Check that --stream trigger a stream clone and result in a valid repositoty

We check the associated output for exact bytes on file number as changes in
these value implies changes in the data transfered and can detect unintended
changes in the process.

#if stream-legacy
  $ hg clone --stream -U http://localhost:$HGPORT clone1
  streaming all changes
  1091 files to transfer, 102 KB of data (no-zstd !)
  stream-cloned 1091 files / 102 KB in * seconds (* */sec) (glob) (no-zstd !)
  1091 files to transfer, 98.8 KB of data (zstd !)
  stream-cloned 1091 files / 98.8 KB in * seconds (* */sec) (glob) (zstd !)
  searching for changes
  no changes found
#endif
#if stream-bundle2-v2
  $ hg clone --stream -U http://localhost:$HGPORT clone1
  streaming all changes
  1094 files to transfer, 102 KB of data (no-zstd !)
  stream-cloned 1094 files / 102 KB in * seconds (* */sec) (glob) (no-zstd !)
  1094 files to transfer, 98.9 KB of data (zstd no-rust !)
  stream-cloned 1094 files / 98.9 KB in * seconds (* */sec) (glob) (zstd no-rust !)
  1096 files to transfer, 99.0 KB of data (zstd rust !)
  stream-cloned 1096 files / 99.0 KB in * seconds (* */sec) (glob) (zstd rust !)
#endif

#if stream-bundle2-v3
  $ hg clone --stream -U http://localhost:$HGPORT clone1
  streaming all changes
  1093 entries to transfer
  stream-cloned 1094 files / 102 KB in * seconds (* */sec) (glob) (no-zstd !)
  stream-cloned 1094 files / 98.9 KB in * seconds (* */sec) (glob) (zstd no-rust !)
  stream-cloned 1096 files / 99.0 KB in * seconds (* */sec) (glob) (zstd rust !)
#endif

#if no-stream-legacy
  $ ls -1 clone1/.hg/cache
  branch2-base
  branch2-served
  rbc-names-v2
  rbc-revs-v2
  tags2
  tags2-served
#endif

  $ hg -R clone1 verify --quiet
  $ cat server/errors.txt

getbundle requests with stream=1 are uncompressed
-------------------------------------------------

We check that `getbundle` will return a stream bundle when requested.

XXX manually building the --requestheader is fragile and will drift away from actual usage

  $ get-with-headers.py $LOCALIP:$HGPORT '?cmd=getbundle' content-type --bodyfile body --hgproto '0.1 0.2 comp=zlib,none' --requestheader "x-hgarg-1=bundlecaps=HG20%2Cbundle2%3DHG20%250Abookmarks%250Achangegroup%253D01%252C02%252C03%250Adigests%253Dmd5%252Csha1%252Csha512%250Aerror%253Dabort%252Cunsupportedcontent%252Cpushraced%252Cpushkey%250Ahgtagsfnodes%250Alistkeys%250Aphases%253Dheads%250Apushkey%250Aremote-changegroup%253Dhttp%252Chttps%250Astream%253Dv2&cg=0&common=0000000000000000000000000000000000000000&heads=c17445101a72edac06facd130d14808dfbd5c7c2&stream=1"
  200 Script output follows
  content-type: application/mercurial-0.2
  

  $ f --size --hex --bytes 48 body
  body: size=* (glob)
  0000: 04 6e 6f 6e 65 48 47 32 30 00 00 00 00 00 00 00 |.noneHG20.......|
  0010: ?? 07 53 54 52 45 41 4d 32 00 00 00 00 03 00 09 |?.STREAM2.......| (glob)
  0020: 06 09 04 0c ?? 62 79 74 65 63 6f 75 6e 74 31 30 |....?bytecount10| (glob)

--uncompressed is an alias to --stream
---------------------------------------

The alias flag should trigger a stream clone too.

  $ hg clone --uncompressed -U http://localhost:$HGPORT clone1-uncompressed
  streaming all changes
  * files to transfer* (glob) (no-stream-bundle2-v3 !)
  * entries to transfer (glob) (stream-bundle2-v3 !)
  stream-cloned * files / * KB in * seconds (* */sec) (glob)
  searching for changes (stream-legacy !)
  no changes found (stream-legacy !)

Clone with background file closing enabled
-------------------------------------------

The backgound file closing logic should trigger when configured to do so, and
the result should be a valid repository.

  $ hg --debug --config worker.backgroundclose=true --config worker.backgroundcloseminfilecount=1 clone --stream -U http://localhost:$HGPORT clone-background | grep "background file closing"
  starting 4 threads for background file closing
  starting 4 threads for background file closing (no-stream-legacy !)
  $ hg verify -R clone-background --quiet

Cannot stream clone when there are secret changesets
----------------------------------------------------

If secret changeset are present the should not be cloned (by default) and the
clone falls back to a bundle clone.

  $ hg -R server phase --force --secret -r tip
  $ hg clone --stream -U http://localhost:$HGPORT secret-denied
  warning: stream clone requested but server has them disabled
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 1025 changes to 1025 files
  new changesets 96ee1d7354c4:c17445101a72

  $ killdaemons.py

Streaming of secrets can be overridden by server config
-------------------------------------------------------

Secret changeset can still be streamed if the server is configured to do so.

  $ cd server
  $ hg serve --config server.uncompressedallowsecret=true -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

  $ hg clone --stream -U http://localhost:$HGPORT secret-allowed
  streaming all changes
  * files to transfer* (glob) (no-stream-bundle2-v3 !)
  * entries to transfer (glob) (stream-bundle2-v3 !)
  stream-cloned * files / * KB in * seconds (* */sec) (glob)
  searching for changes (stream-legacy !)
  no changes found (stream-legacy !)

  $ killdaemons.py

Verify interaction between preferuncompressed and secret presence
-----------------------------------------------------------------

Secret presence will still make the clone falls back to a normal bundle even if
the server prefers stream clone.

  $ cd server
  $ hg serve --config server.preferuncompressed=true -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

  $ hg clone -U http://localhost:$HGPORT preferuncompressed-secret
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 1025 changes to 1025 files
  new changesets 96ee1d7354c4:c17445101a72

  $ killdaemons.py

Clone not allowed when full bundles disabled and can't serve secrets
--------------------------------------------------------------------

The clone should fail as no valid option is found.

  $ cd server
  $ hg serve --config server.disablefullbundle=true -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

  $ hg clone --stream http://localhost:$HGPORT secret-full-disabled
  warning: stream clone requested but server has them disabled
  requesting all changes
  remote: abort: server has pull-based clones disabled
  abort: pull failed on remote
  (remove --pull if specified or upgrade Mercurial)
  [100]

Local stream clone with secrets involved
----------------------------------------

(This is just a test over behavior: if you have access to the repo's files,
there is no security so it isn't important to prevent a clone here.)

  $ hg clone -U --stream server local-secret
  warning: stream clone requested but server has them disabled
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 1025 changes to 1025 files
  new changesets 96ee1d7354c4:c17445101a72

(revert introduction of secret changeset)

  $ hg -R server phase --draft 'secret()'

Stream clone while repo is changing:
------------------------------------

We should send a repository in a valid state, ignoring the ongoing transaction.

  $ mkdir changing
  $ cd changing

prepare repo with small and big file to cover both code paths in emitrevlogdata
(inlined revlog and non-inlined revlogs).

  $ hg init repo
  $ touch repo/f1
  $ $TESTDIR/seq.py 50000 > repo/f2
  $ hg -R repo ci -Aqm "0"
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
#   $ cat << EOF >> $HGRCPATH
#   > [hooks]
#   > pre-clone=rm -f "$TESTTMP/sync_file_walked_*"
#   > EOF
  $ hg serve -R repo -p $HGPORT1 -d --error errors.log --pid-file=hg.pid --config extensions.stream_steps="$RUNTESTDIR/testlib/ext-stream-clone-steps.py"
  $ cat hg.pid >> $DAEMON_PIDS

clone while modifying the repo between stating file with write lock and
actually serving file content

also delete some cache in the process

  $ (hg clone -q --stream -U http://localhost:$HGPORT1 clone; touch "$HG_TEST_STREAM_WALKED_FILE_5") &

  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_1
(delete one file)
  $ ls repo/.hg/cache/rbc-revs-v2
  repo/.hg/cache/rbc-revs-v2
  $ rm repo/.hg/cache/rbc-revs-v2
(truncate another)
  $ ls repo/.hg/cache/rbc-names-v2
  repo/.hg/cache/rbc-names-v2
  $ echo football > repo/.hg/cache/rbc-names-v2
(lenghten another one)
  $ ls repo/.hg/cache/branch2-served
  repo/.hg/cache/branch2-served
  $ echo bar >> repo/.hg/cache/branch2-served
(remove one in wcache))
  $ ls repo/.hg/wcache/manifestfulltextcache
  repo/.hg/wcache/manifestfulltextcache
  $ rm repo/.hg/wcache/manifestfulltextcache
  $ touch $HG_TEST_STREAM_WALKED_FILE_2

  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_3
  $ echo >> repo/f1
  $ echo >> repo/f2
  $ hg -R repo ci -m "1" --config ui.timeout.warn=-1
(truncate further)
  $ ls repo/.hg/cache/rbc-names-v2
  repo/.hg/cache/rbc-names-v2
  $ echo foo > repo/.hg/cache/rbc-names-v2
(lenghten another one)
  $ ls repo/.hg/cache/branch2-served
  repo/.hg/cache/branch2-served
  $ echo babar >> repo/.hg/cache/branch2-served
  $ touch $HG_TEST_STREAM_WALKED_FILE_4
  $ $RUNTESTDIR/testlib/wait-on-file 10 $HG_TEST_STREAM_WALKED_FILE_5
  $ hg -R clone id
  000000000000
  $ hg -R clone verify --quiet
  $ cat errors.log
  $ cd ..

Stream repository with bookmarks
--------------------------------

The bookmark file should be send over in the stream bundle.

add a bookmark

  $ hg -R server bookmark -r tip some-bookmark

clone it

  $ hg clone --stream http://localhost:$HGPORT with-bookmarks
  streaming all changes
  1091 files to transfer, * KB of data (glob) (stream-legacy !)
  1097 files to transfer, * KB of data (glob) (stream-bundle2-v2 no-rust !)
  1099 files to transfer, * KB of data (glob) (stream-bundle2-v2 rust !)
  1096 entries to transfer (stream-bundle2-v3 !)
  stream-cloned * files / * KB in * seconds (* */sec) (glob)
  searching for changes (stream-legacy !)
  no changes found (stream-legacy !)
  updating to branch default
  1088 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg verify -R with-bookmarks -q
  $ hg -R with-bookmarks bookmarks
     some-bookmark             2:5223b5e3265f

Stream repository with phases
-----------------------------

The file storing phases information (e.g. phaseroots) should be sent as part of
the stream bundle.

Clone as publishing

  $ hg -R server phase -r 'all()'
  0: draft
  1: draft
  2: draft

  $ hg clone --stream http://localhost:$HGPORT phase-publish
  streaming all changes
  1091 files to transfer, * KB of data (glob) (stream-legacy !)
  1097 files to transfer, * KB of data (glob) (stream-bundle2-v2 no-rust !)
  1099 files to transfer, * KB of data (glob) (stream-bundle2-v2 rust !)
  1096 entries to transfer (stream-bundle2-v3 !)
  stream-cloned * files * KB in * seconds (* */sec) (glob)
  searching for changes (stream-legacy !)
  no changes found (stream-legacy !)
  updating to branch default
  1088 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg verify -R phase-publish -q
  $ hg -R phase-publish phase -r 'all()'
  0: public
  1: public
  2: public

Clone as non publishing

  $ cat << EOF >> server/.hg/hgrc
  > [phases]
  > publish = False
  > EOF
  $ killdaemons.py
  $ hg -R server serve -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS

  $ hg clone --stream http://localhost:$HGPORT phase-no-publish
  streaming all changes
  * files to transfer, * KB of data (glob) (no-stream-bundle2-v3 !)
  * entries to transfer (glob) (stream-bundle2-v3 !)
  stream-cloned * / * KB in * seconds (* */sec) (glob)
  searching for changes (stream-legacy !)
  no changes found (stream-legacy !)
  updating to branch default
  1088 files updated, 0 files merged, 0 files removed, 0 files unresolved

Note: With v1 of the stream protocol, changeset are always cloned as public. It
make stream v1 unsuitable for non-publishing repository.

  $ hg -R phase-no-publish phase -r 'all()'
  0: public (stream-legacy !)
  1: public (stream-legacy !)
  2: public (stream-legacy !)
  0: draft (no-stream-legacy !)
  1: draft (no-stream-legacy !)
  2: draft (no-stream-legacy !)
  $ hg verify -R phase-no-publish -q

  $ killdaemons.py


Stream repository with obsolescence
-----------------------------------

#if stream-legacy

With v1 of the stream protocol, changeset are always cloned as public. There's
no obsolescence markers exchange in stream v1.

#else

Clone non-publishing with obsolescence

The obsstore file should be send as part of the stream bundle

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution=all
  > EOF

  $ cd server
  $ echo foo > foo
  $ hg -q commit -m 'about to be pruned'
  $ hg debugobsolete `hg log -r . -T '{node}'` -d '0 0' -u test --record-parents
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg up null -q
  $ hg log -T '{rev}: {phase}\n'
  2: draft
  1: draft
  0: draft
  $ hg serve -p $HGPORT -d --pid-file=hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..

  $ hg clone -U --stream http://localhost:$HGPORT with-obsolescence
  streaming all changes
  1099 files to transfer, * KB of data (glob) (stream-bundle2-v2 no-rust !)
  1101 files to transfer, * KB of data (glob) (stream-bundle2-v2 rust !)
  1098 entries to transfer (no-stream-bundle2-v2 !)
  stream-cloned * files / * KB in * seconds (* */sec) (glob)
  $ hg -R with-obsolescence log -T '{rev}: {phase}\n'
  2: draft
  1: draft
  0: draft
  $ hg debugobsolete -R with-obsolescence
  8c206a663911c1f97f2f9d7382e417ae55872cfa 0 {5223b5e3265f0df40bb743da62249413d74ac70f} (Thu Jan 01 00:00:00 1970 +0000) {'user': 'test'}
  $ hg verify -R with-obsolescence -q

  $ hg clone -U --stream --config experimental.evolution=0 http://localhost:$HGPORT with-obsolescence-no-evolution
  streaming all changes
  remote: abort: server has obsolescence markers, but client cannot receive them via stream clone
  abort: pull failed on remote
  [100]

  $ killdaemons.py

#endif

Cloning a repo with no requirements doesn't give some obscure error
-------------------------------------------------------------------

  $ mkdir -p empty-repo/.hg
  $ hg clone -q --stream ssh://user@dummy/empty-repo empty-repo2
  $ hg --cwd empty-repo2 verify -q

Cloning a repo with an empty manifestlog doesn't give some weird error
----------------------------------------------------------------------

  $ rm -r empty-repo; hg init empty-repo
  $ (cd empty-repo; touch x; hg commit -Am empty; hg debugstrip -r 0) > /dev/null
  $ hg clone -q --stream ssh://user@dummy/empty-repo empty-repo3
  $ hg --cwd empty-repo3 verify -q
