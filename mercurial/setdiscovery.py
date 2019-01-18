# setdiscovery.py - improved discovery of common nodeset for mercurial
#
# Copyright 2010 Benoit Boissinot <bboissin@gmail.com>
# and Peter Arrenbrecht <peter@arrenbrecht.ch>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""
Algorithm works in the following way. You have two repository: local and
remote. They both contains a DAG of changelists.

The goal of the discovery protocol is to find one set of node *common*,
the set of nodes shared by local and remote.

One of the issue with the original protocol was latency, it could
potentially require lots of roundtrips to discover that the local repo was a
subset of remote (which is a very common case, you usually have few changes
compared to upstream, while upstream probably had lots of development).

The new protocol only requires one interface for the remote repo: `known()`,
which given a set of changelists tells you if they are present in the DAG.

The algorithm then works as follow:

 - We will be using three sets, `common`, `missing`, `unknown`. Originally
 all nodes are in `unknown`.
 - Take a sample from `unknown`, call `remote.known(sample)`
   - For each node that remote knows, move it and all its ancestors to `common`
   - For each node that remote doesn't know, move it and all its descendants
   to `missing`
 - Iterate until `unknown` is empty

There are a couple optimizations, first is instead of starting with a random
sample of missing, start by sending all heads, in the case where the local
repo is a subset, you computed the answer in one round trip.

