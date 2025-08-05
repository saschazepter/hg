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
  mercurial/__main__.py:*: function level import: mercurial.demandimport (glob)
  mercurial/__main__.py:*: function level import: mercurial.dispatch (glob)
  mercurial/bundle2.py:*: function level import: mercurial.localrepo (glob)
  mercurial/bundle2.py:*: function level import: mercurial.exchange (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.hg (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.hg (glob)
  mercurial/color.py:*: function level import: mercurial.win32 (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.fileset (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.pyo3_rustext (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.cext.base85 (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.cext.bdiff (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.cext.mpatch (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.cext.osutil (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.win32 (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.cext (glob)
  mercurial/debugcommands.py:*: function level import: mercurial.pyo3_rustext (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.node.hex (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.i18n._ (glob)
  mercurial/error.py:*: function level import: mercurial.node.short (glob)
  mercurial/extensions.py:*: function level import: mercurial.color (glob)
  mercurial/extensions.py:*: function level import: mercurial.filemerge (glob)
  mercurial/extensions.py:*: function level import: mercurial.fileset (glob)
  mercurial/extensions.py:*: function level import: mercurial.revset (glob)
  mercurial/extensions.py:*: function level import: mercurial.templatefilters (glob)
  mercurial/extensions.py:*: function level import: mercurial.templatefuncs (glob)
  mercurial/extensions.py:*: function level import: mercurial.templatekw (glob)
  mercurial/extensions.py:*: function level import: hgext.__index__ (glob)
  mercurial/extensions.py:*: function level import: hgext.__index__ (glob)
  mercurial/hg.py:*: function level import: mercurial.streamclone (glob)
  mercurial/hgweb/server.py:*: function level import: mercurial.sslutil (glob)
  mercurial/localrepo.py:*: function level import: mercurial.upgrade (glob)
  mercurial/localrepo.py:*: function level import: mercurial.upgrade (glob)
  mercurial/localrepo.py:*: function level import: mercurial.upgrade (glob)
  mercurial/merge.py:*: function level import: mercurial.extensions (glob)
  mercurial/merge_utils/diff.py:*: function level import: mercurial.merge (glob)
  mercurial/metadata.py:*: function level import: mercurial.worker (glob)
  mercurial/profiling.py:*: function level import: mercurial.lsprof (glob)
  mercurial/profiling.py:*: function level import: mercurial.lsprofcalltree (glob)
  mercurial/profiling.py:*: function level import: mercurial.statprof (glob)
  mercurial/repoview.py:*: function level import: mercurial.mergestate (glob)
  mercurial/revlogutils/rewrite.py:*: function level import: mercurial.pure.parsers (glob)
  mercurial/revlogutils/rewrite.py:*: function level import: mercurial.pure.parsers (glob)
  mercurial/revset.py:*: function level import: mercurial.discovery (glob)
  mercurial/revset.py:*: function level import: mercurial.repo.factory (glob)
  mercurial/revset.py:*: function level import: mercurial.repo.factory (glob)
  mercurial/statprof.py:*: function level import: mercurial.utils.procutil (glob)
  mercurial/streamclone.py:*: function level import: mercurial.localrepo (glob)
  mercurial/streamclone.py:*: function level import: mercurial.localrepo (glob)
  mercurial/streamclone.py:*: function level import: mercurial.localrepo (glob)
  mercurial/subrepo.py:*: function level import: mercurial.hg (glob)
  mercurial/subrepo.py:*: function level import: mercurial.hg (glob)
  mercurial/subrepo.py:*: function level import: mercurial.repo.factory (glob)
  mercurial/subrepo.py:*: function level import: mercurial.repo.factory (glob)
  mercurial/subrepo.py:*: function level import: mercurial.repo.factory (glob)
  mercurial/subrepo.py:*: function level import: mercurial.hg (glob)
  mercurial/templatekw.py:*: function level import: mercurial.cmdutil (glob)
  mercurial/util.py:*: function level import: mercurial.__version__ (glob)
  mercurial/utils/compression.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoframing.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoframing.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoframing.py:*: function level import: mercurial.zstd (glob)
  Import cycle: mercurial.cmdutil -> mercurial.hg -> mercurial.cmdutil
  Import cycle: mercurial.bundle2 -> mercurial.exchange -> mercurial.bundle2
  Import cycle: hgext.convert.convcmd -> hgext.convert.p4 -> hgext.convert.convcmd
  Import cycle: mercurial.encoding -> mercurial.error -> mercurial.i18n -> mercurial.encoding
  Import cycle: mercurial.localrepo -> mercurial.upgrade -> mercurial.repo.factory -> mercurial.localrepo
  Import cycle: mercurial.extensions -> mercurial.revset -> mercurial.repo.factory -> mercurial.extensions
  Import cycle: hgext.fsmonitor.pywatchman.load -> hgext.fsmonitor.pywatchman.pybser -> hgext.fsmonitor.pywatchman.load
  Import cycle: hgext.fsmonitor.pywatchman.__init__ -> hgext.fsmonitor.pywatchman.load -> hgext.fsmonitor.pywatchman.__init__
  Import cycle: mercurial.bundlerepo -> mercurial.localrepo -> mercurial.revset -> mercurial.repo.factory -> mercurial.bundlerepo
  Import cycle: mercurial.commit -> mercurial.context -> mercurial.subrepo -> mercurial.hg -> mercurial.localrepo -> mercurial.commit
  Import cycle: mercurial.bundlecaches -> mercurial.repo.requirements -> mercurial.extensions -> mercurial.cmdutil -> mercurial.exchange -> mercurial.bundlecaches
  [1]

All files that get type checked must have 'from __future__ import annotations'

  $ testrepohg files 'set:**.py and size(">0")' -I mercurial -I hgext -X mercurial/thirdparty -0 \
  > | xargs -0 grep -L '^from __future__ import annotations$'
