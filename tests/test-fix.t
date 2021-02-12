A script that implements uppercasing of specific lines in a file. This
approximates the behavior of code formatters well enough for our tests.

  $ UPPERCASEPY="$TESTTMP/uppercase.py"
  $ cat > $UPPERCASEPY <<EOF
  > import re
  > import sys
  > from mercurial.utils.procutil import setbinary
  > setbinary(sys.stdin)
  > setbinary(sys.stdout)
  > stdin = getattr(sys.stdin, 'buffer', sys.stdin)
  > stdout = getattr(sys.stdout, 'buffer', sys.stdout)
  > lines = set()
  > def format(text):
  >   return re.sub(b' +', b' ', text.upper())
  > for arg in sys.argv[1:]:
  >   if arg == 'all':
  >     stdout.write(format(stdin.read()))
  >     sys.exit(0)
  >   else:
  >     first, last = arg.split('-')
  >     lines.update(range(int(first), int(last) + 1))
  > for i, line in enumerate(stdin.readlines()):
  >   if i + 1 in lines:
  >     stdout.write(format(line))
  >   else:
  >     stdout.write(line)
  > EOF
  $ TESTLINES="foo\nbar\nbaz\nqux\n"
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY
  foo
  bar
  baz
  qux
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY all
  FOO
  BAR
  BAZ
  QUX
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY 1-1
  FOO
  bar
  baz
  qux
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY 1-2
  FOO
  BAR
  baz
  qux
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY 2-3
  foo
  BAR
  BAZ
  qux
  $ printf $TESTLINES | "$PYTHON" $UPPERCASEPY 2-2 4-4
  foo
  BAR
  baz
  QUX

Set up the config with two simple fixers: one that fixes specific line ranges,
and one that always fixes the whole file. They both "fix" files by converting
letters to uppercase. They use different file extensions, so each test case can
choose which behavior to use by naming files.

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > fix =
  > [experimental]
  > evolution.createmarkers=True
  > evolution.allowunstable=True
  > [fix]
  > uppercase-whole-file:command="$PYTHON" $UPPERCASEPY all
  > uppercase-whole-file:pattern=set:**.whole
  > uppercase-changed-lines:command="$PYTHON" $UPPERCASEPY
  > uppercase-changed-lines:linerange={first}-{last}
  > uppercase-changed-lines:pattern=set:**.changed
  > EOF

Help text for fix.

  $ hg help fix
  hg fix [OPTION]... [FILE]...
  
  rewrite file content in changesets or working directory
  
      Runs any configured tools to fix the content of files. Only affects files
      with changes, unless file arguments are provided. Only affects changed
      lines of files, unless the --whole flag is used. Some tools may always
      affect the whole file regardless of --whole.
  
      If --working-dir is used, files with uncommitted changes in the working
      copy will be fixed. Note that no backup are made.
  
      If revisions are specified with --source, those revisions and their
      descendants will be checked, and they may be replaced with new revisions
      that have fixed file content. By automatically including the descendants,
      no merging, rebasing, or evolution will be required. If an ancestor of the
      working copy is included, then the working copy itself will also be fixed,
      and the working copy will be updated to the fixed parent.
  
      When determining what lines of each file to fix at each revision, the
      whole set of revisions being fixed is considered, so that fixes to earlier
      revisions are not forgotten in later ones. The --base flag can be used to
      override this default behavior, though it is not usually desirable to do
      so.
  
  (use 'hg help -e fix' to show help for the fix extension)
  
  options ([+] can be repeated):
  
      --all            fix all non-public non-obsolete revisions
      --base REV [+]   revisions to diff against (overrides automatic selection,
                       and applies to every revision being fixed)
   -s --source REV [+] fix the specified revisions and their descendants
   -w --working-dir    fix the working directory
      --whole          always fix every line of a file
  
  (some details hidden, use --verbose to show complete help)

  $ hg help -e fix
  fix extension - rewrite file content in changesets or working copy
  (EXPERIMENTAL)
  
  Provides a command that runs configured tools on the contents of modified
  files, writing back any fixes to the working copy or replacing changesets.
  
  Here is an example configuration that causes 'hg fix' to apply automatic
  formatting fixes to modified lines in C++ code:
  
    [fix]
    clang-format:command=clang-format --assume-filename={rootpath}
    clang-format:linerange=--lines={first}:{last}
    clang-format:pattern=set:**.cpp or **.hpp
  
  The :command suboption forms the first part of the shell command that will be
  used to fix a file. The content of the file is passed on standard input, and
  the fixed file content is expected on standard output. Any output on standard
  error will be displayed as a warning. If the exit status is not zero, the file
  will not be affected. A placeholder warning is displayed if there is a non-
  zero exit status but no standard error output. Some values may be substituted
  into the command:
  
    {rootpath}  The path of the file being fixed, relative to the repo root
    {basename}  The name of the file being fixed, without the directory path
  
  If the :linerange suboption is set, the tool will only be run if there are
  changed lines in a file. The value of this suboption is appended to the shell
  command once for every range of changed lines in the file. Some values may be
  substituted into the command:
  
    {first}   The 1-based line number of the first line in the modified range
    {last}    The 1-based line number of the last line in the modified range
  
  Deleted sections of a file will be ignored by :linerange, because there is no
  corresponding line range in the version being fixed.
  
  By default, tools that set :linerange will only be executed if there is at
  least one changed line range. This is meant to prevent accidents like running
  a code formatter in such a way that it unexpectedly reformats the whole file.
  If such a tool needs to operate on unchanged files, it should set the
  :skipclean suboption to false.
  
  The :pattern suboption determines which files will be passed through each
  configured tool. See 'hg help patterns' for possible values. However, all
  patterns are relative to the repo root, even if that text says they are
  relative to the current working directory. If there are file arguments to 'hg
  fix', the intersection of these patterns is used.
  
  There is also a configurable limit for the maximum size of file that will be
  processed by 'hg fix':
  
    [fix]
    maxfilesize = 2MB
  
  Normally, execution of configured tools will continue after a failure
  (indicated by a non-zero exit status). It can also be configured to abort
  after the first such failure, so that no files will be affected if any tool
  fails. This abort will also cause 'hg fix' to exit with a non-zero status:
  
    [fix]
    failure = abort
  
  When multiple tools are configured to affect a file, they execute in an order
  defined by the :priority suboption. The priority suboption has a default value
  of zero for each tool. Tools are executed in order of descending priority. The
  execution order of tools with equal priority is unspecified. For example, you
  could use the 'sort' and 'head' utilities to keep only the 10 smallest numbers
  in a text file by ensuring that 'sort' runs before 'head':
  
    [fix]
    sort:command = sort -n
    head:command = head -n 10
    sort:pattern = numbers.txt
    head:pattern = numbers.txt
    sort:priority = 2
    head:priority = 1
  
  To account for changes made by each tool, the line numbers used for
  incremental formatting are recomputed before executing the next tool. So, each
  tool may see different values for the arguments added by the :linerange
  suboption.
  
  Each fixer tool is allowed to return some metadata in addition to the fixed
  file content. The metadata must be placed before the file content on stdout,
  separated from the file content by a zero byte. The metadata is parsed as a
  JSON value (so, it should be UTF-8 encoded and contain no zero bytes). A fixer
  tool is expected to produce this metadata encoding if and only if the
  :metadata suboption is true:
  
    [fix]
    tool:command = tool --prepend-json-metadata
    tool:metadata = true
  
  The metadata values are passed to hooks, which can be used to print summaries
  or perform other post-fixing work. The supported hooks are:
  
    "postfixfile"
      Run once for each file in each revision where any fixer tools made changes
      to the file content. Provides "$HG_REV" and "$HG_PATH" to identify the file,
      and "$HG_METADATA" with a map of fixer names to metadata values from fixer
      tools that affected the file. Fixer tools that didn't affect the file have a
      value of None. Only fixer tools that executed are present in the metadata.
  
    "postfix"
      Run once after all files and revisions have been handled. Provides
      "$HG_REPLACEMENTS" with information about what revisions were created and
      made obsolete. Provides a boolean "$HG_WDIRWRITTEN" to indicate whether any
      files in the working copy were updated. Provides a list "$HG_METADATA"
      mapping fixer tool names to lists of metadata values returned from
      executions that modified a file. This aggregates the same metadata
      previously passed to the "postfixfile" hook.
  
  Fixer tools are run in the repository's root directory. This allows them to
  read configuration files from the working copy, or even write to the working
  copy. The working copy is not updated to match the revision being fixed. In
  fact, several revisions may be fixed in parallel. Writes to the working copy
  are not amended into the revision being fixed; fixer tools should always write
  fixed file content back to stdout as documented above.
  
  list of commands:
  
   fix           rewrite file content in changesets or working directory
  
  (use 'hg help -v -e fix' to show built-in aliases and global options)

