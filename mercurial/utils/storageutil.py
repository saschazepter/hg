# storageutil.py - Storage functionality agnostic of backend implementation.
#
# Copyright 2018 Gregory Szorc <gregory.szorc@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import re
import struct

from ..i18n import _
from ..node import (
    bin,
    nullrev,
    sha1nodeconstants,
)

from ..revlogutils.constants import (
    META_MARKER,
    META_MARKER_SIZE,
)

from .. import (
    error,
    mdiff,
)
from ..utils import hashutil

_nullhash = hashutil.sha1(sha1nodeconstants.nullid)

# revision data contains extra metadata not part of the official digest
# Only used in changegroup >= v4.
CG_FLAG_SIDEDATA = 1


def hashrevisionsha1(text, p1, p2):
    """Compute the SHA-1 for revision data and its parents.

    This hash combines both the current file contents and its history
    in a manner that makes it easy to distinguish nodes with the same
    content in the revision graph.
    """
    # As of now, if one of the parent node is null, p2 is null
    if p2 == sha1nodeconstants.nullid:
        # deep copy of a hash is faster than creating one
        s = _nullhash.copy()
        s.update(p1)
    else:
        # none of the parent nodes are nullid
        if p1 < p2:
            a = p1
            b = p2
        else:
            a = p2
            b = p1
        s = hashutil.sha1(a)
        s.update(b)
    s.update(text)
    return s.digest()


METADATA_RE = re.compile(META_MARKER)


def parsemeta(text):
    """Parse metadata header from revision data.

    Returns a 2-tuple of (metadata, offset), where both can be None if there
    is no metadata.
    """
    # text can be buffer, so we can't use .startswith or .index
    if text[:META_MARKER_SIZE] != META_MARKER:
        return None, None
    s = METADATA_RE.search(text, META_MARKER_SIZE).start()
    mtext = text[META_MARKER_SIZE:s]
    meta = {}
    for l in mtext.splitlines():
        k, v = l.split(b': ', 1)
        meta[k] = v
    return meta, s + META_MARKER_SIZE


def packmeta(meta, text):
    """Add metadata to fulltext to produce revision text."""
    keys = sorted(meta)
    pieces = [META_MARKER]
    pieces.extend(b'%s: %s\n' % (k, meta[k]) for k in keys)
    pieces.append(META_MARKER)
    pieces.append(text)
    return b''.join(pieces)


def iscensoredtext(text):
    meta = parsemeta(text)[0]
    return meta and b'censored' in meta


def filtermetadata(text):
    """Extract just the revision data from source text.

    Returns ``text`` unless it has a metadata header, in which case we return
    a new buffer without hte metadata.
    """
    if not text.startswith(META_MARKER):
        return text

    offset = text.index(META_MARKER, 2)
    return text[offset + META_MARKER_SIZE :]


def filedataequivalent(store, node, filedata):
    """Determines whether file data is equivalent to a stored node.

    Returns True if the passed file data would hash to the same value
    as a stored revision and False otherwise.

    When a stored revision is censored, filedata must be empty to have
    equivalence.

    When a stored revision has copy metadata, it is ignored as part
    of the compare.
    """

    if filedata.startswith(META_MARKER):
        revisiontext = META_MARKER + META_MARKER + filedata
    else:
        revisiontext = filedata

    p1, p2 = store.parents(node)

    computednode = hashrevisionsha1(revisiontext, p1, p2)

    if computednode == node:
        return True

    # Censored files compare against the empty file.
    if store.iscensored(store.rev(node)):
        return filedata == b''

    # metadata (like renaming) alter the hash, so we need to compare the actual
    # content.
    #
    # XXX when checking metadata is cheap we could skip computing the hash
    if store.has_meta(node):
        return store.read(node) == filedata

    return False


def iterrevs(storelen, start=0, stop=None):
    """Iterate over revision numbers in a store."""
    step = 1

    if stop is not None:
        if start > stop:
            step = -1
        stop += step
        if stop > storelen:
            stop = storelen
    else:
        stop = storelen

    return range(start, stop, step)


