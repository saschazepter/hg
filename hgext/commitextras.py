# commitextras.py
#
# Copyright 2013 Facebook, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

'''adds a new flag extras to commit (ADVANCED)'''

from __future__ import annotations

import re

from mercurial.i18n import _
from mercurial import (
    commands,
    error,
    extensions,
    registrar,
)

cmdtable = {}
command = registrar.command(cmdtable)
testedwith = b'ships-with-hg-core'

usedinternally = {
    b'amend_source',
    b'branch',
    b'close',
    b'histedit_source',
    b'topic',
    b'rebase_source',
    b'intermediate-source',
    b'__touch-noise__',
    b'source',
    b'transplant_source',
}


def extsetup(ui):
    entry = extensions.wrapcommand(commands.table, b'commit', _commit)
    options = entry[1]
    options.append(
        (
            b'',
            b'extra',
            [],
            _(b'set a changeset\'s extra values'),
            _(b"KEY=VALUE"),
        )
    )


def _parse_extras(extras):
    res = {}
    for raw in extras:
        if b'=' not in raw:
            msg = _(b"unable to parse '%s', should follow KEY=VALUE format")
            raise error.InputError(msg % raw)
        k, v = raw.split(b'=', 1)
        if not k:
            msg = _(b"unable to parse '%s', keys can't be empty")
            raise error.InputError(msg % raw)
        if re.search(br'[^\w-]', k):
            msg = _(b"keys can only contain ascii letters, digits, '_' and '-'")
            raise error.InputError(msg)
        if k in usedinternally:
            msg = _(b"key '%s' is used internally, can't be set manually")
            raise error.InputError(msg % k)
        res[k] = v
    return res


def _commit(orig, ui, repo, *pats, **opts):
    if hasattr(repo, 'unfiltered'):
        repo = repo.unfiltered()

    class repoextra(repo.__class__):
        def commit(self, *innerpats, **inneropts):
            extras = opts.get('extra')
            parsed = _parse_extras(extras)
            for k in parsed:
                inneropts['extra'][k] = parsed[k]
            return super().commit(*innerpats, **inneropts)

    repo.__class__ = repoextra
    return orig(ui, repo, *pats, **opts)
