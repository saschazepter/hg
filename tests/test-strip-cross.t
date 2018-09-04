test stripping of filelogs where the linkrev doesn't always increase

  $ echo '[extensions]' >> $HGRCPATH
  $ echo 'strip =' >> $HGRCPATH
  $ hg init orig
  $ cd orig
  $ commit()
  > {
  >     hg up -qC null
  >     count=1
  >     for i in "$@"; do
  >         for f in $i; do
  >             echo $count > $f
  >         done
  >         count=`expr $count + 1`
  >     done
  >     hg commit -qAm "$*"
  > }

2 1 0 2 0 1 2

  $ commit '201 210'
  $ commit '102 120' '210'
  $ commit '021'
  $ commit '201' '021 120'
  $ commit '012 021' '102 201' '120 210'
  $ commit 'manifest-file'
  $ commit '102 120' '012 210' '021 201'
  $ commit '201 210' '021 120' '012 102'
  $ HGUSER=another-user; export HGUSER
  $ commit 'manifest-file'
  $ commit '012' 'manifest-file'
  $ cd ..
  $ hg clone -q -U -r -1 -r -2 -r -3 -r -4 -r -6 orig crossed
  $ cd crossed
  $ hg debugindex --manifest
     rev linkrev nodeid       p1           p2
       0       0 6f105cbb914d 000000000000 000000000000
       1       3 1b55917b3699 000000000000 000000000000
       2       1 8f3d04e263e5 000000000000 000000000000
       3       2 f0ef8726ac4f 000000000000 000000000000
       4       4 0b76e38b4070 000000000000 000000000000

  $ for i in 012 021 102 120 201 210 manifest-file; do
  >     echo $i
  >     hg debugindex $i
  >     echo
  > done
  012
     rev linkrev nodeid       p1           p2
       0       0 b8e02f643373 000000000000 000000000000
       1       1 5d9299349fc0 000000000000 000000000000
       2       2 2661d26c6496 000000000000 000000000000
  
  021
     rev linkrev nodeid       p1           p2
       0       0 b8e02f643373 000000000000 000000000000
       1       2 5d9299349fc0 000000000000 000000000000
       2       1 2661d26c6496 000000000000 000000000000
  
  102
     rev linkrev nodeid       p1           p2
       0       1 b8e02f643373 000000000000 000000000000
       1       0 5d9299349fc0 000000000000 000000000000
       2       2 2661d26c6496 000000000000 000000000000
  
  120
     rev linkrev nodeid       p1           p2
       0       1 b8e02f643373 000000000000 000000000000
       1       2 5d9299349fc0 000000000000 000000000000
       2       0 2661d26c6496 000000000000 000000000000
  
  201
     rev linkrev nodeid       p1           p2
       0       2 b8e02f643373 000000000000 000000000000
       1       0 5d9299349fc0 000000000000 000000000000
       2       1 2661d26c6496 000000000000 000000000000
  
  210
     rev linkrev nodeid       p1           p2
       0       2 b8e02f643373 000000000000 000000000000
       1       1 5d9299349fc0 000000000000 000000000000
       2       0 2661d26c6496 000000000000 000000000000
  
  manifest-file
     rev linkrev nodeid       p1           p2
       0       3 b8e02f643373 000000000000 000000000000
       1       4 5d9299349fc0 000000000000 000000000000
  
  $ cd ..
  $ for i in 0 1 2 3 4; do
  >     hg clone -q -U --pull crossed $i
  >     echo "% Trying to strip revision $i"
  >     hg --cwd $i strip $i
  >     echo "% Verifying"
  >     hg --cwd $i verify
  >     echo
  > done
  % Trying to strip revision 0
  saved backup bundle to $TESTTMP/0/.hg/strip-backup/*-backup.hg (glob)
  % Verifying
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 15 changes to 7 files
  
  % Trying to strip revision 1
  saved backup bundle to $TESTTMP/1/.hg/strip-backup/*-backup.hg (glob)
  % Verifying
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 14 changes to 7 files
  
  % Trying to strip revision 2
  saved backup bundle to $TESTTMP/2/.hg/strip-backup/*-backup.hg (glob)
  % Verifying
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 14 changes to 7 files
  
  % Trying to strip revision 3
  saved backup bundle to $TESTTMP/3/.hg/strip-backup/*-backup.hg (glob)
  % Verifying
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 19 changes to 7 files
  
  % Trying to strip revision 4
  saved backup bundle to $TESTTMP/4/.hg/strip-backup/*-backup.hg (glob)
  % Verifying
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 19 changes to 7 files
  
