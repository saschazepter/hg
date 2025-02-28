#testcases dirstate-v1 dirstate-v2

#if dirstate-v2
  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-dirstate-v2=1
  > [storage]
  > dirstate-v2.slow-path=allow
  > EOF
#endif

  $ hg init ignorerepo
  $ cd ignorerepo

debugignore with no hgignore should be deterministic:
  $ hg debugignore
  <nevermatcher>

#if rhg
  $ rhg_debugignore() {
  >   echo debugignorerhg:
  >   hg debugignorerhg
  >   echo script::hgignore --print-re:
  >   hg script::hgignore --print-re
  > }
  $ rhg_debugignore
  debugignorerhg:
  (?:)
  script::hgignore --print-re:
  
#endif

Issue562: .hgignore requires newline at end:

  $ touch foo
  $ touch bar
  $ touch baz
  $ cat > makeignore.py <<EOF
  > f = open(".hgignore", "w")
  > f.write("ignore\n")
  > f.write("foo\n")
  > # No EOL here
  > f.write("bar")
  > f.close()
  > EOF

  $ "$PYTHON" makeignore.py

Should display baz only:

  $ hg status
  ? baz

  $ rm foo bar baz .hgignore makeignore.py

  $ touch a.o
  $ touch a.c
  $ touch syntax
  $ mkdir dir
  $ touch dir/a.o
  $ touch dir/b.o
  $ touch dir/c.o

  $ hg add dir/a.o
  $ hg commit -m 0
  $ hg add dir/b.o

  $ hg status
  A dir/b.o
  ? a.c
  ? a.o
  ? dir/c.o
  ? syntax

  $ echo "*.o" > .hgignore
  $ hg status
  abort: $TESTTMP/ignorerepo/.hgignore: invalid pattern (relre): *.o (glob)
  [255]

Test relre with flags (issue6759)
---------------------------------

regexp with flag is the first one

  $ echo 're:(?i)\.O$' > .hgignore
  $ echo 're:.hgignore' >> .hgignore
  $ hg status
  A dir/b.o
  ? a.c
  ? syntax
  $ hg debugignore
  <includematcher includes='(?i:.*\\.O$)|.*.hgignore'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\\A[\x00-	\x0b-\xf4\x8f\xbf\xbf]*(?:(?:\\.[Oo]\\z)|(?:[\x00-	\x0b-\xf4\x8f\xbf\xbf](?:hgignore)))) (esc)
  script::hgignore --print-re:
  ^(?:(?i:.*\.O$)|.*.hgignore)
#endif

regex with flag is not the first one

  $ echo 're:.hgignore' > .hgignore
  $ echo 're:(?i)\.O$' >> .hgignore
  $ hg status
  A dir/b.o
  ? a.c
  ? syntax
  $ hg debugignore
  <includematcher includes='.*.hgignore|(?i:.*\\.O$)'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\\A[\x00-	\x0b-\xf4\x8f\xbf\xbf]*(?:(?:[\x00-	\x0b-\xf4\x8f\xbf\xbf](?:hgignore))|(?:\\.[Oo]\\z))) (esc)
  script::hgignore --print-re:
  ^(?:.*.hgignore|(?i:.*\.O$))
#endif

flag in a pattern should affect that pattern only

  $ echo 're:(?i)\.O$' > .hgignore
  $ echo 're:.HGIGNORE' >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax
  $ hg debugignore
  <includematcher includes='(?i:.*\\.O$)|.*.HGIGNORE'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\\A[\x00-	\x0b-\xf4\x8f\xbf\xbf]*(?:(?:\\.[Oo]\\z)|(?:[\x00-	\x0b-\xf4\x8f\xbf\xbf](?:HGIGNORE)))) (esc)
  script::hgignore --print-re:
  ^(?:(?i:.*\.O$)|.*.HGIGNORE)
#endif

  $ echo 're:.HGIGNORE' > .hgignore
  $ echo 're:(?i)\.O$' >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax
  $ hg debugignore
  <includematcher includes='.*.HGIGNORE|(?i:.*\\.O$)'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\\A[\x00-	\x0b-\xf4\x8f\xbf\xbf]*(?:(?:[\x00-	\x0b-\xf4\x8f\xbf\xbf](?:HGIGNORE))|(?:\\.[Oo]\\z))) (esc)
  script::hgignore --print-re:
  ^(?:.*.HGIGNORE|(?i:.*\.O$))
#endif

