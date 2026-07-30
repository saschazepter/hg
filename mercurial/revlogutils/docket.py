# docket - code related to revlog "docket"
#
# Copyright 2021 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

### Revlog docket file
#
# The revlog is stored on disk using multiple files:
#
# * a small docket file, containing metadata and a pointer,
#
# * an index file, containing fixed width information about revisions,
#
# * a data file, containing variable width data for these revisions,

from __future__ import annotations

import struct
import typing

from typing import (
    Dict,
    Iterator,
    TypedDict,
)

from ..interfaces.types import (
    HgPathT,
    VfsT,
)

from ..thirdparty import attr
from .. import error, revlogutils, util
from ..utils import docket as docket_mod

from . import (
    constants,
)

if typing.TYPE_CHECKING:
    import attr


make_uid = docket_mod.make_uid


# Docket format
#
# Fixed size header:
S_HEADER = struct.Struct(
    # * 4 bytes: revlog version
    #          |   This is mandatory as docket must be compatible with the
    #          |    previous revlog index header.
    constants.INDEX_HEADER_FMT
    # * 1 byte:  default compression header
    + b's'
    # * 1 byte:  number of current uuids (A)
    + b'B'
    # * 1 byte:  number of pending uuids (B)
    + b'B'
    # * 1 byte:  number of outdated uuids (C)
    + b'B'
)
# "current" section:
# * A groups of:
#   * 1 byte:  file type for each entry
#   * 8 bytes: size for each entry
#   * UID_SIZE bytes: uuis for each entry
#
# * B groups of:
#   * 1 byte:  file type for each ENTRY
#   * 8 bytes: size for each entry
#   * UID_SIZE bytes: uuis for each entry
S_ENTRY = struct.Struct('>BQ%ds' % docket_mod.UID_SIZE)  # and U bytes
# "outdated" section:
# * C group of:
#   * 1 byte:  file type for each ENTRYy
#   * UID_SIZE bytes: uuis for each entry
S_OLD_ENTRY = struct.Struct('>B%ds' % docket_mod.UID_SIZE)  # and U bytes

UidT = int

FileType = constants.V2FileType
EXT = constants.V2_FILE_TYPE_EXT

_UuidT = bytes
"""type alias that helps to clarify type signature"""


@attr.s
class BlockInfo:
    """hold attributes of a index/data block tracked by a docket"""

    uuid = attr.ib(type=_UuidT)
    """The uuid used for that data block"""

    end = attr.ib(type=int, default=0)
    """The number of bytes marking the end of the active data"""

    def serialize(self, file_type: FileType) -> bytes:
        return S_ENTRY.pack(
            int(file_type),
            self.end,
            self.uuid,
        )

    @staticmethod
    def deserialize(data: bytes) -> tuple[FileType, BlockInfo]:
        pieces = S_ENTRY.unpack(data)
        block = BlockInfo(
            uuid=pieces[2],
            end=pieces[1],
        )
        return (FileType(pieces[0]), block)


def file_path(file_type: FileType, radix: bytes, uuid: bytes) -> bytes:
    """compute a file path from a revlog radix, a uuid and a file type"""
    return b"%s-%s.%s" % (radix, uuid, EXT[file_type])


_BlockIndexT = Dict[FileType, BlockInfo]
"""Type alias to simplify and align definitions"""


