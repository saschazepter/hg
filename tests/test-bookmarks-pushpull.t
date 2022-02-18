#testcases b2-pushkey b2-binary

#if b2-pushkey
  $ cat << EOF >> $HGRCPATH
  > [devel]
  > legacy.exchange=bookmarks
  > EOF
#endif

#require serve

  $ cat << EOF >> $HGRCPATH
  > [command-templates]
  > log={rev}:{node|short} {desc|firstline}
  > [phases]
  > publish=False
  > [experimental]
  > evolution.createmarkers=True
  > evolution.exchange=True
  > EOF

  $ cat > $TESTTMP/hook.sh <<'EOF'
  > echo "test-hook-bookmark: $HG_BOOKMARK:  $HG_OLDNODE -> $HG_NODE"
  > EOF
  $ TESTHOOK="hooks.txnclose-bookmark.test=sh $TESTTMP/hook.sh"

initialize

  $ hg init a
  $ cd a
  $ echo 'test' > test
  $ hg commit -Am'test'
  adding test

set bookmarks

  $ hg bookmark X
  $ hg bookmark Y
  $ hg bookmark Z

import bookmark by name

  $ hg init ../b
  $ cd ../b
  $ hg book Y
  $ hg book
   * Y                         -1:000000000000
  $ hg pull ../a --config "$TESTHOOK"
  pulling from ../a
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  adding remote bookmark X
  updating bookmark Y
  adding remote bookmark Z
  added 1 changesets with 1 changes to 1 files
  new changesets 4e3505fd9583 (1 drafts)
  test-hook-bookmark: X:   -> 4e3505fd95835d721066b76e75dbb8cc554d7f77
  test-hook-bookmark: Y:  0000000000000000000000000000000000000000 -> 4e3505fd95835d721066b76e75dbb8cc554d7f77
  test-hook-bookmark: Z:   -> 4e3505fd95835d721066b76e75dbb8cc554d7f77
  (run 'hg update' to get a working copy)
  $ hg bookmarks
     X                         0:4e3505fd9583
   * Y                         0:4e3505fd9583
     Z                         0:4e3505fd9583
  $ hg debugpushkey ../a namespaces
  bookmarks	
  namespaces	
  obsolete	
  phases	
  $ hg debugpushkey ../a bookmarks
  X	4e3505fd95835d721066b76e75dbb8cc554d7f77
  Y	4e3505fd95835d721066b76e75dbb8cc554d7f77
  Z	4e3505fd95835d721066b76e75dbb8cc554d7f77

delete the bookmark to re-pull it

  $ hg book -d X
  $ hg pull -B X ../a
  pulling from ../a
  no changes found
  adding remote bookmark X

finally no-op pull

  $ hg pull -B X ../a
  pulling from ../a
  no changes found
  $ hg bookmark
     X                         0:4e3505fd9583
   * Y                         0:4e3505fd9583
     Z                         0:4e3505fd9583

export bookmark by name

  $ hg bookmark W
  $ hg bookmark foo
  $ hg bookmark foobar
  $ hg push -B W ../a
  pushing to ../a
  searching for changes
  no changes found
  exporting bookmark W
  [1]
  $ hg -R ../a bookmarks
     W                         -1:000000000000
     X                         0:4e3505fd9583
     Y                         0:4e3505fd9583
   * Z                         0:4e3505fd9583

delete a remote bookmark

  $ hg book -d W

#if b2-pushkey

  $ hg push -B W ../a --config "$TESTHOOK" --debug --config devel.bundle2.debug=yes
  pushing to ../a
  query 1; heads
  searching for changes
  all remote heads known locally
  listing keys for "phases"
  checking for updated bookmarks
  listing keys for "bookmarks"
  no changes found
  bundle2-output-bundle: "HG20", 4 parts total
  bundle2-output: start emission of HG20 stream
  bundle2-output: bundle parameter: 
  bundle2-output: start of parts
  bundle2-output: bundle part: "replycaps"
  bundle2-output-part: "replycaps" 224 bytes payload
  bundle2-output: part 0: "REPLYCAPS"
  bundle2-output: header chunk size: 16
  bundle2-output: payload chunk size: 224
  bundle2-output: closing payload chunk
  bundle2-output: bundle part: "check:bookmarks"
  bundle2-output-part: "check:bookmarks" 23 bytes payload
  bundle2-output: part 1: "CHECK:BOOKMARKS"
  bundle2-output: header chunk size: 22
  bundle2-output: payload chunk size: 23
  bundle2-output: closing payload chunk
  bundle2-output: bundle part: "check:phases"
  bundle2-output-part: "check:phases" 24 bytes payload
  bundle2-output: part 2: "CHECK:PHASES"
  bundle2-output: header chunk size: 19
  bundle2-output: payload chunk size: 24
  bundle2-output: closing payload chunk
  bundle2-output: bundle part: "pushkey"
  bundle2-output-part: "pushkey" (params: 4 mandatory) empty payload
  bundle2-output: part 3: "PUSHKEY"
  bundle2-output: header chunk size: 90
  bundle2-output: closing payload chunk
  bundle2-output: end of bundle
  bundle2-input: start processing of HG20 stream
  bundle2-input: reading bundle2 stream parameters
  bundle2-input-bundle: with-transaction
  bundle2-input: start extraction of bundle2 parts
  bundle2-input: part header size: 16
  bundle2-input: part type: "REPLYCAPS"
  bundle2-input: part id: "0"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part replycaps
  bundle2-input-part: "replycaps" supported
  bundle2-input: payload chunk size: 224
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 224
  bundle2-input: part header size: 22
  bundle2-input: part type: "CHECK:BOOKMARKS"
  bundle2-input: part id: "1"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part check:bookmarks
  bundle2-input-part: "check:bookmarks" supported
  bundle2-input: payload chunk size: 23
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 23
  bundle2-input: part header size: 19
  bundle2-input: part type: "CHECK:PHASES"
  bundle2-input: part id: "2"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part check:phases
  bundle2-input-part: "check:phases" supported
  bundle2-input: payload chunk size: 24
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 24
  bundle2-input: part header size: 90
  bundle2-input: part type: "PUSHKEY"
  bundle2-input: part id: "3"
  bundle2-input: part parameters: 4
  bundle2-input: found a handler for part pushkey
  bundle2-input-part: "pushkey" (params: 4 mandatory) supported
  pushing key for "bookmarks:W"
  bundle2-input: payload chunk size: 0
  bundle2-input: part header size: 0
  bundle2-input: end of bundle2 stream
  bundle2-input-bundle: 4 parts total
  running hook txnclose-bookmark.test: sh $TESTTMP/hook.sh
  test-hook-bookmark: W:  0000000000000000000000000000000000000000 -> 
  bundle2-output-bundle: "HG20", 1 parts total
  bundle2-output: start emission of HG20 stream
  bundle2-output: bundle parameter: 
  bundle2-output: start of parts
  bundle2-output: bundle part: "reply:pushkey"
  bundle2-output-part: "reply:pushkey" (params: 0 advisory) empty payload
  bundle2-output: part 0: "REPLY:PUSHKEY"
  bundle2-output: header chunk size: 43
  bundle2-output: closing payload chunk
  bundle2-output: end of bundle
  bundle2-input: start processing of HG20 stream
  bundle2-input: reading bundle2 stream parameters
  bundle2-input-bundle: no-transaction
  bundle2-input: start extraction of bundle2 parts
  bundle2-input: part header size: 43
  bundle2-input: part type: "REPLY:PUSHKEY"
  bundle2-input: part id: "0"
  bundle2-input: part parameters: 2
  bundle2-input: found a handler for part reply:pushkey
  bundle2-input-part: "reply:pushkey" (params: 0 advisory) supported
  bundle2-input: payload chunk size: 0
  bundle2-input: part header size: 0
  bundle2-input: end of bundle2 stream
  bundle2-input-bundle: 1 parts total
  deleting remote bookmark W
  listing keys for "phases"
  [1]

