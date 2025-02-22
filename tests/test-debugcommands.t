  $ cat << EOF >> $HGRCPATH
  > [ui]
  > interactive=yes
  > EOF

  $ hg init debugrevlog
  $ cd debugrevlog
  $ echo a > a
  $ hg ci -Am adda
  adding a
  $ hg rm .
  removing a
  $ hg ci -Am make-it-empty
  $ hg revert --all -r 0
  adding a
  $ hg ci -Am make-it-full
  $ hg debugrevlog -c
  format : 1
  flags  : (none)
  
  revisions     :   3
      merges    :   0 ( 0.00%)
      normal    :   3 (100.00%)
  revisions     :   3
      empty     :   0 ( 0.00%)
                     text  :   0 (100.00%)
                     delta :   0 (100.00%)
      snapshot  :   3 (100.00%)
        lvl-0   :         3 (100.00%)
      deltas    :   0 ( 0.00%)
  revision size : 191
      snapshot  : 191 (100.00%)
        lvl-0   :       191 (100.00%)
      deltas    :   0 ( 0.00%)
  
  chunks        :   3
      0x75 (u)  :   3 (100.00%)
  chunks size   : 191
      0x75 (u)  : 191 (100.00%)
  
  
  total-stored-content: 188 bytes
  
  avg chain length  :  0
  max chain length  :  0
  max chain reach   : 67
  compression ratio :  0
  
  uncompressed data size (min/max/avg) : 57 / 66 / 62
  full revision size (min/max/avg)     : 58 / 67 / 63
  inter-snapshot size (min/max/avg)    : 0 / 0 / 0
  delta size (min/max/avg)             : 0 / 0 / 0
  $ hg debugrevlog -m
  format : 1
  flags  : inline, generaldelta
  
  revisions     :  3
      merges    :  0 ( 0.00%)
      normal    :  3 (100.00%)
  revisions     :  3
      empty     :  1 (33.33%)
                     text  :  1 (100.00%)
                     delta :  0 ( 0.00%)
      snapshot  :  2 (66.67%)
        lvl-0   :        2 (66.67%)
      deltas    :  0 ( 0.00%)
  revision size : 88
      snapshot  : 88 (100.00%)
        lvl-0   :       88 (100.00%)
      deltas    :  0 ( 0.00%)
  
  chunks        :  3
      empty     :  1 (33.33%)
      0x75 (u)  :  2 (66.67%)
  chunks size   : 88
      empty     :  0 ( 0.00%)
      0x75 (u)  : 88 (100.00%)
  
  
  total-stored-content: 86 bytes
  
  avg chain length  :  0
  max chain length  :  0
  max chain reach   : 44
  compression ratio :  0
  
  uncompressed data size (min/max/avg) : 0 / 43 / 28
  full revision size (min/max/avg)     : 44 / 44 / 44
  inter-snapshot size (min/max/avg)    : 0 / 0 / 0
  delta size (min/max/avg)             : 0 / 0 / 0
  $ hg debugrevlog a
  format : 1
  flags  : inline, generaldelta
  
  revisions     : 1
      merges    : 0 ( 0.00%)
      normal    : 1 (100.00%)
  revisions     : 1
      empty     : 0 ( 0.00%)
                     text  : 0 (100.00%)
                     delta : 0 (100.00%)
      snapshot  : 1 (100.00%)
        lvl-0   :       1 (100.00%)
      deltas    : 0 ( 0.00%)
  revision size : 3
      snapshot  : 3 (100.00%)
        lvl-0   :       3 (100.00%)
      deltas    : 0 ( 0.00%)
  
  chunks        : 1
      0x75 (u)  : 1 (100.00%)
  chunks size   : 3
      0x75 (u)  : 3 (100.00%)
  
  
  total-stored-content: 2 bytes
  
  avg chain length  : 0
  max chain length  : 0
  max chain reach   : 3
  compression ratio : 0
  
  uncompressed data size (min/max/avg) : 2 / 2 / 2
  full revision size (min/max/avg)     : 3 / 3 / 3
  inter-snapshot size (min/max/avg)    : 0 / 0 / 0
  delta size (min/max/avg)             : 0 / 0 / 0

