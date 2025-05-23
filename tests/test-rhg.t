#require rhg

  $ NO_FALLBACK="env RHG_ON_UNSUPPORTED=abort"

Unimplemented command
  $ $NO_FALLBACK rhg unimplemented-command
  unsupported feature: error: unrecognized subcommand 'unimplemented-command'
  
  Usage: rhg [OPTIONS] <COMMAND>
  
  For more information, try '--help'.
  
  [252]
  $ rhg unimplemented-command --config rhg.on-unsupported=abort-silent
  [252]

Finding root
  $ $NO_FALLBACK rhg root
  abort: no repository found in '$TESTTMP' (.hg not found)!
  [255]

  $ hg init repository
  $ cd repository
  $ $NO_FALLBACK rhg root
  $TESTTMP/repository

Reading and setting configuration
  $ echo "[ui]" >> $HGRCPATH
  $ echo "username = user1" >> $HGRCPATH
  $ echo "[extensions]" >> $HGRCPATH
  $ echo "sparse =" >> $HGRCPATH
  $ $NO_FALLBACK rhg config ui.username
  user1
  $ echo "[ui]" >> .hg/hgrc
  $ echo "username = user2" >> .hg/hgrc
  $ $NO_FALLBACK rhg config ui.username
  user2
  $ $NO_FALLBACK rhg --config ui.username=user3 config ui.username
  user3

Alias to command
  $ $NO_FALLBACK rhg foo --config alias.foo=root
  $TESTTMP/repository
  $ $NO_FALLBACK rhg --config alias.foo=root foo
  $TESTTMP/repository

Alias that shadows an existing command
  $ $NO_FALLBACK rhg status --config alias.status=root
  $TESTTMP/repository

Alias to command with arguments
  $ $NO_FALLBACK rhg foo --config alias.foo="config ui.username"
  user2

Alias to command with arguments, shell quoted
  $ $NO_FALLBACK rhg foo --config alias.foo="\"config\" ui.username"
  user2
  $ $NO_FALLBACK rhg foo --config alias.foo="\"config ui.username"
  config error: error in definition for alias 'foo': invalid quotation or escape
  [30]

Alias that adds arguments to command
  $ $NO_FALLBACK rhg config --config alias.config="config ui.username"
  user2

Shell alias
  $ $NO_FALLBACK rhg foo --config alias.foo="!echo hello"
  unsupported feature: shell alias
  [252]

Alias interpolation
  $ $NO_FALLBACK rhg foo --config alias.foo='status $1'
  unsupported feature: alias interpolation
  [252]

Alias to another alias (can only refer to earlier one)
  $ $NO_FALLBACK rhg foo --config alias.bar=root --config alias.foo=bar
  $TESTTMP/repository
  $ $NO_FALLBACK rhg foo --config alias.foo=bar --config alias.bar=root
  unsupported feature: error: unrecognized subcommand 'bar'
  
  Usage: rhg [OPTIONS] <COMMAND>
  
  For more information, try '--help'.
  
  [252]

Unwritable file descriptor
  $ $NO_FALLBACK rhg root > /dev/full
  abort: No space left on device (os error 28)
  [255]

Deleted repository
  $ rm -rf `pwd`
  $ $NO_FALLBACK rhg root
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
  $ $NO_FALLBACK rhg files
  file1
  file2
  file3

Listing tracked files with NUL delimiters.
  $ $NO_FALLBACK rhg files -0 | xargs -0n1
  file1
  file2
  file3

Listing tracked files from subdirectory
  $ mkdir -p path/to/directory
  $ cd path/to/directory
  $ $NO_FALLBACK rhg files
  ../../../file1
  ../../../file2
  ../../../file3

  $ $NO_FALLBACK rhg files --config ui.relative-paths=legacy
  ../../../file1
  ../../../file2
  ../../../file3

  $ $NO_FALLBACK rhg files --config ui.relative-paths=false
  file1
  file2
  file3

  $ $NO_FALLBACK rhg files --config ui.relative-paths=true
  ../../../file1
  ../../../file2
  ../../../file3

