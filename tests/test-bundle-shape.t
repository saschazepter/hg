#require rust

TODO test streamv3 once that gains shapes support

Setup
=====

  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > clonebundles=
  > narrow=
  > 
  > [experimental]
  > server.stream-narrow-clones=yes
  > EOF

Generate a source repo with a bunch of files and folders, some with a few edits
  $ hg init source
  $ cd source
  $ mkdir -p dir1/excluded/nested dir2 excluded
  $ touch \
  >  a \
  >  b \
  >  dir1/a \
  >  dir1/b \
  >  dir1/excluded/a \
  >  dir1/excluded/b \
  >  dir1/excluded/nested/a \
  >  dir1/excluded/nested/b \
  >  dir2/a \
  >  dir2/b \
  >  excluded/a \
  >  excluded/b
  $ hg commit -Aqm0
  $ echo "foo"    > a
  $ echo "foo"    > dir1/a
  $ echo "foobar" > dir1/b
  $ echo "foobar" > dir2/b
  $ echo "foo"    > dir2/a
  $ echo "foo"    > dir1/excluded/a
  $ echo "foo"    > excluded/a
  $ echo "foobar" > excluded/b
  $ hg commit -qm1
  $ echo "bar"    > dir1/excluded/a
  $ hg commit -qm2
  $ cd ..

Test errors
===========

Make sure we complain if not using Rust when generating a shape bundle
  $ HGMODULEPOLICY=c hg bundle -R source -a -t"none-v2;stream=v2;shape=foo" --config storage.all-slow-path=allow outfile.hg
  abort: shape bundlespec option is only available with the Rust extensions
  [10]

Make sure we complain if not using stream bundles when generating a shape bundle
  $ hg bundle -R source -a -t"none-v2;shape=foo" outfile.hg
  abort: shape bundlespec option is only implemented for stream bundles
  [10]

Test without any shaping (sanity check)
  $ hg bundle -R source -a -t"none-v2;stream=v2" outfile-no-shape.hg

  $ hg debugbundle outfile-no-shape.hg
  Stream params: {}
  stream2 -- {bytecount: *, filecount: 20, requirements: *} (mandatory: True) (glob)

Create shapes config

  $ cat << EOF >> $TESTTMP/source-shapes
  > version = 0
  > [[shards]]
  > name = "default"
  > requires = ["base"]
  > shape = true
  > [[shards]]
  > name = "excluded1"
  > paths = ["excluded"]
  > [[shards]]
  > name = "excluded2"
  > paths = ["dir1/excluded"]
  > [[shards]]
  > name = "foobar"
  > paths = ["dir2"]
  > shape = true
  > [[shards]]
  > name = "foobaz"
  > shape = true
  > requires = ["excluded1", "foobar"]
  > EOF
  $ hg -R source admin::narrow-server --shape-update -f $TESTTMP/source-shapes

Test with an unknown shape
  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=foo" outfile-shaped.hg
  abort: unknown shape: 'foo'
  [10]

Test with the default shape
  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=default" outfile-shape-default.hg

  $ hg debugbundle outfile-shape-default.hg | grep -E 'store-fingerprint: [0-9a-f]{64}'
  stream2 -- {bytecount: *, filecount: 12, requirements: *, store-fingerprint: 961e3d6d14621106b59a576aa6d8907d3f4734ea3f04c01d0bdff031b5572b19} (mandatory: True) (glob)

Add a full non-fingerprinted streaming clone for reference and fallback testing
  $ hg -R source bundle -a --type="none-v2;stream=v2" outfile-shape-full.hg

  $ hg debugbundle outfile-shape-full.hg
  Stream params: {}
  stream2 -- {bytecount: *, filecount: 20, requirements: *} (mandatory: True) (glob)


Test with a known shape
  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=foobar" outfile-shape-foobar.hg

  $ hg debugbundle outfile-shape-foobar.hg | grep -E 'store-fingerprint: [0-9a-f]{64}'
  stream2 -- {bytecount: *, filecount: 10, requirements: *, store-fingerprint: feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726} (mandatory: True) (glob)

  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=foobaz" outfile-shape-foobaz.hg

  $ hg debugbundle outfile-shape-foobaz.hg | grep -E 'store-fingerprint: [0-9a-f]{64}'
  stream2 -- {bytecount: *, filecount: 12, requirements: *, store-fingerprint: bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e} (mandatory: True) (glob)

Test cloning
============

Start hg server
---------------

  $ cd source
  $ hg serve -d -p $HGPORT --pid-file hg.pid --errorlog error.log --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ cd ..