Test debugindex, with and without the --verbose/--debug flag
  $ hg debugrevlogindex a
     rev linkrev nodeid       p1           p2
       0       0 b789fdd96dc2 000000000000 000000000000

  $ hg --verbose debugrevlogindex a
     rev    offset  length linkrev nodeid       p1           p2
       0         0       3       0 b789fdd96dc2 000000000000 000000000000

  $ hg --debug debugrevlogindex a
     rev    offset  length linkrev nodeid                                   p1                                       p2
       0         0       3       0 b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3 0000000000000000000000000000000000000000 0000000000000000000000000000000000000000

  $ hg debugrevlogindex -f 1 a
     rev flag     size   link     p1     p2       nodeid
       0 0000        2      0     -1     -1 b789fdd96dc2

  $ hg --verbose debugrevlogindex -f 1 a
     rev flag   offset   length     size   link     p1     p2       nodeid
       0 0000        0        3        2      0     -1     -1 b789fdd96dc2

  $ hg --debug debugrevlogindex -f 1 a
     rev flag   offset   length     size   link     p1     p2                                   nodeid
       0 0000        0        3        2      0     -1     -1 b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3

  $ hg debugindex -c
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 07f494440405 000000000000 000000000000
       1       1 8cccb4b5fec2 07f494440405 000000000000
       2       2 b1e228c512c5 8cccb4b5fec2 000000000000
  $ hg debugindex -c --debug
     rev   rank linkrev                                   nodeid p1-rev                                p1-nodeid p2-rev                                p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 07f4944404050f47db2e5c5071e0e84e7a27bba9     -1 0000000000000000000000000000000000000000     -1 0000000000000000000000000000000000000000                   57          0     0         2                    0         58       inline                    0             0
       1     -1       1 8cccb4b5fec20cafeb99dd01c26d4dee8ea4388a      0 07f4944404050f47db2e5c5071e0e84e7a27bba9     -1 0000000000000000000000000000000000000000                   66          1     0         2                   58         67       inline                    0             0
       2     -1       2 b1e228c512c5d7066d70562ed839c3323a62d6d2      1 8cccb4b5fec20cafeb99dd01c26d4dee8ea4388a     -1 0000000000000000000000000000000000000000                   65          2     0         2                  125         66       inline                    0             0
  $ hg debugindex -m
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 a0c8bcbbb45c 000000000000 000000000000
       1       1 57faf8a737ae a0c8bcbbb45c 000000000000
       2       2 a35b10320954 57faf8a737ae 000000000000
  $ hg debugindex -m --debug
     rev   rank linkrev                                   nodeid p1-rev                                p1-nodeid p2-rev                                p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 a0c8bcbbb45c63b90b70ad007bf38961f64f2af0     -1 0000000000000000000000000000000000000000     -1 0000000000000000000000000000000000000000                   43          0     0         2                    0         44       inline                    0             0
       1     -1       1 57faf8a737ae7faf490582941a82319ba6529dca      0 a0c8bcbbb45c63b90b70ad007bf38961f64f2af0     -1 0000000000000000000000000000000000000000                    0          1     0         2                   44          0       inline                    0             0
       2     -1       2 a35b103209548032201c16c7688cb2657f037a38      1 57faf8a737ae7faf490582941a82319ba6529dca     -1 0000000000000000000000000000000000000000                   43          2     0         2                   44         44       inline                    0             0
  $ hg debugindex a
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 b789fdd96dc2 000000000000 000000000000
  $ hg debugindex --debug a
     rev   rank linkrev                                   nodeid p1-rev                                p1-nodeid p2-rev                                p2-nodeid            full-size delta-base flags comp-mode          data-offset chunk-size sd-comp-mode      sidedata-offset sd-chunk-size
       0     -1       0 b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3     -1 0000000000000000000000000000000000000000     -1 0000000000000000000000000000000000000000                    2          0     0         2                    0          3       inline                    0             0

debugdelta chain basic output

