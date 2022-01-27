Setting up test

  $ hg init test
  $ cd test
  $ echo 0 > afile
  $ hg add afile
  $ hg commit -m "0.0"
  $ echo 1 >> afile
  $ hg commit -m "0.1"
  $ echo 2 >> afile
  $ hg commit -m "0.2"
  $ echo 3 >> afile
  $ hg commit -m "0.3"
  $ hg update -C 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo 1 >> afile
  $ hg commit -m "1.1"
  created new head
  $ echo 2 >> afile
  $ hg commit -m "1.2"
  $ echo "a line" > fred
  $ echo 3 >> afile
  $ hg add fred
  $ hg commit -m "1.3"
  $ hg mv afile adifferentfile
  $ hg commit -m "1.3m"
  $ hg update -C 3
  1 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg mv afile anotherfile
  $ hg commit -m "0.3m"
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 9 changesets with 7 changes to 4 files
  $ cd ..
  $ hg init empty

Bundle and phase

  $ hg -R test phase --force --secret 0
  $ hg -R test bundle phase.hg empty
  searching for changes
  no changes found (ignored 9 secret changesets)
  [1]
  $ hg -R test phase --draft -r 'head()'

Bundle --all

  $ hg -R test bundle --all all.hg
  9 changesets found

Bundle test to full.hg

  $ hg -R test bundle full.hg empty
  searching for changes
  9 changesets found

Unbundle full.hg in test

  $ hg -R test unbundle full.hg
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 0 changes to 4 files
  (run 'hg update' to get a working copy)

Verify empty

  $ hg -R empty heads
  [1]
  $ hg -R empty verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 0 changesets with 0 changes to 0 files

#if repobundlerepo

Pull full.hg into test (using --cwd)

  $ hg --cwd test pull ../full.hg
  pulling from ../full.hg
  searching for changes
  no changes found

Verify that there are no leaked temporary files after pull (issue2797)

  $ ls test/.hg | grep .hg10un
  [1]

Pull full.hg into empty (using --cwd)

  $ hg --cwd empty pull ../full.hg
  pulling from ../full.hg
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets f9ee2f85a263:aa35859c02ea (9 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)

Rollback empty

  $ hg -R empty rollback
  repository tip rolled back to revision -1 (undo pull)

Pull full.hg into empty again (using --cwd)

  $ hg --cwd empty pull ../full.hg
  pulling from ../full.hg
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets f9ee2f85a263:aa35859c02ea (9 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)

Pull full.hg into test (using -R)

  $ hg -R test pull full.hg
  pulling from full.hg
  searching for changes
  no changes found

Pull full.hg into empty (using -R)

  $ hg -R empty pull full.hg
  pulling from full.hg
  searching for changes
  no changes found

Rollback empty

  $ hg -R empty rollback
  repository tip rolled back to revision -1 (undo pull)

Pull full.hg into empty again (using -R)

  $ hg -R empty pull full.hg
  pulling from full.hg
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets f9ee2f85a263:aa35859c02ea (9 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)

Log -R full.hg in fresh empty

  $ rm -r empty
  $ hg init empty
  $ cd empty
  $ hg -R bundle://../full.hg log
  changeset:   8:aa35859c02ea
  tag:         tip
  parent:      3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3m
  
  changeset:   7:a6a34bfa0076
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3m
  
  changeset:   6:7373c1169842
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3
  
  changeset:   5:1bb50a9436a7
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.2
  
  changeset:   4:095197eb4973
  parent:      0:f9ee2f85a263
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.1
  
  changeset:   3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3
  
  changeset:   2:e38ba6f5b7e0
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.2
  
  changeset:   1:34c2bf6b0626
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.1
  
  changeset:   0:f9ee2f85a263
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.0
  
Make sure bundlerepo doesn't leak tempfiles (issue2491)

  $ ls .hg
  00changelog.i
  cache
  requires
  store
  wcache

Pull ../full.hg into empty (with hook)

  $ cat >> .hg/hgrc <<EOF
  > [hooks]
  > changegroup = sh -c "printenv.py --line changegroup"
  > EOF

doesn't work (yet ?)
NOTE: msys is mangling the URL below

