===============================
Test validation when unbundling
===============================

This file tests that hg validates incoming bundles when configured correctly.

  $ cat >> $HGRCPATH <<EOF
  > [storage]
  > revlog.reuse-external-delta = no
  > revlog.validate-delta-base = yes
  > EOF

Set up repo and corruption script
---------------------------------

  $ hg init src
  $ cd src
  $ echo hello > f
  $ hg commit -qAm 0
  $ echo world >> f
  $ hg commit -qm 1
  $ cd ..

  $ cat > corrupt.py <<EOF
  > import sys
  > src, dst = sys.argv[1:]
  > data = open(src, 'rb').read()
  > assert data.count(b'world') == 1
  > open(dst, 'wb').write(data.replace(b'world', b'wurld'))
  > EOF

Test a corrupt delta
--------------------

  $ hg -R src bundle -q -a -t 'none-v2;cg.version=03' delta.hg
  $ "$PYTHON" corrupt.py delta.hg bad-delta.hg
  $ hg init dst-delta
  $ hg -R dst-delta unbundle -q bad-delta.hg
  transaction abort!
  rollback completed
  abort: None (known-bad-output rust !)
  abort: unknown node: \xf5{\xaed\x9fn\x9b\xe3\xb9\x06;\x84\xcd\xbc\xdew\xa1\xac\xa7\x97 (esc) (known-bad-output pure !)
  abort: RevlogError (known-bad-output no-rust no-pure !)
  abort: integrity check failed on f:f57bae649f6e (missing-correct-output !)
  [50]
  $ hg -R dst-delta log -T '{rev}\n'
