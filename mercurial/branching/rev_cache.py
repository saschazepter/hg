# rev_cache.py - caching branch information per revision
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
from __future__ import annotations

import struct

from ..node import (
    nullrev,
)

from .. import (
    encoding,
    error,
    util,
)

from ..utils import (
    stringutil,
)

calcsize = struct.calcsize
pack_into = struct.pack_into
unpack_from = struct.unpack_from


# Revision branch info cache

_rbcversion = b'-v1'
_rbcnames = b'rbc-names' + _rbcversion
_rbcrevs = b'rbc-revs' + _rbcversion
# [4 byte hash prefix][4 byte branch name number with sign bit indicating open]
_rbcrecfmt = b'>4sI'
_rbcrecsize = calcsize(_rbcrecfmt)
_rbcmininc = 64 * _rbcrecsize
_rbcnodelen = 4
_rbcbranchidxmask = 0x7FFFFFFF
_rbccloseflag = 0x80000000


class rbcrevs:
    """a byte string consisting of an immutable prefix followed by a mutable suffix"""

    def __init__(self, revs):
        self._prefix = revs
        self._rest = bytearray()

    def __len__(self):
        return len(self._prefix) + len(self._rest)

    def unpack_record(self, rbcrevidx):
        if rbcrevidx < len(self._prefix):
            return unpack_from(_rbcrecfmt, util.buffer(self._prefix), rbcrevidx)
        else:
            return unpack_from(
                _rbcrecfmt,
                util.buffer(self._rest),
                rbcrevidx - len(self._prefix),
            )

    def make_mutable(self):
        if len(self._prefix) > 0:
            entirety = bytearray()
            entirety[:] = self._prefix
            entirety.extend(self._rest)
            self._rest = entirety
            self._prefix = bytearray()

    def truncate(self, pos):
        self.make_mutable()
        del self._rest[pos:]

    def pack_into(self, rbcrevidx, node, branchidx):
        if rbcrevidx < len(self._prefix):
            self.make_mutable()
        buf = self._rest
        start_offset = rbcrevidx - len(self._prefix)
        end_offset = start_offset + _rbcrecsize

        if len(self._rest) < end_offset:
            # bytearray doesn't allocate extra space at least in Python 3.7.
            # When multiple changesets are added in a row, precise resize would
            # result in quadratic complexity. Overallocate to compensate by
            # using the classic doubling technique for dynamic arrays instead.
            # If there was a gap in the map before, less space will be reserved.
            self._rest.extend(b'\0' * end_offset)
        return pack_into(
            _rbcrecfmt,
            buf,
            start_offset,
            node,
            branchidx,
        )

    def extend(self, extension):
        return self._rest.extend(extension)

    def slice(self, begin, end):
        if begin < len(self._prefix):
            acc = bytearray()
            acc[:] = self._prefix[begin:end]
            acc.extend(
                self._rest[begin - len(self._prefix) : end - len(self._prefix)]
            )
            return acc
        return self._rest[begin - len(self._prefix) : end - len(self._prefix)]


