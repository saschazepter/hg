Test the basics
---------------

Create a new repo with the file index
  $ hg init repo1 --config format.exp-use-fileindex-v1=enable-unstable-format-and-corrupt-my-data
  $ cd repo1
  $ hg debugrequirements | grep -E 'fncache|dotencode|fileindex'
  exp-fileindex-v1
  $ hg debugformat --verbose fncache dotencode fileindex
  format-variant                 repo config default
  fncache:                         no    yes     yes
  fileindex-v1:                   yes     no      no
  dotencode:                       no    yes     yes
  $ hg debug::file-index
  $ hg debug::file-index --docket
  marker: fileindex-v1
  list_file_size: 0
  reserved_revlog_size: 0
  meta_file_size: 0
  tree_file_size: 0
  trash_file_size: 0
  list_file_id: 00000000
  reserved_revlog_id: 00000000
  meta_file_id: 00000000
  tree_file_id: 00000000
  tree_root_pointer: 0
  tree_unused_bytes: 0
  reserved_revlog_unused: 0
  trash_start_offset: 0
  reserved_flags: 0
  $ hg debug::file-index --tree
  00000000:
Add a file
  $ touch file
  $ hg add file
  $ hg commit -m 0

Confirm it's in the file index, not the fncache
  $ test -f .hg/store/fncache
  [1]
  $ ls .hg/store/fileindex*
  .hg/store/fileindex
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)
  $ hg debug::file-index
  0: file

Look up by path and by token
  $ hg debug::file-index --path file
  0: file
  $ hg debug::file-index --token 0
  0: file
  $ hg debug::file-index --path nonexistent
  abort: path nonexistent is not in the file index
  [10]
  $ hg debug::file-index --token 1
  abort: token 1 is not in the file index
  [10]

Examine the file index structure
  $ hg debug::file-index --docket
  marker: fileindex-v1
  list_file_size: 5
  reserved_revlog_size: 0
  meta_file_size: 8
  tree_file_size: 18
  trash_file_size: 0
  list_file_id: * (glob)
  reserved_revlog_id: 00000000
  meta_file_id: * (glob)
  tree_file_id: * (glob)
  tree_root_pointer: 0
  tree_unused_bytes: 0
  reserved_revlog_unused: 0
  trash_start_offset: 0
  reserved_flags: 0
  $ hg debug::file-index --tree
  00000000:
      "file" -> 0000000c
  0000000c: token = 0

Add more files
  $ touch fi filename other
  $ hg add
  adding fi
  adding filename
  adding other
  $ hg commit -m 1
  $ hg debug::file-index
  0: file
  1: fi
  2: filename
  3: other
  $ hg debug::file-index --path filename
  2: filename
  $ hg debug::file-index --token 3
  3: other
  $ hg debug::file-index --tree
  00000012:
      "fi" -> 0000002e
      "other" -> 00000028
  0000002e: token = 1
      "le" -> 0000003e
  0000003e: token = 0
      "name" -> 0000004e
  0000004e: token = 2
  00000028: token = 3

Test debug-revlog-stats to exercise walking the store.
  $ hg debug-revlog-stats --filelog
  rev-count   data-size inl type      target 
          1           0 yes file      fi
          1           0 yes file      file
          1           0 yes file      filename
          1           0 yes file      other

Test vacuuming the tree file
----------------------------

Manually vacuum tree
  $ old_id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ hg debug::file-index --vacuum
  vacuumed tree: 84 bytes => 66 bytes (saved 21.4%)
  $ new_id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ f --size ".hg/store/fileindex-tree.$old_id"
  .hg/store/fileindex-tree.*: size=84 (glob)
  $ f --size ".hg/store/fileindex-tree.$new_id"
  .hg/store/fileindex-tree.*: size=66 (glob)
  $ hg debug::file-index --vacuum
  vacuumed tree: 66 bytes => 66 bytes (saved 0.0%)

Force vacuuming tree during commit
  $ touch anotherfile
  $ hg add
  adding anotherfile
  $ hg --config storage.fileindex.max-unused-percentage=0 commit -m 2
  $ hg debug::file-index --docket | grep tree_unused_bytes
  tree_unused_bytes: 0

Test race where vacuuming happens between reading tree ID and opening file.
It should successfully read the old tree file (vacuuming shouldn't delete it
immediately). Use --path because it causes a lookup in the tree file.
  $ hg debug::file-index --path anotherfile > $TESTTMP/race-lock.out 2>&1 \
  > --config devel.sync.fileindex.pre-read-tree-file=$TESTTMP/race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/race-lock.waiting
  $ hg debug::file-index --vacuum
  vacuumed tree: 82 bytes => 82 bytes (saved 0.0%)
  $ touch $TESTTMP/race-lock
  $ wait
  $ cat $TESTTMP/race-lock.out
  4: anotherfile

  $ cd ..

Test removing paths with debugstrip
-----------------------------------

  $ hg init repostrip --config format.exp-use-fileindex-v1=enable-unstable-format-and-corrupt-my-data
  $ cd repostrip

