# chainsaw.py
#
# Copyright 2022 Georges Racinet <georges.racinet@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""chainsaw is a collection of single-minded and dangerous tools. (EXPERIMENTAL)

  "Don't use a chainsaw to cut your food!"

The chainsaw extension provides commands that are so much geared towards a
specific use case in a specific context or environment that they are totally
inappropriate and **really dangerous** in other contexts.

The help text of each command explicitly summarizes its context of application
and the wanted end result.

It is recommended to run these commands with the ``HGPLAIN`` environment
variable (see :hg:`help scripting`).
"""

import shutil

from mercurial.i18n import _
from mercurial import (
    cmdutil,
    commands,
    error,
    registrar,
)

cmdtable = {}
command = registrar.command(cmdtable)
# Note for extension authors: ONLY specify testedwith = 'ships-with-hg-core' for
# extensions which SHIP WITH MERCURIAL. Non-mainline extensions should
# be specifying the version(s) of Mercurial they are tested with, or
# leave the attribute unspecified.
testedwith = b'ships-with-hg-core'


@command(
    b'admin::chainsaw-update',
    [
        (
            b'',
            b'purge-unknown',
            True,
            _(
                b'Remove unversioned files before update. Disabling this can '
                b'in some cases interfere with the update.'
                b'See also :hg:`purge`.'
            ),
        ),
        (
            b'',
            b'purge-ignored',
            True,
            _(
                b'Remove ignored files before update. Disable this for '
                b'instance to reuse previous compiler object files. '
                b'See also :hg:`purge`.'
            ),
        ),
        (
            b'',
            b'rev',
            b'',
            _(b'revision to update to'),
        ),
        (
            b'',
            b'source',
            b'',
            _(b'repository to clone from'),
        ),
    ],
    _(b'hg admin::chainsaw-update [OPTION] --rev REV --source SOURCE...'),
    helpbasic=True,
)
def update(ui, repo, **opts):
    """pull and update to a given revision, no matter what, (EXPERIMENTAL)

    Context of application: *some* Continuous Integration (CI) systems,
    packaging or deployment tools.

    Wanted end result: clean working directory updated at the given revision.

    chainsaw-update pulls from one source, then updates the working directory
    to the given revision, overcoming anything that would stand in the way.

    By default, it will:

    - break locks if needed, leading to possible corruption if there
      is a concurrent write access.
    - perform recovery actions if needed
    - revert any local modification.
    - purge unknown and ignored files.
    - go as far as to reclone if everything else failed (not implemented yet).

    DO NOT use it for anything else than performing a series
    of unattended updates, with full exclusive repository access each time
    and without any other local work than running build scripts.
    In case the local repository is a share (see :hg:`help share`), exclusive
    write access to the share source is also mandatory.

    It is recommended to run these commands with the ``HGPLAIN`` environment
    variable (see :hg:`scripting`).

    Motivation: in Continuous Integration and Delivery systems (CI/CD), the
    occasional remnant or bogus lock are common sources of waste of time (both
    working time and calendar time). CI/CD scripts tend to grow with counter-
    measures, often done in urgency. Also, whilst it is neat to keep
    repositories from one job to the next (especially with large
    repositories), an exceptional recloning is better than missing a release
    deadline.
    """
    rev = opts['rev']
    source = opts['source']
    if not rev:
        raise error.InputError(_(b'specify a target revision with --rev'))
    if not source:
        raise error.InputError(_(b'specify a pull path with --source'))
    ui.status(_(b'breaking locks, if any\n'))
    repo.svfs.tryunlink(b'lock')
    repo.vfs.tryunlink(b'wlock')

    ui.status(_(b'recovering after interrupted transaction, if any\n'))
    repo.recover()

    ui.status(_(b'pulling from %s\n') % source)
    overrides = {(b'ui', b'quiet'): True}
    with ui.configoverride(overrides, b'chainsaw-update'):
        pull = cmdutil.findcmd(b'pull', commands.table)[1][0]
        pull(ui, repo, source, rev=[rev], remote_hidden=False)

    purge = cmdutil.findcmd(b'purge', commands.table)[1][0]
    purge(
        ui,
        repo,
        dirs=True,
        all=opts.get('purge_ignored'),
        files=opts.get('purge_unknown'),
        confirm=False,
    )

    ui.status(_(b'updating to revision \'%s\'\n') % rev)
    update = cmdutil.findcmd(b'update', commands.table)[1][0]
    update(ui, repo, rev=rev, clean=True)

    ui.status(
        _(
            b'chainsaw-update to revision \'%s\' '
            b'for repository at \'%s\' done\n'
        )
        % (rev, repo.root)
    )
