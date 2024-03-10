This test cover a bug that no longer exist.

Define helpers.

  $ hg_log () { hg log -G -T "{rev}:{node|short}"; }
  $ commit () { echo "foo - ${2:-$1}" > $1; hg commit -Aqm "Edited $1"; }
  $ strip() { hg --config extensions.strip= strip -q -r "$1" ; }

Setup hg repo.

  $ hg init repo
  $ cd repo
  $ touch x; hg add x; hg commit -m "initial"
  $ hg clone -q . ../clone
  $ commit a

  $ cd ../clone

  $ commit b

  $ hg pull -q ../repo

  $ ls -1 .hg/cache/branch?*
  .hg/cache/branch2-base
  .hg/cache/branch2-served
  $ cat .hg/cache/branch?-served
  222ae9789a75703f9836e44de7db179cbfd420ee 2
  a3498d6e39376d2456425dd8c692367bdbf00fa2 o default
  222ae9789a75703f9836e44de7db179cbfd420ee o default

  $ hg_log
  o  2:222ae9789a75
  |
  | @  1:a3498d6e3937
  |/
  o  0:7ab0a3bd758a
  

  $ strip '1:'

After the strip the "served" cache is now identical to the "base" one, and the
older one have been actively deleted.

  $ ls -1 .hg/cache/branch?*
  .hg/cache/branch2-base
  $ cat .hg/cache/branch?-base
  7ab0a3bd758a58b9f79557ce708533e627776cce 0
  7ab0a3bd758a58b9f79557ce708533e627776cce o default

We do a new commit and we get a new valid branchmap for the served version

  $ commit c
  $ ls -1 .hg/cache/branch?*
  .hg/cache/branch2-base
  .hg/cache/branch2-served
  $ cat .hg/cache/branch?-served
  a1602b357cfca067600406eb19060c7128804d72 1
  a1602b357cfca067600406eb19060c7128804d72 o default


On pull we end up with the same tip, and so wrongly reuse the invalid cache and crash.

  $ hg pull ../repo --quiet
  $ hg heads -T '{rev} {node} {branch}\n'
  2 222ae9789a75703f9836e44de7db179cbfd420ee default
  1 a1602b357cfca067600406eb19060c7128804d72 default
  $ ls -1 .hg/cache/branch?*
  .hg/cache/branch2-base
  .hg/cache/branch2-served
  $ cat .hg/cache/branch?-served
  222ae9789a75703f9836e44de7db179cbfd420ee 2
  a1602b357cfca067600406eb19060c7128804d72 o default
  222ae9789a75703f9836e44de7db179cbfd420ee o default
