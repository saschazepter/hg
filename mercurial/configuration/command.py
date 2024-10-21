# Gather code related to command dealing with configuration.

from __future__ import annotations

import os

from typing import Any, Dict, Optional

from ..i18n import _

from .. import (
    cmdutil,
    error,
    requirements,
    ui as uimod,
    util,
    vfs as vfsmod,
)

from . import rcutil

EDIT_FLAG = 'edit'


# keep typing simple for now
ConfigLevelT = str
LEVEL_USER = 'user'  # "user" is the default level and never passed explicitly
LEVEL_LOCAL = 'local'
LEVEL_GLOBAL = 'global'
LEVEL_SHARED = 'shared'
LEVEL_NON_SHARED = 'non_shared'
EDIT_LEVELS = (
    LEVEL_USER,
    LEVEL_LOCAL,
    LEVEL_GLOBAL,
    LEVEL_SHARED,
    LEVEL_NON_SHARED,
)


def find_edit_level(
    ui: uimod.ui, repo, opts: Dict[str, Any]
) -> Optional[ConfigLevelT]:
    """return the level we should edit, if any.

    Parse the command option to detect when an edit is requested, and if so the
    configuration level we should edit.
    """
    if opts.get(EDIT_FLAG) or any(opts.get(o) for o in EDIT_LEVELS):
        cmdutil.check_at_most_one_arg(opts, *EDIT_LEVELS)
        for level in EDIT_LEVELS:
            if opts.get(level):
                return level
        return EDIT_LEVELS[0]
    return None


def edit_config(ui: uimod.ui, repo, level: ConfigLevelT) -> None:
    """let the user edit configuration file for the given level"""

    if level == LEVEL_USER:
        paths = rcutil.userrcpath()
    elif level == LEVEL_GLOBAL:
        paths = rcutil.systemrcpath()
    elif level == LEVEL_LOCAL:
        if not repo:
            raise error.InputError(_(b"can't use --local outside a repository"))
        paths = [repo.vfs.join(b'hgrc')]
    elif level == LEVEL_NON_SHARED:
        paths = [repo.vfs.join(b'hgrc-not-shared')]
    elif level == LEVEL_SHARED:
        if not repo.shared():
            raise error.InputError(
                _(b"repository is not shared; can't use --shared")
            )
        if requirements.SHARESAFE_REQUIREMENT not in repo.requirements:
            raise error.InputError(
                _(
                    b"share safe feature not enabled; "
                    b"unable to edit shared source repository config"
                )
            )
        paths = [vfsmod.vfs(repo.sharedpath).join(b'hgrc')]
    else:
        msg = 'unknown config level: %s' % level
        raise error.ProgrammingError(msg)

    for f in paths:
        if os.path.exists(f):
            break
    else:
        if LEVEL_GLOBAL:
            samplehgrc = uimod.samplehgrcs[b'global']
        elif LEVEL_LOCAL:
            samplehgrc = uimod.samplehgrcs[b'local']
        else:
            samplehgrc = uimod.samplehgrcs[b'user']

        f = paths[0]
        util.writefile(f, util.tonativeeol(samplehgrc))

    editor = ui.geteditor()
    ui.system(
        b"%s \"%s\"" % (editor, f),
        onerr=error.InputError,
        errprefix=_(b"edit failed"),
        blockedtag=b'config_edit',
    )
