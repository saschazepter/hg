===============================
Test validation when unbundling
===============================

This file tests that hg validates incoming bundles when configured correctly.

Set up repo and corruption script
---------------------------------

The file is large enough for incoming deltas to be stored as is.

  $ hg init src
  $ cd src
  $ "$PYTHON" $TESTDIR/seq.py 1 1000 > f
  $ hg commit -qAm cAc
  $ ("$PYTHON" $TESTDIR/seq.py 1 499; echo world; "$PYTHON" $TESTDIR/seq.py 501 1000) > f
  $ hg commit -qm cBc
  $ ("$PYTHON" $TESTDIR/seq.py 1 499; echo world; "$PYTHON" $TESTDIR/seq.py 501 799; echo babar; "$PYTHON" $TESTDIR/seq.py 801 1000) > f
  $ hg commit -qm cCc
  $ cd ..

  $ cat > corrupt.py <<EOF
  > import sys
  > src, dst = sys.argv[1:]
  > data = open(src, 'rb').read()
  > assert data.count(b'world') == 1
  > open(dst, 'wb').write(data.replace(b'world', b'wurld'))
  > EOF

  $ hg -R src bundle -q --base null -r 'desc("cBc")' \
  >   -t 'none-v2;cg.version=03' delta.hg
  $ "$PYTHON" corrupt.py delta.hg bad-delta.hg
  $ hg -R src bundle -q --base null -r 'desc("cBc")' \
  >   -t 'none-v2;cg.version=03' full.hg --config devel.bundle.delta=full
  $ "$PYTHON" corrupt.py full.hg bad-full.hg
  $ hg -R src bundle -q --base null -r 'desc("cBc")' \
  >   -t 'none-v2;cg.version=04' full-v4.hg --config devel.bundle.delta=full
  $ "$PYTHON" corrupt.py full-v4.hg bad-full-v4.hg
  $ hg -R src bundle -q --base 'desc("cBc")' -r 'desc("cCc")' \
  >   -t 'none-v2;cg.version=03' next.hg

Without validation, the corruption is stored silently.

  $ hg init dst-corrupt
  $ hg -R dst-corrupt unbundle -q bad-delta.hg
  $ hg -R dst-corrupt log -T '{desc}\n'
  cBc
  cAc

Validating delta bases
======================

`storage.revlog.validate-delta-base` checks the bases deltas are computed
against. For historical reason, it also enables
`storage.revlog.validate-incoming-content` by default, the cases below disable
it to only show the checks of the delta bases.

Test a corrupt delta
--------------------

Only the base is checked, not the incoming revision.

  $ hg init dst-delta
  $ hg -R dst-delta unbundle -q bad-delta.hg \
  >   --config storage.revlog.reuse-external-delta=no \
  >   --config storage.revlog.validate-delta-base=yes \
  >   --config storage.revlog.validate-incoming-content=no
  $ hg -R dst-delta log -T '{desc}\n'
  cBc
  cAc

Test a corrupt delta stored as is
---------------------------------

Nothing rebuilds the full text of a delta stored as is, so nothing is checked.

  $ hg init dst-delta-as-is
  $ hg -R dst-delta-as-is unbundle -q bad-delta.hg \
  >   --config storage.revlog.validate-delta-base=yes \
  >   --config storage.revlog.validate-incoming-content=no
  $ hg -R dst-delta-as-is log -T '{desc}\n'
  cBc
  cAc

Test a corrupt full text
------------------------

  $ hg init dst-full
  $ hg -R dst-full unbundle -q bad-full.hg \
  >   --config storage.revlog.validate-delta-base=yes \
  >   --config storage.revlog.validate-incoming-content=no
  $ hg -R dst-full log -T '{desc}\n'
  cBc
  cAc

Test a corrupt full text with changegroup v4
--------------------------------------------

Changegroup v4 sends full texts as is, instead of deltas against the null
revision, so nothing rebuilds them and nothing is checked.