Check that '^' after flag is properly detected.

  $ echo 're:(?i)^[^a].*\.O$' > .hgignore
  $ echo 're:.HGIGNORE' >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? syntax
  $ hg debugignore
  <includematcher includes='(?i:^[^a].*\\.O$)|.*.HGIGNORE'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\\A(?:(?:\\A[\x00-@B-`b-\xf4\x8f\xbf\xbf][\x00-	\x0b-\xf4\x8f\xbf\xbf]*\\.[Oo]\\z)|(?:[\x00-	\x0b-\xf4\x8f\xbf\xbf]*[\x00-	\x0b-\xf4\x8f\xbf\xbf](?:HGIGNORE)))) (esc)
  script::hgignore --print-re:
  ^(?:(?i:^[^a].*\.O$)|.*.HGIGNORE)
#endif

  $ echo 're:.HGIGNORE' > .hgignore
  $ echo 're:(?i)^[^a].*\.O$' >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? syntax
  $ hg debugignore
  <includematcher includes='.*.HGIGNORE|(?i:^[^a].*\\.O$)'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\\A(?:(?:[\x00-	\x0b-\xf4\x8f\xbf\xbf]*[\x00-	\x0b-\xf4\x8f\xbf\xbf](?:HGIGNORE))|(?:\\A[\x00-@B-`b-\xf4\x8f\xbf\xbf][\x00-	\x0b-\xf4\x8f\xbf\xbf]*\\.[Oo]\\z))) (esc)
  script::hgignore --print-re:
  ^(?:.*.HGIGNORE|(?i:^[^a].*\.O$))
#endif

further testing
---------------

  $ echo 're:^(?!a).*\.o$' > .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? syntax
#if rhg
  $ hg status --config rhg.on-unsupported=abort
  unsupported feature: Unsupported syntax regex parse error:
      ^(?!a).*\.o$
       ^^^
  error: look-around, including look-ahead and look-behind, is not supported
  [252]
#endif

Ensure given files are relative to cwd

  $ echo "dir/.*\.o" > .hgignore
  $ hg status -i
  I dir/c.o

  $ hg debugignore dir/c.o dir/missing.o
  dir/c.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 1: 'dir/.*\.o') (glob)
  dir/missing.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 1: 'dir/.*\.o') (glob)
  $ cd dir
  $ hg debugignore c.o missing.o
  c.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 1: 'dir/.*\.o') (glob)
  missing.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 1: 'dir/.*\.o') (glob)

For icasefs, inexact matches also work, except for missing files

#if icasefs
  $ hg debugignore c.O missing.O
  c.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 1: 'dir/.*\.o') (glob)
  missing.O is not ignored
#endif

  $ cd ..

  $ echo ".*\.o" > .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax

Ensure that comments work:

  $ touch 'foo#bar' 'quux#' 'quu0#'
#if no-windows
  $ touch 'baz\' 'baz\wat' 'ba0\#wat' 'ba1\\' 'ba1\\wat' 'quu0\'
