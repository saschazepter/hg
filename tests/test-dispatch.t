test command parsing and dispatch

  $ hg init a
  $ cd a

Redundant options used to crash (issue436):
  $ hg -v log -v
  $ hg -v log -v x

  $ echo a > a
  $ hg ci -Ama
  adding a

Missing arg:

  $ hg cat
  hg cat: invalid arguments
  hg cat [OPTION]... FILE...
  
  output the current or given revision of files
  
  options ([+] can be repeated):
  
   -o --output FORMAT       print output to file with formatted name
   -r --rev REV             print the given revision
      --decode              apply any matching decode filter
   -I --include PATTERN [+] include names matching the given patterns
   -X --exclude PATTERN [+] exclude names matching the given patterns
   -T --template TEMPLATE   display with template
  
  (use 'hg cat -h' to show more help)
  [10]

Missing parameter for early option:

  $ hg log -R 2>&1 | grep 'hg log'
  hg log: option -R requires argument
  hg log [OPTION]... [FILE]
  (use 'hg log -h' to show more help)

"--" may be an option value:

  $ hg -R -- log
  abort: repository -- not found
  [255]
  $ hg log -R --
  abort: repository -- not found
  [255]
  $ hg log -T --
  -- (no-eol)
  $ hg log -T -- -k nomatch

Parsing of early options should stop at "--":

  $ hg cat -- --config=hooks.pre-cat=false
  --config=hooks.pre-cat=false: no such file in rev cb9a9f314b8b
  [1]
  $ hg cat -- --debugger
  --debugger: no such file in rev cb9a9f314b8b
  [1]

Unparsable form of early options:

  $ hg cat --debugg
  abort: option --debugger may not be abbreviated
  [10]

Parsing failure of early options should be detected before executing the
command:

  $ hg log -b '--config=hooks.pre-log=false' default
  abort: option --config may not be abbreviated
  [10]
  $ hg log -b -R. default
  abort: option -R has to be separated from other options (e.g. not -qR) and --repository may only be abbreviated as --repo
  [10]
  $ hg log --cwd .. -b --cwd=. default
  abort: option --cwd may not be abbreviated
  [10]

However, we can't prevent it from loading extensions and configs:

  $ cat <<EOF > bad.py
  > raise Exception('bad')
  > EOF
  $ hg log -b '--config=extensions.bad=bad.py' default
  *** failed to import extension "bad" from bad.py: bad
  abort: option --config may not be abbreviated
  [10]

  $ mkdir -p badrepo/.hg
  $ echo 'invalid-syntax' > badrepo/.hg/hgrc
  $ hg log -b -Rbadrepo default
  config error at badrepo/.hg/hgrc:1: invalid-syntax
  [30]

  $ hg log -b --cwd=inexistent default
  abort: $ENOENT$: 'inexistent'
  [255]

  $ hg log -b '--config=ui.traceback=yes' 2>&1 | grep '^Traceback'
  Traceback (most recent call last):
  $ hg log -b '--config=profiling.enabled=yes' 2>&1 | grep -i sample
  Sample count: .*|No samples recorded\. (re)

Early options can't be specified in [aliases] and [defaults] because they are
applied before the command name is resolved:

  $ hg log -b '--config=alias.log=log --config=hooks.pre-log=false'
  hg log: option -b not recognized
  error in definition for alias 'log': --config may only be given on the command
  line
  [10]

  $ hg log -b '--config=defaults.log=--config=hooks.pre-log=false'
  abort: option --config may not be abbreviated
  [10]

Shell aliases bypass any command parsing rules but for the early one:

  $ hg log -b '--config=alias.log=!echo howdy'
  howdy

Early options must come first if HGPLAIN=+strictflags is specified:
(BUG: chg cherry-picks early options to pass them as a server command)

#if no-chg
  $ HGPLAIN=+strictflags hg log -b --config='hooks.pre-log=false' default
  abort: unknown revision '--config=hooks.pre-log=false'
  [10]
  $ HGPLAIN=+strictflags hg log -b -R. default
  abort: unknown revision '-R.'
  [10]
  $ HGPLAIN=+strictflags hg log -b --cwd=. default
  abort: unknown revision '--cwd=.'
  [10]
#endif
  $ HGPLAIN=+strictflags hg log -b --debugger default
  abort: unknown revision '--debugger'
  [10]
  $ HGPLAIN=+strictflags hg log -b --config='alias.log=!echo pwned' default
  abort: unknown revision '--config=alias.log=!echo pwned'
  [10]

  $ HGPLAIN=+strictflags hg log --config='hooks.pre-log=false' -b default
  abort: option --config may not be abbreviated
  [10]
  $ HGPLAIN=+strictflags hg log -q --cwd=.. -b default
  abort: option --cwd may not be abbreviated
  [10]
  $ HGPLAIN=+strictflags hg log -q -R . -b default
  abort: option -R has to be separated from other options (e.g. not -qR) and --repository may only be abbreviated as --repo
  [10]

  $ HGPLAIN=+strictflags hg --config='hooks.pre-log=false' log -b default
  abort: pre-log hook exited with status 1
  [40]
  $ HGPLAIN=+strictflags hg --cwd .. -q -Ra log -b default
  0:cb9a9f314b8b
  $ HGPLAIN=+strictflags hg --cwd .. -q --repository a log -b default
  0:cb9a9f314b8b
  $ HGPLAIN=+strictflags hg --cwd .. -q --repo a log -b default
  0:cb9a9f314b8b

For compatibility reasons, HGPLAIN=+strictflags is not enabled by plain HGPLAIN:

  $ HGPLAIN= hg log --config='hooks.pre-log=false' -b default
  abort: pre-log hook exited with status 1
  [40]
  $ HGPLAINEXCEPT= hg log --cwd .. -q -Ra -b default
  0:cb9a9f314b8b

[defaults]

  $ hg cat a
  a
  $ cat >> $HGRCPATH <<EOF
  > [defaults]
  > cat = -r null
  > EOF
  $ hg cat a
  a: no such file in rev 000000000000
  [1]

  $ cd "$TESTTMP"

OSError "No such file or directory" / "The system cannot find the path
specified" should include filename even when it is empty

  $ hg -R a archive ''
  abort: $ENOENT$: '' (no-windows !)
  abort: $ENOTDIR$: '' (windows !)
  [255]

#if no-outer-repo

No repo:

  $ hg cat
  abort: no repository found in '$TESTTMP' (.hg not found)
  [10]

#endif

#if rmcwd

Current directory removed:

  $ mkdir $TESTTMP/repo1
  $ cd $TESTTMP/repo1
  $ rm -rf $TESTTMP/repo1

The output could be one of the following and something else:
 chg: abort: failed to getcwd (errno = *) (glob)
 abort: error getting current working directory: * (glob)
 sh: 0: getcwd() failed: $ENOENT$
Since the exact behavior depends on the shell, only check it returns non-zero.
  $ HGDEMANDIMPORT=disable hg version -q 2>/dev/null || false
  [1]

#endif
