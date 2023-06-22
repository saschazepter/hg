#require no-reposimplestore

Testing the case when there is no infinitepush extension present on the client
side and the server routes each push to bundlestore. This case is very much
similar to CI use case.

Setup
-----

  $ . "$TESTDIR/library-infinitepush.sh"
  $ cat >> $HGRCPATH <<EOF
  > [alias]
  > glog = log -GT "{rev}:{node|short} {desc}\n{phase}"
  > EOF
  $ cp $HGRCPATH $TESTTMP/defaulthgrc
  $ hg init repo
  $ cd repo
  $ setupserver
  $ echo "pushtobundlestore = True" >> .hg/hgrc
  $ echo "[extensions]" >> .hg/hgrc
  $ echo "infinitepush=" >> .hg/hgrc
  $ echo "[infinitepush]" >> .hg/hgrc
  $ echo "deprecation-abort=no" >> .hg/hgrc
  $ echo initialcommit > initialcommit
  $ hg ci -Aqm "initialcommit"
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact (chg !)
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be (chg !)
  unused and barring learning of users of this functionality, we drop this (chg !)
  extension in Mercurial 6.6. (chg !)
  $ hg phase --public .
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.

  $ cd ..
  $ hg clone repo client -q
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg clone repo client2 -q
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  $ hg clone ssh://user@dummy/repo client3 -q
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  $ cd client

Pushing a new commit from the client to the server
-----------------------------------------------------

  $ echo foobar > a
  $ hg ci -Aqm "added a"
  $ hg glog
  @  1:6cb0989601f1 added a
  |  draft
  o  0:67145f466344 initialcommit
     public

  $ hg push
  pushing to $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  storing changesets on the bundlestore
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing 1 commit:
      6cb0989601f1  added a

  $ scratchnodes
  6cb0989601f1fb5805238edfb16f3606713d9a0b 3b414252ff8acab801318445d88ff48faf4a28c3

Understanding how data is stored on the bundlestore in server
-------------------------------------------------------------

There are two things, filebundlestore and index
  $ ls ../repo/.hg/scratchbranches
  filebundlestore
  index

filebundlestore stores the bundles
  $ ls ../repo/.hg/scratchbranches/filebundlestore/3b/41/
  3b414252ff8acab801318445d88ff48faf4a28c3

index/nodemap stores a map of node id and file in which bundle is stored in filebundlestore
  $ ls ../repo/.hg/scratchbranches/index/
  nodemap
  $ ls ../repo/.hg/scratchbranches/index/nodemap/
  6cb0989601f1fb5805238edfb16f3606713d9a0b

  $ cd ../repo

Checking that the commit was not applied to revlog on the server
------------------------------------------------------------------

  $ hg glog
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  @  0:67145f466344 initialcommit
     public

Applying the changeset from the bundlestore
--------------------------------------------

  $ hg unbundle .hg/scratchbranches/filebundlestore/3b/41/3b414252ff8acab801318445d88ff48faf4a28c3
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 6cb0989601f1
  (run 'hg update' to get a working copy)

  $ hg glog
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

Pushing more changesets from the local repo
--------------------------------------------

  $ cd ../client
  $ echo b > b
  $ hg ci -Aqm "added b"
  $ echo c > c
  $ hg ci -Aqm "added c"
  $ hg glog
  @  3:bf8a6e3011b3 added c
  |  draft
  o  2:eaba929e866c added b
  |  draft
  o  1:6cb0989601f1 added a
  |  public
  o  0:67145f466344 initialcommit
     public

  $ hg push
  pushing to $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  storing changesets on the bundlestore
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing 2 commits:
      eaba929e866c  added b
      bf8a6e3011b3  added c

Checking that changesets are not applied on the server
------------------------------------------------------

  $ hg glog -R ../repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

Both of the new changesets are stored in a single bundle-file
  $ scratchnodes
  6cb0989601f1fb5805238edfb16f3606713d9a0b 3b414252ff8acab801318445d88ff48faf4a28c3
  bf8a6e3011b345146bbbedbcb1ebd4837571492a 239585f5e61f0c09ce7106bdc1097bff731738f4
  eaba929e866c59bc9a6aada5a9dd2f6990db83c0 239585f5e61f0c09ce7106bdc1097bff731738f4

Pushing more changesets to the server
-------------------------------------

  $ echo d > d
  $ hg ci -Aqm "added d"
  $ echo e > e
  $ hg ci -Aqm "added e"

