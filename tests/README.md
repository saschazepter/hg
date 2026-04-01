# Running and Writing Tests

Mercurial contains a simple regression test framework that allows both Python
unit tests and shell-script driven regression tests.

## Running the test suite

To run the tests, do:

    $ make tests
    cd tests && ./run-tests.py -j8
    ............................................
    Ran 44 tests, 0 failed.

This finds all scripts in the tests/ directory named test-* and executes them 8
at a time. The scripts can be either unified tests, shell scripts, or Python.
Each test is run in a temporary directory that is removed when the test is
complete.

You can also run tests individually:

    $ cd tests/
    $ ./run-tests.py test-pull.t test-undo.t
    ..
    Ran 2 tests, 0 failed.

A test-<x> succeeds if the script returns success and its output matches
test-<x>.out. If the new output doesn't match, it is stored in test-<x>.err.

Also, 'run-tests.py' has some useful options:

* -i: interactively accept test changes
* -r: rerun tests with errors
* -f: exit on first failure
* -R: restart after last error
* -j: run multiple threads
* -l: skip building a private hg install
* --view: view output differences with an external tool

See 'run-tests.py -h' for a full list.

One option that comes in handy when running tests repeatedly is '--local'. By
default, 'run-tests.py' installs Mercurial into its temporary directory for each
run of the test suite. You can save several seconds per run with '--local',
which tells 'run-tests.py' simply to use the local 'hg' script and library. The
catch: if you edit the code during a long test suite run, different tests will
run with different code. It's best to use '--local' when you are running the
same test script many times, as often happens during development.

## Writing a shell script test

### Be careful with new test scripts!

The test suite is slow. And the test suite is slow because it is highly
redundant. And it is highly redundant because for years we've been writing a
completely new test for each issue that creates a new repo, adds a file, runs
status, commits, does a merge, etc.

If we add a one-second test for each bug fix that shows up, very soon we'll have
a test suite that takes an hour to run and thus is no longer useful to anyone.

Therefore, if you want to add testing for a feature, you must either:

* add a short, fast doctest (where appropriate)
* fold your test into an appropriate existing test

When doing the latter, you should try to take advantage of work the test suite
is already doing. For instance, if you're testing whether uppercase keywords
work correctly, please adjust one of the many existing tests that uses a keyword
to use an uppercase one.

If you are adding a small tests for a bugfix/improvement to an existing feature
please add it to an existing test file related to this feature. Only fallback to
new test file when you are opening a significant new feature space and you know
that the test file will gather significant content over time.

Patches that add completely new test file for a trivial case will likely be
rejected.

### Basic example

Creating a regression test is easy. Simply create a *.t file which contains
shell script commands prepended with '  $ '. Lines not starting with two spaces
are comments.

Here's an example (test-x.t):

    File replaced with directory:
    
      $ hg init a
      $ cd a
      $ echo a > a
      $ hg commit -Ama
      $ rm a
      $ mkdir a
      $ echo a > a/a
    
    Should fail - would corrupt dirstate:
    
      $ hg add a/a

Then run this test for the first time:

    $ python run-tests.py -i test-x.t

    ERROR: /home/adi/hgrepos/hg-crew/tests/test-x.t output changed
    --- /home/adi/hgrepos/hg-crew/tests/test-x.t
    +++ /home/adi/hgrepos/hg-crew/tests/test-x.t.err
    @@ -4,6 +4,7 @@
       $ cd a
       $ echo a > a
       $ hg commit -Ama
    +  adding a
       $ rm a
       $ mkdir a
       $ echo a > a/a
    @@ -11,4 +12,6 @@
     Should fail - would corrupt dirstate:
    
       $ hg add a/a
    +  abort: file 'a' in dirstate clashes with 'a/a'
    +  [255]

    !Accept this change? [n]

Check the output of the commands inserted into your test file and accept the
modified test file with 'y'.

The test file now includes both command input interspersed with command output:

File replaced with directory:

      $ hg init a
      $ cd a
      $ echo a > a
      $ hg commit -Ama
      adding a
      $ rm a
      $ mkdir a
      $ echo a > a/a

Should fail - would corrupt dirstate:

      $ hg add a/a
      abort: file 'a' in dirstate clashes with 'a/a'
      [255]

Note how nonzero return values show up enclosed in squared brackets ("[255]" for
"hg add a/a").

Running this test again will now pass

    $ python run-tests.py test-x.t -i
    .
    # Ran 1 tests, 0 skipped, 0 failed.

This kind of test is also known as "unified test" (because it unifies input and
output into the same file).

### Filtering output

Such tests must be repeatable, that is, output generated by commands must not
contain strings that change for each invocation (like the path of a temporary
file).

To cope with this kind of variation, unified tests support filtering using
(glob) or (re).

To enable glob filtering for an output line, append " (glob)" to the respective
line like in the following example:

    test version
      $ hg version -q
      Mercurial Distributed SCM (version *) (glob)

(glob) filtering supports * for matching a string and ? for matching a single
character. Example:

    test diff
      $ hg diff
      diff -r ???????????? orphanchild (glob)
      --- /dev/null
      +++ b/orphanchild
      @@ -0,0 +1,1 @@
      +orphan