#endif

  $ cat <<'EOF' >> .hgignore
  > # full-line comment
  >   # whitespace-only comment line
  > syntax# pattern, no whitespace, then comment
  > a.c  # pattern, then whitespace, then comment
  > baz\\# # (escaped) backslash, then comment
  > ba0\\\#w # (escaped) backslash, escaped comment character, then comment
  > ba1\\\\# # (escaped) backslashes, then comment
  > foo\#b # escaped comment character
  > quux\## escaped comment character at end of name
  > EOF
  $ hg status
  A dir/b.o
  ? .hgignore
  ? quu0#
  ? quu0\ (no-windows !)

  $ cat <<'EOF' > .hgignore
  > .*\.o
  > syntax: glob
  > syntax# pattern, no whitespace, then comment
  > a.c  # pattern, then whitespace, then comment
  > baz\\#* # (escaped) backslash, then comment
  > ba0\\\#w* # (escaped) backslash, escaped comment character, then comment
  > ba1\\\\#* # (escaped) backslashes, then comment
  > foo\#b* # escaped comment character
  > quux\## escaped comment character at end of name
  > quu0[\#]# escaped comment character inside [...]
  > EOF
  $ hg status
  A dir/b.o
  ? .hgignore
  ? ba1\\wat (no-windows !)
  ? baz\wat (no-windows !)
  ? quu0\ (no-windows !)

  $ rm 'foo#bar' 'quux#' 'quu0#'
#if no-windows
  $ rm 'baz\' 'baz\wat' 'ba0\#wat' 'ba1\\' 'ba1\\wat' 'quu0\'
#endif

Check that '^\.' does not ignore the root directory:

  $ echo "^\." > .hgignore
  $ hg status
  A dir/b.o
  ? a.c
  ? a.o
  ? dir/c.o
  ? syntax

Test that patterns from ui.ignore options are read:

  $ echo > .hgignore
  $ cat >> $HGRCPATH << EOF
  > [ui]
  > ignore.other = $TESTTMP/ignorerepo/.hg/testhgignore
  > EOF
  $ echo "glob:**.o" > .hg/testhgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax

empty out testhgignore
  $ echo > .hg/testhgignore

Test relative ignore path (issue4473):

  $ cat >> $HGRCPATH << EOF
  > [ui]
  > ignore.relative = .hg/testhgignorerel
  > EOF
  $ echo "glob:*.o" > .hg/testhgignorerel
  $ cd dir
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax
  $ hg debugignore
  <includematcher includes='.*\\.o(?:/|$)'>

  $ cd ..
  $ echo > .hg/testhgignorerel
  $ echo "syntax: glob" > .hgignore
  $ echo "re:.*\.o" >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax

  $ echo "syntax: invalid" > .hgignore
  $ hg status
  $TESTTMP/ignorerepo/.hgignore: ignoring invalid syntax 'invalid'
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? dir/c.o
  ? syntax

  $ echo "syntax: glob" > .hgignore
  $ echo "*.o" >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? syntax

  $ echo "relglob:syntax*" > .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? dir/c.o

  $ echo "rootglob:dir/b.o" > .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? dir/c.o
  ? syntax
#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\A[a&&b])
  script::hgignore --print-re:
  ^(?:dir/b\.o(?:/|$))
#endif

  $ echo "relglob:*" > .hgignore
  $ hg status
  A dir/b.o

  $ cd dir
  $ hg status .
  A b.o

  $ hg debugignore
  <includematcher includes='.*(?:/|$)'>

#if rhg
  $ rhg_debugignore
  debugignorerhg:
  (?:\A(?-u:[\x00-\xFF])*?(?:/|\z))
  script::hgignore --print-re:
  ^(?:.*(?:/|$))
#endif

  $ hg debugignore b.o
  b.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 1: '*') (glob)

  $ cd ..

Check patterns that match only the directory

"(fsmonitor !)" below assumes that fsmonitor is enabled with
"walk_on_invalidate = false" (default), which doesn't involve
re-walking whole repository at detection of .hgignore change.

  $ echo "^dir\$" > .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? dir/c.o (fsmonitor !)
  ? syntax

Check recursive glob pattern matches no directories (dir/**/c.o matches dir/c.o)

  $ echo "syntax: glob" > .hgignore
  $ echo "dir/**/c.o" >> .hgignore
  $ touch dir/c.o
  $ mkdir dir/subdir
  $ touch dir/subdir/c.o
  $ hg status
  A dir/b.o
  ? .hgignore
  ? a.c
  ? a.o
  ? syntax
  $ hg debugignore a.c
  a.c is not ignored
  $ hg debugignore dir/c.o
  dir/c.o is ignored
  (ignore rule in $TESTTMP/ignorerepo/.hgignore, line 2: 'dir/**/c.o') (glob)

Check rooted globs

  $ hg purge --all --config extensions.purge=
  $ echo "syntax: rootglob" > .hgignore
  $ echo "a/*.ext" >> .hgignore
  $ for p in a b/a aa; do mkdir -p $p; touch $p/b.ext; done
  $ hg status -A 'set:**.ext'
  ? aa/b.ext
  ? b/a/b.ext
  I a/b.ext

Check using 'include:' in ignore file

  $ hg purge --all --config extensions.purge=
  $ touch foo.included

  $ echo ".*.included" > otherignore
  $ hg status -I "include:otherignore"
  ? foo.included

  $ echo "include:otherignore" >> .hgignore
  $ hg status
  A dir/b.o
  ? .hgignore
  ? otherignore

Check recursive uses of 'include:'

  $ echo "include:nested/ignore" >> otherignore
  $ mkdir nested nested/more
  $ echo "glob:*ignore" > nested/ignore
  $ echo "rootglob:a" >> nested/ignore
  $ touch a nested/a nested/more/a
  $ hg status
  A dir/b.o
  ? nested/a
  ? nested/more/a
  $ rm a nested/a nested/more/a

  $ cp otherignore goodignore
  $ echo "include:badignore" >> otherignore
  $ hg status
  skipping unreadable pattern file 'badignore': $ENOENT$
  A dir/b.o

  $ mv goodignore otherignore

Check using 'include:' while in a non-root directory

  $ cd ..
  $ hg -R ignorerepo status
  A dir/b.o
  $ cd ignorerepo

