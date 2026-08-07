====================
Basic jif testing
====================

#require jif


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
