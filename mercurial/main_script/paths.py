# main_script - utility around the top level command for Mercurial
#
# Copyright 2005-2025 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os

from ..i18n import _

from .. import (
    encoding,
    error,
    repo as repo_utils,
)

from ..configuration import rcutil
from ..utils import (
    urlutil,
)


def get_cwd() -> bytes:
    """return the path to the current working directory

    raise an Abort error in case of error.
    """
    try:
        return encoding.getcwd()
    except OSError as e:
        msg = _(b"error getting current working directory: %s")
        msg %= encoding.strtolocal(e.strerror)
        raise error.Abort(msg)


def get_local(ui, rpath, wd=None):
    """Return (path, local ui object) for the given target path.

    Takes paths in [cwd]/.hg/hgrc into account."
    """
    cwd = get_cwd()
    # If using an alternate wd, temporarily switch to it so that relative
    # paths are resolved correctly during config loading.
    oldcwd = None
    try:
        if wd is None:
            wd = cwd
        else:
            oldcwd = cwd
            os.chdir(wd)

        path = repo_utils.find_repo(wd) or b""
        if not path:
            lui = ui
        else:
            lui = ui.copy()
            if rcutil.use_repo_hgrc():
                for __, c_type, rc_path in rcutil.repo_components(path):
                    assert c_type == b'path'
                    lui.readconfig(rc_path, root=path)

        if rpath:
            # the specified path, might be defined in the [paths] section of
            # the local repository. So we had to read the local config first
            # even if it get overriden here.
            path_obj = urlutil.get_clone_path_obj(lui, rpath)
            path = path_obj.rawloc
            lui = ui.copy()
            if rcutil.use_repo_hgrc():
                for __, c_type, rc_path in rcutil.repo_components(path):
                    assert c_type == b'path'
                    lui.readconfig(rc_path, root=path)
    finally:
        if oldcwd:
            os.chdir(oldcwd)

    return path, lui