Listing tracked files through broken pipe
  $ $NO_FALLBACK rhg files | head -n 1
  ../../../file1

Status with --rev and --change
  $ cd $TESTTMP/repository
  $ $NO_FALLBACK rhg status --change null
  $ $NO_FALLBACK rhg status --change 0
  A file1
  A file2
  A file3
  $ $NO_FALLBACK rhg status --rev null --rev 0
  A file1
  A file2
  A file3

Status with --change --copies
  $ hg copy file2 file2copy
  $ hg rename file3 file3rename
  $ hg commit -m "commit 4" -q
  $ $NO_FALLBACK rhg status --change . --copies
  A file2copy
    file2
  A file3rename
    file3
  R file3

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
  $ $NO_FALLBACK rhg debugdata -c 2
  8d0267cb034247ebfa5ee58ce59e22e57a492297
  test
  0 0
  file-3
  
  Commit 3 (no-eol)
  $ $NO_FALLBACK rhg debugdata -m 2
  file-1\x00b8e02f6433738021a065f94175c7cd23db5f05be (esc)
  file-2\x005d9299349fc01ddd25d0070d149b124d8f10411e (esc)
  file-3\x002661d26c649684b482d10f91960cc3db683c38b4 (esc)

Debuging with full node id
  $ $NO_FALLBACK rhg debugdata -c `hg log -r 0 -T '{node}'`
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
  $ $NO_FALLBACK rhg files -r cf8b83
  file-1
  file-2
  file-3
  $ $NO_FALLBACK rhg cat -r cf8b83 file-2
  2
  $ $NO_FALLBACK rhg cat --rev cf8b83 file-2
  2
  $ $NO_FALLBACK rhg cat -r c file-2
  abort: ambiguous revision identifier: c
  [255]
  $ $NO_FALLBACK rhg cat -r d file-2
  2
  $ $NO_FALLBACK rhg cat -r 0000 file-2
  file-2: no such file in rev 000000000000
  [1]

Cat files
  $ cd $TESTTMP
  $ rm -rf repository
  $ hg init repository
  $ cd repository
  $ echo "original content" > original
  $ hg add original
  $ hg commit -m "add original" original
Without `--rev`
  $ $NO_FALLBACK rhg cat original
  original content
With `--rev`
  $ $NO_FALLBACK rhg cat -r 0 original
  original content
Cat copied file should not display copy metadata
  $ hg copy original copy_of_original
  $ hg commit -m "add copy of original"
  $ $NO_FALLBACK rhg cat original
  original content
  $ $NO_FALLBACK rhg cat -r 1 copy_of_original
  original content

Annotate files
  $ $NO_FALLBACK rhg annotate original
  0: original content
  $ $NO_FALLBACK rhg annotate --rev . --user --file --date --number --changeset \
  > --line-number --text --no-follow --ignore-all-space --ignore-space-change \
  > --ignore-blank-lines --ignore-space-at-eol original
  test 0 1c9e69808da7 Thu Jan 01 00:00:00 1970 +0000 original:1: original content
  $ $NO_FALLBACK rhg blame -r . -ufdnclawbBZ --no-follow original
  test 0 1c9e69808da7 Thu Jan 01 00:00:00 1970 +0000 original:1: original content
  $ $NO_FALLBACK rhg annotate -r 'wdir()' original
  0 : original content
  $ $NO_FALLBACK rhg annotate -Tjson original
  [
   {
    "lines": [{"line": "original content\n", "rev": 0}],
    "path": "original"
   }
  ]

Fallback to Python
  $ $NO_FALLBACK rhg cat original --exclude="*.rs"
  unsupported feature: error: unexpected argument '--exclude' found
  
    tip: to pass '--exclude' as a value, use '-- --exclude'
  
  Usage: rhg cat <FILE>...
  
  For more information, try '--help'.
  
  [252]
  $ rhg cat original --exclude="*.rs"
  original content

