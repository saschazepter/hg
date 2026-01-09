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

  $ cat >> source/.hg/store/server-shapes << EOF
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
  stream2 -- {bytecount: 2637, filecount: 20, requirements: generaldelta%2Crevlog-compression-zstd%2Crevlogv1%2Csparserevlog} (mandatory: True)


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
  $ hg debug::clonebundle-manifest ssh://user@dummy/source --debug | grep 'correct store fingerprint'
  filtering peer-bundle-cache://outfile-shape-foobar.hg because not the correct store fingerprint (expected feb09be59c639f9f80726b5cd0204cf05cda6ea875fa7fd7c1dea98f9a28e726)
  filtering peer-bundle-cache://outfile-shape-foobaz.hg because not the correct store fingerprint (expected bda77439a4ee183aaa533e68680cdbc2fae13fb0c0e20210a598fe8889ef640e)

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