#if no-pure no-rust
  $ hg debugindexstats
  node trie capacity: 4
  node trie count: 2
  node trie depth: 1
  node trie last rev scanned: -1 (no-rust !)
  node trie last rev scanned: 3 (rust !)
  node trie lookups: 3 (no-rust !)
  node trie lookups: 2 (rust !)
  node trie misses: 1
  node trie splits: 1
  revs in memory: 3
#else
  $ hg debugindexstats
  abort: debugindexstats only works with native C code
  [255]
#endif

#if no-pure
  $ hg debugdeltachain -m --all-info
      rev      p1      p2  chain# chainlen     prev   delta       size    rawsize  chainsize     ratio   lindist extradist extraratio   readsize largestblk rddensity srchunks
        0      -1      -1       1        1       -1    base         44         43         44   1.02326        44         0    0.00000         44         44   1.00000        1
        1       0      -1       2        1       -1    base          0          0          0   0.00000         0         0    0.00000          0          0   1.00000        1
        2       1      -1       3        1       -1    base         44         43         44   1.02326        44         0    0.00000         44         44   1.00000        1

  $ hg debugdeltachain -m -T '{rev} {chainid} {chainlen}\n'
  0 1 1
  1 2 1
  2 3 1

  $ hg debugdeltachain -m -Tjson  --size-info
  [
   {
    "chainid": 1,
    "chainlen": 1,
    "chainratio": 1.0232558139534884,
    "chainsize": 44,
    "compsize": 44,
    "deltatype": "base",
    "p1": -1,
    "p2": -1,
    "prevrev": -1,
    "rev": 0,
    "uncompsize": 43
   },
   {
    "chainid": 2,
    "chainlen": 1,
    "chainratio": 0,
    "chainsize": 0,
    "compsize": 0,
    "deltatype": "base",
    "p1": 0,
    "p2": -1,
    "prevrev": -1,
    "rev": 1,
    "uncompsize": 0
   },
   {
    "chainid": 3,
    "chainlen": 1,
    "chainratio": 1.0232558139534884,
    "chainsize": 44,
    "compsize": 44,
    "deltatype": "base",
    "p1": 1,
    "p2": -1,
    "prevrev": -1,
    "rev": 2,
    "uncompsize": 43
   }
  ]

  $ hg debugdeltachain -m -Tjson  --all-info
  [
   {
    "chainid": 1,
    "chainlen": 1,
    "chainratio": 1.0232558139534884,
    "chainsize": 44,
    "compsize": 44,
    "deltatype": "base",
    "extradist": 0,
    "extraratio": 0.0,
    "largestblock": 44,
    "lindist": 44,
    "p1": -1,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1.0,
    "readsize": 44,
    "rev": 0,
    "srchunks": 1,
    "uncompsize": 43
   },
   {
    "chainid": 2,
    "chainlen": 1,
    "chainratio": 0,
    "chainsize": 0,
    "compsize": 0,
    "deltatype": "base",
    "extradist": 0,
    "extraratio": 0,
    "largestblock": 0,
    "lindist": 0,
    "p1": 0,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1,
    "readsize": 0,
    "rev": 1,
    "srchunks": 1,
    "uncompsize": 0
   },
   {
    "chainid": 3,
    "chainlen": 1,
    "chainratio": 1.0232558139534884,
    "chainsize": 44,
    "compsize": 44,
    "deltatype": "base",
    "extradist": 0,
    "extraratio": 0.0,
    "largestblock": 44,
    "lindist": 44,
    "p1": 1,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1.0,
    "readsize": 44,
    "rev": 2,
    "srchunks": 1,
    "uncompsize": 43
   }
  ]

