==================================
Basic testing for the push command
==================================

Testing of the '--rev' flag
===========================

  $ hg init test-revflag
  $ hg -R test-revflag unbundle "$TESTDIR/bundles/remote.hg"
  adding changesets
  adding manifests
  adding file changes
  added 9 changesets with 7 changes to 4 files (+1 heads)
  new changesets bfaf4b5cbf01:916f1afdef90 (9 drafts)
  (run 'hg heads' to see heads, 'hg merge' to merge)

  $ for i in 0 1 2 3 4 5 6 7 8; do
  >    echo
  >    hg init test-revflag-"$i"
  >    hg -R test-revflag push -r "$i" test-revflag-"$i"
  >    hg -R test-revflag-"$i" verify
  > done
  
  pushing to test-revflag-0
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 1 changesets with 1 changes to 1 files
  
  pushing to test-revflag-1
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 1 files
  
  pushing to test-revflag-2
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 3 changes to 1 files
  
  pushing to test-revflag-3
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 4 changes to 1 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 4 changes to 1 files
  
  pushing to test-revflag-4
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 2 changesets with 2 changes to 1 files
  
  pushing to test-revflag-5
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 3 changesets with 3 changes to 1 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 3 changesets with 3 changes to 1 files
  
  pushing to test-revflag-6
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 5 changes to 2 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 4 changesets with 5 changes to 2 files
  
  pushing to test-revflag-7
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 6 changes to 3 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 5 changesets with 6 changes to 3 files
  
  pushing to test-revflag-8
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 5 changesets with 5 changes to 2 files
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 5 changesets with 5 changes to 2 files

  $ cd test-revflag-8

  $ hg pull ../test-revflag-7
  pulling from ../test-revflag-7
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 4 changesets with 2 changes to 3 files (+1 heads)
  new changesets c70afb1ee985:faa2e4234c7a
  (run 'hg heads' to see heads, 'hg merge' to merge)

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 9 changesets with 7 changes to 4 files

  $ cd ..

Test server side validation during push
=======================================

  $ hg init test-validation
  $ cd test-validation

  $ cat > .hg/hgrc <<EOF
  > [server]
  > validate=1
  > EOF

  $ echo alpha > alpha
  $ echo beta > beta
  $ hg addr
  adding alpha
  adding beta
  $ hg ci -m 1

  $ cd ..
  $ hg clone test-validation test-validation-clone
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

#if reporevlogstore

Test spurious filelog entries:

  $ cd test-validation-clone
  $ echo blah >> beta
  $ cp .hg/store/data/beta.i tmp1
  $ hg ci -m 2
  $ cp .hg/store/data/beta.i tmp2
  $ hg -q rollback
  $ mv tmp2 .hg/store/data/beta.i
  $ echo blah >> beta
  $ hg ci -m '2 (corrupt)'

Expected to fail:

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
   beta@1: dddc47b3ba30 not in manifests
  checked 2 changesets with 4 changes to 2 files
  1 integrity errors encountered!
  (first damaged changeset appears to be 1)
  [1]

  $ hg push
  pushing to $TESTTMP/test-validation
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  transaction abort!
  rollback completed
  abort: received spurious file revlog entry
  [255]

  $ hg -q rollback
  $ mv tmp1 .hg/store/data/beta.i
  $ echo beta > beta

Test missing filelog entries:

  $ cp .hg/store/data/beta.i tmp
  $ echo blah >> beta
  $ hg ci -m '2 (corrupt)'
  $ mv tmp .hg/store/data/beta.i

Expected to fail:

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
   beta@1: manifest refers to unknown revision dddc47b3ba30
  checked 2 changesets with 2 changes to 2 files
  1 integrity errors encountered!
  (first damaged changeset appears to be 1)
  [1]

  $ hg push
  pushing to $TESTTMP/test-validation
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  transaction abort!
  rollback completed
  abort: missing file data for beta:dddc47b3ba30e54484720ce0f4f768a0f4b6efb9 - run hg verify
  [255]

  $ cd ..

#endif