There is no default behavior in the absence of --rev and --working-dir.

  $ hg init badusage
  $ cd badusage

  $ hg fix
  abort: no changesets specified
  (use --source or --working-dir)
  [255]
  $ hg fix --whole
  abort: no changesets specified
  (use --source or --working-dir)
  [255]
  $ hg fix --base 0
  abort: no changesets specified
  (use --source or --working-dir)
  [255]

Fixing a public revision isn't allowed. It should abort early enough that
nothing happens, even to the working directory.

  $ printf "hello\n" > hello.whole
  $ hg commit -Aqm "hello"
  $ hg phase -r 0 --public
  $ hg fix -r 0
  abort: cannot fix public changesets: 6470986d2e7b
  (see 'hg help phases' for details)
  [10]
  $ hg fix -r 0 --working-dir
  abort: cannot fix public changesets: 6470986d2e7b
  (see 'hg help phases' for details)
  [10]
  $ hg cat -r tip hello.whole
  hello
  $ cat hello.whole
  hello

  $ cd ..

Fixing a clean working directory should do nothing. Even the --whole flag
shouldn't cause any clean files to be fixed. Specifying a clean file explicitly
should only fix it if the fixer always fixes the whole file. The combination of
an explicit filename and --whole should format the entire file regardless.

  $ hg init fixcleanwdir
  $ cd fixcleanwdir

  $ printf "hello\n" > hello.changed
  $ printf "world\n" > hello.whole
  $ hg commit -Aqm "foo"
  $ hg fix --working-dir
  $ hg diff
  $ hg fix --working-dir --whole
  $ hg diff
  $ hg fix --working-dir *
  $ cat *
  hello
  WORLD
  $ hg revert --all --no-backup
  reverting hello.whole
  $ hg fix --working-dir * --whole
  $ cat *
  HELLO
  WORLD

The same ideas apply to fixing a revision, so we create a revision that doesn't
modify either of the files in question and try fixing it. This also tests that
we ignore a file that doesn't match any configured fixer.

  $ hg revert --all --no-backup
  reverting hello.changed
  reverting hello.whole
  $ printf "unimportant\n" > some.file
  $ hg commit -Aqm "some other file"

  $ hg fix -r .
  $ hg cat -r tip *
  hello
  world
  unimportant
  $ hg fix -r . --whole
  $ hg cat -r tip *
  hello
  world
  unimportant
  $ hg fix -r . *
  $ hg cat -r tip *
  hello
  WORLD
  unimportant
  $ hg fix -r . * --whole --config experimental.evolution.allowdivergence=true
  2 new content-divergent changesets
  $ hg cat -r tip *
  HELLO
  WORLD
  unimportant

  $ cd ..

Fixing the working directory should still work if there are no revisions.

  $ hg init norevisions
  $ cd norevisions

  $ printf "something\n" > something.whole
  $ hg add
  adding something.whole
  $ hg fix --working-dir
  $ cat something.whole
  SOMETHING

  $ cd ..

Test that the working copy is reported clean if formatting of the parent makes
it clean.
  $ hg init wc-already-formatted
  $ cd wc-already-formatted

  $ printf "hello   world\n" > hello.whole
  $ hg commit -Am initial
  adding hello.whole
  $ hg fix -w *
  $ hg st
  M hello.whole
  $ hg fix -s . *
  $ hg st
  $ hg diff

  $ cd ..

Test the effect of fixing the working directory for each possible status, with
and without providing explicit file arguments.

  $ hg init implicitlyfixstatus
  $ cd implicitlyfixstatus

  $ printf "modified\n" > modified.whole
  $ printf "removed\n" > removed.whole
  $ printf "deleted\n" > deleted.whole
  $ printf "clean\n" > clean.whole
  $ printf "ignored.whole" > .hgignore
  $ hg commit -Aqm "stuff"

  $ printf "modified!!!\n" > modified.whole
  $ printf "unknown\n" > unknown.whole
  $ printf "ignored\n" > ignored.whole
  $ printf "added\n" > added.whole
  $ hg add added.whole
  $ hg remove removed.whole
  $ rm deleted.whole

  $ hg status --all
  M modified.whole
  A added.whole
  R removed.whole
  ! deleted.whole
  ? unknown.whole
  I ignored.whole
  C .hgignore
  C clean.whole

  $ hg fix --working-dir

  $ hg status --all
  M modified.whole
  A added.whole
  R removed.whole
  ! deleted.whole
  ? unknown.whole
  I ignored.whole
  C .hgignore
  C clean.whole

  $ cat *.whole
  ADDED
  clean
  ignored
  MODIFIED!!!
  unknown

  $ printf "modified!!!\n" > modified.whole
  $ printf "added\n" > added.whole

