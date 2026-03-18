# revlogutils/init.py - initilization code for the revlog
#
# Copyright 2026 Pierre-Yves David <pierre-yves.david@octobus,net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""Helper function for the initial parsing of setup of a revlog"""

from __future__ import annotations

import typing

from typing import Dict, Optional

from ..thirdparty import attr

from ..i18n import _

from .. import (
    error,
    policy,
    vfs as vfsmod,
)


from . import config, constants, docket as docketutil, nodemap as nodemaputil

rustrevlog = policy.importrust('revlog')


# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr


@attr.s()
class _RevlogInit:
    """a utility class that hold initialization information"""

    format_version = attr.ib(type=int)
    format_flags = attr.ib(type=int)
    files = attr.ib(type=Dict[str, Optional[bytes]])
    index_data = attr.ib(type=bytes)
    inline = attr.ib(default=False, type=bool)
    docket = attr.ib(default=None, type=docketutil.RevlogDocket)


def default_header(
    opts: dict,
    kind: constants.Kind,
    configs: config.RevlogConfigs,
):
    """init-method: process options config and return corresponding default
    revlog header, which can be used by `_loadindex` to create a new index.

    This method is part of the initialization sequence. That initialization
    sequence is cut into multiple methods for clarity.
    """
    if b'changelogv2' in opts and kind == constants.KIND_CHANGELOG:
        new_header = constants.CHANGELOGV2
    elif b'revlogv2' in opts:
        new_header = constants.REVLOGV2
    elif b'revlogv1' in opts:
        new_header = constants.REVLOGV1
        if configs.feature.may_inline:
            new_header |= constants.FLAG_INLINE_DATA
        if kind != constants.KIND_CHANGELOG and b'generaldelta' in opts:
            new_header |= constants.FLAG_GENERALDELTA
            if opts.get(b'delta-info-flags'):
                new_header |= constants.FLAG_DELTA_INFO
        if kind == constants.KIND_FILELOG and b'filelog_hasmeta_flag' in opts:
            new_header |= constants.FLAG_FILELOG_META
    elif b'revlogv0' in opts:
        new_header = constants.REVLOGV0
    else:
        new_header = constants.REVLOG_DEFAULT_VERSION
    return new_header


def find_entry_point_path(
    vfs: vfsmod.vfs,
    radix: bytes,
    *,
    postfix: bytes | None = None,
    try_pending: bool = False,
    try_split: bool = False,
):
    """init-method: compute the path of the entry point for this revlog

    This method is part of the initialization sequence. That initialization
    sequence is cut into multiple methods for clarity.
    """
    if postfix is not None:
        return b'%s.i.%s' % (radix, postfix)
    elif try_pending and vfs.exists(b'%s.i.a' % radix):
        return b'%s.i.a' % radix
    else:
        split = split_index_filename(radix)
        if try_split and vfs.exists(split):
            return split
        else:
            return b'%s.i' % radix


def split_index_filename(radix):
    """the path where to expect the index of an ongoing splitting operation

    The file will only exist if a splitting operation is in progress, but
    it is always expected at the same location."""
    parts = radix.split(b'/')
    if len(parts) > 1:
        # adds a '-s' prefix to the ``data/` or `meta/` base
        head = parts[0] + b'-s'
        mids = parts[1:-1]
        tail = parts[-1] + b'.i'
        pieces = [head] + mids + [tail]
        return b'/'.join(pieces)
    else:
        # the revlog is stored at the root of the store (changelog or
        # manifest), no risk of collision.
        return radix + b'.i.s'