debugdelta chain with sparse read enabled

  $ cat >> $HGRCPATH <<EOF
  > [experimental]
  > sparse-read = True
  > EOF
  $ hg debugdeltachain -m --all-info
      rev      p1      p2  chain# chainlen     prev   delta       size    rawsize  chainsize     ratio   lindist extradist extraratio   readsize largestblk rddensity srchunks
        0      -1      -1       1        1       -1    base         44         43         44   1.02326        44         0    0.00000         44         44   1.00000        1
        1       0      -1       2        1       -1    base          0          0          0   0.00000         0         0    0.00000          0          0   1.00000        1
        2       1      -1       3        1       -1    base         44         43         44   1.02326        44         0    0.00000         44         44   1.00000        1

  $ hg debugdeltachain -m --sparse-info -T '{rev} {chainid} {chainlen} {readsize} {largestblock} {readdensity}\n'
  0 1 1 44 44 1.0
  1 2 1 0 0 1
  2 3 1 44 44 1.0

  $ hg debugdeltachain -m -Tjson --sparse-info
  [
   {
    "chainid": 1,
    "chainlen": 1,
    "deltatype": "base",
    "largestblock": 44,
    "p1": -1,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1.0,
    "readsize": 44,
    "rev": 0,
    "srchunks": 1
   },
   {
    "chainid": 2,
    "chainlen": 1,
    "deltatype": "base",
    "largestblock": 0,
    "p1": 0,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1,
    "readsize": 0,
    "rev": 1,
    "srchunks": 1
   },
   {
    "chainid": 3,
    "chainlen": 1,
    "deltatype": "base",
    "largestblock": 44,
    "p1": 1,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1.0,
    "readsize": 44,
    "rev": 2,
    "srchunks": 1
   }
  ]

  $ hg debugdeltachain -m -Tjson --all-info
  [
   {
    "chainid": 1,
    "chainlen": 1,
    "chainratio": 1.0232558139534884,
    "chainsize": 44,
    "compsize": 44,
    "deltatype": "base",
    "extradist": 0,
    "extraratio": 0.0,
    "largestblock": 44,
    "lindist": 44,
    "p1": -1,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1.0,
    "readsize": 44,
    "rev": 0,
    "srchunks": 1,
    "uncompsize": 43
   },
   {
    "chainid": 2,
    "chainlen": 1,
    "chainratio": 0,
    "chainsize": 0,
    "compsize": 0,
    "deltatype": "base",
    "extradist": 0,
    "extraratio": 0,
    "largestblock": 0,
    "lindist": 0,
    "p1": 0,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1,
    "readsize": 0,
    "rev": 1,
    "srchunks": 1,
    "uncompsize": 0
   },
   {
    "chainid": 3,
    "chainlen": 1,
    "chainratio": 1.0232558139534884,
    "chainsize": 44,
    "compsize": 44,
    "deltatype": "base",
    "extradist": 0,
    "extraratio": 0.0,
    "largestblock": 44,
    "lindist": 44,
    "p1": 1,
    "p2": -1,
    "prevrev": -1,
    "readdensity": 1.0,
    "readsize": 44,
    "rev": 2,
    "srchunks": 1,
    "uncompsize": 43
   }
  ]

  $ printf "This test checks things.\n" >> a
  $ hg ci -m a
  $ hg branch other
  marked working directory as branch other
  (branches are permanent and global, did you want a bookmark?)
  $ for i in `$TESTDIR/seq.py 5`; do
  >   printf "shorter ${i}" >> a
  >   hg ci -m "a other:$i"
  >   hg up -q default
  >   printf "for the branch default we want longer chains: ${i}" >> a
  >   hg ci -m "a default:$i"
  >   hg up -q other
  > done
  $ hg debugdeltachain a -T '{rev} {srchunks}\n'  --all-info\
  >    --config experimental.sparse-read.density-threshold=0.50 \
  >    --config experimental.sparse-read.min-gap-size=0
  0 1
  1 1
  2 1
  3 1
  4 1
  5 1
  6 1
  7 1
  8 1
  9 1
  10 2 (no-zstd !)
  10 1 (zstd !)
  11 1
  $ hg --config extensions.strip= strip --no-backup -r 1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test max chain len
  $ cat >> $HGRCPATH << EOF
  > [format]
  > maxchainlen=4
  > EOF

  $ printf "This test checks if maxchainlen config value is respected also it can serve as basic test for debugrevlog -d <file>.\n" >> a
  $ hg ci -m a
  $ printf "b\n" >> a
  $ hg ci -m a
  $ printf "c\n" >> a
  $ hg ci -m a
  $ printf "d\n" >> a
  $ hg ci -m a
  $ printf "e\n" >> a
  $ hg ci -m a
  $ printf "f\n" >> a
  $ hg ci -m a
  $ printf 'g\n' >> a
  $ hg ci -m a
  $ printf 'h\n' >> a
  $ hg ci -m a

  $ hg debugrevlog -d a
  # rev p1rev p2rev start   end deltastart base   p1   p2 rawsize totalsize compression heads chainlen
      0    -1    -1     0   ???          0    0    0    0     ???      ????           ?     1        0 (glob)
      1     0    -1   ???   ???          0    0    0    0     ???      ????           ?     1        1 (glob)
      2     1    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        2 (glob)
      3     2    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        3 (glob)
      4     3    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        4 (glob)
      5     4    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        0 (glob)
      6     5    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        1 (glob)
      7     6    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        2 (glob)
      8     7    -1   ???   ???        ???  ???  ???    0     ???      ????           ?     1        3 (glob)