hg -R bundle://../full.hg verify

  $ hg pull bundle://../full.hg
  pulling from bundle:../full.hg
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets f9ee2f85a263:aa35859c02ea (9 drafts)
  changegroup hook: HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=f9ee2f85a263049e9ae6d37a0e67e96194ffb735
  HG_NODE_LAST=aa35859c02ea8bd48da5da68cd2740ac71afcbaf
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  bundle:../full.hg (no-msys !)
  bundle;../full.hg (msys !)
  HG_URL=bundle:../full.hg (no-msys !)
  HG_URL=bundle;../full.hg (msys !)
  
  (run 'hg heads' to see heads, 'hg merge' to merge)

Rollback empty

  $ hg rollback
  repository tip rolled back to revision -1 (undo pull)
  $ cd ..

Log -R bundle:empty+full.hg

  $ hg -R bundle:empty+full.hg log --template="{rev} "; echo ""
  8 7 6 5 4 3 2 1 0 

Pull full.hg into empty again (using -R; with hook)

  $ hg -R empty pull full.hg
  pulling from full.hg
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets f9ee2f85a263:aa35859c02ea (9 drafts)
  changegroup hook: HG_HOOKNAME=changegroup
  HG_HOOKTYPE=changegroup
  HG_NODE=f9ee2f85a263049e9ae6d37a0e67e96194ffb735
  HG_NODE_LAST=aa35859c02ea8bd48da5da68cd2740ac71afcbaf
  HG_SOURCE=pull
  HG_TXNID=TXN:$ID$
  HG_TXNNAME=pull
  bundle:empty+full.hg
  HG_URL=bundle:empty+full.hg
  
  (run 'hg heads' to see heads, 'hg merge' to merge)

#endif

Cannot produce streaming clone bundles with "hg bundle"

  $ hg -R test bundle -t packed1 packed.hg
  abort: packed bundles cannot be produced by "hg bundle"
  (use 'hg debugcreatestreamclonebundle')
  [10]

packed1 is produced properly


#if reporevlogstore rust

  $ hg -R test debugcreatestreamclonebundle packed.hg
  writing 2665 bytes for 6 files
  bundle requirements: generaldelta, revlog-compression-zstd, revlogv1, sparserevlog

  $ f -B 64 --size --sha1 --hexdump packed.hg
  packed.hg: size=2865, sha1=353d10311f4befa195d9a1ca4b8e26518115c702
  0000: 48 47 53 31 55 4e 00 00 00 00 00 00 00 06 00 00 |HGS1UN..........|
  0010: 00 00 00 00 0a 69 00 3b 67 65 6e 65 72 61 6c 64 |.....i.;generald|
  0020: 65 6c 74 61 2c 72 65 76 6c 6f 67 2d 63 6f 6d 70 |elta,revlog-comp|
  0030: 72 65 73 73 69 6f 6e 2d 7a 73 74 64 2c 72 65 76 |ression-zstd,rev|
  $ hg debugbundle --spec packed.hg
  none-packed1;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog
#endif

#if reporevlogstore no-rust zstd

  $ hg -R test debugcreatestreamclonebundle packed.hg
  writing 2665 bytes for 6 files
  bundle requirements: generaldelta, revlog-compression-zstd, revlogv1, sparserevlog

  $ f -B 64 --size --sha1 --hexdump packed.hg
  packed.hg: size=2865, sha1=353d10311f4befa195d9a1ca4b8e26518115c702
  0000: 48 47 53 31 55 4e 00 00 00 00 00 00 00 06 00 00 |HGS1UN..........|
  0010: 00 00 00 00 0a 69 00 3b 67 65 6e 65 72 61 6c 64 |.....i.;generald|
  0020: 65 6c 74 61 2c 72 65 76 6c 6f 67 2d 63 6f 6d 70 |elta,revlog-comp|
  0030: 72 65 73 73 69 6f 6e 2d 7a 73 74 64 2c 72 65 76 |ression-zstd,rev|
  $ hg debugbundle --spec packed.hg
  none-packed1;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog
#endif

#if reporevlogstore no-rust no-zstd

  $ hg -R test debugcreatestreamclonebundle packed.hg
  writing 2664 bytes for 6 files
  bundle requirements: generaldelta, revlogv1, sparserevlog

  $ f -B 64 --size --sha1 --hexdump packed.hg
  packed.hg: size=2840, sha1=12bf3eee3eb8a04c503ce2d29b48f0135c7edff5
  0000: 48 47 53 31 55 4e 00 00 00 00 00 00 00 06 00 00 |HGS1UN..........|
  0010: 00 00 00 00 0a 68 00 23 67 65 6e 65 72 61 6c 64 |.....h.#generald|
  0020: 65 6c 74 61 2c 72 65 76 6c 6f 67 76 31 2c 73 70 |elta,revlogv1,sp|
  0030: 61 72 73 65 72 65 76 6c 6f 67 00 64 61 74 61 2f |arserevlog.data/|
  $ hg debugbundle --spec packed.hg
  none-packed1;requirements%3Dgeneraldelta%2Crevlogv1%2Csparserevlog
