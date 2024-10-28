==============================================
Test merge algorithm with "relaxed block sync"
==============================================

Setup
=====

  $ cat >> $HGRCPATH << EOF
  > [experimental]
  > relaxed-block-sync-merge=yes
  > [ui]
  > merge=:merge3
  > EOF
  $ unset HGMERGE

  $ hg init repo
  $ cd repo

  $ m=../scratch
  $ mkdir "$m"

# For the purpose of this test, we use a file [listing] that has one line
# per file of [scratch] directory.
# This way, the patches can be represented as bash scripts.
#
# Adding a line is then just "touch", removing a line is "rm", and
# modifying a line is "echo modfied > file1".

# Make_change takes a "patch script", as described above, and
# produces a file [listing] with the coresponding contents
# past applying the patch to a fixed base state.
  $ make_change() {
  >   cmd=$1
  >    rm -r ../scratch
  >    mkdir ../scratch
  >    (cat listing 2>/dev/null || true) | while IFS=' :' read k v; do echo "$v" > ../scratch/"$k"; done
  >   
  >   (
  >    cd ../scratch
  >    eval "$cmd" >&2
  >    for f in *; do val=$(cat "$f"); printf "$f: $val\n"; done) > listing
  > }

# mk_rev takes a [base] and a patch, and produces a child revision of [base]
# corresponding to that patch.
  $ mk_rev() {
  >   base=$1
  >   cmd=$2
  >   (hg update -C "$base" -q
  >   make_change "$cmd"
  >   (hg commit -qAm _ 2>&1) | grep -v 'commit already existed') >&2
  >   hg log -r . -T '{rev}'
  > }

  $ test() {
  >   cmd1=$1
  >   cmd2=$2
  >   r2=$(mk_rev 0 "$cmd2")
  >   r1=$(mk_rev 0 "$cmd1")
  >   # already at r1
  >   hg merge -q "$r2"
  >   cat listing
  > }

  $ rev0=$(mk_rev 'rev(-1)' 'echo val1 > key1; echo val2 > key2; echo val3 > key3; ')
  $ cat listing
  key1: val1
  key2: val2
  key3: val3

Actual testing
==============

easy merge: no need for relaxed block sync:
-------------------------------------------

  $ test 'echo modified1 > key1' 'echo modified3 > key3'
  key1: modified1
  key2: val2
  key3: modified3

Add adjacent to modify:
-----------------------

  $ test 'echo modified > key3' 'echo val4 > key4'
  key1: val1
  key2: val2
  key3: modified
  key4: val4

Modify adjacent to modify:
--------------------------

  $ test 'echo modified3 > key3' 'echo modified2 > key2'
  key1: val1
  key2: modified2
  key3: modified3

Remove adjacent to modify:
--------------------------

  $ test 'rm key2' 'echo modified > key1'
  key1: modified
  key3: val3

Add adjacent to remove:
-----------------------

  $ test 'rm key2' 'touch key1a'
  key1: val1
  key1a: 
  key3: val3

Remove adjacent to remove:
--------------------------

  $ test 'rm key2' 'rm key1'
  key3: val3

It even works if you're sandwiched between additions above and below:

  $ test 'echo val-changed-3 > key3' 'touch key2a; touch key4'
  key1: val1
  key2: val2
  key2a: 
  key3: val-changed-3
  key4: 

Add adjacent to add:
--------------------

Add adjacent to add is still disallowed because we don't  know what order to add
lines in:

  $ test 'touch key1a' 'touch key1b'
  warning: conflicts while merging listing! (edit, then use 'hg resolve --mark')
  key1: val1
  <<<<<<< working copy:    744662bcc33a - test: _
  key1a: 
  ||||||| common ancestor: b1791e356cd4 - test: _
  =======
  key1b: 
  >>>>>>> merge rev:       06735b47f956 - test: _
  key2: val2
  key3: val3

Add kinda-adjacent to add can still work if there's an
adjacent line that helps resolve the order ambiguity:

  $ test 'touch key1a; rm key2' 'touch key2a'
  key1: val1
  key1a: 
  key2a: 
  key3: val3
