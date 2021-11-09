# simplestorerepo.py - Extension that swaps in alternate repository storage.
#
# Copyright 2018 Gregory Szorc <gregory.szorc@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

# To use this with the test suite:
#
#   $ HGREPOFEATURES="simplestore" ./run-tests.py \
#       --extra-config-opt extensions.simplestore=`pwd`/simplestorerepo.py

from __future__ import absolute_import

import stat

from mercurial.i18n import _
from mercurial.node import (
    bin,
    hex,
    nullrev,
)
from mercurial.thirdparty import attr
from mercurial import (
    ancestor,
    bundlerepo,
    error,
    extensions,
    localrepo,
    mdiff,
    pycompat,
    revlog,
    store,
    verify,
)
from mercurial.interfaces import (
    repository,
    util as interfaceutil,
)
from mercurial.utils import (
    cborutil,
    storageutil,
)
from mercurial.revlogutils import flagutil

# Note for extension authors: ONLY specify testedwith = 'ships-with-hg-core' for
# extensions which SHIP WITH MERCURIAL. Non-mainline extensions should
# be specifying the version(s) of Mercurial they are tested with, or
# leave the attribute unspecified.
testedwith = b'ships-with-hg-core'

REQUIREMENT = b'testonly-simplestore'


def validatenode(node):
    if isinstance(node, int):
        raise ValueError('expected node; got int')

    if len(node) != 20:
        raise ValueError('expected 20 byte node')


def validaterev(rev):
    if not isinstance(rev, int):
        raise ValueError('expected int')


class simplestoreerror(error.StorageError):
    pass


@interfaceutil.implementer(repository.irevisiondelta)
@attr.s(slots=True)
class simplestorerevisiondelta(object):
    node = attr.ib()
    p1node = attr.ib()
    p2node = attr.ib()
    basenode = attr.ib()
    flags = attr.ib()
    baserevisionsize = attr.ib()
    revision = attr.ib()
    delta = attr.ib()
    linknode = attr.ib(default=None)


@interfaceutil.implementer(repository.iverifyproblem)
@attr.s(frozen=True)
class simplefilestoreproblem(object):
    warning = attr.ib(default=None)
    error = attr.ib(default=None)
    node = attr.ib(default=None)


