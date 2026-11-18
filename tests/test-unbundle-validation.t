===============================
Test validation when unbundling
===============================

This file tests that hg validates incoming bundles when configured correctly.

Set up repo and corruption script
---------------------------------

  $ hg init src
  $ cd src
  $ echo hello > f
  $ hg commit -qAm cAc
  $ echo world >> f
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
  abort: integrity check failed on f:f57bae649f6e
  [50]
  $ hg -R dst-delta log -T '{desc}\n'