#endif
#if b2-binary

  $ hg push -B W ../a --config "$TESTHOOK" --debug --config devel.bundle2.debug=yes
  pushing to ../a
  query 1; heads
  searching for changes
  all remote heads known locally
  listing keys for "phases"
  checking for updated bookmarks
  listing keys for "bookmarks"
  no changes found
  bundle2-output-bundle: "HG20", 4 parts total
  bundle2-output: start emission of HG20 stream
  bundle2-output: bundle parameter: 
  bundle2-output: start of parts
  bundle2-output: bundle part: "replycaps"
  bundle2-output-part: "replycaps" 224 bytes payload
  bundle2-output: part 0: "REPLYCAPS"
  bundle2-output: header chunk size: 16
  bundle2-output: payload chunk size: 224
  bundle2-output: closing payload chunk
  bundle2-output: bundle part: "check:bookmarks"
  bundle2-output-part: "check:bookmarks" 23 bytes payload
  bundle2-output: part 1: "CHECK:BOOKMARKS"
  bundle2-output: header chunk size: 22
  bundle2-output: payload chunk size: 23
  bundle2-output: closing payload chunk
  bundle2-output: bundle part: "check:phases"
  bundle2-output-part: "check:phases" 24 bytes payload
  bundle2-output: part 2: "CHECK:PHASES"
  bundle2-output: header chunk size: 19
  bundle2-output: payload chunk size: 24
  bundle2-output: closing payload chunk
  bundle2-output: bundle part: "bookmarks"
  bundle2-output-part: "bookmarks" 23 bytes payload
  bundle2-output: part 3: "BOOKMARKS"
  bundle2-output: header chunk size: 16
  bundle2-output: payload chunk size: 23
  bundle2-output: closing payload chunk
  bundle2-output: end of bundle
  bundle2-input: start processing of HG20 stream
  bundle2-input: reading bundle2 stream parameters
  bundle2-input-bundle: with-transaction
  bundle2-input: start extraction of bundle2 parts
  bundle2-input: part header size: 16
  bundle2-input: part type: "REPLYCAPS"
  bundle2-input: part id: "0"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part replycaps
  bundle2-input-part: "replycaps" supported
  bundle2-input: payload chunk size: 224
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 224
  bundle2-input: part header size: 22
  bundle2-input: part type: "CHECK:BOOKMARKS"
  bundle2-input: part id: "1"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part check:bookmarks
  bundle2-input-part: "check:bookmarks" supported
  bundle2-input: payload chunk size: 23
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 23
  bundle2-input: part header size: 19
  bundle2-input: part type: "CHECK:PHASES"
  bundle2-input: part id: "2"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part check:phases
  bundle2-input-part: "check:phases" supported
  bundle2-input: payload chunk size: 24
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 24
  bundle2-input: part header size: 16
  bundle2-input: part type: "BOOKMARKS"
  bundle2-input: part id: "3"
  bundle2-input: part parameters: 0
  bundle2-input: found a handler for part bookmarks
  bundle2-input-part: "bookmarks" supported
  bundle2-input: payload chunk size: 23
  bundle2-input: payload chunk size: 0
  bundle2-input-part: total payload size 23
  bundle2-input: part header size: 0
  bundle2-input: end of bundle2 stream
  bundle2-input-bundle: 4 parts total
  running hook txnclose-bookmark.test: sh $TESTTMP/hook.sh
  test-hook-bookmark: W:  0000000000000000000000000000000000000000 -> 
  bundle2-output-bundle: "HG20", 0 parts total
  bundle2-output: start emission of HG20 stream
  bundle2-output: bundle parameter: 
  bundle2-output: start of parts
  bundle2-output: end of bundle
  bundle2-input: start processing of HG20 stream
  bundle2-input: reading bundle2 stream parameters
  bundle2-input-bundle: no-transaction
  bundle2-input: start extraction of bundle2 parts
  bundle2-input: part header size: 0
  bundle2-input: end of bundle2 stream
  bundle2-input-bundle: 0 parts total
  deleting remote bookmark W
  listing keys for "phases"
  [1]

