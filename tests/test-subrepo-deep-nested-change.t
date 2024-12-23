  $ cat >> $HGRCPATH <<EOF
  > [extdiff]
  > # for portability:
  > pdiff = sh "$RUNTESTDIR/pdiff"
  > [progress]
  > disable=False
  > assume-tty = 1
  > delay = 0
  > # set changedelay really large so we don't see nested topics
  > changedelay = 30000
  > format = topic bar number
  > refresh = 0
  > width = 60
  > EOF

Preparing the subrepository 'sub2'

  $ hg init sub2
  $ echo sub2 > sub2/sub2
  $ hg add -R sub2
  adding sub2/sub2
  $ hg commit -R sub2 -m "sub2 import"

Preparing the 'sub1' repo which depends on the subrepo 'sub2'

  $ hg init sub1
  $ echo sub1 > sub1/sub1
  $ echo "sub2 = ../sub2" > sub1/.hgsub
  $ hg clone sub2 sub1/sub2
  \r (no-eol) (esc)
  linking [=====>                                       ] 1/7\r (no-eol) (esc) (no-rust !)
  linking [===========>                                 ] 2/7\r (no-eol) (esc) (no-rust !)
  linking [==================>                          ] 3/7\r (no-eol) (esc) (no-rust !)
  linking [========================>                    ] 4/7\r (no-eol) (esc) (no-rust !)
  linking [===============================>             ] 5/7\r (no-eol) (esc) (no-rust !)
  linking [=====================================>       ] 6/7\r (no-eol) (esc) (no-rust !)
  linking [============================================>] 7/7\r (no-eol) (esc) (no-rust !)
  linking [====>                                        ] 1/9\r (no-eol) (esc) (rust !)
  linking [=========>                                   ] 2/9\r (no-eol) (esc) (rust !)
  linking [==============>                              ] 3/9\r (no-eol) (esc) (rust !)
  linking [===================>                         ] 4/9\r (no-eol) (esc) (rust !)
  linking [========================>                    ] 5/9\r (no-eol) (esc) (rust !)
  linking [=============================>               ] 6/9\r (no-eol) (esc) (rust !)
  linking [==================================>          ] 7/9\r (no-eol) (esc) (rust !)
  linking [=======================================>     ] 8/9\r (no-eol) (esc) (rust !)
  linking [============================================>] 9/9\r (no-eol) (esc) (rust !)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc) (no-rust !)
  updating [===========================================>] 1/1\r (no-eol) (esc) (no-rust !)
                                                              \r (no-eol) (esc) (no-rust !)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg add -R sub1
  adding sub1/.hgsub
  adding sub1/sub1
  $ hg commit -R sub1 -m "sub1 import"

Preparing the 'main' repo which depends on the subrepo 'sub1'

  $ hg init main
  $ echo main > main/main
  $ echo "sub1 = ../sub1" > main/.hgsub

