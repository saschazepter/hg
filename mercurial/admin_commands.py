# admin_commands.py - command processing for admin* commands
#
# Copyright 2022 Mercurial Developers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import itertools
import typing

from .i18n import _
from .admin import verify
from . import (
    cmdutil,
    error,
    policy,
    registrar,
    tables,
    transaction,
)


if typing.TYPE_CHECKING:
    from .interfaces.types import (
        RepoT,
        UiT,
    )

shape_mod = policy.importrust("shape")


def init():
    """noop function that is called to make sure the module is loaded and has
    registered the necessary items.

    See `mercurial.initialization` for details"""


command = registrar.command(tables.command_table)


@command(
    b'admin::verify',
    [
        (b'c', b'check', [], _(b'add a check'), _(b'CHECK')),
        (b'o', b'option', [], _(b'pass an option to a check'), _(b'OPTION')),
    ],
    helpcategory=command.CATEGORY_MAINTENANCE,
)
def admin_verify(ui, repo, **opts):
    """verify the integrity of the repository

    Alternative UI to `hg verify` with a lot more control over the
    verification process and better error reporting.
    """

    if not repo.url().startswith(b'file:'):
        raise error.Abort(_(b"cannot verify bundle or remote repos"))

    if transaction.has_abandoned_transaction(repo):
        ui.warn(_(b"abandoned transaction found - run hg recover\n"))

    checks = opts.get("check", [])
    options = opts.get("option", [])

    funcs = verify.get_checks(repo, ui, names=checks, options=options)

    ui.status(_(b"running %d checks\n") % len(funcs))
    # Done in two times so the execution is separated from the resolving step
    for name, func in sorted(funcs.items(), key=lambda x: x[0]):
        ui.status(_(b"running %s\n") % name)
        errors = func()
        if errors:
            ui.warn(_(b"found %d errors\n") % errors)


@command(
    b'admin::narrow',
    [
        (
            b'',
            b'store-fingerprint',
            None,
            _(b"get the fingerprint for this repo's store narrospec"),
        ),
    ],
    helpcategory=command.CATEGORY_MAINTENANCE,
)
def admin_narrow(ui: UiT, repo: RepoT, **opts):
    """Narrow-related client administration utils.

    This command is experimental and is subject to change.
    """

    if shape_mod is None:
        raise error.Abort(_(b"this command needs the Rust extensions"))

    if not repo.is_narrow:
        raise error.Abort(_(b"this command only makes sense in a narrow clone"))

    if opts.get("store_fingerprint"):
        includes, excludes = repo.narrowpats
        fingerprint = shape_mod.fingerprint_for_patterns(includes, excludes)
        ui.writenoi18n(b"%s\n" % fingerprint)
    else:
        raise error.Abort(_(b"need at least one flag"))


@command(
    b'admin::narrow-server',
    [
        (
            b'',
            b'shape-fingerprints',
            None,
            _(b'list the fingerprint for each shape'),
        ),
        (
            b'',
            b'shape-patterns',
            b'',
            _(b'list the path patterns for each shape'),
            _(b'SHAPE-PATTERNS'),
        ),
        (
            b'',
            b'shape-narrow-patterns',
            b'',
            _(b'list the legacy narrow-style patterns for each shape'),
            _(b'SHAPE-NARROW-PATTERNS'),
        ),
    ],
    helpcategory=command.CATEGORY_MAINTENANCE,
)
def admin_narrow_server(ui: UiT, repo: RepoT, **opts):
    """Narrow-related server administration utils.

    This command is experimental and is subject to change.
    """

    if shape_mod is None:
        raise error.Abort(_(b"this command needs the Rust extensions"))

    if repo.is_narrow:
        raise error.InputError(_(b"repo is narrowed, this is a server command"))

    subcommand = cmdutil.check_at_most_one_arg(
        opts, "shape_fingerprints", "shape_patterns", "shape_narrow_patterns"
    )
    if subcommand is None:
        raise error.InputError("need at least one flag")

    shardset = shape_mod.get_shardset(repo.root)

    if subcommand in ("shape_patterns", "shape_narrow_patterns"):
        name = opts[subcommand]
        if b"," in name:
            raise error.Abort(
                _(b"composed shapespec is not implemented (yet)"),
            )
        shape = shardset.shape(name.decode())
        if shape is None:
            raise error.Abort(_(b"shape '%s' not found" % name))

    if subcommand == "shape_fingerprints":
        all_shapes = shardset.all_shapes()
        for shape in all_shapes:
            # TODO formatter?
            name = shape.name().encode()
            ui.writenoi18n(b"%s %s\n" % (shape.fingerprint(), name))
        return
    elif subcommand == "shape_patterns":
        # TODO formatter?
        includes, excludes = shape.patterns()
        include_tuples = zip(includes, itertools.repeat(True))
        exclude_tuples = zip(excludes, itertools.repeat(False))
        paths = sorted(
            itertools.chain(include_tuples, exclude_tuples),
            key=lambda t: zero_path(t[0]),
        )
        for path, included in paths:
            prefix = b"inc" if included else b"exc"
            ui.writenoi18n(b"%s:/%s\n" % (prefix, path))

        return
    elif subcommand == "shape_narrow_patterns":
        # TODO formatter?
        includes, excludes = shape.patterns()
        if includes:
            ui.writenoi18n(b"[include]\n")
            for include in includes:
                # compatibility with questionable old choices
                include = include if include else b"."
                ui.writenoi18n(b"path:%s\n" % include)
        if excludes:
            ui.writenoi18n(b"[exclude]\n")
            for exclude in excludes:
                # compatibility with questionable old choices
                exclude = exclude if exclude else b"."
                ui.writenoi18n(b"path:%s\n" % exclude)
    else:
        assert False, "unreachable"


def zero_path(path):
    # Temporarily in this module until we get a shape module to host this
    assert b'\0' not in path
    assert not path.startswith(b'/')
    assert not path.endswith(b'/')
    if not path:
        path = b'/'
    else:
        path = b'/%s/' % path
    return path.replace(b'/', b'\0')
