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
  $ hg -R source admin::narrow-server --shape-update -f $TESTTMP/source-shapes --override-reshape-and-reshard-check

Test with an unknown shape
  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=foo" outfile-shaped.hg
  abort: unknown shape: 'foo'
  [10]

Test with the default shape
  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=default" outfile-shape-default.hg

  $ hg debugbundle outfile-shape-default.hg | grep -E 'store-fingerprint: shape00-[0-9a-f]{64}'
  stream2 -- {bytecount: *, filecount: 12, requirements: *, store-fingerprint: shape00-a3b2e41b54f4a21de99700ae576c0f6b59b493a6f3dead7d8e9a8ef4b0779542} (mandatory: True) (glob)

Add a full non-fingerprinted streaming clone for reference and fallback testing
  $ hg -R source bundle -a --type="none-v2;stream=v2" outfile-shape-full.hg

  $ hg debugbundle outfile-shape-full.hg
  Stream params: {}
  stream2 -- {bytecount: *, filecount: 20, requirements: *} (mandatory: True) (glob)


Test with a known shape
  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=foobar" outfile-shape-foobar.hg

  $ hg debugbundle outfile-shape-foobar.hg | grep -E 'store-fingerprint: shape00-[0-9a-f]{64}'
  stream2 -- {bytecount: *, filecount: 10, requirements: *, store-fingerprint: shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1} (mandatory: True) (glob)

  $ hg -R source bundle -a --type="none-v2;stream=v2;shape=foobaz" outfile-shape-foobaz.hg

  $ hg debugbundle outfile-shape-foobaz.hg | grep -E 'store-fingerprint: shape00-[0-9a-f]{64}'
  stream2 -- {bytecount: *, filecount: 12, requirements: *, store-fingerprint: shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1} (mandatory: True) (glob)

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
  none-v2;STREAM=v2;REQUIREMENTS*;STORE-FINGERPRINT=shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1 (glob)
  $ bundlespec2="$(hg debugbundle --spec outfile-shape-foobaz.hg)"
  $ echo $bundlespec2
  none-v2;STREAM=v2;REQUIREMENTS*;STORE-FINGERPRINT=shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1 (glob)

  $ bundlespecfull="$(hg debugbundle --spec outfile-shape-full.hg)"
  $ echo $bundlespecfull
  none-v2;STREAM=v2;REQUIREMENTS%3Dgeneraldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog

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
  peer-bundle-cache://outfile-shape-foobar.hg BUNDLESPEC=none-v2;STREAM=v2;REQUIREMENTS*;STORE-FINGERPRINT=shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1 (glob)
  peer-bundle-cache://outfile-shape-foobaz.hg BUNDLESPEC=none-v2;STREAM=v2;REQUIREMENTS*;STORE-FINGERPRINT=shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1 (glob)

Passing in no includes or excludes shows that all entries are filtered out due to their fingerprints
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --debug | grep 'store-shape'
  filtering peer-bundle-cache://outfile-shape-foobar.hg because it uses a store-shape
  filtering peer-bundle-cache://outfile-shape-foobaz.hg because it uses a store-shape

Passing a pattern that matches nothing filters all entries
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=no_match

Passing a matching pattern works
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=dir2 $hgfiles
    URL: peer-bundle-cache://outfile-shape-foobar.hg
      BUNDLESPEC: none-v2;STREAM=v2;REQUIREMENTS=*;STORE-FINGERPRINT=shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1 (glob)
      COMPRESSION: none
      VERSION: v2

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
  shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1
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
  shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1

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
  shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1
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
  shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1

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
  shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1

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
  $ shard_fingerprint_hg_files=shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d
  $ shard_fingerprint_base=shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09
  $ shard_fingerprint_excluded1=shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013
  $ shard_fingerprint_excluded2=shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac
  $ shard_fingerprint_foobar=shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95

  $ hg -R source debug::sharded-stream-bundles
  Generating sharded bundles
  Generated 5 streaming bundles
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg
  $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg

  $ find source/.hg/bundle-cache -type f | sort | xargs -L1 hg debugbundle | grep -E 'shard-id: shard00-[0-9a-f]{64}'
  stream2 -- {bundle-group-id: 1335303a, bundle-group-top-level: 1, bytecount: *, filecount: 8, requirements: *, shard-id: shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 4, requirements: *, shard-id: shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 2, requirements: *, shard-id: shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 4, requirements: *, shard-id: shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09} (mandatory: True) (glob)
  stream2 -- {bundle-group-id: 1335303a, bytecount: *, filecount: 2, requirements: *, shard-id: shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013} (mandatory: True) (glob)