#endif

#if reporevlogstore

generaldelta requirement is not listed in stream clone bundles unless used

  $ hg --config format.usegeneraldelta=false init testnongd
  $ cd testnongd
  $ touch foo
  $ hg -q commit -A -m initial
  $ cd ..

#endif

#if reporevlogstore rust

  $ hg -R testnongd debugcreatestreamclonebundle packednongd.hg
  writing 301 bytes for 3 files
  bundle requirements: revlog-compression-zstd, revlogv1

  $ f -B 64 --size --sha1 --hexdump packednongd.hg
  packednongd.hg: size=407, sha1=0b8714422b785ba8eb98c916b41ffd5fb994c9b5
  0000: 48 47 53 31 55 4e 00 00 00 00 00 00 00 03 00 00 |HGS1UN..........|
  0010: 00 00 00 00 01 2d 00 21 72 65 76 6c 6f 67 2d 63 |.....-.!revlog-c|
  0020: 6f 6d 70 72 65 73 73 69 6f 6e 2d 7a 73 74 64 2c |ompression-zstd,|
  0030: 72 65 76 6c 6f 67 76 31 00 64 61 74 61 2f 66 6f |revlogv1.data/fo|

  $ hg debugbundle --spec packednongd.hg
  none-packed1;requirements%3Drevlog-compression-zstd%2Crevlogv1

#endif

#if reporevlogstore no-rust zstd

  $ hg -R testnongd debugcreatestreamclonebundle packednongd.hg
  writing 301 bytes for 3 files
  bundle requirements: revlog-compression-zstd, revlogv1

  $ f -B 64 --size --sha1 --hexdump packednongd.hg
  packednongd.hg: size=407, sha1=0b8714422b785ba8eb98c916b41ffd5fb994c9b5
  0000: 48 47 53 31 55 4e 00 00 00 00 00 00 00 03 00 00 |HGS1UN..........|
  0010: 00 00 00 00 01 2d 00 21 72 65 76 6c 6f 67 2d 63 |.....-.!revlog-c|
  0020: 6f 6d 70 72 65 73 73 69 6f 6e 2d 7a 73 74 64 2c |ompression-zstd,|
  0030: 72 65 76 6c 6f 67 76 31 00 64 61 74 61 2f 66 6f |revlogv1.data/fo|

  $ hg debugbundle --spec packednongd.hg
  none-packed1;requirements%3Drevlog-compression-zstd%2Crevlogv1


#endif

#if reporevlogstore no-rust no-zstd

  $ hg -R testnongd debugcreatestreamclonebundle packednongd.hg
  writing 301 bytes for 3 files
  bundle requirements: revlogv1

  $ f -B 64 --size --sha1 --hexdump packednongd.hg
  packednongd.hg: size=383, sha1=1d9c230238edd5d38907100b729ba72b1831fe6f
  0000: 48 47 53 31 55 4e 00 00 00 00 00 00 00 03 00 00 |HGS1UN..........|
  0010: 00 00 00 00 01 2d 00 09 72 65 76 6c 6f 67 76 31 |.....-..revlogv1|
  0020: 00 64 61 74 61 2f 66 6f 6f 2e 69 00 36 34 0a 00 |.data/foo.i.64..|
  0030: 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 |................|

  $ hg debugbundle --spec packednongd.hg
  none-packed1;requirements%3Drevlogv1


#endif

#if reporevlogstore

Warning emitted when packed bundles contain secret changesets

  $ hg init testsecret
  $ cd testsecret
  $ touch foo
  $ hg -q commit -A -m initial
  $ hg phase --force --secret -r .
  $ cd ..

#endif

#if reporevlogstore rust

  $ hg -R testsecret debugcreatestreamclonebundle packedsecret.hg
  (warning: stream clone bundle will contain secret revisions)
  writing 301 bytes for 3 files
  bundle requirements: generaldelta, revlog-compression-zstd, revlogv1, sparserevlog

#endif

#if reporevlogstore no-rust zstd

  $ hg -R testsecret debugcreatestreamclonebundle packedsecret.hg
  (warning: stream clone bundle will contain secret revisions)
  writing 301 bytes for 3 files
  bundle requirements: generaldelta, revlog-compression-zstd, revlogv1, sparserevlog

