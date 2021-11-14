#require no-reposimplestore
#testcases revlogv1 revlogv2

#if revlogv2

  $ cat >> $HGRCPATH <<EOF
  > [experimental]
  > revlogv2=enable-unstable-format-and-corrupt-my-data
  > EOF

#endif

  $ cat >> $HGRCPATH <<EOF
  > [extensions]
  > censor=
  > EOF
  $ cp $HGRCPATH $HGRCPATH.orig

Create repo with unimpeachable content

  $ hg init r
  $ cd r
  $ echo 'Initially untainted file' > target
  $ echo 'Normal file here' > bystander
  $ hg add target bystander
  $ hg ci -m init

Clone repo so we can test pull later

  $ cd ..
  $ hg clone r rpull
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd r

Introduce content which will ultimately require censorship. Name the first
censored node C1, second C2, and so on

  $ echo 'Tainted file' > target
  $ echo 'Passwords: hunter2' >> target
  $ hg ci -m taint target
  $ C1=`hg id --debug -i`

  $ echo 'hunter3' >> target
  $ echo 'Normal file v2' > bystander
  $ hg ci -m moretaint target bystander
  $ C2=`hg id --debug -i`

Add a new sanitized versions to correct our mistake. Name the first head H1,
the second head H2, and so on

  $ echo 'Tainted file is now sanitized' > target
  $ hg ci -m sanitized target
  $ H1=`hg id --debug -i`

  $ hg update -r $C2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ echo 'Tainted file now super sanitized' > target
  $ hg ci -m 'super sanitized' target
  created new head
  $ H2=`hg id --debug -i`

Verify target contents before censorship at each revision

  $ hg cat -r $H1 target | head -n 10
  Tainted file is now sanitized
  $ hg cat -r $H2 target | head -n 10
  Tainted file now super sanitized
  $ hg cat -r $C2 target | head -n 10
  Tainted file
  Passwords: hunter2
  hunter3
  $ hg cat -r $C1 target | head -n 10
  Tainted file
  Passwords: hunter2
  $ hg cat -r 0 target | head -n 10
  Initially untainted file

Censor revision with 2 offenses

(this also tests file pattern matching: path relative to cwd case)

  $ mkdir -p foo/bar/baz
  $ hg --cwd foo/bar/baz censor -r $C2 -t "remove password" ../../../target
  $ hg cat -r $H1 target | head -n 10
  Tainted file is now sanitized
  $ hg cat -r $H2 target | head -n 10
  Tainted file now super sanitized
  $ hg cat -r $C2 target | head -n 10
  abort: censored node: 1e0247a9a4b7
  (set censor.policy to ignore errors)
  $ hg cat -r $C1 target | head -n 10
  Tainted file
  Passwords: hunter2
  $ hg cat -r 0 target | head -n 10
  Initially untainted file

Censor revision with 1 offense

(this also tests file pattern matching: with 'path:' scheme)

  $ hg --cwd foo/bar/baz censor -r $C1 path:target
  $ hg cat -r $H1 target | head -n 10
  Tainted file is now sanitized
  $ hg cat -r $H2 target | head -n 10
  Tainted file now super sanitized
  $ hg cat -r $C2 target | head -n 10
  abort: censored node: 1e0247a9a4b7
  (set censor.policy to ignore errors)
  $ hg cat -r $C1 target | head -n 10
  abort: censored node: 613bc869fceb
  (set censor.policy to ignore errors)
  $ hg cat -r 0 target | head -n 10
  Initially untainted file

Can only checkout target at uncensored revisions, -X is workaround for --all

  $ hg revert -r $C2 target | head -n 10
  abort: censored node: 1e0247a9a4b7
  (set censor.policy to ignore errors)
  $ hg revert -r $C1 target | head -n 10
  abort: censored node: 613bc869fceb
  (set censor.policy to ignore errors)
  $ hg revert -r $C1 --all
  reverting bystander
  reverting target
  abort: censored node: 613bc869fceb
  (set censor.policy to ignore errors)
  [255]
  $ hg revert -r $C1 --all -X target
  $ cat target | head -n 10
  Tainted file now super sanitized
  $ hg revert -r 0 --all
  reverting target
  $ cat target | head -n 10
  Initially untainted file
  $ hg revert -r $H2 --all
  reverting bystander
  reverting target
  $ cat target | head -n 10
  Tainted file now super sanitized

