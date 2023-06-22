Force revlog max inline value to be smaller than default

  $ mkdir $TESTTMP/ext
  $ cat << EOF > $TESTTMP/ext/small_inline.py
  > from mercurial import revlog
  > revlog._maxinline = 8
  > EOF

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > small_inline=$TESTTMP/ext/small_inline.py
  > EOF

  $ hg init repo
  $ cd repo

Try on an empty repository

  $ hg debug-revlog-stats
  rev-count   data-size inl type      target 

  $ mkdir folder
  $ touch a b folder/c folder/d
  $ hg commit -Aqm 0
  $ echo "text" > a
  $ hg rm b
  $ echo "longer string" > folder/d
  $ hg commit -Aqm 1

Differences in data size observed with pure is due to different compression
algorithms

  $ hg debug-revlog-stats
  rev-count   data-size inl type      target 
          2         138 no  changelog  (no-pure !)
          2         137 no  changelog  (pure !)
          2         177 no  manifest   (no-pure !)
          2         168 no  manifest   (pure !)
          2           6 yes file      a
          1           0 yes file      b
          1           0 yes file      folder/c
          2          15 no  file      folder/d

Test 'changelog' command argument

  $ hg debug-revlog-stats -c
  rev-count   data-size inl type      target 
          2         138 no  changelog  (no-pure !)
          2         137 no  changelog  (pure !)

Test 'manifest' command argument

  $ hg debug-revlog-stats -m
  rev-count   data-size inl type      target 
          2         177 no  manifest   (no-pure !)
          2         168 no  manifest   (pure !)

Test 'file' command argument

  $ hg debug-revlog-stats -f
  rev-count   data-size inl type      target 
          2           6 yes file      a
          1           0 yes file      b
          1           0 yes file      folder/c
          2          15 no  file      folder/d

Test multiple command arguments

  $ hg debug-revlog-stats -cm
  rev-count   data-size inl type      target 
          2         138 no  changelog  (no-pure !)
          2         137 no  changelog  (pure !)
          2         177 no  manifest   (no-pure !)
          2         168 no  manifest   (pure !)