#endif

#if reporevlogstore no-rust no-zstd

  $ hg -R testsecret debugcreatestreamclonebundle packedsecret.hg
  (warning: stream clone bundle will contain secret revisions)
  writing 301 bytes for 3 files
  bundle requirements: generaldelta, revlogv1, sparserevlog

#endif

#if reporevlogstore

Unpacking packed1 bundles with "hg unbundle" isn't allowed

  $ hg init packed
  $ hg -R packed unbundle packed.hg
  abort: packed bundles cannot be applied with "hg unbundle"
  (use "hg debugapplystreamclonebundle")
  [10]

packed1 can be consumed from debug command

(this also confirms that streamclone-ed changes are visible via
@filecache properties to in-process procedures before closing
transaction)

  $ cat > $TESTTMP/showtip.py <<EOF
  > from __future__ import absolute_import
  > 
  > def showtip(ui, repo, hooktype, **kwargs):
  >     ui.warn(b'%s: %s\n' % (hooktype, repo[b'tip'].hex()[:12]))
  > 
  > def reposetup(ui, repo):
  >     # this confirms (and ensures) that (empty) 00changelog.i
  >     # before streamclone is already cached as repo.changelog
  >     ui.setconfig(b'hooks', b'pretxnopen.showtip', showtip)
  > 
  >     # this confirms that streamclone-ed changes are visible to
  >     # in-process procedures before closing transaction
  >     ui.setconfig(b'hooks', b'pretxnclose.showtip', showtip)
  > 
  >     # this confirms that streamclone-ed changes are still visible
  >     # after closing transaction
  >     ui.setconfig(b'hooks', b'txnclose.showtip', showtip)
  > EOF
  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > showtip = $TESTTMP/showtip.py
  > EOF

  $ hg -R packed debugapplystreamclonebundle packed.hg
  6 files to transfer, 2.60 KB of data
  pretxnopen: 000000000000
  pretxnclose: aa35859c02ea
  transferred 2.60 KB in * seconds (* */sec) (glob)
  txnclose: aa35859c02ea

(for safety, confirm visibility of streamclone-ed changes by another
process, too)

  $ hg -R packed tip -T "{node|short}\n"
  aa35859c02ea

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > showtip = !
  > EOF

Does not work on non-empty repo

  $ hg -R packed debugapplystreamclonebundle packed.hg
  abort: cannot apply stream clone bundle on non-empty repo
  [255]

#endif

Create partial clones

  $ rm -r empty
  $ hg init empty
  $ hg clone -r 3 test partial
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 1 files
  new changesets f9ee2f85a263:eebf5a27f8ca
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg clone partial partial2
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd partial

#if repobundlerepo

Log -R full.hg in partial

  $ hg -R bundle://../full.hg log -T phases
  changeset:   8:aa35859c02ea
  tag:         tip
  phase:       draft
  parent:      3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3m
  
  changeset:   7:a6a34bfa0076
  phase:       draft
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3m
  
  changeset:   6:7373c1169842
  phase:       draft
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3
  
  changeset:   5:1bb50a9436a7
  phase:       draft
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.2
  
  changeset:   4:095197eb4973
  phase:       draft
  parent:      0:f9ee2f85a263
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.1
  
  changeset:   3:eebf5a27f8ca
  phase:       public
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3
  
  changeset:   2:e38ba6f5b7e0
  phase:       public
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.2
  
  changeset:   1:34c2bf6b0626
  phase:       public
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.1
  
  changeset:   0:f9ee2f85a263
  phase:       public
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.0
  

Incoming full.hg in partial

  $ hg incoming bundle://../full.hg
  comparing with bundle:../full.hg
  searching for changes
  changeset:   4:095197eb4973
  parent:      0:f9ee2f85a263
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.1
  
  changeset:   5:1bb50a9436a7
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.2
  
  changeset:   6:7373c1169842
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3
  
  changeset:   7:a6a34bfa0076
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3m
  
  changeset:   8:aa35859c02ea
  tag:         tip
  parent:      3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3m
  

Outgoing -R full.hg vs partial2 in partial

  $ hg -R bundle://../full.hg outgoing ../partial2
  comparing with ../partial2
  searching for changes
  changeset:   4:095197eb4973
  parent:      0:f9ee2f85a263
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.1
  
  changeset:   5:1bb50a9436a7
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.2
  
  changeset:   6:7373c1169842
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3
  
  changeset:   7:a6a34bfa0076
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3m
  
  changeset:   8:aa35859c02ea
  tag:         tip
  parent:      3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3m
  