Literal * or ? on (glob) lines must be escaped with \ (backslash).

To use regular expression filtering on a line, append " (re)" to the output
line:

    test version
       $ hg version -q
       Mercurial Distributed SCM \(version .*\) (re)

Entire lines can be marked optional with " (?)":

    test status
       $ hg status
       A new/test/file.txt
       M random/logs/garbage.log (?)

### Inline Python

It is possible to add snippets of Python into tests where convenient:

Create a files with various characters:

    >>> a = open('a', 'wb')
    >>> for x in xrange(256):
    ...   a.write(ord(x))
    $ hg add a

### Format summary

The format in a nutshell

* Unified tests use the .t file extension.
* Lines beginning with two spaces, a dollar sign, and a space are run in the
  shell.
* Lines beginning with two spaces, a greater than sign, and a space allow
  multi-line commands.
* Lines beginning with ' >>>' are Python code.
* All other lines beginning with two spaces are considered command output.
* Output lines ending with a space and the keyword (re) are matched as
  Perl-compatible regular expressions.
* Output lines ending with a space and the keyword (glob) are matched with a
  glob-like syntax. The only special characters supported are "*" and "?". Both
  characters can be escaped using "\", and the backslash can be escaped itself.
* Output lines ending with either of the above keywords are always first matched
  literally with actual command output.
* Output lines ending with a space and the keyword (?) are considered optional.
  This keyword may be combined with (glob) or (re) noted above.

Anything else is a comment.

### Documenting tests

Commenting your tests is at least as important as commenting code. You should
add documentation to ensure that:

* The behavior that the test intends to test is clear.
* Any part of the setup important to test that behavior is highlighted.
* Which behavior is intentionally tested and enforced.
* Boundaries between individual test cases are clearly identified.
* A test file should document what it intends on covering.

Documenting a test is done using a reStructuredText like syntax. Example
`test-foo-bar.t` content:

    ===============================
    Testing Foo and Bar interaction
    ===============================

    This file gathers test cases that check how the Foo feature interacts with
    operations related to Bar.

    Setup
    =====

      $ cat << EOF >> $HGRCPATH
      > [bar]
      > some-config = "babar"
      > EOF

    […]

    Testing read-only operations
    ============================

    Reading an empty Foo
    --------------------

    Operating on a blue Bar without a Foo

      $ …

    Output should remain empty

      $ hg foo --rev bar-blu […]


    Reading a simple Foo
    --------------------

    […]

    Testing read-write operations
    =============================

    […]


### Making tests repeatable

There are some tricky points here that you should be aware of when writing
tests:

* hg commit wants user interaction - use -m "text"
* hg up -m wants user interaction, set HGMERGE to something noninteractive:

      #!/bin/sh
      cat <<EOF > merge
      echo merging for `basename $1`
      EOF
      chmod +x merge
      env HGMERGE=./merge hg update -m 1

### Making tests portable

{i} Most of these issues are caught by 'contrib/check-code.py'

You also need to be careful that the tests are portable from one platform to
another. You're probably working on Linux, where the GNU toolchain has more (or
different) functionality than on MacOS, *BSD, Solaris, AIX, etc. While testing
on all platforms is the only sure-fire way to make sure that you've written
portable code, here's a list of problems that have been found and fixed in the
tests. Another, more comprehensive list may be found in the GNU Autoconf manual.

#### sh

The Bourne shell is a very basic shell. On Linux, /bin/sh is typically bash,
which even in Bourne-shell mode has many features that Bourne shells on other
Unix systems don't have. (Note however that on Linux /bin/sh isn't guaranteed to
be bash; in particular, on Ubuntu, /bin/sh is dash, a small Posix-compliant
shell that lacks many bash features). You'll need to be careful about constructs
that seem ubiquitous, but are actually not available in the least common
denominator. While using another shell (ksh, bash explicitly, posix shell, etc.)
explicitly may seem like another option, these may not exist in a portable
location, and so are generally probably not a good idea. You may find that
rewriting the test in python will be easier.

* don't use pushd/popd; save the output of "pwd" and use "cd" in place of the
  pushd, and cd back to the saved pwd instead of popd.
* don't use math expressions like let, (( ... )), or $(( ... )); use "expr"
  instead.
* don't use $(...) command substitution; use `...` instead.
* don't use $PWD; use `pwd` instead.
* don't use $RANDOM; either use inline python or don't rely on random values at
  all.
* don't use the "function" keyword to define functions; use the old-style form
  instead:

      # DON'T USE THIS
      function foo {
         ...
      }
      
      # USE THIS INSTEAD
      foo () {
         ...
      }
* don't use "source" to load another script; use "." instead.

#### grep

* don't use the -q option; redirect stdout to /dev/null instead.
* don't use the -a option; use inline python (-a is not on Solaris).
* don't use extended regular expressions with grep; use egrep instead, and don't
  escape any regex operators.
* don't use \S in regular expressions (BSD egrep does not like it).
* don't use context flags -A, -B or -C (they're not on Solaris).

#### sed