#endif

Test debuglocks command:

  $ hg debuglocks
  lock:  free
  wlock: free

* Test setting the lock

  $ dolock() {
  >     {
  >         "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/unlock
  >         rm -f .hg/unlock
  >         echo y
  >     } | hg debuglocks "$@" > /dev/null
  > }
  $ dolock -s &
  $ "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/store/lock

  $ hg debuglocks
  lock:  user *, process * (*s) (glob)
  wlock: free
  [1]
  $ touch .hg/unlock
  $ wait
  $ [ -f .hg/store/lock ] || echo "There is no lock"
  There is no lock

* Test setting the wlock

  $ dolock -S &
  $ "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/wlock

  $ hg debuglocks
  lock:  free
  wlock: user *, process * (*s) (glob)
  [1]
  $ touch .hg/unlock
  $ wait
  $ [ -f .hg/wlock ] || echo "There is no wlock"
  There is no wlock

* Test setting both locks

  $ dolock -Ss &
  $ "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/wlock
  $ "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/store/lock

  $ hg debuglocks
  lock:  user *, process * (*s) (glob)
  wlock: user *, process * (*s) (glob)
  [2]

* Test failing to set a lock

  $ hg debuglocks -s
  abort: lock is already held
  [255]

  $ hg debuglocks -S
  abort: wlock is already held
  [255]

  $ touch .hg/unlock
  $ wait

  $ hg debuglocks
  lock:  free
  wlock: free

* Test forcing the lock

  $ dolock -s &
  $ "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/store/lock

  $ hg debuglocks
  lock:  user *, process * (*s) (glob)
  wlock: free
  [1]

  $ hg debuglocks -L

  $ hg debuglocks
  lock:  free
  wlock: free

  $ touch .hg/unlock
  $ wait

* Test forcing the wlock

  $ dolock -S &
  $ "$RUNTESTDIR/testlib/wait-on-file" 5 .hg/wlock

  $ hg debuglocks
  lock:  free
  wlock: user *, process * (*s) (glob)
  [1]

  $ hg debuglocks -W

  $ hg debuglocks
  lock:  free
  wlock: free

  $ touch .hg/unlock
  $ wait

Test WdirUnsupported exception

  $ hg debugdata -c ffffffffffffffffffffffffffffffffffffffff
  abort: working directory revision cannot be specified
  [255]