Listing the files explicitly causes untracked files to also be fixed, but
ignored files are still unaffected.

  $ hg fix --working-dir *.whole

  $ hg status --all
  M clean.whole
  M modified.whole
  A added.whole
  R removed.whole
  ! deleted.whole
  ? unknown.whole
  I ignored.whole
  C .hgignore

  $ cat *.whole
  ADDED
  CLEAN
  ignored
  MODIFIED!!!
  UNKNOWN

  $ cd ..

Test that incremental fixing works on files with additions, deletions, and
changes in multiple line ranges. Note that deletions do not generally cause
neighboring lines to be fixed, so we don't return a line range for purely
deleted sections. In the future we should support a :deletion config that
allows fixers to know where deletions are located.

  $ hg init incrementalfixedlines
  $ cd incrementalfixedlines

  $ printf "a\nb\nc\nd\ne\nf\ng\n" > foo.txt
  $ hg commit -Aqm "foo"
  $ printf "zz\na\nc\ndd\nee\nff\nf\ngg\n" > foo.txt

  $ hg --config "fix.fail:command=echo" \
  >    --config "fix.fail:linerange={first}:{last}" \
  >    --config "fix.fail:pattern=foo.txt" \
  >    fix --working-dir
  $ cat foo.txt
  1:1 4:6 8:8

  $ cd ..

Test that --whole fixes all lines regardless of the diffs present.

  $ hg init wholeignoresdiffs
  $ cd wholeignoresdiffs

  $ printf "a\nb\nc\nd\ne\nf\ng\n" > foo.changed
  $ hg commit -Aqm "foo"
  $ printf "zz\na\nc\ndd\nee\nff\nf\ngg\n" > foo.changed

  $ hg fix --working-dir
  $ cat foo.changed
  ZZ
  a
  c
  DD
  EE
  FF
  f
  GG

  $ hg fix --working-dir --whole
  $ cat foo.changed
  ZZ
  A
  C
  DD
  EE
  FF
  F
  GG

  $ cd ..

We should do nothing with symlinks, and their targets should be unaffected. Any
other behavior would be more complicated to implement and harder to document.

#if symlink
  $ hg init dontmesswithsymlinks
  $ cd dontmesswithsymlinks

  $ printf "hello\n" > hello.whole
  $ ln -s hello.whole hellolink
  $ hg add
  adding hello.whole
  adding hellolink
  $ hg fix --working-dir hellolink
  $ hg status
  A hello.whole
  A hellolink

  $ cd ..
#endif

We should allow fixers to run on binary files, even though this doesn't sound
like a common use case. There's not much benefit to disallowing it, and users
can add "and not binary()" to their filesets if needed. The Mercurial
philosophy is generally to not handle binary files specially anyway.

  $ hg init cantouchbinaryfiles
  $ cd cantouchbinaryfiles

  $ printf "hello\0\n" > hello.whole
  $ hg add
  adding hello.whole
  $ hg fix --working-dir 'set:binary()'
  $ cat hello.whole
  HELLO\x00 (esc)

  $ cd ..

We have a config for the maximum size of file we will attempt to fix. This can
be helpful to avoid running unsuspecting fixer tools on huge inputs, which
could happen by accident without a well considered configuration. A more
precise configuration could use the size() fileset function if one global limit
is undesired.

  $ hg init maxfilesize
  $ cd maxfilesize

  $ printf "this file is huge\n" > hello.whole
  $ hg add
  adding hello.whole
  $ hg --config fix.maxfilesize=10 fix --working-dir
  ignoring file larger than 10 bytes: hello.whole
  $ cat hello.whole
  this file is huge

  $ cd ..

If we specify a file to fix, other files should be left alone, even if they
have changes.

  $ hg init fixonlywhatitellyouto
  $ cd fixonlywhatitellyouto

  $ printf "fix me!\n" > fixme.whole
  $ printf "not me.\n" > notme.whole
  $ hg add
  adding fixme.whole
  adding notme.whole
  $ hg fix --working-dir fixme.whole
  $ cat *.whole
  FIX ME!
  not me.

  $ cd ..

If we try to fix a missing file, we still fix other files.

  $ hg init fixmissingfile
  $ cd fixmissingfile

  $ printf "fix me!\n" > foo.whole
  $ hg add
  adding foo.whole
  $ hg fix --working-dir foo.whole bar.whole
  bar.whole: $ENOENT$
  $ cat *.whole
  FIX ME!

  $ cd ..

Specifying a directory name should fix all its files and subdirectories.

  $ hg init fixdirectory
  $ cd fixdirectory

  $ mkdir -p dir1/dir2
  $ printf "foo\n" > foo.whole
  $ printf "bar\n" > dir1/bar.whole
  $ printf "baz\n" > dir1/dir2/baz.whole
  $ hg add
  adding dir1/bar.whole
  adding dir1/dir2/baz.whole
  adding foo.whole
  $ hg fix --working-dir dir1
  $ cat foo.whole dir1/bar.whole dir1/dir2/baz.whole
  foo
  BAR
  BAZ

  $ cd ..

Fixing a file in the working directory that needs no fixes should not actually
write back to the file, so for example the mtime shouldn't change.

  $ hg init donttouchunfixedfiles
  $ cd donttouchunfixedfiles

  $ printf "NO FIX NEEDED\n" > foo.whole
  $ hg add
  adding foo.whole
  $ cp -p foo.whole foo.whole.orig
  $ cp -p foo.whole.orig foo.whole
  $ sleep 2 # mtime has a resolution of one or two seconds.
  $ hg fix --working-dir
  $ f foo.whole.orig --newer foo.whole
  foo.whole.orig: newer than foo.whole

  $ cd ..

When a fixer prints to stderr, we don't assume that it has failed. We show the
error messages to the user, and we still let the fixer affect the file it was
fixing if its exit code is zero. Some code formatters might emit error messages
on stderr and nothing on stdout, which would cause us the clear the file,
except that they also exit with a non-zero code. We show the user which fixer
emitted the stderr, and which revision, but we assume that the fixer will print
the filename if it is relevant (since the issue may be non-specific). There is
also a config to abort (without affecting any files whatsoever) if we see any
tool with a non-zero exit status.

  $ hg init showstderr
  $ cd showstderr

  $ printf "hello\n" > hello.txt
  $ hg add
  adding hello.txt
  $ cat > $TESTTMP/work.sh <<'EOF'
  > printf 'HELLO\n'
  > printf "$@: some\nerror that didn't stop the tool" >&2
  > exit 0 # success despite the stderr output
  > EOF
  $ hg --config "fix.work:command=sh $TESTTMP/work.sh {rootpath}" \
  >    --config "fix.work:pattern=hello.txt" \
  >    fix --working-dir
  [wdir] work: hello.txt: some
  [wdir] work: error that didn't stop the tool
  $ cat hello.txt
  HELLO

  $ printf "goodbye\n" > hello.txt
  $ printf "foo\n" > foo.whole
  $ hg add
  adding foo.whole
  $ cat > $TESTTMP/fail.sh <<'EOF'
  > printf 'GOODBYE\n'
  > printf "$@: some\nerror that did stop the tool\n" >&2
  > exit 42 # success despite the stdout output
  > EOF
  $ hg --config "fix.fail:command=sh $TESTTMP/fail.sh {rootpath}" \
  >    --config "fix.fail:pattern=hello.txt" \
  >    --config "fix.failure=abort" \
  >    fix --working-dir
  [wdir] fail: hello.txt: some
  [wdir] fail: error that did stop the tool
  abort: no fixes will be applied
  (use --config fix.failure=continue to apply any successful fixes anyway)
  [255]
  $ cat hello.txt
  goodbye
  $ cat foo.whole
  foo

  $ hg --config "fix.fail:command=sh $TESTTMP/fail.sh {rootpath}" \
  >    --config "fix.fail:pattern=hello.txt" \
  >    fix --working-dir
  [wdir] fail: hello.txt: some
  [wdir] fail: error that did stop the tool
  $ cat hello.txt
  goodbye
  $ cat foo.whole
  FOO

  $ hg --config "fix.fail:command=exit 42" \
  >    --config "fix.fail:pattern=hello.txt" \
  >    fix --working-dir
  [wdir] fail: exited with status 42

  $ cd ..

