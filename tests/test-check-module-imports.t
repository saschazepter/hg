#require test-repo hg32

  $ . "$TESTDIR/helpers-testrepo.sh"

  $ cd "$TESTDIR"/..

There are a handful of cases here that require renaming a module so it
doesn't overlap with a stdlib module name. There are also some cycles
here that we should still endeavor to fix, and some cycles will be
hidden by deduplication algorithm in the cycle detector, so fixing
these may expose other cycles.

Known-bad files are excluded by -X as some of them would produce unstable
outputs, which should be fixed later.

NOTE: the `hg files` command here only works on files that are known to
Mercurial. If you add an import of a new file and haven't yet `hg add`ed it, you
will likely receive warnings about a direct import.

  $ bash contrib/check-import

All files that get type checked must have 'from __future__ import annotations'

  $ testrepohg files 'set:**.py and size(">0")' -I mercurial -I hgext -X mercurial/thirdparty -0 \
  > | xargs -0 grep -L '^from __future__ import annotations$'
