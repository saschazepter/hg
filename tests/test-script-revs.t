========================================
Testing of the `hg script::revs` command
========================================

Initial setup
=============

  $ hg init cmdtest
  $ cd cmdtest
  $ hg debugbuilddag .+10


Basic expression
================

Simple successful

  $ hg script::revs 0
  1ea73414a91b0920940797d8fc6a11e447f8ea1e
  $ hg script::revs -e 0
  $ hg script::revs --exists 0
  $ hg script::revs -e 0 -T "{rev}\n"
  0

Simple empty revset

  $ hg script::revs "(0 and 1)"
  $ hg script::revs --exists "(0 and 1)"
  [2]
  $ hg script::revs --no-exists "(0 and 1)"

  $ hg script::revs --no-exists "(0 and 1)" -T 'whatever'

Simple invalid revset

  $ hg script::revs "(0"
  hg: parse error at 2: unexpected token: end
  ((0
     ^ here)
  [10]