Uncensored file can be viewed at any revision

  $ hg cat -r $H1 bystander | head -n 10
  Normal file v2
  $ hg cat -r $C2 bystander | head -n 10
  Normal file v2
  $ hg cat -r $C1 bystander | head -n 10
  Normal file here
  $ hg cat -r 0 bystander | head -n 10
  Normal file here

Can update to children of censored revision

  $ hg update -r $H1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Tainted file is now sanitized
  $ hg update -r $H2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Tainted file now super sanitized

Set censor policy to abort in trusted $HGRC so hg verify fails

  $ cp $HGRCPATH.orig $HGRCPATH
  $ cat >> $HGRCPATH <<EOF
  > [censor]
  > policy = abort
  > EOF

Repo fails verification due to censorship

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
   target@1: censored file data
   target@2: censored file data
  checked 5 changesets with 7 changes to 2 files
  2 integrity errors encountered!
  (first damaged changeset appears to be 1)
  [1]

Cannot update to revision with censored data

  $ hg update -r $C2
  abort: censored node: 1e0247a9a4b7
  (set censor.policy to ignore errors)
  [255]
  $ hg update -r $C1
  abort: censored node: 613bc869fceb
  (set censor.policy to ignore errors)
  [255]
  $ hg update -r 0
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg update -r $H2
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved

Set censor policy to ignore in trusted $HGRC so hg verify passes

  $ cp $HGRCPATH.orig $HGRCPATH
  $ cat >> $HGRCPATH <<EOF
  > [censor]
  > policy = ignore
  > EOF

Repo passes verification with warnings with explicit config

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 5 changesets with 7 changes to 2 files

May update to revision with censored data with explicit config

  $ hg update -r $C2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  $ hg update -r $C1
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  $ hg update -r 0
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Initially untainted file
  $ hg update -r $H2
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Tainted file now super sanitized