Prepare inline bundles
----------------------

  $ bundlespec="$(hg debugbundle --spec outfile-shape-foobar.hg)"
  $ echo $bundlespec
  none-v2;stream=v2;requirements*;store-fingerprint=feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726 (glob)
  $ bundlespec2="$(hg debugbundle --spec outfile-shape-foobaz.hg)"
  $ echo $bundlespec2
  none-v2;stream=v2;requirements*;store-fingerprint=bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e (glob)

  $ bundlespecfull="$(hg debugbundle --spec outfile-shape-full.hg)"
  $ echo $bundlespecfull
  none-v2;stream=v2;requirements%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog

  $ mkdir source/.hg/bundle-cache
  $ mv outfile-shape-*.hg source/.hg/bundle-cache/

  $ cat > source/.hg/clonebundles.manifest << EOF
  > peer-bundle-cache://outfile-shape-foobar.hg BUNDLESPEC=$bundlespec
  > peer-bundle-cache://outfile-shape-foobaz.hg BUNDLESPEC=$bundlespec2
  > EOF

Check the resulting manifest
----------------------------

Define the special set of files included in all shapes.
  $ hgfiles="--include=.hgignore --include=.hgtags --include=.hgsub --include=.hgsubstate"


The raw manifest looks OK
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --raw
  peer-bundle-cache://outfile-shape-foobar.hg BUNDLESPEC=none-v2;stream=v2;requirements*;store-fingerprint=feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726 (glob)
  peer-bundle-cache://outfile-shape-foobaz.hg BUNDLESPEC=none-v2;stream=v2;requirements*;store-fingerprint=bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e (glob)

Passing in no includes or excludes shows that all entries are filtered out due to their fingerprints
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --debug | grep 'store-shape'
  filtering peer-bundle-cache://outfile-shape-foobar.hg because it uses a store-shape
  filtering peer-bundle-cache://outfile-shape-foobaz.hg because it uses a store-shape

Passing a pattern that matches nothing filters all entries
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=no_match

Passing a matching pattern works
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=dir2 $hgfiles
    URL: peer-bundle-cache://outfile-shape-foobar.hg
      BUNDLESPEC: none-v2;stream=v2;requirements=*;store-fingerprint=feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726 (glob)
      COMPRESSION: none
      VERSION: v2
      STORE-FINGERPRINT: feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726

Non-streaming, non-narrow cloning
---------------------------------

Passing no includes should fall back to regular clone

  $ hg clone ssh://user@dummy/source plain-clone 2>&1 --narrow | grep "falling back"
  no compatible clone bundles available on server; falling back to regular clone
  $ rm -rf plain-clone

Test a pure Python client
  $ HGMODULEPOLICY=py hg clone ssh://user@dummy/source --narrow plain-clone 2>&1 | grep "falling back"
  no compatible clone bundles available on server; falling back to regular clone

  $ cat source/error.log
  $ cat source/access.log


Non-narrow streaming cloning
----------------------------

Passing no includes should fall back to full (non-fingerprinted) streaming clone if available

  $ echo "peer-bundle-cache://outfile-shape-full.hg BUNDLESPEC=$bundlespecfull" >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source full-clone | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-full.hg

Test a pure Python client
  $ rm -rf full-clone
  $ HGMODULEPOLICY=py hg clone ssh://user@dummy/source --narrow full-clone | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-full.hg


  $ cat source/error.log
  $ cat source/access.log

Narrow + stream cloning
-----------------------

The right fingerprint should be derived from the narrow patterns, selecting
the correct narrow stream clone bundle

Test that if no fingerprints match, we don't clone anything

  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=notexist

  $ hg clone ssh://user@dummy/source clone-shaped --narrow --include=notexist 2>&1 | grep "falling back"
  no compatible clone bundles available on server; falling back to regular clone
  $ rm -rf clone-shaped

Test matching fingerprints

First with a Python client
  $ HGMODULEPOLICY=py hg clone ssh://user@dummy/source clone-shaped --narrow $hgfiles --include=dir2 | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-foobar.hg
  $ hg admin::narrow-client -R clone-shaped --store-fingerprint
  feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726
  $ rm -rf clone-shaped

Then with the Rust client

  $ hg clone ssh://user@dummy/source clone-shaped --narrow $hgfiles --include=dir2 | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-foobar.hg
  $ cd clone-shaped
  $ hg debug-revlog-stats --filelogs -T'{revlog_target}\n'
  dir2/a
  dir2/b

We make sure that the client has the same fingerprint than the streamclone

  $ hg admin::narrow-client --store-fingerprint
  feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726

