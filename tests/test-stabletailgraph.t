====================================
Test for the stabletailgraph package
====================================

This test file contains a bunch of small test graphs with some minimal yet
non-trivial structure, on which the various stable-tail graph and stable-tail
sort functions are tested.

Each case consists of the creation of the interesting graph structure, followed
by a check, for each noteworthy node, of:
- the stable-tail sort output (with the linear parts globbed),
- the leap set,
- the specific leap set.

In the ASCII art of the diagrams, the side of the exclusive part which is
followed in priority is denoted with "<" or ">" if it is on the left or right
respectively.

The intermediary linear parts in the example graph are there to force the
exclusive part choice (made on a min rank condition).


Setup
=====

Enable the rank computation to test sorting based on the rank.

  $ cat << EOF >> $HGRCPATH
  > [format]
  > exp-use-changelog-v2=enable-unstable-format-and-corrupt-my-data
  > 
  > [alias]
  > test-sts = debug::stable-tail-sort -T '{tags},'
  > test-leaps = debug::stable-tail-sort-leaps -T '{tags}'
  > test-log = log --graph -T '{tags} rank={_fast_rank}' --rev 'tagged()'
  > EOF


Example 1: single merge node
============================

A base case with one branchpoint "b" and one merge node "e".

The exclusive part, starting with the lowest-ranking parent "c" of "e",
appears first in stable-tail sort of "e" and "f".

#        f
#        |
#        e
#        |
#      --<--
#      |   |
#      c   d
#      |   |
#      --+--      <- at this point, the sort of "e" is done consuming its
#        |           exclusive part [c] and jumps back to its other parent "d"
#        b
#        |
#        a

  $ hg init example-1
  $ cd example-1
  $ hg debugbuilddag '.:a*a:b*b:c<b+2:d*c/d:e*e:f.'
  $ hg test-log
  o  f rank=7
  |
  o    e rank=6
  |\
  | o  d rank=4
  | :
  o :  c rank=3
  :/
  o  b rank=2
  |
  o  a rank=1
  

Check the sort of the base linear case.

  $ hg test-sts c
  c,b,a, (no-eol)

Check the stable-tail sort of "e": "c" should come before "d".

  $ hg test-sts e
  e,c,d,*,b,a, (no-eol) (glob)

Check that the linear descendant of the merge inherits its sort properly.

  $ hg test-sts f
  f,e,c,d,*,b,a, (no-eol) (glob)

Check the leaps of "e": arriving at "c", the sort continues at "d", which
which breaks the child-parent chain and results in a leap.

  $ hg test-leaps e
  cd

Check that this leap is indeed specific to "e", i.e. that it appears in its
stable-tail sort, but not in any stable-tail sort of its ancestors.

  $ hg test-leaps --specific e

Check that this leap is inherited by its direct ancestor "f".

  $ hg test-leaps f
  cd

Check that this leap is not classified as specific to "f", since it is specific
to "e".

  $ hg test-leaps --specific f

  $ cd ..


Example 2: nested exclusive parts, without specific leap
========================================================

"g" is a merge node whose exclusive part contains a merge node "e".
We check that the stable-tail sort recurses properly by delegating.

Notice that parts of the sort of "e" is an infix of the sort of "g".
This is an expected property of the sort.

#           g
#           |
#        ---<---
#        |     |
#        e     |    <- while processing the sort in the exclusive part of "g"
#        |     |       we recursively process the exclusive part of "e"
#      --<--   f
#      |   |   |
#      c   d   |
#      |   |   |
#      --+--   |
#        |     |
#        b     |
#        |     |
#        ---+---    <- done with excl(g), jump to "f"
#           |
#           a

  $ hg init example-2
  $ cd example-2
  $ hg debugbuilddag '.:a*a:b*b:c<b+2:d*c/d:e<a+6:f*e/f:g.'
  $ hg test-log
  o    g rank=13
  |\
  | o  f rank=7
  | :
  o :    e rank=6
  |\ \
  | o :  d rank=4
  | : :
  o : :  c rank=3
  :/ /
  o /  b rank=2
  :/
  o  a rank=1
  
Display the sort of "e" for reference

  $ hg test-sts e
  e,c,d,*,b,a, (no-eol) (glob)

Check the correctness of the sort of "g",
and that a part of the sort of "e" appears as an infix.

  $ hg test-sts g
  g,e,c,d,*,b,f,*,a, (no-eol) (glob)

