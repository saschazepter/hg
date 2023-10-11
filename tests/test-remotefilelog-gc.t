#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > serverexpiration=-1
  > EOF
  $ echo x > x
  $ hg commit -qAm x
  $ cd ..

  $ hgcloneshallow ssh://user@dummy/master shallow -q
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)

# Set the prefetchdays config to zero so that all commits are prefetched
# no matter what their creation date is.
  $ cd shallow
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > prefetchdays=0
  > EOF
  $ cd ..

# commit a new version of x so we can gc the old one

  $ cd master
  $ echo y > x
  $ hg commit -qAm y
  $ cd ..

  $ cd shallow
  $ hg pull -q
  $ hg update -q
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)
  $ cd ..

# gc client cache

  $ lastweek=`"$PYTHON" -c 'import datetime,time; print(datetime.datetime.fromtimestamp(time.time() - (86400 * 7)).strftime("%y%m%d%H%M"))'`
  $ find $CACHEDIR -type f -exec touch -t $lastweek {} \;

  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/1406e74118627694268417491f018a4a883152f0 (glob)
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/48023ec064c1d522f0d792a5a912bb1bf7859a4a (glob)
  $TESTTMP/hgcache/repos (glob)
  $ hg gc
  finished: removed 1 of 2 files (0.00 GB to 0.00 GB)
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/48023ec064c1d522f0d792a5a912bb1bf7859a4a (glob)
  $TESTTMP/hgcache/repos

# gc server cache

  $ find master/.hg/remotefilelogcache -type f | sort
  master/.hg/remotefilelogcache/x/1406e74118627694268417491f018a4a883152f0 (glob)
  master/.hg/remotefilelogcache/x/48023ec064c1d522f0d792a5a912bb1bf7859a4a (glob)
  $ hg gc master
  finished: removed 0 of 1 files (0.00 GB to 0.00 GB)
  $ find master/.hg/remotefilelogcache -type f | sort
  master/.hg/remotefilelogcache/x/48023ec064c1d522f0d792a5a912bb1bf7859a4a (glob)

# Test that GC keepset includes pullprefetch revset if it is configured

  $ cd shallow
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > pullprefetch=all()
  > EOF
  $ hg prefetch
  1 files fetched over 1 fetches - (1 misses, 0.00% hit ratio) over *s (glob)

  $ cd ..
  $ hg gc
  finished: removed 0 of 2 files (0.00 GB to 0.00 GB)

# Ensure that there are 2 versions of the file in cache
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/1406e74118627694268417491f018a4a883152f0 (glob)
  $TESTTMP/hgcache/master/11/f6ad8ec52a2984abaafd7c3b516503785c2072/48023ec064c1d522f0d792a5a912bb1bf7859a4a (glob)
  $TESTTMP/hgcache/repos (glob)

# Test that if garbage collection on repack and repack on hg gc flags are set then incremental repack with garbage collector is run

  $ hg gc --config remotefilelog.gcrepack=True --config remotefilelog.repackonhggc=True

# Ensure that loose files are repacked
  $ find $CACHEDIR -type f | sort
  $TESTTMP/hgcache/master/packs/320dab99b7e3f60512b97f347689625263d22cf5.dataidx
  $TESTTMP/hgcache/master/packs/320dab99b7e3f60512b97f347689625263d22cf5.datapack
  $TESTTMP/hgcache/master/packs/837b83c1ef6485a336eb4421ac5973c0ec130fbb.histidx
  $TESTTMP/hgcache/master/packs/837b83c1ef6485a336eb4421ac5973c0ec130fbb.histpack
  $TESTTMP/hgcache/repos

# Test that warning is displayed when there are no valid repos in repofile

  $ cp $CACHEDIR/repos $CACHEDIR/repos.bak
  $ echo " " > $CACHEDIR/repos
  $ hg gc
  warning: no valid repos in repofile
  $ mv $CACHEDIR/repos.bak $CACHEDIR/repos

# Test that warning is displayed when the repo path is malformed

  $ printf "asdas\0das" >> $CACHEDIR/repos
  $ hg gc
  abort: invalid path asdas\x00da: .*(null|NULL).* (re)
  [255]
