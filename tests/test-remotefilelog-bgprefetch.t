#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"
  $ cat >> $HGRCPATH <<EOF
  > [devel]
  > remotefilelog.bg-wait=True
  > EOF

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > EOF
  $ echo x > x
  $ echo z > z
  $ hg commit -qAm x
  $ echo x2 > x
  $ echo y > y
  $ hg commit -qAm y
  $ echo w > w
  $ rm z
  $ hg commit -qAm w
  $ hg bookmark foo

  $ cd ..

# clone the repo

  $ hgcloneshallow ssh://user@dummy/master shallow --noupdate
  streaming all changes
  2 files to transfer, 776 bytes of data (no-zstd !)
  transferred 776 bytes in * seconds (*/sec) (glob) (no-zstd !)
  2 files to transfer, 784 bytes of data (zstd !)
  transferred 784 bytes in * seconds (* */sec) (glob) (zstd !)
  searching for changes
  no changes found

# Set the prefetchdays config to zero so that all commits are prefetched
# no matter what their creation date is. Also set prefetchdelay config
# to zero so that there is no delay between prefetches.
  $ cd shallow
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > prefetchdays=0
  > prefetchdelay=0
  > EOF
  $ cd ..

# prefetch a revision
  $ cd shallow

  $ hg prefetch -r 0
  2 files fetched over 1 fetches - (2 misses, 0.00% hit ratio) over *s (glob)

  $ hg cat -r 0 x
  x

# background prefetch on pull when configured

  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > pullprefetch=bookmark()
  > backgroundprefetch=True
  > EOF
  $ hg strip tip
  saved backup bundle to $TESTTMP/shallow/.hg/strip-backup/6b4b6f66ef8c-b4b8bdaf-backup.hg (glob)
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)

  $ clearcache
  $ hg pull
  pulling from ssh://user@dummy/master
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  updating bookmark foo
  added 1 changesets with 0 changes to 0 files
  new changesets 6b4b6f66ef8c
  (run 'hg update' to get a working copy)
  prefetching file contents
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/ef95c5376f34698742fe34f315fd82136f8f68c0
  $TESTTMP/hgcache/master/95/cb0bfd2977c761298d9624e4b4d4c72a39974a/076f5e2225b3ff0400b98c92aa6cdf403ee24cca
  $TESTTMP/hgcache/master/af/f024fe4ab0fece4091de044c58c9ae4233383a/bb6ccd5dceaa5e9dc220e0dad65e051b94f69a2c
  $TESTTMP/hgcache/repos

# background prefetch with repack on pull when configured

  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > backgroundrepack=True
  > EOF
  $ hg strip tip
  saved backup bundle to $TESTTMP/shallow/.hg/strip-backup/6b4b6f66ef8c-b4b8bdaf-backup.hg (glob)

  $ clearcache
  $ hg pull
  pulling from ssh://user@dummy/master
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  updating bookmark foo
  added 1 changesets with 0 changes to 0 files
  new changesets 6b4b6f66ef8c
  (run 'hg update' to get a working copy)
  prefetching file contents
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/6e8633deba6e544e5f8edbd7b996d6e31a2c42ae.histidx
  $TESTTMP/hgcache/master/packs/6e8633deba6e544e5f8edbd7b996d6e31a2c42ae.histpack
  $TESTTMP/hgcache/master/packs/8ce5ab3745465ab83bba30a7b9c295e0c8404652.dataidx
  $TESTTMP/hgcache/master/packs/8ce5ab3745465ab83bba30a7b9c295e0c8404652.datapack
  $TESTTMP/hgcache/repos

# background prefetch with repack on update when wcprevset configured

  $ clearcache
  $ hg up -r 0
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  2 files fetched over 1 fetches - (2 misses, 0.00% hit ratio) over *s (glob)
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/1406e74118627694268417491f018a4a883152f0
  $TESTTMP/hgcache/master/39/5df8f7c51f007019cb30201c49e884b46b92fa/69a1b67522704ec122181c0890bd16e9d3e7516a
  $TESTTMP/hgcache/repos

  $ hg up -r 1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  2 files fetched over 2 fetches - (2 misses, 0.00% hit ratio) over *s (glob)

  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > bgprefetchrevs=.::
  > EOF

  $ clearcache
  $ hg up -r 0
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  * files fetched over * fetches - (* misses, 0.00% hit ratio) over *s (glob)
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histidx
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histpack
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.dataidx
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.datapack
  $TESTTMP/hgcache/repos

# Ensure that file 'w' was prefetched - it was not part of the update operation and therefore
# could only be downloaded by the background prefetch

  $ hg debugdatapack `ls -ct $TESTTMP/hgcache/master/packs/*.datapack | head -n 1`
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407:
  w:
  Node          Delta Base    Delta Length  Blob Size
  bb6ccd5dceaa  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  x:
  Node          Delta Base    Delta Length  Blob Size
  ef95c5376f34  000000000000  3             3
  1406e7411862  ef95c5376f34  14            2
  
  Total:                      17            5         (240.0% bigger)
  y:
  Node          Delta Base    Delta Length  Blob Size
  076f5e2225b3  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  z:
  Node          Delta Base    Delta Length  Blob Size
  69a1b6752270  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)

# background prefetch with repack on commit when wcprevset configured

  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > bgprefetchrevs=0::
  > EOF

  $ clearcache
  $ find $CACHEDIR -type f | sort
  $ echo b > b