Check the leaps of "e".

  $ hg test-leaps e
  cd

  $ hg test-leaps --specific e

Check that "g" inherits a leap from "e" in addition of its own.

  $ hg test-leaps g
  cd
  bf

Check that only the additional leap of "g" is classified as specific.

  $ hg test-leaps --specific g

  $ cd ..


Example 3: shadowing of a final leap
====================================

We have a merge "f" whose exclusive part contains a merge "d".

The inherited parent of "d" is not in the exclusive part of "f".
At the end of the exclusive part of "d",
the leap to "c" is shadowed by the leap to "e", i.e. the inherited part to "f".

Notice that emitting "c" before "e" would break the reverse topological
ordering.

#           f
#           |
#        ---<---
#        |     |
#        d     |
#        |     e
#      --<--   |
#      |   |   |
#      |   +----
#      b   |
#      |   c
#      |   |
#      --+--       <- at this point, jumping to "e", not the shadowed "c"
#        |
#        a

  $ hg init example-3
  $ cd example-3
  $ hg debugbuilddag '.:a*a:b<a+2:c*b/c:d<c+3:e*d/e:f.'
  $ hg test-log
  o    f rank=9
  |\
  | o  e rank=6
  | :
  o :  d rank=5
  |\:
  | o  c rank=3
  | :
  o :  b rank=2
  :/
  o  a rank=1
  

Display the sort of "d" for reference:

  $ hg test-sts d
  d,b,c,*,a, (no-eol) (glob)

Check that we leap from "b" directly to "e" (shadowing the leap to "c"),
and that "c" is then emitted after "e" (its descendant).

  $ hg test-sts f
  f,d,b,e,*,c,*,a, (no-eol) (glob)

Check the leaps of "d".

  $ hg test-leaps d
  bc

  $ hg test-leaps --specific d

Check thet leaps of "f", which, despite being a descendant of "f", has a
different stable-tail sort which does not reuse any leap of "d".

  $ hg test-leaps f
  be

  $ hg test-leaps --specific f

  $ cd ..


Example 4: skipping over nested exclusive part (entirely)
=========================================================

We have a merge "f" whose exclusive part contains a merge "d".

The exclusive part of "d" is not in the exclusive part of "f".
However, some of the inherited part of "d" is part of the exclusive part of "f"
and needs to be iterated over before leaping to the inherited part of "f".

The sort of "d" is partially reused for the ordering of the exclusive part of
"f". However the reused part is not contiguous in the sort of "d".

#           f
#           |
#        ---<---
#        |     |
#        d     |
#        |     e
#      -->--   |    <- in the sort of "f", we need to skip "c" and leap to the
#      |   |   |       inherited part of "d"
#      |   +----
#      b   |
#      |   c
#      |   |
#      --+--
#        |
#        a

  $ hg init example-4
  $ cd example-4
  $ hg debugbuilddag '.:a*a+1:b<a+1:c*b/c:d<c+4:e*d/e:f.'
  $ hg test-log
  o    f rank=10
  |\
  | o  e rank=6
  | :
  o :  d rank=5
  |\:
  | o  c rank=2
  | |
  o |  b rank=3
  |/
  o  a rank=1
  

Display the sort of "d" for reference:

  $ hg test-sts d
  d,c,b,*,a, (no-eol) (glob)

Check that sort "f" leaps from "d" to "b":

  $ hg test-sts f
  f,d,b,*,e,*,c,a, (no-eol) (glob)

Check the leaps of "d".

  $ hg test-leaps d
  cb

  $ hg test-leaps --specific d

Check the leaps of "f".

  $ hg test-leaps f
  db
  e* (glob)

  $ hg test-leaps --specific f
  db

  $ cd ..


Example 5: skipping over nested exclusive part (partially)
==========================================================

We have a merge "f" whose exclusive part contains a merge "d".

Similar to example 4, but the exclusive part of "d" is only partially
contained in the inherited part of "f".
So, we need to leap in the middle of the exclusive part of "d".

