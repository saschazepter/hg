#require no-reposimplestore no-chg

XXX-CHG this test hangs if `hg` is really `chg`. This was hidden by the use of
`alias hg=chg` by run-tests.py. With such alias removed, this test is revealed
buggy. This need to be resolved sooner than later.


Testing infinipush extension and the confi options provided by it

Setup

  $ . "$TESTDIR/library-infinitepush.sh"
  $ cp $HGRCPATH $TESTTMP/defaulthgrc
  $ setupcommon
  $ hg init repo
  $ cd repo
  $ setupserver
  $ echo initialcommit > initialcommit
  $ hg ci -Aqm "initialcommit"
  $ hg phase --public .

  $ cd ..
  $ hg clone ssh://user@dummy/repo client -q

Create two heads. Push first head alone, then two heads together. Make sure that
multihead push works.
  $ cd client
  $ echo multihead1 > multihead1
  $ hg add multihead1
  $ hg ci -m "multihead1"
  $ hg up null
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo multihead2 > multihead2
  $ hg ci -Am "multihead2"
  adding multihead2
  created new head
  $ hg push -r . --bundle-store
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 1 commit:
  remote:     ee4802bf6864  multihead2
  $ hg push -r '1:2' --bundle-store
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 2 commits:
  remote:     bc22f9a30a82  multihead1
  remote:     ee4802bf6864  multihead2
  $ scratchnodes
  bc22f9a30a821118244deacbd732e394ed0b686c ab1bc557aa090a9e4145512c734b6e8a828393a5
  ee4802bf6864326a6b3dcfff5a03abc2a0a69b8f ab1bc557aa090a9e4145512c734b6e8a828393a5

Create two new scratch bookmarks
  $ hg up 0
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo scratchfirstpart > scratchfirstpart
  $ hg ci -Am "scratchfirstpart"
  adding scratchfirstpart
  created new head
  $ hg push -r . -B scratch/firstpart
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 1 commit:
  remote:     176993b87e39  scratchfirstpart
  $ hg up 0
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo scratchsecondpart > scratchsecondpart
  $ hg ci -Am "scratchsecondpart"
  adding scratchsecondpart
  created new head
  $ hg push -r . -B scratch/secondpart
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 1 commit:
  remote:     8db3891c220e  scratchsecondpart

Pull two bookmarks from the second client
  $ cd ..
  $ hg clone ssh://user@dummy/repo client2 -q
  $ cd client2
  $ hg pull -B scratch/firstpart -B scratch/secondpart
  pulling from ssh://user@dummy/repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files (+1 heads)
  new changesets * (glob)
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg log -r scratch/secondpart -T '{node}'
  8db3891c220e216f6da214e8254bd4371f55efca (no-eol)
  $ hg log -r scratch/firstpart -T '{node}'
  176993b87e39bd88d66a2cccadabe33f0b346339 (no-eol)
Make two commits to the scratch branch

  $ echo testpullbycommithash1 > testpullbycommithash1
  $ hg ci -Am "testpullbycommithash1"
  adding testpullbycommithash1
  created new head
  $ hg log -r '.' -T '{node}\n' > ../testpullbycommithash1
  $ echo testpullbycommithash2 > testpullbycommithash2
  $ hg ci -Aqm "testpullbycommithash2"
  $ hg push -r . -B scratch/mybranch -q

Create third client and pull by commit hash.
Make sure testpullbycommithash2 has not fetched
  $ cd ..
  $ hg clone ssh://user@dummy/repo client3 -q
  $ cd client3
  $ hg pull -r `cat ../testpullbycommithash1`
  pulling from ssh://user@dummy/repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 33910bfe6ffe (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  o  testpullbycommithash1 draft
  |
  @  initialcommit public
  
Make public commit in the repo and pull it.
Make sure phase on the client is public.
  $ cd ../repo
  $ echo publiccommit > publiccommit
  $ hg ci -Aqm "publiccommit"
  $ hg phase --public .
  $ cd ../client3
  $ hg pull
  pulling from ssh://user@dummy/repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets a79b6597f322
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg log -G -T '{desc} {phase} {bookmarks} {node|short}'
  o  publiccommit public  a79b6597f322
  |
  | o  testpullbycommithash1 draft  33910bfe6ffe
  |/
  @  initialcommit public  67145f466344
  
  $ hg up a79b6597f322
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo scratchontopofpublic > scratchontopofpublic
  $ hg ci -Aqm "scratchontopofpublic"
  $ hg push -r . -B scratch/scratchontopofpublic
  pushing to ssh://user@dummy/repo
  searching for changes
  remote: pushing 1 commit:
  remote:     c70aee6da07d  scratchontopofpublic
  $ cd ../client2
  $ hg pull -B scratch/scratchontopofpublic
  pulling from ssh://user@dummy/repo
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files (+1 heads)
  new changesets a79b6597f322:c70aee6da07d (1 drafts)
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg log -r scratch/scratchontopofpublic -T '{phase}'
  draft (no-eol)
