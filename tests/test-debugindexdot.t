Just exercise debugindexdot
Create a short file history including a merge.
  $ hg init t
  $ cd t
  $ echo a > a
  $ hg ci -qAm t1 -d '0 0'
  $ echo a >> a
  $ hg ci -m t2 -d '1 0'
  $ hg up -qC 0
  $ echo b >> a
  $ hg ci -m t3 -d '2 0'
  created new head
  $ HGMERGE=true hg merge -q
  $ hg ci -m merge -d '3 0'

  $ hg debugindexdot -c
  digraph G {
  	-1 -> 0
  	0 -> 1
  	0 -> 2
  	2 -> 3
  	1 -> 3
  }

  $ hg debugindexdot -m
  digraph G {
  	-1 -> 0
  	0 -> 1
  	0 -> 2
  	2 -> 3
  	1 -> 3
  }

  $ hg debugindexdot a
  digraph G {
  	-1 -> 0
  	0 -> 1
  	0 -> 2
  	2 -> 3
  	1 -> 3
  }

Include arbitrary graphviz statements
  $ hg debugindexdot -c -i 'rankdir=BT' -i 'node [shape=box]'
  digraph G {
  	rankdir=BT
  	node [shape=box]
  	-1 -> 0
  	0 -> 1
  	0 -> 2
  	2 -> 3
  	1 -> 3
  }

Use a template for labels
  $ hg debugindexdot -c -T '{desc}'
  digraph G {
  	0 [label="t1"]
  	1 [label="t2"]
  	2 [label="t3"]
  	3 [label="merge"]
  	-1 -> 0
  	0 -> 1
  	0 -> 2
  	2 -> 3
  	1 -> 3
  }

Templates only work with changelog
  $ hg debugindexdot -m -T '{desc}'
  abort: -T/--template is only supported for -c/--changelog
  [255]
  $ hg debugindexdot a -T '{desc}'
  abort: -T/--template is only supported for -c/--changelog
  [255]

Show a single rev
  $ hg debugindexdot -c -r 0
  digraph G {
  	0
  }
  $ hg debugindexdot -m -r 0
  digraph G {
  	0
  }
  $ hg debugindexdot a -r 0
  digraph G {
  	0
  }

Show all revs explicitly
  $ hg debugindexdot -c -r 0 -r 1 -r 2 -r 3
  digraph G {
  	0
  	1
  	2
  	3
  	0 -> 1
  	0 -> 2
  	1 -> 3
  	2 -> 3
  }

Show rev by node
  $ hg debugindexdot -c -r $(hg log -r 0 -T '{node}')
  digraph G {
  	0
  }

Show sibling revs
  $ hg debugindexdot -c -r 1 -r 2
  digraph G {
  	1
  	2
  }

Show a parent and child rev
  $ hg debugindexdot -c -r 0 -r 1
  digraph G {
  	0
  	1
  	0 -> 1
  }

Show an ancestor and descendant rev
  $ hg debugindexdot -c -r 0 -r 3
  digraph G {
  	0
  	3
  	0 -> 3 [style=dashed]
  }

Show common ancestors
  $ hg debugindexdot -c -r 1 -r 2 --common
  digraph G {
  	0 [style=filled]
  	1
  	2
  	0 -> 1
  	0 -> 2
  }

Dashed edge from 0 to 3, even though it's already reachable via 0 -> 1 -> 3,
to represent 0 -> 2 -> 3.
  $ hg debugindexdot -c -r 0 -r 1 -r 3
  digraph G {
  	0
  	1
  	3
  	0 -> 1
  	1 -> 3
  	0 -> 3 [style=dashed]
  }

  $ cd ..