#           f
#           |
#        ---<---
#        |     |
#        d     |
#        |     e
#      -->--   |
#      |   |   |
#      |   g   |
#      |   |   |
#      |   +----    <- in the sort of "f", leaping from "g" to "b"
#      b   |
#      |   c
#      |   |
#      --+--
#        |
#        a

  $ hg init example-5
  $ cd example-5
  $ hg debugbuilddag '.:a*a+2:b<a+1:c+1:g*b/g:d<c+6:e*d/e:f.'
  $ hg test-log
  o    f rank=14
  |\
  | o  e rank=8
  | :
  o :    d rank=7
  |\ \
  | o :  g rank=3
  | :/
  | o  c rank=2
  | |
  o |  b rank=4
  |/
  o  a rank=1
  

Display the sort of "d" for reference:

  $ hg test-sts d
  d,g,c,b,*,a, (no-eol) (glob)

Check that sort "f" leaps from "g" to "b":

  $ hg test-sts f
  f,d,g,b,*,e,*,c,a, (no-eol) (glob)

Check the leaps of "d".

  $ hg test-leaps d
  cb
  $ hg test-leaps --specific d

Check the leaps of "f".

  $ hg test-leaps f
  gb
  e* (glob)

  $ hg test-leaps --specific f
  gb

  $ cd ..


Example 6: merge in the inherited part
======================================

Variant of example 2, but with a merge ("f") in the inherited part of "g".

"g" is a merge node whose inherited part contains a merge node "f".
We check that the stable-tail sort delegates properly after the exclusive part.

#         g
#         |
#      ---<---
#      |     |
#      d     f
#      |     |
#      |  ---<---
#      |  |     |
#      |  e     c
#      |  |     |
#      ---+     |    <- at this point, we're done (for good) with the exclusive
#         |     |       part of "g"
#         b     |
#         |     |
#         ---+---
#            |
#            a

  $ hg init example-6
  $ cd example-6
  $ hg debugbuilddag '.:a*a:b<a+3:c*b:d*b:e*e/c:f*d/f:g.'
  $ hg test-log
  o    g rank=9
  |\
  | o    f rank=7
  | |\
  | | o  e rank=3
  | | |
  o---+  d rank=3
   / /
  o |  c rank=4
  : |
  : o  b rank=2
  :/
  o  a rank=1
  

Display the sort of "f" for reference:

  $ hg test-sts f
  f,e,b,c,*,a, (no-eol) (glob)

Check that the sort of "g" delegates to the sort of "f" after processing its
exclusive part of "g":

  $ hg test-sts g
  g,d,f,e,b,c,*,a, (no-eol) (glob)

Check the leaps of "f".

  $ hg test-leaps f
  bc

  $ hg test-leaps --specific f

Check the leaps of "g".

  $ hg test-leaps g
  df
  bc

  $ hg test-leaps --specific g

  $ cd ..


Example 7: postponed iteration of common exclusive ancestors
============================================================

Sibling merges "j" and "k", with partially shared exclusive parts.

When considering the sort of "l", the iteration over this shared part cannot
happen when iterating over excl(j) and has to be postponed to excl(k).

#            l
#            |
#        ----<----
#        |       |
#        j       k
#        |       |
#      -->--   --<--
#      |   |   |   |
#      g   e   h   i
#      |   |   |   |
#      |   --+--   |   <- at this point, for the sort of "l", the iteration on
#      f     |     |      the end of excl(j) is postponed to the iteration of
#      |     d     |      excl(k)
#      |     |     |
#      |     c     |
#      |     |     |
#      ---+---     |
#         |        |
#         b        |
#         |        |
#         ----+-----
#             |
#             a

  $ hg init example-7
  $ cd example-7
  $ hg debugbuilddag \
  > '.:a*a:b*b:c*c:d*d:e*b:f<f+3:g<d+2:h<a+6:i*e/g:j*h/i:k*j/k:l.'
  $ hg test-log
  o    l rank=20
  |\
  | o    k rank=13
  | |\
  o \ \    j rank=10
  |\ \ \
  | | | o  i rank=7
  | | | :
  | | o :  h rank=6
  | | : :
  | o : :  g rank=6
  | : : :
  | o : :  f rank=3
  | | : :
  o---+ :  e rank=5
   / / /
  | o :  d rank=4
  | | :
  | o :  c rank=3
  |/ /
  o /  b rank=2
  :/
  o  a rank=1
  

Display the sort of "j" for reference:

  $ hg test-sts j
  j,e,d,c,g,*,f,b,a, (no-eol) (glob)

Display the sort of "k" for reference:

  $ hg test-sts k
  k,h,*,d,c,b,i,*,a, (no-eol) (glob)