def load_entry_point(
    vfs: vfsmod.vfs,
    radix: bytes,
    kind: constants.Kind,
    configs: config.RevlogConfigs,
    display_id: bytes,
    postfix: bytes | None = None,
    try_pending: bool = False,
    try_split: bool = False,
) -> _RevlogInit:
    """init-method: load revlog entry point from disk

    * For formats using a docket, this will load the docket.
    * For formats not using a docket, this means accessing the index.

    Returns the index data.

    This method is part of the initialization sequence. That initialization
    sequence is cut into multiple methods for clarity.
    """
    files = {}
    docket = None

    entry_point = find_entry_point_path(
        vfs,
        radix,
        postfix=postfix,
        try_pending=try_pending,
        try_split=try_split,
    )
    entry_data = vfs.tryread(
        entry_point,
        configs.data.mmap_index_threshold,
    )
    if len(entry_data) > 0:
        header = constants.INDEX_HEADER.unpack(entry_data[:4])[0]
        initempty = False
        format_flags = header & ~0xFFFF
        format_version = header & 0xFFFF
    else:
        header = default_header(
            vfs.options,
            kind,
            configs,
        )
        initempty = True
        format_flags = header & ~0xFFFF
        format_version = header & 0xFFFF

    supported_flags = constants.SUPPORTED_FLAGS.get(format_version)
    if supported_flags is None:
        msg = _(b'unknown version (%d) in revlog %s')
        msg %= (format_version, display_id)
        raise error.RevlogError(msg)
    elif format_flags & ~supported_flags:
        msg = _(b'unknown flags (%#04x) in version %d revlog %s')
        display_flag = format_flags >> 16
        msg %= (display_flag, format_version, display_id)
        raise error.RevlogError(msg)

    features = constants.FEATURES_BY_VERSION[format_version]
    inline = features['inline'](format_flags)
    configs.delta.general_delta = features['generaldelta'](format_flags)
    configs.delta.delta_info = features['delta_info'](format_flags)
    configs.data.generaldelta = configs.delta.general_delta
    configs.data.delta_info = configs.delta.delta_info
    configs.feature.has_side_data = features['sidedata']
    configs.feature.hasmeta_flag = features['hasmeta_flag'](format_flags)

    if format_version == constants.CHANGELOGV2:
        opts = vfs.options
        compute_rank = opts.get(b'changelogv2.compute-rank', True)
        configs.feature.compute_rank = compute_rank

    if configs.feature.persistent_nodemap:
        files["nodemap"] = nodemaputil.get_nodemap_file(
            vfs,
            radix,
            try_pending=try_pending,
        )

    if not features['docket']:
        files["index"] = entry_point
        if postfix is None:
            files["data"] = b'%s.d' % radix
        else:
            files["data"] = b'%s.d.%s' % (radix, postfix)
        index_data = entry_data
    else:
        files["docket"] = entry_point
        if initempty:
            docket = docketutil.default_docket(
                vfs,
                radix,
                entry_point,
                configs,
                header,
            )
        else:
            docket = docketutil.parse_docket(
                vfs,
                radix,
                entry_point,
                entry_data,
                use_pending=try_pending,
            )
        index_data, other_files = load_secondary_files(
            vfs, configs, display_id, docket
        )
        files.update(other_files)

    configs.finalize()
    return _RevlogInit(
        format_version=format_version,
        format_flags=format_flags,
        files=files,
        index_data=index_data,
        inline=inline,
        docket=docket,
    )


def load_secondary_files(vfs, configs, display_id, docket):
    """init-method: process a docket to initialize secondary files

    Returns the index data.

    This method is part of the initialization sequence. That initialization
    sequence is cut into multiple methods for clarity.
    """
    if docket is None:
        msg = "can't load secondary file without a docket"
        raise error.ProgrammingError(msg)
    files = {}
    files["index"] = docket.index_filepath()
    index_data = b''
    index_size = docket.index_end
    if index_size > 0:
        index_data = vfs.tryread(
            files["index"],
            configs.data.mmap_index_threshold,
            size=index_size,
        )
        if len(index_data) < index_size:
            msg = _(b'too few index data for %s: got %d, expected %d')
            msg %= (display_id, len(index_data), index_size)
            raise error.RevlogError(msg)

    # generaldelta implied by version 2 revlogs.
    configs.delta.general_delta = True
    configs.data.generaldelta = True
    # the logic for persistent nodemap will be dealt with within the
    # main docket, so disable it for now.
    files["nodemap"] = None

    files["data"] = docket.data_filepath()
    files["sidedata"] = docket.sidedata_filepath()
    return index_data, files


def use_rust_index(
    vfs: vfsmod.vfs,
    kind: constants.Kind,
    inline: bool,
    format_version: int,
):
    """init-method: should this revlog use an index implemented in Rust

    This method is part of the initialization sequence. That initialization
    sequence is cut into multiple methods for clarity.
    """

    use_rust_index = False
    is_changelog = kind == constants.KIND_CHANGELOG
    may_rust = getattr(vfs, "rust_compatible", True)
    # we still avoid rust for inlined changelog as this create some issues.
    #
    # (See failure in test-split-legacy-inline-changelog.t)
    may_rust = may_rust and not (inline and is_changelog)
    if rustrevlog is not None and may_rust:
        use_rust_index = True

        if format_version != constants.REVLOGV1:
            use_rust_index = False

    if vfs.filter_name not in (None, 'dot-encode', 'plain'):
        use_rust_index = False
    return use_rust_index
