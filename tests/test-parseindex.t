revlog.parseindex must be able to parse the index file even if
an index entry is split between two 64k blocks.  The ideal test
would be to create an index file with inline data where
64k < size < 64k + 64 (64k is the size of the read buffer, 64 is
the size of an index entry) and with an index entry starting right
before the 64k block boundary, and try to read it.
We approximate that by reducing the read buffer to 1 byte.

  $ hg init a
  $ cd a
  $ echo abc > foo
  $ hg add foo
  $ hg commit -m 'add foo'
  $ echo >> foo
  $ hg commit -m 'change foo'
  $ hg log -r 0:
  changeset:   0:7c31755bf9b5
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     add foo
  
  changeset:   1:26333235a41c
  tag:         tip
  user:        test
  date:        Thu Jan 01 00:00:00 1970 +0000
  summary:     change foo
  
  $ cat >> test.py << EOF
  > from __future__ import print_function
  > from mercurial import changelog, node, pycompat, vfs
  > 
  > class singlebyteread(object):
  >     def __init__(self, real):
  >         self.real = real
  > 
  >     def read(self, size=-1):
  >         if size == 65536:
  >             size = 1
  >         return self.real.read(size)
  > 
  >     def __getattr__(self, key):
  >         return getattr(self.real, key)
  > 
  >     def __enter__(self):
  >         self.real.__enter__()
  >         return self
  > 
  >     def __exit__(self, *args, **kwargs):
  >         return self.real.__exit__(*args, **kwargs)
  > 
  > def opener(*args):
  >     o = vfs.vfs(*args)
  >     def wrapper(*a, **kwargs):
  >         f = o(*a, **kwargs)
  >         return singlebyteread(f)
  >     wrapper.options = o.options
  >     return wrapper
  > 
  > cl = changelog.changelog(opener(b'.hg/store'))
  > print(len(cl), 'revisions:')
  > for r in cl:
  >     print(pycompat.sysstr(node.short(cl.node(r))))
  > EOF
  $ "$PYTHON" test.py
  2 revisions:
  7c31755bf9b5
  26333235a41c

  $ cd ..

#if no-pure

Test SEGV caused by bad revision passed to reachableroots() (issue4775):

  $ cd a

  $ "$PYTHON" <<EOF
  > from __future__ import print_function
  > from mercurial import changelog, vfs
  > cl = changelog.changelog(vfs.vfs(b'.hg/store'))
  > print('good heads:')
  > for head in [0, len(cl) - 1, -1]:
  >     print('%s: %r' % (head, cl.reachableroots(0, [head], [0])))
  > print('bad heads:')
  > for head in [len(cl), 10000, -2, -10000, None]:
  >     print('%s:' % head, end=' ')
  >     try:
  >         cl.reachableroots(0, [head], [0])
  >         print('uncaught buffer overflow?')
  >     except (IndexError, TypeError) as inst:
  >         print(inst)
  > print('good roots:')
  > for root in [0, len(cl) - 1, -1]:
  >     print('%s: %r' % (root, cl.reachableroots(root, [len(cl) - 1], [root])))
  > print('out-of-range roots are ignored:')
  > for root in [len(cl), 10000, -2, -10000]:
  >     print('%s: %r' % (root, cl.reachableroots(root, [len(cl) - 1], [root])))
  > print('bad roots:')
  > for root in [None]:
  >     print('%s:' % root, end=' ')
  >     try:
  >         cl.reachableroots(root, [len(cl) - 1], [root])
  >         print('uncaught error?')
  >     except TypeError as inst:
  >         print(inst)
  > EOF
  good heads:
  0: [0]
  1: [0]
  -1: []
  bad heads:
  2: head out of range
  10000: head out of range
  -2: head out of range
  -10000: head out of range
  None: an integer is required( .got type NoneType.)? (re)
  good roots:
  0: [0]
  1: [1]
  -1: [-1]
  out-of-range roots are ignored:
  2: []
  10000: []
  -2: []
  -10000: []
  bad roots:
  None: an integer is required( .got type NoneType.)? (re)

  $ cd ..

