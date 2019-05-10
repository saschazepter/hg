
  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > copies.write-to=changeset-only
  > copies.read-from=changeset-only
  > [alias]
  > changesetcopies = log -r . -T 'files: {files}
  >   {extras % "{ifcontains("copies", key, "{key}: {value}\n")}"}'
  > showcopies = log -r . -T '{file_copies % "{source} -> {name}\n"}'
  > [extensions]
  > rebase =
  > EOF

Check that copies are recorded correctly

  $ hg init repo
  $ cd repo
  $ echo a > a
  $ hg add a
  $ hg ci -m initial
  $ hg cp a b
  $ hg cp a c
  $ hg cp a d
  $ hg ci -m 'copy a to b, c, and d'
  $ hg changesetcopies
  files: b c d
  p1copies: b\x00a (esc)
  c\x00a (esc)
  d\x00a (esc)
  $ hg showcopies
  a -> b
  a -> c
  a -> d
  $ hg showcopies --config experimental.copies.read-from=compatibility
  a -> b
  a -> c
  a -> d
  $ hg showcopies --config experimental.copies.read-from=filelog-only

Check that renames are recorded correctly

  $ hg mv b b2
  $ hg ci -m 'rename b to b2'
  $ hg changesetcopies
  files: b b2
  p1copies: b2\x00b (esc)
  $ hg showcopies
  b -> b2

Rename onto existing file. This should get recorded in the changeset files list and in the extras,
even though there is no filelog entry.

  $ hg cp b2 c --force
  $ hg st --copies
  M c
    b2
  $ hg debugindex c
     rev linkrev nodeid       p1           p2
       0       1 b789fdd96dc2 000000000000 000000000000
  $ hg ci -m 'move b onto d'
  $ hg changesetcopies
  files: c
  p1copies: c\x00b2 (esc)
  $ hg showcopies
  b2 -> c
  $ hg debugindex c
     rev linkrev nodeid       p1           p2
       0       1 b789fdd96dc2 000000000000 000000000000

Create a merge commit with copying done during merge.

  $ hg co 0
  0 files updated, 0 files merged, 3 files removed, 0 files unresolved
  $ hg cp a e
  $ hg cp a f
  $ hg ci -m 'copy a to e and f'
  created new head
  $ hg merge 3
  3 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
File 'a' exists on both sides, so 'g' could be recorded as being from p1 or p2, but we currently
always record it as being from p1
  $ hg cp a g
File 'd' exists only in p2, so 'h' should be from p2
  $ hg cp d h
File 'f' exists only in p1, so 'i' should be from p1
  $ hg cp f i
  $ hg ci -m 'merge'
  $ hg changesetcopies
  files: g h i
  p1copies: g\x00a (esc)
  i\x00f (esc)
  p2copies: h\x00d (esc)
  $ hg showcopies
  a -> g
  d -> h
  f -> i

Test writing to both changeset and filelog

  $ hg cp a j
  $ hg ci -m 'copy a to j' --config experimental.copies.write-to=compatibility
  $ hg changesetcopies
  files: j
  p1copies: j\x00a (esc)
  $ hg debugdata j 0
  \x01 (esc)
  copy: a
  copyrev: b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3
  \x01 (esc)
  a
  $ hg showcopies
  a -> j
  $ hg showcopies --config experimental.copies.read-from=compatibility
  a -> j
  $ hg showcopies --config experimental.copies.read-from=filelog-only
  a -> j

Test writing only to filelog

  $ hg cp a k
  $ hg ci -m 'copy a to k' --config experimental.copies.write-to=filelog-only
  $ hg changesetcopies
  files: k
  $ hg debugdata k 0
  \x01 (esc)
  copy: a
  copyrev: b789fdd96dc2f3bd229c1dd8eedf0fc60e2b68e3
  \x01 (esc)
  a
  $ hg showcopies
  $ hg showcopies --config experimental.copies.read-from=compatibility
  a -> k
  $ hg showcopies --config experimental.copies.read-from=filelog-only
  a -> k

  $ cd ..

Test rebasing a commit with copy information

  $ hg init rebase-rename
  $ cd rebase-rename
  $ echo a > a
  $ hg ci -Aqm 'add a'
  $ echo a2 > a
  $ hg ci -m 'modify a'
  $ hg co -q 0
  $ hg mv a b
  $ hg ci -qm 'rename a to b'
  $ hg rebase -d 1 --config rebase.experimental.inmemory=yes
  rebasing 2:55d0b405c1b2 "rename a to b" (tip)
  merging a and b to b
  saved backup bundle to $TESTTMP/rebase-rename/.hg/strip-backup/55d0b405c1b2-78df867e-rebase.hg
  $ hg st --change . --copies
  A b
    a
  R a
  $ cd ..
