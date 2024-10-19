================================================
Test changing config value from the command line
================================================

  $ BCK_HGRCPATH="$HGRCPATH"
  $ unset HGRCPATH

Show files involved
===================

(we list config for "no.value" because we don't actually want to display a
value, we just care about the debug output)

Small helper to avoid unstable output depending of the host system.

  $ filter_hgrcd() {
  >    sed 's,/etc/mercurial/hgrc.d/.*\.rc,/etc/mercurial/hgrc.d/XXX.rc,' | uniq
  > }

no repo

#if windows
  $ USER_RC="$TESTTMP\\mercurial.ini"
  $ USER_AUTO_RC="$TESTTMP\\mercurial-managed.ini"
#else
  $ USER_RC="$TESTTMP/.hgrc"
  $ USER_AUTO_RC="$TESTTMP/.hgrc-managed"
#endif

#if windows
  $ hg config --debug no.item
  read config from: resource:mercurial.defaultrc.mergetools.rc
  read config from: *\python*\mercurial.ini (glob)
  read config from: $TESTTMP\mercurial.ini
  read config from: $TESTTMP\.hgrc
  read config from: $TESTTMP\mercurial.ini
  read config from: $TESTTMP\.hgrc
  [1]
#else
  $ hg config --debug no.item | filter_hgrcd
  read config from: resource:mercurial.defaultrc.mergetools.rc
  read config from: */hgtests*/install/etc/mercurial/hgrc (glob) (?)
  read config from: /usr/etc/mercurial/hgrc (?)
  read config from: /etc/mercurial/hgrc
  read config from: /etc/mercurial/hgrc.d/XXX.rc (?)
  read config from: $TESTTMP/.hgrc
  read config from: $TESTTMP/.config/hg/hgrc
#endif


no repo with HGRCPATH

  $ HGRCPATH=$BCK_HGRCPATH hg config --debug no.item
  read config from: $HGRCPATH
  [1]

with repo

  $ hg init repo
#if windows
  $ hg -R repo config --debug no.item
  read config from: resource:mercurial.defaultrc.mergetools.rc
  read config from: *\python*\mercurial.ini (glob)
  read config from: $TESTTMP\mercurial.ini
  read config from: $TESTTMP\.hgrc
  read config from: $TESTTMP\mercurial.ini
  read config from: $TESTTMP\.hgrc
  read config from: $TESTTMP\repo\.hg\hgrc
  read config from: $TESTTMP\repo\.hg\hgrc-not-shared
  [1]
#else
  $ hg -R repo config --debug no.item | filter_hgrcd
  read config from: resource:mercurial.defaultrc.mergetools.rc
  read config from: */hgtests*/install/etc/mercurial/hgrc (glob) (?)
  read config from: /usr/etc/mercurial/hgrc (?)
  read config from: /etc/mercurial/hgrc
  read config from: /etc/mercurial/hgrc.d/XXX.rc (?)
  read config from: $TESTTMP/.hgrc
  read config from: $TESTTMP/.config/hg/hgrc
  read config from: $TESTTMP/repo/.hg/hgrc
  read config from: $TESTTMP/repo/.hg/hgrc-not-shared
#endif

with share

  $ hg share --quiet repo share --config extensions.share=

#if windows
  $ hg -R share config --debug no.item
  read config from: resource:mercurial.defaultrc.mergetools.rc
  read config from: *\python*\mercurial.ini (glob)
  read config from: $TESTTMP\mercurial.ini
  read config from: $TESTTMP\.hgrc
  read config from: $TESTTMP\mercurial.ini
  read config from: $TESTTMP\.hgrc
  read config from: $TESTTMP\repo\.hg/hgrc
  read config from: $TESTTMP\share\.hg\hgrc
  read config from: $TESTTMP\share\.hg\hgrc-not-shared
  [1]
