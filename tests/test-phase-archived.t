=========================================================
Test features and behaviors related to the archived phase
=========================================================

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-archived-phase=yes
  > [extensions]
  > strip=
  > [experimental]
  > EOF

  $ hg init repo
  $ cd repo
  $ echo  root > a
  $ hg add a
  $ hg ci -m 'root'

Test that bundle can unarchive a changeset
------------------------------------------

  $ echo foo >> a
  $ hg st
  M a
  $ hg ci -m 'unbundletesting'
  $ hg log -G
  @  changeset:   1:883aadbbf309
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     unbundletesting
  |
  o  changeset:   0:c1863a3840c6
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  
  $ hg strip --soft --rev '.'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/883aadbbf309-efc55adc-backup.hg
  $ hg log -G
  @  changeset:   0:c1863a3840c6
     tag:         tip
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  
  $ hg log -G --hidden
  o  changeset:   1:883aadbbf309
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     unbundletesting
  |
  @  changeset:   0:c1863a3840c6
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  
  $ hg unbundle .hg/strip-backup/883aadbbf309-efc55adc-backup.hg
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 0 changes to 1 files
  (run 'hg update' to get a working copy)
  $ hg log -G
  o  changeset:   1:883aadbbf309
  |  tag:         tip
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     unbundletesting
  |
  @  changeset:   0:c1863a3840c6
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  

Test that history rewriting command can use the archived phase when allowed to
------------------------------------------------------------------------------

  $ hg up 'desc(unbundletesting)'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo bar >> a
  $ hg commit --amend --config experimental.cleanup-as-archived=yes
  $ hg log -G
  @  changeset:   2:d1e73e428f29
  |  tag:         tip
  |  parent:      0:c1863a3840c6
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     unbundletesting
  |
  o  changeset:   0:c1863a3840c6
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  
  $ hg log -G --hidden
  @  changeset:   2:d1e73e428f29
  |  tag:         tip
  |  parent:      0:c1863a3840c6
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     unbundletesting
  |
  | o  changeset:   1:883aadbbf309
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     unbundletesting
  |
  o  changeset:   0:c1863a3840c6
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  
  $ ls -1 .hg/strip-backup/
  883aadbbf309-efc55adc-amend.hg
  883aadbbf309-efc55adc-backup.hg
  $ hg unbundle .hg/strip-backup/883aadbbf309*amend.hg
  adding changesets
  adding manifests
  adding file changes
  added 0 changesets with 0 changes to 1 files
  (run 'hg update' to get a working copy)
  $ hg log -G
  @  changeset:   2:d1e73e428f29
  |  tag:         tip
  |  parent:      0:c1863a3840c6
  |  user:        test
  |  date:        Thu Jan 01 00:00:00 1970 +0000
  |  summary:     unbundletesting
  |
  | o  changeset:   1:883aadbbf309
  |/   user:        test
  |    date:        Thu Jan 01 00:00:00 1970 +0000
  |    summary:     unbundletesting
  |
  o  changeset:   0:c1863a3840c6
     user:        test
     date:        Thu Jan 01 00:00:00 1970 +0000
     summary:     root
  

Test that a strip will preserve unrelated changeset archived
------------------------------------------------------------

prepare a suitable tree

  $ echo foo > bar
  $ hg add bar
  $ hg commit -m 'some more commit'
  $ hg log -G --hidden -T '{rev} {node|short} [{phase}] {desc|firstline}\n'
  @  3 f90bf4e57854 [draft] some more commit
  |
  o  2 d1e73e428f29 [draft] unbundletesting
  |
  | o  1 883aadbbf309 [draft] unbundletesting
  |/
  o  0 c1863a3840c6 [draft] root
  
  $ hg strip --soft --rev '.'
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/f90bf4e57854-56b37ff2-backup.hg
  $ hg log -G --hidden -T '{rev} {node|short} [{phase}] {desc|firstline}\n'
  o  3 f90bf4e57854 [archived] some more commit
  |
  @  2 d1e73e428f29 [draft] unbundletesting
  |
  | o  1 883aadbbf309 [draft] unbundletesting
  |/
  o  0 c1863a3840c6 [draft] root
  


Strips the other (lower rev-num) head

  $ hg strip --rev 'min(head() and not .)'
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/883aadbbf309-efc55adc-backup.hg

The archived changeset should still be hidden

  $ hg log -G -T '{rev} {node|short} [{phase}] {desc|firstline}\n'
  @  1 d1e73e428f29 [draft] unbundletesting
  |
  o  0 c1863a3840c6 [draft] root
  

It may still be around:

  $ hg log --hidden -G -T '{rev} {node|short} [{phase}] {desc|firstline}\n'
  o  2 f90bf4e57854 [archived] some more commit
  |
  @  1 d1e73e428f29 [draft] unbundletesting
  |
  o  0 c1863a3840c6 [draft] root
  

