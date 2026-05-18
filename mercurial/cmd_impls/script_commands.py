# script_commands.py - command declaration for "script::" namespace
#
# Copyright 2022 Mercurial Developers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations


from ..i18n import _
from .. import (
    cmd_impls,
    logcmdutil,
    pycompat,
    registrar,
    scmutil,
    tables,
)

command = registrar.command(tables.command_table)


def init():
    """noop function that is called to make sure the module is loaded and has
    registered the necessary items.

    See `mercurial.initialization` for details"""


@command(
    b'script::revs',
    [
        (
            b'e',
            b'exists',
            None,
            _(b'return 0 if the revset match any revs, 2 otherwise'),
        ),
    ]
    + cmd_impls.template_opts,
    _(b'REVS'),
    helpcategory=command.CATEGORY_MISC,
)
def cmd_script_revs_check(ui, repo, *revs, exists: bool | None = None, **opts):
    """given a revset, list its content or/amd check that it matches revisions

    By default, the command will echo the nodeid of each revision in the
    matched revset.

    If --exists is passed. The command won't display anything and return 0 if
    the revset match anything, 2 otherwise.

    If --no-exists is passed. The command won't display anything and return 2 if
    the revset match anything, 0 otherwise.

    if --template is explicitly passed with --exists or --no-exists, it will be
    used to display the matched revision, and the return code will still be
    adjusted.
    """
    revs = scmutil.revrange(repo, revs)

    has_template = opts.get("template") or opts.get("style")
    any_match = bool(revs)

    if exists is None and not has_template:
        opts["template"] = b"{node}\n"
        has_template = True

    if has_template:
        opts = pycompat.byteskwargs(opts)
        displayer = logcmdutil.changesetdisplayer(
            ui,
            repo,
            opts,
            buffered=False,
        )
        logcmdutil.displayrevs(ui, repo, revs, displayer)

    exists = bool(exists)  # prevent potenial silly bug
    if exists is not None and (any_match != exists):
        return 2
    return 0