Check that `fallback-immediately` overrides `$NO_FALLBACK`
  $ $NO_FALLBACK rhg cat original --exclude="*.rs" --config rhg.fallback-immediately=1
  original content

  $ (unset RHG_FALLBACK_EXECUTABLE; rhg cat original --exclude="*.rs")
  abort: 'rhg.on-unsupported=fallback' without 'rhg.fallback-executable' set.
  [255]

  $ (unset RHG_FALLBACK_EXECUTABLE; rhg cat original)
  original content

  $ rhg cat original --exclude="*.rs" --config rhg.fallback-executable=false
  [1]

  $ rhg cat original --exclude="*.rs" --config rhg.fallback-executable=hg-non-existent
  abort: invalid fallback 'hg-non-existent': cannot find binary path
  [253]

  $ rhg cat original --exclude="*.rs" --config rhg.fallback-executable=rhg
  Blocking recursive fallback. The 'rhg.fallback-executable = rhg' config points to `rhg` itself.
  unsupported feature: error: unexpected argument '--exclude' found
  
    tip: to pass '--exclude' as a value, use '-- --exclude'
  
  Usage: rhg cat <FILE>...
  
  For more information, try '--help'.
  
  [252]

Fallback with shell path segments
  $ $NO_FALLBACK rhg cat .
  unsupported feature: `..` or `.` path segment
  [252]
  $ $NO_FALLBACK rhg cat ..
  unsupported feature: `..` or `.` path segment
  [252]
  $ $NO_FALLBACK rhg cat ../..
  unsupported feature: `..` or `.` path segment
  [252]

Fallback with filesets
  $ $NO_FALLBACK rhg cat "set:c or b"
  unsupported feature: rhg does not support file patterns
  [252]

Fallback with generic hooks
  $ $NO_FALLBACK rhg cat original --config hooks.pre-cat=something
  unsupported feature: pre-cat hook defined
  [252]

  $ $NO_FALLBACK rhg cat original --config hooks.post-cat=something
  unsupported feature: post-cat hook defined
  [252]

  $ $NO_FALLBACK rhg cat original --config hooks.fail-cat=something
  unsupported feature: fail-cat hook defined
  [252]

Fallback with [defaults]
  $ $NO_FALLBACK rhg cat original --config "defaults.cat=-r null"
  unsupported feature: `defaults` config set
  [252]


Requirements
  $ $NO_FALLBACK rhg debugrequirements
  dotencode
  fncache
  generaldelta
  persistent-nodemap
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store

  $ echo indoor-pool >> .hg/requires
  $ $NO_FALLBACK rhg files
  unsupported feature: repository requires feature unknown to this Mercurial: indoor-pool
  [252]

  $ $NO_FALLBACK rhg cat -r 1 copy_of_original
  unsupported feature: repository requires feature unknown to this Mercurial: indoor-pool
  [252]

  $ $NO_FALLBACK rhg debugrequirements
  unsupported feature: repository requires feature unknown to this Mercurial: indoor-pool
  [252]

  $ echo -e '\xFF' >> .hg/requires
  $ $NO_FALLBACK rhg debugrequirements
  abort: parse error in 'requires' file
  [255]

Persistent nodemap
  $ cd $TESTTMP
  $ rm -rf repository
  $ hg --config format.use-persistent-nodemap=no init repository
  $ cd repository
  $ $NO_FALLBACK rhg debugrequirements | grep nodemap
  [1]
  $ hg debugbuilddag .+5000 --overwritten-file --config "storage.revlog.nodemap.mode=warn"
  $ hg id -r tip
  c3ae8dec9fad tip
  $ ls .hg/store/00changelog*
  .hg/store/00changelog.d
  .hg/store/00changelog.i
  $ $NO_FALLBACK rhg files -r c3ae8dec9fad
  of

  $ cd $TESTTMP
  $ rm -rf repository
  $ hg --config format.use-persistent-nodemap=True init repository
  $ cd repository
  $ $NO_FALLBACK rhg debugrequirements | grep nodemap
  persistent-nodemap
  $ hg debugbuilddag .+5000 --overwritten-file --config "storage.revlog.nodemap.mode=warn"
  $ hg id -r tip
  c3ae8dec9fad tip
  $ ls .hg/store/00changelog*
  .hg/store/00changelog-*.nd (glob)
  .hg/store/00changelog.d
  .hg/store/00changelog.i
  .hg/store/00changelog.n

