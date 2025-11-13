==================================================
Tests for "delta-info" specific feature of revlogs
==================================================



  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-delta-info-flags=yes
  > sparse-revlog = yes
  > [storage]
  > revlog-compression=none
  > revlog.optimize-delta-parent-choice = yes
  > revlog.reuse-external-delta-parent = no
  > revlog.reuse-external-delta = no
  > revlog.reuse-external-delta-compression = no
  > delta-fold-estimate = always
  > EOF


Check that we can control delta-quality storage
===============================================

  $ hg init with-quality
  $ hg -R with-quality debugformat delta-info
  format-variant                 repo
  delta-info-flags:               yes
  $ cat << EOF >> with-quality/.hg/hgrc
  > [storage]
  > revlog.record-delta-quality=yes
  > EOF
  $ hg init no-quality
  $ hg -R no-quality debugformat delta-info
  format-variant                 repo
  delta-info-flags:               yes
  $ cat << EOF >> no-quality/.hg/hgrc
  > [storage]
  > revlog.record-delta-quality=no
  > EOF


quality flag should be stored

  $ "$RUNTESTDIR/seq.py" 100 > with-quality/file
  $ hg -R with-quality add with-quality/file
  $ hg -R with-quality commit -m 'base'
  $ echo foo >> with-quality/file
  $ hg -R with-quality commit -m 'update'
  $ hg -R with-quality debugindex file -v -T'{rev} {nodeid} {flags}\n'
  0 5f215a9162b2 1024
  1 cdf8529500f8 896

quality flag should not be stored

  $ "$RUNTESTDIR/seq.py" 100 > no-quality/file
  $ hg -R no-quality add no-quality/file
  $ hg -R no-quality commit -m 'base'
  $ echo foo >> no-quality/file
  $ hg -R no-quality commit -m 'update'
  $ hg -R no-quality debugindex file -v -T'{rev} {nodeid} {flags}\n'
  0 5f215a9162b2 1024
  1 cdf8529500f8 0