.. The following output line about files fetches is globed because it is
.. flaky, the core the test is checked when checking the cache dir, so
.. hopefully this flakyness is not hiding any actual bug.
  $ hg commit -qAm b
  * files fetched over 1 fetches - (* misses, 0.00% hit ratio) over *s (glob) (?)
  $ hg bookmark temporary
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histidx
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histpack
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.dataidx
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.datapack
  $TESTTMP/hgcache/repos

# Ensure that file 'w' was prefetched - it was not part of the commit operation and therefore
# could only be downloaded by the background prefetch

  $ hg debugdatapack `ls -ct $TESTTMP/hgcache/master/packs/*.datapack | head -n 1`
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407:
  w:
  Node          Delta Base    Delta Length  Blob Size
  bb6ccd5dceaa  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  x:
  Node          Delta Base    Delta Length  Blob Size
  ef95c5376f34  000000000000  3             3
  1406e7411862  ef95c5376f34  14            2
  
  Total:                      17            5         (240.0% bigger)
  y:
  Node          Delta Base    Delta Length  Blob Size
  076f5e2225b3  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  z:
  Node          Delta Base    Delta Length  Blob Size
  69a1b6752270  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)

# background prefetch with repack on rebase when wcprevset configured

  $ hg up -r 2
  3 files updated, 0 files merged, 2 files removed, 0 files unresolved
  (leaving bookmark temporary)
  $ clearcache
  $ find $CACHEDIR -type f | sort
.. The following output line about files fetches is globed because it is
.. flaky, the core the test is checked when checking the cache dir, so
.. hopefully this flakyness is not hiding any actual bug.
  $ hg rebase -s temporary -d foo
  rebasing 3:d9cf06e3b5b6 temporary tip "b"
  saved backup bundle to $TESTTMP/shallow/.hg/strip-backup/d9cf06e3b5b6-e5c3dc63-rebase.hg
  ? files fetched over ? fetches - (? misses, 0.00% hit ratio) over *s (glob)
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histidx
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histpack
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.dataidx
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.datapack
  $TESTTMP/hgcache/repos

# Ensure that file 'y' was prefetched - it was not part of the rebase operation and therefore
# could only be downloaded by the background prefetch

  $ hg debugdatapack `ls -ct $TESTTMP/hgcache/master/packs/*.datapack | head -n 1`
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407:
  w:
  Node          Delta Base    Delta Length  Blob Size
  bb6ccd5dceaa  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  x:
  Node          Delta Base    Delta Length  Blob Size
  ef95c5376f34  000000000000  3             3
  1406e7411862  ef95c5376f34  14            2
  
  Total:                      17            5         (240.0% bigger)
  y:
  Node          Delta Base    Delta Length  Blob Size
  076f5e2225b3  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  z:
  Node          Delta Base    Delta Length  Blob Size
  69a1b6752270  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)

# Check that foregound prefetch with no arguments blocks until background prefetches finish

  $ hg up -r 3
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ clearcache
  $ hg prefetch --repack --config ui.timeout.warn=-1
  (running background incremental repack)
  * files fetched over 1 fetches - (* misses, 0.00% hit ratio) over *s (glob) (?)

  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histidx
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histpack
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.dataidx
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.datapack
  $TESTTMP/hgcache/repos

# Ensure that files were prefetched
  $ hg debugdatapack `ls -ct $TESTTMP/hgcache/master/packs/*.datapack | head -n 1`
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407:
  w:
  Node          Delta Base    Delta Length  Blob Size
  bb6ccd5dceaa  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  x:
  Node          Delta Base    Delta Length  Blob Size
  ef95c5376f34  000000000000  3             3
  1406e7411862  ef95c5376f34  14            2
  
  Total:                      17            5         (240.0% bigger)
  y:
  Node          Delta Base    Delta Length  Blob Size
  076f5e2225b3  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  z:
  Node          Delta Base    Delta Length  Blob Size
  69a1b6752270  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)

# Check that foreground prefetch fetches revs specified by '. + draft() + bgprefetchrevs + pullprefetch'

  $ clearcache
  $ hg prefetch --repack --config ui.timeout.warn=-1
  (running background incremental repack)
  * files fetched over 1 fetches - (* misses, 0.00% hit ratio) over *s (glob) (?)

  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histidx
  $TESTTMP/hgcache/master/packs/8f1443d44e57fec96f72fb2412e01d2818767ef2.histpack
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.dataidx
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407.datapack
  $TESTTMP/hgcache/repos

# Ensure that files were prefetched
  $ hg debugdatapack `ls -ct $TESTTMP/hgcache/master/packs/*.datapack | head -n 1`
  $TESTTMP/hgcache/master/packs/f4d50848e0b465e9bfd2875f213044c06cfd7407:
  w:
  Node          Delta Base    Delta Length  Blob Size
  bb6ccd5dceaa  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  x:
  Node          Delta Base    Delta Length  Blob Size
  ef95c5376f34  000000000000  3             3
  1406e7411862  ef95c5376f34  14            2
  
  Total:                      17            5         (240.0% bigger)
  y:
  Node          Delta Base    Delta Length  Blob Size
  076f5e2225b3  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)
  z:
  Node          Delta Base    Delta Length  Blob Size
  69a1b6752270  000000000000  2             2
  
  Total:                      2             2         (0.0% bigger)

# Test that if data was prefetched and repacked we dont need to prefetch it again
# It ensures that Mercurial looks not only in loose files but in packs as well

  $ hg prefetch --repack
  (running background incremental repack)