Test push hook locking
=====================

  $ hg init 1

  $ echo '[ui]' >> 1/.hg/hgrc
  $ echo 'timeout = 10' >> 1/.hg/hgrc

  $ echo foo > 1/foo
  $ hg --cwd 1 ci -A -m foo
  adding foo

  $ hg clone 1 2
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ hg clone 2 3
  updating to branch default
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

  $ cat <<EOF > $TESTTMP/debuglocks-pretxn-hook.sh
  > hg debuglocks
  > true
  > EOF
  $ echo '[hooks]' >> 2/.hg/hgrc
  $ echo "pretxnchangegroup.a = sh $TESTTMP/debuglocks-pretxn-hook.sh" >> 2/.hg/hgrc
  $ echo 'changegroup.push = hg push -qf ../1' >> 2/.hg/hgrc

  $ echo bar >> 3/foo
  $ hg --cwd 3 ci -m bar

  $ hg --cwd 3 push ../2 --config devel.legacy.exchange=bundle1
  pushing to ../2
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  lock:  user *, process * (*s) (glob)
  wlock: free
  added 1 changesets with 1 changes to 1 files

  $ hg --cwd 1 --config extensions.strip= strip tip -q
  $ hg --cwd 2 --config extensions.strip= strip tip -q
  $ hg --cwd 3 push ../2 # bundle2+
  pushing to ../2
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  lock:  user *, process * (*s) (glob)
  wlock: user *, process * (*s) (glob)
  added 1 changesets with 1 changes to 1 files

Test bare push with multiple race checking options
--------------------------------------------------

  $ hg init test-bare-push-no-concurrency
  $ hg init test-bare-push-unrelated-concurrency
  $ hg -R test-revflag push -r 0 test-bare-push-no-concurrency --config server.concurrent-push-mode=strict
  pushing to test-bare-push-no-concurrency
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ hg -R test-revflag push -r 0 test-bare-push-unrelated-concurrency --config server.concurrent-push-mode=check-related
  pushing to test-bare-push-unrelated-concurrency
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files

SEC: check for unsafe ssh url

  $ cat >> $HGRCPATH << EOF
  > [ui]
  > ssh = sh -c "read l; read l; read l"
  > EOF

  $ hg -R test-revflag push 'ssh://-oProxyCommand=touch${IFS}owned/path'
  pushing to ssh://-oProxyCommand%3Dtouch%24%7BIFS%7Downed/path
  abort: potentially unsafe url: 'ssh://-oProxyCommand=touch${IFS}owned/path'
  [255]
  $ hg -R test-revflag push 'ssh://%2DoProxyCommand=touch${IFS}owned/path'
  pushing to ssh://-oProxyCommand%3Dtouch%24%7BIFS%7Downed/path
  abort: potentially unsafe url: 'ssh://-oProxyCommand=touch${IFS}owned/path'
  [255]
  $ hg -R test-revflag push 'ssh://fakehost|touch${IFS}owned/path'
  pushing to ssh://fakehost%7Ctouch%24%7BIFS%7Downed/path
  abort: no suitable response from remote hg
  [255]
  $ hg -R test-revflag push 'ssh://fakehost%7Ctouch%20owned/path'
  pushing to ssh://fakehost%7Ctouch%20owned/path
  abort: no suitable response from remote hg
  [255]

  $ [ ! -f owned ] || echo 'you got owned'

Test `commands.push.require-revs`
---------------------------------

  $ hg clone -q test-revflag test-require-revs-source
  $ hg init test-require-revs-dest
  $ cd test-require-revs-source
  $ cat >> .hg/hgrc << EOF
  > [paths]
  > default = ../test-require-revs-dest
  > [commands]
  > push.require-revs=1
  > EOF
  $ hg push
  pushing to $TESTTMP/test-require-revs-dest
  abort: no revisions specified to push
  (did you mean "hg push -r ."?)
  [10]
  $ hg push -r 0
  pushing to $TESTTMP/test-require-revs-dest
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 1 changes to 1 files
  $ hg bookmark -r 0 push-this-bookmark
(test that -B (bookmark) works for specifying "revs")
  $ hg push -B push-this-bookmark
  pushing to $TESTTMP/test-require-revs-dest
  searching for changes
  no changes found
  exporting bookmark push-this-bookmark
  [1]
(test that -b (branch)  works for specifying "revs")
  $ hg push -b default
  pushing to $TESTTMP/test-require-revs-dest
  searching for changes
  abort: push creates new remote head [0-9a-f]+ (re)
  (merge or see 'hg help push' for details about pushing new heads)
  [20]
(demonstrate that even though we don't have anything to exchange, we're still
showing the error)
  $ hg push
  pushing to $TESTTMP/test-require-revs-dest
  abort: no revisions specified to push
  (did you mean "hg push -r ."?)
  [10]
  $ hg push --config paths.default:pushrev=0
  pushing to $TESTTMP/test-require-revs-dest
  searching for changes
  no changes found
  [1]