class revbranchcache:
    """Persistent cache, mapping from revision number to branch name and close.
    This is a low level cache, independent of filtering.

    Branch names are stored in rbc-names in internal encoding separated by 0.
    rbc-names is append-only, and each branch name is only stored once and will
    thus have a unique index.

    The branch info for each revision is stored in rbc-revs as constant size
    records. The whole file is read into memory, but it is only 'parsed' on
    demand. The file is usually append-only but will be truncated if repo
    modification is detected.
    The record for each revision contains the first 4 bytes of the
    corresponding node hash, and the record is only used if it still matches.
    Even a completely trashed rbc-revs fill thus still give the right result
    while converging towards full recovery ... assuming no incorrectly matching
    node hashes.
    The record also contains 4 bytes where 31 bits contains the index of the
    branch and the last bit indicate that it is a branch close commit.
    The usage pattern for rbc-revs is thus somewhat similar to 00changelog.i
    and will grow with it but be 1/8th of its size.
    """

    def __init__(self, repo, readonly=True):
        assert repo.filtername is None
        self._repo = repo
        self._names = []  # branch names in local encoding with static index
        self._rbcrevs = rbcrevs(bytearray())
        self._rbcsnameslen = 0  # length of names read at _rbcsnameslen
        try:
            bndata = repo.cachevfs.read(_rbcnames)
            self._rbcsnameslen = len(bndata)  # for verification before writing
            if bndata:
                self._names = [
                    encoding.tolocal(bn) for bn in bndata.split(b'\0')
                ]
        except (IOError, OSError):
            if readonly:
                # don't try to use cache - fall back to the slow path
                self.branchinfo = self._branchinfo

        if self._names:
            try:
                usemmap = repo.ui.configbool(b'storage', b'revbranchcache.mmap')
                with repo.cachevfs(_rbcrevs) as fp:
                    if usemmap and repo.cachevfs.is_mmap_safe(_rbcrevs):
                        data = util.buffer(util.mmapread(fp))
                    else:
                        data = fp.read()
                self._rbcrevs = rbcrevs(data)
            except (IOError, OSError) as inst:
                repo.ui.debug(
                    b"couldn't read revision branch cache: %s\n"
                    % stringutil.forcebytestr(inst)
                )
        # remember number of good records on disk
        self._rbcrevslen = min(
            len(self._rbcrevs) // _rbcrecsize, len(repo.changelog)
        )
        if self._rbcrevslen == 0:
            self._names = []
        self._rbcnamescount = len(self._names)  # number of names read at
        # _rbcsnameslen

    def _clear(self):
        self._rbcsnameslen = 0
        del self._names[:]
        self._rbcnamescount = 0
        self._rbcrevslen = len(self._repo.changelog)
        self._rbcrevs = rbcrevs(bytearray(self._rbcrevslen * _rbcrecsize))
        util.clearcachedproperty(self, b'_namesreverse')

    @util.propertycache
    def _namesreverse(self):
        return {b: r for r, b in enumerate(self._names)}

    def branchinfo(self, rev):
        """Return branch name and close flag for rev, using and updating
        persistent cache."""
        changelog = self._repo.changelog
        rbcrevidx = rev * _rbcrecsize

        # avoid negative index, changelog.read(nullrev) is fast without cache
        if rev == nullrev:
            return changelog.branchinfo(rev)

        # if requested rev isn't allocated, grow and cache the rev info
        if len(self._rbcrevs) < rbcrevidx + _rbcrecsize:
            return self._branchinfo(rev)

        # fast path: extract data from cache, use it if node is matching
        reponode = changelog.node(rev)[:_rbcnodelen]
        cachenode, branchidx = self._rbcrevs.unpack_record(rbcrevidx)
        close = bool(branchidx & _rbccloseflag)
        if close:
            branchidx &= _rbcbranchidxmask
        if cachenode == b'\0\0\0\0':
            pass
        elif cachenode == reponode:
            try:
                return self._names[branchidx], close
            except IndexError:
                # recover from invalid reference to unknown branch
                self._repo.ui.debug(
                    b"referenced branch names not found"
                    b" - rebuilding revision branch cache from scratch\n"
                )
                self._clear()
        else:
            # rev/node map has changed, invalidate the cache from here up
            self._repo.ui.debug(
                b"history modification detected - truncating "
                b"revision branch cache to revision %d\n" % rev
            )
            truncate = rbcrevidx + _rbcrecsize
            self._rbcrevs.truncate(truncate)
            self._rbcrevslen = min(self._rbcrevslen, truncate)

        # fall back to slow path and make sure it will be written to disk
        return self._branchinfo(rev)

    def _branchinfo(self, rev):
        """Retrieve branch info from changelog and update _rbcrevs"""
        changelog = self._repo.changelog
        b, close = changelog.branchinfo(rev)
        if b in self._namesreverse:
            branchidx = self._namesreverse[b]
        else:
            branchidx = len(self._names)
            self._names.append(b)
            self._namesreverse[b] = branchidx
        reponode = changelog.node(rev)
        if close:
            branchidx |= _rbccloseflag
        self._setcachedata(rev, reponode, branchidx)
        return b, close

    def setdata(self, rev, changelogrevision):
        """add new data information to the cache"""
        branch, close = changelogrevision.branchinfo

        if branch in self._namesreverse:
            branchidx = self._namesreverse[branch]
        else:
            branchidx = len(self._names)
            self._names.append(branch)
            self._namesreverse[branch] = branchidx
        if close:
            branchidx |= _rbccloseflag
        self._setcachedata(rev, self._repo.changelog.node(rev), branchidx)
        # If no cache data were readable (non exists, bad permission, etc)
        # the cache was bypassing itself by setting:
        #
        #   self.branchinfo = self._branchinfo
        #
        # Since we now have data in the cache, we need to drop this bypassing.
        if 'branchinfo' in vars(self):
            del self.branchinfo

    def _setcachedata(self, rev, node, branchidx):
        """Writes the node's branch data to the in-memory cache data."""
        if rev == nullrev:
            return
        rbcrevidx = rev * _rbcrecsize
        self._rbcrevs.pack_into(rbcrevidx, node, branchidx)
        self._rbcrevslen = min(self._rbcrevslen, rev)

        tr = self._repo.currenttransaction()
        if tr:
            tr.addfinalize(b'write-revbranchcache', self.write)

    def write(self, tr=None):
        """Save branch cache if it is dirty."""
        repo = self._repo
        wlock = None
        step = b''
        try:
            # write the new names
            if self._rbcnamescount < len(self._names):
                wlock = repo.wlock(wait=False)
                step = b' names'
                self._writenames(repo)

            # write the new revs
            start = self._rbcrevslen * _rbcrecsize
            if start != len(self._rbcrevs):
                step = b''
                if wlock is None:
                    wlock = repo.wlock(wait=False)
                self._writerevs(repo, start)

        except (IOError, OSError, error.Abort, error.LockError) as inst:
            repo.ui.debug(
                b"couldn't write revision branch cache%s: %s\n"
                % (step, stringutil.forcebytestr(inst))
            )
        finally:
            if wlock is not None:
                wlock.release()

    def _writenames(self, repo):
        """write the new branch names to revbranchcache"""
        if self._rbcnamescount != 0:
            f = repo.cachevfs.open(_rbcnames, b'ab')
            if f.tell() == self._rbcsnameslen:
                f.write(b'\0')
            else:
                f.close()
                repo.ui.debug(b"%s changed - rewriting it\n" % _rbcnames)
                self._rbcnamescount = 0
                self._rbcrevslen = 0
        if self._rbcnamescount == 0:
            # before rewriting names, make sure references are removed
            repo.cachevfs.unlinkpath(_rbcrevs, ignoremissing=True)
            f = repo.cachevfs.open(_rbcnames, b'wb')
        f.write(
            b'\0'.join(
                encoding.fromlocal(b)
                for b in self._names[self._rbcnamescount :]
            )
        )
        self._rbcsnameslen = f.tell()
        f.close()
        self._rbcnamescount = len(self._names)

    def _writerevs(self, repo, start):
        """write the new revs to revbranchcache"""
        revs = min(len(repo.changelog), len(self._rbcrevs) // _rbcrecsize)
        with repo.cachevfs.open(_rbcrevs, b'ab') as f:
            if f.tell() != start:
                repo.ui.debug(
                    b"truncating cache/%s to %d\n" % (_rbcrevs, start)
                )
                f.seek(start)
                if f.tell() != start:
                    start = 0
                    f.seek(start)
                f.truncate()
            end = revs * _rbcrecsize
            f.write(self._rbcrevs.slice(start, end))
        self._rbcrevslen = revs
