"""strip changesets and their descendants from history (DEPRECATED)

The functionality of this extension has been included in core Mercurial
since version 5.7. Please use :hg:`debugstrip ...` instead.

This extension allows you to strip changesets and all their descendants from the
repository. See the command help for details.
"""

from __future__ import annotations

from mercurial.i18n import _

from mercurial import (
    registrar,
    strip,
)

cmdtable = {}
command = registrar.command(cmdtable)

# Note for extension authors: ONLY specify testedwith = 'ships-with-hg-core' for
# extensions which SHIP WITH MERCURIAL. Non-mainline extensions should
# be specifying the version(s) of Mercurial they are tested with, or
# leave the attribute unspecified.
testedwith = b'ships-with-hg-core'


@command(
    b"strip",
    [
        (
            b'r',
            b'rev',
            [],
            _(
                b'strip specified revision (optional, '
                b'can specify revisions without this '
                b'option)'
            ),
            _(b'REV'),
        ),
        (
            b'f',
            b'force',
            None,
            _(
                b'force removal of changesets, discard '
                b'uncommitted changes (no backup)'
            ),
        ),
        (b'', b'no-backup', None, _(b'do not save backup bundle')),
        (
            b'',
            b'nobackup',
            None,
            _(b'do not save backup bundle (DEPRECATED)'),
        ),
        (b'n', b'', None, _(b'ignored  (DEPRECATED)')),
        (
            b'k',
            b'keep',
            None,
            _(b"do not modify working directory during strip"),
        ),
        (
            b'B',
            b'bookmark',
            [],
            _(b"remove revs only reachable from given bookmark"),
            _(b'BOOKMARK'),
        ),
        (
            b'',
            b'soft',
            None,
            _(b"simply drop changesets from visible history (EXPERIMENTAL)"),
        ),
        (
            b'',
            b'permit-empty-revset',
            False,
            _(b"return success even if no revision was stripped"),
        ),
    ],
    _(b'hg strip [-k] [-f] [-B bookmark] [-r] REV...'),
    helpcategory=command.CATEGORY_MAINTENANCE,
)
def _strip(ui, repo, *revs, **opts):
    return strip._strip_command(ui, repo, *revs, **opts)
