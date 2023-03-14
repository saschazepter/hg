#testcases dirstate-v1 dirstate-v2

#if dirstate-v2
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=1
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF
#endif

  $ rm -rf r

  $ hg init r
  $ cd r
  $ mkdir d1
  $ mkdir d2
  $ touch d1/f d2/f
  $ hg commit -Am '.'
  adding d1/f
  adding d2/f
  $ echo 'syntax:re' >> .hgignore
  $ echo '^d1$' >> .hgignore
  $ hg commit -Am "ignore d1"
  adding .hgignore

Now d1 is a directory that's both committed and ignored.
Untracked files in d2 are still shown, but ones in d1 are ignored:

  $ touch d1/g
  $ touch d2/g
  $ RAYON_NUM_THREADS=1 hg status
  ? d2/g
