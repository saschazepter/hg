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
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ cd repo
  $ setupserver
  $ echo initialcommit > initialcommit
  $ hg ci -Aqm "initialcommit"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg phase --public .
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.

  $ cd ..
  $ hg clone ssh://user@dummy/repo client -q
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.

Create two heads. Push first head alone, then two heads together. Make sure that
multihead push works.
  $ cd client
  $ echo multihead1 > multihead1
  $ hg add multihead1
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg ci -m "multihead1"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg up null
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ echo multihead2 > multihead2
  $ hg ci -Am "multihead2"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding multihead2
  created new head
  $ hg push -r . --bundle-store
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing to ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  remote: pushing 1 commit:
  remote:     ee4802bf6864  multihead2
  $ hg push -r '1:2' --bundle-store
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing to ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  remote: pushing 2 commits:
  remote:     bc22f9a30a82  multihead1
  remote:     ee4802bf6864  multihead2
  $ scratchnodes
  bc22f9a30a821118244deacbd732e394ed0b686c de1b7d132ba98f0172cd974e3e69dfa80faa335c
  ee4802bf6864326a6b3dcfff5a03abc2a0a69b8f de1b7d132ba98f0172cd974e3e69dfa80faa335c

Create two new scratch bookmarks
  $ hg up 0
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo scratchfirstpart > scratchfirstpart
  $ hg ci -Am "scratchfirstpart"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding scratchfirstpart
  created new head
  $ hg push -r . -B scratch/firstpart
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing to ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  remote: pushing 1 commit:
  remote:     176993b87e39  scratchfirstpart
  $ hg up 0
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo scratchsecondpart > scratchsecondpart
  $ hg ci -Am "scratchsecondpart"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding scratchsecondpart
  created new head
  $ hg push -r . -B scratch/secondpart
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing to ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  remote: pushing 1 commit:
  remote:     8db3891c220e  scratchsecondpart

Pull two bookmarks from the second client
  $ cd ..
  $ hg clone ssh://user@dummy/repo client2 -q
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ cd client2
  $ hg pull -B scratch/firstpart -B scratch/secondpart
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
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
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  8db3891c220e216f6da214e8254bd4371f55efca (no-eol)
  $ hg log -r scratch/firstpart -T '{node}'
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  176993b87e39bd88d66a2cccadabe33f0b346339 (no-eol)
Make two commits to the scratch branch

  $ echo testpullbycommithash1 > testpullbycommithash1
  $ hg ci -Am "testpullbycommithash1"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding testpullbycommithash1
  created new head
  $ hg log -r '.' -T '{node}\n' > ../testpullbycommithash1
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ echo testpullbycommithash2 > testpullbycommithash2
  $ hg ci -Aqm "testpullbycommithash2"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg push -r . -B scratch/mybranch -q
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.

Create third client and pull by commit hash.
Make sure testpullbycommithash2 has not fetched
  $ cd ..
  $ hg clone ssh://user@dummy/repo client3 -q
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ cd client3
  $ hg pull -r `cat ../testpullbycommithash1`
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 33910bfe6ffe (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg log -G -T '{desc} {phase} {bookmarks}'
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  o  testpullbycommithash1 draft
  |
  @  initialcommit public
  
Make public commit in the repo and pull it.
Make sure phase on the client is public.
  $ cd ../repo
  $ echo publiccommit > publiccommit
  $ hg ci -Aqm "publiccommit"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg phase --public .
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ cd ../client3
  $ hg pull
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets a79b6597f322
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg log -G -T '{desc} {phase} {bookmarks} {node|short}'
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  o  publiccommit public  a79b6597f322
  |
  | o  testpullbycommithash1 draft  33910bfe6ffe
  |/
  @  initialcommit public  67145f466344
  
  $ hg up a79b6597f322
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo scratchontopofpublic > scratchontopofpublic
  $ hg ci -Aqm "scratchontopofpublic"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg push -r . -B scratch/scratchontopofpublic
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing to ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  remote: pushing 1 commit:
  remote:     c70aee6da07d  scratchontopofpublic
  $ cd ../client2
  $ hg pull -B scratch/scratchontopofpublic
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
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
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  draft (no-eol)