Test cache warming command

  $ rm -rf .hg/cache/
  $ hg debugupdatecaches --debug
  updating the branch cache
  $ ls -r .hg/cache/*
  .hg/cache/tags2-served
  .hg/cache/tags2
  .hg/cache/rbc-revs-v2
  .hg/cache/rbc-names-v2
  .hg/cache/hgtagsfnodes1
  .hg/cache/branch2-served

Test debug::unbundle

  $ hg bundle --exact --rev tip foo.hg
  1 changesets found
  $ hg debug::unbundle foo.hg
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 0 changes to 1 files (no-pure !)

Test debugcolor

#if no-windows
  $ hg debugcolor --style --color always | grep -E 'mode|style|log\.'
  color mode: 'ansi'
  available style:
  \x1b[0;33mlog.changeset\x1b[0m:                      \x1b[0;33myellow\x1b[0m (esc)
#endif

  $ hg debugcolor --style --color never
  color mode: None
  available style:

  $ cd ..

Test internal debugstacktrace command

  $ cat > debugstacktrace.py << EOF
  > from mercurial import (
  >     util,
  > )
  > from mercurial.utils import (
  >     procutil,
  > )
  > def f():
  >     util.debugstacktrace(f=procutil.stdout)
  >     g()
  > def g():
  >     util.dst(b'hello from g\\n', skip=1)
  >     h()
  > def h():
  >     util.dst(b'hi ...\\nfrom h hidden in g', 1, depth=2)
  > f()
  > EOF
  $ "$PYTHON" debugstacktrace.py
  stacktrace at:
   *debugstacktrace.py:15 in * (glob)
   *debugstacktrace.py:8  in f (glob)
  hello from g at:
   *debugstacktrace.py:15 in * (glob)
   *debugstacktrace.py:9  in f (glob)
  hi ...
  from h hidden in g at:
   *debugstacktrace.py:9  in f (glob)
   *debugstacktrace.py:12 in g (glob)

Test debugcapabilities command:

  $ hg debugcapabilities ./debugrevlog/
  Main capabilities:
    branchmap
    $USUAL_BUNDLE2_CAPS$
    getbundle
    known
    lookup
    pushkey
    unbundle
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
    stream
      v2

Test debugpeer

  $ hg debugpeer ssh://user@dummy/debugrevlog
  url: ssh://user@dummy/debugrevlog
  local: no
  pushable: yes

#if rust

  $ hg --debug debugpeer ssh://user@dummy/debugrevlog
  running .* ".*[/\\]dummyssh" ['"]user@dummy['"] ['"]hg -R debugrevlog serve --stdio['"] (re)
  devel-peer-request: hello+between
  devel-peer-request:   pairs: 81 bytes
  sending hello command
  sending between command
  remote: 473
  remote: capabilities: batch branchmap $USUAL_BUNDLE2_CAPS$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=generaldelta,revlog-compression-zstd,revlogv1,sparserevlog unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  remote: 1
  devel-peer-request: protocaps
  devel-peer-request:   caps: * bytes (glob)
  sending protocaps command
  url: ssh://user@dummy/debugrevlog
  local: no
  pushable: yes

#endif

#if no-rust zstd

  $ hg --debug debugpeer ssh://user@dummy/debugrevlog
  running .* ".*[/\\]dummyssh" ['"]user@dummy['"] ['"]hg -R debugrevlog serve --stdio['"] (re)
  devel-peer-request: hello+between
  devel-peer-request:   pairs: 81 bytes
  sending hello command
  sending between command
  remote: 473
  remote: capabilities: batch branchmap $USUAL_BUNDLE2_CAPS$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=generaldelta,revlog-compression-zstd,revlogv1,sparserevlog unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  remote: 1
  devel-peer-request: protocaps
  devel-peer-request:   caps: * bytes (glob)
  sending protocaps command
  url: ssh://user@dummy/debugrevlog
  local: no
  pushable: yes

#endif

#if no-rust no-zstd

  $ hg --debug debugpeer ssh://user@dummy/debugrevlog
  running .* ".*[/\\]dummyssh" ['"]user@dummy['"] ['"]hg -R debugrevlog serve --stdio['"] (re)
  devel-peer-request: hello+between
  devel-peer-request:   pairs: 81 bytes
  sending hello command
  sending between command
  remote: 449
  remote: capabilities: batch branchmap $USUAL_BUNDLE2_CAPS$ changegroupsubset getbundle known lookup protocaps pushkey streamreqs=generaldelta,revlogv1,sparserevlog unbundle=HG10GZ,HG10BZ,HG10UN unbundlehash
  remote: 1
  devel-peer-request: protocaps
  devel-peer-request:   caps: * bytes (glob)
  sending protocaps command
  url: ssh://user@dummy/debugrevlog
  local: no
  pushable: yes

#endif

Test debugshell

  $ hg debugshell -c 'ui.write(b"%s\n" % ui.username())'
  test