Check that the common part of excl(j) and excl(k) is iterated over after "k":

  $ hg test-sts l
  l,j,e,g,*,f,k,h,*,d,c,b,i,*,a, (no-eol) (glob)

Check the leaps of "j".

  $ hg test-leaps j
  cg

  $ hg test-leaps --specific j

Check the leaps of "k".

  $ hg test-leaps k
  bi

  $ hg test-leaps --specific k

Check the leaps of "l".

  $ hg test-leaps l
  eg
  fk
  bi

  $ hg test-leaps --specific l
  eg

  $ cd ..


Example 8: postponed iteration of common ancestors between parts
================================================================

Sibling merges "g" and "i", with some part shared between the inherited part
of "g" and the exclusive part of "i".

When considering the sort of "j", the iteration over this shared part cannot
happen when iterating over inherited(g) and has to be postponed to excl(i).

#            j
#            |
#        ----<----
#        |       |
#        g       i
#        |       |
#      --<--   --<--
#      |   |   |   |
#      c   f   |   h
#      |   |   |   |
#      |   --+--   |   <- at this point, for the sort of "j", the iteration
#      |     |     |      on the end of inherited(g) is postponed to the
#      |     e     |      iteration of excl(k)
#      |     |     |
#      ---+---     |
#         b        |
#         |        |
#         ----+-----
#             |
#             a

  $ hg init example-8
  $ cd example-8
  $ hg debugbuilddag '.:a*a:b*b:c*b:d*d:e*e:f*c/f:g<a+5:h*e/h:i*g/i:j.'
  $ hg test-log
  o    j rank=14
  |\
  | o    i rank=10
  | |\
  | | o  h rank=6
  | | :
  o | :    g rank=7
  |\ \ \
  | o | :  f rank=5
  | |/ /
  | o :  e rank=4
  | | :
  | o :  d rank=3
  | | :
  o | :  c rank=3
  |/ /
  o /  b rank=2
  :/
  o  a rank=1
  

Display the sort of "g" for reference:

  $ hg test-sts g
  g,c,f,e,d,b,a, (no-eol)

Display the sort of "i" for reference:

  $ hg test-sts i
  i,e,d,b,h,*,a, (no-eol) (glob)

Check that the common part of inherited(g) and excl(k) is iterated over after
"i":

  $ hg test-sts j
  j,g,c,f,i,e,d,b,h,*,a, (no-eol) (glob)

Check the leaps of "g".

  $ hg test-leaps g
  cf
  $ hg test-leaps g
  cf

Check the leaps of "i".

  $ hg test-leaps i
  bh

  $ hg test-leaps --specific i

Check the leaps of "j".

  $ hg test-leaps j
  cf
  fi
  bh

  $ hg test-leaps --specific j

  $ cd ..


Example 9: postponed iteration of common ancestors between both parts
=====================================================================

This is a combination of example 7 and 8 at the same time.
Both excl(i) and excl(j) share a common part.
Same with inherited(i) and inherited(j).

We test that the walk on the common ancestors in both cases is properly
postponed when considering sort(k).

#            k
#            |
#        ----<----
#        |       |
#        i       j
#        |       |
#      --<--   --<--
#      |   |   |   |
#      c   f   g   h
#      |   |   |   |
#      |   e   |   |
#      |   |   |   |
#      +--]|[---   |   <- rest of excl(i) postponed to excl(j)
#      |   |       |
#      b   ----+----   <- rest of inherited(i) postponed to inherited(j)
#      |       |
#      |       d
#      |       |
#      ----+----
#          |
#          a

  $ hg init example-9
  $ cd example-9
  $ hg debugbuilddag '.:a*a:b*b:c*a:d*d:e*e:f<b+2:g<d+3:h*c/f:i*g/h:j*i/j:k.'
  $ hg test-log
  o    k rank=14
  |\
  | o    j rank=9
  | |\
  o \ \    i rank=7
  |\ \ \
  | | | o  h rank=5
  | | | :
  | | o :  g rank=4
  | | : :
  | o : :  f rank=4
  | | : :
  | o---+  e rank=3
  |  / /
  | : o  d rank=2
  | : |
  o : |  c rank=3
  :/ /
  o /  b rank=2
  |/
  o  a rank=1
  

Display sort(i) for reference:

  $ hg test-sts i
  i,c,b,f,e,d,a, (no-eol)

