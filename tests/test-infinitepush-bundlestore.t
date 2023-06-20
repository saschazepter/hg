#require no-reposimplestore no-chg

XXX-CHG this test hangs if `hg` is really `chg`. This was hidden by the use of
`alias hg=chg` by run-tests.py. With such alias removed, this test is revealed
buggy. This need to be resolved sooner than later.


Testing infinipush extension and the confi options provided by it

Create an ondisk bundlestore in .hg/scratchbranches
  $ . "$TESTDIR/library-infinitepush.sh"
  $ cp $HGRCPATH $TESTTMP/defaulthgrc
  $ setupcommon
  $ mkcommit() {
  >    echo "$1" > "$1"
  >    hg add "$1"
  >    hg ci -m "$1"
  > }
  $ hg init repo
  $ cd repo

Check that we can send a scratch on the server and it does not show there in
the history but is stored on disk
  $ setupserver
  $ cd ..
  $ hg clone ssh://user@dummy/repo client -q
  $ cd client
  $ mkcommit initialcommit
  $ hg push -r .
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  $ mkcommit scratchcommit
  $ hg push -r . -B scratch/mybranch
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 1 commit:
  remote:     20759b6926ce  scratchcommit
  $ hg log -G
  @  changeset:   1:20759b6926ce
  |  bookmark:    scratch/mybranch
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     scratchcommit
  |
  o  changeset:   0:67145f466344
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initialcommit
  
  $ hg log -G -R ../repo
  o  changeset:   0:67145f466344
     tag:         tip
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initialcommit
  
  $ find ../repo/.hg/scratchbranches | sort
  ../repo/.hg/scratchbranches
  ../repo/.hg/scratchbranches/filebundlestore
  ../repo/.hg/scratchbranches/filebundlestore/b9
  ../repo/.hg/scratchbranches/filebundlestore/b9/e1
  ../repo/.hg/scratchbranches/filebundlestore/b9/e1/b9e1ee5f93fb6d7c42496fc176c09839639dd9cc
  ../repo/.hg/scratchbranches/index
  ../repo/.hg/scratchbranches/index/bookmarkmap
  ../repo/.hg/scratchbranches/index/bookmarkmap/scratch
  ../repo/.hg/scratchbranches/index/bookmarkmap/scratch/mybranch
  ../repo/.hg/scratchbranches/index/nodemap
  ../repo/.hg/scratchbranches/index/nodemap/20759b6926ce827d5a8c73eb1fa9726d6f7defb2

From another client we can get the scratchbranch if we ask for it explicitely

  $ cd ..
  $ hg clone ssh://user@dummy/repo client2 -q
  $ cd client2
  $ hg pull -B scratch/mybranch --traceback
  pulling from ssh://user@dummy/repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 20759b6926ce (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg log -G
  o  changeset:   1:20759b6926ce
  |  bookmark:    scratch/mybranch
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     scratchcommit
  |
  @  changeset:   0:67145f466344
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     initialcommit
  
  $ cd ..

Push to non-scratch bookmark

  $ cd client
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ mkcommit newcommit
  created new head
  $ hg push -r .
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  @  newcommit public
  |
  | o  scratchcommit draft scratch/mybranch
  |/
  o  initialcommit public
  

Push to scratch branch
  $ cd ../client2
  $ hg up -q scratch/mybranch
  $ mkcommit 'new scratch commit'
  $ hg push -r . -B scratch/mybranch
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 2 commits:
  remote:     20759b6926ce  scratchcommit
  remote:     1de1d7d92f89  new scratch commit
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  @  new scratch commit draft scratch/mybranch
  |
  o  scratchcommit draft
  |
  o  initialcommit public
  
  $ scratchnodes
  1de1d7d92f8965260391d0513fe8a8d5973d3042 bed63daed3beba97fff2e819a148cf415c217a85
  20759b6926ce827d5a8c73eb1fa9726d6f7defb2 bed63daed3beba97fff2e819a148cf415c217a85

  $ scratchbookmarks
  scratch/mybranch 1de1d7d92f8965260391d0513fe8a8d5973d3042