Sharded bundles have sharding params in uppercase, indicating they are mandatory

  $ hg debugbundle --spec $TESTTMP/source/.hg/bundle-cache/hg-sharded-1335303a-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  none-v2;STREAM=v2;REQUIREMENTS*;SHARD-ID=shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d;BUNDLE-GROUP-ID=1335303a;BUNDLE-GROUP-TOP-LEVEL=1 (glob)

  $ rm $TESTTMP/source/.hg/bundle-cache/*

Test json output

  $ hg -R source debug::sharded-stream-bundles -Tjson
  [
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg"
   },
   {
    "path": "$TESTTMP/source/.hg/bundle-cache/hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg"
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
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  finished applying clone bundle [1/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg
  finished applying clone bundle [2/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg
  finished applying clone bundle [3/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg
  finished applying clone bundle [4/5]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg
  finished applying clone bundle [5/5]
  finished applying 5 clone bundles
  $ hg -R source admin::narrow-server --shape-fingerprint | grep " full"
  shape00-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545 full

  $ hg -R target admin::narrow-client --store-fingerprint
  shape00-3a324c73577297c4840e43bf3af8e60c6f62a96cbe32a69baf25d8b679018545
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
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  applying stream bundle
  finished applying clone bundle [1/2]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg
  applying stream bundle
  finished applying clone bundle [2/2]
  finished applying 2 clone bundles

  $ hg -R partial-foobar admin::narrow-client --store-fingerprint
  shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1

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
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  applying stream bundle
  finished applying clone bundle [1/3]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg
  applying stream bundle
  finished applying clone bundle [2/3]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg
  applying stream bundle
  finished applying clone bundle [3/3]
  finished applying 3 clone bundles

  $ hg -R partial-foobaz admin::narrow-client --store-fingerprint
  shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1

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
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg because bundle group 05a21d65 is missing some required shards
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
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg because bundle group badbadbad is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg because bundle group 05a21d65 is missing some required shards
  $ rm unsuccessful-full -rf

Two generations of complete sets is not an issue, we should pick the first one

  $ hg -R source debug::sharded-stream-bundles >/dev/null

  $ sed 's/05a21d65/43c37dde/g' source/.hg/clonebundles.old > source/.hg/clonebundles.manifest
  $ cat source/.hg/clonebundles.old >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source successful-full --noupdate --store-shape full --stream --debug | grep "clone bundle from"
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-43c37dde-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg
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
  filtering peer-bundle-cache://hg-sharded-05a21d65-43c37dde-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg because bundle group 43c37dde is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-43c37dde-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg because bundle group 43c37dde is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg because bundle group 05a21d65 is missing some required shards
  filtering peer-bundle-cache://hg-sharded-05a21d65-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg because bundle group 05a21d65 is missing some required shards
  $ rm unsuccessful-full -rf

A complete old generation + incomplete new generation must match the old one

  $ sed 's/05a21d65/43c37dde/g' source/.hg/clonebundles.old | head -n 2 > source/.hg/clonebundles.manifest
  $ cat source/.hg/clonebundles.old >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source successful-full --noupdate --store-shape full --stream --debug | grep "clone bundle from"
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg

Apply order
-----------

Top-level bundle listed last in the manifest is still applied first

  $ grep -v top-level source/.hg/clonebundles.old > source/.hg/clonebundles.manifest
  $ grep top-level source/.hg/clonebundles.old >> source/.hg/clonebundles.manifest
  $ hg clone ssh://user@dummy/source reordered-full --noupdate --store-shape full --stream --debug | grep "clone bundle from"
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-7617c9764651da6165bd219c8281fb0629cf178ef515295f31185da8f091fc09.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-d06fa3771f127f68848e190578a7ab93ac42fbdc6f1ccc16812c139bf8a82013.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-5eb2fc572ad8bc29606cba42d5447bc6f7b9ab3b974d94fb3c20e470eb5ebc95.hg
  $ rm reordered-full -rf

Entry filtering
===============

Manifest contains a full bundle, store-fingerprint bundles, and sharded bundles.

  $ cd $TESTTMP
  $ cat > source/.hg/clonebundles.manifest << EOF
  > peer-bundle-cache://no-shape.hg BUNDLESPEC=$bundlespecfull
  > peer-bundle-cache://shape-dir2.hg BUNDLESPEC=$bundlespec
  > peer-bundle-cache://shape-other.hg BUNDLESPEC=$bundlespec2
  > peer-bundle-cache://shard-top.hg BUNDLESPEC=$bundlespecfull;SHARD-ID=shard00-1111111111111111111111111111111111111111111111111111111111111111;BUNDLE-GROUP-ID=abcd;BUNDLE-GROUP-TOP-LEVEL=1
  > peer-bundle-cache://shard-other.hg BUNDLESPEC=$bundlespecfull;SHARD-ID=shard00-2222222222222222222222222222222222222222222222222222222222222222;BUNDLE-GROUP-ID=abcd
  > EOF

If the client did not request a store shape, filter out all but the full bundle

  $ hg debug::clonebundle-manifest ssh://user@dummy/source --debug | grep -E 'filtering|URL:'
  filtering peer-bundle-cache://shape-dir2.hg because it uses a store-shape
  filtering peer-bundle-cache://shape-other.hg because it uses a store-shape
  filtering peer-bundle-cache://shard-top.hg because it is sharded bundle
  filtering peer-bundle-cache://shard-other.hg because it is sharded bundle
    URL: peer-bundle-cache://no-shape.hg

If the client requests a store shape, filter out all but the bundle with the matching
store-fingerprint

  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=dir2 $hgfiles --debug | grep -E 'filtering|URL:'
  filtering peer-bundle-cache://no-shape.hg because it does not use store-shape
  filtering peer-bundle-cache://shape-other.hg because its store-shape is not the requested one; shape00-793abd70e08b89af39560577483a150958d47ad6daa3db734ea88d527b2729b1 not in (shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1)
  filtering peer-bundle-cache://shard-top.hg because no shards were requested
  filtering peer-bundle-cache://shard-other.hg because no shards were requested
    URL: peer-bundle-cache://shape-dir2.hg

Malformed fingerprints, fingerprints without a version, or fingerprints of the
wrong kind (here a shard fingerprint used as a store fingerprint), are invalid
and dropped when parsing the manifest. The ones with a version other than the
one we requested cannot match.

  $ echo "$bundlespec" > bundlespec.txt
  $ bundlespec_no_version=`sed 's/STORE-FINGERPRINT=shape00-/STORE-FINGERPRINT=shape-/' bundlespec.txt`
  $ bundlespec_other_version=`sed 's/STORE-FINGERPRINT=shape00-/STORE-FINGERPRINT=shape99-/' bundlespec.txt`
  $ bundlespec_malformed=`sed 's/STORE-FINGERPRINT=shape00-/STORE-FINGERPRINT=shape00-zz/' bundlespec.txt`
  $ bundlespec_shard_kind=`sed 's/STORE-FINGERPRINT=shape00-/STORE-FINGERPRINT=shard00-/' bundlespec.txt`
  $ cat > source/.hg/clonebundles.manifest << EOF
  > peer-bundle-cache://shape-dir2-malformed.hg BUNDLESPEC=$bundlespec_malformed
  > peer-bundle-cache://shape-dir2-shard-kind.hg BUNDLESPEC=$bundlespec_shard_kind
  > peer-bundle-cache://shape-dir2-no-version.hg BUNDLESPEC=$bundlespec_no_version
  > peer-bundle-cache://shape-dir2-other-version.hg BUNDLESPEC=$bundlespec_other_version
  > peer-bundle-cache://shape-dir2.hg BUNDLESPEC=$bundlespec
  > EOF

  $ hg debug::clonebundle-manifest ssh://user@dummy/source --include=dir2 $hgfiles --debug | grep -E 'fingerprint|filtering|URL:'
  parameter store-fingerprint should be a shape fingerprint ('shape00-zz662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1')
  parameter store-fingerprint should be a shape fingerprint ('shard00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1')
  parameter store-fingerprint should be a shape fingerprint ('shape-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1')
  filtering peer-bundle-cache://shape-dir2-other-version.hg because its store-shape is not the requested one; shape99-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1 not in (shape00-662b6b7c19654b9c7fc122208b511bc08b9fde0e4b7d1e8743d67e5affcfefb1)
    URL: peer-bundle-cache://shape-dir2.hg

Resharding before new bundles exist
===================================

Previous section added fake entries to test filtering; restore manifest with
real entries matching the server-shapes config

  $ cd $TESTTMP
  $ cp source/.hg/clonebundles.old source/.hg/clonebundles.manifest

Add a shape with just the "excluded2" shard

  $ cat $TESTTMP/source-shapes > $TESTTMP/source-shapes-eshape
  $ cat << EOF >> $TESTTMP/source-shapes-eshape
  > [[shards]]
  > name = "excluded-shape"
  > requires = ["excluded2"]
  > shape = true
  > EOF
  $ hg -R source admin::narrow-server --shape-update -f $TESTTMP/source-shapes-eshape

Cloning "excluded-shape" works

  $ hg clone ssh://user@dummy/source before-reshard --noupdate \
  >   --store-shape excluded-shape --stream | grep 'applying'
  applying 2 clone bundles
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-1967bfea8e642011110b7717d5a68acdca46ee3db5ed65928601023d0c60cb1d.hg
  finished applying clone bundle [1/2]
  applying clone bundle from peer-bundle-cache://hg-sharded-05a21d65-shard00-234f14f2311c98e650fb5da950cd96ee24a8b6ccad12f74950f11fa0da1bdcac.hg
  finished applying clone bundle [2/2]
  finished applying 2 clone bundles
  $ rm -rf before-reshard

Split "excluded2" by adding a shard nested inside it, and add that shard to
"excluded-shape" so it keeps covering the same files and this is a pure resharding

  $ hg -R source admin::narrow-server --shape-fingerprints | grep excluded-shape
  shape00-ad94b60172f9f42f582e5464968508918fbd0a630a2b5c13db1a5508cec181be excluded-shape
  $ cat $TESTTMP/source-shapes > $TESTTMP/source-shapes-split
  $ cat << EOF >> $TESTTMP/source-shapes-split
  > [[shards]]
  > name = "nested"
  > paths = ["dir1/excluded/nested"]
  > [[shards]]
  > name = "excluded-shape"
  > requires = ["excluded2", "nested"]
  > shape = true
  > EOF
  $ hg -R source admin::narrow-server --shape-update -f $TESTTMP/source-shapes-split

The shape still covers the same files, so its fingerprint is unchanged

  $ hg -R source admin::narrow-server --shape-fingerprints | grep excluded-shape
  shape00-ad94b60172f9f42f582e5464968508918fbd0a630a2b5c13db1a5508cec181be excluded-shape

"excluded-shape" can still be cloned because the previous config with the old
shards was saved and its shards set was used

  $ hg clone ssh://user@dummy/source after-reshard --noupdate --store-shape excluded-shape --stream --debug 2>&1 | grep 'clone bundles'
  applying 2 clone bundles
  finished applying 2 clone bundles
  $ rm -rf after-reshard

Shards sets from previous configs cannot be used for shapes with the same name
but a different fingerprint

  $ cat $TESTTMP/source-shapes > $TESTTMP/source-shapes-redefined
  $ cat << EOF >> $TESTTMP/source-shapes-redefined
  > [[shards]]
  > name = "nested"
  > paths = ["dir1/excluded/nested"]
  > [[shards]]
  > name = "excluded-shape"
  > requires = ["nested"]
  > shape = true
  > EOF
  $ hg -R source admin::narrow-server --shape-update -f $TESTTMP/source-shapes-redefined \
  >   --override-fingerprint-change-check --override-saved-configs-check
  $ hg clone ssh://user@dummy/source redefined --noupdate --store-shape excluded-shape --stream --debug 2>&1 | grep 'clone bundles'
  no compatible clone bundles available on server; falling back to regular clone
  $ rm -rf redefined
