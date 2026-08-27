================================================================
Test the procedure for migrating a repository off tree manifests
================================================================

  $ cat << EOF >> $HGRCPATH
  > [extensions]
  > convert=
  > EOF

Set up the repo
---------------

Create a treemanifest repo with subdirectories, branches, merges, etc.

  $ hg --config experimental.treemanifest=yes init repo-old
  $ cd repo-old
  $ mkdir -p dir1/dir2
  $ echo a > a
  $ echo b > dir1/b
  $ echo c > dir1/dir2/c
  $ hg add -q .
  $ hg commit -m 'first'
  $ hg move -q dir1/dir2/c dir1/dir2/c-renamed
  $ hg commit -m 'rename c'
  $ hg branch -q side
  $ echo s > dir1/s
  $ hg add -q dir1/s
  $ hg commit -m 'on side branch'
  $ hg update -q default
  $ echo a2 > a
  $ hg commit -m 'edit a'
  $ hg merge -q side
  $ hg commit -m 'merge side'
  $ hg tag -m 'tag the merge' v1.0
  $ hg bookmark the-bookmark
  $ hg phase --public -r 'desc("first")'
  $ cd ..

Confirm the treemanifest structure

  $ hg debugrequires -R repo-old | grep treemanifest
  treemanifest
  $ ls repo-old/.hg/store/meta
  dir1
  $ hg -R repo-old debugdata -m 0
  a\x00b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3 (esc)
  dir1\x00afc793739285000cfb72c06a10342980a5c8d519t (esc)

Convert the repo
----------------

Use the `convert` extension to convert to a new repo without treemanifest

  $ hg convert --config experimental.treemanifest=no repo-old repo-new
  initializing destination repo-new repository
  scanning source...
  sorting...
  converting...
  5 first
  4 rename c
  3 on side branch
  2 edit a
  1 merge side
  0 tag the merge
  updating bookmarks

Confirm it worked

  $ hg debugrequires -R repo-new | grep treemanifest
  [1]
  $ test -d repo-new/.hg/store/meta
  [1]
  $ hg -R repo-new verify -q
  $ hg -R repo-new debugdata -m 0
  a\x00b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3 (esc)
  dir1/b\x001e88685f5ddec574a34c70af492f95b6debc8741 (esc)
  dir1/dir2/c\x00149da44f2a4e14f488b7bd4157945a9837408c00 (esc)

Compare the two repos
---------------------

The graph, file contents, copy sources, etc. should all be the same

  $ logtemplate='{rev} {branch} {p1rev},{p2rev} {desc}\n{join(files, " ")}\n{file_copies}\n'
  $ hg -R repo-old log --copies --template "$logtemplate" > repo-old.log
  $ hg -R repo-new log --copies --template "$logtemplate" > repo-new.log
  $ cmp repo-old.log repo-new.log
  $ for rev in 0 1 2 3 4 5; do
  >   hg -R repo-old archive -r $rev repo-old.archive
  >   hg -R repo-new archive -r $rev repo-new.archive
  >   diff -r -x .hg_archival.txt -x .hgtags repo-old.archive repo-new.archive ||
  >     echo "rev $rev differs"
  >   rm -r repo-old.archive repo-new.archive
  > done

Check branches, bookmarks, and tags

  $ hg -R repo-new branches
  default                        5:a7aa3128f02f
  side                           2:14ef5ed15be3 (inactive)
  $ hg -R repo-new bookmarks
     the-bookmark              5:a7aa3128f02f
  $ hg -R repo-new tags
  tip                                5:a7aa3128f02f
  v1.0                               4:e3e2256d9241

The changesets have different hashes

  $ hg -R repo-old log -r 0 --template '{node}\n'
  f8f50934ef0e207b6fca68a007f34dc593b47a43
  $ hg -R repo-new log -r 0 --template '{node}\n'
  a47e99e713f0d591512ccc48ce58e4a25b48c5c4
  $ hg -R repo-new incoming --quiet repo-old
  abort: repository is unrelated
  [255]

Public changesets become draft

  $ hg -R repo-old log --template '{rev} {phase}\n' -r 'desc("first")'
  0 public
  $ hg -R repo-new log --template '{rev} {phase}\n' -r 'desc("first")'
  0 draft

Caveat: obsolete commits are lost
---------------------------------

Create a repo with obsmarkers

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > evolution.createmarkers = yes
  > EOF
  $ hg --config experimental.treemanifest=yes init repo-obsolete
  $ cd repo-obsolete
  $ echo a > a
  $ hg commit -qAm 'first'
  $ echo a2 > a
  $ hg commit -qm 'typo in the message'
  $ hg commit -q --amend -m 'second'
  $ hg debugobsolete | wc -l
  \s*1 (re)
  $ hg log --hidden --template '{rev} {desc}\n'
  2 second
  1 typo in the message
  0 first
  $ cd ..

The obsolete changesets are left out of the conversion

  $ hg convert repo-obsolete repo-obsolete-1 -q
  $ hg -R repo-obsolete-1 debugobsolete | wc -l
  \s*0 (re)
  $ hg -R repo-obsolete-1 log --hidden --template '{rev} {desc}\n'
  1 second
  0 first

The global flag --hidden is allowed, but makes no difference

  $ hg convert repo-obsolete repo-obsolete-2 -q --hidden
  $ hg -R repo-obsolete-2 debugobsolete | wc -l
  \s*0 (re)
  $ hg -R repo-obsolete-2 log --hidden --template '{rev} {desc}\n'
  1 second
  0 first

  $ rm -rf repo-obsolete*