Push scratch bookmark with no new revs
  $ hg push -r . -B scratch/anotherbranch
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 2 commits:
  remote:     20759b6926ce  scratchcommit
  remote:     1de1d7d92f89  new scratch commit
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  @  new scratch commit draft scratch/anotherbranch scratch/mybranch
  |
  o  scratchcommit draft
  |
  o  initialcommit public
  
  $ scratchbookmarks
  scratch/anotherbranch 1de1d7d92f8965260391d0513fe8a8d5973d3042
  scratch/mybranch 1de1d7d92f8965260391d0513fe8a8d5973d3042

Pull scratch and non-scratch bookmark at the same time

  $ hg -R ../repo book newbook
  $ cd ../client
  $ hg pull -B newbook -B scratch/mybranch --traceback
  pulling from ssh://user@dummy/repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  adding remote bookmark newbook
  added 1 changesets with 1 changes to 2 files
  new changesets 1de1d7d92f89 (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  o  new scratch commit draft scratch/mybranch
  |
  | @  newcommit public
  | |
  o |  scratchcommit draft
  |/
  o  initialcommit public
  

Push scratch revision without bookmark with --bundle-store

  $ hg up -q tip
  $ mkcommit scratchcommitnobook
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  @  scratchcommitnobook draft
  |
  o  new scratch commit draft scratch/mybranch
  |
  | o  newcommit public
  | |
  o |  scratchcommit draft
  |/
  o  initialcommit public
  
  $ hg push -r . --bundle-store
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 3 commits:
  remote:     20759b6926ce  scratchcommit
  remote:     1de1d7d92f89  new scratch commit
  remote:     2b5d271c7e0d  scratchcommitnobook
  $ hg -R ../repo log -G -T '{desc} {phase}'
  o  newcommit public
  |
  o  initialcommit public
  

  $ scratchnodes
  1de1d7d92f8965260391d0513fe8a8d5973d3042 66fa08ff107451320512817bed42b7f467a1bec3
  20759b6926ce827d5a8c73eb1fa9726d6f7defb2 66fa08ff107451320512817bed42b7f467a1bec3
  2b5d271c7e0d25d811359a314d413ebcc75c9524 66fa08ff107451320512817bed42b7f467a1bec3

Test with pushrebase
  $ mkcommit scratchcommitwithpushrebase
  $ hg push -r . -B scratch/mybranch
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 4 commits:
  remote:     20759b6926ce  scratchcommit
  remote:     1de1d7d92f89  new scratch commit
  remote:     2b5d271c7e0d  scratchcommitnobook
  remote:     d8c4f54ab678  scratchcommitwithpushrebase
  $ hg -R ../repo log -G -T '{desc} {phase}'
  o  newcommit public
  |
  o  initialcommit public
  
  $ scratchnodes
  1de1d7d92f8965260391d0513fe8a8d5973d3042 e3cb2ac50f9e1e6a5ead3217fc21236c84af4397
  20759b6926ce827d5a8c73eb1fa9726d6f7defb2 e3cb2ac50f9e1e6a5ead3217fc21236c84af4397
  2b5d271c7e0d25d811359a314d413ebcc75c9524 e3cb2ac50f9e1e6a5ead3217fc21236c84af4397
  d8c4f54ab678fd67cb90bb3f272a2dc6513a59a7 e3cb2ac50f9e1e6a5ead3217fc21236c84af4397

Change the order of pushrebase and infinitepush
  $ mkcommit scratchcommitwithpushrebase2
  $ hg push -r . -B scratch/mybranch
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 5 commits:
  remote:     20759b6926ce  scratchcommit
  remote:     1de1d7d92f89  new scratch commit
  remote:     2b5d271c7e0d  scratchcommitnobook
  remote:     d8c4f54ab678  scratchcommitwithpushrebase
  remote:     6c10d49fe927  scratchcommitwithpushrebase2
  $ hg -R ../repo log -G -T '{desc} {phase}'
  o  newcommit public
  |
  o  initialcommit public
  
  $ scratchnodes
  1de1d7d92f8965260391d0513fe8a8d5973d3042 cd0586065eaf8b483698518f5fc32531e36fd8e0
  20759b6926ce827d5a8c73eb1fa9726d6f7defb2 cd0586065eaf8b483698518f5fc32531e36fd8e0
  2b5d271c7e0d25d811359a314d413ebcc75c9524 cd0586065eaf8b483698518f5fc32531e36fd8e0
  6c10d49fe92751666c40263f96721b918170d3da cd0586065eaf8b483698518f5fc32531e36fd8e0
  d8c4f54ab678fd67cb90bb3f272a2dc6513a59a7 cd0586065eaf8b483698518f5fc32531e36fd8e0

Non-fastforward scratch bookmark push

  $ hg log -GT "{rev}:{node} {desc}\n"
  @  6:6c10d49fe92751666c40263f96721b918170d3da scratchcommitwithpushrebase2
  |
  o  5:d8c4f54ab678fd67cb90bb3f272a2dc6513a59a7 scratchcommitwithpushrebase
  |
  o  4:2b5d271c7e0d25d811359a314d413ebcc75c9524 scratchcommitnobook
  |
  o  3:1de1d7d92f8965260391d0513fe8a8d5973d3042 new scratch commit
  |
  | o  2:91894e11e8255bf41aa5434b7b98e8b2aa2786eb newcommit
  | |
  o |  1:20759b6926ce827d5a8c73eb1fa9726d6f7defb2 scratchcommit
  |/
  o  0:67145f4663446a9580364f70034fea6e21293b6f initialcommit
  
  $ hg up 6c10d49fe927
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo 1 > amend
  $ hg add amend
  $ hg ci --amend -m 'scratch amended commit'
  saved backup bundle to $TESTTMP/client/.hg/strip-backup/6c10d49fe927-c99ffec5-amend.hg
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  @  scratch amended commit draft scratch/mybranch
  |
  o  scratchcommitwithpushrebase draft
  |
  o  scratchcommitnobook draft
  |
  o  new scratch commit draft
  |
  | o  newcommit public
  | |
  o |  scratchcommit draft
  |/
  o  initialcommit public
  

  $ scratchbookmarks
  scratch/anotherbranch 1de1d7d92f8965260391d0513fe8a8d5973d3042
  scratch/mybranch 6c10d49fe92751666c40263f96721b918170d3da
  $ hg push -r . -B scratch/mybranch
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 5 commits:
  remote:     20759b6926ce  scratchcommit
  remote:     1de1d7d92f89  new scratch commit
  remote:     2b5d271c7e0d  scratchcommitnobook
  remote:     d8c4f54ab678  scratchcommitwithpushrebase
  remote:     8872775dd97a  scratch amended commit
  $ scratchbookmarks
  scratch/anotherbranch 1de1d7d92f8965260391d0513fe8a8d5973d3042
  scratch/mybranch 8872775dd97a750e1533dc1fbbca665644b32547
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  @  scratch amended commit draft scratch/mybranch
  |
  o  scratchcommitwithpushrebase draft
  |
  o  scratchcommitnobook draft
  |
  o  new scratch commit draft
  |
  | o  newcommit public
  | |
  o |  scratchcommit draft
  |/
  o  initialcommit public
  
Check that push path is not ignored. Add new path to the hgrc
  $ cat >> .hg/hgrc << EOF
  > [paths]
  > peer=ssh://user@dummy/client2
  > EOF

Checkout last non-scrath commit
  $ hg up 91894e11e8255
  1 files updated, 0 files merged, 6 files removed, 0 files unresolved
  $ mkcommit peercommit
Use --force because this push creates new head
  $ hg push peer -r . -f
  pushing to ssh://user@dummy/client2
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 2 changesets with 2 changes to 2 files (+1 heads)
  $ hg -R ../repo log -G -T '{desc} {phase} {bookmarks}'
  o  newcommit public
  |
  o  initialcommit public
  
  $ hg -R ../client2 log -G -T '{desc} {phase} {bookmarks}'
  o  peercommit public
  |
  o  newcommit public
  |
  | @  new scratch commit draft scratch/anotherbranch scratch/mybranch
  | |
  | o  scratchcommit draft
  |/
  o  initialcommit public
  