def fileidlookup(store, fileid, identifier):
    """Resolve the file node for a value.

    ``store`` is an object implementing the ``ifileindex`` interface.

    ``fileid`` can be:

    * A binary node of appropiate size (e.g. 20/32 Bytes).
    * An integer revision number
    * A hex node of appropiate size (e.g. 40/64 Bytes).
    * A bytes that can be parsed as an integer representing a revision number.

    ``identifier`` is used to populate ``error.LookupError`` with an identifier
    for the store.

    Raises ``error.LookupError`` on failure.
    """
    if isinstance(fileid, int):
        try:
            return store.node(fileid)
        except IndexError:
            raise error.LookupError(
                b'%d' % fileid, identifier, _(b'no match found')
            )

    if len(fileid) == len(store.nullid):
        try:
            store.rev(fileid)
            return fileid
        except error.LookupError:
            pass

    if len(fileid) == 2 * len(store.nullid):
        try:
            rawnode = bin(fileid)
            store.rev(rawnode)
            return rawnode
        except TypeError:
            pass

    try:
        rev = int(fileid)

        if b'%d' % rev != fileid:
            raise ValueError

        try:
            return store.node(rev)
        except (IndexError, TypeError):
            pass
    except (ValueError, OverflowError):
        pass

    raise error.LookupError(fileid, identifier, _(b'no match found'))


def resolvestripinfo(minlinkrev, tiprev, headrevs, linkrevfn, parentrevsfn):
    """Resolve information needed to strip revisions.

    Finds the minimum revision number that must be stripped in order to
    strip ``minlinkrev``.

    Returns a 2-tuple of the minimum revision number to do that and a set
    of all revision numbers that have linkrevs that would be broken
    by that strip.

    ``tiprev`` is the current tip-most revision. It is ``len(store) - 1``.
    ``headrevs`` is an iterable of head revisions.
    ``linkrevfn`` is a callable that receives a revision and returns a linked
    revision.
    ``parentrevsfn`` is a callable that receives a revision number and returns
    an iterable of its parent revision numbers.
    """
    brokenrevs = set()
    strippoint = tiprev + 1

    heads = {}
    futurelargelinkrevs = set()
    for head in headrevs:
        headlinkrev = linkrevfn(head)
        heads[head] = headlinkrev
        if headlinkrev >= minlinkrev:
            futurelargelinkrevs.add(headlinkrev)

    # This algorithm involves walking down the rev graph, starting at the
    # heads. Since the revs are topologically sorted according to linkrev,
    # once all head linkrevs are below the minlink, we know there are
    # no more revs that could have a linkrev greater than minlink.
    # So we can stop walking.
    while futurelargelinkrevs:
        strippoint -= 1
        linkrev = heads.pop(strippoint)

        if linkrev < minlinkrev:
            brokenrevs.add(strippoint)
        else:
            futurelargelinkrevs.remove(linkrev)

        for p in parentrevsfn(strippoint):
            if p != nullrev:
                plinkrev = linkrevfn(p)
                heads[p] = plinkrev
                if plinkrev >= minlinkrev:
                    futurelargelinkrevs.add(plinkrev)

    return strippoint, brokenrevs


def deltaiscensored(delta, baserev, baselenfn):
    """Determine if a delta represents censored revision data.

    ``baserev`` is the base revision this delta is encoded against.
    ``baselenfn`` is a callable receiving a revision number that resolves the
    length of the revision fulltext.

    Returns a bool indicating if the result of the delta represents a censored
    revision.
    """
    # Fragile heuristic: unless new file meta keys are added alphabetically
    # preceding "censored", all censored revisions are prefixed by
    # "\1\ncensored:". A delta producing such a censored revision must be a
    # full-replacement delta, so we inspect the first and only patch in the
    # delta for this prefix.
    hlen = struct.calcsize(b">lll")
    if len(delta) <= hlen:
        return False

    oldlen = baselenfn(baserev)
    newlen = len(delta) - hlen
    if delta[:hlen] != mdiff.replacediffheader(oldlen, newlen):
        return False

    add = b"\1\ncensored:"
    addlen = len(add)
    return newlen >= addlen and delta[hlen : hlen + addlen] == add
