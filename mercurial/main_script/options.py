# main_script - utility around the top level command for Mercurial
#
# Copyright 2005-2025 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from typing import (
    Iterable,
)

from ..i18n import _

from .. import (
    cmd_impls,
    config as configmod,
    error,
    fancyopts,
    pycompat,
)


def early_parse_opts(ui, args):
    options = {}
    fancyopts.fancyopts(
        args,
        cmd_impls.global_opts,
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
