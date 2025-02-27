#require no-chg

Set up a server

  $ hg init server
  $ cd server
  $ cat >> .hg/hgrc << EOF
  > [extensions]
  > clonebundles =
  > EOF

  $ touch foo
  $ hg -q commit -A -m 'add foo'
  $ touch bar
  $ hg -q commit -A -m 'add bar'

  $ hg serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS
  $ cd ..

Missing manifest should not result in server lookup

  $ hg --verbose clone -U http://localhost:$HGPORT no-manifest
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf
  (sent 3 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ cat server/access.log
  * - - [*] "GET /?cmd=capabilities HTTP/1.1" 200 - (glob)
  $LOCALIP - - [$LOGDATE$] "GET /?cmd=batch HTTP/1.1" 200 - x-hgarg-1:cmds=heads+%3Bknown+nodes%3D x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)
  $LOCALIP - - [$LOGDATE$] "GET /?cmd=getbundle HTTP/1.1" 200 - x-hgarg-1:bookmarks=1&$USUAL_BUNDLE_CAPS$&cg=1&common=0000000000000000000000000000000000000000&heads=aaff8d2ffbbf07a46dd1f05d8ae7877e3f56e2a2&listkeys=bookmarks&phases=1 x-hgproto-1:0.1 0.2 comp=$USUAL_COMPRESSIONS$ partial-pull (glob)

Empty manifest file results in retrieval
(the extension only checks if the manifest file exists)

  $ touch server/.hg/clonebundles.manifest
  $ hg --verbose clone -U http://localhost:$HGPORT empty-manifest
  no clone bundles available on remote; falling back to regular clone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

Manifest file with invalid URL aborts

  $ echo 'http://does.not.exist/bundle.hg' > server/.hg/clonebundles.manifest
  $ hg clone http://localhost:$HGPORT 404-url
  applying clone bundle from http://does.not.exist/bundle.hg
  error fetching bundle: (.* not known|(\[Errno -?\d+] )?([Nn]o address associated with (host)?name|Temporary failure in name resolution|Name does not resolve)) (re) (no-windows !)
  error fetching bundle: [Errno 1100*] getaddrinfo failed (glob) (windows !)
  abort: error applying bundle
  (if this error persists, consider contacting the server operator or disable clone bundles via "--config ui.clonebundles=false")
  [255]

Manifest file with URL with unknown scheme skips the URL
  $ echo 'weirdscheme://does.not.exist/bundle.hg' > server/.hg/clonebundles.manifest
  $ hg clone http://localhost:$HGPORT unknown-scheme
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Server is not running aborts

  $ echo "http://localhost:$HGPORT1/bundle.hg" > server/.hg/clonebundles.manifest
  $ hg clone http://localhost:$HGPORT server-not-runner
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  error fetching bundle: (.*\$ECONNREFUSED\$|Protocol not supported|(.* )?\$EADDRNOTAVAIL\$|.* No route to host) (re)
  abort: error applying bundle
  (if this error persists, consider contacting the server operator or disable clone bundles via "--config ui.clonebundles=false")
  [255]

Server returns 404

  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS
  $ hg clone http://localhost:$HGPORT running-404
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  HTTP error fetching bundle: HTTP Error 404: File not found
  abort: error applying bundle
  (if this error persists, consider contacting the server operator or disable clone bundles via "--config ui.clonebundles=false")
  [255]

We can override failure to fall back to regular clone

  $ hg --config ui.clonebundlefallback=true clone -U http://localhost:$HGPORT 404-fallback
  applying clone bundle from http://localhost:$HGPORT1/bundle.hg
  HTTP error fetching bundle: HTTP Error 404: File not found
  falling back to normal clone
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf

Bundle with partial content works

  $ hg -R server bundle --type gzip-v1 --base null -r 53245c60e682 partial.hg
  1 changesets found