Fixing the working directory and its parent revision at the same time should
check out the replacement revision for the parent. This prevents any new
uncommitted changes from appearing. We test this for a clean working directory
and a dirty one. In both cases, all lines/files changed since the grandparent
will be fixed. The grandparent is the "baserev" for both the parent and the
working copy.

  $ hg init fixdotandcleanwdir
  $ cd fixdotandcleanwdir

  $ printf "hello\n" > hello.whole
  $ printf "world\n" > world.whole
  $ hg commit -Aqm "the parent commit"

  $ hg parents --template '{rev} {desc}\n'
  0 the parent commit
  $ hg fix --working-dir -r .
  $ hg parents --template '{rev} {desc}\n'
  1 the parent commit
  $ hg cat -r . *.whole
  HELLO
  WORLD
  $ cat *.whole
  HELLO
  WORLD
  $ hg status

  $ cd ..

Same test with a dirty working copy.

  $ hg init fixdotanddirtywdir
  $ cd fixdotanddirtywdir

  $ printf "hello\n" > hello.whole
  $ printf "world\n" > world.whole
  $ hg commit -Aqm "the parent commit"

  $ printf "hello,\n" > hello.whole
  $ printf "world!\n" > world.whole

  $ hg parents --template '{rev} {desc}\n'
  0 the parent commit
  $ hg fix --working-dir -r .
  $ hg parents --template '{rev} {desc}\n'
  1 the parent commit
  $ hg cat -r . *.whole
  HELLO
  WORLD
  $ cat *.whole
  HELLO,
  WORLD!
  $ hg status
  M hello.whole
  M world.whole

  $ cd ..

When we have a chain of commits that change mutually exclusive lines of code,
we should be able to do incremental fixing that causes each commit in the chain
to include fixes made to the previous commits. This prevents children from
backing out the fixes made in their parents. A dirty working directory is
conceptually similar to another commit in the chain.

  $ hg init incrementallyfixchain
  $ cd incrementallyfixchain

  $ cat > file.changed <<EOF
  > first
  > second
  > third
  > fourth
  > fifth
  > EOF
  $ hg commit -Aqm "the common ancestor (the baserev)"
  $ cat > file.changed <<EOF
  > first (changed)
  > second
  > third
  > fourth
  > fifth
  > EOF
  $ hg commit -Aqm "the first commit to fix"
  $ cat > file.changed <<EOF
  > first (changed)
  > second
  > third (changed)
  > fourth
  > fifth
  > EOF
  $ hg commit -Aqm "the second commit to fix"
  $ cat > file.changed <<EOF
  > first (changed)
  > second
  > third (changed)
  > fourth
  > fifth (changed)
  > EOF

  $ hg fix -r . -r '.^' --working-dir

  $ hg parents --template '{rev}\n'
  4
  $ hg cat -r '.^^' file.changed
  first
  second
  third
  fourth
  fifth
  $ hg cat -r '.^' file.changed
  FIRST (CHANGED)
  second
  third
  fourth
  fifth
  $ hg cat -r . file.changed
  FIRST (CHANGED)
  second
  THIRD (CHANGED)
  fourth
  fifth
  $ cat file.changed
  FIRST (CHANGED)
  second
  THIRD (CHANGED)
  fourth
  FIFTH (CHANGED)

  $ cd ..

If we incrementally fix a merge commit, we should fix any lines that changed
versus either parent. You could imagine only fixing the intersection or some
other subset, but this is necessary if either parent is being fixed. It
prevents us from forgetting fixes made in either parent.

  $ hg init incrementallyfixmergecommit
  $ cd incrementallyfixmergecommit

  $ printf "a\nb\nc\n" > file.changed
  $ hg commit -Aqm "ancestor"

  $ printf "aa\nb\nc\n" > file.changed
  $ hg commit -m "change a"

  $ hg checkout '.^'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ printf "a\nb\ncc\n" > file.changed
  $ hg commit -m "change c"
  created new head

  $ hg merge
  merging file.changed
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ hg commit -m "merge"
  $ hg cat -r . file.changed
  aa
  b
  cc

  $ hg fix -r . --working-dir
  $ hg cat -r . file.changed
  AA
  b
  CC

  $ cd ..

We should be allowed to fix the working (and only the working copy) while
merging.

  $ hg init fixworkingcopywhilemerging
  $ cd fixworkingcopywhilemerging

  $ printf "a\nb\nc\n" > file.changed
  $ hg commit -Aqm "ancestor"

  $ printf "aa\nb\nc\n" > file.changed
  $ hg commit -m "change a"

  $ hg checkout '.^'
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ printf "a\nb\ncc\n" > file.changed
  $ hg commit -m "change c"
  created new head

  $ hg merge
  merging file.changed
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)
  $ cat file.changed
  aa
  b
  cc
Not allowed to fix a parent of the working copy while merging
  $ hg fix -r . --working-dir
  abort: outstanding uncommitted merge
  (use 'hg commit' or 'hg merge --abort')
  [20]
  $ hg fix --working-dir
  $ cat file.changed
  AA
  b
  CC

  $ cd ..