#if rust
  $ hg clone sub1 main/sub1
  \r (no-eol) (esc)
  linking [==>                                        ]  1/11\r (no-eol) (esc)
  linking [======>                                    ]  2/11\r (no-eol) (esc)
  linking [==========>                                ]  3/11\r (no-eol) (esc)
  linking [==============>                            ]  4/11\r (no-eol) (esc)
  linking [==================>                        ]  5/11\r (no-eol) (esc)
  linking [======================>                    ]  6/11\r (no-eol) (esc)
  linking [==========================>                ]  7/11\r (no-eol) (esc)
  linking [==============================>            ]  8/11\r (no-eol) (esc)
  linking [==================================>        ]  9/11\r (no-eol) (esc)
  linking [======================================>    ] 10/11\r (no-eol) (esc)
  linking [==========================================>] 11/11\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  linking [====>                                        ] 1/9\r (no-eol) (esc)
  linking [=========>                                   ] 2/9\r (no-eol) (esc)
  linking [==============>                              ] 3/9\r (no-eol) (esc)
  linking [===================>                         ] 4/9\r (no-eol) (esc)
  linking [========================>                    ] 5/9\r (no-eol) (esc)
  linking [=============================>               ] 6/9\r (no-eol) (esc)
  linking [==================================>          ] 7/9\r (no-eol) (esc)
  linking [=======================================>     ] 8/9\r (no-eol) (esc)
  linking [============================================>] 9/9\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  updating to branch default
  cloning subrepo sub2 from $TESTTMP/sub2
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#else
  $ hg clone sub1 main/sub1
  \r (no-eol) (esc)
  linking [====>                                        ] 1/9\r (no-eol) (esc)
  linking [=========>                                   ] 2/9\r (no-eol) (esc)
  linking [==============>                              ] 3/9\r (no-eol) (esc)
  linking [===================>                         ] 4/9\r (no-eol) (esc)
  linking [========================>                    ] 5/9\r (no-eol) (esc)
  linking [=============================>               ] 6/9\r (no-eol) (esc)
  linking [==================================>          ] 7/9\r (no-eol) (esc)
  linking [=======================================>     ] 8/9\r (no-eol) (esc)
  linking [============================================>] 9/9\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  linking [=====>                                       ] 1/7\r (no-eol) (esc)
  linking [===========>                                 ] 2/7\r (no-eol) (esc)
  linking [==================>                          ] 3/7\r (no-eol) (esc)
  linking [========================>                    ] 4/7\r (no-eol) (esc)
  linking [===============================>             ] 5/7\r (no-eol) (esc)
  linking [=====================================>       ] 6/7\r (no-eol) (esc)
  linking [============================================>] 7/7\r (no-eol) (esc)
  updating [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  updating to branch default
  cloning subrepo sub2 from $TESTTMP/sub2
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#endif
  $ hg add -R main
  adding main/.hgsub
  adding main/main
  $ hg commit -R main -m "main import"

#if serve

Unfortunately, subrepos not at their nominal location cannot be cloned.  But
they are still served from their location within the local repository.  The only
reason why 'main' can be cloned via the filesystem is because 'sub1' and 'sub2'
are also available as siblings of 'main'.

  $ hg serve -R main --debug -S -p $HGPORT -d --pid-file=hg1.pid -E error.log -A access.log
  adding  = $TESTTMP/main
  adding sub1 = $TESTTMP/main/sub1
  adding sub1/sub2 = $TESTTMP/main/sub1/sub2
  listening at http://*:$HGPORT/ (bound to *:$HGPORT) (glob) (?)
  adding  = $TESTTMP/main (?)
  adding sub1 = $TESTTMP/main/sub1 (?)
  adding sub1/sub2 = $TESTTMP/main/sub1/sub2 (?)
  $ cat hg1.pid >> $DAEMON_PIDS

  $ hg clone http://localhost:$HGPORT httpclone --config progress.disable=True
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 3 changes to 3 files
  new changesets 7f491f53a367
  updating to branch default
  cloning subrepo sub1 from http://localhost:$HGPORT/../sub1
  abort: HTTP Error 404: Not Found
  [100]

  $ cat access.log
  * "GET /?cmd=capabilities HTTP/1.1" 200 - (glob)
  * "GET /?cmd=batch HTTP/1.1" 200 - * (glob)
  * "GET /?cmd=getbundle HTTP/1.1" 200 - * (glob)
  * "GET /../sub1?cmd=capabilities HTTP/1.1" 404 - (glob)
  $ cat error.log

  $ killdaemons.py
  $ rm hg1.pid error.log access.log
#endif

Cleaning both repositories, just as a clone -U

  $ hg up -C -R sub2 null
  \r (no-eol) (esc)
  updating [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg up -C -R sub1 null
  \r (no-eol) (esc)
  updating [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg up -C -R main null
  \r (no-eol) (esc)
  updating [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ rm -rf main/sub1
  $ rm -rf sub1/sub2

Clone main

#if rust
  $ hg --config extensions.largefiles= clone main cloned
  \r (no-eol) (esc)
  linking [====>                                        ] 1/9\r (no-eol) (esc) (no-rust !)
  linking [=========>                                   ] 2/9\r (no-eol) (esc) (no-rust !)
  linking [==============>                              ] 3/9\r (no-eol) (esc) (no-rust !)
  linking [===================>                         ] 4/9\r (no-eol) (esc) (no-rust !)
  linking [========================>                    ] 5/9\r (no-eol) (esc) (no-rust !)
  linking [=============================>               ] 6/9\r (no-eol) (esc) (no-rust !)
  linking [==================================>          ] 7/9\r (no-eol) (esc) (no-rust !)
  linking [=======================================>     ] 8/9\r (no-eol) (esc) (no-rust !)
  linking [============================================>] 9/9\r (no-eol) (esc) (no-rust !)
  linking [==>                                        ]  1/11\r (no-eol) (esc) (rust !)
  linking [======>                                    ]  2/11\r (no-eol) (esc) (rust !)
  linking [==========>                                ]  3/11\r (no-eol) (esc) (rust !)
  linking [==============>                            ]  4/11\r (no-eol) (esc) (rust !)
  linking [==================>                        ]  5/11\r (no-eol) (esc) (rust !)
  linking [======================>                    ]  6/11\r (no-eol) (esc) (rust !)
  linking [==========================>                ]  7/11\r (no-eol) (esc) (rust !)
  linking [==============================>            ]  8/11\r (no-eol) (esc) (rust !)
  linking [==================================>        ]  9/11\r (no-eol) (esc) (rust !)
  linking [======================================>    ] 10/11\r (no-eol) (esc) (rust !)
  linking [==========================================>] 11/11\r (no-eol) (esc) (rust !)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  linking [==>                                        ]  1/11\r (no-eol) (esc)
  linking [======>                                    ]  2/11\r (no-eol) (esc)
  linking [==========>                                ]  3/11\r (no-eol) (esc)
  linking [==============>                            ]  4/11\r (no-eol) (esc)
  linking [==================>                        ]  5/11\r (no-eol) (esc)
  linking [======================>                    ]  6/11\r (no-eol) (esc)
  linking [==========================>                ]  7/11\r (no-eol) (esc)
  linking [==============================>            ]  8/11\r (no-eol) (esc)
  linking [==================================>        ]  9/11\r (no-eol) (esc)
  linking [======================================>    ] 10/11\r (no-eol) (esc)
  linking [==========================================>] 11/11\r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  linking [====>                                        ] 1/9\r (no-eol) (esc)
  linking [=========>                                   ] 2/9\r (no-eol) (esc)
  linking [==============>                              ] 3/9\r (no-eol) (esc)
  linking [===================>                         ] 4/9\r (no-eol) (esc)
  linking [========================>                    ] 5/9\r (no-eol) (esc)
  linking [=============================>               ] 6/9\r (no-eol) (esc)
  linking [==================================>          ] 7/9\r (no-eol) (esc)
  linking [=======================================>     ] 8/9\r (no-eol) (esc)
  linking [============================================>] 9/9\r (no-eol) (esc)
  updating [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  updating to branch default
  cloning subrepo sub1 from $TESTTMP/sub1
  cloning subrepo sub1/sub2 from $TESTTMP/sub2
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#else
  $ hg --config extensions.largefiles= clone main cloned
  \r (no-eol) (esc)
  linking [====>                                        ] 1/9\r (no-eol) (esc)
  linking [=========>                                   ] 2/9\r (no-eol) (esc)
  linking [==============>                              ] 3/9\r (no-eol) (esc)
  linking [===================>                         ] 4/9\r (no-eol) (esc)
  linking [========================>                    ] 5/9\r (no-eol) (esc)
  linking [=============================>               ] 6/9\r (no-eol) (esc)
  linking [==================================>          ] 7/9\r (no-eol) (esc)
  linking [=======================================>     ] 8/9\r (no-eol) (esc)
  linking [============================================>] 9/9\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  linking [====>                                        ] 1/9\r (no-eol) (esc)
  linking [=========>                                   ] 2/9\r (no-eol) (esc)
  linking [==============>                              ] 3/9\r (no-eol) (esc)
  linking [===================>                         ] 4/9\r (no-eol) (esc)
  linking [========================>                    ] 5/9\r (no-eol) (esc)
  linking [=============================>               ] 6/9\r (no-eol) (esc)
  linking [==================================>          ] 7/9\r (no-eol) (esc)
  linking [=======================================>     ] 8/9\r (no-eol) (esc)
  linking [============================================>] 9/9\r (no-eol) (esc)
  updating [===========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  linking [=====>                                       ] 1/7\r (no-eol) (esc)
  linking [===========>                                 ] 2/7\r (no-eol) (esc)
  linking [==================>                          ] 3/7\r (no-eol) (esc)
  linking [========================>                    ] 4/7\r (no-eol) (esc)
  linking [===============================>             ] 5/7\r (no-eol) (esc)
  linking [=====================================>       ] 6/7\r (no-eol) (esc)
  linking [============================================>] 7/7\r (no-eol) (esc)
  updating [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  updating to branch default
  cloning subrepo sub1 from $TESTTMP/sub1
  cloning subrepo sub1/sub2 from $TESTTMP/sub2
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
#endif

Largefiles is NOT enabled in the clone if the source repo doesn't require it
  $ hg debugrequires -R cloned | grep largefiles
  [1]

Checking cloned repo ids

  $ printf "cloned " ; hg id -R cloned
  cloned 7f491f53a367 tip
  $ printf "cloned/sub1 " ; hg id -R cloned/sub1
  cloned/sub1 fc3b4ce2696f tip
  $ printf "cloned/sub1/sub2 " ; hg id -R cloned/sub1/sub2
  cloned/sub1/sub2 c57a0840e3ba tip

debugsub output for main and sub1

  $ hg debugsub -R cloned
  path sub1
   source   ../sub1
   revision fc3b4ce2696f7741438c79207583768f2ce6b0dd
  $ hg debugsub -R cloned/sub1
  path sub2
   source   ../sub2
   revision c57a0840e3badd667ef3c3ef65471609acb2ba3c

Modifying deeply nested 'sub2'

  $ echo modified > cloned/sub1/sub2/sub2
  $ hg commit --subrepos -m "deep nested modif should trigger a commit" -R cloned
  committing subrepository sub1
  committing subrepository sub1/sub2

Checking modified node ids

  $ printf "cloned " ; hg id -R cloned
  cloned ffe6649062fe tip
  $ printf "cloned/sub1 " ; hg id -R cloned/sub1
  cloned/sub1 2ecb03bf44a9 tip
  $ printf "cloned/sub1/sub2 " ; hg id -R cloned/sub1/sub2
  cloned/sub1/sub2 53dd3430bcaf tip

debugsub output for main and sub1

  $ hg debugsub -R cloned
  path sub1
   source   ../sub1
   revision 2ecb03bf44a94e749e8669481dd9069526ce7cb9
  $ hg debugsub -R cloned/sub1
  path sub2
   source   ../sub2
   revision 53dd3430bcaf5ab4a7c48262bcad6d441f510487

Check that deep archiving works

  $ cd cloned
  $ echo 'test' > sub1/sub2/test.txt
  $ hg --config extensions.largefiles=! add sub1/sub2/test.txt
  $ mkdir sub1/sub2/folder
  $ echo 'subfolder' > sub1/sub2/folder/test.txt
  $ hg ci -ASm "add test.txt"
  adding sub1/sub2/folder/test.txt
  committing subrepository sub1
  committing subrepository sub1/sub2

  $ rm -r main
  $ hg archive -S -qr 'wdir()' ../wdir
  $ cat ../wdir/.hg_archival.txt
  repo: 7f491f53a367861f47ee64a80eb997d1f341b77a
  node: 9bb10eebee29dc0f1201dcf5977b811a540255fd+
  branch: default
  latesttag: null
  latesttagdistance: 4
  changessincelatesttag: 4
  $ hg update -Cq .

A deleted subrepo file is flagged as dirty, like the top level repo

  $ rm -r ../wdir sub1/sub2/folder/test.txt
  $ hg archive -S -qr 'wdir()' ../wdir
  $ cat ../wdir/.hg_archival.txt
  repo: 7f491f53a367861f47ee64a80eb997d1f341b77a
  node: 9bb10eebee29dc0f1201dcf5977b811a540255fd+
  branch: default
  latesttag: null
  latesttagdistance: 4
  changessincelatesttag: 4
  $ hg update -Cq .
  $ rm -r ../wdir

  $ hg archive -S -qr 'wdir()' ../wdir \
  >            --config 'experimental.archivemetatemplate=archived {node|short}\n'
  $ cat ../wdir/.hg_archival.txt
  archived ffffffffffff
  $ rm -r ../wdir

.. but first take a detour through some deep removal testing

  $ hg remove -S -I 're:.*.txt' .
  \r (no-eol) (esc)
  searching [==========================================>] 1/1\r (no-eol) (esc)
  searching [==========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [=====================>                      ] 1/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  removing sub1/sub2/folder/test.txt
  removing sub1/sub2/test.txt
  $ hg status -S
  R sub1/sub2/folder/test.txt
  R sub1/sub2/test.txt
  $ hg update -Cq
  $ hg remove -I 're:.*.txt' sub1
  \r (no-eol) (esc)
  searching [==========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ hg status -S
  $ hg remove sub1/sub2/folder/test.txt
  \r (no-eol) (esc)
  searching [==========================================>] 1/1\r (no-eol) (esc)
  searching [==========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ hg remove sub1/.hgsubstate
  \r (no-eol) (esc)
  searching [==========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ mv sub1/.hgsub sub1/x.hgsub
  $ hg status -S
  warning: subrepo spec file 'sub1/.hgsub' not found
  R sub1/.hgsubstate
  R sub1/sub2/folder/test.txt
  ! sub1/.hgsub
  ? sub1/x.hgsub
  $ hg status -R sub1
  warning: subrepo spec file 'sub1/.hgsub' not found
  R .hgsubstate
  ! .hgsub
  ? x.hgsub
  $ mv sub1/x.hgsub sub1/.hgsub
  $ hg update -Cq
  $ touch sub1/foo
  $ hg forget sub1/sub2/folder/test.txt
  $ rm sub1/sub2/test.txt

Test relative path printing + subrepos
  $ mkdir -p foo/bar
  $ cd foo
  $ touch bar/abc
  $ hg addremove -S ..
  \r (no-eol) (esc)
  searching for exact renames [========================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  adding ../sub1/sub2/folder/test.txt
  removing ../sub1/sub2/test.txt
  adding ../sub1/foo
  adding bar/abc
  $ cd ..
  $ hg status -S
  A foo/bar/abc
  A sub1/foo
  R sub1/sub2/test.txt

Archive wdir() with subrepos
  $ hg rm main
  \r (no-eol) (esc)
  deleting [===========================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ hg archive -S -r 'wdir()' ../wdir
  \r (no-eol) (esc)
  archiving [                                           ] 0/3\r (no-eol) (esc)
  archiving [=============>                             ] 1/3\r (no-eol) (esc)
  archiving [===========================>               ] 2/3\r (no-eol) (esc)
  archiving [==========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/4\r (no-eol) (esc)
  archiving (sub1) [========>                           ] 1/4\r (no-eol) (esc)
  archiving (sub1) [=================>                  ] 2/4\r (no-eol) (esc)
  archiving (sub1) [==========================>         ] 3/4\r (no-eol) (esc)
  archiving (sub1) [===================================>] 4/4\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/2\r (no-eol) (esc)
  archiving (sub1/sub2) [==============>                ] 1/2\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ diff -r . ../wdir | grep -E -v '\.hg$|^Common subdirectories:'
  Only in ../wdir: .hg_archival.txt

  $ find ../wdir -type f | sort
  ../wdir/.hg_archival.txt
  ../wdir/.hgsub
  ../wdir/.hgsubstate
  ../wdir/foo/bar/abc
  ../wdir/sub1/.hgsub
  ../wdir/sub1/.hgsubstate
  ../wdir/sub1/foo
  ../wdir/sub1/sub1
  ../wdir/sub1/sub2/folder/test.txt
  ../wdir/sub1/sub2/sub2

  $ cat ../wdir/.hg_archival.txt
  repo: 7f491f53a367861f47ee64a80eb997d1f341b77a
  node: 9bb10eebee29dc0f1201dcf5977b811a540255fd+
  branch: default
  latesttag: null
  latesttagdistance: 4
  changessincelatesttag: 4

Attempting to archive 'wdir()' with a missing file is handled gracefully
  $ rm sub1/sub1
  $ rm -r ../wdir
  $ hg archive -v -S -r 'wdir()' ../wdir
  \r (no-eol) (esc)
  archiving [                                           ] 0/3\r (no-eol) (esc)
  archiving [=============>                             ] 1/3\r (no-eol) (esc)
  archiving [===========================>               ] 2/3\r (no-eol) (esc)
  archiving [==========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/3\r (no-eol) (esc)
  archiving (sub1) [===========>                        ] 1/3\r (no-eol) (esc)
  archiving (sub1) [=======================>            ] 2/3\r (no-eol) (esc)
  archiving (sub1) [===================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/2\r (no-eol) (esc)
  archiving (sub1/sub2) [==============>                ] 1/2\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ find ../wdir -type f | sort
  ../wdir/.hg_archival.txt
  ../wdir/.hgsub
  ../wdir/.hgsubstate
  ../wdir/foo/bar/abc
  ../wdir/sub1/.hgsub
  ../wdir/sub1/.hgsubstate
  ../wdir/sub1/foo
  ../wdir/sub1/sub2/folder/test.txt
  ../wdir/sub1/sub2/sub2

Continue relative path printing + subrepos
  $ hg update -Cq
  $ rm -r ../wdir
  $ hg archive -S -r 'wdir()' ../wdir
  \r (no-eol) (esc)
  archiving [                                           ] 0/3\r (no-eol) (esc)
  archiving [=============>                             ] 1/3\r (no-eol) (esc)
  archiving [===========================>               ] 2/3\r (no-eol) (esc)
  archiving [==========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/3\r (no-eol) (esc)
  archiving (sub1) [===========>                        ] 1/3\r (no-eol) (esc)
  archiving (sub1) [=======================>            ] 2/3\r (no-eol) (esc)
  archiving (sub1) [===================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/3\r (no-eol) (esc)
  archiving (sub1/sub2) [=========>                     ] 1/3\r (no-eol) (esc)
  archiving (sub1/sub2) [===================>           ] 2/3\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ cat ../wdir/.hg_archival.txt
  repo: 7f491f53a367861f47ee64a80eb997d1f341b77a
  node: 9bb10eebee29dc0f1201dcf5977b811a540255fd
  branch: default
  latesttag: null
  latesttagdistance: 4
  changessincelatesttag: 4

  $ touch sub1/sub2/folder/bar
  $ hg addremove sub1/sub2
  adding sub1/sub2/folder/bar
  $ hg status -S
  A sub1/sub2/folder/bar
  ? foo/bar/abc
  ? sub1/foo
  $ hg update -Cq
  $ hg addremove sub1
  adding sub1/sub2/folder/bar
  adding sub1/foo
  $ hg update -Cq
  $ rm sub1/sub2/folder/test.txt
  $ rm sub1/sub2/test.txt
  $ hg ci -ASm "remove test.txt"
  adding sub1/sub2/folder/bar
  removing sub1/sub2/folder/test.txt
  removing sub1/sub2/test.txt
  adding sub1/foo
  adding foo/bar/abc
  committing subrepository sub1
  committing subrepository sub1/sub2

  $ hg forget sub1/sub2/sub2
  $ echo x > sub1/sub2/x.txt
  $ hg add sub1/sub2/x.txt

Files sees uncommitted adds and removes in subrepos
  $ hg files -S
  .hgsub
  .hgsubstate
  foo/bar/abc
  main
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/foo
  sub1/sub1
  sub1/sub2/folder/bar
  sub1/sub2/x.txt

  $ hg files -S "set:eol('dos') or eol('unix') or size('<= 0')"
  .hgsub
  .hgsubstate
  foo/bar/abc
  main
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/foo
  sub1/sub1
  sub1/sub2/folder/bar
  sub1/sub2/x.txt

  $ hg files -r '.^' -S "set:eol('dos') or eol('unix')"
  .hgsub
  .hgsubstate
  main
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/sub1
  sub1/sub2/folder/test.txt
  sub1/sub2/sub2
  sub1/sub2/test.txt

  $ hg files sub1
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/foo
  sub1/sub1
  sub1/sub2/folder/bar
  sub1/sub2/x.txt

  $ hg files sub1/sub2
  sub1/sub2/folder/bar
  sub1/sub2/x.txt

  $ hg files
  .hgsub
  .hgsubstate
  foo/bar/abc
  main

  $ hg files -S -r '.^' sub1/sub2/folder
  sub1/sub2/folder/test.txt

  $ hg files -S -r '.^' sub1/sub2/missing
  sub1/sub2/missing: no such file in rev 78026e779ea6
  [1]

  $ hg files -r '.^' sub1/
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/sub1
  sub1/sub2/folder/test.txt
  sub1/sub2/sub2
  sub1/sub2/test.txt

  $ hg files -r '.^' sub1/sub2
  sub1/sub2/folder/test.txt
  sub1/sub2/sub2
  sub1/sub2/test.txt

  $ hg rollback -q
  $ hg up -Cq

  $ hg --config extensions.largefiles=! archive -S ../archive_all
  \r (no-eol) (esc)
  archiving [                                           ] 0/3\r (no-eol) (esc)
  archiving [=============>                             ] 1/3\r (no-eol) (esc)
  archiving [===========================>               ] 2/3\r (no-eol) (esc)
  archiving [==========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/3\r (no-eol) (esc)
  archiving (sub1) [===========>                        ] 1/3\r (no-eol) (esc)
  archiving (sub1) [=======================>            ] 2/3\r (no-eol) (esc)
  archiving (sub1) [===================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/3\r (no-eol) (esc)
  archiving (sub1/sub2) [=========>                     ] 1/3\r (no-eol) (esc)
  archiving (sub1/sub2) [===================>           ] 2/3\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ find ../archive_all | sort
  ../archive_all
  ../archive_all/.hg_archival.txt
  ../archive_all/.hgsub
  ../archive_all/.hgsubstate
  ../archive_all/main
  ../archive_all/sub1
  ../archive_all/sub1/.hgsub
  ../archive_all/sub1/.hgsubstate
  ../archive_all/sub1/sub1
  ../archive_all/sub1/sub2
  ../archive_all/sub1/sub2/folder
  ../archive_all/sub1/sub2/folder/test.txt
  ../archive_all/sub1/sub2/sub2
  ../archive_all/sub1/sub2/test.txt

Check that archive -X works in deep subrepos

  $ hg --config extensions.largefiles=! archive -S -X '**test*' ../archive_exclude
  \r (no-eol) (esc)
  archiving [                                           ] 0/3\r (no-eol) (esc)
  archiving [=============>                             ] 1/3\r (no-eol) (esc)
  archiving [===========================>               ] 2/3\r (no-eol) (esc)
  archiving [==========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/3\r (no-eol) (esc)
  archiving (sub1) [===========>                        ] 1/3\r (no-eol) (esc)
  archiving (sub1) [=======================>            ] 2/3\r (no-eol) (esc)
  archiving (sub1) [===================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/1\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ find ../archive_exclude | sort
  ../archive_exclude
  ../archive_exclude/.hg_archival.txt
  ../archive_exclude/.hgsub
  ../archive_exclude/.hgsubstate
  ../archive_exclude/main
  ../archive_exclude/sub1
  ../archive_exclude/sub1/.hgsub
  ../archive_exclude/sub1/.hgsubstate
  ../archive_exclude/sub1/sub1
  ../archive_exclude/sub1/sub2
  ../archive_exclude/sub1/sub2/sub2

  $ hg --config extensions.largefiles=! archive -S -I '**test*' ../archive_include
  \r (no-eol) (esc)
  archiving (sub1) [ <=>                                  ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/2\r (no-eol) (esc)
  archiving (sub1/sub2) [==============>                ] 1/2\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ find ../archive_include | sort
  ../archive_include
  ../archive_include/sub1
  ../archive_include/sub1/sub2
  ../archive_include/sub1/sub2/folder
  ../archive_include/sub1/sub2/folder/test.txt
  ../archive_include/sub1/sub2/test.txt

Check that deep archive works with largefiles (which overrides hgsubrepo impl)
This also tests the repo.ui regression in 43fb170a23bd, and that lf subrepo
subrepos are archived properly.
Note that add --large through a subrepo currently adds the file as a normal file

  $ echo "large" > sub1/sub2/large.bin
  $ hg --config extensions.largefiles= add --large -R sub1/sub2 sub1/sub2/large.bin
  $ echo "large" > large.bin
  $ hg --config extensions.largefiles= add --large large.bin
  $ hg --config extensions.largefiles= ci -S -m "add large files"
  committing subrepository sub1
  committing subrepository sub1/sub2

  $ hg --config extensions.largefiles= archive -S ../archive_lf
  $ find ../archive_lf | sort
  ../archive_lf
  ../archive_lf/.hg_archival.txt
  ../archive_lf/.hgsub
  ../archive_lf/.hgsubstate
  ../archive_lf/large.bin
  ../archive_lf/main
  ../archive_lf/sub1
  ../archive_lf/sub1/.hgsub
  ../archive_lf/sub1/.hgsubstate
  ../archive_lf/sub1/sub1
  ../archive_lf/sub1/sub2
  ../archive_lf/sub1/sub2/folder
  ../archive_lf/sub1/sub2/folder/test.txt
  ../archive_lf/sub1/sub2/large.bin
  ../archive_lf/sub1/sub2/sub2
  ../archive_lf/sub1/sub2/test.txt
  $ rm -rf ../archive_lf

Exclude large files from main and sub-sub repo

  $ hg --config extensions.largefiles= archive -S -X '**.bin' ../archive_lf
  $ find ../archive_lf | sort
  ../archive_lf
  ../archive_lf/.hg_archival.txt
  ../archive_lf/.hgsub
  ../archive_lf/.hgsubstate
  ../archive_lf/main
  ../archive_lf/sub1
  ../archive_lf/sub1/.hgsub
  ../archive_lf/sub1/.hgsubstate
  ../archive_lf/sub1/sub1
  ../archive_lf/sub1/sub2
  ../archive_lf/sub1/sub2/folder
  ../archive_lf/sub1/sub2/folder/test.txt
  ../archive_lf/sub1/sub2/sub2
  ../archive_lf/sub1/sub2/test.txt
  $ rm -rf ../archive_lf

Exclude normal files from main and sub-sub repo

  $ hg --config extensions.largefiles= archive -S -X '**.txt' -p '.' ../archive_lf.tgz
  $ tar -tzf ../archive_lf.tgz | sort
  .hgsub
  .hgsubstate
  large.bin
  main
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/sub1
  sub1/sub2/large.bin
  sub1/sub2/sub2

Include normal files from within a largefiles subrepo

  $ hg --config extensions.largefiles= archive -S -I '**.txt' ../archive_lf
  $ find ../archive_lf | sort
  ../archive_lf
  ../archive_lf/.hg_archival.txt
  ../archive_lf/sub1
  ../archive_lf/sub1/sub2
  ../archive_lf/sub1/sub2/folder
  ../archive_lf/sub1/sub2/folder/test.txt
  ../archive_lf/sub1/sub2/test.txt
  $ rm -rf ../archive_lf

Include large files from within a largefiles subrepo

  $ hg --config extensions.largefiles= archive -S -I '**.bin' ../archive_lf
  $ find ../archive_lf | sort
  ../archive_lf
  ../archive_lf/large.bin
  ../archive_lf/sub1
  ../archive_lf/sub1/sub2
  ../archive_lf/sub1/sub2/large.bin
  $ rm -rf ../archive_lf

Find an exact largefile match in a largefiles subrepo

  $ hg --config extensions.largefiles= archive -S -I 'sub1/sub2/large.bin' ../archive_lf
  $ find ../archive_lf | sort
  ../archive_lf
  ../archive_lf/sub1
  ../archive_lf/sub1/sub2
  ../archive_lf/sub1/sub2/large.bin
  $ rm -rf ../archive_lf

The local repo enables largefiles if a largefiles repo is cloned

  $ hg showconfig extensions
  extensions.largefiles=

  $ hg --config extensions.largefiles= clone -qU . ../lfclone
  $ hg debugrequires -R ../lfclone | grep largefiles
  largefiles

Find an exact match to a standin (should archive nothing)
  $ hg --config extensions.largefiles= archive -S -I 'sub/sub2/.hglf/large.bin' ../archive_lf
  $ find ../archive_lf 2> /dev/null | sort

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > largefiles=
  > [largefiles]
  > patterns=glob:**.dat
  > EOF

Test forget through a deep subrepo with the largefiles extension, both a
largefile and a normal file.  Then a largefile that hasn't been committed yet.
  $ touch sub1/sub2/untracked.txt
  $ touch sub1/sub2/large.dat
  $ hg forget sub1/sub2/large.bin sub1/sub2/test.txt sub1/sub2/untracked.txt
  not removing sub1/sub2/untracked.txt: file is already untracked
  [1]
  $ hg add --large --dry-run -v sub1/sub2/untracked.txt
  adding sub1/sub2/untracked.txt as a largefile
  $ hg add --large -v sub1/sub2/untracked.txt
  adding sub1/sub2/untracked.txt as a largefile
  $ hg add --normal -v sub1/sub2/large.dat
  adding sub1/sub2/large.dat
  $ hg forget -v sub1/sub2/untracked.txt
  removing sub1/sub2/untracked.txt
  $ hg status -S
  A sub1/sub2/large.dat
  R sub1/sub2/large.bin
  R sub1/sub2/test.txt
  ? foo/bar/abc
  ? sub1/sub2/untracked.txt
  ? sub1/sub2/x.txt
  $ hg add sub1/sub2

  $ hg archive -S -r 'wdir()' ../wdir2
  $ diff -r . ../wdir2 | grep -E -v '\.hg$|^Common subdirectories:'
  Only in ../wdir2: .hg_archival.txt
  Only in .: .hglf
  Only in .: foo
  Only in ./sub1/sub2: large.bin
  Only in ./sub1/sub2: test.txt
  Only in ./sub1/sub2: untracked.txt
  Only in ./sub1/sub2: x.txt
  $ find ../wdir2 -type f | sort
  ../wdir2/.hg_archival.txt
  ../wdir2/.hgsub
  ../wdir2/.hgsubstate
  ../wdir2/large.bin
  ../wdir2/main
  ../wdir2/sub1/.hgsub
  ../wdir2/sub1/.hgsubstate
  ../wdir2/sub1/sub1
  ../wdir2/sub1/sub2/folder/test.txt
  ../wdir2/sub1/sub2/large.dat
  ../wdir2/sub1/sub2/sub2
  $ hg status -S -mac -n | sort
  .hgsub
  .hgsubstate
  large.bin
  main
  sub1/.hgsub
  sub1/.hgsubstate
  sub1/sub1
  sub1/sub2/folder/test.txt
  sub1/sub2/large.dat
  sub1/sub2/sub2

  $ hg ci -Sqm 'forget testing'

Test 'wdir()' modified file archiving with largefiles
  $ echo 'mod' > main
  $ echo 'mod' > large.bin
  $ echo 'mod' > sub1/sub2/large.dat
  $ hg archive -S -r 'wdir()' ../wdir3
  $ diff -r . ../wdir3 | grep -E -v '\.hg$|^Common subdirectories'
  Only in ../wdir3: .hg_archival.txt
  Only in .: .hglf
  Only in .: foo
  Only in ./sub1/sub2: large.bin
  Only in ./sub1/sub2: test.txt
  Only in ./sub1/sub2: untracked.txt
  Only in ./sub1/sub2: x.txt
  $ find ../wdir3 -type f | sort
  ../wdir3/.hg_archival.txt
  ../wdir3/.hgsub
  ../wdir3/.hgsubstate
  ../wdir3/large.bin
  ../wdir3/main
  ../wdir3/sub1/.hgsub
  ../wdir3/sub1/.hgsubstate
  ../wdir3/sub1/sub1
  ../wdir3/sub1/sub2/folder/test.txt
  ../wdir3/sub1/sub2/large.dat
  ../wdir3/sub1/sub2/sub2
  $ hg up -Cq

Test issue4330: commit a directory where only normal files have changed
  $ touch foo/bar/large.dat
  $ hg add --large foo/bar/large.dat
  $ hg ci -m 'add foo/bar/large.dat'
  $ touch a.txt
  $ touch a.dat
  $ hg add -v foo/bar/abc a.txt a.dat
  adding a.dat as a largefile
  adding a.txt
  adding foo/bar/abc
  $ hg ci -m 'dir commit with only normal file deltas' foo/bar
  $ hg status
  A a.dat
  A a.txt

Test a directory commit with a changed largefile and a changed normal file
  $ echo changed > foo/bar/large.dat
  $ echo changed > foo/bar/abc
  $ hg ci -m 'dir commit with normal and lf file deltas' foo
  $ hg status
  A a.dat
  A a.txt

  $ hg ci -m "add a.*"
  $ hg mv a.dat b.dat
  $ hg mv foo/bar/abc foo/bar/def
  $ hg status -C
  A b.dat
    a.dat
  A foo/bar/def
    foo/bar/abc
  R a.dat
  R foo/bar/abc

  $ hg ci -m "move large and normal"
  $ hg status -C --rev '.^' --rev .
  A b.dat
    a.dat
  A foo/bar/def
    foo/bar/abc
  R a.dat
  R foo/bar/abc


  $ echo foo > main
  $ hg ci -m "mod parent only"
  $ hg init sub3
  $ echo "sub3 = sub3" >> .hgsub
  $ echo xyz > sub3/a.txt
  $ hg add sub3/a.txt
  $ hg ci -Sm "add sub3"
  committing subrepository sub3
  $ cat .hgsub | grep -v sub3 > .hgsub1
  $ mv .hgsub1 .hgsub
  $ hg ci -m "remove sub3"

  $ hg log -r "subrepo()" --style compact
  0   7f491f53a367   1970-01-01 00:00 +0000   test
    main import
  
  1   ffe6649062fe   1970-01-01 00:00 +0000   test
    deep nested modif should trigger a commit
  
  2   9bb10eebee29   1970-01-01 00:00 +0000   test
    add test.txt
  
  3   7c64f035294f   1970-01-01 00:00 +0000   test
    add large files
  
  4   f734a59e2e35   1970-01-01 00:00 +0000   test
    forget testing
  
  11   9685a22af5db   1970-01-01 00:00 +0000   test
    add sub3
  
  12[tip]   2e0485b475b9   1970-01-01 00:00 +0000   test
    remove sub3
  
  $ hg log -r "subrepo('sub3')" --style compact
  11   9685a22af5db   1970-01-01 00:00 +0000   test
    add sub3
  
  12[tip]   2e0485b475b9   1970-01-01 00:00 +0000   test
    remove sub3
  
  $ hg log -r "subrepo('bogus')" --style compact


Test .hgsubstate in the R state

  $ hg rm .hgsub .hgsubstate
  \r (no-eol) (esc)
  deleting [=====================>                      ] 1/2\r (no-eol) (esc)
  deleting [===========================================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  $ hg ci -m 'trash subrepo tracking'

  $ hg log -r "subrepo('re:sub\d+')" --style compact
  0   7f491f53a367   1970-01-01 00:00 +0000   test
    main import
  
  1   ffe6649062fe   1970-01-01 00:00 +0000   test
    deep nested modif should trigger a commit
  
  2   9bb10eebee29   1970-01-01 00:00 +0000   test
    add test.txt
  
  3   7c64f035294f   1970-01-01 00:00 +0000   test
    add large files
  
  4   f734a59e2e35   1970-01-01 00:00 +0000   test
    forget testing
  
  11   9685a22af5db   1970-01-01 00:00 +0000   test
    add sub3
  
  12   2e0485b475b9   1970-01-01 00:00 +0000   test
    remove sub3
  
  13[tip]   a68b2c361653   1970-01-01 00:00 +0000   test
    trash subrepo tracking
  

Restore the trashed subrepo tracking

  $ hg rollback -q
  $ hg update -Cq .

Interaction with extdiff, largefiles and subrepos

  $ hg --config extensions.extdiff= pdiff -S

  $ hg --config extensions.extdiff= pdiff -r '.^' -S
  \r (no-eol) (esc)
  archiving [                                           ] 0/2\r (no-eol) (esc)
  archiving [====================>                      ] 1/2\r (no-eol) (esc)
  archiving [==========================================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [ <=>                                  ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [ <=>                             ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub3) [ <=>                                  ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving [                                           ] 0/2\r (no-eol) (esc)
  archiving [====================>                      ] 1/2\r (no-eol) (esc)
  archiving [==========================================>] 2/2\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [ <=>                                  ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [ <=>                             ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  diff -Nru cloned.*/.hgsub cloned/.hgsub (glob)
  --- cloned.*/.hgsub	* (glob)
  +++ cloned/.hgsub	* (glob)
  @@ -1,2 +1* @@ (glob)
   sub1 = ../sub1
  -sub3 = sub3
  diff -Nru cloned.*/.hgsubstate cloned/.hgsubstate (glob)
  --- cloned.*/.hgsubstate	* (glob)
  +++ cloned/.hgsubstate	* (glob)
  @@ -1,2 +1* @@ (glob)
   7a36fa02b66e61f27f3d4a822809f159479b8ab2 sub1
  -b1a26de6f2a045a9f079323693614ee322f1ff7e sub3
  [1]

  $ hg --config extensions.extdiff= pdiff -r 0 -r '.^' -S
  \r (no-eol) (esc)
  archiving [                                           ] 0/3\r (no-eol) (esc)
  archiving [=============>                             ] 1/3\r (no-eol) (esc)
  archiving [===========================>               ] 2/3\r (no-eol) (esc)
  archiving [==========================================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/1\r (no-eol) (esc)
  archiving (sub1) [===================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/1\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving [                                           ] 0/8\r (no-eol) (esc)
  archiving [====>                                      ] 1/8\r (no-eol) (esc)
  archiving [=========>                                 ] 2/8\r (no-eol) (esc)
  archiving [===============>                           ] 3/8\r (no-eol) (esc)
  archiving [====================>                      ] 4/8\r (no-eol) (esc)
  archiving [=========================>                 ] 5/8\r (no-eol) (esc)
  archiving [===============================>           ] 6/8\r (no-eol) (esc)
  archiving [====================================>      ] 7/8\r (no-eol) (esc)
  archiving [==========================================>] 8/8\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1) [                                    ] 0/1\r (no-eol) (esc)
  archiving (sub1) [===================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/3\r (no-eol) (esc)
  archiving (sub1/sub2) [=========>                     ] 1/3\r (no-eol) (esc)
  archiving (sub1/sub2) [===================>           ] 2/3\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 3/3\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub3) [                                    ] 0/1\r (no-eol) (esc)
  archiving (sub3) [===================================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  diff -Nru cloned.*/.hglf/b.dat cloned.*/.hglf/b.dat (glob)
  --- cloned.*/.hglf/b.dat	* (glob)
  +++ cloned.*/.hglf/b.dat	* (glob)
  @@ -*,0 +1* @@ (glob)
  +da39a3ee5e6b4b0d3255bfef95601890afd80709
  diff -Nru cloned.*/.hglf/foo/bar/large.dat cloned.*/.hglf/foo/bar/large.dat (glob)
  --- cloned.*/.hglf/foo/bar/large.dat	* (glob)
  +++ cloned.*/.hglf/foo/bar/large.dat	* (glob)
  @@ -*,0 +1* @@ (glob)
  +2f6933b5ee0f5fdd823d9717d8729f3c2523811b
  diff -Nru cloned.*/.hglf/large.bin cloned.*/.hglf/large.bin (glob)
  --- cloned.*/.hglf/large.bin	* (glob)
  +++ cloned.*/.hglf/large.bin	* (glob)
  @@ -*,0 +1* @@ (glob)
  +7f7097b041ccf68cc5561e9600da4655d21c6d18
  diff -Nru cloned.*/.hgsub cloned.*/.hgsub (glob)
  --- cloned.*/.hgsub	* (glob)
  +++ cloned.*/.hgsub	* (glob)
  @@ -1* +1,2 @@ (glob)
   sub1 = ../sub1
  +sub3 = sub3
  diff -Nru cloned.*/.hgsubstate cloned.*/.hgsubstate (glob)
  --- cloned.*/.hgsubstate	* (glob)
  +++ cloned.*/.hgsubstate	* (glob)
  @@ -1* +1,2 @@ (glob)
  -fc3b4ce2696f7741438c79207583768f2ce6b0dd sub1
  +7a36fa02b66e61f27f3d4a822809f159479b8ab2 sub1
  +b1a26de6f2a045a9f079323693614ee322f1ff7e sub3
  diff -Nru cloned.*/foo/bar/def cloned.*/foo/bar/def (glob)
  --- cloned.*/foo/bar/def	* (glob)
  +++ cloned.*/foo/bar/def	* (glob)
  @@ -*,0 +1* @@ (glob)
  +changed
  diff -Nru cloned.*/main cloned.*/main (glob)
  --- cloned.*/main	* (glob)
  +++ cloned.*/main	* (glob)
  @@ -1* +1* @@ (glob)
  -main
  +foo
  diff -Nru cloned.*/sub1/.hgsubstate cloned.*/sub1/.hgsubstate (glob)
  --- cloned.*/sub1/.hgsubstate	* (glob)
  +++ cloned.*/sub1/.hgsubstate	* (glob)
  @@ -1* +1* @@ (glob)
  -c57a0840e3badd667ef3c3ef65471609acb2ba3c sub2
  +c77908c81ccea3794a896c79e98b0e004aee2e9e sub2
  diff -Nru cloned.*/sub1/sub2/folder/test.txt cloned.*/sub1/sub2/folder/test.txt (glob)
  --- cloned.*/sub1/sub2/folder/test.txt	* (glob)
  +++ cloned.*/sub1/sub2/folder/test.txt	* (glob)
  @@ -*,0 +1* @@ (glob)
  +subfolder
  diff -Nru cloned.*/sub1/sub2/sub2 cloned.*/sub1/sub2/sub2 (glob)
  --- cloned.*/sub1/sub2/sub2	* (glob)
  +++ cloned.*/sub1/sub2/sub2	* (glob)
  @@ -1* +1* @@ (glob)
  -sub2
  +modified
  diff -Nru cloned.*/sub3/a.txt cloned.*/sub3/a.txt (glob)
  --- cloned.*/sub3/a.txt	* (glob)
  +++ cloned.*/sub3/a.txt	* (glob)
  @@ -*,0 +1* @@ (glob)
  +xyz
  [1]

  $ echo mod > sub1/sub2/sub2
  $ hg --config extensions.extdiff= pdiff -S
  \r (no-eol) (esc)
  archiving (sub1) [ <=>                                  ] 0\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  \r (no-eol) (esc)
  archiving (sub1/sub2) [                               ] 0/1\r (no-eol) (esc)
  archiving (sub1/sub2) [==============================>] 1/1\r (no-eol) (esc)
                                                              \r (no-eol) (esc)
  --- */cloned.*/sub1/sub2/sub2	* (glob)
  +++ */cloned/sub1/sub2/sub2	* (glob)
  @@ -1* +1* @@ (glob)
  -modified
  +mod
  [1]

  $ cd ..