We verify exact bundle content as an extra check against accidental future
changes. If this output changes, we could break old clients.

  $ f --size --hexdump partial.hg
  partial.hg: size=207
  0000: 48 47 31 30 47 5a 78 9c 63 60 60 98 17 ac 12 93 |HG10GZx.c``.....|
  0010: f0 ac a9 23 45 70 cb bf 0d 5f 59 4e 4a 7f 79 21 |...#Ep..._YNJ.y!|
  0020: 9b cc 40 24 20 a0 d7 ce 2c d1 38 25 cd 24 25 d5 |..@$ ...,.8%.$%.|
  0030: d8 c2 22 cd 38 d9 24 cd 22 d5 c8 22 cd 24 cd 32 |..".8.$."..".$.2|
  0040: d1 c2 d0 c4 c8 d2 32 d1 38 39 29 c9 34 cd d4 80 |......2.89).4...|
  0050: ab 24 b5 b8 84 cb 40 c1 80 2b 2d 3f 9f 8b 2b 31 |.$....@..+-?..+1|
  0060: 25 45 01 c8 80 9a d2 9b 65 fb e5 9e 45 bf 8d 7f |%E......e...E...|
  0070: 9f c6 97 9f 2b 44 34 67 d9 ec 8e 0f a0 92 0b 75 |....+D4g.......u|
  0080: 41 d6 24 59 18 a4 a4 9a a6 18 1a 5b 98 9b 5a 98 |A.$Y.......[..Z.|
  0090: 9a 18 26 9b a6 19 98 1a 99 99 26 a6 18 9a 98 24 |..&.......&....$|
  00a0: 26 59 a6 25 5a 98 a5 18 a6 24 71 41 35 b1 43 dc |&Y.%Z....$qA5.C.|
  00b0: 16 b2 83 f7 e9 45 8b d2 56 c7 a3 1f 82 52 d7 8a |.....E..V....R..|
  00c0: 78 ed fc d5 76 f1 36 35 dc 05 00 36 ed 5e c7    |x...v.65...6.^.|

  $ echo "http://localhost:$HGPORT1/partial.hg" > server/.hg/clonebundles.manifest
  $ hg clone -U http://localhost:$HGPORT partial-bundle
  applying clone bundle from http://localhost:$HGPORT1/partial.hg
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  finished applying clone bundle
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets aaff8d2ffbbf
  1 local changesets published

Incremental pull doesn't fetch bundle

  $ hg clone -r 53245c60e682 -U http://localhost:$HGPORT partial-clone
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 53245c60e682

  $ cd partial-clone
  $ hg pull
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets aaff8d2ffbbf
  (run 'hg update' to get a working copy)
  $ cd ..

Bundle with full content works

  $ hg -R server bundle --type gzip-v2 --base null -r tip full.hg
  2 changesets found

Again, we perform an extra check against bundle content changes. If this content
changes, clone bundles produced by new Mercurial versions may not be readable
by old clients.

  $ f --size --hexdump full.hg
  full.hg: size=442
  0000: 48 47 32 30 00 00 00 0e 43 6f 6d 70 72 65 73 73 |HG20....Compress|
  0010: 69 6f 6e 3d 47 5a 78 9c 63 60 60 d0 e4 76 f6 70 |ion=GZx.c``..v.p|
  0020: f4 73 77 75 0f f2 0f 0d 60 00 02 46 46 76 26 4e |.swu....`..FFv&N|
  0030: c6 b2 d4 a2 e2 cc fc 3c 03 a3 bc a4 e4 8c c4 bc |.......<........|
  0040: f4 d4 62 23 06 06 e6 19 40 f9 4d c1 2a 31 09 cf |..b#....@.M.*1..|
  0050: 9a 3a 52 04 b7 fc db f0 95 e5 a4 f4 97 17 b2 c9 |.:R.............|
  0060: 0c 14 00 02 e6 d9 99 25 1a a7 a4 99 a4 a4 1a 5b |.......%.......[|
  0070: 58 a4 19 27 9b a4 59 a4 1a 59 a4 99 a4 59 26 5a |X..'..Y..Y...Y&Z|
  0080: 18 9a 18 59 5a 26 1a 27 27 25 99 a6 99 1a 70 95 |...YZ&.''%....p.|
  0090: a4 16 97 70 19 28 18 70 a5 e5 e7 73 71 25 a6 a4 |...p.(.p...sq%..|
  00a0: 28 00 19 20 17 af fa df ab ff 7b 3f fb 92 dc 8b |(.. ......{?....|
  00b0: 1f 62 bb 9e b7 d7 d9 87 3d 5a 44 89 2f b0 99 87 |.b......=ZD./...|
  00c0: ec e2 54 63 43 e3 b4 64 43 73 23 33 43 53 0b 63 |..TcC..dCs#3CS.c|
  00d0: d3 14 23 03 a0 fb 2c 2c 0c d3 80 1e 30 49 49 b1 |..#...,,....0II.|
  00e0: 4c 4a 32 48 33 30 b0 34 42 b8 38 29 b1 08 e2 62 |LJ2H30.4B.8)...b|
  00f0: 20 03 6a ca c2 2c db 2f f7 2c fa 6d fc fb 34 be | .j..,./.,.m..4.|
  0100: fc 5c 21 a2 39 cb 66 77 7c 00 0d c3 59 17 14 58 |.\!.9.fw|...Y..X|
  0110: 49 16 06 29 a9 a6 29 86 c6 16 e6 a6 16 a6 26 86 |I..)..).......&.|
  0120: c9 a6 69 06 a6 46 66 a6 89 29 86 26 26 89 49 96 |..i..Ff..).&&.I.|
  0130: 69 89 16 66 29 86 29 49 5c 20 07 3e 16 fe 23 ae |i..f).)I\ .>..#.|
  0140: 26 da 1c ab 10 1f d1 f8 e3 b3 ef cd dd fc 0c 93 |&...............|
  0150: 88 75 34 36 75 04 82 55 17 14 36 a4 38 10 04 d8 |.u46u..U..6.8...|
  0160: 21 01 9a b1 83 f7 e9 45 8b d2 56 c7 a3 1f 82 52 |!......E..V....R|
  0170: d7 8a 78 ed fc d5 76 f1 36 25 81 89 c7 ad ec 90 |..x...v.6%......|
  0180: 54 47 75 2b 89 48 b1 b2 62 c9 89 c9 19 a9 56 45 |TGu+.H..b.....VE|
  0190: a9 65 ba 49 45 89 79 c9 19 ba 60 01 a0 14 23 58 |.e.IE.y...`...#X|
  01a0: 81 35 c8 7d 40 cc 04 e2 a4 a4 a6 25 96 e6 94 60 |.5.}@......%...`|
  01b0: 33 17 5f 54 00 00 d3 1b 0d 4c                   |3._T.....L|

  $ echo "http://localhost:$HGPORT1/full.hg" > server/.hg/clonebundles.manifest
  $ hg clone -U http://localhost:$HGPORT full-bundle
  applying clone bundle from http://localhost:$HGPORT1/full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Feature works over SSH

  $ hg clone -U ssh://user@dummy/server ssh-full-clone
  applying clone bundle from http://localhost:$HGPORT1/full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Inline bundle
=============

Checking bundle retrieved over the wireprotocol

Feature works over SSH with inline bundle
-----------------------------------------

  $ mkdir server/.hg/bundle-cache/
  $ cp full.hg server/.hg/bundle-cache/
  $ echo "peer-bundle-cache://full.hg" > server/.hg/clonebundles.manifest
  $ hg clone -U ssh://user@dummy/server ssh-inline-clone
  applying clone bundle from peer-bundle-cache://full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Out-of-repo storage for inline bundle
-------------------------------------

  $ cp -R server server-extern
  $ cat >> server-extern/.hg/hgrc << EOF
  > [server]
  > peer-bundle-cache-root = `pwd`/server/.hg/bundle-cache
  > EOF
  $ rm -r server-extern/.hg/bundle-cache
  $ hg clone -U ssh://user@dummy/server-extern ssh-inline-clone-extern
  applying clone bundle from peer-bundle-cache://full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

HTTP Supports
-------------

  $ hg clone -U http://localhost:$HGPORT http-inline-clone
  applying clone bundle from peer-bundle-cache://full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published


Check local behavior
--------------------

We don't use the clone bundle, but we do not crash either.

  $ hg clone -U ./server local-inline-clone-default
  $ hg clone -U ./server local-inline-clone-pull --pull
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf

Pre-transmit Hook
-----------------

Hooks work with inline bundle

  $ cp server/.hg/hgrc server/.hg/hgrc-beforeinlinehooks
  $ cat >> server/.hg/hgrc <<-EOF
  > [hooks]
  > pretransmit-inline-clone-bundle=sh -c 'printf "foo\n"'
  > EOF
  $ hg clone -U ssh://user@dummy/server ssh-inline-clone-hook
  applying clone bundle from peer-bundle-cache://full.hg
  remote: foo
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Hooks can make an inline bundle fail

  $ cp server/.hg/hgrc-beforeinlinehooks server/.hg/hgrc
  $ cat >> server/.hg/hgrc <<-EOF
  > [hooks]
  > pretransmit-inline-clone-bundle=sh -c 'printf "bar\n"' && false
  > EOF
  $ hg clone -U ssh://user@dummy/server ssh-inline-clone-hook-fail
  applying clone bundle from peer-bundle-cache://full.hg
  remote: bar
  remote: abort: pretransmit-inline-clone-bundle hook exited with status 1
  abort: stream ended unexpectedly (got 0 bytes, expected 1)
  [255]
  $ cp server/.hg/hgrc-beforeinlinehooks server/.hg/hgrc

Other tests
===========

Entry with unknown BUNDLESPEC is filtered and not used

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://bad.entry1 BUNDLESPEC=UNKNOWN
  > http://bad.entry2 BUNDLESPEC=xz-v1
  > http://bad.entry3 BUNDLESPEC=none-v100
  > http://localhost:$HGPORT1/full.hg BUNDLESPEC=gzip-v2
  > EOF

  $ hg clone -U http://localhost:$HGPORT filter-unknown-type
  applying clone bundle from http://localhost:$HGPORT1/full.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Automatic fallback when all entries are filtered

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://bad.entry BUNDLESPEC=UNKNOWN
  > EOF

  $ hg clone -U http://localhost:$HGPORT filter-all
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf

We require a Python version that supports SNI. Therefore, URLs requiring SNI
are not filtered.

  $ cp full.hg sni.hg
  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/sni.hg REQUIRESNI=true
  > http://localhost:$HGPORT1/full.hg
  > EOF

  $ hg clone -U http://localhost:$HGPORT sni-supported
  applying clone bundle from http://localhost:$HGPORT1/sni.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Stream clone bundles are supported

  $ hg -R server debugcreatestreamclonebundle packed.hg
  writing 613 bytes for 5 files (no-rust !)
  writing 739 bytes for 7 files (rust !)
  bundle requirements: generaldelta, revlogv1, sparserevlog (no-rust no-zstd !)
  bundle requirements: generaldelta, revlog-compression-zstd, revlogv1, sparserevlog (no-rust zstd !)
  bundle requirements: generaldelta, revlog-compression-zstd, revlogv1, sparserevlog (rust !)

No bundle spec should work

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/packed.hg
  > EOF

  $ hg clone -U http://localhost:$HGPORT stream-clone-no-spec
  applying clone bundle from http://localhost:$HGPORT1/packed.hg
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found

Bundle spec without parameters should work

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/packed.hg BUNDLESPEC=none-packed1
  > EOF

  $ hg clone -U http://localhost:$HGPORT stream-clone-vanilla-spec
  applying clone bundle from http://localhost:$HGPORT1/packed.hg
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found

Bundle spec with format requirements should work

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/packed.hg BUNDLESPEC=none-packed1;requirements%3Drevlogv1
  > EOF

  $ hg clone -U http://localhost:$HGPORT stream-clone-supported-requirements
  applying clone bundle from http://localhost:$HGPORT1/packed.hg
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found

Stream bundle spec with unknown requirements should be filtered out

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/packed.hg BUNDLESPEC=none-packed1;requirements%3Drevlogv42
  > EOF

  $ hg clone -U http://localhost:$HGPORT stream-clone-unsupported-requirements
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf

Set up manifest for testing preferences
(Remember, the TYPE does not have to match reality - the URL is
important)

  $ cp full.hg gz-a.hg
  $ cp full.hg gz-b.hg
  $ cp full.hg bz2-a.hg
  $ cp full.hg bz2-b.hg
  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2 extra=a
  > http://localhost:$HGPORT1/bz2-a.hg BUNDLESPEC=bzip2-v2 extra=a
  > http://localhost:$HGPORT1/gz-b.hg BUNDLESPEC=gzip-v2 extra=b
  > http://localhost:$HGPORT1/bz2-b.hg BUNDLESPEC=bzip2-v2 extra=b
  > EOF

Preferring an undefined attribute will take first entry

  $ hg --config ui.clonebundleprefers=foo=bar clone -U http://localhost:$HGPORT prefer-foo
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Preferring bz2 type will download first entry of that type

  $ hg --config ui.clonebundleprefers=COMPRESSION=bzip2 clone -U http://localhost:$HGPORT prefer-bz
  applying clone bundle from http://localhost:$HGPORT1/bz2-a.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Preferring multiple values of an option works

  $ hg --config ui.clonebundleprefers=COMPRESSION=unknown,COMPRESSION=bzip2 clone -U http://localhost:$HGPORT prefer-multiple-bz
  applying clone bundle from http://localhost:$HGPORT1/bz2-a.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Sorting multiple values should get us back to original first entry

  $ hg --config ui.clonebundleprefers=BUNDLESPEC=unknown,BUNDLESPEC=gzip-v2,BUNDLESPEC=bzip2-v2 clone -U http://localhost:$HGPORT prefer-multiple-gz
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Preferring multiple attributes has correct order

  $ hg --config ui.clonebundleprefers=extra=b,BUNDLESPEC=bzip2-v2 clone -U http://localhost:$HGPORT prefer-separate-attributes
  applying clone bundle from http://localhost:$HGPORT1/bz2-b.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Test where attribute is missing from some entries

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2
  > http://localhost:$HGPORT1/bz2-a.hg BUNDLESPEC=bzip2-v2
  > http://localhost:$HGPORT1/gz-b.hg BUNDLESPEC=gzip-v2 extra=b
  > http://localhost:$HGPORT1/bz2-b.hg BUNDLESPEC=bzip2-v2 extra=b
  > EOF

  $ hg --config ui.clonebundleprefers=extra=b clone -U http://localhost:$HGPORT prefer-partially-defined-attribute
  applying clone bundle from http://localhost:$HGPORT1/gz-b.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published

Test a bad attribute list

  $ hg --config ui.clonebundleprefers=bad clone -U http://localhost:$HGPORT bad-input
  abort: invalid ui.clonebundleprefers item: bad
  (each comma separated item should be key=value pairs)
  [255]
  $ hg --config ui.clonebundleprefers=key=val,bad,key2=val2 clone \
  >    -U http://localhost:$HGPORT bad-input
  abort: invalid ui.clonebundleprefers item: bad
  (each comma separated item should be key=value pairs)
  [255]


Test interaction between clone bundles and --stream

A manifest with just a gzip bundle

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2
  > EOF

  $ hg clone -U --stream http://localhost:$HGPORT uncompressed-gzip
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  streaming all changes
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)

A manifest with a stream clone but no BUNDLESPEC

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/packed.hg
  > EOF

  $ hg clone -U --stream http://localhost:$HGPORT uncompressed-no-bundlespec
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  streaming all changes
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)

A manifest with a gzip bundle and a stream clone

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2
  > http://localhost:$HGPORT1/packed.hg BUNDLESPEC=none-packed1
  > EOF

  $ hg clone -U --stream http://localhost:$HGPORT uncompressed-gzip-packed
  applying clone bundle from http://localhost:$HGPORT1/packed.hg
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found

A manifest with a gzip bundle and stream clone with supported requirements

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2
  > http://localhost:$HGPORT1/packed.hg BUNDLESPEC=none-packed1;requirements%3Drevlogv1
  > EOF

  $ hg clone -U --stream http://localhost:$HGPORT uncompressed-gzip-packed-requirements
  applying clone bundle from http://localhost:$HGPORT1/packed.hg
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)
  finished applying clone bundle
  searching for changes
  no changes found

A manifest with a gzip bundle and a stream clone with unsupported requirements

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2
  > http://localhost:$HGPORT1/packed.hg BUNDLESPEC=none-packed1;requirements%3Drevlogv42
  > EOF

  $ hg clone -U --stream http://localhost:$HGPORT uncompressed-gzip-packed-unsupported-requirements
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  streaming all changes
  * files to transfer, * bytes of data (glob)
  stream-cloned * files / * bytes in * seconds (* */sec) (glob)

Test clone bundle retrieved through bundle2

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > largefiles=
  > EOF
  $ killdaemons.py
  $ hg -R server serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ hg -R server debuglfput gz-a.hg
  1f74b3d08286b9b3a16fb3fa185dd29219cbc6ae

  $ cat > server/.hg/clonebundles.manifest << EOF
  > largefile://1f74b3d08286b9b3a16fb3fa185dd29219cbc6ae BUNDLESPEC=gzip-v2
  > EOF

  $ hg clone -U http://localhost:$HGPORT largefile-provided --traceback
  applying clone bundle from largefile://1f74b3d08286b9b3a16fb3fa185dd29219cbc6ae
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published
  $ killdaemons.py

A manifest with a gzip bundle requiring too much memory for a 16MB system and working
on a 32MB system.

  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS
  $ hg -R server serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2 REQUIREDRAM=12MB
  > EOF

  $ hg clone -U --debug --config ui.available-memory=16MB http://localhost:$HGPORT gzip-too-large
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  filtering http://localhost:$HGPORT1/gz-a.hg as it needs more than 2/3 of system memory
  no compatible clone bundles available on server; falling back to regular clone
  (you may want to report this to the server operator)
  query 1; heads
  sending batch command
  requesting all changes
  sending getbundle command
  bundle2-input-bundle: with-transaction
  bundle2-input-part: "changegroup" (params: 1 mandatory 1 advisory) supported
  adding changesets
  add changeset 53245c60e682
  add changeset aaff8d2ffbbf
  adding manifests
  adding file changes
  adding bar revisions
  adding foo revisions
  bundle2-input-part: total payload size 936
  bundle2-input-part: "listkeys" (params: 1 mandatory) supported
  bundle2-input-part: "phase-heads" supported
  bundle2-input-part: total payload size 24
  bundle2-input-bundle: 3 parts total
  checking for updated bookmarks
  updating the branch cache
  added 2 changesets with 2 changes to 2 files
  new changesets 53245c60e682:aaff8d2ffbbf
  calling hook changegroup.lfiles: hgext.largefiles.reposetup.checkrequireslfiles
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)

  $ hg clone -U --debug --config ui.available-memory=32MB http://localhost:$HGPORT gzip-too-large2
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  bundle2-input-bundle: 1 params with-transaction
  bundle2-input-part: "changegroup" (params: 1 mandatory 1 advisory) supported
  adding changesets
  add changeset 53245c60e682
  add changeset aaff8d2ffbbf
  adding manifests
  adding file changes
  adding bar revisions
  adding foo revisions
  bundle2-input-part: total payload size 920
  bundle2-input-part: "cache:rev-branch-cache" (advisory) supported
  bundle2-input-part: total payload size 59
  bundle2-input-bundle: 2 parts total
  updating the branch cache
  added 2 changesets with 2 changes to 2 files
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
  2 local changesets published
  calling hook changegroup.lfiles: hgext.largefiles.reposetup.checkrequireslfiles
  updating the branch cache
  (sent 4 HTTP requests and * bytes; received * bytes in responses) (glob)
  $ killdaemons.py

Testing a clone bundle with digest
==================================

  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS
  $ hg -R server serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS

  $ digest=$("$PYTHON" -c "import hashlib; print (hashlib.sha256(open('gz-a.hg', 'rb').read()).hexdigest())")
  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2 DIGEST=sha256:${digest}
  > EOF
  $ hg clone -U http://localhost:$HGPORT digest-valid
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files
  finished applying clone bundle
  searching for changes
  no changes found
  2 local changesets published
  $ digest_bad=$("$PYTHON" -c "import hashlib; print (hashlib.sha256(open('gz-a.hg', 'rb').read()+b'.').hexdigest())")
  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2 DIGEST=sha256:${digest_bad}
  > EOF
  $ hg clone -U  http://localhost:$HGPORT digest-invalid
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  abort: file with digest [0-9a-f]* expected, but [0-9a-f]* found for [0-9]* bytes (re)
  [150]
  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/bad-a.hg BUNDLESPEC=gzip-v2 DIGEST=sha256:xx
  > http://localhost:$HGPORT1/bad-b.hg BUNDLESPEC=gzip-v2 DIGEST=xxx:0000
  > http://localhost:$HGPORT1/bad-c.hg BUNDLESPEC=gzip-v2 DIGEST=sha256:0000
  > http://localhost:$HGPORT1/bad-d.hg BUNDLESPEC=gzip-v2 DIGEST=xxx:00,xxx:01
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2 DIGEST=sha256:${digest_bad}
  > EOF
  $ hg clone --debug -U  http://localhost:$HGPORT digest-malformed
  using http://localhost:$HGPORT/
  sending capabilities command
  sending clonebundles_manifest command
  filtering http://localhost:$HGPORT1/bad-a.hg due to a bad DIGEST attribute
  filtering http://localhost:$HGPORT1/bad-b.hg due to lack of supported digest
  filtering http://localhost:$HGPORT1/bad-c.hg due to a bad sha256 digest
  filtering http://localhost:$HGPORT1/bad-d.hg due to conflicting xxx digests
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  bundle2-input-bundle: 1 params with-transaction
  bundle2-input-bundle: 0 parts total
  \(sent [0-9]* HTTP requests and [0-9]* bytes; received [0-9]* bytes in responses\) (re)
  abort: file with digest [0-9a-f]* expected, but [0-9a-f]* found for [0-9]* bytes (re)
  [150]
  $ cat > server/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/gz-a.hg BUNDLESPEC=gzip-v2 DIGEST=sha512:00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000,sha256:0000000000000000000000000000000000000000000000000000000000000000
  > EOF
  $ hg clone -U  http://localhost:$HGPORT digest-preference
  applying clone bundle from http://localhost:$HGPORT1/gz-a.hg
  abort: file with digest 0{64} expected, but [0-9a-f]+ found for [0-9]+ bytes (re)
  [150]
  $ killdaemons.py

Testing a clone bundles that involves revlog splitting (issue6811)
==================================================================

  $ cat >> $HGRCPATH << EOF
  > [format]
  > revlog-compression=none
  > use-persistent-nodemap=no
  > EOF

  $ hg init server-revlog-split/
  $ cd server-revlog-split
  $ cat >> .hg/hgrc << EOF
  > [extensions]
  > clonebundles =
  > EOF
  $ echo foo > A
  $ hg add A
  $ hg commit -m 'initial commit'
IMPORTANT: the revlogs must not be split
  $ ls -1 .hg/store/00manifest.*
  .hg/store/00manifest.i
  $ ls -1 .hg/store/data/_a.*
  .hg/store/data/_a.i

do big enough update to split the revlogs

  $ $TESTDIR/seq.py 100000 > A
  $ mkdir foo
  $ cd foo
  $ touch `$TESTDIR/seq.py 10000`
  $ cd ..
  $ hg add -q foo
  $ hg commit -m 'split the manifest and one filelog'

IMPORTANT: now the revlogs must be split
  $ ls -1 .hg/store/00manifest.*
  .hg/store/00manifest.d
  .hg/store/00manifest.i
  $ ls -1 .hg/store/data/_a.*
  .hg/store/data/_a.d
  .hg/store/data/_a.i

Add an extra commit on top of that

  $ echo foo >> A
  $ hg commit -m 'one extra commit'

  $ cd ..

Do a bundle that contains the split, but not the update

  $ hg bundle --exact --rev '::(default~1)' -R server-revlog-split/ --type gzip-v2 split-test.hg
  2 changesets found

  $ cat > server-revlog-split/.hg/clonebundles.manifest << EOF
  > http://localhost:$HGPORT1/split-test.hg BUNDLESPEC=gzip-v2
  > EOF

start the necessary server

  $ "$PYTHON" $TESTDIR/dumbhttp.py -p $HGPORT1 --pid http.pid
  $ cat http.pid >> $DAEMON_PIDS
  $ hg -R server-revlog-split serve -d -p $HGPORT --pid-file hg.pid --accesslog access.log
  $ cat hg.pid >> $DAEMON_PIDS

Check that clone works fine
===========================

Here, the initial clone will trigger a revlog split (which is a bit clowny it
itself, but whatever). The split revlogs will see additionnal data added to
them in the subsequent pull. This should not be a problem

  $ hg clone http://localhost:$HGPORT revlog-split-in-the-bundle
  applying clone bundle from http://localhost:$HGPORT1/split-test.hg
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 10002 changes to 10001 files
  finished applying clone bundle
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets e3879eaa1db7
  2 local changesets published
  updating to branch default
  10001 files updated, 0 files merged, 0 files removed, 0 files unresolved

check the results

  $ cd revlog-split-in-the-bundle
  $ f --size .hg/store/00manifest.*
  .hg/store/00manifest.d: size=499037
  .hg/store/00manifest.i: size=192
  $ f --size .hg/store/data/_a.*
  .hg/store/data/_a.d: size=588917
  .hg/store/data/_a.i: size=192

manifest should work

  $ hg  files -r tip | wc -l
  \s*10001 (re)

file content should work

  $ hg  cat -r tip A | wc -l
  \s*100001 (re)