class RevlogDocket:
    """metadata associated with revlog"""

    # short hand to avoid having to import the module all around
    FT = FileType

    _initial: _BlockIndexT | None
    _current: _BlockIndexT

    def __init__(
        self,
        vfs: VfsT,
        radix: HgPathT,
        file_path: HgPathT,
        use_pending: bool = False,
        version_header: int | None = None,
        default_compression_header: revlogutils.CompModeT | None = None,
        blocks: tuple[_BlockIndexT, _BlockIndexT] | None = None,
        pending: _BlockIndexT | None = None,
        outdated_uuids: list[tuple[FileType, _UuidT]] | None = None,
    ):
        assert version_header is not None
        self._version_header: int = version_header
        self._dirty: bool = False
        self._radix: HgPathT = radix
        self._path: HgPathT = file_path
        self._opener: VfsT = vfs
        self._initial: _BlockIndexT | None = None
        if blocks is None:
            base, pending = {}, {}
            has_pending = False
        else:
            base, pending = blocks
            # if the pending data are different from the current data, we are
            # reading a docket written during a pending transaction by another
            # "process". We can't start updating data with such docket as we
            # need to let the other process commit or rollback its transaction
            # first. We will have to reload the docket with up to date
            # information at that time.
            #
            # This means we have three case overall:
            # - explicit use of `pending` data:
            #   → read only use of  "pending"   data.
            # - reading data that highlight another writer active:
            #   → read only use of "current" data.
            # - base == pending:
            #   →  read write, base will not change, we will write the updated
            #   version as pending.
            has_pending = base != pending

            if has_pending:
                for ft, block in sorted(base.items()):
                    assert ft in pending
                    if pending[ft].uuid == block.uuid:
                        assert block.end <= pending[ft].end

        if use_pending:
            self._current = pending
        elif has_pending:
            self._current = base
        else:
            self._initial = base
            self._current = pending

        if outdated_uuids is None:
            outdated_uuids = []
        self._outdated_uuids: list[tuple[FileType, _UuidT]] = outdated_uuids
        assert default_compression_header is not None
        self.default_compression_header = default_compression_header

    @util.propertycache
    def _read_only(self) -> bool:
        return self._initial is None

    @util.propertycache
    def active_fts(self) -> tuple[FileType]:
        """The list of active file types for the revlog variant of this docket

        Ordering matter as this will control the order in which they will be
        open, and close.

        It seems like good hygiene to keep consistent in terms of data
        referencing each other (e.g, making sure we open indexes first and close
        them last.). However unlinke revlog-v1 where this was a hard
        requirements, the docket used here should garantee that we ever only
        access consistent data (as long as the docket is open first, and written
        last, as it should be)

        Regardless of consistency, keeping the order consistent makes testing
        and debugging simpler.
        """
        features = constants.FEATURES_BY_VERSION[self._version_header]
        return tuple(sorted(features['active_file_types']))

    @util.propertycache
    def index_fts(self) -> tuple[FileType]:
        return tuple(ft for ft in self.active_fts if ft.is_index)

    def docket_path(self) -> HgPathT:
        """file path of that docket"""
        return self._path

    def _filepath(self, file_type: FileType, uuid: _UuidT) -> bytes:
        return file_path(file_type, self._radix, uuid)

    def filepath(self, file_type: FileType) -> bytes:
        if self._current.get(file_type) is None:
            self._current[file_type] = BlockInfo(uuid=make_uid())
        return self._filepath(file_type, self._current[file_type].uuid)

    def new_filepath(self, file_type: FileType) -> HgPathT:
        """switch index file to a new UID

        The previous index UID is moved to the "older" list."""
        if self._read_only:
            msg = b'updating read-only docket: %s'
            msg %= self._path
            raise error.ProgrammingError(msg)
        # XXX if the old size is 0, we could skip adding it and delete it on
        # XXX the spot.
        old = self._current[file_type]
        new_uuid = make_uid()
        assert new_uuid != old.uuid
        self._outdated_uuids.append((file_type, old.uuid))
        self._current[file_type] = BlockInfo(uuid=new_uuid, end=old.end)
        self._dirty = True
        return self.filepath(file_type)

    def old_filepaths(self) -> Iterator[HgPathT]:
        """yield file path to older index files associated to this docket"""
        # very simplistic version at first
        for file_type, uuid in self._outdated_uuids:
            yield self._filepath(file_type, uuid)

    def get_end(self, file_type: FileType) -> int:
        return self._current[file_type].end

    def set_end(self, file_type: FileType, new_size: int) -> None:
        if self._read_only:
            msg = b'updating read-only docket: %s'
            msg %= self._path
            raise error.ProgrammingError(msg)
        if new_size != self._current[file_type].end:
            self._current[file_type].end = new_size
            self._dirty = True

    def is_pending_offset(self, file_type: FileType, offset: int) -> bool:
        assert self._initial is not None
        if file_type not in self._initial:
            return True
        assert file_type in self._current
        initial = self._initial[file_type]
        current = self._current[file_type]
        if initial.uuid != current.uuid:
            return True
        return initial.end <= offset

    def write(
        self,
        transaction,
        pending: bool = False,
        stripping: bool = False,
    ) -> bool:
        """write the modification of disk if any

        This make the new content visible to all process"""
        if not self._dirty:
            return False
        else:
            if self._read_only:
                msg = b'writing read-only docket: %s'
                msg %= self._path
                raise error.ProgrammingError(msg)
            if not stripping:
                # XXX we could, leverage the docket while stripping. However it
                # is not powerfull enough at the time of this comment
                transaction.addbackup(self._path, location=b'store')
            with self._opener(self._path, mode=b'w', atomictemp=True) as f:
                f.write(self._serialize(pending=pending))
            # if pending we still need to the write final data eventually
            self._dirty = pending
            return True

    def _serialize(self, pending: bool = False) -> bytes:
        if pending:
            info = self._initial
        else:
            info = self._current

        data = (
            self._version_header,
            self.default_compression_header,
            # currently fixed to index, data, sidedata
            len(info),
            len(self._current),
            len(self._outdated_uuids),
        )
        s = []
        s.append(S_HEADER.pack(*data))

        for ft, block in sorted(info.items()):
            s.append(block.serialize(ft))

        for ft, block in sorted(self._current.items()):
            s.append(block.serialize(ft))

        for ft, uuid in self._outdated_uuids:
            s.append(S_OLD_ENTRY.pack(ft, uuid))
        return b''.join(s)


