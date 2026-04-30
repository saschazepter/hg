# ext-sidedata.py - small extension to test the sidedata logic
#
# Copyright 2019 Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.


import hashlib
import struct

from mercurial.node import nullrev
from mercurial import (
    extensions,
    requirements,
    revlog,
)

from mercurial.revlogutils import constants
from mercurial.revlogutils import sidedata


def wrapaddrevision(
    orig, self, text, transaction, link, p1, p2, *args, **kwargs
):
    if self.revlog_kind == constants.KIND_MANIFESTLOG:
        other_data = kwargs.get('other_data')
        if other_data is None:
            other_data = {}
            kwargs["other_data"] = other_data
        if constants.V2FileType.SIDEDATA in other_data:
            sd_bin = other_data[constants.V2FileType.SIDEDATA]
            sd = sidedata.deserialize_sidedata(sd_bin)
        else:
            sd = {}
        ## let's store some arbitrary data just for testing
        # text length
        sd[sidedata.SD_TEST1] = struct.pack('>I', len(text))
        # and sha2 hashes
        sha256 = hashlib.sha256(text).digest()
        sd[sidedata.SD_TEST2] = struct.pack('>32s', sha256)
        other_data[constants.V2FileType.SIDEDATA] = sidedata.serialize_sidedata(
            sd
        )
    return orig(self, text, transaction, link, p1, p2, *args, **kwargs)


def wrap_revisiondata(orig, self, nodeorrev, *args, **kwargs):
    text = orig(self, nodeorrev, *args, **kwargs)
    sd = self.sidedata(nodeorrev)
    if getattr(self, 'sidedatanocheck', False):
        return text
    if self.feature_config.has_side_data:
        return text
    if nodeorrev != nullrev and nodeorrev != self.nullid:
        cat1 = sd.get(sidedata.SD_TEST1)
        if cat1 is not None and len(text) != struct.unpack('>I', cat1)[0]:
            raise RuntimeError('text size mismatch')
        expected = sd.get(sidedata.SD_TEST2)
        got = hashlib.sha256(text).digest()
        if expected is not None and got != expected:
            raise RuntimeError('sha256 mismatch')
    return text


def extsetup(ui):
    extensions.wrapfunction(revlog.revlog, 'addrevision', wrapaddrevision)
    extensions.wrapfunction(revlog.revlog, '_revisiondata', wrap_revisiondata)


def _sd_computer(repo, revlog, rev, old_sidedata):
    assert not old_sidedata  # not supported yet
    update = {}
    revlog.sidedatanocheck = True
    try:
        text = revlog.revision(rev)
    finally:
        del revlog.sidedatanocheck
    ## let's store some arbitrary data just for testing
    # text length
    update[sidedata.SD_TEST1] = struct.pack('>I', len(text))
    # and sha2 hashes
    sha256 = hashlib.sha256(text).digest()
    update[sidedata.SD_TEST2] = struct.pack('>32s', sha256)
    return update, (0, 0)


def reposetup(ui, repo):
    if requirements.REVLOGV2_REQUIREMENT in repo.requirements:
        repo.register_wanted_sidedata(b"test-1-2")
    repo.register_sidedata_computer(
        constants.KIND_MANIFESTLOG,
        b"test-1-2",
        (sidedata.SD_TEST1, sidedata.SD_TEST2),
        _sd_computer,
        0,
    )