Abort fixing revisions if there is an unfinished operation. We don't want to
make things worse by editing files or stripping/obsoleting things. Also abort
fixing the working directory if there are unresolved merge conflicts.

  $ hg init abortunresolved
  $ cd abortunresolved

  $ echo "foo1" > foo.whole
  $ hg commit -Aqm "foo 1"

  $ hg update null
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  $ echo "foo2" > foo.whole
  $ hg commit -Aqm "foo 2"

  $ hg --config extensions.rebase= rebase -r 1 -d 0
  rebasing 1:c3b6dc0e177a tip "foo 2"
  merging foo.whole
  warning: conflicts while merging foo.whole! (edit, then use 'hg resolve --mark')
  unresolved conflicts (see 'hg resolve', then 'hg rebase --continue')
  [240]

  $ hg --config extensions.rebase= fix --working-dir
  abort: unresolved conflicts
  (use 'hg resolve')
  [255]

  $ hg --config extensions.rebase= fix -r .
  abort: rebase in progress
  (use 'hg rebase --continue', 'hg rebase --abort', or 'hg rebase --stop')
  [20]

  $ cd ..

When fixing a file that was renamed, we should diff against the source of the
rename for incremental fixing and we should correctly reproduce the rename in
the replacement revision.

  $ hg init fixrenamecommit
  $ cd fixrenamecommit

  $ printf "a\nb\nc\n" > source.changed
  $ hg commit -Aqm "source revision"
  $ hg move source.changed dest.changed
  $ printf "a\nb\ncc\n" > dest.changed
  $ hg commit -m "dest revision"

  $ hg fix -r .
  $ hg log -r tip --copies --template "{file_copies}\n"
  dest.changed (source.changed)
  $ hg cat -r tip dest.changed
  a
  b
  CC

  $ cd ..

When fixing revisions that remove files we must ensure that the replacement
actually removes the file, whereas it could accidentally leave it unchanged or
write an empty string to it.

  $ hg init fixremovedfile
  $ cd fixremovedfile

  $ printf "foo\n" > foo.whole
  $ printf "bar\n" > bar.whole
  $ hg commit -Aqm "add files"
  $ hg remove bar.whole
  $ hg commit -m "remove file"
  $ hg status --change .
  R bar.whole
  $ hg fix -r . foo.whole
  $ hg status --change tip
  M foo.whole
  R bar.whole

  $ cd ..

If fixing a revision finds no fixes to make, no replacement revision should be
created.

  $ hg init nofixesneeded
  $ cd nofixesneeded

  $ printf "FOO\n" > foo.whole
  $ hg commit -Aqm "add file"
  $ hg log --template '{rev}\n'
  0
  $ hg fix -r .
  $ hg log --template '{rev}\n'
  0

  $ cd ..

If fixing a commit reverts all the changes in the commit, we replace it with a
commit that changes no files.

  $ hg init nochangesleft
  $ cd nochangesleft

  $ printf "FOO\n" > foo.whole
  $ hg commit -Aqm "add file"
  $ printf "foo\n" > foo.whole
  $ hg commit -m "edit file"
  $ hg status --change .
  M foo.whole
  $ hg fix -r .
  $ hg status --change tip

  $ cd ..

If we fix a parent and child revision together, the child revision must be
replaced if the parent is replaced, even if the diffs of the child needed no
fixes. However, we're free to not replace revisions that need no fixes and have
no ancestors that are replaced.

  $ hg init mustreplacechild
  $ cd mustreplacechild

  $ printf "FOO\n" > foo.whole
  $ hg commit -Aqm "add foo"
  $ printf "foo\n" > foo.whole
  $ hg commit -m "edit foo"
  $ printf "BAR\n" > bar.whole
  $ hg commit -Aqm "add bar"

  $ hg log --graph --template '{rev} {files}'
  @  2 bar.whole
  |
  o  1 foo.whole
  |
  o  0 foo.whole
  
  $ hg fix -r 0:2
  $ hg log --graph --template '{rev} {files}'
  o  4 bar.whole
  |
  o  3
  |
  | @  2 bar.whole
  | |
  | x  1 foo.whole
  |/
  o  0 foo.whole
  

  $ cd ..

It's also possible that the child needs absolutely no changes, but we still
need to replace it to update its parent. If we skipped replacing the child
because it had no file content changes, it would become an orphan for no good
reason.

  $ hg init mustreplacechildevenifnop
  $ cd mustreplacechildevenifnop

  $ printf "Foo\n" > foo.whole
  $ hg commit -Aqm "add a bad foo"
  $ printf "FOO\n" > foo.whole
  $ hg commit -m "add a good foo"
  $ hg fix -r . -r '.^'
  $ hg log --graph --template '{rev} {desc}'
  o  3 add a good foo
  |
  o  2 add a bad foo
  
  @  1 add a good foo
  |
  x  0 add a bad foo
  

  $ cd ..

Similar to the case above, the child revision may become empty as a result of
fixing its parent. We should still create an empty replacement child.
TODO: determine how this should interact with ui.allowemptycommit given that
the empty replacement could have children.

  $ hg init mustreplacechildevenifempty
  $ cd mustreplacechildevenifempty

  $ printf "foo\n" > foo.whole
  $ hg commit -Aqm "add foo"
  $ printf "Foo\n" > foo.whole
  $ hg commit -m "edit foo"
  $ hg fix -r . -r '.^'
  $ hg log --graph --template '{rev} {desc}\n' --stat
  o  3 edit foo
  |
  o  2 add foo
      foo.whole |  1 +
      1 files changed, 1 insertions(+), 0 deletions(-)
  
  @  1 edit foo
  |   foo.whole |  2 +-
  |   1 files changed, 1 insertions(+), 1 deletions(-)
  |
  x  0 add foo
      foo.whole |  1 +
      1 files changed, 1 insertions(+), 0 deletions(-)
  

  $ cd ..

Fixing a secret commit should replace it with another secret commit.

  $ hg init fixsecretcommit
  $ cd fixsecretcommit

  $ printf "foo\n" > foo.whole
  $ hg commit -Aqm "add foo" --secret
  $ hg fix -r .
  $ hg log --template '{rev} {phase}\n'
  1 secret
  0 secret

  $ cd ..

We should also preserve phase when fixing a draft commit while the user has
their default set to secret.

  $ hg init respectphasesnewcommit
  $ cd respectphasesnewcommit

  $ printf "foo\n" > foo.whole
  $ hg commit -Aqm "add foo"
  $ hg --config phases.newcommit=secret fix -r .
  $ hg log --template '{rev} {phase}\n'
  1 draft
  0 draft

  $ cd ..

Debug output should show what fixer commands are being subprocessed, which is
useful for anyone trying to set up a new config.

  $ hg init debugoutput
  $ cd debugoutput

  $ printf "foo\nbar\nbaz\n" > foo.changed
  $ hg commit -Aqm "foo"
  $ printf "Foo\nbar\nBaz\n" > foo.changed
  $ hg --debug fix --working-dir
  subprocess: * $TESTTMP/uppercase.py 1-1 3-3 (glob)

  $ cd ..

