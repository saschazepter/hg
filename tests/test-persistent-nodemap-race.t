===============================================================
Test the index-open race between the nodemap and the index file
===============================================================

When a revlog is opened, two things are read from disk: the persistent nodemap
and the index. If another process appends a revision (updating both the index
and the nodemap) in between those two reads, the two can end up out of sync.

This is bad when the index is read *before* the nodemap: the freshly written
nodemap then refers to a tip revision absent from the stale index we already
loaded, which forces a full (and expensive) nodemap rebuild from scratch.

This test reproduces that race deterministically using the
`devel.sync.revlog.pre-read-index-file` synchronization points and observes,
via `devel.debug.nodemap.catchup`, that the full rebuild happens. It exercises
the Rust revlog opening code through `rhg`.

#require rhg

  $ NO_FALLBACK="env RHG_ON_UNSUPPORTED=abort"

  $ cat >> $HGRCPATH << EOF
  > [format]
  > use-persistent-nodemap=yes
  > [storage]
  > revlog.persistent-nodemap.slow-path=allow
  > EOF

Build a repository with a tracked file to read. We never create inline
changelogs, so the changelog already carries a persistent nodemap that the
opening code will read (the nodemap is not used for inline revlogs).

  $ hg init repo
  $ cd repo
  $ echo content > afile
  $ hg commit -Aqm 'add afile'
  $ node=`hg log -r . -T '{node}'`

  $ test -f .hg/store/00changelog.d && echo "changelog: non-inline"
  changelog: non-inline
  $ ls .hg/store/*.nd
  .hg/store/00changelog-????????.nd (glob)

Start an `rhg cat`, which opens the changelog. The sync point makes it create
`index-open-sync.waiting` and then wait for `index-open-sync`, in between
reading the index and reading the nodemap.

  $ $NO_FALLBACK rhg cat -r "$node" afile \
  >   --config devel.debug.nodemap.catchup=yes \
  >   --config devel.sync.revlog.between-index-and-nodemap-open-file="$TESTTMP"/index-open-sync \
  >   > "$TESTTMP"/cat.out 2> "$TESTTMP"/cat.err &
  $ "$RUNTESTDIR"/testlib/wait-on-file 5 "$TESTTMP"/index-open-sync.waiting

While `rhg cat` is paused, append a revision. This advances both the changelog
index and its persistent nodemap on disk.

  $ echo more >> afile
  $ hg commit -qm 'concurrent commit'

Let the paused `rhg cat` proceed to read the (now advanced) nodemap.

  $ touch "$TESTTMP"/index-open-sync
  $ wait

`rhg cat` returns the correct content for the revision it was asked for ...

  $ cat "$TESTTMP"/cat.out
  content

... but the freshly written nodemap refers to a revision that is not in the
stale index we read first, so the whole nodemap is rebuilt from scratch. (With
the index and nodemap read in the other order, this would instead print
"caught up 1 revisions".)

  $ cat "$TESTTMP"/cat.err
  persistent nodemap: rebuilt from scratch (1 revisions)

  $ cd ..
