============================================================
Test how `hg status` behavior for file with ambiguous length
============================================================

#testcases dirstate-v1 dirstate-v2
#testcases parents-swap delta-info

Some file have an actual file size that differs from the "uncompressed size"
stored in the revlog index. This happens mostly because of metadata.

As the `hg status` logic uses the stored file size to fast path modification
checks, this can create issues.

The logic for this fast path mostly happens when the on-disk mtime is different
from the one in the dirstate but the size is the same as the one expected in
the dirstate.

Here we will be testing two ways of having different sizes:

 A: the file has rename information
 B: the initial bytes of the file are the same as a metadata header, so empty metadata are stored

Before the "delta-info" format, a revision's parentage was used to detect
metadata in some cases. So we will be testing multiple parentage cases:

 1: the file revision has no parent
 2: the file revision has a single parent
 3: the file revision has two parents

The combinations of the two dimensions will be denoted A1, A2, …, B3

 ┌──────────────┬────┬────┬────┐
 │    ╲ parents │ 0  │ 1  │ 2  │
 │ metadata ╲   │    │    │    │
 ├──────────────┼────┼────┼────┤
 │              │    │    │    │
 │ rename       │ A1 │ A2 │ ø  │
 │              │    │    │    │
 ├──────────────┼────┼────┼────┤
 │              │    │    │    │
 │ "\1\n" start │ B1 │ B2 │ B3 │
 │              │    │    │    │
 └──────────────┴────┴────┴────┘

(Case A3 can't happen, see A2 documentation for details)

We test with both dirstate-v1 and dirstate-v2 as they store slightly different
information and use different logic.

We also test with and without delta-info as this uses different logic to detect
metadata presence.

Variant setup
=============

#if dirstate-v2
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=yes
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF
#else
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=no
  > EOF
#endif


#if delta-info
  $ cat << EOF >> $HGRCPATH
  > [format]
  > use-delta-info-flags=yes
  > EOF
#else
  $ cat << EOF >> $HGRCPATH
  > [format]
  > use-delta-info-flags=no
  > EOF
#endif

Case-A1
=======

file-revision with rename metadata but no parents

"A1" requires a rename, so we create "old_A1" to be renamed to "A1" in the next
changeset

  $ hg init repo-A1
  $ cd repo-A1

  $ echo foo >> old_A1
  $ hg add old_A1
  $ hg commit -m 'c01c'
  $ hg mv old_A1 A1
  $ hg commit -m 'c02c'
  $ hg debugindex A1
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       1 2e5eab2edf5c 000000000000 000000000000

Make sure we a nice and new clean dirstate

  $ hg up -C null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that status report the file as clean when the mtime is ambiguous

  $ touch -t 200001010000 A1
  $ env RHG_ON_UNSUPPORTED=abort hg status --all A1
  C A1 (no-rhg !)
  C A1 (rhg no-delta-info !)
  M A1 (rhg delta-info known-bad-output !)

  $ cd ..

Case-A1 second
==============

This case highlights that the rename always replaces one parent.

(we don't really care that the rename replaces the parent, but we want to test
the behavior of status in that case)

File revision with a rename and 1 parent. This can be achieved by renaming a
file over another one.

  $ hg init repo-A1s
  $ cd repo-A1s

  $ echo bar >> A1s
  $ echo baz >> old_A1s
  $ hg add old_A1s A1s
  $ hg commit -m 'c01c'
  $ hg mv old_A1s A1s --force
  $ hg commit -m 'c02c'
  $ hg debugindex A1s
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 b004912a8510 000000000000 000000000000
       1       1 6b58d91010da 000000000000 000000000000

Make sure we have a nice and new clean dirstate

  $ hg up -C null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that status reports the file as clean when the mtime is ambiguous

  $ touch -t 200001010000 A1s
  $ env RHG_ON_UNSUPPORTED=abort hg status --all A1s
  C A1s (no-rhg !)
  C A1s (rhg no-delta-info !)
  M A1s (rhg delta-info known-bad-output !)

  $ cd ..

Case-A2
=======

Even in case of a merge, the rename will only preserve one of the two parents.

So case A3 isn't possible and this creates A2 (with the infamous parent swap
that created issue6528).

