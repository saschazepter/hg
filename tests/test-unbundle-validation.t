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
  $ cd ..

  $ cat > corrupt.py <<EOF
  > import sys
  > src, dst = sys.argv[1:]
  > data = open(src, 'rb').read()
  > assert data.count(b'world') == 1
  > open(dst, 'wb').write(data.replace(b'world', b'wurld'))
  > EOF

  $ hg -R src bundle -q -a -t 'none-v2;cg.version=03' delta.hg
  $ "$PYTHON" corrupt.py delta.hg bad-delta.hg
  $ hg -R src bundle -q -a -t 'none-v2;cg.version=03' full.hg \
  >   --config devel.bundle.delta=full
  $ "$PYTHON" corrupt.py full.hg bad-full.hg
  $ hg -R src bundle -q -a -t 'none-v2;cg.version=04' full-v4.hg \
  >   --config devel.bundle.delta=full
  $ "$PYTHON" corrupt.py full-v4.hg bad-full-v4.hg

Without validation, the corruption is stored silently.

  $ hg init dst-corrupt
  $ hg -R dst-corrupt unbundle -q bad-delta.hg
  $ hg -R dst-corrupt log -T '{desc}\n'
  cBc
  cAc

Validating delta bases
======================

`storage.revlog.validate-delta-base` checks the bases deltas are computed
against.

Test a corrupt delta
--------------------

  $ hg init dst-delta
  $ hg -R dst-delta unbundle -q bad-delta.hg \
  >   --config storage.revlog.reuse-external-delta=no \
  >   --config storage.revlog.validate-delta-base=yes
  transaction abort!
  rollback completed
  abort: integrity check failed on f:11f271f9a74d
  [50]
  $ hg -R dst-delta log -T '{desc}\n'

Test a corrupt delta stored as is
---------------------------------

Nothing rebuilds the full text of a delta stored as is, so nothing is checked.

  $ hg init dst-delta-as-is
  $ hg -R dst-delta-as-is unbundle -q bad-delta.hg \
  >   --config storage.revlog.validate-delta-base=yes
  $ hg -R dst-delta-as-is log -T '{desc}\n'
  cBc
  cAc

Test a corrupt full text
------------------------

  $ hg init dst-full
  $ hg -R dst-full unbundle -q bad-full.hg \
  >   --config storage.revlog.validate-delta-base=yes
  transaction abort!
  rollback completed
  abort: integrity check failed on f:11f271f9a74d
  [50]
  $ hg -R dst-full log -T '{desc}\n'

Test a corrupt full text with changegroup v4
--------------------------------------------

Changegroup v4 sends full texts as is, instead of deltas against the null
revision, so nothing rebuilds them and nothing is checked.

XXX: reusing the incoming deltas crashes on such full texts, so this disables
it.

  $ hg init dst-full-v4
  $ hg -R dst-full-v4 unbundle -q bad-full-v4.hg \
  >   --config storage.revlog.reuse-external-delta=no \
  >   --config storage.revlog.validate-delta-base=yes
  $ hg -R dst-full-v4 log -T '{desc}\n'
  cBc
  cAc
