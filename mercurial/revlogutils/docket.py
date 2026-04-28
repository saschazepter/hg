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

import enum
import struct

from typing import Iterator

from ..interfaces.types import (
    HgPathT,
)

from .. import error, util
from ..utils import docket as docket_mod

from . import (
    constants,
)

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


class FileType(enum.IntEnum):
    INDEX = 1
    DATA = 2
    SIDEDATA = 3

    @property
    def is_index(self) -> bool:
        """True when this FileType is part of indexes information

        File storing index information are handled differently. They are read
        all at once during initialization and only written to afterward.

        They don't requires the kind of read caching used by the other files.
        """
        is_index = self < self.DATA
        # too low level module to import util, manually implements propertycache
        self.__dict__["is_index"] = is_index
        return is_index


EXT = {
    FileType.INDEX: b'idx',
    FileType.DATA: b'dat',
    FileType.SIDEDATA: b'sda',
}


def file_path(file_type: FileType, radix: bytes, uuid: bytes) -> bytes:
    """compute a file path from a revlog radix, a uuid and a file type"""
    return b"%s-%s.%s" % (radix, uuid, EXT[file_type])


class RevlogDocket:
    """metadata associated with revlog"""

    # short hand to avoid having to import the module all around
    FT = FileType

    def __init__(
        self,
        vfs,
        radix,
        file_path,
        use_pending=False,
        version_header=None,
        index_uuid=None,
        data_uuid=None,
        sidedata_uuid=None,
        index_end=0,
        pending_index_end=0,
        data_end=0,
        pending_data_end=0,
        sidedata_end=0,
        pending_sidedata_end=0,
        outdated_uuids=None,
        default_compression_header=None,
    ):
        self._version_header = version_header
        self._read_only = bool(use_pending)
        self._dirty = False
        self._radix = radix
        self._path = file_path
        self._opener = vfs
        self._uuids: dict[FileType, bytes] = {}
        if index_uuid is not None:
            self._uuids[FileType.INDEX] = index_uuid
        if data_uuid is not None:
            self._uuids[FileType.DATA] = data_uuid
        if sidedata_uuid is not None:
            self._uuids[FileType.SIDEDATA] = sidedata_uuid

        if outdated_uuids is None:
            outdated_uuids = []
        self._outdated_uuids: list[tuple[FileType, bytes]] = outdated_uuids

        # thes asserts should be True as long as we have a single index filename
        assert index_end <= pending_index_end
        assert data_end <= pending_data_end
        assert sidedata_end <= pending_sidedata_end

        self._initial_ends: dict[FileType, int] = {
            FileType.INDEX: index_end,
            FileType.DATA: data_end,
            FileType.SIDEDATA: sidedata_end,
        }
        self._pending_ends: dict[FileType, int] = {
            FileType.INDEX: pending_index_end,
            FileType.DATA: pending_data_end,
            FileType.SIDEDATA: pending_sidedata_end,
        }
        if use_pending:
            self._ends: dict[FileType, int] = self._pending_ends.copy()
        else:
            self._ends: dict[FileType, int] = self._initial_ends.copy()
        self.default_compression_header = default_compression_header

    def docket_path(self) -> HgPathT:
        """file path of that docket"""
        return self._path

    def _filepath(self, file_type: FileType, uuid: bytes) -> bytes:
        return file_path(file_type, self._radix, uuid)

    def filepath(self, file_type: FileType) -> bytes:
        if self._uuids.get(file_type) is None:
            self._uuids[file_type] = make_uid()
        return self._filepath(file_type, self._uuids[file_type])

    def new_filepath(self, file_type: FileType) -> HgPathT:
        """switch index file to a new UID

        The previous index UID is moved to the "older" list."""
        # XXX if the old size is 0, we could skip adding it and delete it on
        # XXX the spot.
        self._outdated_uuids.append((file_type, self._uuids[file_type]))
        self._uuids[file_type] = make_uid()
        return self.filepath(file_type)

    def old_filepaths(self) -> Iterator[HgPathT]:
        """yield file path to older index files associated to this docket"""
        # very simplistic version at first
        for file_type, uuid in self._outdated_uuids:
            yield self._filepath(file_type, uuid)

    def get_end(self, file_type: FileType) -> int:
        return self._ends[file_type]

    def set_end(self, file_type: FileType, new_size: int) -> None:
        if new_size != self._ends[file_type]:
            self._ends[file_type] = new_size
            self._dirty = True

    def write(
        self, transaction, pending: bool = False, stripping: bool = False
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
            ends = self._initial_ends
        else:
            ends = self._ends

        # this assert should be True as long as we have a single index filename
        assert ends[FileType.INDEX] <= self._ends[FileType.INDEX]
        assert ends[FileType.DATA] <= self._ends[FileType.DATA]
        assert ends[FileType.SIDEDATA] <= self._ends[FileType.SIDEDATA]
        data = (
            self._version_header,
            self.default_compression_header,
            # currently fixed to index, data, sidedata
            3,
            3,
            len(self._outdated_uuids),
        )
        s = []
        s.append(S_HEADER.pack(*data))

        for ft in (FileType.INDEX, FileType.DATA, FileType.SIDEDATA):
            uuid = self._uuids[ft]
            size = ends.get(ft, 0)
            s.append(S_ENTRY.pack(int(ft), size, uuid))

        for ft in (FileType.INDEX, FileType.DATA, FileType.SIDEDATA):
            uuid = self._uuids[ft]
            size = self._ends.get(ft, ends.get(ft, 0))
            s.append(S_ENTRY.pack(int(ft), size, uuid))

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


def parse_docket_args(data) -> dict:
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
    assert current_count == 3
    for __ in range(0, current_count):
        ft, end, uuid = S_ENTRY.unpack(get_data(S_ENTRY.size))
        current_data[ft] = (end, uuid)

    pending_data = {}
    assert pending_count == 3
    for __ in range(0, pending_count):
        ft, end, uuid = S_ENTRY.unpack(get_data(S_ENTRY.size))
        pending_data[ft] = (end, uuid)

    older_uuids = []
    for __ in range(outdated_count):
        ft, uuid = S_OLD_ENTRY.unpack(get_data(S_OLD_ENTRY.size))
        older_uuids.append((ft, uuid))

    return {
        'version_header': version_header,
        'default_compression_header': default_compression_header,
        'current': current_data,
        'pending': pending_data,
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
        version_header=args['version_header'],
        default_compression_header=args['default_compression_header'],
        index_uuid=args['current'][FileType.INDEX][1],
        data_uuid=args['current'][FileType.DATA][1],
        sidedata_uuid=args['current'][FileType.SIDEDATA][1],
        index_end=args['current'][FileType.INDEX][0],
        data_end=args['current'][FileType.DATA][0],
        sidedata_end=args['current'][FileType.SIDEDATA][0],
        pending_index_end=args['pending'][FileType.INDEX][0],
        pending_data_end=args['pending'][FileType.DATA][0],
        pending_sidedata_end=args['pending'][FileType.SIDEDATA][0],
        outdated_uuids=args['outdated_uuids'],
    )
    return docket
