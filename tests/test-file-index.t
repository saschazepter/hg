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
  no docket exists yet (empty file index)
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

  $ cd ..

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