Display sort(j) for reference:

  $ hg test-sts j
  j,g,*,b,h,*,d,a, (no-eol) (glob)

Check that the end of excl(i) is postponed to excl(j), the end of inherited(i)
is postponed to inherited(j) in sort(k):

  $ hg test-sts k
  k,i,c,f,e,j,g,*,b,h,*,d,a, (no-eol) (glob)

Check the leaps of "i".

  $ hg test-leaps i
  bf

  $ hg test-leaps --specific i

Check the leaps of "j".

  $ hg test-leaps j
  bh

  $ hg test-leaps --specific j

Check the leaps of "k".

  $ hg test-leaps k
  cf
  ej
  bh

  $ hg test-leaps --specific k
  cf

  $ cd ..


Example 10: adjusting other leaps
=================================

This test checks the adjustment of leaps attached to other open merges in the
stack.

#            o
#            |
#      ------>------
#      |           |
#      n           l
#      |           |
#      |       ----<----
#      |       |       |
#      |       i       k
#      m       |       |
#      |    ---<---    |
#      |    |     |    |
#      |    d     h    |
#      |    |     |    j
#      |    |     g    |
#      |    c     |    |
#      |    |     +-----
#      -----+     |
#           |     f
#           b     |
#           |     e         <- Done with excl(o) by element count, without
#           |     |            having emitted "b". Implicitly unstack open
#           ---+---            merges to leap e->n.
#              |
#              a

  $ hg init example-10
  $ cd example-10
  $ hg debugbuilddag '
  >   .:a
  >    *a:b.:c.:d
  >    *a:e.:f.:g.:h
  >             *d/h:i
  >         *f:j+6:k
  >                 *i/k:l
  >      *b:m+15:n
  >                   *n/l:o.
  > '
  $ hg test-log
  o    o rank=34
  |\
  | o  n rank=18
  | :
  | o  m rank=3
  | |
  o |    l rank=17
  |\ \
  | o |  k rank=10
  | : |
  | o |  j rank=4
  | | |
  o | |    i rank=9
  |\ \ \
  | o | |  h rank=5
  | | | |
  | o | |  g rank=4
  | |/ /
  | o |  f rank=3
  | | |
  | o |  e rank=2
  | | |
  o | |  d rank=4
  | | |
  o---+  c rank=3
   / /
  | o  b rank=2
  |/
  o  a rank=1
  

Check the stable-tail sort of "o":

  $ hg test-sts o
  o,l,i,d,c,h,g,k,*,j,f,e,n,*,m,b,a, (no-eol) (glob)

Stale-tail sort of "l" for reference:

  $ hg test-sts l
  l,i,d,c,b,h,g,k,*,j,f,e,a, (no-eol) (glob)

Check the corresponding leaps:

  $ hg test-leaps o
  ch
  gk
  en

  $ hg test-leaps --specific o
  ch

  $ hg test-leaps l
  bh
  gk

  $ hg test-leaps --specific l

  $ cd ..


Example 11: adjusting other leaps with the same destination
===========================================================

This is a variant of the previous test, checking the adjustment of leaps having
the same destination in particular.

#            r
#            |
#      ------>------
#      |           |
#      |           o
#      q           |
#      |     ------>------
#      |     |           |
#      |     n           l
#      |     |           |
#      |     |       ----<----
#      p     |       |       |
#      |     |       i       k
#      |     m       |       |
#      |     |    ---<---    |
#      |     |    |     |    |
#      |     |    d     h    |
#      |     |    |     |    j
#      -----]|[---+     |    |   <- in sts(r): leap d->h
#            |    |     g    |
#            |    c     |    |
#            |    |     +-----
#            -----+     |        <- the leap c->h of sts(o)
#                 |     f           is shadowed in sts(r)
#                 b     |
#                 |     e
#                 |     |
#                 ---+---
#                    |
#                    a

  $ hg init example-11
  $ cd example-11
  $ hg debugbuilddag '
  >   .:a
  >    *a:b.:c.:d
  >    *a:e.:f.:g.:h
  >             *d/h:i
  >         *f:j+6:k
  >                 *i/k:l
  >      *b:m+15:n
  >                   *n/l:o
  >          *c:p+31:q
  >                       *o/q:r.
  > '
  $ hg test-log
  o    r rank=67
  |\
  | o  q rank=35
  | :
  | o  p rank=4
  | |
  o |    o rank=34
  |\ \
  | o |  n rank=18
  | : |
  | o |  m rank=3
  | | |
  o | |    l rank=17
  |\ \ \
  | o | |  k rank=10
  | : | |
  | o | |  j rank=4
  | | | |
  o | | |    i rank=9
  |\ \ \ \
  | o | | |  h rank=5
  | | | | |
  | o | | |  g rank=4
  | |/ / /
  | o | |  f rank=3
  | | | |
  | o | |  e rank=2
  | | | |
  o-----+  d rank=4
   / / /
  | | o  c rank=3
  | |/
  | o  b rank=2
  |/
  o  a rank=1
  