XXX: we should have pushed only the parts which are not in bundlestore
  $ hg push
  pushing to $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  storing changesets on the bundlestore
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing 4 commits:
      eaba929e866c  added b
      bf8a6e3011b3  added c
      1bb96358eda2  added d
      b4e4bce66051  added e

Sneak peek into the bundlestore at the server
  $ scratchnodes
  1bb96358eda285b536c6d1c66846a7cdb2336cea 98fbae0016662521b0007da1b7bc349cd3caacd1
  6cb0989601f1fb5805238edfb16f3606713d9a0b 3b414252ff8acab801318445d88ff48faf4a28c3
  b4e4bce660512ad3e71189e14588a70ac8e31fef 98fbae0016662521b0007da1b7bc349cd3caacd1
  bf8a6e3011b345146bbbedbcb1ebd4837571492a 98fbae0016662521b0007da1b7bc349cd3caacd1
  eaba929e866c59bc9a6aada5a9dd2f6990db83c0 98fbae0016662521b0007da1b7bc349cd3caacd1

Checking if `hg pull` pulls something or `hg incoming` shows something
-----------------------------------------------------------------------

  $ hg incoming
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  comparing with $TESTTMP/repo
  searching for changes
  no changes found
  [1]

  $ hg pull
  pulling from $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  no changes found

Pulling from second client which is a localpeer to test `hg pull -r <rev>`
--------------------------------------------------------------------------

Pulling the revision which is applied

  $ cd ../client2
  $ hg pull -r 6cb0989601f1
  pulling from $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 6cb0989601f1
  (run 'hg update' to get a working copy)
  $ hg glog
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

Pulling the revision which is in bundlestore
XXX: we should support pulling revisions from a local peers bundlestore without
client side wrapping

  $ hg pull -r b4e4bce660512ad3e71189e14588a70ac8e31fef
  pulling from $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  abort: unknown revision 'b4e4bce660512ad3e71189e14588a70ac8e31fef'
  [10]
  $ hg glog
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

  $ cd ../client

Pulling from third client which is not a localpeer
---------------------------------------------------

Pulling the revision which is applied

  $ cd ../client3
  $ hg pull -r 6cb0989601f1
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 6cb0989601f1
  (run 'hg update' to get a working copy)
  $ hg glog
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

Pulling the revision which is in bundlestore

Trying to specify short hash
XXX: we should support this
  $ hg pull -r b4e4bce660512
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  abort: unknown revision 'b4e4bce660512'
  [255]

XXX: we should show better message when the pull is happening from bundlestore
  $ hg pull -r b4e4bce660512ad3e71189e14588a70ac8e31fef
  pulling from ssh://user@dummy/repo
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  searching for changes
  remote: IMPORTANT: if you use this extension, please contact
  remote: mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  remote: unused and barring learning of users of this functionality, we drop this
  remote: extension in Mercurial 6.6.
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 4 files
  new changesets eaba929e866c:b4e4bce66051
  (run 'hg update' to get a working copy)
  $ hg glog
  o  5:b4e4bce66051 added e
  |  public
  o  4:1bb96358eda2 added d
  |  public
  o  3:bf8a6e3011b3 added c
  |  public
  o  2:eaba929e866c added b
  |  public
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

  $ cd ../client

Checking storage of phase information with the bundle on bundlestore
---------------------------------------------------------------------

creating a draft commit
  $ cat >> $HGRCPATH <<EOF
  > [phases]
  > publish = False
  > EOF
  $ echo f > f
  $ hg ci -Aqm "added f"
  $ hg glog -r '.^::'
  @  6:9b42578d4447 added f
  |  draft
  o  5:b4e4bce66051 added e
  |  public
  ~

  $ hg push
  pushing to $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  storing changesets on the bundlestore
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing 5 commits:
      eaba929e866c  added b
      bf8a6e3011b3  added c
      1bb96358eda2  added d
      b4e4bce66051  added e
      9b42578d4447  added f

XXX: the phase of 9b42578d4447 should not be changed here
  $ hg glog -r .
  @  6:9b42578d4447 added f
  |  public
  ~