* try to use test globs and regexes instead
* make sure that the beginning-of-line matcher ("^") is at the very beginning of
  the expression -- it may not be supported inside parens.
* don't use the -i option; instead, redirect to a file:

       sed -e 's/foo/bar/' a > a.new
       mv a.new a

* "i" (and maybe some other functions) requires back-slash ("\\") and new-lines
  on both side of text to insert line on some platforms(e.g.: Mac OS X and
  recent Solaris, at least) without GNU sed

      # insert new "foo bar" line before existing 2nd line in target
        $ sed -e '2i\
        > foo bar
        > ' target
        $

#### echo

* echo may interpret "\n" and print a newline; use printf instead if you want a
  literal "\n" (backslash + n).

#### false

* false is guaranteed only to return a non-zero value; you cannot depend on it
  being 1. On Solaris in particular, /bin/false returns 255. Rewrite your test
  to not depend on a particular return value, or create a temporary "false"
  executable, and call that instead.

#### diff

* don't use the -N option. There's no particularly good workaround short of
  writing a reasonably complicated replacement script, but substituting gdiff
  for diff if you can't rewrite the test not to need -N will probably do.
* before using the -u or -U option compare files with cmp (on Solaris diff -u/-U
  isn't silent when the files are identical).

#### wc

* don't use it, or else eliminate leading whitespace from the output with test
  globs

#### head

* don't use the -c option (not part of SUSv3, not supported on OpenBSD).
  Instead, use dd. the following are equivalent; the latter is preferred:

        head -c 20 foo > bar

        dd if=foo of=bar bs=1 count=20 2>/dev/null

#### ls

* don't use the -R option. Instead, use find(1).
* make sure options are put before file names.

#### tr

* don't use ranges like tr a-z A-Z . Classes like tr [:lower:] [:upper:] can be
  used instead.

### A naming scheme for test elements

Rather than use an ad-hoc mix of names like foo, bar, baz for generic names in
tests, consider the following scheme when writing new test cases:

* 0, 1, 2, 3... for commit messages (each commit message matches its expected
  revision)
* f1, f2, f3... for generic filenames
* c1, c2, c3... for generic file contents (easily identifiable in the output)
* d1, d2, d3... for generic directory names
* r for repos, t for tags, b for branches, u for users, and so on

If you've only got one directory, one file, etc. in your test, you can drop the
'1'.

## Writing a Python unit test

A unit test operates much like a regression test, but is written in Python.
Here's an example:

    #test-foo.py
     1 #!/usr/bin/env python
     2 
     3 import sys
     4 from mercurial import bdiff, mpatch
     5 
     6 def test1(a, b):
     7     d = bdiff.bdiff(a, b)
     8     c = a
     9     if d:
    10         c = mpatch.patches(a, [d])
    11     if c != b:
    12         print "***", `a`, `b`
    13         print "bad:"
    14         print `c`[:200]
    15         print `d`
    16 
    17 def test(a, b):
    18     print "***", `a`, `b`
    19     test1(a, b)
    20     test1(b, a)
    21 
    22 test("a\nc\n\n\n\n", "a\nb\n\n\n")
    23 test("a\nb\nc\n", "a\nc\n")
    24 test("", "")
    25 test("a\nb\nc", "a\nb\nc")
    26 test("a\nb\nc\nd\n", "a\nd\n")
    27 test("a\nb\nc\nd\n", "a\nc\ne\n")
    28 test("a\nb\nc\n", "a\nc\n")
    29 test("a\n", "c\na\nb\n")
    30 test("a\n", "")
    31 test("a\n", "b\nc\n")
    32 test("a\n", "c\na\n")
    33 test("", "adjfkjdjksdhfksj")
    34 test("", "ab")
    35 test("", "abc")
    36 test("a", "a")
    37 test("ab", "ab")
    38 test("abc", "abc")
    39 test("a\n", "a\n")
    40 test("a\nb", "a\nb")
    41 
    42 print "done"

It is also possible to write a 'pure' unit test (one that doesn't have a
corresponding .out file). The only thing that is needed in addition to the usual
guidelines for writing Python unit tests is this snippet at the end:

    import silenttestrunner
    ...
    if __name__ == '__main__':
        silenttestrunner.main(__name__)

## Writing a Python doctest

The Mercurial test suite also supports running Python doctests from the
docstrings in the source code. This can be useful for testing simple functions
which don't work on complex data or repositories. Here's an example test from
mercurial/changelog.py:

    def _string_escape(text):
        """
        >>> d = {'nl': chr(10), 'bs': chr(92), 'cr': chr(13), 'nul': chr(0)}
        >>> s = "ab%(nl)scd%(bs)s%(bs)sn%(nul)sab%(cr)scd%(bs)s%(nl)s" % d
        >>> s
        'ab\\ncd\\\\\\\\n\\x00ab\\rcd\\\\\\n'
        >>> res = _string_escape(s)
        >>> s == res.decode('string_escape')
        True
        """
        # subset of the string_escape codec
        text = text.replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r')
        return text.replace('\0', '\\0')

This tests is run by tests/test-docstring.py, which contains a list of modules
to search for docstring tests in.