Rhg status on a sparse repo with nodemap (this specific combination used to crash in 6.5.2)

  $ hg debugsparse -X excluded-dir
  $ $NO_FALLBACK rhg status

Specifying revisions by changeset ID
  $ $NO_FALLBACK rhg files -r c3ae8dec9fad
  of
  $ $NO_FALLBACK rhg cat -r c3ae8dec9fad of
  r5000

Crate a shared repository

  $ echo "[extensions]"      >> $HGRCPATH
  $ echo "share = "          >> $HGRCPATH

  $ cd $TESTTMP
  $ hg init repo1
  $ echo a > repo1/a
  $ hg -R repo1 commit -A -m'init'
  adding a

  $ hg share repo1 repo2
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

And check that basic rhg commands work with sharing

  $ $NO_FALLBACK rhg files -R repo2
  repo2/a
  $ $NO_FALLBACK rhg -R repo2 cat -r 0 repo2/a
  a

Same with relative sharing

  $ hg share repo2 repo3 --relative
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ $NO_FALLBACK rhg files -R repo3
  repo3/a
  $ $NO_FALLBACK rhg -R repo3 cat -r 0 repo3/a
  a

Same with share-safe

  $ echo "[format]"         >> $HGRCPATH
  $ echo "use-share-safe = True" >> $HGRCPATH

  $ cd $TESTTMP
  $ hg init repo4
  $ cd repo4
  $ echo a > a
  $ hg commit -A -m'init'
  adding a

  $ cd ..
  $ hg share repo4 repo5
  updating working directory
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

And check that basic rhg commands work with sharing

  $ cd repo5
  $ $NO_FALLBACK rhg files
  a
  $ $NO_FALLBACK rhg cat -r 0 a
  a

The blackbox extension is supported

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "blackbox =" >> $HGRCPATH
  $ echo "[blackbox]" >> $HGRCPATH
  $ echo "maxsize = 1" >> $HGRCPATH
  $ $NO_FALLBACK rhg files > /dev/null
  $ cat .hg/blackbox.log
  ????-??-?? ??:??:??.??? * @d3873e73d99ef67873dac33fbcc66268d5d2b6f4 (*)> (rust) files exited 0 after * seconds (glob)
  $ cat .hg/blackbox.log.1
  ????-??-?? ??:??:??.??? * @d3873e73d99ef67873dac33fbcc66268d5d2b6f4 (*)> (rust) files (glob)

Subrepos are not supported

  $ touch .hgsub
  $ $NO_FALLBACK rhg files
  unsupported feature: subrepos (.hgsub is present)
  [252]
  $ rhg files
  a
  $ rm .hgsub

The `:required` extension suboptions are correctly ignored

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "blackbox:required = yes" >> $HGRCPATH
  $ rhg files
  a
  $ echo "*:required = yes" >> $HGRCPATH
  $ rhg files
  a

Check that we expand both user and environment in ignore includes (HOME is TESTTMP)

  $ echo "specificprefix" > ~/ignore.expected-extension
  $ touch specificprefix
  $ $NO_FALLBACK rhg st
  ? specificprefix
  $ $NO_FALLBACK RHG_EXT_TEST=expected-extension rhg st --config 'ui.ignore=~/ignore.${RHG_EXT_TEST}'

We can ignore all extensions at once

  $ echo "[extensions]" >> $HGRCPATH
  $ echo "thisextensionbetternotexist=" >> $HGRCPATH
  $ echo "thisextensionbetternotexisteither=" >> $HGRCPATH
  $ $NO_FALLBACK rhg files
  unsupported feature: extensions: thisextensionbetternotexist, thisextensionbetternotexisteither (consider adding them to 'rhg.ignored-extensions' config)
  [252]

  $ echo "[rhg]" >> $HGRCPATH
  $ echo "ignored-extensions=*" >> $HGRCPATH
  $ $NO_FALLBACK rhg files
  a

Latin-1 is not supported yet

  $ $NO_FALLBACK HGENCODING=latin-1 rhg root
  unsupported feature: HGENCODING value 'latin-1' is not supported
  [252]
