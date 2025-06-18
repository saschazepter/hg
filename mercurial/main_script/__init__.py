# main_script - utility around the top level command for Mercurial
#
# Copyright 2005-2025 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os

from typing import (
    Iterable,
)

from ..i18n import _

from .. import (
    cmdutil,
    commands,
    config as configmod,
    encoding,
    error,
    fancyopts,
    pycompat,
)

from ..configuration import rcutil
from ..utils import (
    urlutil,
)


def early_parse_opts(ui, args):
    options = {}
    fancyopts.fancyopts(
        args,
        commands.globalopts,
        options,
        gnu=not ui.plain(b'strictflags'),
        early=True,
        optaliases={b'repository': [b'repo']},
    )
    return options


def parse_config_files_opts(
    ui, cmdargs: list[bytes], config_files: Iterable[bytes]
) -> list[tuple[bytes, bytes, bytes, bytes]]:
    """parse the --config-file options from the command line

    A list of tuples containing (section, name, value, source) is returned,
    in the order they were read.
    """

    configs: list[tuple[bytes, bytes, bytes, bytes]] = []

    cfg = configmod.config()

    for file in config_files:
        try:
            cfg.read(file)
        except error.ConfigError as e:
            raise error.InputError(
                _(b'invalid --config-file content at %s') % e.location,
                hint=e.message,
            )
        except FileNotFoundError:
            hint = None
            if b'--cwd' in cmdargs:
                hint = _(b"this file is resolved before --cwd is processed")

            raise error.InputError(
                _(b'missing file "%s" for --config-file') % file, hint=hint
            )

    for section in cfg.sections():
        for item in cfg.items(section):
            name = item[0]
            value = item[1]
            src = cfg.source(section, name)

            ui.setconfig(section, name, value, src)
            configs.append((section, name, value, src))

    return configs


def parse_config_opts(ui, config):
    """parse the --config options from the command line"""
    configs = []

    for cfg in config:
        try:
            name, value = (cfgelem.strip() for cfgelem in cfg.split(b'=', 1))
            section, name = name.split(b'.', 1)
            if not section or not name:
                raise IndexError
            ui.setconfig(section, name, value, b'--config')
            configs.append((section, name, value))
        except (IndexError, ValueError):
            raise error.InputError(
                _(
                    b'malformed --config option: %r '
                    b'(use --config section.name=value)'
                )
                % pycompat.bytestr(cfg)
            )

    return configs


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

        path = cmdutil.findrepo(wd) or b""
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
