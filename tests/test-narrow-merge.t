#testcases flat tree

  $ . "$TESTDIR/narrow-library.sh"

#if tree
  $ cat << EOF >> $HGRCPATH
  > [experimental]
  > treemanifest = 1
  > EOF
#endif

create full repo

  $ hg init master
  $ cd master
  $ cat >> .hg/hgrc <<EOF
  > [narrow]
  > serveellipses=True
  > EOF

  $ mkdir inside
  $ echo inside1 > inside/f1
  $ echo inside2 > inside/f2
  $ mkdir outside
  $ echo outside1 > outside/f1
  $ echo outside2 > outside/f2
  $ hg ci -Aqm 'initial'

  $ echo modified > inside/f1
  $ hg ci -qm 'modify inside/f1'

  $ hg update -q 0
  $ echo modified > inside/f2
  $ hg ci -qm 'modify inside/f2'

  $ hg update -q 0
  $ echo modified2 > inside/f1
  $ hg ci -qm 'conflicting inside/f1'

  $ hg update -q 0
  $ echo modified > outside/f1
  $ hg ci -qm 'modify outside/f1'

  $ hg update -q 0
  $ echo modified2 > outside/f1
  $ hg ci -qm 'conflicting outside/f1'

  $ cd ..

  $ hg clone --narrow ssh://user@dummy/master narrow --include inside
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 5 changes to 2 files (+4 heads)
  new changesets *:* (glob)
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd narrow

  $ hg update -q 0

Can merge in when no files outside narrow spec are involved

  $ hg update -q 'desc("modify inside/f1")'
  $ hg merge 'desc("modify inside/f2")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m 'merge inside changes'

Can merge conflicting changes inside narrow spec

  $ hg update -q 'desc("modify inside/f1")'
  $ hg merge 'desc("conflicting inside/f1")' 2>&1 | egrep -v '(warning:|incomplete!)'
  merging inside/f1
  0 files updated, 0 files merged, 0 files removed, 1 files unresolved
  use 'hg resolve' to retry unresolved file merges or 'hg merge --abort' to abandon
  $ echo modified3 > inside/f1
  $ hg resolve -m
  (no more unresolved files)
  $ hg commit -m 'merge inside/f1'

TODO: Can merge non-conflicting changes outside narrow spec

  $ hg update -q 'desc("modify inside/f1")'

#if flat

  $ hg merge 'desc("modify outside/f1")'
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)

status should be clean

  $ hg status
  ? inside/f1.orig

file out of the spec should still not be in the dirstate at all

  $ hg debugdirstate | grep outside/f1
  [1]

Commit that merge

  $ hg ci -m 'merge from outside to inside'

status should be clean

  $ hg status
  ? inside/f1.orig

file out of the spec should not be in the mergestate anymore

  $ hg debugmergestate | grep outside/f1
  [1]

file out of the spec should still not be in the dirstate at all

  $ hg debugdirstate | grep outside/f1
  [1]

The filenode used should come from p2

  $ hg manifest --debug --rev . | grep outside/f1
  83cd11431a3b2aff8a3995e5f27bcf33cdb5be98 644   outside/f1
  $ hg manifest --debug --rev 'p1(.)' | grep outside/f1
  c6b956c48be2cd4fa94be16002aba311143806fa 644   outside/f1
  $ hg manifest --debug --rev 'p2(.)' | grep outside/f1
  83cd11431a3b2aff8a3995e5f27bcf33cdb5be98 644   outside/f1


remove the commit to get in the previous situation again

  $ hg debugstrip -r .
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  saved backup bundle to $TESTTMP/narrow/.hg/strip-backup/48eb25338b19-a1bb8350-backup.hg

#else

  $ hg merge 'desc("modify outside/f1")'
  abort: merge affects file 'outside/' outside narrow, which is not yet supported (tree !)
  (merging in the other direction may work)
  [255]

#endif

  $ hg update -q 'desc("modify outside/f1")'
  $ hg merge 'desc("modify inside/f1")'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg ci -m 'merge from inside to outside'

Refuses merge of conflicting outside changes

  $ hg update -q 'desc("modify outside/f1")'
  $ hg merge 'desc("conflicting outside/f1")'
  abort: conflict in file 'outside/f1' is outside narrow clone (flat !)
  abort: conflict in file 'outside/' is outside narrow clone (tree !)
  [20]
