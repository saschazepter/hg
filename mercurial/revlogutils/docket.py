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
# * 4 bytes: revlog version
#          |   This is mandatory as docket must be compatible with the previous
#          |   revlog index header.
# * 1 bytes: size of index uuid
# * 1 bytes: number of outdated index uuid
# * 1 bytes: size of data uuid
# * 1 bytes: number of outdated data uuid
# * 1 bytes: size of sizedata uuid
# * 1 bytes: number of outdated data uuid
# * 8 bytes: size of index-data
# * 8 bytes: pending size of index-data
# * 8 bytes: size of data
# * 8 bytes: size of sidedata
# * 8 bytes: pending size of data
# * 8 bytes: pending size of sidedata
# * 1 bytes: default compression header
S_HEADER = struct.Struct(constants.INDEX_HEADER_FMT + b'BBBBBBQQQQQQc')
# * 1 bytes: size of index uuid
# * 8 bytes: size of file
S_OLD_UID = struct.Struct('>BL')

UidT = int


class FileType(enum.IntEnum):
    INDEX = 1
    DATA = 2
    SIDEDATA = 3


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

    def __init__(
        self,
        vfs,
        radix,
        file_path,
        use_pending=False,
        version_header=None,
        index_uuid=None,
        older_index_uuids=None,
        data_uuid=None,
        older_data_uuids=None,
        sidedata_uuid=None,
        older_sidedata_uuids=None,
        index_end=0,
        pending_index_end=0,
        data_end=0,
        pending_data_end=0,
        sidedata_end=0,
        pending_sidedata_end=0,
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

        if older_index_uuids is None:
            older_index_uuids = []
        if older_data_uuids is None:
            older_data_uuids = []
        if older_sidedata_uuids is None:
            older_sidedata_uuids = []
        assert not set(older_index_uuids) & set(older_data_uuids)
        assert not set(older_data_uuids) & set(older_sidedata_uuids)
        assert not set(older_index_uuids) & set(older_sidedata_uuids)
        self._older_uuids: dict[FileType, list[tuple[bytes, int]]] = {
            FileType.INDEX: older_index_uuids,
            FileType.DATA: older_data_uuids,
            FileType.SIDEDATA: older_sidedata_uuids,
        }

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
        old = (self._uuids[file_type], self._ends[file_type])
        self._older_uuids[file_type].insert(0, old)
        self._uuids[file_type] = make_uid()
        return self.filepath(file_type)

    def old_filepaths(
        self,
        file_type: FileType,
        include_empty=True,
    ) -> Iterator[HgPathT]:
        """yield file path to older index files associated to this docket"""
        # very simplistic version at first
        for uuid, size in self._older_uuids[file_type]:
            if include_empty or size > 0:
                yield self._filepath(file_type, uuid)

    def index_filepath(self) -> HgPathT:
        """file path to the current index file associated to this docket"""
        # very simplistic version at first
        return self.filepath(FileType.INDEX)

    def new_index_file(self) -> HgPathT:
        """switch index file to a new UID

        The previous index UID is moved to the "older" list."""
        return self.new_filepath(FileType.INDEX)

    def old_index_filepaths(self, include_empty=True) -> Iterator[HgPathT]:
        """yield file path to older index files associated to this docket"""
        # very simplistic version at first
        yield from self.old_filepaths(
            FileType.INDEX,
            include_empty=include_empty,
        )

    def data_filepath(self) -> HgPathT:
        """file path to the current data file associated to this docket"""
        # very simplistic version at first
        return self.filepath(FileType.DATA)

    def new_data_file(self) -> HgPathT:
        """switch data file to a new UID

        The previous data UID is moved to the "older" list."""
        return self.new_filepath(FileType.DATA)

    def old_data_filepaths(
        self, include_empty: int = True
    ) -> Iterator[HgPathT]:
        """yield file path to older data files associated to this docket"""
        yield from self.old_filepaths(
            FileType.DATA,
            include_empty=include_empty,
        )

    def sidedata_filepath(self) -> HgPathT:
        """file path to the current sidedata file associated to this docket"""
        # very simplistic version at first
        return self.filepath(FileType.SIDEDATA)

    def new_sidedata_file(self) -> HgPathT:
        """switch sidedata file to a new UID

        The previous sidedata UID is moved to the "older" list."""
        return self.new_filepath(FileType.SIDEDATA)

    def old_sidedata_filepaths(
        self, include_empty: bool = True
    ) -> Iterator[HgPathT]:
        """yield file path to older sidedata files associated to this docket"""
        # very simplistic version at first
        yield from self.old_filepaths(
            FileType.SIDEDATA,
            include_empty=include_empty,
        )

    def get_end(self, file_type: FileType) -> int:
        return self._ends[file_type]

    def set_end(self, file_type: FileType, new_size: int) -> None:
        if new_size != self._ends[file_type]:
            self._ends[file_type] = new_size
            self._dirty = True

    @property
    def index_end(self) -> int:
        return self.get_end(FileType.INDEX)

    @index_end.setter
    def index_end(self, new_size: int) -> None:
        self.set_end(FileType.INDEX, new_size)

    @property
    def data_end(self) -> int:
        return self.get_end(FileType.DATA)

    @data_end.setter
    def data_end(self, new_size: int) -> None:
        self.set_end(FileType.DATA, new_size)

    @property
    def sidedata_end(self) -> int:
        return self.get_end(FileType.SIDEDATA)

    @sidedata_end.setter
    def sidedata_end(self, new_size: int) -> None:
        self.set_end(FileType.SIDEDATA, new_size)

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
            official_index_end = self._initial_ends[FileType.INDEX]
            official_data_end = self._initial_ends[FileType.DATA]
            official_sidedata_end = self._initial_ends[FileType.SIDEDATA]
        else:
            official_index_end = self._ends[FileType.INDEX]
            official_data_end = self._ends[FileType.DATA]
            official_sidedata_end = self._ends[FileType.SIDEDATA]

        # this assert should be True as long as we have a single index filename
        assert official_data_end <= self._ends[FileType.DATA]
        assert official_sidedata_end <= self._ends[FileType.SIDEDATA]
        data = (
            self._version_header,
            len(self._uuids[FileType.INDEX]),
            len(self._older_uuids[FileType.INDEX]),
            len(self._uuids[FileType.DATA]),
            len(self._older_uuids[FileType.DATA]),
            len(self._uuids[FileType.SIDEDATA]),
            len(self._older_uuids[FileType.SIDEDATA]),
            official_index_end,
            self._ends[FileType.INDEX],
            official_data_end,
            self._ends[FileType.DATA],
            official_sidedata_end,
            self._ends[FileType.SIDEDATA],
            self.default_compression_header,
        )
        s = []
        s.append(S_HEADER.pack(*data))

        s.append(self._uuids[FileType.INDEX])
        for u, size in self._older_uuids[FileType.INDEX]:
            s.append(S_OLD_UID.pack(len(u), size))
        for u, size in self._older_uuids[FileType.INDEX]:
            s.append(u)

        s.append(self._uuids[FileType.DATA])
        for u, size in self._older_uuids[FileType.DATA]:
            s.append(S_OLD_UID.pack(len(u), size))
        for u, size in self._older_uuids[FileType.DATA]:
            s.append(u)

        s.append(self._uuids[FileType.SIDEDATA])
        for u, size in self._older_uuids[FileType.SIDEDATA]:
            s.append(S_OLD_UID.pack(len(u), size))
        for u, size in self._older_uuids[FileType.SIDEDATA]:
            s.append(u)
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


def _parse_old_uids(get_data, count) -> list[tuple[bytes, UidT]]:
    all_sizes = []
    all_uids = []
    for i in range(0, count):
        raw = get_data(S_OLD_UID.size)
        all_sizes.append(S_OLD_UID.unpack(raw))

    for uid_size, file_size in all_sizes:
        uid = get_data(uid_size)
        all_uids.append((uid, file_size))
    return all_uids


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

    index_uuid_size = next(iheader)
    index_uuid = get_data(index_uuid_size)

    older_index_uuid_count = next(iheader)
    older_index_uuids = _parse_old_uids(get_data, older_index_uuid_count)

    data_uuid_size = next(iheader)
    data_uuid = get_data(data_uuid_size)

    older_data_uuid_count = next(iheader)
    older_data_uuids = _parse_old_uids(get_data, older_data_uuid_count)

    sidedata_uuid_size = next(iheader)
    sidedata_uuid = get_data(sidedata_uuid_size)

    older_sidedata_uuid_count = next(iheader)
    older_sidedata_uuids = _parse_old_uids(get_data, older_sidedata_uuid_count)

    index_size = next(iheader)

    pending_index_size = next(iheader)

    data_size = next(iheader)

    pending_data_size = next(iheader)

    sidedata_size = next(iheader)

    pending_sidedata_size = next(iheader)

    default_compression_header = next(iheader)
    return {
        'version_header': version_header,
        'index_uuid': index_uuid,
        'older_index_uuids': older_index_uuids,
        'data_uuid': data_uuid,
        'older_data_uuids': older_data_uuids,
        'sidedata_uuid': sidedata_uuid,
        'older_sidedata_uuids': older_sidedata_uuids,
        'index_end': index_size,
        'pending_index_end': pending_index_size,
        'data_end': data_size,
        'pending_data_end': pending_data_size,
        'sidedata_end': sidedata_size,
        'pending_sidedata_end': pending_sidedata_size,
        'default_compression_header': default_compression_header,
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
        index_uuid=args['index_uuid'],
        older_index_uuids=args['older_index_uuids'],
        data_uuid=args['data_uuid'],
        older_data_uuids=args['older_data_uuids'],
        sidedata_uuid=args['sidedata_uuid'],
        older_sidedata_uuids=args['older_sidedata_uuids'],
        index_end=args['index_end'],
        pending_index_end=args['pending_index_end'],
        data_end=args['data_end'],
        pending_data_end=args['pending_data_end'],
        sidedata_end=args['sidedata_end'],
        pending_sidedata_end=args['pending_sidedata_end'],
        default_compression_header=args['default_compression_header'],
    )
    return docket