@interfaceutil.implementer(repository.ifilestorage)
class filestorage(object):
    """Implements storage for a tracked path.

    Data is stored in the VFS in a directory corresponding to the tracked
    path.

    Index data is stored in an ``index`` file using CBOR.

    Fulltext data is stored in files having names of the node.
    """

    _flagserrorclass = simplestoreerror

    def __init__(self, repo, svfs, path):
        self.nullid = repo.nullid
        self._repo = repo
        self._svfs = svfs
        self._path = path

        self._storepath = b'/'.join([b'data', path])
        self._indexpath = b'/'.join([self._storepath, b'index'])

        indexdata = self._svfs.tryread(self._indexpath)
        if indexdata:
            indexdata = cborutil.decodeall(indexdata)

        self._indexdata = indexdata or []
        self._indexbynode = {}
        self._indexbyrev = {}
        self._index = []
        self._refreshindex()

        self._flagprocessors = dict(flagutil.flagprocessors)

    def _refreshindex(self):
        self._indexbynode.clear()
        self._indexbyrev.clear()
        self._index = []

        for i, entry in enumerate(self._indexdata):
            self._indexbynode[entry[b'node']] = entry
            self._indexbyrev[i] = entry

        self._indexbynode[self._repo.nullid] = {
            b'node': self._repo.nullid,
            b'p1': self._repo.nullid,
            b'p2': self._repo.nullid,
            b'linkrev': nullrev,
            b'flags': 0,
        }

        self._indexbyrev[nullrev] = {
            b'node': self._repo.nullid,
            b'p1': self._repo.nullid,
            b'p2': self._repo.nullid,
            b'linkrev': nullrev,
            b'flags': 0,
        }

        for i, entry in enumerate(self._indexdata):
            p1rev, p2rev = self.parentrevs(self.rev(entry[b'node']))

            # start, length, rawsize, chainbase, linkrev, p1, p2, node
            self._index.append(
                (0, 0, 0, -1, entry[b'linkrev'], p1rev, p2rev, entry[b'node'])
            )

        self._index.append((0, 0, 0, -1, -1, -1, -1, self._repo.nullid))

    def __len__(self):
        return len(self._indexdata)

    def __iter__(self):
        return iter(range(len(self)))

    def revs(self, start=0, stop=None):
        step = 1
        if stop is not None:
            if start > stop:
                step = -1

            stop += step
        else:
            stop = len(self)

        return range(start, stop, step)

    def parents(self, node):
        validatenode(node)

        if node not in self._indexbynode:
            raise KeyError('unknown node')

        entry = self._indexbynode[node]

        return entry[b'p1'], entry[b'p2']

    def parentrevs(self, rev):
        p1, p2 = self.parents(self._indexbyrev[rev][b'node'])
        return self.rev(p1), self.rev(p2)

    def rev(self, node):
        validatenode(node)

        try:
            self._indexbynode[node]
        except KeyError:
            raise error.LookupError(node, self._indexpath, _('no node'))

        for rev, entry in self._indexbyrev.items():
            if entry[b'node'] == node:
                return rev

        raise error.ProgrammingError(b'this should not occur')

    def node(self, rev):
        validaterev(rev)

        return self._indexbyrev[rev][b'node']

    def hasnode(self, node):
        validatenode(node)
        return node in self._indexbynode

    def censorrevision(self, tr, censornode, tombstone=b''):
        raise NotImplementedError('TODO')

    def lookup(self, node):
        if isinstance(node, int):
            return self.node(node)

        if len(node) == 20:
            self.rev(node)
            return node

        try:
            rev = int(node)
            if '%d' % rev != node:
                raise ValueError

            if rev < 0:
                rev = len(self) + rev
            if rev < 0 or rev >= len(self):
                raise ValueError

            return self.node(rev)
        except (ValueError, OverflowError):
            pass

        if len(node) == 40:
            try:
                rawnode = bin(node)
                self.rev(rawnode)
                return rawnode
            except TypeError:
                pass

        raise error.LookupError(node, self._path, _('invalid lookup input'))

    def linkrev(self, rev):
        validaterev(rev)

        return self._indexbyrev[rev][b'linkrev']

    def _flags(self, rev):
        validaterev(rev)

        return self._indexbyrev[rev][b'flags']

    def _candelta(self, baserev, rev):
        validaterev(baserev)
        validaterev(rev)

        if (self._flags(baserev) & revlog.REVIDX_RAWTEXT_CHANGING_FLAGS) or (
            self._flags(rev) & revlog.REVIDX_RAWTEXT_CHANGING_FLAGS
        ):
            return False

        return True

    def checkhash(self, text, node, p1=None, p2=None, rev=None):
        if p1 is None and p2 is None:
            p1, p2 = self.parents(node)
        if node != storageutil.hashrevisionsha1(text, p1, p2):
            raise simplestoreerror(
                _("integrity check failed on %s") % self._path
            )

    def revision(self, nodeorrev, raw=False):
        if isinstance(nodeorrev, int):
            node = self.node(nodeorrev)
        else:
            node = nodeorrev
        validatenode(node)

        if node == self._repo.nullid:
            return b''

        rev = self.rev(node)
        flags = self._flags(rev)

        path = b'/'.join([self._storepath, hex(node)])
        rawtext = self._svfs.read(path)

        if raw:
            validatehash = flagutil.processflagsraw(self, rawtext, flags)
            text = rawtext
        else:
            r = flagutil.processflagsread(self, rawtext, flags)
            text, validatehash = r
        if validatehash:
            self.checkhash(text, node, rev=rev)

        return text

    def rawdata(self, nodeorrev):
        return self.revision(raw=True)

    def read(self, node):
        validatenode(node)

        revision = self.revision(node)

        if not revision.startswith(b'\1\n'):
            return revision

        start = revision.index(b'\1\n', 2)
        return revision[start + 2 :]

    def renamed(self, node):
        validatenode(node)

        if self.parents(node)[0] != self._repo.nullid:
            return False

        fulltext = self.revision(node)
        m = storageutil.parsemeta(fulltext)[0]

        if m and 'copy' in m:
            return m['copy'], bin(m['copyrev'])

        return False

    def cmp(self, node, text):
        validatenode(node)

        t = text

        if text.startswith(b'\1\n'):
            t = b'\1\n\1\n' + text

        p1, p2 = self.parents(node)

        if storageutil.hashrevisionsha1(t, p1, p2) == node:
            return False

        if self.iscensored(self.rev(node)):
            return text != b''

        if self.renamed(node):
            t2 = self.read(node)
            return t2 != text

        return True

    def size(self, rev):
        validaterev(rev)

        node = self._indexbyrev[rev][b'node']

        if self.renamed(node):
            return len(self.read(node))

        if self.iscensored(rev):
            return 0

        return len(self.revision(node))

    def iscensored(self, rev):
        validaterev(rev)

        return self._flags(rev) & repository.REVISION_FLAG_CENSORED

    def commonancestorsheads(self, a, b):
        validatenode(a)
        validatenode(b)

        a = self.rev(a)
        b = self.rev(b)

        ancestors = ancestor.commonancestorsheads(self.parentrevs, a, b)
        return pycompat.maplist(self.node, ancestors)

    def descendants(self, revs):
        # This is a copy of revlog.descendants()
        first = min(revs)
        if first == nullrev:
            for i in self:
                yield i
            return

        seen = set(revs)
        for i in self.revs(start=first + 1):
            for x in self.parentrevs(i):
                if x != nullrev and x in seen:
                    seen.add(i)
                    yield i
                    break

    # Required by verify.
    def files(self):
        entries = self._svfs.listdir(self._storepath)

        # Strip out undo.backup.* files created as part of transaction
        # recording.
        entries = [f for f in entries if not f.startswith('undo.backup.')]

        return [b'/'.join((self._storepath, f)) for f in entries]

    def storageinfo(
        self,
        exclusivefiles=False,
        sharedfiles=False,
        revisionscount=False,
        trackedsize=False,
        storedsize=False,
    ):
        # TODO do a real implementation of this
        return {
            'exclusivefiles': [],
            'sharedfiles': [],
            'revisionscount': len(self),
            'trackedsize': 0,
            'storedsize': None,
        }

    def verifyintegrity(self, state):
        state['skipread'] = set()
        for rev in self:
            node = self.node(rev)
            try:
                self.revision(node)
            except Exception as e:
                yield simplefilestoreproblem(
                    error='unpacking %s: %s' % (node, e), node=node
                )
                state['skipread'].add(node)

    def emitrevisions(
        self,
        nodes,
        nodesorder=None,
        revisiondata=False,
        assumehaveparentrevisions=False,
        deltamode=repository.CG_DELTAMODE_STD,
        sidedata_helpers=None,
    ):
        # TODO this will probably break on some ordering options.
        nodes = [n for n in nodes if n != self._repo.nullid]
        if not nodes:
            return
        for delta in storageutil.emitrevisions(
            self,
            nodes,
            nodesorder,
            simplestorerevisiondelta,
            revisiondata=revisiondata,
            assumehaveparentrevisions=assumehaveparentrevisions,
            deltamode=deltamode,
            sidedata_helpers=sidedata_helpers,
        ):
            yield delta

    def add(self, text, meta, transaction, linkrev, p1, p2):
        if meta or text.startswith(b'\1\n'):
            text = storageutil.packmeta(meta, text)

        return self.addrevision(text, transaction, linkrev, p1, p2)

    def addrevision(
        self,
        text,
        transaction,
        linkrev,
        p1,
        p2,
        node=None,
        flags=revlog.REVIDX_DEFAULT_FLAGS,
        cachedelta=None,
    ):
        validatenode(p1)
        validatenode(p2)

        if flags:
            node = node or storageutil.hashrevisionsha1(text, p1, p2)

        rawtext, validatehash = flagutil.processflagswrite(self, text, flags)

        node = node or storageutil.hashrevisionsha1(text, p1, p2)

        if node in self._indexbynode:
            return node

        if validatehash:
            self.checkhash(rawtext, node, p1=p1, p2=p2)

        return self._addrawrevision(
            node, rawtext, transaction, linkrev, p1, p2, flags
        )

    def _addrawrevision(self, node, rawtext, transaction, link, p1, p2, flags):
        transaction.addbackup(self._indexpath)

        path = b'/'.join([self._storepath, hex(node)])

        self._svfs.write(path, rawtext)

        self._indexdata.append(
            {
                b'node': node,
                b'p1': p1,
                b'p2': p2,
                b'linkrev': link,
                b'flags': flags,
            }
        )

        self._reflectindexupdate()

        return node

    def _reflectindexupdate(self):
        self._refreshindex()
        self._svfs.write(
            self._indexpath, ''.join(cborutil.streamencode(self._indexdata))
        )

    def addgroup(
        self,
        deltas,
        linkmapper,
        transaction,
        addrevisioncb=None,
        duplicaterevisioncb=None,
        maybemissingparents=False,
    ):
        if maybemissingparents:
            raise error.Abort(
                _('simple store does not support missing parents ' 'write mode')
            )

        empty = True

        transaction.addbackup(self._indexpath)

        for node, p1, p2, linknode, deltabase, delta, flags in deltas:
            linkrev = linkmapper(linknode)
            flags = flags or revlog.REVIDX_DEFAULT_FLAGS

            if node in self._indexbynode:
                if duplicaterevisioncb:
                    duplicaterevisioncb(self, self.rev(node))
                empty = False
                continue

            # Need to resolve the fulltext from the delta base.
            if deltabase == self._repo.nullid:
                text = mdiff.patch(b'', delta)
            else:
                text = mdiff.patch(self.revision(deltabase), delta)

            rev = self._addrawrevision(
                node, text, transaction, linkrev, p1, p2, flags
            )

            if addrevisioncb:
                addrevisioncb(self, rev)
            empty = False
        return not empty

    def _headrevs(self):
        # Assume all revisions are heads by default.
        revishead = {rev: True for rev in self._indexbyrev}

        for rev, entry in self._indexbyrev.items():
            # Unset head flag for all seen parents.
            revishead[self.rev(entry[b'p1'])] = False
            revishead[self.rev(entry[b'p2'])] = False

        return [rev for rev, ishead in sorted(revishead.items()) if ishead]

    def heads(self, start=None, stop=None):
        # This is copied from revlog.py.
        if start is None and stop is None:
            if not len(self):
                return [self._repo.nullid]
            return [self.node(r) for r in self._headrevs()]

        if start is None:
            start = self._repo.nullid
        if stop is None:
            stop = []
        stoprevs = {self.rev(n) for n in stop}
        startrev = self.rev(start)
        reachable = {startrev}
        heads = {startrev}

        parentrevs = self.parentrevs
        for r in self.revs(start=startrev + 1):
            for p in parentrevs(r):
                if p in reachable:
                    if r not in stoprevs:
                        reachable.add(r)
                    heads.add(r)
                if p in heads and p not in stoprevs:
                    heads.remove(p)

        return [self.node(r) for r in heads]

    def children(self, node):
        validatenode(node)

        # This is a copy of revlog.children().
        c = []
        p = self.rev(node)
        for r in self.revs(start=p + 1):
            prevs = [pr for pr in self.parentrevs(r) if pr != nullrev]
            if prevs:
                for pr in prevs:
                    if pr == p:
                        c.append(self.node(r))
            elif p == nullrev:
                c.append(self.node(r))
        return c

    def getstrippoint(self, minlink):
        return storageutil.resolvestripinfo(
            minlink,
            len(self) - 1,
            self._headrevs(),
            self.linkrev,
            self.parentrevs,
        )

    def strip(self, minlink, transaction):
        if not len(self):
            return

        rev, _ignored = self.getstrippoint(minlink)
        if rev == len(self):
            return

        # Purge index data starting at the requested revision.
        self._indexdata[rev:] = []
        self._reflectindexupdate()