Can merge in revision with censored data. Test requires one branch of history
with the file censored, but we can't censor at a head, so advance H1.

  $ hg update -r $H1
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ C3=$H1
  $ echo 'advanced head H1' > target
  $ hg ci -m 'advance head H1' target
  $ H1=`hg id --debug -i`
  $ hg censor -r $C3 target
  $ hg update -r $H2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg merge -r $C3
  merging target
  0 files updated, 1 files merged, 0 files removed, 0 files unresolved
  (branch merge, don't forget to commit)

Revisions present in repository heads may not be censored

  $ hg update -C -r $H2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg censor -r $H2 target
  abort: cannot censor file in heads (78a8fc215e79)
  (clean/delete and commit first)
  [255]
  $ echo 'twiddling thumbs' > bystander
  $ hg ci -m 'bystander commit'
  $ H2=`hg id --debug -i`
  $ hg censor -r "$H2^" target
  abort: cannot censor file in heads (efbe78065929)
  (clean/delete and commit first)
  [255]

Cannot censor working directory

  $ echo 'seriously no passwords' > target
  $ hg ci -m 'extend second head arbitrarily' target
  $ H2=`hg id --debug -i`
  $ hg update -r "$H2^"
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ hg censor -r . target
  abort: cannot censor working directory
  (clean/delete/update first)
  [255]
  $ hg update -r $H2
  1 files updated, 0 files merged, 0 files removed, 0 files unresolved

Can re-add file after being deleted + censored

  $ C4=$H2
  $ hg rm target
  $ hg ci -m 'delete target so it may be censored'
  $ H2=`hg id --debug -i`
  $ hg censor -r $C4 target
  $ hg cat -r $C4 target | head -n 10
  $ hg cat -r "$H2^^" target | head -n 10
  Tainted file now super sanitized
  $ echo 'fresh start' > target
  $ hg add target
  $ hg ci -m reincarnated target
  $ H2=`hg id --debug -i`
  $ hg cat -r $H2 target | head -n 10
  fresh start
  $ hg cat -r "$H2^" target | head -n 10
  target: no such file in rev 452ec1762369
  $ hg cat -r $C4 target | head -n 10
  $ hg cat -r "$H2^^^" target | head -n 10
  Tainted file now super sanitized

Can censor after revlog has expanded to no longer permit inline storage

  $ for x in `"$PYTHON" $TESTDIR/seq.py 0 50000`
  > do
  >   echo "Password: hunter$x" >> target
  > done
  $ hg ci -m 'add 100k passwords'
  $ H2=`hg id --debug -i`
  $ C5=$H2
  $ hg revert -r "$H2^" target
  $ hg ci -m 'cleaned 100k passwords'
  $ H2=`hg id --debug -i`
  $ hg censor -r $C5 target
  $ hg cat -r $C5 target | head -n 10
  $ hg cat -r $H2 target | head -n 10
  fresh start

Repo with censored nodes can be cloned and cloned nodes are censored

  $ cd ..
  $ hg clone r rclone
  updating to branch default
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cd rclone
  $ hg cat -r $H1 target | head -n 10
  advanced head H1
  $ hg cat -r $H2~5 target | head -n 10
  Tainted file now super sanitized
  $ hg cat -r $C2 target | head -n 10
  $ hg cat -r $C1 target | head -n 10
  $ hg cat -r 0 target | head -n 10
  Initially untainted file
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 12 changesets with 13 changes to 2 files

Repo cloned before tainted content introduced can pull censored nodes

  $ cd ../rpull
  $ hg cat -r tip target | head -n 10
  Initially untainted file
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 1 changesets with 2 changes to 2 files
  $ hg pull -r $H1 -r $H2
  pulling from $TESTTMP/r
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 11 changesets with 11 changes to 2 files (+1 heads)
  new changesets 186fb27560c3:683e4645fded
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg update 4
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Tainted file now super sanitized
  $ hg cat -r $H1 target | head -n 10
  advanced head H1
  $ hg cat -r $H2~5 target | head -n 10
  Tainted file now super sanitized
  $ hg cat -r $C2 target | head -n 10
  $ hg cat -r $C1 target | head -n 10
  $ hg cat -r 0 target | head -n 10
  Initially untainted file
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 12 changesets with 13 changes to 2 files

Censored nodes can be pushed if they censor previously unexchanged nodes

  $ echo 'Passwords: hunter2hunter2' > target
  $ hg ci -m 're-add password from clone' target
  created new head
  $ H3=`hg id --debug -i`
  $ REV=$H3
  $ echo 'Re-sanitized; nothing to see here' > target
  $ hg ci -m 're-sanitized' target
  $ H2=`hg id --debug -i`
  $ CLEANREV=$H2
  $ hg cat -r $REV target | head -n 10
  Passwords: hunter2hunter2
  $ hg censor -r $REV target
  $ hg cat -r $REV target | head -n 10
  $ hg cat -r $CLEANREV target | head -n 10
  Re-sanitized; nothing to see here
  $ hg push -f -r $H2
  pushing to $TESTTMP/r
  searching for changes
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 1 files (+1 heads)

  $ cd ../r
  $ hg cat -r $REV target | head -n 10
  $ hg cat -r $CLEANREV target | head -n 10
  Re-sanitized; nothing to see here
  $ hg update $CLEANREV
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Re-sanitized; nothing to see here

Censored nodes can be bundled up and unbundled in another repo

  $ hg bundle --base 0 ../pwbundle
  13 changesets found
  $ cd ../rclone
  $ hg unbundle ../pwbundle
  adding changesets
  adding manifests
  adding file changes
  added 2 changesets with 2 changes to 2 files (+1 heads)
  new changesets 075be80ac777:dcbaf17bf3a1 (2 drafts)
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg cat -r $REV target | head -n 10
  $ hg cat -r $CLEANREV target | head -n 10
  Re-sanitized; nothing to see here
  $ hg update $CLEANREV
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Re-sanitized; nothing to see here
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 14 changesets with 15 changes to 2 files

Grepping only warns, doesn't error out

  $ cd ../rpull
  $ hg grep 'Normal file'
  bystander:Normal file v2
  $ hg grep nothing
  target:Re-sanitized; nothing to see here
  $ hg grep --diff 'Normal file'
  cannot search in censored file: target:7
  cannot search in censored file: target:10
  cannot search in censored file: target:12
  bystander:6:-:Normal file v2
  cannot search in censored file: target:1
  cannot search in censored file: target:2
  cannot search in censored file: target:3
  bystander:2:-:Normal file here
  bystander:2:+:Normal file v2
  bystander:0:+:Normal file here
  $ hg grep --diff nothing
  cannot search in censored file: target:7
  cannot search in censored file: target:10
  cannot search in censored file: target:12
  target:13:+:Re-sanitized; nothing to see here
  cannot search in censored file: target:1
  cannot search in censored file: target:2
  cannot search in censored file: target:3

Censored nodes can be imported on top of censored nodes, consecutively

  $ hg init ../rimport
  $ hg bundle --base 1 ../rimport/splitbundle
  12 changesets found
  $ cd ../rimport
  $ hg pull -r $H1 -r $H2 ../r
  pulling from ../r
  adding changesets
  adding manifests
  adding file changes
  added 8 changesets with 10 changes to 2 files (+1 heads)
  new changesets e97f55b2665a:dcbaf17bf3a1
  (run 'hg heads' to see heads, 'hg merge' to merge)
  $ hg unbundle splitbundle
  adding changesets
  adding manifests
  adding file changes
  added 6 changesets with 5 changes to 2 files (+1 heads)
  new changesets efbe78065929:683e4645fded (6 drafts)
  (run 'hg heads .' to see heads, 'hg merge' to merge)
  $ hg update $H2
  2 files updated, 0 files merged, 0 files removed, 0 files unresolved
  $ cat target | head -n 10
  Re-sanitized; nothing to see here
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checked 14 changesets with 15 changes to 2 files
  $ cd ../r

Can import bundle where first revision of a file is censored

  $ hg init ../rinit
  $ hg censor -r 0 target
  $ hg bundle -r 0 --base null ../rinit/initbundle
  1 changesets found
  $ cd ../rinit
  $ hg unbundle initbundle
  adding changesets
  adding manifests
  adding file changes
  added 1 changesets with 2 changes to 2 files
  new changesets e97f55b2665a (1 drafts)
  (run 'hg update' to get a working copy)
  $ hg cat -r 0 target | head -n 10

#if revlogv2

Testing feature that does not work in revlog v1
===============================================

Censoring a revision that is used as delta base
-----------------------------------------------

  $ cd ..
  $ hg init censor-with-delta
  $ cd censor-with-delta
  $ echo root > target
  $ hg add target
  $ hg commit -m root
  $ B0=`hg id --debug -i`
  $ for x in `"$PYTHON" $TESTDIR/seq.py 0 50000`
  > do
  >   echo "Password: hunter$x" >> target
  > done
  $ hg ci -m 'write a long file'
  $ B1=`hg id --debug -i`
  $ echo 'small change (should create a delta)' >> target
  $ hg ci -m 'create a delta over the password'
(should show that the last revision is a delta, not a snapshot)
  $ B2=`hg id --debug -i`

Make sure the last revision is a delta against the revision we will censor

  $ hg debugdeltachain target -T '{rev} {chainid} {chainlen} {prevrev}\n'
  0 1 1 -1
  1 2 1 -1
  2 2 2 1

Censor the file

  $ hg cat -r $B1 target | wc -l
   *50002 (re)
  $ hg censor -r $B1 target
  $ hg cat -r $B1 target | wc -l
   *0 (re)

Check the children is fine

  $ hg cat -r $B2 target | wc -l
   *50003 (re)

#endif
