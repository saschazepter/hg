#require no-windows

  $ . "$TESTDIR/remotefilelog-library.sh"

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [remotefilelog]
  > server=True
  > EOF
  $ echo x > x
  $ hg commit -qAm x
  $ mkdir dir
  $ echo y > dir/y
  $ hg commit -qAm y

  $ cd ..

Shallow clone from full

  $ hgcloneshallow ssh://user@dummy/master shallow --noupdate
  streaming all changes
  3 files to transfer, 473 bytes of data (no-rust !)
  stream-cloned 3 files / 473 bytes in * seconds (*/sec) (glob) (no-rust !)
  5 files to transfer, 599 bytes of data (rust !)
  stream-cloned 5 files / 599 bytes in * seconds (*/sec) (glob) (rust !)
  searching for changes
  no changes found
  $ cd shallow
  $ hg debugrequires
  dotencode
  dirstate-v2 (dirstate-v2 !)
  exp-remotefilelog-repo-req-1
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store

  $ hg update
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  2 files fetched over 1 fetches - (2 misses, 0.00% hit ratio) over *s (glob)

Log on a file without -f

  $ hg log dir/y
  warning: file log can be slow on large repos - use -f to speed it up
  changeset:   1:2e73264fab97
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     y
  
Log on a file with -f

  $ hg log -f dir/y
  changeset:   1:2e73264fab97
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     y
  
Log on a file with kind in path
  $ hg log -r "filelog('path:dir/y')"
  changeset:   1:2e73264fab97
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     y
  
Log on multiple files with -f

  $ hg log -f dir/y x
  changeset:   1:2e73264fab97
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     y
  
  changeset:   0:b292c1e3311f
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     x
  
Log on a directory

  $ hg log dir
  changeset:   1:2e73264fab97
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     y
  
Log on a file from inside a directory

  $ cd dir
  $ hg log y
  warning: file log can be slow on large repos - use -f to speed it up
  changeset:   1:2e73264fab97
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     y
  
Log on a file via -fr
  $ cd ..
  $ hg log -fr tip dir/ --template '{rev}\n'
  1

Trace renames
  $ hg mv x z
  $ hg commit -m move
  $ hg log -f z -T '{desc} {file_copies}\n' -G
  @  move z (x)
  :
  o  x
  

Verify remotefilelog handles rename metadata stripping when comparing file sizes
  $ hg debugrebuilddirstate
  $ hg status