#endif

Divergent bookmark cannot be exported

  $ hg book W@default
  $ hg push -B W@default ../a
  pushing to ../a
  searching for changes
  cannot push divergent bookmark W@default!
  no changes found
  [2]
  $ hg book -d W@default

export the active bookmark

  $ hg bookmark V
  $ hg push -B . ../a
  pushing to ../a
  searching for changes
  no changes found
  exporting bookmark V
  [1]

exporting the active bookmark with 'push -B .'
demand that one of the bookmarks is activated

  $ hg update -r default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (leaving bookmark V)
  $ hg push -B . ../a
  abort: no active bookmark
  [10]
  $ hg update -r V
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (activating bookmark V)

delete the bookmark

  $ hg book -d V
  $ hg push -B V ../a
  pushing to ../a
  searching for changes
  no changes found
  deleting remote bookmark V
  [1]
  $ hg up foobar
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark foobar)

push/pull name that doesn't exist

  $ hg push -B badname ../a
  pushing to ../a
  searching for changes
  bookmark badname does not exist on the local or remote repository!
  no changes found
  [2]
  $ hg pull -B anotherbadname ../a
  pulling from ../a
  abort: remote bookmark anotherbadname not found!
  [10]

divergent bookmarks

  $ cd ../a
  $ echo c1 > f1
  $ hg ci -Am1
  adding f1
  $ hg book -f @
  $ hg book -f X
  $ hg book
     @                         1:0d2164f0ce0d
   * X                         1:0d2164f0ce0d
     Y                         0:4e3505fd9583
     Z                         1:0d2164f0ce0d

  $ cd ../b
  $ hg up
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  updating bookmark foobar
  $ echo c2 > f2
  $ hg ci -Am2
  adding f2
  $ hg book -if @
  $ hg book -if X
  $ hg book
     @                         1:9b140be10808
     X                         1:9b140be10808
     Y                         0:4e3505fd9583
     Z                         0:4e3505fd9583
     foo                       -1:000000000000
   * foobar                    1:9b140be10808

  $ hg pull --config paths.foo=../a foo --config "$TESTHOOK"
  pulling from $TESTTMP/a
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  divergent bookmark @ stored as @foo
  divergent bookmark X stored as X@foo
  updating bookmark Z
  added 1 changesets with 1 changes to 1 files (+1 heads)
  new changesets 0d2164f0ce0d (1 drafts)
  test-hook-bookmark: @foo:   -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  test-hook-bookmark: X@foo:   -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  test-hook-bookmark: Z:  4e3505fd95835d721066b76e75dbb8cc554d7f77 -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg book
     @                         1:9b140be10808
     @foo                      2:0d2164f0ce0d
     X                         1:9b140be10808
     X@foo                     2:0d2164f0ce0d
     Y                         0:4e3505fd9583
     Z                         2:0d2164f0ce0d
     foo                       -1:000000000000
   * foobar                    1:9b140be10808

(test that too many divergence of bookmark)

  $ "$PYTHON" $TESTDIR/seq.py 1 100 | while read i; do hg bookmarks -r 000000000000 "X@${i}"; done
  $ hg pull ../a
  pulling from ../a
  searching for changes
  no changes found
  warning: failed to assign numbered name to divergent bookmark X
  divergent bookmark @ stored as @1
  $ hg bookmarks | grep '^   X' | grep -v ':000000000000'
     X                         1:9b140be10808
     X@foo                     2:0d2164f0ce0d

(test that remotely diverged bookmarks are reused if they aren't changed)

  $ hg bookmarks | grep '^   @'
     @                         1:9b140be10808
     @1                        2:0d2164f0ce0d
     @foo                      2:0d2164f0ce0d
  $ hg pull ../a
  pulling from ../a
  searching for changes
  no changes found
  warning: failed to assign numbered name to divergent bookmark X
  divergent bookmark @ stored as @1
  $ hg bookmarks | grep '^   @'
     @                         1:9b140be10808
     @1                        2:0d2164f0ce0d
     @foo                      2:0d2164f0ce0d

  $ "$PYTHON" $TESTDIR/seq.py 1 100 | while read i; do hg bookmarks -d "X@${i}"; done
  $ hg bookmarks -d "@1"

  $ hg push -f ../a
  pushing to ../a
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  $ hg -R ../a book
     @                         1:0d2164f0ce0d
   * X                         1:0d2164f0ce0d
     Y                         0:4e3505fd9583
     Z                         1:0d2164f0ce0d

mirroring bookmarks

  $ hg book
     @                         1:9b140be10808
     @foo                      2:0d2164f0ce0d
     X                         1:9b140be10808
     X@foo                     2:0d2164f0ce0d
     Y                         0:4e3505fd9583
     Z                         2:0d2164f0ce0d
     foo                       -1:000000000000
   * foobar                    1:9b140be10808
  $ cp .hg/bookmarks .hg/bookmarks.bak
  $ hg book -d X
  $ hg incoming --bookmark  -v ../a
  comparing with ../a
  searching for changed bookmarks
     @                         0d2164f0ce0d diverged
     X                         0d2164f0ce0d added
  $ hg incoming --bookmark  -v ../a --config 'paths.*:bookmarks.mode=babar'
  (paths.*:bookmarks.mode has unknown value: "babar")
  comparing with ../a
  searching for changed bookmarks
     @                         0d2164f0ce0d diverged
     X                         0d2164f0ce0d added
  $ hg incoming --bookmark  -v ../a --config 'paths.*:bookmarks.mode=mirror'
  comparing with ../a
  searching for changed bookmarks
     @                         0d2164f0ce0d changed
     @foo                      000000000000 removed
     X                         0d2164f0ce0d added
     X@foo                     000000000000 removed
     foo                       000000000000 removed
     foobar                    000000000000 removed
  $ hg incoming --bookmark  -v ../a --config 'paths.*:bookmarks.mode=ignore'
  comparing with ../a
  bookmarks exchange disabled with this path
  $ hg pull ../a --config 'paths.*:bookmarks.mode=ignore'
  pulling from ../a
  searching for changes
  no changes found
  $ hg book
     @                         1:9b140be10808
     @foo                      2:0d2164f0ce0d
     X@foo                     2:0d2164f0ce0d
     Y                         0:4e3505fd9583
     Z                         2:0d2164f0ce0d
     foo                       -1:000000000000
   * foobar                    1:9b140be10808
  $ hg pull ../a --config 'paths.*:bookmarks.mode=mirror'
  pulling from ../a
  searching for changes
  no changes found
  $ hg book
     @                         2:0d2164f0ce0d
     X                         2:0d2164f0ce0d
     Y                         0:4e3505fd9583
     Z                         2:0d2164f0ce0d
  $ mv .hg/bookmarks.bak .hg/bookmarks

explicit pull should overwrite the local version (issue4439)

  $ hg update -r X
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark X)
  $ hg pull --config paths.foo=../a foo -B . --config "$TESTHOOK"
  pulling from $TESTTMP/a
  no changes found
  divergent bookmark @ stored as @foo
  importing bookmark X
  test-hook-bookmark: @foo:  0d2164f0ce0d8f1d6f94351eba04b794909be66c -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  test-hook-bookmark: X:  9b140be1080824d768c5a4691a564088eede71f9 -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c

