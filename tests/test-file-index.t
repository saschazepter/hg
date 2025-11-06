#if no-rust
  $ cat << EOF >> $HGRCPATH
  > [storage]
  > fileindex.slow-path=allow
  > EOF
#endif

Test the basics
---------------

Create a new repo with the file index
  $ hg init repo1 --config format.use-fileindex-v1=1
  $ cd repo1
  $ hg debugrequirements | grep -E 'fncache|dotencode|fileindex'
  fileindex-v1
  $ hg debugformat --verbose fncache dotencode fileindex
  format-variant                 repo config default
  fncache:                         no    yes     yes
  fileindex-v1:                   yes     no      no
  dotencode:                       no    yes     yes
  $ hg debug::file-index
  $ hg debug::file-index --docket
  marker: fileindex-v1
  list_file_size: 0
  meta_file_size: 0
  tree_file_size: 0
  list_file_id: 00000000
  meta_file_id: 00000000
  tree_file_id: 00000000
  tree_root_pointer: 0
  tree_unused_bytes: 0
  reserved_flags: 0
  garbage_entries: 0
  $ hg debug::file-index --tree
  00000000: "" (0)
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
  1: file

Look up by path and by token
  $ hg debug::file-index --path file
  1: file
  $ hg debug::file-index --token 1
  1: file
  $ hg debug::file-index --path nonexistent
  abort: path nonexistent is not in the file index
  [10]
  $ hg debug::file-index --token 0
  abort: token 0 is not in the file index
  [10]
  $ hg debug::file-index --token 2
  abort: token 2 is not in the file index
  [10]

Examine the file index structure
  $ hg debug::file-index --docket
  marker: fileindex-v1
  list_file_size: 5
  meta_file_size: 16
  tree_file_size: 11
  list_file_id: * (glob)
  meta_file_id: * (glob)
  tree_file_id: * (glob)
  tree_root_pointer: 0
  tree_unused_bytes: 0
  reserved_flags: 0
  garbage_entries: 0
  $ hg debug::file-index --tree
  00000000: "" (0)
      "f" -> "file" (1)

Add more files
  $ touch fi filename other
  $ hg add
  adding fi
  adding filename
  adding other
  $ hg commit -m 1
  $ hg debug::file-index
  1: file
  2: fi
  3: filename
  4: other
  $ hg debug::file-index --path filename
  3: filename
  $ hg debug::file-index --token 3
  3: filename
  $ hg debug::file-index --tree
  0000000b: "" (0)
      "f" -> 0000001b
      "o" -> "other" (4)
  0000001b: "fi" (2)
      "l" -> 00000026
  00000026: "le" (1)
      "n" -> "name" (3)

Test debug-revlog-stats to exercise walking the store.
  $ hg debug-revlog-stats --filelog
  rev-count   data-size inl type      target 
          1           0 yes file      fi
          1           0 yes file      file
          1           0 yes file      filename
          1           0 yes file      other

Test formatting
---------------

We can format the docket as JSON
  $ hg debug::file-index --docket -Tjson
  [
   {
    "garbage_entries": [],
    "list_file_id": "*", (glob)
    "list_file_size": 23,
    "marker": "fileindex-v1",
    "meta_file_id": "*", (glob)
    "meta_file_size": 40,
    "reserved_flags": 0,
    "tree_file_id": "*", (glob)
    "tree_file_size": 49,
    "tree_root_pointer": 11,
    "tree_unused_bytes": 11
   }
  ]

Test vacuuming the tree file
----------------------------

Manually vacuum tree
  $ old_id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ hg debug::file-index --vacuum
  vacuumed tree: 49 bytes => 38 bytes (saved 22.4%)
  $ new_id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ f --size ".hg/store/fileindex-tree.$old_id"
  .hg/store/fileindex-tree.*: size=49 (glob)
  $ f --size ".hg/store/fileindex-tree.$new_id"
  .hg/store/fileindex-tree.*: size=38 (glob)
  $ hg debug::file-index --vacuum
  vacuumed tree: 38 bytes => 38 bytes (saved 0.0%)

Force vacuuming tree during commit
  $ touch anotherfile
  $ hg add
  adding anotherfile
  $ hg --config devel.fileindex.vacuum-mode=always commit -m 2
  $ hg debug::file-index --docket -T '{tree_unused_bytes}\n'
  0

