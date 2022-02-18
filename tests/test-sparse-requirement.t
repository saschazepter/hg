  $ hg init repo
  $ cd repo

  $ touch a.html b.html c.py d.py

  $ cat > frontend.sparse << EOF
  > [include]
  > *.html
  > EOF

  $ hg -q commit -A -m initial

  $ echo 1 > a.html
  $ echo 1 > c.py
  $ hg commit -m 'commit 1'

Enable sparse profile

  $ hg debugrequires
  dotencode
  dirstate-v2 (dirstate-v2 !)
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  testonly-simplestore (reposimplestore !)

  $ hg debugsparse --config extensions.sparse= --enable-profile frontend.sparse
  $ ls -A
  .hg
  a.html
  b.html

Requirement for sparse added when sparse is enabled

  $ hg debugrequires --config extensions.sparse=
  dotencode
  dirstate-v2 (dirstate-v2 !)
  exp-sparse
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  testonly-simplestore (reposimplestore !)

Client without sparse enabled reacts properly

  $ hg files
  abort: repository is using sparse feature but sparse is not enabled; enable the "sparse" extensions to access
  [255]

Requirement for sparse is removed when sparse is disabled

  $ hg debugsparse --reset --config extensions.sparse=

  $ hg debugrequires
  dotencode
  dirstate-v2 (dirstate-v2 !)
  fncache
  generaldelta
  persistent-nodemap (rust !)
  revlog-compression-zstd (zstd !)
  revlogv1
  share-safe
  sparserevlog
  store
  testonly-simplestore (reposimplestore !)

And client without sparse can access

  $ hg files
  a.html
  b.html
  c.py
  d.py
  frontend.sparse
