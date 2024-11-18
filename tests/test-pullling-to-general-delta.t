============================================================================
Pulling from modern to a non-general delta target (and other related checks)
============================================================================

There is various issue that can arise when we update the code with modern
storage in mind while working on delta processing. So this file is meant for
various scenario that might break in the future or have break in the past.

Setup
=====

Create a modern server with an older clone

  $ cat << EOF >> $HGRCPATH
  > [command-templates]
  > log = "{desc} {tags}\n"
  > EOF

  $ hg init server

  $ hg clone --quiet --pull server client --config format.usegeneraldelta=no
  $ hg debugformat -R client generaldelta
  format-variant     repo
  generaldelta:        no

Create some complexe history

  $ cd server
  $ hg debugbuilddag -n '.+3:a$.+5:b/a:k$.+7:c/b:l$.+6:d/a:m<k+6/l+1/m'
  $ hg log -G
  o    r36 tip
  |\
  | o  r35
  | |
  | o    r34
  | |\
  | | o  r33
  | | |
  | | o  r32
  | | |
  | | o  r31
  | | |
  | | o  r30
  | | |
  | | o  r29
  | | |
  | | o  r28
  | | |
  o | |    r27 m
  |\ \ \
  | o | |  r26 d
  | | | |
  | o | |  r25
  | | | |
  | o | |  r24
  | | | |
  | o | |  r23
  | | | |
  | o | |  r22
  | | | |
  | o | |  r21
  | | | |
  | o | |  r20
  |  / /
  | o |    r19 l
  | |\ \
  | | o |  r18 c
  | | | |
  | | o |  r17
  | | | |
  | | o |  r16
  | | | |
  | | o |  r15
  | | | |
  | | o |  r14
  | | | |
  | | o |  r13
  | | | |
  | | o |  r12
  | | | |
  | | o |  r11
  | |  /
  +---o  r10 k
  | |/
  | o  r9 b
  | |
  | o  r8
  | |
  | o  r7
  | |
  | o  r6
  | |
  | o  r5
  | |
  | o  r4
  |
  o  r3 a
  |
  o  r2
  |
  o  r1
  |
  o  r0
  
  $ cd ..


Pull it in the client
=====================


pull with default value
-----------------------

  $ cp -R client client-simple-pull
  $ hg -R client-simple-pull pull
  pulling from $TESTTMP/server
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 37 changesets with 37 changes to 37 files
  new changesets 61246295ee1e:b4b117cbbcf3
  (run 'hg update' to get a working copy)
  $ hg -R client-simple-pull verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 37 changesets with 37 changes to 37 files


pull with "no-reuse" policy
---------------------------

  $ cp -R client client-no-reuse
  $ hg -R client-no-reuse pull --config paths.default:pulled-delta-reuse-policy=no-reuse
  pulling from $TESTTMP/server
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 37 changesets with 37 changes to 37 files
  new changesets 61246295ee1e:b4b117cbbcf3
  (run 'hg update' to get a working copy)
  $ hg -R client-no-reuse verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 37 changesets with 37 changes to 37 files


pull with "try-base" policy
---------------------------

  $ cp -R client client-try-base
  $ hg -R client-try-base pull --config paths.default:pulled-delta-reuse-policy=try-base
  pulling from $TESTTMP/server
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 37 changesets with 37 changes to 37 files
  new changesets 61246295ee1e:b4b117cbbcf3
  (run 'hg update' to get a working copy)
  $ hg -R client-try-base verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 37 changesets with 37 changes to 37 files


pull with "forced" policy
-------------------------

  $ cp -R client client-forced
  $ hg -R client-forced paths --config paths.default:pulled-delta-reuse-policy=forced
  default = $TESTTMP/server
  default:pulled-delta-reuse-policy = forced
  $ hg -R client-forced pull --config paths.default:pulled-delta-reuse-policy=forced
  pulling from $TESTTMP/server
  requesting all changes
  adding changesets
  adding manifests
  adding file changes
  added 37 changesets with 37 changes to 37 files
  new changesets 61246295ee1e:b4b117cbbcf3
  (run 'hg update' to get a working copy)
  $ hg -R client-forced verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 37 changesets with 37 changes to 37 files