(we don't really care than the rename replaces the parent, but we want to test
the behavior of status in that case)

  $ hg init repo-A2
  $ cd repo-A2
  $ cat << EOF > A2
  > initial
  > content
  > EOF
  $ echo foo >> old_A2
  $ hg add A2 old_A2
  $ hg commit -m 'c01c'
  $ cat << EOF > A2
  > left
  > initial
  > content
  > EOF
  $ hg commit -m 'c02c'
  $ hg up '.~1'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat << EOF > A2
  > initial
  > content
  > right
  > EOF
  $ hg commit -m 'c03c'
  created new head
  $ hg merge
  merging A2
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg mv old_A2 A2 --force
  $ hg commit -m 'c04c'
  $ hg debugindex A2
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 52535790e5a4 000000000000 000000000000
       1       1 a75f9ba0708f 52535790e5a4 000000000000
       2       2 ea304aefd227 52535790e5a4 000000000000
       3       3 1acf5a646c20 000000000000 a75f9ba0708f (parents-swap !)
       3       3 1acf5a646c20 a75f9ba0708f 000000000000 (delta-info !)

Make sure we have a nice and new clean dirstate

  $ hg up -C null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that status reports the file as clean when the mtime is ambiguous

  $ touch -t 200001010000 A2
  $ env RHG_ON_UNSUPPORTED=abort hg status --all A2
  C A2 (no-rhg !)
  C A2 (rhg no-delta-info !)
  M A2 (rhg delta-info known-bad-output !)

  $ cd ..

Case-B1
=======

"B1" is simple, we just commit a new file whose content starts with a "metadata
header"

  $ hg init repo-B1
  $ cd repo-B1


  >>> with open('B1', 'wb') as f:
  ...     f.write(b"\x01\nfooB1")
  7
  $ hg add B1
  $ hg commit -m 'c01c'
  $ hg debugindex B1
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 18007faa00ac 000000000000 000000000000

Make sure we have a nice and new clean dirstate

  $ hg up -C null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that status reports the file as clean when the mtime is ambiguous

  $ touch -t 200001010000 B1
  $ env RHG_ON_UNSUPPORTED=abort hg status --all B1
  C B1 (no-rhg !)
  C B1 (rhg no-delta-info !)
  M B1 (rhg delta-info known-bad-output !)

  $ cd ..

Case-B2
=======
  $ hg init repo-B2
  $ cd repo-B2

"B2" wants a parent, so we need a first version to iterate over

  $ echo fooB2 >> B2
  $ hg add B2
  $ hg commit -m 'c01c'
  >>> with open('B2', 'wb') as f:
  ...     f.write(b"\x01\nfooB2")
  7
  $ hg commit -m 'c02c'
  $ hg debugindex B2
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 288ace91caa7 000000000000 000000000000
       1       1 99f93d9af14a 000000000000 288ace91caa7 (parents-swap !)
       1       1 99f93d9af14a 288ace91caa7 000000000000 (delta-info !)

Make sure we have a nice and new clean dirstate

  $ hg up -C null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ hg up tip
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that status reports the file as clean when the mtime is ambiguous

  $ touch -t 200001010000 B2
  $ env RHG_ON_UNSUPPORTED=abort hg status --all B2
  C B2 (no-rhg !)
  C B2 (rhg no-delta-info !)
  M B2 (rhg delta-info known-bad-output !)

  $ cd ..

Case-B3
=======

A case with two parents, so we need a merge, with the content starting with a
metadata header.

  $ hg init repo-B3
  $ cd repo-B3
  $ cat << EOF > B3
  > initial
  > content
  > EOF
  $ echo foo >> old_B3
  $ hg add B3 old_B3
  $ hg commit -m 'c01c'
  $ cat << EOF > B3
  > left
  > initial
  > content
  > EOF
  $ hg commit -m 'c02c'
  $ hg up '.~1'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat << EOF > B3
  > initial
  > content
  > right
  > EOF
  $ hg commit -m 'c03c'
  created new head
  $ hg merge
  merging B3
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  >>> with open('B3', 'wb') as f:
  ...     f.write(b"\x01\nfooB2")
  7
  $ hg commit -m 'c04c'
  $ hg debugindex B3
     rev linkrev       nodeid    p1-nodeid    p2-nodeid
       0       0 52535790e5a4 000000000000 000000000000
       1       1 a75f9ba0708f 52535790e5a4 000000000000
       2       2 ea304aefd227 52535790e5a4 000000000000
       3       3 9ff56e8cfdcb ea304aefd227 a75f9ba0708f

Make sure we have a nice and new clean dirstate

  $ hg up -C null
  0 files updated, 0 files merged, 2 files removed, 0 files unresolved
  $ hg up tip
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Test that status reports the file as clean when the mtime is ambiguous

  $ touch -t 200001010000 B3
  $ env RHG_ON_UNSUPPORTED=abort hg status --all B3
  C B3 (no-rhg !)
  C B3 (rhg no-delta-info !)
  M B3 (rhg delta-info known-bad-output !)

  $ cd ..