reinstall state for further testing:

  $ hg book -fr 9b140be10808 X

revsets should not ignore divergent bookmarks

  $ hg bookmark -fr 1 Z
  $ hg log -r 'bookmark()' --template '{rev}:{node|short} {bookmarks}\n'
  0:4e3505fd9583 Y
  1:9b140be10808 @ X Z foobar
  2:0d2164f0ce0d @foo X@foo
  $ hg log -r 'bookmark("X@foo")' --template '{rev}:{node|short} {bookmarks}\n'
  2:0d2164f0ce0d @foo X@foo
  $ hg log -r 'bookmark("re:X@foo")' --template '{rev}:{node|short} {bookmarks}\n'
  2:0d2164f0ce0d @foo X@foo

update a remote bookmark from a non-head to a head

  $ hg up -q Y
  $ echo c3 > f2
  $ hg ci -Am3
  adding f2
  created new head
  $ hg push ../a --config "$TESTHOOK"
  pushing to ../a
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files (+1 heads)
  test-hook-bookmark: Y:  4e3505fd95835d721066b76e75dbb8cc554d7f77 -> f6fc62dde3c0771e29704af56ba4d8af77abcc2f
  updating bookmark Y
  $ hg -R ../a book
     @                         1:0d2164f0ce0d
   * X                         1:0d2164f0ce0d
     Y                         3:f6fc62dde3c0
     Z                         1:0d2164f0ce0d

update a bookmark in the middle of a client pulling changes

  $ cd ..
  $ hg clone -q a pull-race

We want to use http because it is stateless and therefore more susceptible to
race conditions

  $ hg serve -R pull-race -p $HGPORT -d --pid-file=pull-race.pid -E main-error.log
  $ cat pull-race.pid >> $DAEMON_PIDS

  $ cat <<EOF > $TESTTMP/out_makecommit.sh
  > #!/bin/sh
  > hg ci -Am5
  > echo committed in pull-race
  > EOF

  $ hg clone -q http://localhost:$HGPORT/ pull-race2 --config "$TESTHOOK"
  test-hook-bookmark: @:   -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  test-hook-bookmark: X:   -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  test-hook-bookmark: Y:   -> f6fc62dde3c0771e29704af56ba4d8af77abcc2f
  test-hook-bookmark: Z:   -> 0d2164f0ce0d8f1d6f94351eba04b794909be66c
  $ cd pull-race
  $ hg up -q Y
  $ echo c4 > f2
  $ hg ci -Am4
  $ echo c5 > f3
  $ cat <<EOF > .hg/hgrc
  > [hooks]
  > outgoing.makecommit = sh $TESTTMP/out_makecommit.sh
  > EOF

