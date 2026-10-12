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
  $ AUTO_BASENAME="mercurial-managed.ini"
  $ USER_AUTO_RC="$TESTTMP\\$AUTO_BASENAME"
#else
  $ USER_RC="$TESTTMP/.hgrc"
  $ AUTO_BASENAME=".hgrc-managed"
  $ USER_AUTO_RC="$TESTTMP/$AUTO_BASENAME"
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
  > [alias]
  > # a hand written comment
  > config-set-hand-written = value-hand
  > EOF
  $ hg config --set alias.config-set-test-D=value-d
  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)
  [alias]
  # a hand written comment
  config-set-hand-written = value-hand
  $ hg config alias.config-set-hand-written
  value-hand
  $ hg config alias.config-set-test-D
  value-d

A later update still does not duplicate the include line:

  $ hg config --set alias.config-set-test-E=value-e
  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)
  [alias]
  # a hand written comment
  config-set-hand-written = value-hand

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


Checking we are smoothly integrating with existing config
=========================================================

(injecting the include when needed, and only once, is covered by the sections
above)

The include line is moved back to the top if hand edits pushed it further
down, so hand-written values keep overriding the managed ones:

  $ cat > $USER_RC <<EOF
  > [alias]
  > config-set-hand-written = value-hand
  > %include $AUTO_BASENAME
  > EOF
  $ hg config --set alias.config-set-test-H=value-h
  $ cat $USER_RC
  %include .hgrc-managed (no-windows !)
  %include mercurial-managed.ini (windows !)
  [alias]
  config-set-hand-written = value-hand
  $ hg config alias.config-set-test-H
  value-h
  $ hg config alias.config-set-hand-written
  value-hand

Updating the config of the current process
==========================================

The configuration already loaded in memory is updated too, so in-process
users running after the command (hooks, extensions, …) see the new value.

(Note that there are a few know issues with such update, like tweak default not
updating value, value transfered to the repository not being updated etc.)


basic in-memory update
----------------------

  $ cat > $TESTTMP/showlive.py <<EOF
  > import os
  > def showlive(ui, repo, **kwargs):
  >     if repo is None:
  >         baseui = None
  >     else:
  >         ui = repo.ui
  >         baseui = repo.baseui
  >     alias_name = os.environ["TEST_ALIAS_NAME"].encode("ascii")
  >     value = ui.config(b"alias", alias_name)
  >     if value is None:
  >        value = b"<unset>"
  >     ui.write(b"live value: %s\n" % value)
  >     if baseui is not None:
  >         base_value = baseui.config(b"alias", alias_name)
  >         if base_value is None:
  >            base_value = b"<unset>"
  >         ui.write(b"live value in baseui: %s\n" % base_value)
  > EOF

  $ TEST_ALIAS_NAME="config-set-live" hg -R repo \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-live=from-set
  live value: from-set
  live value in baseui: from-set

the same key set several times
------------------------------

The last value wins, overwriting the in-memory value registered for the
first one.

  $ TEST_ALIAS_NAME="config-set-live" hg -R repo \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-live=twice-1 \
  >            --set alias.config-set-live=twice-2
  live value: twice-2
  live value in baseui: twice-2

Setting a shadowed value does not affect the memory value
---------------------------------------------------------

The in-memory update respects the config priorities.


  $ cat >> repo/.hg/hgrc << EOF
  > [alias]
  > config-set-live-shadow = foo
  > EOF
  $ TEST_ALIAS_NAME="config-set-live-shadow" hg -R repo \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-live-shadow=foo-bar
  live value: foo
  live value in baseui: foo-bar
  $ hg config alias.config-set-live-shadow
  foo-bar
  $ hg config alias.config-set-live-shadow -R repo
  foo

managed file created by the command
-----------------------------------

The managed file did not exist before the command, it gets the priority
of the file that includes it.

  $ hg init fresh
  $ TEST_ALIAS_NAME="config-set-fresh" hg -R fresh \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-fresh=fresh-value
  live value: fresh-value
  live value in baseui: fresh-value

value overriding the bundled default configuration
--------------------------------------------------

The bundled resources are read before any configuration file.

  $ cat > $TESTTMP/showtool.py <<EOF
  > def showtool(ui, repo, **kwargs):
  >     value = repo.ui.config(b"merge-tools", b"kdiff3.args") or b"<unset>"
  >     ui.write(b"live tool args: %s\n" % value)
  > EOF
  $ hg -R fresh config --local --set merge-tools.kdiff3.args=custom-args \
  >     --config hooks.post-config=python:$TESTTMP/showtool.py:showtool
  live tool args: custom-args
  $ hg -R fresh config merge-tools.kdiff3.args
  custom-args

value shadowed by an %include-d file
------------------------------------

The user file includes another one, read at a higher priority than the
file itself.

  $ cat > $TESTTMP/team.rc <<EOF
  > [alias]
  > config-set-test-M = team-value
  > EOF
  $ cat >> $USER_RC <<EOF
  > %include team.rc
  > EOF
  $ TEST_ALIAS_NAME="config-set-test-M" hg \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-test-M=new-team-value
  live value: team-value
  $ hg config alias.config-set-test-M
  team-value

  $ hg init fresh2
  $ TEST_ALIAS_NAME="config-set-test-M" hg -R fresh2 \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --local --set alias.config-set-test-M=repo-value
  live value: repo-value
  live value in baseui: team-value
  $ hg config alias.config-set-test-M
  team-value
  $ hg -R fresh2 config alias.config-set-test-M
  repo-value

value ignored by plain mode
---------------------------

Plain mode ignores some items of the configuration files, so the in-memory
update ignores them too.

  $ HGPLAIN=1 TEST_ALIAS_NAME="config-set-plain" hg -R repo \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-plain=plain-value
  live value: <unset>
  live value in baseui: <unset>

  $ hg -R repo config alias.config-set-plain
  plain-value

value kept by plain mode
------------------------

  $ HGPLAIN=1 hg -R fresh \
  >     --config hooks.post-config=python:$TESTTMP/showtool.py:showtool \
  >     config --local --set merge-tools.kdiff3.args=plain-args
  live tool args: plain-args

value of a feature excepted from plain mode
-------------------------------------------

  $ HGPLAINEXCEPT=alias TEST_ALIAS_NAME="config-set-plain-except" hg -R repo \
  >     --config hooks.post-config=python:$TESTTMP/showlive.py:showlive \
  >     config --set alias.config-set-plain-except=except-value
  live value: except-value
  live value in baseui: except-value

relative path in the shared configuration
-----------------------------------------

Relative paths of the shared configuration resolve against the root of the
share, as the configuration is first read relative to it, the in-memory update
does the same.

  $ cat > $TESTTMP/showpath.py <<EOF
  > def showpath(ui, repo, **kwargs):
  >     for path in repo.ui.paths.get(b"config-set-shared", []):
  >         ui.write(b"live path: %s\n" % path.rawloc)
  > EOF
  $ cd share
  $ hg --config hooks.post-config=python:$TESTTMP/showpath.py:showpath \
  >     config --shared --set paths.config-set-shared=../celeste
  live path: $TESTTMP/celeste

  $ hg paths config-set-shared
  $TESTTMP/celeste
  $ cd ..