Then you can do something similar to the bisecting strategy used when
finding faulty changesets. Instead of random samples, you can try picking
nodes that will maximize the number of nodes that will be
classified with it (since all ancestors or descendants will be marked as well).
"""

from __future__ import absolute_import

import collections
import random

from .i18n import _
from .node import (
    nullid,
    nullrev,
)
from . import (
    error,
    util,
)

def _updatesample(revs, heads, sample, parentfn, quicksamplesize=0):
    """update an existing sample to match the expected size

    The sample is updated with revs exponentially distant from each head of the
    <revs> set. (H~1, H~2, H~4, H~8, etc).

    If a target size is specified, the sampling will stop once this size is
    reached. Otherwise sampling will happen until roots of the <revs> set are
    reached.

    :revs:  set of revs we want to discover (if None, assume the whole dag)
    :heads: set of DAG head revs
    :sample: a sample to update
    :parentfn: a callable to resolve parents for a revision
    :quicksamplesize: optional target size of the sample"""
    dist = {}
    visit = collections.deque(heads)
    seen = set()
    factor = 1
    while visit:
        curr = visit.popleft()
        if curr in seen:
            continue
        d = dist.setdefault(curr, 1)
        if d > factor:
            factor *= 2
        if d == factor:
            sample.add(curr)
            if quicksamplesize and (len(sample) >= quicksamplesize):
                return
        seen.add(curr)

        for p in parentfn(curr):
            if p != nullrev and (not revs or p in revs):
                dist.setdefault(p, d + 1)
                visit.append(p)

def _takequicksample(repo, headrevs, revs, size):
    """takes a quick sample of size <size>

    It is meant for initial sampling and focuses on querying heads and close
    ancestors of heads.

    :dag: a dag object
    :headrevs: set of head revisions in local DAG to consider
    :revs: set of revs to discover
    :size: the maximum size of the sample"""
    if len(revs) <= size:
        return list(revs)
    sample = set(repo.revs('heads(%ld)', revs))

    if len(sample) >= size:
        return _limitsample(sample, size)

    _updatesample(None, headrevs, sample, repo.changelog.parentrevs,
                  quicksamplesize=size)
    return sample

def _takefullsample(repo, headrevs, revs, size):
    if len(revs) <= size:
        return list(revs)
    sample = set(repo.revs('heads(%ld)', revs))

    # update from heads
    revsheads = set(repo.revs('heads(%ld)', revs))
    _updatesample(revs, revsheads, sample, repo.changelog.parentrevs)

    # update from roots
    revsroots = set(repo.revs('roots(%ld)', revs))

    # _updatesample() essentially does interaction over revisions to look up
    # their children. This lookup is expensive and doing it in a loop is
    # quadratic. We precompute the children for all relevant revisions and
    # make the lookup in _updatesample() a simple dict lookup.
    #
    # Because this function can be called multiple times during discovery, we
    # may still perform redundant work and there is room to optimize this by
    # keeping a persistent cache of children across invocations.
    children = {}

    parentrevs = repo.changelog.parentrevs
    for rev in repo.changelog.revs(start=min(revsroots)):
        # Always ensure revision has an entry so we don't need to worry about
        # missing keys.
        children.setdefault(rev, [])

        for prev in parentrevs(rev):
            if prev == nullrev:
                continue

            children.setdefault(prev, []).append(rev)

    _updatesample(revs, revsroots, sample, children.__getitem__)
    assert sample
    sample = _limitsample(sample, size)
    if len(sample) < size:
        more = size - len(sample)
        sample.update(random.sample(list(revs - sample), more))
    return sample

def _limitsample(sample, desiredlen):
    """return a random subset of sample of at most desiredlen item"""
    if len(sample) > desiredlen:
        sample = set(random.sample(sample, desiredlen))
    return sample

class partialdiscovery(object):
    """an object representing ongoing discovery

    Feed with data from the remote repository, this object keep track of the
    current set of changeset in various states:

    - common:    revs also known remotely
    - undecided: revs we don't have information on yet
    - missing:   revs missing remotely
    (all tracked revisions are known locally)
    """

    def __init__(self, repo, targetheads):
        self._repo = repo
        self._targetheads = targetheads
        self._common = repo.changelog.incrementalmissingrevs()
        self._undecided = None
        self.missing = set()

    def addcommons(self, commons):
        """registrer nodes known as common"""
        self._common.addbases(commons)
        self._common.removeancestorsfrom(self.undecided)

    def addmissings(self, missings):
        """registrer some nodes as missing"""
        newmissing = self._repo.revs('%ld::%ld', missings, self.undecided)
        if newmissing:
            self.missing.update(newmissing)
            self.undecided.difference_update(newmissing)

    def addinfo(self, sample):
        """consume an iterable of (rev, known) tuples"""
        common = set()
        missing = set()
        for rev, known in sample:
            if known:
                common.add(rev)
            else:
                missing.add(rev)
        if common:
            self.addcommons(common)
        if missing:
            self.addmissings(missing)

    def hasinfo(self):
        """return True is we have any clue about the remote state"""
        return self._common.hasbases()

    def iscomplete(self):
        """True if all the necessary data have been gathered"""
        return self._undecided is not None and not self._undecided

    @property
    def undecided(self):
        if self._undecided is not None:
            return self._undecided
        self._undecided = set(self._common.missingancestors(self._targetheads))
        return self._undecided

    def commonheads(self):
        """the heads of the known common set"""
        # heads(common) == heads(common.bases) since common represents
        # common.bases and all its ancestors
        return self._common.basesheads()

def findcommonheads(ui, local, remote,
                    initialsamplesize=100,
                    fullsamplesize=200,
                    abortwhenunrelated=True,
                    ancestorsof=None):
    '''Return a tuple (common, anyincoming, remoteheads) used to identify
    missing nodes from or in remote.
    '''
    start = util.timer()

    roundtrips = 0
    cl = local.changelog
    clnode = cl.node
    clrev = cl.rev

    if ancestorsof is not None:
        ownheads = [clrev(n) for n in ancestorsof]
    else:
        ownheads = [rev for rev in cl.headrevs() if rev != nullrev]

    # early exit if we know all the specified remote heads already
    ui.debug("query 1; heads\n")
    roundtrips += 1
    sample = _limitsample(ownheads, initialsamplesize)
    # indices between sample and externalized version must match
    sample = list(sample)

    with remote.commandexecutor() as e:
        fheads = e.callcommand('heads', {})
        fknown = e.callcommand('known', {
            'nodes': [clnode(r) for r in sample],
        })

    srvheadhashes, yesno = fheads.result(), fknown.result()

    if cl.tip() == nullid:
        if srvheadhashes != [nullid]:
            return [nullid], True, srvheadhashes
        return [nullid], False, []

    # start actual discovery (we note this before the next "if" for
    # compatibility reasons)
    ui.status(_("searching for changes\n"))

    srvheads = []
    for node in srvheadhashes:
        if node == nullid:
            continue

        try:
            srvheads.append(clrev(node))
        # Catches unknown and filtered nodes.
        except error.LookupError:
            continue

    if len(srvheads) == len(srvheadhashes):
        ui.debug("all remote heads known locally\n")
        return srvheadhashes, False, srvheadhashes

    if len(sample) == len(ownheads) and all(yesno):
        ui.note(_("all local heads known remotely\n"))
        ownheadhashes = [clnode(r) for r in ownheads]
        return ownheadhashes, True, srvheadhashes

    # full blown discovery

    disco = partialdiscovery(local, ownheads)
    # treat remote heads (and maybe own heads) as a first implicit sample
    # response
    disco.addcommons(srvheads)
    disco.addinfo(zip(sample, yesno))

    full = False
    progress = ui.makeprogress(_('searching'), unit=_('queries'))
    while not disco.iscomplete():

        if full or disco.hasinfo():
            if full:
                ui.note(_("sampling from both directions\n"))
            else:
                ui.debug("taking initial sample\n")
            samplefunc = _takefullsample
            targetsize = fullsamplesize
        else:
            # use even cheaper initial sample
            ui.debug("taking quick initial sample\n")
            samplefunc = _takequicksample
            targetsize = initialsamplesize
        sample = samplefunc(local, ownheads, disco.undecided, targetsize)

        roundtrips += 1
        progress.update(roundtrips)
        ui.debug("query %i; still undecided: %i, sample size is: %i\n"
                 % (roundtrips, len(disco.undecided), len(sample)))
        # indices between sample and externalized version must match
        sample = list(sample)

        with remote.commandexecutor() as e:
            yesno = e.callcommand('known', {
                'nodes': [clnode(r) for r in sample],
            }).result()

        full = True

        disco.addinfo(zip(sample, yesno))

    result = disco.commonheads()
    elapsed = util.timer() - start
    progress.complete()
    ui.debug("%d total queries in %.4fs\n" % (roundtrips, elapsed))
    msg = ('found %d common and %d unknown server heads,'
           ' %d roundtrips in %.4fs\n')
    missing = set(result) - set(srvheads)
    ui.log('discovery', msg, len(result), len(missing), roundtrips,
           elapsed)

    if not result and srvheadhashes != [nullid]:
        if abortwhenunrelated:
            raise error.Abort(_("repository is unrelated"))
        else:
            ui.warn(_("warning: repository is unrelated\n"))
        return ({nullid}, True, srvheadhashes,)

    anyincoming = (srvheadhashes != [nullid])
    result = {clnode(r) for r in result}
    return result, anyincoming, srvheadhashes