(new config needs a server restart)

  $ cd ..
  $ killdaemons.py
  $ hg serve -R pull-race -p $HGPORT -d --pid-file=pull-race.pid -E main-error.log
  $ cat pull-race.pid >> $DAEMON_PIDS
  $ cd pull-race2
  $ hg -R $TESTTMP/pull-race book
     @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
   * Y                         4:b0a5eff05604
     Z                         1:0d2164f0ce0d
  $ hg pull
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  updating bookmark Y
  added 1 changesets with 1 changes to 1 files
  new changesets b0a5eff05604 (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg book
   * @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
     Y                         4:b0a5eff05604
     Z                         1:0d2164f0ce0d

Update a bookmark right after the initial lookup -B (issue4689)

  $ echo c6 > ../pull-race/f3 # to be committed during the race
  $ cat <<EOF > $TESTTMP/listkeys_makecommit.sh
  > #!/bin/sh
  > if hg st | grep -q M; then
  >     hg commit -m race
  >     echo committed in pull-race
  > else
  >     exit 0
  > fi
  > EOF
  $ cat <<EOF > ../pull-race/.hg/hgrc
  > [hooks]
  > # If anything to commit, commit it right after the first key listing used
  > # during lookup. This makes the commit appear before the actual getbundle
  > # call.
  > listkeys.makecommit= sh $TESTTMP/listkeys_makecommit.sh
  > EOF
  $ restart_server() {
  >  "$TESTDIR/killdaemons.py" $DAEMON_PIDS
  >  hg serve -R ../pull-race -p $HGPORT -d --pid-file=../pull-race.pid -E main-error.log
  >  cat ../pull-race.pid >> $DAEMON_PIDS
  > }
  $ restart_server # new config need server restart
  $ hg -R $TESTTMP/pull-race book
     @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
   * Y                         5:35d1ef0a8d1b
     Z                         1:0d2164f0ce0d
  $ hg update -r Y
  1 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (activating bookmark Y)
  $ hg pull -B .
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  updating bookmark Y
  added 1 changesets with 1 changes to 1 files
  new changesets 35d1ef0a8d1b (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg book
     @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
   * Y                         5:35d1ef0a8d1b
     Z                         1:0d2164f0ce0d

Update a bookmark right after the initial lookup -r (issue4700)

  $ echo c7 > ../pull-race/f3 # to be committed during the race
  $ cat <<EOF > ../lookuphook.py
  > """small extensions adding a hook after wireprotocol lookup to test race"""
  > import functools
  > from mercurial import wireprotov1server
  > 
  > def wrappedlookup(orig, repo, *args, **kwargs):
  >     ret = orig(repo, *args, **kwargs)
  >     repo.hook(b'lookup')
  >     return ret
  > 
  > table = wireprotov1server.commands
  > table[b'lookup'].func = functools.partial(wrappedlookup, table[b'lookup'].func)
  > EOF
  $ cat <<EOF > ../pull-race/.hg/hgrc
  > [extensions]
  > lookuphook=$TESTTMP/lookuphook.py
  > [hooks]
  > lookup.makecommit= sh $TESTTMP/listkeys_makecommit.sh
  > EOF
  $ restart_server # new config need server restart
  $ hg -R $TESTTMP/pull-race book
     @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
   * Y                         6:0d60821d2197
     Z                         1:0d2164f0ce0d
  $ hg pull -r Y
  pulling from http://localhost:$HGPORT/
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  updating bookmark Y
  added 1 changesets with 1 changes to 1 files
  new changesets 0d60821d2197 (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg book
     @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
   * Y                         6:0d60821d2197
     Z                         1:0d2164f0ce0d
  $ hg -R $TESTTMP/pull-race book
     @                         1:0d2164f0ce0d
     X                         1:0d2164f0ce0d
   * Y                         7:714424d9e8b8
     Z                         1:0d2164f0ce0d

(done with this section of the test)

  $ killdaemons.py
  $ cd ../b

diverging a remote bookmark fails

  $ hg up -q 4e3505fd9583
  $ echo c4 > f2
  $ hg ci -Am4
  adding f2
  created new head
  $ echo c5 > f2
  $ hg ci -Am5
  $ hg log -G
  @  5:c922c0139ca0 5
  |
  o  4:4efff6d98829 4
  |
  | o  3:f6fc62dde3c0 3
  |/
  | o  2:0d2164f0ce0d 1
  |/
  | o  1:9b140be10808 2
  |/
  o  0:4e3505fd9583 test
  

  $ hg book -f Y

  $ cat <<EOF > ../a/.hg/hgrc
  > [web]
  > push_ssl = false
  > allow_push = *
  > EOF

  $ hg serve -R ../a -p $HGPORT2 -d --pid-file=../hg2.pid
  $ cat ../hg2.pid >> $DAEMON_PIDS

  $ hg push http://localhost:$HGPORT2/
  pushing to http://localhost:$HGPORT2/
  searching for changes
  abort: push creates new remote head c922c0139ca0 with bookmark 'Y'
  (merge or see 'hg help push' for details about pushing new heads)
  [20]
  $ hg -R ../a book
     @                         1:0d2164f0ce0d
   * X                         1:0d2164f0ce0d
     Y                         3:f6fc62dde3c0
     Z                         1:0d2164f0ce0d


Unrelated marker does not alter the decision

  $ hg debugobsolete aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  1 new obsolescence markers
  $ hg push http://localhost:$HGPORT2/
  pushing to http://localhost:$HGPORT2/
  searching for changes
  abort: push creates new remote head c922c0139ca0 with bookmark 'Y'
  (merge or see 'hg help push' for details about pushing new heads)
  [20]
  $ hg -R ../a book
     @                         1:0d2164f0ce0d
   * X                         1:0d2164f0ce0d
     Y                         3:f6fc62dde3c0
     Z                         1:0d2164f0ce0d

Update to a successor works

  $ hg id --debug -r 3
  f6fc62dde3c0771e29704af56ba4d8af77abcc2f
  $ hg id --debug -r 4
  4efff6d98829d9c824c621afd6e3f01865f5439f
  $ hg id --debug -r 5
  c922c0139ca03858f655e4a2af4dd02796a63969 tip Y
  $ hg debugobsolete f6fc62dde3c0771e29704af56ba4d8af77abcc2f cccccccccccccccccccccccccccccccccccccccc
  1 new obsolescence markers
  obsoleted 1 changesets
  $ hg debugobsolete cccccccccccccccccccccccccccccccccccccccc 4efff6d98829d9c824c621afd6e3f01865f5439f
  1 new obsolescence markers
  $ hg push http://localhost:$HGPORT2/
  pushing to http://localhost:$HGPORT2/
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 2 changesets with 2 changes to 1 files (+1 heads)
  remote: 2 new obsolescence markers
  remote: obsoleted 1 changesets
  updating bookmark Y
  $ hg -R ../a book
     @                         1:0d2164f0ce0d
   * X                         1:0d2164f0ce0d
     Y                         5:c922c0139ca0
     Z                         1:0d2164f0ce0d

hgweb

  $ cat <<EOF > .hg/hgrc
  > [web]
  > push_ssl = false
  > allow_push = *
  > EOF

  $ hg serve -p $HGPORT -d --pid-file=../hg.pid -E errors.log
  $ cat ../hg.pid >> $DAEMON_PIDS
  $ cd ../a

  $ hg debugpushkey http://localhost:$HGPORT/ namespaces
  bookmarks	
  namespaces	
  obsolete	
  phases	
  $ hg debugpushkey http://localhost:$HGPORT/ bookmarks
  @	9b140be1080824d768c5a4691a564088eede71f9
  X	9b140be1080824d768c5a4691a564088eede71f9
  Y	c922c0139ca03858f655e4a2af4dd02796a63969
  Z	9b140be1080824d768c5a4691a564088eede71f9
  foo	0000000000000000000000000000000000000000
  foobar	9b140be1080824d768c5a4691a564088eede71f9
  $ hg out -B http://localhost:$HGPORT/
  comparing with http://localhost:$HGPORT/
  searching for changed bookmarks
     @                         0d2164f0ce0d
     X                         0d2164f0ce0d
     Z                         0d2164f0ce0d
     foo                                   
     foobar                                
  $ hg push -B Z http://localhost:$HGPORT/
  pushing to http://localhost:$HGPORT/
  searching for changes
  no changes found
  updating bookmark Z
  [1]
  $ hg book -d Z
  $ hg in -B http://localhost:$HGPORT/
  comparing with http://localhost:$HGPORT/
  searching for changed bookmarks
     @                         9b140be10808
     X                         9b140be10808
     Z                         0d2164f0ce0d
     foo                       000000000000
     foobar                    9b140be10808
  $ hg pull -B Z http://localhost:$HGPORT/
  pulling from http://localhost:$HGPORT/
  no changes found
  divergent bookmark @ stored as @1
  divergent bookmark X stored as X@1
  adding remote bookmark Z
  adding remote bookmark foo
  adding remote bookmark foobar
  $ hg clone http://localhost:$HGPORT/ cloned-bookmarks
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 3 files (+2 heads)
  2 new obsolescence markers
  new changesets 4e3505fd9583:c922c0139ca0 (5 drafts)
  updating to bookmark @
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg -R cloned-bookmarks bookmarks
   * @                         1:9b140be10808
     X                         1:9b140be10808
     Y                         4:c922c0139ca0
     Z                         2:0d2164f0ce0d
     foo                       -1:000000000000
     foobar                    1:9b140be10808

  $ cd ..

Test to show result of bookmarks comparison

  $ mkdir bmcomparison
  $ cd bmcomparison

  $ hg init source
  $ hg -R source debugbuilddag '+2*2*3*4'
  $ hg -R source log -G --template '{rev}:{node|short}'
  o  4:e7bd5218ca15
  |
  | o  3:6100d3090acf
  |/
  | o  2:fa942426a6fd
  |/
  | o  1:66f7d451a68b
  |/
  o  0:1ea73414a91b
  
  $ hg -R source bookmarks -r 0 SAME
  $ hg -R source bookmarks -r 0 ADV_ON_REPO1
  $ hg -R source bookmarks -r 0 ADV_ON_REPO2
  $ hg -R source bookmarks -r 0 DIFF_ADV_ON_REPO1
  $ hg -R source bookmarks -r 0 DIFF_ADV_ON_REPO2
  $ hg -R source bookmarks -r 1 DIVERGED

  $ hg clone -U source repo1

(test that incoming/outgoing exit with 1, if there is no bookmark to
be exchanged)

  $ hg -R repo1 incoming -B
  comparing with $TESTTMP/bmcomparison/source
  searching for changed bookmarks
  no changed bookmarks found
  [1]
  $ hg -R repo1 outgoing -B
  comparing with $TESTTMP/bmcomparison/source
  searching for changed bookmarks
  no changed bookmarks found
  [1]

  $ hg -R repo1 bookmarks -f -r 1 ADD_ON_REPO1
  $ hg -R repo1 bookmarks -f -r 2 ADV_ON_REPO1
  $ hg -R repo1 bookmarks -f -r 3 DIFF_ADV_ON_REPO1
  $ hg -R repo1 bookmarks -f -r 3 DIFF_DIVERGED
  $ hg -R repo1 -q --config extensions.mq= strip 4
  $ hg -R repo1 log -G --template '{node|short} ({bookmarks})'
  o  6100d3090acf (DIFF_ADV_ON_REPO1 DIFF_DIVERGED)
  |
  | o  fa942426a6fd (ADV_ON_REPO1)
  |/
  | o  66f7d451a68b (ADD_ON_REPO1 DIVERGED)
  |/
  o  1ea73414a91b (ADV_ON_REPO2 DIFF_ADV_ON_REPO2 SAME)
  

  $ hg clone -U source repo2
  $ hg -R repo2 bookmarks -f -r 1 ADD_ON_REPO2
  $ hg -R repo2 bookmarks -f -r 1 ADV_ON_REPO2
  $ hg -R repo2 bookmarks -f -r 2 DIVERGED
  $ hg -R repo2 bookmarks -f -r 4 DIFF_ADV_ON_REPO2
  $ hg -R repo2 bookmarks -f -r 4 DIFF_DIVERGED
  $ hg -R repo2 -q --config extensions.mq= strip 3
  $ hg -R repo2 log -G --template '{node|short} ({bookmarks})'
  o  e7bd5218ca15 (DIFF_ADV_ON_REPO2 DIFF_DIVERGED)
  |
  | o  fa942426a6fd (DIVERGED)
  |/
  | o  66f7d451a68b (ADD_ON_REPO2 ADV_ON_REPO2)
  |/
  o  1ea73414a91b (ADV_ON_REPO1 DIFF_ADV_ON_REPO1 SAME)
  

(test that difference of bookmarks between repositories are fully shown)

  $ hg -R repo1 incoming -B repo2 -v
  comparing with repo2
  searching for changed bookmarks
     ADD_ON_REPO2              66f7d451a68b added
     ADV_ON_REPO2              66f7d451a68b advanced
     DIFF_ADV_ON_REPO2         e7bd5218ca15 changed
     DIFF_DIVERGED             e7bd5218ca15 changed
     DIVERGED                  fa942426a6fd diverged
  $ hg -R repo1 outgoing -B repo2 -v
  comparing with repo2
  searching for changed bookmarks
     ADD_ON_REPO1              66f7d451a68b added
     ADD_ON_REPO2                           deleted
     ADV_ON_REPO1              fa942426a6fd advanced
     DIFF_ADV_ON_REPO1         6100d3090acf advanced
     DIFF_ADV_ON_REPO2         1ea73414a91b changed
     DIFF_DIVERGED             6100d3090acf changed
     DIVERGED                  66f7d451a68b diverged

  $ hg -R repo2 incoming -B repo1 -v
  comparing with repo1
  searching for changed bookmarks
     ADD_ON_REPO1              66f7d451a68b added
     ADV_ON_REPO1              fa942426a6fd advanced
     DIFF_ADV_ON_REPO1         6100d3090acf changed
     DIFF_DIVERGED             6100d3090acf changed
     DIVERGED                  66f7d451a68b diverged
  $ hg -R repo2 outgoing -B repo1 -v
  comparing with repo1
  searching for changed bookmarks
     ADD_ON_REPO1                           deleted
     ADD_ON_REPO2              66f7d451a68b added
     ADV_ON_REPO2              66f7d451a68b advanced
     DIFF_ADV_ON_REPO1         1ea73414a91b changed
     DIFF_ADV_ON_REPO2         e7bd5218ca15 advanced
     DIFF_DIVERGED             e7bd5218ca15 changed
     DIVERGED                  fa942426a6fd diverged

  $ cd ..

Pushing a bookmark should only push the changes required by that
bookmark, not all outgoing changes:
  $ hg clone http://localhost:$HGPORT/ addmarks
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 3 files (+2 heads)
  2 new obsolescence markers
  new changesets 4e3505fd9583:c922c0139ca0 (5 drafts)
  updating to bookmark @
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd addmarks
  $ echo foo > foo
  $ hg add foo
  $ hg commit -m 'add foo'
  $ echo bar > bar
  $ hg add bar
  $ hg commit -m 'add bar'
  $ hg co "tip^"
  0 files updated, 0 files merged, 1 files removed, 0 files unresolved
  (leaving bookmark @)
  $ hg book add-foo
  $ hg book -r tip add-bar
Note: this push *must* push only a single changeset, as that's the point
of this test.
  $ hg push -B add-foo --traceback
  pushing to http://localhost:$HGPORT/
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files
  exporting bookmark add-foo

pushing a new bookmark on a new head does not require -f if -B is specified

  $ hg up -q X
  $ hg book W
  $ echo c5 > f2
  $ hg ci -Am5
  created new head
  $ hg push -B .
  pushing to http://localhost:$HGPORT/
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files (+1 heads)
  exporting bookmark W
  $ hg -R ../b id -r W
  cc978a373a53 tip W

pushing an existing but divergent bookmark with -B still requires -f

  $ hg clone -q . ../r
  $ hg up -q X
  $ echo 1 > f2
  $ hg ci -qAml

  $ cd ../r
  $ hg up -q X
  $ echo 2 > f2
  $ hg ci -qAmr
  $ hg push -B X
  pushing to $TESTTMP/addmarks
  searching for changes
  remote has heads on branch 'default' that are not known locally: a2a606d9ff1b
  abort: push creates new remote head 54694f811df9 with bookmark 'X'
  (pull and merge or see 'hg help push' for details about pushing new heads)
  [20]
  $ cd ../addmarks

Check summary output for incoming/outgoing bookmarks

  $ hg bookmarks -d X
  $ hg bookmarks -d Y
  $ hg summary --remote | grep '^remote:'
  remote: *, 2 incoming bookmarks, 1 outgoing bookmarks (glob)

  $ cd ..

pushing an unchanged bookmark should result in no changes

  $ hg init unchanged-a
  $ hg init unchanged-b
  $ cd unchanged-a
  $ echo initial > foo
  $ hg commit -A -m initial
  adding foo
  $ hg bookmark @
  $ hg push -B @ ../unchanged-b
  pushing to ../unchanged-b
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  exporting bookmark @

  $ hg push -B @ ../unchanged-b
  pushing to ../unchanged-b
  searching for changes
  no changes found
  [1]

Pushing a really long bookmark should work fine (issue5165)
===============================================

#if b2-binary
  >>> with open('longname', 'w') as f:
  ...     f.write('wat' * 100) and None
  $ hg book `cat longname`
  $ hg push -B `cat longname` ../unchanged-b
  pushing to ../unchanged-b
  searching for changes
  no changes found
  exporting bookmark (wat){100} (re)
  [1]
  $ hg -R ../unchanged-b book --delete `cat longname`

Test again but forcing bundle2 exchange to make sure that doesn't regress.

  $ hg push -B `cat longname` ../unchanged-b --config devel.legacy.exchange=bundle1
  pushing to ../unchanged-b
  searching for changes
  no changes found
  exporting bookmark (wat){100} (re)
  [1]
  $ hg -R ../unchanged-b book --delete `cat longname`
  $ hg book --delete `cat longname`
  $ hg co @
  0 files updated, 0 files merged, 0 files removed, 0 files unresolved
  (activating bookmark @)
#endif

Check hook preventing push (issue4455)
======================================

  $ hg bookmarks
   * @                         0:55482a6fb4b1
  $ hg log -G
  @  0:55482a6fb4b1 initial
  
  $ hg init ../issue4455-dest
  $ hg push ../issue4455-dest # changesets only
  pushing to ../issue4455-dest
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ cat >> .hg/hgrc << EOF
  > [paths]
  > local=../issue4455-dest/
  > ssh=ssh://user@dummy/issue4455-dest
  > http=http://localhost:$HGPORT/
  > EOF
  $ cat >> ../issue4455-dest/.hg/hgrc << EOF
  > [hooks]
  > prepushkey=false
  > [web]
  > push_ssl = false
  > allow_push = *
  > EOF
  $ killdaemons.py
  $ hg serve -R ../issue4455-dest -p $HGPORT -d --pid-file=../issue4455.pid -E ../issue4455-error.log
  $ cat ../issue4455.pid >> $DAEMON_PIDS

Local push
----------

#if b2-pushkey

  $ hg push -B @ local
  pushing to $TESTTMP/issue4455-dest
  searching for changes
  no changes found
  pushkey-abort: prepushkey hook exited with status 1
  abort: exporting bookmark @ failed
  [255]

#endif
#if b2-binary

  $ hg push -B @ local
  pushing to $TESTTMP/issue4455-dest
  searching for changes
  no changes found
  abort: prepushkey hook exited with status 1
  [40]

#endif

  $ hg -R ../issue4455-dest/ bookmarks
  no bookmarks set

Using ssh
---------

#if b2-pushkey

  $ hg push -B @ ssh # bundle2+
  pushing to ssh://user@dummy/issue4455-dest
  searching for changes
  no changes found
  remote: pushkey-abort: prepushkey hook exited with status 1
  abort: exporting bookmark @ failed
  [255]

  $ hg -R ../issue4455-dest/ bookmarks
  no bookmarks set

  $ hg push -B @ ssh --config devel.legacy.exchange=bundle1
  pushing to ssh://user@dummy/issue4455-dest
  searching for changes
  no changes found
  remote: pushkey-abort: prepushkey hook exited with status 1
  exporting bookmark @ failed
  [1]

#endif
#if b2-binary

  $ hg push -B @ ssh # bundle2+
  pushing to ssh://user@dummy/issue4455-dest
  searching for changes
  no changes found
  remote: prepushkey hook exited with status 1
  abort: push failed on remote
  [100]

#endif

  $ hg -R ../issue4455-dest/ bookmarks
  no bookmarks set

Using http
----------

#if b2-pushkey
  $ hg push -B @ http # bundle2+
  pushing to http://localhost:$HGPORT/
  searching for changes
  no changes found
  remote: pushkey-abort: prepushkey hook exited with status 1
  abort: exporting bookmark @ failed
  [255]

  $ hg -R ../issue4455-dest/ bookmarks
  no bookmarks set

  $ hg push -B @ http --config devel.legacy.exchange=bundle1
  pushing to http://localhost:$HGPORT/
  searching for changes
  no changes found
  remote: pushkey-abort: prepushkey hook exited with status 1
  exporting bookmark @ failed
  [1]

#endif

#if b2-binary

  $ hg push -B @ ssh # bundle2+
  pushing to ssh://user@dummy/issue4455-dest
  searching for changes
  no changes found
  remote: prepushkey hook exited with status 1
  abort: push failed on remote
  [100]

#endif

  $ hg -R ../issue4455-dest/ bookmarks
  no bookmarks set

  $ cd ..

Test that pre-pushkey compat for bookmark works as expected (issue5777)

  $ cat << EOF >> $HGRCPATH
  > [ui]
  > [server]
  > bookmarks-pushkey-compat = yes
  > EOF

  $ hg init server
  $ echo foo > server/a
  $ hg -R server book foo
  $ hg -R server commit -Am a
  adding a
  $ hg clone ssh://user@dummy/server client
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  new changesets 79513d0d7716 (1 drafts)
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Forbid bookmark move on the server

  $ cat << EOF >> $TESTTMP/no-bm-move.sh
  > #!/bin/sh
  > echo \$HG_NAMESPACE | grep -v bookmarks
  > EOF
  $ cat << EOF >> server/.hg/hgrc
  > [hooks]
  > prepushkey.no-bm-move= sh $TESTTMP/no-bm-move.sh
  > EOF

pushing changeset is okay

  $ echo bar >> client/a
  $ hg -R client commit -m b
  $ hg -R client push
  pushing to ssh://user@dummy/server
  searching for changes
  remote: adding changesets
  remote: adding manifests
  remote: adding file changes
  remote: added 1 changesets with 1 changes to 1 files

attempt to move the bookmark is rejected

  $ hg -R client book foo -r .
  moving bookmark 'foo' forward from 79513d0d7716

#if b2-pushkey
  $ hg -R client push
  pushing to ssh://user@dummy/server
  searching for changes
  no changes found
  remote: pushkey-abort: prepushkey.no-bm-move hook exited with status 1
  abort: updating bookmark foo failed
  [255]
#endif
#if b2-binary
  $ hg -R client push
  pushing to ssh://user@dummy/server
  searching for changes
  no changes found
  remote: prepushkey.no-bm-move hook exited with status 1
  abort: push failed on remote
  [100]
#endif

-- test for pushing bookmarks pointing to secret changesets

Set up a "remote" repo
  $ hg init issue6159remote
  $ cd issue6159remote
  $ echo a > a
  $ hg add a
  $ hg commit -m_
  $ hg bookmark foo
  $ cd ..

Clone a local repo
  $ hg clone -q issue6159remote issue6159local
  $ cd issue6159local
  $ hg up -qr foo
  $ echo b > b

Move the bookmark "foo" to point at a secret changeset
  $ hg commit -qAm_ --config phases.new-commit=secret

Pushing the bookmark "foo" now fails as it contains a secret changeset
  $ hg push -r foo
  pushing to $TESTTMP/issue6159remote
  searching for changes
  no changes found (ignored 1 secret changesets)
  abort: cannot push bookmark foo as it points to a secret changeset
  [255]

Test pushing all bookmarks

  $ hg init $TESTTMP/ab1
  $ cd $TESTTMP/ab1
  $ "$PYTHON" $TESTDIR/seq.py 1 5 | while read i; do
  > echo $i > test && hg ci -Am test
  > done
  adding test
  $ hg clone -U . ../ab2
  $ hg book -r 1 A; hg book -r 2 B; hg book -r 3 C
  $ hg push ../ab2
  pushing to ../ab2
  searching for changes
  no changes found
  [1]
  $ hg push --all-bookmarks -r 1 ../ab2
  abort: cannot specify both --all-bookmarks and --rev
  [10]
  $ hg push --all-bookmarks -B A ../ab2
  abort: cannot specify both --all-bookmarks and --bookmark
  [10]
  $ hg push --all-bookmarks ../ab2
  pushing to ../ab2
  searching for changes
  no changes found
  exporting bookmark A
  exporting bookmark B
  exporting bookmark C
  [1]