applying the bundle on the server to check preservation of phase-information

  $ cd ../repo
  $ scratchnodes
  1bb96358eda285b536c6d1c66846a7cdb2336cea 280a46a259a268f0e740c81c5a7751bdbfaec85f
  6cb0989601f1fb5805238edfb16f3606713d9a0b 3b414252ff8acab801318445d88ff48faf4a28c3
  9b42578d44473575994109161430d65dd147d16d 280a46a259a268f0e740c81c5a7751bdbfaec85f
  b4e4bce660512ad3e71189e14588a70ac8e31fef 280a46a259a268f0e740c81c5a7751bdbfaec85f
  bf8a6e3011b345146bbbedbcb1ebd4837571492a 280a46a259a268f0e740c81c5a7751bdbfaec85f
  eaba929e866c59bc9a6aada5a9dd2f6990db83c0 280a46a259a268f0e740c81c5a7751bdbfaec85f

  $ hg unbundle .hg/scratchbranches/filebundlestore/28/0a/280a46a259a268f0e740c81c5a7751bdbfaec85f
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 5 files
  new changesets eaba929e866c:9b42578d4447 (1 drafts)
  (run 'hg update' to get a working copy)

  $ hg glog
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  o  6:9b42578d4447 added f
  |  draft
  o  5:b4e4bce66051 added e
  |  public
  o  4:1bb96358eda2 added d
  |  public
  o  3:bf8a6e3011b3 added c
  |  public
  o  2:eaba929e866c added b
  |  public
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

Checking storage of obsmarkers in the bundlestore
--------------------------------------------------

enabling obsmarkers and rebase extension

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution = all
  > [extensions]
  > rebase =
  > EOF

  $ cd ../client

  $ hg phase -r . --draft --force
  $ hg rebase -r 6 -d 3
  rebasing 6:9b42578d4447 tip "added f"

  $ hg glog
  @  7:99949238d9ac added f
  |  draft
  | o  5:b4e4bce66051 added e
  | |  public
  | o  4:1bb96358eda2 added d
  |/   public
  o  3:bf8a6e3011b3 added c
  |  public
  o  2:eaba929e866c added b
  |  public
  o  1:6cb0989601f1 added a
  |  public
  o  0:67145f466344 initialcommit
     public

  $ hg push -f
  pushing to $TESTTMP/repo
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  searching for changes
  storing changesets on the bundlestore
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  pushing 1 commit:
      99949238d9ac  added f

XXX: the phase should not have changed here
  $ hg glog -r .
  @  7:99949238d9ac added f
  |  public
  ~

Unbundling on server to see obsmarkers being applied

  $ cd ../repo

  $ scratchnodes
  1bb96358eda285b536c6d1c66846a7cdb2336cea 280a46a259a268f0e740c81c5a7751bdbfaec85f
  6cb0989601f1fb5805238edfb16f3606713d9a0b 3b414252ff8acab801318445d88ff48faf4a28c3
  99949238d9ac7f2424a33a46dface6f866afd059 090a24fe63f31d3b4bee714447f835c8c362ff57
  9b42578d44473575994109161430d65dd147d16d 280a46a259a268f0e740c81c5a7751bdbfaec85f
  b4e4bce660512ad3e71189e14588a70ac8e31fef 280a46a259a268f0e740c81c5a7751bdbfaec85f
  bf8a6e3011b345146bbbedbcb1ebd4837571492a 280a46a259a268f0e740c81c5a7751bdbfaec85f
  eaba929e866c59bc9a6aada5a9dd2f6990db83c0 280a46a259a268f0e740c81c5a7751bdbfaec85f

  $ hg glog
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  IMPORTANT: if you use this extension, please contact (chg !)
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be (chg !)
  unused and barring learning of users of this functionality, we drop this (chg !)
  extension in Mercurial 6.6. (chg !)
  o  6:9b42578d4447 added f
  |  draft
  o  5:b4e4bce66051 added e
  |  public
  o  4:1bb96358eda2 added d
  |  public
  o  3:bf8a6e3011b3 added c
  |  public
  o  2:eaba929e866c added b
  |  public
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public

  $ hg unbundle .hg/scratchbranches/filebundlestore/09/0a/090a24fe63f31d3b4bee714447f835c8c362ff57
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 0 changes to 1 files (+1 heads)
  1 new obsolescence markers
  obsoleted 1 changesets
  new changesets 99949238d9ac (1 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)

  $ hg glog
  IMPORTANT: if you use this extension, please contact
  mercurial-devel@mercurial-scm.org IMMEDIATELY. This extension is believed to be
  unused and barring learning of users of this functionality, we drop this
  extension in Mercurial 6.6.
  o  7:99949238d9ac added f
  |  draft
  | o  5:b4e4bce66051 added e
  | |  public
  | o  4:1bb96358eda2 added d
  |/   public
  o  3:bf8a6e3011b3 added c
  |  public
  o  2:eaba929e866c added b
  |  public
  o  1:6cb0989601f1 added a
  |  public
  @  0:67145f466344 initialcommit
     public