Check the stable-tail sort of "r":

  $ hg test-sts r
  r,o,l,i,d,h,g,k,*,j,f,e,n,*,m,q,*,p,c,b,a, (no-eol) (glob)

Stable-tail sort of "o" for reference:

  $ hg test-sts o
  o,l,i,d,c,h,g,k,*,j,f,e,n,*,m,b,a, (no-eol) (glob)

Check the associated leaps:

  $ hg test-leaps r
  dh
  gk
  en
  mq

  $ hg test-leaps --specific r
  dh

  $ hg test-leaps o
  ch
  gk
  en

  $ hg test-leaps --specific o
  ch

  $ cd ..


Example 12
==========

This is a variant of the previous test, checking the adjustments of leaps
in the open merge stack having a lower destination (which should appear only
later in the stable-tail sort of the head).

#            t
#            |
#      ------>------
#      |           |
#      |           o
#      s           |
#      |     ------>------
#      |     |           |
#      |     n           l
#      r     |           |
#      |     |       ----<----
#      |     |       |       |
#    --<--   |       i       k
#    |   |   m       |       |
#    p   q   |    ---<---    |
#    |   |   |    |     |    |
#    |   ---]|[--]|[----+    |
#    |       |    |     |    |
#    |       |    d     h    |
#    |       |    |     |    j
#    -------]|[---+     |    |   <- d->k is sts(t)
#            |    |     g    |
#            |    c     |    |
#            |    |     +-----
#            -----+     |        <- c->h in sts(o), not applying in sts(t)
#                 |     f
#                 b     |
#                 |     e
#                 |     |
#                 ---+---
#                    |
#                    a

  $ hg init example-12
  $ cd example-12
  $ hg debugbuilddag '
  >   .:a
  >    *a:b.:c.:d
  >    *a:e.:f.:g.:h
  >             *d/h:i
  >         *f:j+6:k
  >                 *i/k:l
  >      *b:m+15:n
  >                   *n/l:o
  >          *c:p
  >               *h:q
  >               *p/q:r+25:s
  >                       *o/s:t.
  > '
  $ hg test-log
  o    t rank=63
  |\
  | o  s rank=35
  | :
  | o    r rank=10
  | |\
  | | o  q rank=6
  | | |
  | o |  p rank=4
  | | |
  o | |    o rank=34
  |\ \ \
  | o | |  n rank=18
  | : | |
  | o | |  m rank=3
  | | | |
  o | | |    l rank=17
  |\ \ \ \
  | o | | |  k rank=10
  | : | | |
  | o | | |  j rank=4
  | | | | |
  o-------+  i rank=9
  | | | | |
  | | | | o  h rank=5
  | | | | |
  | +-----o  g rank=4
  | | | |
  | o | |  f rank=3
  | | | |
  | o | |  e rank=2
  | | | |
  o-----+  d rank=4
   / / /
  | | o  c rank=3
  | |/
  | o  b rank=2
  |/
  o  a rank=1
  

Check the stable-tail sort of "t":

  $ hg test-sts t
  t,o,l,i,d,k,*,j,n,*,m,s,*,r,p,c,b,q,h,g,f,e,a, (no-eol) (glob)

Stable-tail sort of "o" for reference:

  $ hg test-sts o
  o,l,i,d,c,h,g,k,*,j,f,e,n,*,m,b,a, (no-eol) (glob)

Check the associated leaps:

  $ hg test-leaps t
  dk
  jn
  ms
  bq

  $ hg test-leaps --specific t
  dk
  jn

  $ hg test-leaps o
  ch
  gk
  en

  $ hg test-leaps --specific o
  ch

  $ cd ..
