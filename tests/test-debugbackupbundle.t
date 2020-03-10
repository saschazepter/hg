  $ cat >> $HGRCPATH << EOF
  > [extensions]
  > strip=
  > EOF

Setup repo

  $ hg init repo
  $ cd repo

Test backups list and recover

  $ hg debugbackupbundle
  no backup changesets found

  $ mkcommit() {
  >    echo "$1" > "$1"
  >    hg add "$1"
  >    hg ci -l $1
  > }
  $ mkcommit a
  $ mkcommit b
  $ hg strip .
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/repo/.hg/strip-backup/d2ae7f538514-2953539b-backup.hg
  $ hg debugbackupbundle
  Recover changesets using: hg debugbackupbundle --recover <changeset hash>
  
  Available backup changesets:
  * (glob)
  d2ae7f538514 b

  $ hg debugbackupbundle --recover d2ae7f538514
  Unbundling d2ae7f538514
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets d2ae7f538514 (1 drafts)