Fixing an obsolete revision can cause divergence, so we abort unless the user
configures to allow it. This is not yet smart enough to know whether there is a
successor, but even then it is not likely intentional or idiomatic to fix an
obsolete revision.

  $ hg init abortobsoleterev
  $ cd abortobsoleterev

  $ printf "foo\n" > foo.changed
  $ hg commit -Aqm "foo"
  $ hg ci --amend -m rewritten
  $ hg --hidden fix -r 0
  abort: cannot fix b87e30dbf19b, as that creates content-divergence with 2e007a78dfb8
  (add --verbose for details or see 'hg help evolution.instability')
  [10]

  $ hg --hidden fix -r 0 --config experimental.evolution.allowdivergence=true
  2 new content-divergent changesets
  $ hg cat -r tip foo.changed
  FOO

  $ cd ..

Test all of the available substitution values for fixer commands.

  $ hg init substitution
  $ cd substitution

  $ mkdir foo
  $ printf "hello\ngoodbye\n" > foo/bar
  $ hg add
  adding foo/bar
  $ hg --config "fix.fail:command=printf '%s\n' '{rootpath}' '{basename}'" \
  >    --config "fix.fail:linerange='{first}' '{last}'" \
  >    --config "fix.fail:pattern=foo/bar" \
  >    fix --working-dir
  $ cat foo/bar
  foo/bar
  bar
  1
  2

  $ cd ..

The --base flag should allow picking the revisions to diff against for changed
files and incremental line formatting.

  $ hg init baseflag
  $ cd baseflag

  $ printf "one\ntwo\n" > foo.changed
  $ printf "bar\n" > bar.changed
  $ hg commit -Aqm "first"
  $ printf "one\nTwo\n" > foo.changed
  $ hg commit -m "second"
  $ hg fix -w --base .
  $ hg status
  $ hg fix -w --base null
  $ cat foo.changed
  ONE
  TWO
  $ cat bar.changed
  BAR

  $ cd ..

If the user asks to fix the parent of another commit, they are asking to create
an orphan. We must respect experimental.evolution.allowunstable.

  $ hg init allowunstable
  $ cd allowunstable

  $ printf "one\n" > foo.whole
  $ hg commit -Aqm "first"
  $ printf "two\n" > foo.whole
  $ hg commit -m "second"
  $ hg --config experimental.evolution.allowunstable=False fix -r '.^'
  abort: cannot fix changeset, as that will orphan 1 descendants
  (see 'hg help evolution.instability')
  [10]
  $ hg fix -r '.^'
  1 new orphan changesets
  $ hg cat -r 2 foo.whole
  ONE

  $ cd ..

The --base flag affects the set of files being fixed. So while the --whole flag
makes the base irrelevant for changed line ranges, it still changes the
meaning and effect of the command. In this example, no files or lines are fixed
until we specify the base, but then we do fix unchanged lines.

  $ hg init basewhole
  $ cd basewhole
  $ printf "foo1\n" > foo.changed
  $ hg commit -Aqm "first"
  $ printf "foo2\n" >> foo.changed
  $ printf "bar\n" > bar.changed
  $ hg commit -Aqm "second"

  $ hg fix --working-dir --whole
  $ cat *.changed
  bar
  foo1
  foo2

  $ hg fix --working-dir --base 0 --whole
  $ cat *.changed
  BAR
  FOO1
  FOO2

  $ cd ..

The execution order of tools can be controlled. This example doesn't work if
you sort after truncating, but the config defines the correct order while the
definitions are out of order (which might imply the incorrect order given the
implementation of fix). The goal is to use multiple tools to select the lowest
5 numbers in the file.

  $ hg init priorityexample
  $ cd priorityexample

  $ cat >> .hg/hgrc <<EOF
  > [fix]
  > head:command = head -n 5
  > head:pattern = numbers.txt
  > head:priority = 1
  > sort:command = sort -n
  > sort:pattern = numbers.txt
  > sort:priority = 2
  > EOF

  $ printf "8\n2\n3\n6\n7\n4\n9\n5\n1\n0\n" > numbers.txt
  $ hg add -q
  $ hg fix -w
  $ cat numbers.txt
  0
  1
  2
  3
  4

And of course we should be able to break this by reversing the execution order.
Test negative priorities while we're at it.

  $ cat >> .hg/hgrc <<EOF
  > [fix]
  > head:priority = -1
  > sort:priority = -2
  > EOF
  $ printf "8\n2\n3\n6\n7\n4\n9\n5\n1\n0\n" > numbers.txt
  $ hg fix -w
  $ cat numbers.txt
  2
  3
  6
  7
  8

  $ cd ..

It's possible for repeated applications of a fixer tool to create cycles in the
generated content of a file. For example, two users with different versions of
a code formatter might fight over the formatting when they run hg fix. In the
absence of other changes, this means we could produce commits with the same
hash in subsequent runs of hg fix. This is a problem unless we support
obsolescence cycles well. We avoid this by adding an extra field to the
successor which forces it to have a new hash. That's why this test creates
three revisions instead of two.

  $ hg init cyclictool
  $ cd cyclictool

  $ cat >> .hg/hgrc <<EOF
  > [fix]
  > swapletters:command = tr ab ba
  > swapletters:pattern = foo
  > EOF

  $ echo ab > foo
  $ hg commit -Aqm foo

  $ hg fix -r 0
  $ hg fix -r 1

  $ hg cat -r 0 foo --hidden
  ab
  $ hg cat -r 1 foo --hidden
  ba
  $ hg cat -r 2 foo
  ab

  $ cd ..

We run fixer tools in the repo root so they can look for config files or other
important things in the working directory. This does NOT mean we are
reconstructing a working copy of every revision being fixed; we're just giving
the tool knowledge of the repo's location in case it can do something
reasonable with that.

  $ hg init subprocesscwd
  $ cd subprocesscwd

  $ cat >> .hg/hgrc <<EOF
  > [fix]
  > printcwd:command = "$PYTHON" -c "import os; print(os.getcwd())"
  > printcwd:pattern = relpath:foo/bar
  > filesetpwd:command = "$PYTHON" -c "import os; print('fs: ' + os.getcwd())"
  > filesetpwd:pattern = set:**quux
  > EOF

  $ mkdir foo
  $ printf "bar\n" > foo/bar
  $ printf "quux\n" > quux
  $ hg commit -Aqm blah

  $ hg fix -w -r . foo/bar
  $ hg cat -r tip foo/bar
  $TESTTMP/subprocesscwd
  $ cat foo/bar
  $TESTTMP/subprocesscwd

  $ cd foo

  $ hg fix -w -r . bar
  $ hg cat -r tip bar ../quux
  $TESTTMP/subprocesscwd
  quux
  $ cat bar ../quux
  $TESTTMP/subprocesscwd
  quux
  $ echo modified > bar
  $ hg fix -w bar
  $ cat bar
  $TESTTMP/subprocesscwd

Apparently fixing p1() and its descendants doesn't include wdir() unless
explicitly stated.

  $ hg fix -r '.::'
  $ hg cat -r . ../quux
  quux
  $ hg cat -r tip ../quux
  fs: $TESTTMP/subprocesscwd
  $ cat ../quux
  quux