Start with one file
  $ touch file0
  $ hg ci -qAm 0
  $ hg debug::file-index
  0: file0

Strip to remove the file
  $ hg debugstrip -q -r 0
  $ hg debug::file-index

Add the file back
  $ touch file0
  $ hg ci -qAm 0
  $ hg debug::file-index
  0: file0

Add another file
  $ touch file1
  $ hg ci -qAm 1
  $ hg debug::file-index
  0: file0
  1: file1

Strip to remove only the second file
  $ hg debugstrip -q -r 1
  $ hg debug::file-index
  0: file0

Add two more files
  $ touch file1
  $ hg ci -qAm 1
  $ hg up -q 0
  $ touch file2
  $ hg ci -qAm 2
  $ hg debug::file-index
  0: file0
  1: file1
  2: file2

Strip to remove the middle file
  $ hg debugstrip -q -r 1
  $ hg debug::file-index
  0: file0
  1: file2

  $ cd ..

Test removing paths with tracked
--------------------------------

  $ cp $HGRCPATH hgrc.backup
  $ . "$TESTDIR/narrow-library.sh"

Set up a narrow clone
  $ hg clone -q repostrip repotracked --narrow --include "" --config format.exp-use-fileindex-v1=enable-unstable-format-and-corrupt-my-data
  $ cd repotracked
  $ hg debug::file-index
  0: file0
  1: file2

Test excluding file0
  $ hg tracked -q --addexclude file0
  $ hg debug::file-index
  0: file2

Test excluding file2 too
  $ hg tracked -q --addexclude file2
  $ hg debug::file-index

  $ cd ..
  $ mv hgrc.backup $HGRCPATH

Test interaction with hooks
---------------------------

Access file index in pretxnclose hook
  $ hg init repohook --config format.exp-use-fileindex-v1=enable-unstable-format-and-corrupt-my-data
  $ cd repohook
  $ cat > .hg/hgrc <<EOF
  > [hooks]
  > pretxnclose = hg debug::file-index
  > EOF
  $ touch file
  $ hg add file
  $ hg commit -m 0 --verbose
  committing files:
  file
  committing manifest
  committing changelog
  running hook pretxnclose: hg debug::file-index
  0: file
  committed changeset 0:* (glob)

  $ cd ..

Test transaction failure and rollback
-------------------------------------

We test all combinations of these cases:

Rollback
- manual via hg rollback
- automatic when transaction fails
- with hg recover when transaction is abandoned
Vacuuming
- no (same tree file)
- yes (new tree file)

There are a few important things here:
1. Don't leave old tree files around forever, delete them at some point.
2. But leave them around long enough so we can rollback after a vacuum.
3. And in that case, also clean up the file we rolled back from at some point.
Currently we never clean up files so (2) always passes.
TODO: Implement file cleaning and add tests for (1) and (3).

Manul rollback, new file index (initial commit)
  $ hg init repotxn --config format.exp-use-fileindex-v1=enable-unstable-format-and-corrupt-my-data
  $ cd repotxn
  $ touch file
  $ hg commit -qAm 0
  $ hg rollback
  repository tip rolled back to revision -1 (undo commit)
  working directory now based on revision -1
  $ hg debug::file-index

Set up the following tests so we are adding to a nonempty file index
  $ hg commit -qAm 0 --config devel.fileindex.vacuum-mode=never
  $ touch file2
  $ original_id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ hg debug::file-index
  0: file

Manual rollback, same file
  $ hg commit -qAm 1 --config devel.fileindex.vacuum-mode=never
  $ hg rollback
  repository tip rolled back to revision 0 (undo commit)
  working directory now based on revision 0
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file

Manual rollback, new file
  $ hg commit -qAm 1 --config devel.fileindex.vacuum-mode=always
  $ hg rollback
  repository tip rolled back to revision 0 (undo commit)
  working directory now based on revision 0
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file

Abort transaction, same file
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=abort-post-finalize --config devel.fileindex.vacuum-mode=never
  transaction abort!
  rollback completed
  abort: requested abort-post-finalize
  [255]
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file

Abort transaction, new file
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=abort-post-finalize --config devel.fileindex.vacuum-mode=always
  transaction abort!
  rollback completed
  abort: requested abort-post-finalize
  [255]
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file

Recover transaction, same file
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=kill-9-post-finalize --config devel.fileindex.vacuum-mode=never || echo exit=$?
  *Killed* (glob) (no-chg !)
  exit=137 (no-chg !)
  exit=255 (chg !)
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file
  1: file2
  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file

Recover transaction, new file
  $ id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=kill-9-post-finalize --config devel.fileindex.vacuum-mode=always || echo exit=$?
  *Killed* (glob) (no-chg !)
  exit=137 (no-chg !)
  exit=255 (chg !)
  $ test "$id" != "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file
  1: file2
  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)
  $ test "$id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  0: file