Test corrupted p1/p2 fields that could cause SEGV at parsers.c:

  $ mkdir invalidparent
  $ cd invalidparent

  $ hg clone --pull -q --config phases.publish=False ../a limit --config format.sparse-revlog=no
  $ hg clone --pull -q --config phases.publish=False ../a neglimit --config format.sparse-revlog=no
  $ hg clone --pull -q --config phases.publish=False ../a segv --config format.sparse-revlog=no
  $ rm -R limit/.hg/cache neglimit/.hg/cache segv/.hg/cache

  $ "$PYTHON" <<EOF
  > data = open("limit/.hg/store/00changelog.i", "rb").read()
  > poisons = [
  >     (b'limit', b'\0\0\0\x02'),
  >     (b'neglimit', b'\xff\xff\xff\xfe'),
  >     (b'segv', b'\0\x01\0\0'),
  > ]
  > for n, p in poisons:
  >     # corrupt p1 at rev0 and p2 at rev1
  >     d = data[:24] + p + data[28:127 + 28] + p + data[127 + 32:]
  >     open(n + b"/.hg/store/00changelog.i", "wb").write(d)
  > EOF

  $ hg -R limit debugrevlogindex -f1 -c
     rev flag     size   link     p1     p2       nodeid
       0 0000       62      0      2     -1 7c31755bf9b5
       1 0000       65      1      0      2 26333235a41c

  $ hg -R limit debugdeltachain -c
      rev  chain# chainlen     prev   delta       size    rawsize  chainsize     ratio   lindist extradist extraratio
        0       1        1       -1    base         63         62         63   1.01613        63         0    0.00000
        1       2        1       -1    base         66         65         66   1.01538        66         0    0.00000

  $ hg -R neglimit debugrevlogindex -f1 -c
     rev flag     size   link     p1     p2       nodeid
       0 0000       62      0     -2     -1 7c31755bf9b5
       1 0000       65      1      0     -2 26333235a41c

  $ hg -R segv debugrevlogindex -f1 -c
     rev flag     size   link     p1     p2       nodeid
       0 0000       62      0  65536     -1 7c31755bf9b5
       1 0000       65      1      0  65536 26333235a41c

  $ hg -R segv debugdeltachain -c
      rev  chain# chainlen     prev   delta       size    rawsize  chainsize     ratio   lindist extradist extraratio
        0       1        1       -1    base         63         62         63   1.01613        63         0    0.00000
        1       2        1       -1    base         66         65         66   1.01538        66         0    0.00000

  $ cat <<EOF > test.py
  > from __future__ import print_function
  > import sys
  > from mercurial import changelog, pycompat, vfs
  > cl = changelog.changelog(vfs.vfs(pycompat.fsencode(sys.argv[1])))
  > n0, n1 = cl.node(0), cl.node(1)
  > ops = [
  >     ('reachableroots',
  >      lambda: cl.index.reachableroots2(0, [1], [0], False)),
  >     ('compute_phases_map_sets', lambda: cl.computephases({1: {cl.node(0)}})),
  >     ('index_headrevs', lambda: cl.headrevs()),
  >     ('find_gca_candidates', lambda: cl.commonancestorsheads(n0, n1)),
  >     ('find_deepest', lambda: cl.ancestor(n0, n1)),
  >     ]
  > for l, f in ops:
  >     print(l + ':', end=' ')
  >     try:
  >         f()
  >         print('uncaught buffer overflow?')
  >     except ValueError as inst:
  >         print(inst)
  > EOF

  $ "$PYTHON" test.py limit/.hg/store
  reachableroots: parent out of range
  compute_phases_map_sets: parent out of range
  index_headrevs: parent out of range
  find_gca_candidates: parent out of range
  find_deepest: parent out of range
  $ "$PYTHON" test.py neglimit/.hg/store
  reachableroots: parent out of range
  compute_phases_map_sets: parent out of range
  index_headrevs: parent out of range
  find_gca_candidates: parent out of range
  find_deepest: parent out of range
  $ "$PYTHON" test.py segv/.hg/store
  reachableroots: parent out of range
  compute_phases_map_sets: parent out of range
  index_headrevs: parent out of range
  find_gca_candidates: parent out of range
  find_deepest: parent out of range

  $ cd ..

#endif