Test race where vacuuming happens between reading tree ID and opening file.
It should successfully read the old tree file (vacuuming shouldn't delete it
immediately). Use --path because it causes a lookup in the tree file.
  $ hg debug::file-index --path anotherfile > $TESTTMP/race-lock.out 2>&1 \
  > --config devel.sync.fileindex.pre-read-data-files=$TESTTMP/race-lock \
  > &
  $ $RUNTESTDIR/testlib/wait-on-file 5 $TESTTMP/race-lock.waiting
  $ hg debug::file-index --vacuum
  vacuumed tree: 43 bytes => 43 bytes (saved 0.0%)
  $ touch $TESTTMP/race-lock
  $ wait
  $ cat $TESTTMP/race-lock.out
  5: anotherfile

Vacuum empty tree (no data files)
  $ hg init $TESTTMP/repoempty --config format.use-fileindex-v1=1
  $ hg -R $TESTTMP/repoempty debug::file-index --vacuum
  vacuumed tree: 0 bytes => 0 bytes (saved 0.0%)
Vacuum empty tree again (data files exist)
  $ hg -R $TESTTMP/repoempty debug::file-index --vacuum
  vacuumed tree: 0 bytes => 0 bytes (saved 0.0%)

Test cleaning up old files
--------------------------

There should be multiple tree files now
  $ ls .hg/store/fileindex-tree.*
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)

All except one are garbage
  $ hg debug::file-index --docket -T '{garbage_entries % "{path}\n"}'
  fileindex-tree.* (glob)
  fileindex-tree.* (glob)
  fileindex-tree.* (glob)
  fileindex-tree.* (glob)

Force garbage collection
  $ hg debug::file-index --gc
  $ ls .hg/store/fileindex-tree.*
  .hg/store/fileindex-tree.* (glob)
  $ hg debug::file-index --docket -T '{garbage_entries % "{path}\n"}'

Make another tree
  $ hg debug::file-index --vacuum
  vacuumed tree: 43 bytes => 43 bytes (saved 0.0%)
  $ ls .hg/store/fileindex-tree*
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  $ hg debug::file-index --docket -T '{garbage_entries % "{path} ttl={ttl}\n"}'
  fileindex-tree.* ttl=2 (glob)
Delete the old tree via automatic gc during after 2 transactions.
  $ hg ci -qAm "empty" --config ui.allowemptycommit=True --config storage.fileindex.gc-retention-seconds=0
  $ hg debug::file-index --docket -T '{garbage_entries % "{path} ttl={ttl}\n"}'
  fileindex-tree.* ttl=1 (glob)
  $ hg ci -qAm "empty" --config ui.allowemptycommit=True --config storage.fileindex.gc-retention-seconds=0
  $ hg debug::file-index --docket -T '{garbage_entries % "{path} ttl={ttl}\n"}'
  $ ls .hg/store/fileindex-tree*
  .hg/store/fileindex-tree.* (glob)

Produce garbage entries with fake timestamps
Avoid GC while doing so, since we want to test GC once at the end
  $ max_uint32=4294967295
  $ disable_gc="--config storage.fileindex.gc-retention-seconds=$max_uint32"
Override the first entry's timestamp to zero (Jan 1970)
  $ hg debug::file-index --vacuum --config devel.fileindex.garbage-timestamp=0 $disable_gc
  vacuumed tree: 43 bytes => 43 bytes (saved 0.0%)
Leave the second entry's timestamp at the current time
  $ hg debug::file-index --vacuum $disable_gc
  vacuumed tree: 43 bytes => 43 bytes (saved 0.0%)
Override the third entry's timestamp to the max uint32 (Feb 2106)
  $ hg debug::file-index --vacuum --config devel.fileindex.garbage-timestamp=$max_uint32 $disable_gc
  vacuumed tree: 43 bytes => 43 bytes (saved 0.0%)
  $ ls .hg/store/fileindex-tree*
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  $ hg debug::file-index --docket -T '{garbage_entries % "{path} timestamp={timestamp}\n"}'
  fileindex-tree.* timestamp=0 (glob)
  fileindex-tree.* timestamp=* (glob)
  fileindex-tree.* timestamp=4294967295 (glob)
