#require rust

Define an rhg function that will only run if rhg exists
  $ rhg() {
  > if [ -f "$RUNTESTDIR/../rust/target/debug/rhg" ]; then
  >   "$RUNTESTDIR/../rust/target/debug/rhg" "$@"
  > else
  >   echo "skipped: Cannot find rhg. Try to run cargo build in rust/rhg."
  >   exit 80
  > fi
  > }

Unimplemented command
  $ rhg unimplemented-command
  error: Found argument 'unimplemented-command' which wasn't expected, or isn't valid in this context
  
  USAGE:
      rhg <SUBCOMMAND>
  
  For more information try --help
  [252]

Finding root
  $ rhg root
  abort: no repository found in '$TESTTMP' (.hg not found)!
  [255]

  $ hg init repository
  $ cd repository
  $ rhg root
  $TESTTMP/repository

Unwritable file descriptor
  $ rhg root > /dev/full
  abort: No space left on device (os error 28)
  [255]

Deleted repository
  $ rm -rf `pwd`
  $ rhg root
  abort: error getting current working directory: $ENOENT$
  [255]

Listing tracked files
  $ cd $TESTTMP
  $ hg init repository
  $ cd repository
  $ for i in 1 2 3; do
  >   echo $i >> file$i
  >   hg add file$i
  > done
  > hg commit -m "commit $i" -q

Listing tracked files from root
  $ rhg files
  file1
  file2
  file3

Listing tracked files from subdirectory
  $ mkdir -p path/to/directory
  $ cd path/to/directory
  $ rhg files
  ../../../file1
  ../../../file2
  ../../../file3

Listing tracked files through broken pipe
  $ rhg files | head -n 1
  ../../../file1

Debuging data in inline index
  $ cd $TESTTMP
  $ rm -rf repository
  $ hg init repository
  $ cd repository
  $ for i in 1 2 3 4 5 6; do
  >   echo $i >> file-$i
  >   hg add file-$i
  >   hg commit -m "Commit $i" -q
  > done
  $ rhg debugdata -c 2
  8d0267cb034247ebfa5ee58ce59e22e57a492297
  test
  0 0
  file-3
  
  Commit 3 (no-eol)
  $ rhg debugdata -m 2
  file-1\x00b8e02f6433738021a065f94175c7cd23db5f05be (esc)
  file-2\x005d9299349fc01ddd25d0070d149b124d8f10411e (esc)
  file-3\x002661d26c649684b482d10f91960cc3db683c38b4 (esc)

Debuging with full node id
  $ rhg debugdata -c `hg log -r 0 -T '{node}'`
  d1d1c679d3053e8926061b6f45ca52009f011e3f
  test
  0 0
  file-1
  
  Commit 1 (no-eol)

Specifying revisions by changeset ID
  $ hg log -T '{node}\n'
  c6ad58c44207b6ff8a4fbbca7045a5edaa7e908b
  d654274993d0149eecc3cc03214f598320211900
  f646af7e96481d3a5470b695cf30ad8e3ab6c575
  cf8b83f14ead62b374b6e91a0e9303b85dfd9ed7
  91c6f6e73e39318534dc415ea4e8a09c99cd74d6
  6ae9681c6d30389694d8701faf24b583cf3ccafe
  $ rhg files -r cf8b83
  file-1
  file-2
  file-3
  $ rhg cat -r cf8b83 file-2
  2
  $ rhg cat -r c file-2
  abort: ambiguous revision identifier c
  [255]
  $ rhg cat -r d file-2
  2

Cat files
  $ cd $TESTTMP
  $ rm -rf repository
  $ hg init repository
  $ cd repository
  $ echo "original content" > original
  $ hg add original
  $ hg commit -m "add original" original
  $ rhg cat -r 0 original
  original content
Cat copied file should not display copy metadata
  $ hg copy original copy_of_original
  $ hg commit -m "add copy of original"
  $ rhg cat -r 1 copy_of_original
  original content

Requirements
  $ rhg debugrequirements
  dotencode
  fncache
  generaldelta
  revlogv1
  sparserevlog
  store

  $ echo indoor-pool >> .hg/requires
  $ rhg files
  [252]

  $ rhg cat -r 1 copy_of_original
  [252]

  $ rhg debugrequirements
  dotencode
  fncache
  generaldelta
  revlogv1
  sparserevlog
  store
  indoor-pool

  $ echo -e '\xFF' >> .hg/requires
  $ rhg debugrequirements
  abort: .hg/requires is corrupted
  [255]

Persistent nodemap
  $ cd $TESTTMP
  $ rm -rf repository
  $ hg init repository
  $ cd repository
  $ rhg debugrequirements | grep nodemap
  [1]
  $ hg debugbuilddag .+5000 --overwritten-file --config "storage.revlog.nodemap.mode=warn"
  $ hg id -r tip
  c3ae8dec9fad tip
  $ ls .hg/store/00changelog*
  .hg/store/00changelog.d
  .hg/store/00changelog.i
  $ rhg files -r c3ae8dec9fad
  of

  $ cd $TESTTMP
  $ rm -rf repository
  $ hg --config format.use-persistent-nodemap=True init repository
  $ cd repository
  $ rhg debugrequirements | grep nodemap
  persistent-nodemap
  $ hg debugbuilddag .+5000 --overwritten-file --config "storage.revlog.nodemap.mode=warn"
  $ hg id -r tip
  c3ae8dec9fad tip
  $ ls .hg/store/00changelog*
  .hg/store/00changelog-*.nd (glob)
  .hg/store/00changelog.d
  .hg/store/00changelog.i
  .hg/store/00changelog.n

Specifying revisions by changeset ID
  $ rhg files -r c3ae8dec9fad
  of
  $ rhg cat -r c3ae8dec9fad of
  r5000