We make sure that the client has the expected narrowspec

  $ hg tracked
  I path:.hgignore
  I path:.hgsub
  I path:.hgsubstate
  I path:.hgtags
  I path:dir2

Accessing a file outside of the shape is not possible

  $ hg cat a
  [1]
  $ hg cat excluded/a
  [1]

The rest works correctly

  $ hg cat dir2/a
  foo
  $ hg cat dir2/b
  foobar
  $ cd ..

Testing another shape
---------------------

First with a pure Python client

  $ HGMODULEPOLICY=py hg clone ssh://user@dummy/source clone-shaped2 --narrow $hgfiles --include=dir2 --include=excluded | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-foobaz.hg
  $ hg -R clone-shaped2 admin::narrow-client --store-fingerprint
  bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e
  $ rm -rf clone-shaped2

Then with the Rust client

  $ hg clone ssh://user@dummy/source clone-shaped2 --narrow --include=dir2 $hgfiles --include=excluded | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-foobaz.hg
  $ cd clone-shaped2
  $ hg debug-revlog-stats --filelogs -T'{revlog_target}\n'
  dir2/a
  dir2/b
  excluded/a
  excluded/b

The client has the same fingerprint than the streamclone

  $ hg admin::narrow-client --store-fingerprint
  bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e

The client has the expected narrowspec

  $ hg tracked
  I path:.hgignore
  I path:.hgsub
  I path:.hgsubstate
  I path:.hgtags
  I path:dir2
  I path:excluded

Accessing a file outside of the shape is not possible

  $ hg cat a
  [1]
  $ hg cat excluded/a
  foo

The rest works correctly
  $ hg cat excluded/a
  foo
  $ hg cat dir2/a
  foo
  $ hg cat dir2/b
  foobar

Testing that cloning with --store-shape works the same
------------------------------------------------

Start a narrow server that doesn't understand shapes
  $ killdaemons.py

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > advertise-shapes=no
  > EOF

  $ hg serve -d -p $HGPORT --pid-file hg.pid
  $ cat hg.pid > $DAEMON_PIDS
  $ cd ..
  $ hg clone ssh://user@dummy/source clone-shaped3 --store-shape foobaz
  abort: cannot use store shapes; remote repository does not support the 'exp-shape-1' capability
  [255]
  $ killdaemons.py

Restore the capability

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > advertise-shapes=yes
  > EOF

Restart the normal server
  $ hg serve -R source -d -p $HGPORT --pid-file hg.pid --errorlog error.log --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ hg clone ssh://user@dummy/source clone-shaped3 --store-shape unknown-shape
  abort: shape not found on remote: 'unknown-shape'
  [10]

  $ hg clone ssh://user@dummy/source clone-shaped3 --store-shape foobaz | grep "bundle from"
  applying clone bundle from peer-bundle-cache://outfile-shape-foobaz.hg
  $ cd clone-shaped3
  $ hg debug-revlog-stats --filelogs -T'{revlog_target}\n'
  dir2/a
  dir2/b
  excluded/a
  excluded/b

The client has the same fingerprint than the streamclone

  $ hg admin::narrow-client --store-fingerprint
  bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e

The client has the expected narrowspec

  $ hg tracked
  I path:.hgignore
  I path:.hgsub
  I path:.hgsubstate
  I path:.hgtags
  I path:dir2
  I path:excluded
  X path:.

Accessing a file outside of the shape is not possible

  $ hg cat a
  [1]
  $ hg cat excluded/a
  foo

The rest works correctly
  $ hg cat excluded/a
  foo
  $ hg cat dir2/a
  foo
  $ hg cat dir2/b
  foobar
  $ cd ..


Test sharded streamclones
=========================

