Test the "plain encoding" feature
=================================

This test the "plain" encoding for store where not much is actually encoding for filelog


Setup
-----


  $ cat >> $HGRCPATH << EOF
  > [format]
  > dotencode=no
  > exp-use-very-fragile-and-unsafe-plain-store-encoding=yes
  > EOF


Create a plain-encoded repository

  $ hg init plain-encoded
  $ cd plain-encoded

create some files and directory

  $ echo foo > foo
  $ mkdir toto
  $ echo bar > toto/bar
  $ mkdir toto/tutu
  $ echo fuz > toto/tutu/fuz
  $ mkdir rc.d
  $ echo baz >rc.d/baz
  $ hg addremove .
  adding foo
  adding rc.d/baz
  adding toto/bar
  adding toto/tutu/fuz
  $ hg commit -m 'initial commit'

verify that basic operations works
----------------------------------

  $ hg export
  # HG changeset patch
  # User test
  # Date 0 0
  #      Thu Jan 01 00:00:00 1970 +0000
  # Node ID b41a27cd96f26122b2178745540aa1f515bb02f3
  # Parent  0000000000000000000000000000000000000000
  initial commit
  
  diff -r 000000000000 -r b41a27cd96f2 foo
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/foo	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +foo
  diff -r 000000000000 -r b41a27cd96f2 rc.d/baz
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/rc.d/baz	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +baz
  diff -r 000000000000 -r b41a27cd96f2 toto/bar
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/toto/bar	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +bar
  diff -r 000000000000 -r b41a27cd96f2 toto/tutu/fuz
  --- /dev/null	Thu Jan 01 00:00:00 1970 +0000
  +++ b/toto/tutu/fuz	Thu Jan 01 00:00:00 1970 +0000
  @@ -0,0 +1,1 @@
  +fuz

  $ hg cat -r 0 rc.d/baz
  baz

  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 1 changesets with 4 changes to 4 files
  $ cd ..

verify that thing listing the repository content works
------------------------------------------------------


local clone

  $ hg clone plain-encoded local-cloned --debug --noupdate
  linked 10 files (no-rust !)
  linked 12 files (rust !)
  updating the branch cache
  $ hg verify -R local-cloned
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 1 changesets with 4 changes to 4 files
  $ hg update -R local-cloned
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved

stream clone

  $ hg clone --stream ssh://user@dummy/plain-encoded stream-cloned --noupdate
  streaming all changes
  10 files to transfer, * (glob) (no-rust !)
  stream-cloned 10 files / * (glob) (no-rust !)
  12 files to transfer, * (glob) (rust !)
  stream-cloned 12 files / * (glob) (rust !)
  $ hg verify -R stream-cloned
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 1 changesets with 4 changes to 4 files
  $ hg update -R stream-cloned
  4 files updated, 0 files merged, 0 files removed, 0 files unresolved

Verify store layout
-------------------

  $ cd plain-encoded

  $ f --recurse .hg/store/data
  .hg/store/data: directory with 3 files
  .hg/store/data/foo.i:
  .hg/store/data/rc.d_: directory with 1 files
  .hg/store/data/rc.d_/baz.i:
  .hg/store/data/toto_: directory with 2 files
  .hg/store/data/toto_/bar.i:
  .hg/store/data/toto_/tutu_: directory with 1 files
  .hg/store/data/toto_/tutu_/fuz.i:

Downgrade/Upgrade
-----------------

downgrade

  $ hg debugformat fragile-plain-encode dotencode fncache
  format-variant                 repo
  fncache:                        yes
  dotencode:                       no
  fragile-plain-encode:           yes
  $ hg debugupgraderepo --quiet --run \
  >     --config format.dotencode=yes \
  >     --config format.exp-use-very-fragile-and-unsafe-plain-store-encoding=no
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: exp-very-fragile-and-unsafe-plain-store-encoding
     added: dotencode
  
  processed revlogs:
    - all-filelogs
  
  $ hg debugformat fragile-plain-encode dotencode fncache
  format-variant                 repo
  fncache:                        yes
  dotencode:                      yes
  fragile-plain-encode:            no
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 1 changesets with 4 changes to 4 files

upgrade

  $ hg debugformat fragile-plain-encode dotencode fncache
  format-variant                 repo
  fncache:                        yes
  dotencode:                      yes
  fragile-plain-encode:            no
  $ hg debugupgraderepo --quiet --run \
  >     --config format.dotencode=no \
  >     --config format.exp-use-very-fragile-and-unsafe-plain-store-encoding=yes
  upgrade will perform the following actions:
  
  requirements
     preserved: * (glob)
     removed: dotencode
     added: exp-very-fragile-and-unsafe-plain-store-encoding
  
  processed revlogs:
    - all-filelogs
  
  $ hg debugformat fragile-plain-encode dotencode fncache
  format-variant                 repo
  fncache:                        yes
  dotencode:                       no
  fragile-plain-encode:           yes
  $ hg verify
  checking changesets
  checking manifests
  crosschecking files in changesets and manifests
  checking files
  checking dirstate
  checked 1 changesets with 4 changes to 4 files