Trigger gc again with a day long retention period
  $ hg ci -qAm "empty" --config ui.allowemptycommit=True --config storage.fileindex.gc-retention-seconds=86400
It only deleted the first entry
  $ ls .hg/store/fileindex-tree*
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  $ hg debug::file-index --docket -T '{garbage_entries % "{path} timestamp={timestamp}\n"}'
  fileindex-tree.* timestamp=* (glob)
  fileindex-tree.* timestamp=4294967295 (glob)

  $ cd ..

Test removing paths with debugstrip
-----------------------------------

  $ hg init repostrip --config format.use-fileindex-v1=1
  $ cd repostrip

Start with one file
  $ touch file0
  $ hg ci -qAm 0
  $ hg debug::file-index
  1: file0

Strip to remove the file
  $ hg debugstrip -q -r 0
  $ hg debug::file-index

Add the file back
  $ touch file0
  $ hg ci -qAm 0
  $ hg debug::file-index
  1: file0

Add another file
  $ touch file1
  $ hg ci -qAm 1
  $ hg debug::file-index
  1: file0
  2: file1

Strip to remove only the second file
  $ hg debugstrip -q -r 1
  $ hg debug::file-index
  1: file0

Add two more files
  $ touch file1
  $ hg ci -qAm 1
  $ hg up -q 0
  $ touch file2
  $ hg ci -qAm 2
  $ hg debug::file-index
  1: file0
  2: file1
  3: file2

Strip to remove the middle file
  $ hg debugstrip -q -r 1
  $ hg debug::file-index
  1: file0
  2: file2

Strip to remove the remaining files
  $ hg debugstrip -q -r 0
  $ hg debug::file-index
  $ hg debug::file-index --docket -T 'size={tree_file_size}, root={tree_root_pointer}\n'
  size=0, root=0

  $ cd ..

Test removing paths with tracked
--------------------------------

  $ cp $HGRCPATH hgrc.backup
  $ . "$TESTDIR/narrow-library.sh"

Create source repository
  $ hg init repofull --config format.exp-use-fileindex-v1=enable-unstable-format-and-corrupt-my-data
  $ cd repofull
  $ touch file0 file1
  $ hg ci -qAm 0
  $ cd ..

Set up a narrow clone
  $ hg clone -q repofull repotracked --narrow --include "" --config format.use-fileindex-v1=1
  $ cd repotracked
  $ hg debug::file-index
  1: file0
  2: file1

Test excluding file0
  $ hg tracked -q --addexclude file0
  $ hg debug::file-index
  1: file1

Test excluding file1 too
  $ hg tracked -q --addexclude file1
  $ hg debug::file-index

  $ cd ..
  $ mv hgrc.backup $HGRCPATH

Test interaction with hooks
---------------------------

Access file index in pretxnclose hook
  $ hg init repohook --config format.use-fileindex-v1=1
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
  1: file
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
1. Delete old files at some point (see "Test cleaning up old files" above).
2. But leave them around long enough so we can rollback after a vacuum.
3. And in that case, also clean up the file we rolled back from.

  $ hg init repotxn --config format.use-fileindex-v1=1
  $ cd repotxn

Retention is based on time and TTL (a transaction countdown). Disable the
time-based retention to show that TTL alone is sufficient for rollback/recovery.
  $ cat > .hg/hgrc <<EOF
  > [storage]
  > fileindex.gc-retention-seconds=0
  > EOF

Manul rollback, new file index (initial commit)
  $ touch file
  $ hg commit -qAm 0
  $ hg rollback
  repository tip rolled back to revision -1 (undo commit)
  working directory now based on revision -1
  $ hg debug::file-index
Rolling back removes the file index files.
  $ ls .hg/store | grep fileindex
  [1]

Set up the following tests so we are adding to a nonempty file index
  $ hg commit -qAm 0 --config devel.fileindex.vacuum-mode=never
  $ touch file2
  $ original_id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ hg debug::file-index
  1: file

Manual rollback, same file
  $ hg commit -qAm 1 --config devel.fileindex.vacuum-mode=never
  $ hg rollback
  repository tip rolled back to revision 0 (undo commit)
  working directory now based on revision 0
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  $ ls .hg/store/fileindex-*
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)