Outgoing -R does-not-exist.hg vs partial2 in partial

  $ hg -R bundle://../does-not-exist.hg outgoing ../partial2
  abort: *../does-not-exist.hg* (glob)
  [255]

#endif

  $ cd ..

hide outer repo
  $ hg init

Direct clone from bundle (all-history)

#if repobundlerepo

  $ hg clone full.hg full-clone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets f9ee2f85a263:aa35859c02ea (9 drafts)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R full-clone heads
  changeset:   8:aa35859c02ea
  tag:         tip
  parent:      3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3m
  
  changeset:   7:a6a34bfa0076
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1.3m
  
  $ rm -r full-clone

When cloning from a non-copiable repository into '', do not
recurse infinitely (issue2528)

  $ hg clone full.hg ''
  abort: empty destination path is not valid
  [10]

test for https://bz.mercurial-scm.org/216

Unbundle incremental bundles into fresh empty in one go

  $ rm -r empty
  $ hg init empty
  $ hg -R test bundle --base null -r 0 ../0.hg
  1 changesets found
  $ hg -R test bundle --base 0    -r 1 ../1.hg
  1 changesets found
  $ hg -R empty unbundle -u ../0.hg ../1.hg
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets f9ee2f85a263 (1 drafts)
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 34c2bf6b0626 (1 drafts)
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

View full contents of the bundle
  $ hg -R test bundle --base null -r 3  ../partial.hg
  4 changesets found
  $ cd test
  $ hg -R ../../partial.hg log -r "bundle()"
  changeset:   0:f9ee2f85a263
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.0
  
  changeset:   1:34c2bf6b0626
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.1
  
  changeset:   2:e38ba6f5b7e0
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.2
  
  changeset:   3:eebf5a27f8ca
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0.3
  
  $ cd ..

#endif

test for 540d1059c802

  $ hg init orig
  $ cd orig
  $ echo foo > foo
  $ hg add foo
  $ hg ci -m 'add foo'

  $ hg clone . ../copy
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg tag foo

  $ cd ../copy
  $ echo >> foo
  $ hg ci -m 'change foo'
  $ hg bundle ../bundle.hg ../orig
  searching for changes
  1 changesets found

  $ cd ..

#if repobundlerepo
  $ cd orig
  $ hg incoming ../bundle.hg
  comparing with ../bundle.hg
  searching for changes
  changeset:   2:ed1b79f46b9a
  tag:         tip
  parent:      0:bbd179dfa0a7
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     change foo
  
  $ cd ..

test bundle with # in the filename (issue2154):

  $ cp bundle.hg 'test#bundle.hg'
  $ cd orig
  $ hg incoming '../test#bundle.hg'
  comparing with ../test
  abort: unknown revision 'bundle.hg'
  [10]

note that percent encoding is not handled:

  $ hg incoming ../test%23bundle.hg
  abort: repository ../test%23bundle.hg not found
  [255]
  $ cd ..

#endif

test to bundle revisions on the newly created branch (issue3828):

  $ hg -q clone -U test test-clone
  $ cd test

  $ hg -q branch foo
  $ hg commit -m "create foo branch"
  $ hg -q outgoing ../test-clone
  9:b4f5acb1ee27
  $ hg -q bundle --branch foo foo.hg ../test-clone
#if repobundlerepo
  $ hg -R foo.hg -q log -r "bundle()"
  9:b4f5acb1ee27
#endif

  $ cd ..

test for https://bz.mercurial-scm.org/1144

test that verify bundle does not traceback

partial history bundle, fails w/ unknown parent

  $ hg -R bundle.hg verify
  abort: 00changelog@bbd179dfa0a71671c253b3ae0aa1513b60d199fa: unknown parent
  [50]

full history bundle, refuses to verify non-local repo

#if repobundlerepo
  $ hg -R all.hg verify
  abort: cannot verify bundle or remote repos
  [255]
#endif

but, regular verify must continue to work

  $ hg -R orig verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 2 files

#if repobundlerepo
diff against bundle

  $ hg init b
  $ cd b
  $ hg -R ../all.hg diff -r tip
  diff -r aa35859c02ea anotherfile
  --- a/anotherfile	Thu Jan 01 00:00:00 1970 +0000
  +++ /dev/null	Thu Jan 01 00:00:00 1970 +0000
  @@ -1,4 +0,0 @@
  -0
  -1
  -2
  -3
  $ cd ..