XXX: reusing the incoming deltas crashes on such full texts, so this disables
it.

  $ hg init dst-full-v4
  $ hg -R dst-full-v4 unbundle -q bad-full-v4.hg \
  >   --config storage.revlog.reuse-external-delta=no \
  >   --config storage.revlog.validate-delta-base=yes \
  >   --config storage.revlog.validate-incoming-content=no
  $ hg -R dst-full-v4 log -T '{desc}\n'
  cBc
  cAc

Test a corrupt delta base
-------------------------

  $ hg clone -q -U dst-corrupt dst-base
  $ hg -R dst-base unbundle -q next.hg \
  >   --config storage.revlog.reuse-external-delta=no \
  >   --config storage.revlog.validate-delta-base=yes \
  >   --config storage.revlog.validate-incoming-content=no
  transaction abort!
  rollback completed
  abort: integrity check failed on f:1
  [50]
  $ hg -R dst-base log -T '{desc}\n'
  cBc
  cAc

Test the default of incoming validation
---------------------------------------

Without explicit configuration, the incoming revision is checked too.

  $ hg init dst-delta-default
  $ hg -R dst-delta-default unbundle -q bad-delta.hg \
  >   --config storage.revlog.reuse-external-delta=no \
  >   --config storage.revlog.validate-delta-base=yes
  transaction abort!
  rollback completed
  abort: integrity check failed on f:11f271f9a74d
  [50]
  $ hg -R dst-delta-default log -T '{desc}\n'

Validating incoming content
===========================

`storage.revlog.validate-incoming-content` checks the incoming revisions.

  $ cat >> $HGRCPATH <<EOF
  > [storage]
  > revlog.validate-incoming-content = yes
  > EOF

Test a corrupt delta
--------------------

  $ hg init dst-incoming-delta
  $ hg -R dst-incoming-delta unbundle -q bad-delta.hg \
  >   --config storage.revlog.reuse-external-delta=no
  transaction abort!
  rollback completed
  abort: integrity check failed on f:11f271f9a74d
  [50]
  $ hg -R dst-incoming-delta log -T '{desc}\n'

Test a corrupt delta stored as is
---------------------------------

  $ hg init dst-incoming-as-is
  $ hg -R dst-incoming-as-is unbundle -q bad-delta.hg
  transaction abort!
  rollback completed
  abort: integrity check failed on f:11f271f9a74d
  [50]
  $ hg -R dst-incoming-as-is log -T '{desc}\n'

Test a corrupt full text
------------------------

  $ hg init dst-incoming-full
  $ hg -R dst-incoming-full unbundle -q bad-full.hg
  transaction abort! (missing-correct-output !)
  rollback completed (missing-correct-output !)
  abort: integrity check failed on f:11f271f9a74d (missing-correct-output !)
  [50] (missing-correct-output !)
  $ hg -R dst-incoming-full log -T '{desc}\n'
  cBc (known-bad-output !)
  cAc (known-bad-output !)

Test a corrupt full text with changegroup v4
--------------------------------------------

XXX: reusing the incoming deltas crashes on such full texts, so this disables
it.

  $ hg init dst-incoming-full-v4
  $ hg -R dst-incoming-full-v4 unbundle -q bad-full-v4.hg \
  >   --config storage.revlog.reuse-external-delta=no
  transaction abort! (missing-correct-output !)
  rollback completed (missing-correct-output !)
  abort: integrity check failed on f:11f271f9a74d (missing-correct-output !)
  [50] (missing-correct-output !)
  $ hg -R dst-incoming-full-v4 log -T '{desc}\n'
  cBc (known-bad-output !)
  cAc (known-bad-output !)

Test a corrupt delta base
-------------------------

The delta base itself is not checked, but the incoming revision rebuilt from it
does not match its hash.

  $ hg clone -q -U dst-corrupt dst-incoming-base
  $ hg -R dst-incoming-base unbundle -q next.hg \
  >   --config storage.revlog.reuse-external-delta=no
  transaction abort! (missing-correct-output !)
  rollback completed (missing-correct-output !)
  abort: integrity check failed on f:fa2fed0b15ce (missing-correct-output !)
  [50] (missing-correct-output !)
  $ hg -R dst-incoming-base log -T '{desc}\n'
  cCc (known-bad-output !)
  cBc
  cAc
