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
  mercurial/bundlecaches.py:*: function level import: mercurial.localrepo (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.hg (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.context (glob)
  mercurial/cmdutil.py:*: function level import: mercurial.hg (glob)
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
  mercurial/diffutil.py:*: function level import: mercurial.context (glob)
  mercurial/diffutil.py:*: function level import: mercurial.merge (glob)
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
  mercurial/filemerge.py:*: function level import: mercurial.context (glob)
  mercurial/filemerge.py:*: function level import: mercurial.hook (glob)
  mercurial/filemerge.py:*: function level import: mercurial.extensions (glob)
  mercurial/filemerge.py:*: function level import: mercurial.context (glob)
  mercurial/hg.py:*: function level import: mercurial.streamclone (glob)
  mercurial/hgweb/server.py:*: function level import: mercurial.sslutil (glob)
  mercurial/localrepo.py:*: function level import: mercurial.upgrade (glob)
  mercurial/localrepo.py:*: function level import: mercurial.upgrade (glob)
  mercurial/localrepo.py:*: function level import: mercurial.upgrade (glob)
  mercurial/merge.py:*: function level import: mercurial.sparse (glob)
  mercurial/merge.py:*: function level import: mercurial.extensions (glob)
  mercurial/merge.py:*: function level import: mercurial.sparse (glob)
  mercurial/merge.py:*: function level import: mercurial.bundlerepo (glob)
  mercurial/merge.py:*: function level import: mercurial.sparse (glob)
  mercurial/metadata.py:*: function level import: mercurial.worker (glob)
  mercurial/obsolete.py:*: function level import: mercurial.statichttprepo (glob)
  mercurial/profiling.py:*: function level import: mercurial.lsprof (glob)
  mercurial/profiling.py:*: function level import: mercurial.lsprofcalltree (glob)
  mercurial/profiling.py:*: function level import: mercurial.statprof (glob)
  mercurial/repoview.py:*: function level import: mercurial.mergestate (glob)
  mercurial/revlogutils/rewrite.py:*: function level import: mercurial.revlog (glob)
  mercurial/revlogutils/rewrite.py:*: function level import: mercurial.pure.parsers (glob)
  mercurial/revlogutils/rewrite.py:*: function level import: mercurial.pure.parsers (glob)
  mercurial/revset.py:*: function level import: mercurial.mergestate (glob)
  mercurial/revset.py:*: function level import: mercurial.mergestate (glob)
  mercurial/revset.py:*: function level import: mercurial.discovery (glob)
  mercurial/revset.py:*: function level import: mercurial.hg (glob)
  mercurial/revset.py:*: function level import: mercurial.hg (glob)
  mercurial/scmutil.py:*: function level import: mercurial.bookmarks (glob)
  mercurial/scmutil.py:*: function level import: mercurial.repair (glob)
  mercurial/scmutil.py:*: function level import: mercurial.repair (glob)
  mercurial/statprof.py:*: function level import: mercurial.utils.procutil (glob)
  mercurial/streamclone.py:*: function level import: mercurial.localrepo (glob)
  mercurial/streamclone.py:*: function level import: mercurial.localrepo (glob)
  mercurial/streamclone.py:*: function level import: mercurial.localrepo (glob)
  mercurial/subrepo.py:*: function level import: mercurial.hg (glob)
  mercurial/subrepo.py:*: function level import: mercurial.hg (glob)
  mercurial/subrepo.py:*: function level import: mercurial.hg (glob)
  mercurial/templatekw.py:*: function level import: mercurial.mergestate (glob)
  mercurial/templatekw.py:*: function level import: mercurial.cmdutil (glob)
  mercurial/util.py:*: function level import: mercurial.__version__ (glob)
  mercurial/utils/compression.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoframing.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoframing.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoframing.py:*: function level import: mercurial.zstd (glob)
  mercurial/wireprotoserver.py:*: function level import: mercurial.hgweb.common (glob)
  mercurial/wireprotoserver.py:*: function level import: mercurial.hgweb.common (glob)
  Import cycle: mercurial.cmdutil -> mercurial.hg -> mercurial.cmdutil
  Import cycle: mercurial.merge -> mercurial.sparse -> mercurial.merge
  Import cycle: mercurial.scmutil -> mercurial.ui -> mercurial.scmutil
  Import cycle: mercurial.repair -> mercurial.scmutil -> mercurial.repair
  Import cycle: mercurial.bundle2 -> mercurial.exchange -> mercurial.bundle2
  Import cycle: mercurial.bookmarks -> mercurial.scmutil -> mercurial.bookmarks
  Import cycle: mercurial.context -> mercurial.subrepoutil -> mercurial.context
  Import cycle: mercurial.localrepo -> mercurial.upgrade -> mercurial.localrepo
  Import cycle: mercurial.subrepo -> mercurial.subrepoutil -> mercurial.subrepo
  Import cycle: hgext.convert.convcmd -> hgext.convert.p4 -> hgext.convert.convcmd
  Import cycle: mercurial.extensions -> mercurial.filemerge -> mercurial.extensions
  Import cycle: mercurial.revlog -> mercurial.revlogutils.rewrite -> mercurial.revlog
  Import cycle: mercurial.bundlecaches -> mercurial.localrepo -> mercurial.bundlecaches
  Import cycle: mercurial.hg -> mercurial.logcmdutil -> mercurial.revset -> mercurial.hg
  Import cycle: mercurial.encoding -> mercurial.error -> mercurial.i18n -> mercurial.encoding
  Import cycle: mercurial.diffutil -> mercurial.merge -> mercurial.obsutil -> mercurial.diffutil
  Import cycle: mercurial.bundlerepo -> mercurial.cmdutil -> mercurial.hg -> mercurial.bundlerepo
  Import cycle: mercurial.discovery -> mercurial.scmutil -> mercurial.repair -> mercurial.discovery
  Import cycle: mercurial.changegroup -> mercurial.scmutil -> mercurial.repair -> mercurial.changegroup
  Import cycle: mercurial.branchmap -> mercurial.obsolete -> mercurial.statichttprepo -> mercurial.branchmap
  Import cycle: mercurial.configuration.rcutil -> mercurial.vfs -> mercurial.ui -> mercurial.configuration.rcutil
  Import cycle: hgext.fsmonitor.pywatchman.load -> hgext.fsmonitor.pywatchman.pybser -> hgext.fsmonitor.pywatchman.load
  Import cycle: hgext.fsmonitor.pywatchman.__init__ -> hgext.fsmonitor.pywatchman.load -> hgext.fsmonitor.pywatchman.__init__
  Import cycle: mercurial.destutil -> mercurial.scmutil -> mercurial.ui -> mercurial.extensions -> mercurial.revset -> mercurial.destutil
  Import cycle: mercurial.commit -> mercurial.context -> mercurial.obsolete -> mercurial.statichttprepo -> mercurial.localrepo -> mercurial.commit
  Import cycle: mercurial.dirstate -> mercurial.scmutil -> mercurial.obsolete -> mercurial.statichttprepo -> mercurial.localrepo -> mercurial.dirstate
  Import cycle: mercurial.changelog -> mercurial.metadata -> mercurial.worker -> mercurial.scmutil -> mercurial.obsolete -> mercurial.statichttprepo -> mercurial.changelog
  Import cycle: mercurial.manifest -> mercurial.revlog -> mercurial.vfs -> mercurial.ui -> mercurial.scmutil -> mercurial.obsolete -> mercurial.statichttprepo -> mercurial.manifest
  [1]

All files that get type checked must have 'from __future__ import annotations'

  $ testrepohg files 'set:**.py and size(">0")' -I mercurial -I hgext -X mercurial/thirdparty -0 \
  > | xargs -0 grep -L '^from __future__ import annotations$'