#endif

bundle single branch

  $ hg init branchy
  $ cd branchy
  $ echo a >a
  $ echo x >x
  $ hg ci -Ama
  adding a
  adding x
  $ echo c >c
  $ echo xx >x
  $ hg ci -Amc
  adding c
  $ echo c1 >c1
  $ hg ci -Amc1
  adding c1
  $ hg up 0
  1 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo b >b
  $ hg ci -Amb
  adding b
  created new head
  $ echo b1 >b1
  $ echo xx >x
  $ hg ci -Amb1
  adding b1
  $ hg clone -q -r2 . part

== bundling via incoming

  $ hg in -R part --bundle incoming.hg --template "{node}\n" .
  comparing with .
  searching for changes
  1a38c1b849e8b70c756d2d80b0b9a3ac0b7ea11a
  057f4db07f61970e1c11e83be79e9d08adc4dc31

== bundling

  $ hg bundle bundle.hg part --debug --config progress.debug=true
  query 1; heads
  searching for changes
  all remote heads known locally
  2 changesets found
  list of changesets:
  1a38c1b849e8b70c756d2d80b0b9a3ac0b7ea11a
  057f4db07f61970e1c11e83be79e9d08adc4dc31
  bundle2-output-bundle: "HG20", (1 params) 2 parts total
  bundle2-output-part: "changegroup" (params: 1 mandatory 1 advisory) streamed payload
  changesets: 1/2 chunks (50.00%)
  changesets: 2/2 chunks (100.00%)
  manifests: 1/2 chunks (50.00%)
  manifests: 2/2 chunks (100.00%)
  files: b 1/3 files (33.33%)
  files: b1 2/3 files (66.67%)
  files: x 3/3 files (100.00%)
  bundle2-output-part: "cache:rev-branch-cache" (advisory) streamed payload

#if repobundlerepo
== Test for issue3441

  $ hg clone -q -r0 . part2
  $ hg -q -R part2 pull bundle.hg
  $ hg -R part2 verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 5 changes to 4 files
#endif

== Test bundling no commits

  $ hg bundle -r 'public()' no-output.hg
  abort: no commits to bundle
  [10]

  $ cd ..

When user merges to the revision existing only in the bundle,
it should show warning that second parent of the working
directory does not exist

  $ hg init update2bundled
  $ cd update2bundled
  $ cat <<EOF >> .hg/hgrc
  > [extensions]
  > strip =
  > EOF
  $ echo "aaa" >> a
  $ hg commit -A -m 0
  adding a
  $ echo "bbb" >> b
  $ hg commit -A -m 1
  adding b
  $ echo "ccc" >> c
  $ hg commit -A -m 2
  adding c
  $ hg update -r 1
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo "ddd" >> d
  $ hg commit -A -m 3
  adding d
  created new head
  $ hg update -r 2
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg log -G
  o  changeset:   3:8bd3e1f196af
  |  tag:         tip
  |  parent:      1:a01eca7af26d
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     3
  |
  | @  changeset:   2:4652c276ac4f
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     2
  |
  o  changeset:   1:a01eca7af26d
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     1
  |
  o  changeset:   0:4fe08cd4693e
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     0
  

#if repobundlerepo
  $ hg bundle --base 1 -r 3 ../update2bundled.hg
  1 changesets found
  $ hg strip -r 3
  saved backup bundle to $TESTTMP/update2bundled/.hg/strip-backup/8bd3e1f196af-017e56d8-backup.hg
  $ hg merge -R ../update2bundled.hg -r 3
  setting parent to node 8bd3e1f196af289b2b121be08031e76d7ae92098 that only exists in the bundle
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)

When user updates to the revision existing only in the bundle,
it should show warning

  $ hg update -R ../update2bundled.hg --clean -r 3
  setting parent to node 8bd3e1f196af289b2b121be08031e76d7ae92098 that only exists in the bundle
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved

When user updates to the revision existing in the local repository
the warning shouldn't be emitted

  $ hg update -R ../update2bundled.hg -r 0
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
#endif

Test the option that create slim bundle

  $ hg bundle -a --config devel.bundle.delta=p1 ./slim.hg
  3 changesets found

Test the option that create and no-delta's bundle
  $ hg bundle -a --config devel.bundle.delta=full ./full.hg
  3 changesets found