Manual rollback, new file
  $ hg commit -qAm 1 --config devel.fileindex.vacuum-mode=always
  $ hg rollback
  repository tip rolled back to revision 0 (undo commit)
  working directory now based on revision 0
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  $ ls .hg/store/fileindex-*
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)

Abort transaction, same file
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=abort-post-finalize --config devel.fileindex.vacuum-mode=never
  transaction abort!
  rollback completed
  abort: requested abort-post-finalize
  [255]
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  $ ls .hg/store/fileindex-*
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)

Abort transaction, new file
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=abort-post-finalize --config devel.fileindex.vacuum-mode=always
  transaction abort!
  rollback completed
  abort: requested abort-post-finalize
  [255]
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  $ ls .hg/store/fileindex-*
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)

Recover transaction, same file
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=kill-9-post-finalize --config devel.fileindex.vacuum-mode=never || echo exit=$?
  *Killed* (glob) (no-chg !)
  exit=137 (no-chg !)
  exit=255 (chg !)
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  2: file2
  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)
  $ test "$original_id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  $ ls .hg/store/fileindex-*
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)

Recover transaction, new file
  $ id=$(hg debug::file-index --docket -T '{tree_file_id}')
  $ hg commit -qAm 1 --config devel.debug.abort-transaction=kill-9-post-finalize --config devel.fileindex.vacuum-mode=always || echo exit=$?
  *Killed* (glob) (no-chg !)
  exit=137 (no-chg !)
  exit=255 (chg !)
  $ test "$id" != "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  2: file2
  $ hg recover
  rolling back interrupted transaction
  (verify step skipped, run `hg verify` to check your repository content)
  $ test "$id" = "$(hg debug::file-index --docket -T '{tree_file_id}')"
  $ hg debug::file-index
  1: file
  $ ls .hg/store/fileindex-*
  .hg/store/fileindex-list.* (glob)
  .hg/store/fileindex-meta.* (glob)
  .hg/store/fileindex-tree.* (glob)

  $ cd ..

Test upgrading from fncache to fileindex and back
-------------------------------------------------

Create an empty repo with fncache
  $ hg init repoupgrade --config format.use-fileindex-v1=0
  $ cd repoupgrade
  $ hg debugformat fileindex
  format-variant                 repo
  fileindex-v1:                    no
  $ hg debug::file-index
  abort: this repository does not have a file index
  [20]

Removing fncache is not allowed if you aren't upgrading to file index
  $ hg debugupgrade --config format.usefncache=0 --config format.use-fileindex-v1=0 --run
  abort: cannot upgrade repository; requirement would be removed: fncache
  [255]

Upgrade empty repo from fncache to fileindex
  $ hg debugupgrade --config format.use-fileindex-v1=1 --run
  note:    selecting all-filelogs for processing to change: dotencode
  note:    selecting all-manifestlogs for processing to change: fncache
  note:    selecting changelog for processing to change: fncache
  
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: dotencode, fncache
     added: fileindex-v1
  
  fileindex-v1
     transactions that add files will be faster in large repos
  
  processed revlogs:
    - all-filelogs
    - changelog
    - manifest
  
  beginning upgrade...
  repository locked and read-only
  creating temporary repository to stage upgraded data: $TESTTMP/repoupgrade/.hg/upgrade.* (glob)
  (it is safe to interrupt this process any time before data migration completes)
  upgrading from fncache to fileindex-v1
  replaced files will be backed up at $TESTTMP/repoupgrade/.hg/upgradebackup.* (glob)
  removing temporary repository $TESTTMP/repoupgrade/.hg/upgrade.* (glob)
  $ hg debug::file-index

You can't roll back the fast path upgrade
  $ hg rollback
  no rollback information available
  [1]

Removing file index is not allowed if you aren't downgrading to fncache
  $ hg debugupgrade --config format.usefncache=0 --config format.use-fileindex-v1=0 --run
  abort: cannot upgrade repository; requirement would be removed: fileindex-v1
  [255]