Bundle generation
-----------------

  $ rm source/.hg/bundle-cache/*
  $ shard_fingerprint_hg_files=f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd
  $ shard_fingerprint_base=f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b
  $ shard_fingerprint_excluded1=ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834
  $ shard_fingerprint_excluded2=905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9
  $ shard_fingerprint_foobar=bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb

  $ hg -R source debug::sharded-stream-bundles
  Generating sharded bundles
  Generated 5 streaming bundles
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg

  $ find source/.hg/bundle-cache -type f | sort | xargs -L1 hg debugbundle | grep -E 'shard-id: [0-9a-f]{64}'
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 4, requirements: *, shard-id: 905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 2, requirements: *, shard-id: bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 2, requirements: *, shard-id: ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 4, requirements: *, shard-id: f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bundle-group-top-level: 1, bytecount: *, filecount: 8, requirements: *, shard-id: f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd} (mandatory: True) (glob)

  $ rm $TESTTMP/source/.hg/bundle-cache/*

Test json output

  $ hg -R source debug::sharded-stream-bundles -Tjson
  [
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg"
   }
  ]

Bundle application
------------------

Try a full stream clone
.......................

  $ cd $TESTTMP
  $ urlprefix="peer-bundle-cache://hg-sharded-05a21d65"

  $ echo "$urlprefix-$shard_fingerprint_hg_files.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_hg_files;bundle-group-id=05a21d65;bundle-group-top-level=1" > source/.hg/clonebundles.manifest

  $ echo "$urlprefix-$shard_fingerprint_base.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_base;bundle-group-id=05a21d65" >> source/.hg/clonebundles.manifest

  $ echo "$urlprefix-$shard_fingerprint_excluded1.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_excluded1;bundle-group-id=05a21d65" >> source/.hg/clonebundles.manifest

  $ echo "$urlprefix-$shard_fingerprint_excluded2.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_excluded2;bundle-group-id=05a21d65" >> source/.hg/clonebundles.manifest

  $ echo "$urlprefix-$shard_fingerprint_foobar.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_foobar;bundle-group-id=05a21d65" >> source/.hg/clonebundles.manifest

  $ hg clone ssh://user@dummy/source target --store-shape full --stream | grep 'applying'
  applying 5 clone bundles
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  finished applying clone bundle [1/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg
  finished applying clone bundle [2/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg
  finished applying clone bundle [3/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg
  finished applying clone bundle [4/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg
  finished applying clone bundle [5/5]
  finished applying 5 clone bundles
  $ hg -R source admin::narrow-server --shape-fingerprint | grep " full"
  00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea full

  $ hg -R target admin::narrow-client --store-fingerprint
  00dfe7451b0897c077166f360d431a57ea09a5279863b00cfe9d60cefa657dea
  $ hg -R target verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 3 changesets with 21 changes to 12 files

Try a partial clone of a single user-defined shard
..................................................

  $ hg clone ssh://user@dummy/source partial-foobar --noupdate --store-shape foobar --stream --debug | grep "applying"
  applying 2 clone bundles
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  applying stream bundle
  finished applying clone bundle [1/2]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg
  applying stream bundle
  finished applying clone bundle [2/2]
  finished applying 2 clone bundles

  $ hg -R partial-foobar admin::narrow-client --store-fingerprint
  feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726

The log is consistent
  $ cd partial-foobar
  $ hg log -p
  changeset:   2:d1d9cd57ca26
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     2
  
  
  changeset:   1:f34bd5434dcf
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  
  diff -r c0ebb2d98ed6 -r f34bd5434dcf dir2/a
  --- a/dir2/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/dir2/a	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foo
  diff -r c0ebb2d98ed6 -r f34bd5434dcf dir2/b
  --- a/dir2/b	Thu Jan 01 00:00:00 1970 +0000
  +++ b/dir2/b	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foobar
  
  changeset:   0:c0ebb2d98ed6
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0
  
  
Update works

  $ hg up 2
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg files
  dir2/a
  dir2/b

Verify is happy
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 3 changesets with 4 changes to 2 files
  $ cd ..

Try a partial clone of a user-defined shard with dependencies
.............................................................

  $ hg clone ssh://user@dummy/source partial-foobaz --noupdate --store-shape foobaz --stream --debug | grep "applying"
  applying 3 clone bundles
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  applying stream bundle
  finished applying clone bundle [1/3]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg
  applying stream bundle
  finished applying clone bundle [2/3]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg
  applying stream bundle
  finished applying clone bundle [3/3]
  finished applying 3 clone bundles

  $ hg -R partial-foobaz admin::narrow-client --store-fingerprint
  bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e

The log is consistent
  $ cd partial-foobaz
  $ hg log -p
  changeset:   2:d1d9cd57ca26
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     2
  
  
  changeset:   1:f34bd5434dcf
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     1
  
  diff -r c0ebb2d98ed6 -r f34bd5434dcf dir2/a
  --- a/dir2/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/dir2/a	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foo
  diff -r c0ebb2d98ed6 -r f34bd5434dcf dir2/b
  --- a/dir2/b	Thu Jan 01 00:00:00 1970 +0000
  +++ b/dir2/b	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foobar
  diff -r c0ebb2d98ed6 -r f34bd5434dcf excluded/a
  --- a/excluded/a	Thu Jan 01 00:00:00 1970 +0000
  +++ b/excluded/a	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foo
  diff -r c0ebb2d98ed6 -r f34bd5434dcf excluded/b
  --- a/excluded/b	Thu Jan 01 00:00:00 1970 +0000
  +++ b/excluded/b	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foobar
  
  changeset:   0:c0ebb2d98ed6
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     0
  
  
Update works

  $ hg up 2
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved

Verify is happy
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 3 changesets with 8 changes to 4 files

  $ cd ..


Test different manifest problems
--------------------------------

  $ cp source/.hg/clonebundles.manifest source/.hg/clonebundles.old

Missing a bundle for a shape
............................

  $ grep -v $shard_fingerprint_base source/.hg/clonebundles.old > source/.hg/clonebundles.manifest

Affects a shape that needs it

  $ hg clone ssh://user@dummy/source unsuccessful-full --noupdate --store-shape full --stream --debug | grep "shard"
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  filtering peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg because bundle group 05a21d65 is missing some required shards
  $ rm unsuccessful-full -rf

But not one that doesn't need this missing shard

  $ hg clone ssh://user@dummy/source successful-foobaz --noupdate --store-shape foobaz --stream --debug | grep "finished applying"
  finished applying clone bundle [1/3]
  finished applying clone bundle [2/3]
  finished applying clone bundle [3/3]
  finished applying 3 clone bundles

Bundle group id mismatches
..........................

One shard with the wrong bundle group id should disqualify the group from matching

  $ sed '1 s/bundle-group-id=05a21d65/bundle-group-id=badbadbad/' source/.hg/clonebundles.old > source/.hg/clonebundles.manifest

  $ hg clone ssh://user@dummy/source unsuccessful-full --noupdate --store-shape full --stream --debug | grep "shard"
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  filtering peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg because bundle group badbadbad is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg because bundle group 05a21d65 is missing some required shards
  $ rm unsuccessful-full -rf

Two generations of complete sets is not an issue, we should pick the first one

  $ hg -R source debug::sharded-stream-bundles >/dev/null

  $ sed 's/05a21d65/43c37dde/g' source/.hg/clonebundles.old > source/.hg/clonebundles.manifest
  $ cat source/.hg/clonebundles.old >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source successful-full --noupdate --store-shape full --stream --debug | grep "clone bundle from"
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg
  $ rm successful-full -rf

Two incomplete generations are not considered a full match

  $ cat > source/.hg/clonebundles.manifest << EOF
  > $urlprefix-43c37dde-$shard_fingerprint_hg_files.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_hg_files;bundle-group-id=43c37dde;bundle-group-top-level=1
  > $urlprefix-43c37dde-$shard_fingerprint_base.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_base;bundle-group-id=43c37dde
  > $urlprefix-05a21d65-$shard_fingerprint_foobar.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_foobar;bundle-group-id=05a21d65
  > $urlprefix-05a21d65-$shard_fingerprint_excluded1.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_excluded1;bundle-group-id=05a21d65
  > $urlprefix-05a21d65-$shard_fingerprint_excluded2.hg BUNDLESPEC=$bundlespecfull;shard-id=$shard_fingerprint_excluded2;bundle-group-id=05a21d65
  > EOF
  $ hg clone ssh://user@dummy/source unsuccessful-full --noupdate --store-shape full --stream --debug | grep "filtering"
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  filtering peer-bundle-cache://hg-sharded-05a21d65-43c37dde-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg because bundle group 43c37dde is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-43c37dde-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg because bundle group 43c37dde is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg because bundle group 05a21d65 is missing some required shards
  $ rm unsuccessful-full -rf

A complete old generation + incomplete new generation must match the old one

  $ sed 's/05a21d65/43c37dde/g' source/.hg/clonebundles.old | head -n 2 > source/.hg/clonebundles.manifest
  $ cat source/.hg/clonebundles.old >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source successful-full --noupdate --store-shape full --stream --debug | grep "clone bundle from"
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg

Apply order
-----------

Top-level bundle listed last in the manifest is still applied first

  $ grep -v top-level source/.hg/clonebundles.old > source/.hg/clonebundles.manifest
  $ grep top-level source/.hg/clonebundles.old >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source reordered-full --noupdate --store-shape full --stream --debug | grep "clone bundle from"
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f9a5433a9be0b9f9d8e531c5a6830e3cd87499248815036fe139b5f441cddfcd.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-f35f89d0a4283ea9aef76ed630345e34a52e7b1ad1dd1336ce114c8eda7eb68b.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-ce1d82aa4fc03d836efe2c255ced2b91762debbc01860ac178992f98d9ee8834.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-905afc01e8a7a31fa7748c515d2dc664ab143b85a2550082a4287e601f12c6a9.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-bd08538c46bf568cd64b94df3285cf179a1bf09e991a7e52872b8d9538487dcb.hg
  $ rm reordered-full -rf