Clean files are not fixed unless explicitly named
  $ echo 'dirty' > ../quux

  $ hg fix --working-dir
  $ cat ../quux
  fs: $TESTTMP/subprocesscwd

  $ cd ../..

Tools configured without a pattern are ignored. It would be too dangerous to
run them on all files, because this might happen while testing a configuration
that also deletes all of the file content. There is no reasonable subset of the
files to use as a default. Users should be explicit about what files are
affected by a tool. This test also confirms that we don't crash when the
pattern config is missing, and that we only warn about it once.

  $ hg init nopatternconfigured
  $ cd nopatternconfigured

  $ printf "foo" > foo
  $ printf "bar" > bar
  $ hg add -q
  $ hg fix --debug --working-dir --config "fix.nopattern:command=echo fixed"
  fixer tool has no pattern configuration: nopattern
  $ cat foo bar
  foobar (no-eol)
  $ hg fix --debug --working-dir --config "fix.nocommand:pattern=foo.bar"
  fixer tool has no command configuration: nocommand

  $ cd ..

Tools can be disabled. Disabled tools do nothing but print a debug message.

  $ hg init disabled
  $ cd disabled

  $ printf "foo\n" > foo
  $ hg add -q
  $ hg fix --debug --working-dir --config "fix.disabled:command=echo fixed" \
  >                              --config "fix.disabled:pattern=foo" \
  >                              --config "fix.disabled:enabled=false"
  ignoring disabled fixer tool: disabled
  $ cat foo
  foo

  $ cd ..

Test that we can configure a fixer to affect all files regardless of the cwd.
The way we invoke matching must not prohibit this.

  $ hg init affectallfiles
  $ cd affectallfiles

  $ mkdir foo bar
  $ printf "foo" > foo/file
  $ printf "bar" > bar/file
  $ printf "baz" > baz_file
  $ hg add -q

  $ cd bar
  $ hg fix --working-dir --config "fix.cooltool:command=echo fixed" \
  >                      --config "fix.cooltool:pattern=glob:**"
  $ cd ..

  $ cat foo/file
  fixed
  $ cat bar/file
  fixed
  $ cat baz_file
  fixed

  $ cd ..

Tools should be able to run on unchanged files, even if they set :linerange.
This includes a corner case where deleted chunks of a file are not considered
changes.

  $ hg init skipclean
  $ cd skipclean

  $ printf "a\nb\nc\n" > foo
  $ printf "a\nb\nc\n" > bar
  $ printf "a\nb\nc\n" > baz
  $ hg commit -Aqm "base"

  $ printf "a\nc\n" > foo
  $ printf "a\nx\nc\n" > baz

  $ cat >> print.py <<EOF
  > import sys
  > for a in sys.argv[1:]:
  >    print(a)
  > EOF

  $ hg fix --working-dir foo bar baz \
  >        --config "fix.changedlines:command=\"$PYTHON\" print.py \"Line ranges:\"" \
  >        --config 'fix.changedlines:linerange="{first} through {last}"' \
  >        --config 'fix.changedlines:pattern=glob:**' \
  >        --config 'fix.changedlines:skipclean=false'

  $ cat foo
  Line ranges:
  $ cat bar
  Line ranges:
  $ cat baz
  Line ranges:
  2 through 2

  $ cd ..

Test various cases around merges. We were previously dropping files if they were
created on only the p2 side of the merge, so let's test permutations of:
*   added, was fixed
*   added, considered for fixing but was already good
*   added, not considered for fixing
*   modified, was fixed
*   modified, considered for fixing but was already good
*   modified, not considered for fixing

Before the bug was fixed where we would drop files, this test demonstrated the
following issues:
*   new_in_r1.ignored, new_in_r1_already_good.changed, and
>   mod_in_r1_already_good.changed were NOT in the manifest for the merge commit
*   mod_in_r1.ignored had its contents from r0, NOT r1.