Downgrade empty repo to fncache
  $ hg debugupgrade --config format.use-fileindex-v1=0 --run
  note:    selecting all-filelogs for processing to change: dotencode
  note:    selecting all-manifestlogs for processing to change: fncache
  note:    selecting changelog for processing to change: fncache
  
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: fileindex-v1
     added: dotencode, fncache
  
  fncache
     repository will be more resilient to storing certain paths and performance of certain operations should be improved
  
  dotencode
     repository will be better able to store files beginning with a space or period
  
  processed revlogs:
    - all-filelogs
    - changelog
    - manifest
  
  beginning upgrade...
  repository locked and read-only
  creating temporary repository to stage upgraded data: $TESTTMP/repoupgrade/.hg/upgrade.* (glob)
  (it is safe to interrupt this process any time before data migration completes)
  copying requires
  data fully upgraded in a temporary repository
  marking source repository as being upgraded; clients will be unable to read from repository
  starting in-place swap of repository data
  replaced files will be backed up at $TESTTMP/repoupgrade/.hg/upgradebackup.* (glob)
  replacing store...
  store replacement complete; repository was inconsistent for *s (glob)
  finalizing requirements file and making repository readable again
  removing temporary repository $TESTTMP/repoupgrade/.hg/upgrade.* (glob)
  copy of old repository backed up at $TESTTMP/repoupgrade/.hg/upgradebackup.* (glob)
  the old repository will not be deleted; remove it to free up disk space once the upgraded repository is verified
  $ hg debug::file-index
  abort: this repository does not have a file index
  [20]

Add a file, then upgrade to fileindex
  $ touch f1
  $ hg add f1
  $ hg ci -m 0
  $ cat .hg/store/fncache | sort
  data/f1.i
  $ hg debugupgrade --config format.use-fileindex-v1=1 --run > /dev/null
  $ test -f .hg/store/fncache
  [1]
  $ hg debug::file-index
  1: f1

Add another file, then downgrade to fncache
  $ touch f2
  $ hg add f2
  $ hg ci -m 1
  $ hg debugupgrade --config format.use-fileindex-v1=0 --run > /dev/null
  copy of old repository backed up at $TESTTMP/repoupgrade/.hg/upgradebackup.* (glob)
  the old repository will not be deleted; remove it to free up disk space once the upgraded repository is verified
  $ cat .hg/store/fncache | sort
  data/f1.i
  data/f2.i
  $ hg debug::file-index
  abort: this repository does not have a file index
  [20]

Finally, upgrade back to fileindex
  $ hg debugupgrade --config format.use-fileindex-v1=1 --run > /dev/null
  $ hg debug::file-index
  1: f1
  2: f2

Test compatiblity of Python and Rust implementations
----------------------------------------------------

#if rust

  $ hg init repocompat --config format.use-fileindex-v1=1
  $ cd repocompat
  $ cat << EOF >> .hg/hgrc
  > [storage]
  > fileindex.slow-path=allow
  > EOF

Add files with Python, read with Rust
  $ touch file0
  $ HGMODULEPOLICY=py hg commit -qAm 0
  $ hg debug::file-index
  1: file0
  $ hg debug::file-index --docket
  marker: fileindex-v1
  list_file_size: 6
  meta_file_size: 16
  tree_file_size: 11
  list_file_id: * (glob)
  meta_file_id: * (glob)
  tree_file_id: * (glob)
  tree_root_pointer: 0
  tree_unused_bytes: 0
  reserved_flags: 0
  garbage_entries: 0
  $ hg debug::file-index --tree
  00000000: "" (0)
      "f" -> "file0" (1)

Vacuum with Python, GC with Rust
  $ HGMODULEPOLICY=py hg debug::file-index --vacuum
  vacuumed tree: 11 bytes => 11 bytes (saved 0.0%)
  $ hg debug::file-index --docket -T '{garbage_entries % "{path}\n"}'
  fileindex-tree.* (glob)
  $ ls .hg/store/fileindex-tree.*
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  $ hg debug::file-index --gc
  $ ls .hg/store/fileindex-tree.*
  .hg/store/fileindex-tree.* (glob)

Add files with Rust, read with Python
  $ touch file1
  $ hg commit -qAm 1
  $ HGMODULEPOLICY=py hg debug::file-index
  1: file0
  2: file1
  $ HGMODULEPOLICY=py hg debug::file-index --docket
  marker: fileindex-v1
  list_file_size: 12
  meta_file_size: 24
  tree_file_size: 38
  list_file_id: * (glob)
  meta_file_id: * (glob)
  tree_file_id: * (glob)
  tree_root_pointer: 11
  tree_unused_bytes: 11
  reserved_flags: 0
  garbage_entries: 0
  $ HGMODULEPOLICY=py hg debug::file-index --tree
  0000000b: "" (0)
      "f" -> 00000016
  00000016: "file" (2)
      "0" -> "0" (1)
      "1" -> "1" (2)