def issimplestorefile(f, kind, st):
    if kind != stat.S_IFREG:
        return False

    if store.isrevlog(f, kind, st):
        return False

    # Ignore transaction undo files.
    if f.startswith('undo.'):
        return False

    # Otherwise assume it belongs to the simple store.
    return True


class simplestore(store.encodedstore):
    def datafiles(self, undecodable=None):
        for x in super(simplestore, self).datafiles():
            yield x

        # Supplement with non-revlog files.
        extrafiles = self._walk('data', True, filefilter=issimplestorefile)

        for f1, size in extrafiles:
            try:
                f2 = store.decodefilename(f1)
            except KeyError:
                if undecodable is None:
                    raise error.StorageError(b'undecodable revlog name %s' % f1)
                else:
                    undecodable.append(f1)
                    continue

            yield f2, size


def reposetup(ui, repo):
    if not repo.local():
        return

    if isinstance(repo, bundlerepo.bundlerepository):
        raise error.Abort(_('cannot use simple store with bundlerepo'))

    class simplestorerepo(repo.__class__):
        def file(self, f):
            return filestorage(repo, self.svfs, f)

    repo.__class__ = simplestorerepo


def featuresetup(ui, supported):
    supported.add(REQUIREMENT)


def newreporequirements(orig, ui, createopts):
    """Modifies default requirements for new repos to use the simple store."""
    requirements = orig(ui, createopts)

    # These requirements are only used to affect creation of the store
    # object. We have our own store. So we can remove them.
    # TODO do this once we feel like taking the test hit.
    # if 'fncache' in requirements:
    #    requirements.remove('fncache')
    # if 'dotencode' in requirements:
    #    requirements.remove('dotencode')

    requirements.add(REQUIREMENT)

    return requirements


def makestore(orig, requirements, path, vfstype):
    if REQUIREMENT not in requirements:
        return orig(requirements, path, vfstype)

    return simplestore(path, vfstype)


def verifierinit(orig, self, *args, **kwargs):
    orig(self, *args, **kwargs)

    # We don't care that files in the store don't align with what is
    # advertised. So suppress these warnings.
    self.warnorphanstorefiles = False


def extsetup(ui):
    localrepo.featuresetupfuncs.add(featuresetup)

    extensions.wrapfunction(
        localrepo, 'newreporequirements', newreporequirements
    )
    extensions.wrapfunction(localrepo, 'makestore', makestore)
    extensions.wrapfunction(verify.verifier, '__init__', verifierinit)
