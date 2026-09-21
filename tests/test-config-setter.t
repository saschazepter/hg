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