Vacuum with Rust, GC with Python
  $ hg debug::file-index --vacuum
  vacuumed tree: 38 bytes => 27 bytes (saved 28.9%)
  $ HGMODULEPOLICY=py hg debug::file-index --docket -T '{garbage_entries % "{path}\n"}'
  fileindex-tree.* (glob)
  $ ls .hg/store/fileindex-tree.*
  .hg/store/fileindex-tree.* (glob)
  .hg/store/fileindex-tree.* (glob)
  $ HGMODULEPOLICY=py hg debug::file-index --gc
  $ ls .hg/store/fileindex-tree.*
  .hg/store/fileindex-tree.* (glob)

  $ cd ..

#endif

Test various prefix tree structures
-----------------------------------

  $ hg init repotree --config format.use-fileindex-v1=1
  $ cd repotree

Paths with distinct prefix
  $ touch foo bar
  $ hg commit -qAm 0
  $ hg debug::file-index --tree
  00000000: "" (0)
      "b" -> "bar" (1)
      "f" -> "foo" (2)
  $ hg debug::file-index --path foo
  2: foo
  $ hg debug::file-index --path bar
  1: bar
  $ hg debug::file-index --path baz
  abort: path baz is not in the file index
  [10]

Paths with a common prefix
  $ touch fun
  $ hg commit -qAm 1
  $ hg debug::file-index --tree
  00000010: "" (0)
      "b" -> "bar" (1)
      "f" -> 00000020
  00000020: "f" (3)
      "o" -> "oo" (2)
      "u" -> "un" (3)
  $ hg debug::file-index --path foo
  2: foo
  $ hg debug::file-index --path fun
  3: fun
  $ hg debug::file-index --path f
  abort: path f is not in the file index
  [10]

Paths where one is a prefix of the other
  $ touch food
  $ hg commit -qAm 2
  $ hg debug::file-index --tree
  00000030: "" (0)
      "b" -> "bar" (1)
      "f" -> 00000040
  00000040: "f" (3)
      "o" -> 00000050
      "u" -> "un" (3)
  00000050: "oo" (2)
      "d" -> "d" (4)
  $ hg debug::file-index --path foo
  2: foo
  $ hg debug::file-index --path food
  4: food
  $ hg debug::file-index --path fo
  abort: path fo is not in the file index
  [10]
  $ hg debug::file-index --path foods
  abort: path foods is not in the file index
  [10]

  $ cd ..

Test long paths
---------------

  $ hg init repolong --config format.use-fileindex-v1=1
  $ cd repolong

Maximum label length (255)
  $ path=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  $ echo ${#path}
  255
  $ mkdir -p $(dirname $path)
  $ touch $path
  $ hg commit -qAm 3
  $ hg debug::file-index --path $path
  1: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  $ hg debug::file-index --tree
  00000000: "" (0)
      "a" -> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" (1)

Go past the maximum label length once
  $ path=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbX
  $ echo ${#path}
  256
  $ mkdir -p $(dirname $path)
  $ touch $path
  $ hg commit -qAm 4
  $ hg debug::file-index --path $path
  2: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbX
  $ hg debug::file-index --tree
  0000000b: "" (0)
      "a" -> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" (1)
      "b" -> 0000001b
  0000001b: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" (2)
      "X" -> "X" (2)

Go past the maximum label length twice
  $ path=ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccZ
  $ echo ${#path}
  511
  $ mkdir -p $(dirname $path)
  $ touch $path
  $ hg commit -qAm 4
  $ hg debug::file-index --path $path
  3: ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccZ
  $ hg debug::file-index --tree
  00000026: "" (0)
      "a" -> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" (1)
      "b" -> 0000001b
      "c" -> 0000003b
  0000001b: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" (2)
      "X" -> "X" (2)
  0000003b: "ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" (3)
      "/" -> 00000046
  00000046: "/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" (3)
      "Z" -> "Z" (3)

  $ cd ..