def default_docket(
    vfs,
    radix,
    file_path,
    configs,
    version_header,
) -> RevlogDocket | None:
    """given a revlog version a new docket object for the given revlog"""
    rl_version = version_header & 0xFFFF
    if rl_version not in (constants.REVLOGV2, constants.CHANGELOGV2):
        return None
    comp = util.compengines[configs.feature.compression_engine].revlogheader()
    docket = RevlogDocket(
        vfs,
        radix,
        file_path,
        version_header=version_header,
        default_compression_header=comp,
    )
    docket._dirty = True
    return docket


class _DocketArgsT(TypedDict):
    version_header: int
    default_compression_header: int
    blocks: tuple[_BlockIndexT, _BlockIndexT]
    outdated_uuids: list[tuple[FileType, _UuidT]]


def parse_docket_args(data) -> _DocketArgsT:
    """given some docket data return the argument to initialize a docket"""
    header = S_HEADER.unpack(data[: S_HEADER.size])

    # this is a mutable closure capture used in `get_data`
    offset = [S_HEADER.size]

    def get_data(size) -> bytes:
        """utility closure to access the `size` next bytes"""
        if offset[0] + size > len(data):
            # XXX better class
            msg = b"docket is too short, expected %d got %d"
            msg %= (offset[0] + size, len(data))
            raise error.Abort(msg)
        raw = data[offset[0] : offset[0] + size]
        offset[0] += size
        return raw

    iheader = iter(header)

    version_header = next(iheader)
    default_compression_header = next(iheader)

    current_count = next(iheader)
    pending_count = next(iheader)
    outdated_count = next(iheader)

    current_data = {}
    for __ in range(0, current_count):
        ft, block = BlockInfo.deserialize(get_data(S_ENTRY.size))
        current_data[ft] = block

    pending_data = {}
    for __ in range(0, pending_count):
        ft, block = BlockInfo.deserialize(get_data(S_ENTRY.size))
        pending_data[ft] = block

    older_uuids = []
    for __ in range(outdated_count):
        ft, uuid = S_OLD_ENTRY.unpack(get_data(S_OLD_ENTRY.size))
        older_uuids.append((FileType(ft), uuid))

    return {
        'version_header': version_header,
        'default_compression_header': default_compression_header,
        'blocks': (current_data, pending_data),
        'outdated_uuids': older_uuids,
    }


def parse_docket(
    vfs,
    radix,
    file_path,
    data,
    use_pending=False,
) -> RevlogDocket:
    """given some docket data return a docket object for the given revlog"""
    args = parse_docket_args(data)
    docket = RevlogDocket(
        vfs,
        radix,
        file_path,
        use_pending=use_pending,
        **args,
    )
    return docket
