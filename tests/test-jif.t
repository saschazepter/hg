====================
Basic jif testing
====================

#require jif

Test behavior of repo command outside a repo
  $ jf status
  abort: no repository found in $TESTTMP
  [255]

Get a small repo

  $ hg init repo
  $ cd repo

Test some status output

  $ echo foo > foo
  $ jf status
  ? foo

  $ hg add foo
  $ jf status
  A foo

  $ hg commit -m 'foo'
  $ echo bar > bar
  $ jf status
  ? bar

  $ hg add bar
  $ jf status
  A bar

  $ echo fuz > foo
  $ jf status
  A bar
  M foo

  $ hg commit -m 'fuz'
  $ hg remove foo
  $ jf st
  R foo

Test copies, and output for machines

  $ hg copy bar baz
  $ jf status
  R foo
  A baz
    bar
  $ jf status --do-not-use-format json
  {"_internal_jf_kind":"status","path":"foo","status":"R"}
  {"_internal_jf_kind":"status","copy_source":"bar","path":"baz","status":"A"}