Check including subincludes

  $ hg revert -q --all
  $ hg purge --all --config extensions.purge=
  $ echo ".hgignore" > .hgignore
  $ mkdir dir1 dir2
  $ touch dir1/file1 dir1/file2 dir2/file1 dir2/file2
  $ echo "subinclude:dir2/.hgignore" >> .hgignore
  $ echo "glob:file*2" > dir2/.hgignore
  $ hg status
  ? dir1/file1
  ? dir1/file2
  ? dir2/file1

Check including subincludes with other patterns

  $ echo "subinclude:dir1/.hgignore" >> .hgignore

  $ mkdir dir1/subdir
  $ touch dir1/subdir/file1
  $ echo "rootglob:f?le1" > dir1/.hgignore
  $ hg status
  ? dir1/file2
  ? dir1/subdir/file1
  ? dir2/file1
  $ rm dir1/subdir/file1

  $ echo "regexp:f.le1" > dir1/.hgignore
  $ hg status
  ? dir1/file2
  ? dir2/file1

Check multiple levels of sub-ignores

  $ touch dir1/subdir/subfile1 dir1/subdir/subfile3 dir1/subdir/subfile4
  $ echo "subinclude:subdir/.hgignore" >> dir1/.hgignore
  $ echo "glob:subfil*3" >> dir1/subdir/.hgignore

  $ hg status
  ? dir1/file2
  ? dir1/subdir/subfile4
  ? dir2/file1

Check include subignore at the same level

  $ mv dir1/subdir/.hgignore dir1/.hgignoretwo
  $ echo "regexp:f.le1" > dir1/.hgignore
  $ echo "subinclude:.hgignoretwo" >> dir1/.hgignore
  $ echo "glob:file*2" > dir1/.hgignoretwo

  $ hg status | grep file2
  [1]
  $ hg debugignore dir1/file2
  dir1/file2 is ignored
  (ignore rule in dir2/.hgignore, line 1: 'file*2')

#if windows

Windows paths are accepted on input

  $ rm dir1/.hgignore
  $ echo "dir1/file*" >> .hgignore
  $ hg debugignore "dir1\file2"
  dir1/file2 is ignored
  (ignore rule in $TESTTMP\ignorerepo\.hgignore, line 4: 'dir1/file*')
  $ hg up -qC .

#endif

#if dirstate-v2 rust

Check the hash of ignore patterns written in the dirstate
This is an optimization that is only relevant when using the Rust extensions

  $ cat_filename_and_hash () {
  >     for i in "$@"; do
  >         printf "$i "
  >         cat "$i" | "$TESTDIR"/f --raw-sha1 | sed 's/^raw-sha1=//'
  >     done
  > }
  $ hg status > /dev/null
  $ cat_filename_and_hash .hg/testhgignore .hg/testhgignorerel .hgignore dir2/.hgignore dir1/.hgignore dir1/.hgignoretwo | $TESTDIR/f --sha1
  sha1=c0beb296395d48ced8e14f39009c4ea6e409bfe6
  $ hg debugstate --docket | grep ignore
  ignore pattern hash: c0beb296395d48ced8e14f39009c4ea6e409bfe6

  $ echo rel > .hg/testhgignorerel
  $ hg status > /dev/null
  $ cat_filename_and_hash .hg/testhgignore .hg/testhgignorerel .hgignore dir2/.hgignore dir1/.hgignore dir1/.hgignoretwo | $TESTDIR/f --sha1
  sha1=b8e63d3428ec38abc68baa27631516d5ec46b7fa
  $ hg debugstate --docket | grep ignore
  ignore pattern hash: b8e63d3428ec38abc68baa27631516d5ec46b7fa
  $ cd ..

Check that the hash depends on the source of the hgignore patterns
(otherwise the context is lost and things like subinclude are cached improperly)

  $ hg init ignore-collision
  $ cd ignore-collision
  $ echo > .hg/testhgignorerel

  $ mkdir dir1/ dir1/subdir
  $ touch dir1/subdir/f dir1/subdir/ignored1
  $ echo 'ignored1' > dir1/.hgignore

  $ mkdir dir2 dir2/subdir
  $ touch dir2/subdir/f dir2/subdir/ignored2
  $ echo 'ignored2' > dir2/.hgignore
  $ echo 'subinclude:dir2/.hgignore' >> .hgignore
  $ echo 'subinclude:dir1/.hgignore' >> .hgignore

  $ hg commit -Aqm_

  $ > dir1/.hgignore
  $ echo 'ignored' > dir2/.hgignore
  $ echo 'ignored1' >> dir2/.hgignore
  $ hg status
  M dir1/.hgignore
  M dir2/.hgignore
  ? dir1/subdir/ignored1

#endif