We're also setting a named branch for every commit to demonstrate that the
branch is kept intact and there aren't issues updating to another branch in the
middle of fix.

  $ hg init merge_keeps_files
  $ cd merge_keeps_files
  $ for f in r0 mod_in_r1 mod_in_r2 mod_in_merge mod_in_child; do
  >   for c in changed whole ignored; do
  >     printf "hello\n" > $f.$c
  >   done
  >   printf "HELLO\n" > "mod_in_${f}_already_good.changed"
  > done
  $ hg branch -q r0
  $ hg ci -Aqm 'r0'
  $ hg phase -p
  $ make_test_files() {
  >   printf "world\n" >> "mod_in_$1.changed"
  >   printf "world\n" >> "mod_in_$1.whole"
  >   printf "world\n" >> "mod_in_$1.ignored"
  >   printf "WORLD\n" >> "mod_in_$1_already_good.changed"
  >   printf "new in $1\n" > "new_in_$1.changed"
  >   printf "new in $1\n" > "new_in_$1.whole"
  >   printf "new in $1\n" > "new_in_$1.ignored"
  >   printf "ALREADY GOOD, NEW IN THIS REV\n" > "new_in_$1_already_good.changed"
  > }
  $ make_test_commit() {
  >   make_test_files "$1"
  >   hg branch -q "$1"
  >   hg ci -Aqm "$2"
  > }
  $ make_test_commit r1 "merge me, pt1"
  $ hg co -q ".^"
  $ make_test_commit r2 "merge me, pt2"
  $ hg merge -qr 1
  $ make_test_commit merge "evil merge"
  $ make_test_commit child "child of merge"
  $ make_test_files wdir
  $ hg fix -r 'not public()' -w
  $ hg log -G -T'{rev}:{shortest(node,8)}: branch:{branch} desc:{desc}'
  @  8:c22ce900: branch:child desc:child of merge
  |
  o    7:5a30615a: branch:merge desc:evil merge
  |\
  | o  6:4e5acdc4: branch:r2 desc:merge me, pt2
  | |
  o |  5:eea01878: branch:r1 desc:merge me, pt1
  |/
  o  0:0c548d87: branch:r0 desc:r0
  
  $ hg files -r tip
  mod_in_child.changed
  mod_in_child.ignored
  mod_in_child.whole
  mod_in_child_already_good.changed
  mod_in_merge.changed
  mod_in_merge.ignored
  mod_in_merge.whole
  mod_in_merge_already_good.changed
  mod_in_mod_in_child_already_good.changed
  mod_in_mod_in_merge_already_good.changed
  mod_in_mod_in_r1_already_good.changed
  mod_in_mod_in_r2_already_good.changed
  mod_in_r0_already_good.changed
  mod_in_r1.changed
  mod_in_r1.ignored
  mod_in_r1.whole
  mod_in_r1_already_good.changed
  mod_in_r2.changed
  mod_in_r2.ignored
  mod_in_r2.whole
  mod_in_r2_already_good.changed
  new_in_child.changed
  new_in_child.ignored
  new_in_child.whole
  new_in_child_already_good.changed
  new_in_merge.changed
  new_in_merge.ignored
  new_in_merge.whole
  new_in_merge_already_good.changed
  new_in_r1.changed
  new_in_r1.ignored
  new_in_r1.whole
  new_in_r1_already_good.changed
  new_in_r2.changed
  new_in_r2.ignored
  new_in_r2.whole
  new_in_r2_already_good.changed
  r0.changed
  r0.ignored
  r0.whole
  $ for f in "$(hg files -r tip)"; do hg cat -r tip $f -T'{path}:\n{data}\n'; done
  mod_in_child.changed:
  hello
  WORLD
  
  mod_in_child.ignored:
  hello
  world
  
  mod_in_child.whole:
  HELLO
  WORLD
  
  mod_in_child_already_good.changed:
  WORLD
  
  mod_in_merge.changed:
  hello
  WORLD
  
  mod_in_merge.ignored:
  hello
  world
  
  mod_in_merge.whole:
  HELLO
  WORLD
  
  mod_in_merge_already_good.changed:
  WORLD
  
  mod_in_mod_in_child_already_good.changed:
  HELLO
  
  mod_in_mod_in_merge_already_good.changed:
  HELLO
  
  mod_in_mod_in_r1_already_good.changed:
  HELLO
  
  mod_in_mod_in_r2_already_good.changed:
  HELLO
  
  mod_in_r0_already_good.changed:
  HELLO
  
  mod_in_r1.changed:
  hello
  WORLD
  
  mod_in_r1.ignored:
  hello
  world
  
  mod_in_r1.whole:
  HELLO
  WORLD
  
  mod_in_r1_already_good.changed:
  WORLD
  
  mod_in_r2.changed:
  hello
  WORLD
  
  mod_in_r2.ignored:
  hello
  world
  
  mod_in_r2.whole:
  HELLO
  WORLD
  
  mod_in_r2_already_good.changed:
  WORLD
  
  new_in_child.changed:
  NEW IN CHILD
  
  new_in_child.ignored:
  new in child
  
  new_in_child.whole:
  NEW IN CHILD
  
  new_in_child_already_good.changed:
  ALREADY GOOD, NEW IN THIS REV
  
  new_in_merge.changed:
  NEW IN MERGE
  
  new_in_merge.ignored:
  new in merge
  
  new_in_merge.whole:
  NEW IN MERGE
  
  new_in_merge_already_good.changed:
  ALREADY GOOD, NEW IN THIS REV
  
  new_in_r1.changed:
  NEW IN R1
  
  new_in_r1.ignored:
  new in r1
  
  new_in_r1.whole:
  NEW IN R1
  
  new_in_r1_already_good.changed:
  ALREADY GOOD, NEW IN THIS REV
  
  new_in_r2.changed:
  NEW IN R2
  
  new_in_r2.ignored:
  new in r2
  
  new_in_r2.whole:
  NEW IN R2
  
  new_in_r2_already_good.changed:
  ALREADY GOOD, NEW IN THIS REV
  
  r0.changed:
  hello
  
  r0.ignored:
  hello
  
  r0.whole:
  hello
  

We should execute the fixer tools as few times as possible, because they might
be slow or expensive to execute. The inputs to each execution are effectively
the file path, file content, and line ranges. So, we should be able to re-use
results whenever those inputs are repeated. That saves a lot of work when
fixing chains of commits that all have the same file revision for a path being
fixed.

  $ hg init numberofinvocations
  $ cd numberofinvocations

  $ printf "bar1" > bar.log
  $ printf "baz1" > baz.log
  $ printf "foo1" > foo.log
  $ printf "qux1" > qux.log
  $ hg commit -Aqm "commit1"

  $ printf "bar2" > bar.log
  $ printf "baz2" > baz.log
  $ printf "foo2" > foo.log
  $ hg commit -Aqm "commit2"

  $ printf "bar3" > bar.log
  $ printf "baz3" > baz.log
  $ hg commit -Aqm "commit3"

  $ printf "bar4" > bar.log

  $ LOGFILE=$TESTTMP/log
  $ LOGGER=$TESTTMP/log.py
  $ cat >> $LOGGER <<EOF
  > # Appends the input file's name to the log file.
  > import sys
  > with open(r'$LOGFILE', 'a') as f:
  >     f.write(sys.argv[1] + '\n')
  > sys.stdout.write(sys.stdin.read())
  > EOF

  $ hg fix --working-dir -r "all()" \
  >        --config "fix.log:command=\"$PYTHON\" \"$LOGGER\" {rootpath}" \
  >        --config "fix.log:pattern=glob:**.log"

  $ cat $LOGFILE | sort | uniq -c
  \s*4 bar.log (re)
  \s*4 baz.log (re)
  \s*3 foo.log (re)
  \s*2 qux.log (re)

  $ cd ..

For tools that support line ranges, it's wrong to blindly re-use fixed file
content for the same file revision if it appears twice with different baserevs,
because the line ranges could be different. Since computing line ranges is
ambiguous, this isn't a matter of correctness, but it affects the usability of
this extension. It could maybe be simpler if baserevs were computed on a
per-file basis to make this situation impossible to construct.

In the following example, we construct two subgraphs with the same file
revisions, and fix different sub-subgraphs to get different baserevs and
different changed line ranges. The key precondition is that revisions 1 and 4
have the same file revision, and the key result is that their successors don't
have the same file content, because we want to fix different areas of that same
file revision's content.

  $ hg init differentlineranges
  $ cd differentlineranges

  $ printf "a\nb\n" > file.changed
  $ hg commit -Aqm "0 ab"
  $ printf "a\nx\n" > file.changed
  $ hg commit -Aqm "1 ax"
  $ hg remove file.changed
  $ hg commit -Aqm "2 removed"
  $ hg revert file.changed -r 0
  $ hg commit -Aqm "3 ab (reverted)"
  $ hg revert file.changed -r 1
  $ hg commit -Aqm "4 ax (reverted)"

  $ hg manifest --debug --template "{hash}\n" -r 0; \
  > hg manifest --debug --template "{hash}\n" -r 3
  418f692145676128d2fb518b027ddbac624be76e
  418f692145676128d2fb518b027ddbac624be76e
  $ hg manifest --debug --template "{hash}\n" -r 1; \
  > hg manifest --debug --template "{hash}\n" -r 4
  09b8b3ce5a507caaa282f7262679e6d04091426c
  09b8b3ce5a507caaa282f7262679e6d04091426c

  $ hg fix --working-dir -r 1+3+4
  3 new orphan changesets

  $ hg cat file.changed -r "successors(1)" --hidden
  a
  X
  $ hg cat file.changed -r "successors(4)" --hidden
  A
  X

  $ cd ..
