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
    shape as shapemod,
    tables,
    transaction,
)


if typing.TYPE_CHECKING:
    from .interfaces.types import (
        RepoT,
        UiT,
    )


if policy.has_rust():
    pure_shapemod = shapemod
    shapemod = policy.importrust("shape")


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
    b'admin::narrow-client',
    [
        (
            b'',
            b'store-fingerprint',
            None,
            _(b"get the fingerprint for this repo's store narrowspec"),
        ),
    ],
    helpcategory=command.CATEGORY_MAINTENANCE,
)
def admin_narrow_client(ui: UiT, repo: RepoT, **opts):
    """Narrow-related client administration utils.

    This command is experimental and is subject to change.
    """
    if not repo.is_narrow:
        raise error.Abort(_(b"this command only makes sense in a narrow clone"))

    if opts.get("store_fingerprint"):
        includes, excludes = repo.narrowpats
        fingerprint = shapemod.fingerprint_for_patterns(includes, excludes)
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
            _(b'list the path patterns for the given shape'),
            _(b'SHAPE-PATTERNS'),
        ),
        (
            b'',
            b'shape-narrow-patterns',
            b'',
            _(b'list the legacy narrow-style patterns for the given shape'),
            _(b'SHAPE-NARROW-PATTERNS'),
        ),
        (
            b'',
            b'shape-files',
            b'',
            _(b'list the files covered by the given shape'),
        ),
        (
            b'',
            b'shape-files-hidden',
            b'',
            _(b"list this shape's files that are not in the working copy"),
        ),
    ],
    helpcategory=command.CATEGORY_MAINTENANCE,
)
def admin_narrow_server(ui: UiT, repo: RepoT, **opts):
    """Narrow-related server administration utils.

    This command is experimental and is subject to change.
    """

    if not policy.has_rust():
        raise error.Abort(_(b"this command needs the Rust extensions"))

    if typing.TYPE_CHECKING:
        # Most APIs from `shapemod` are not implemented in Python, only in Rust
        # So for now the easiest is to just tell pytype to not worry about it.
        # Since it's FFI, unless we export types from PyO3 (we don't yet)
        # they can't be used here.
        global shapemod
        shapemod = typing.cast(typing.Any, shapemod)

    if repo.is_narrow:
        raise error.InputError(_(b"repo is narrowed, this is a server command"))

    subcommand = cmdutil.check_at_most_one_arg(
        opts,
        "shape_fingerprints",
        "shape_patterns",
        "shape_narrow_patterns",
        "shape_files",
        "shape_files_hidden",
    )
    if subcommand is None:
        raise error.InputError("need at least one flag")

    store_shards = shapemod.get_store_shards(repo.root)

    shape_commands = (
        "shape_patterns",
        "shape_narrow_patterns",
        "shape_files",
        "shape_files_hidden",
    )
    if subcommand in shape_commands:
        name = opts[subcommand]
        if b"," in name:
            raise error.Abort(
                _(b"composed shapespec is not implemented (yet)"),
            )
        shape = store_shards.shape(name.decode())
        if shape is None:
            raise error.Abort(_(b"shape '%s' not found" % name))

    if subcommand == "shape_fingerprints":
        all_shapes = store_shards.all_shapes()
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
            key=lambda t: pure_shapemod.zero_path(t[0]),
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
        return
    elif subcommand in ("shape_files", "shape_files_hidden"):
        # TODO formatter?
        list_hidden = subcommand == "shape_files_hidden"
        matcher = shape.matcher()
        files = []
        known = set(repo[None].matches(matcher))
        for entry in repo.store.data_entries(matcher=matcher):
            if not (entry.is_revlog or entry.is_filelog):
                continue
            files.append((entry.target_id, entry.target_id in known))
        files.sort()
        for file, known in files:
            if list_hidden and known:
                continue
            ui.writenoi18n(b"%s\n" % file)
        return
    else:
        assert False, "unreachable"
