#require unix-permissions no-root

#testcases dirstate-v1 dirstate-v2

#if dirstate-v2
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=1
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF
#endif

  $ hg init t
  $ cd t

  $ echo foo > a
  $ hg add a

  $ hg commit -m "1"

  $ hg verify -q

  $ chmod -r .hg/store/data/a.i

  $ hg verify -q
  abort: $EACCES$: '$TESTTMP/t/.hg/store/data/a.i'
  [255]

  $ chmod +r .hg/store/data/a.i

  $ hg verify -q

  $ chmod -w .hg/store/data/a.i

  $ echo barber > a
#if rust
  $ hg commit -m "2"
  abort: abort: when writing $TESTTMP/t/.hg/store/data/a.i: $EACCES$
  [50]
#else
  $ hg commit -m "2"
  trouble committing a!
  abort: $EACCES$: '$TESTTMP/t/.hg/store/data/a.i'
  [255]
#endif

  $ chmod -w .

  $ hg diff --nodates
  diff -r 2a18120dc1c9 a
  --- a/a
  +++ b/a
  @@ -1,1 +1,1 @@
  -foo
  +barber

  $ chmod +w .

  $ chmod +w .hg/store/data/a.i
  $ mkdir dir
  $ touch dir/a
  $ hg status
  M a
  ? dir/a
  $ chmod -rx dir

#if no-fsmonitor

(fsmonitor makes "hg status" avoid accessing to "dir")

  $ hg status
  dir: $EACCES$* (glob)
  M a

#endif

Reenable perm to allow deletion:

  $ chmod +rx dir

  $ cd ..