#else
  $ hg -R share config --debug no.item | filter_hgrcd
  read config from: resource:mercurial.defaultrc.mergetools.rc
  read config from: */hgtests*/install/etc/mercurial/hgrc (glob) (?)
  read config from: /usr/etc/mercurial/hgrc (?)
  read config from: /etc/mercurial/hgrc
  read config from: /etc/mercurial/hgrc.d/XXX.rc (?)
  read config from: $TESTTMP/.hgrc
  read config from: $TESTTMP/.config/hg/hgrc
  read config from: $TESTTMP/repo/.hg/hgrc
  read config from: $TESTTMP/share/.hg/hgrc
  read config from: $TESTTMP/share/.hg/hgrc-not-shared
#endif


Basic testing
=============

  $ hg config alias.config-set-test-A
  [1]

  $ hg config --set alias.config-set-test-A=value-1
  $ hg config alias.config-set-test-A
  value-1

  $ hg config --set alias.config-set-test-A=value-2
  $ hg config alias.config-set-test-A
  value-2

  $ hg config --set alias.config-set-test-B=value-x
  $ hg config alias.config-set-test-A
  value-2
  $ hg config alias.config-set-test-B
  value-x

Files written to disk
=====================

The values are stored in a machine-managed companion file; the human-edited
file only receives a single %include line pointing at it:

  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)

  $ cat $USER_AUTO_RC
  # This file is managed by Mercurial, do not edit it by hand.
  # Use `hg config --set` to change the values it holds.
  [alias]
  config-set-test-A = value-2
  config-set-test-B = value-x

Updating a value overwrites it in place (no duplicated entry) and does not
inject the %include a second time:

  $ hg config --set alias.config-set-test-A=value-3
  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)
  $ cat $USER_AUTO_RC
  # This file is managed by Mercurial, do not edit it by hand.
  # Use `hg config --set` to change the values it holds.
  [alias]
  config-set-test-A = value-3
  config-set-test-B = value-x
  $ hg config alias.config-set-test-A
  value-3

Existing hand-written content is preserved when the %include is injected:

  $ rm $USER_RC $USER_AUTO_RC
  $ cat > $USER_RC <<EOF
  > [ui]
  > # a hand written comment
  > username = Test User
  > EOF
  $ hg config --set alias.config-set-test-D=value-d
  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)
  [ui]
  # a hand written comment
  username = Test User
  $ hg config ui.username
  Test User
  $ hg config alias.config-set-test-D
  value-d

A later update still does not duplicate the include line:

  $ hg config --set alias.config-set-test-E=value-e
  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)
  [ui]
  # a hand written comment
  username = Test User

Malformed values
================

Specifications missing a value or a section are rejected with a clean error:

(HGRCPATH is unset in this file, so the test runner's detailed-exit-code=True
does not apply and the generic 255 exit code is used for InputError)

  $ hg config --set alias.config-set-test-F
  abort: malformed --set option: 'alias.config-set-test-F'
  (use --set section.name=value)
  [255]
  $ hg config --set alias=value-f
  abort: malformed --set option: 'alias=value-f'
  (use --set section.name=value)
  [255]

Checking writing to the right level
===================================

Config start empty

  $ hg config alias.config-set-test-C
  [1]

Running --local outside a repository should error

  $ hg config --local --set  alias.config-set-test-G=value-00
  abort: no "local" configuration file location known
  [255]

Updating the repo and the share independently

  $ hg -R repo config --local --set  alias.config-set-test-G=value-01
  $ hg -R share config --local --set  alias.config-set-test-G=value-02
  $ hg config alias.config-set-test-G
  [1]
  $ hg -R repo config alias.config-set-test-G
  value-01
  $ hg -R share config alias.config-set-test-G
  value-02

The user level is the default, even within a repository:

  $ hg -R repo config --set alias.config-set-test-H=value-h
  $ hg config alias.config-set-test-H
  value-h
  $ hg -R repo config alias.config-set-test-H
  value-h
