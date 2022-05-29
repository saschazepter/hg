import binascii
import getopt
import math
import os
import random
import sys
import time

from mercurial.node import nullrev
from mercurial import (
    ancestor,
    debugcommands,
    hg,
    ui as uimod,
    util,
)


def buildgraph(rng, nodes=100, rootprob=0.05, mergeprob=0.2, prevprob=0.7):
    """nodes: total number of nodes in the graph
    rootprob: probability that a new node (not 0) will be a root
    mergeprob: probability that, excluding a root a node will be a merge
    prevprob: probability that p1 will be the previous node

    return value is a graph represented as an adjacency list.
    """
    graph = [None] * nodes
    for i in range(nodes):
        if i == 0 or rng.random() < rootprob:
            graph[i] = [nullrev]
        elif i == 1:
            graph[i] = [0]
        elif rng.random() < mergeprob:
            if i == 2 or rng.random() < prevprob:
                # p1 is prev
                p1 = i - 1
            else:
                p1 = rng.randrange(i - 1)
            p2 = rng.choice(list(range(0, p1)) + list(range(p1 + 1, i)))
            graph[i] = [p1, p2]
        elif rng.random() < prevprob:
            graph[i] = [i - 1]
        else:
            graph[i] = [rng.randrange(i - 1)]

    return graph


def buildancestorsets(graph):
    ancs = [None] * len(graph)
    for i in range(len(graph)):
        ancs[i] = {i}
        if graph[i] == [nullrev]:
            continue
        for p in graph[i]:
            ancs[i].update(ancs[p])
    return ancs


class naiveincrementalmissingancestors:
    def __init__(self, ancs, bases):
        self.ancs = ancs
        self.bases = set(bases)

    def addbases(self, newbases):
        self.bases.update(newbases)

    def removeancestorsfrom(self, revs):
        for base in self.bases:
            if base != nullrev:
                revs.difference_update(self.ancs[base])
        revs.discard(nullrev)

    def missingancestors(self, revs):
        res = set()
        for rev in revs:
            if rev != nullrev:
                res.update(self.ancs[rev])
        for base in self.bases:
            if base != nullrev:
                res.difference_update(self.ancs[base])
        return sorted(res)


def test_missingancestors(seed, rng):
    # empirically observed to take around 1 second
    graphcount = 100
    testcount = 10
    inccount = 10
    nerrs = [0]
    # the default mu and sigma give us a nice distribution of mostly
    # single-digit counts (including 0) with some higher ones
    def lognormrandom(mu, sigma):
        return int(math.floor(rng.lognormvariate(mu, sigma)))

    def samplerevs(nodes, mu=1.1, sigma=0.8):
        count = min(lognormrandom(mu, sigma), len(nodes))
        return rng.sample(nodes, count)

    def err(seed, graph, bases, seq, output, expected):
        if nerrs[0] == 0:
            print('seed:', hex(seed)[:-1], file=sys.stderr)
        if gerrs[0] == 0:
            print('graph:', graph, file=sys.stderr)
        print('* bases:', bases, file=sys.stderr)
        print('* seq: ', seq, file=sys.stderr)
        print('*  output:  ', output, file=sys.stderr)
        print('*  expected:', expected, file=sys.stderr)
        nerrs[0] += 1
        gerrs[0] += 1

    for g in range(graphcount):
        graph = buildgraph(rng)
        ancs = buildancestorsets(graph)
        gerrs = [0]
        for _ in range(testcount):
            # start from nullrev to include it as a possibility
            graphnodes = range(nullrev, len(graph))
            bases = samplerevs(graphnodes)

            # fast algorithm
            inc = ancestor.incrementalmissingancestors(graph.__getitem__, bases)
            # reference slow algorithm
            naiveinc = naiveincrementalmissingancestors(ancs, bases)
            seq = []
            for _ in range(inccount):
                if rng.random() < 0.2:
                    newbases = samplerevs(graphnodes)
                    seq.append(('addbases', newbases))
                    inc.addbases(newbases)
                    naiveinc.addbases(newbases)
                if rng.random() < 0.4:
                    # larger set so that there are more revs to remove from
                    revs = samplerevs(graphnodes, mu=1.5)
                    seq.append(('removeancestorsfrom', revs))
                    hrevs = set(revs)
                    rrevs = set(revs)
                    inc.removeancestorsfrom(hrevs)
                    naiveinc.removeancestorsfrom(rrevs)
                    if hrevs != rrevs:
                        err(
                            seed,
                            graph,
                            bases,
                            seq,
                            sorted(hrevs),
                            sorted(rrevs),
                        )
                else:
                    revs = samplerevs(graphnodes)
                    seq.append(('missingancestors', revs))
                    h = inc.missingancestors(revs)
                    r = naiveinc.missingancestors(revs)
                    if h != r:
                        err(seed, graph, bases, seq, h, r)


# graph is a dict of child->parent adjacency lists for this graph:
# o  13
# |
# | o  12
# | |
# | | o    11
# | | |\
# | | | | o  10
# | | | | |
# | o---+ |  9
# | | | | |
# o | | | |  8
#  / / / /
# | | o |  7
# | | | |
# o---+ |  6
#  / / /
# | | o  5
# | |/
# | o  4
# | |
# o |  3
# | |
# | o  2
# |/
# o  1
# |
# o  0

graph = {
    0: [-1, -1],
    1: [0, -1],
    2: [1, -1],
    3: [1, -1],
    4: [2, -1],
    5: [4, -1],
    6: [4, -1],
    7: [4, -1],
    8: [-1, -1],
    9: [6, 7],
    10: [5, -1],
    11: [3, 7],
    12: [9, -1],
    13: [8, -1],
}


def test_missingancestors_explicit():
    """A few explicit cases, easier to check for catching errors in refactors.

    The bigger graph at the end has been produced by the random generator
    above, and we have some evidence that the other tests don't cover it.
    """
    for i, (bases, revs) in enumerate(
        (
            ({1, 2, 3, 4, 7}, set(range(10))),
            ({10}, set({11, 12, 13, 14})),
            ({7}, set({1, 2, 3, 4, 5})),
        )
    ):
        print("%% removeancestorsfrom(), example %d" % (i + 1))
        missanc = ancestor.incrementalmissingancestors(graph.get, bases)
        missanc.removeancestorsfrom(revs)
        print("remaining (sorted): %s" % sorted(list(revs)))

    for i, (bases, revs) in enumerate(
        (
            ({10}, {11}),
            ({11}, {10}),
            ({7}, {9, 11}),
        )
    ):
        print("%% missingancestors(), example %d" % (i + 1))
        missanc = ancestor.incrementalmissingancestors(graph.get, bases)
        print("return %s" % missanc.missingancestors(revs))

    print("% removeancestorsfrom(), bigger graph")
    vecgraph = [
        [-1, -1],
        [0, -1],
        [1, 0],
        [2, 1],
        [3, -1],
        [4, -1],
        [5, 1],
        [2, -1],
        [7, -1],
        [8, -1],
        [9, -1],
        [10, 1],
        [3, -1],
        [12, -1],
        [13, -1],
        [14, -1],
        [4, -1],
        [16, -1],
        [17, -1],
        [18, -1],
        [19, 11],
        [20, -1],
        [21, -1],
        [22, -1],
        [23, -1],
        [2, -1],
        [3, -1],
        [26, 24],
        [27, -1],
        [28, -1],
        [12, -1],
        [1, -1],
        [1, 9],
        [32, -1],
        [33, -1],
        [34, 31],
        [35, -1],
        [36, 26],
        [37, -1],
        [38, -1],
        [39, -1],
        [40, -1],
        [41, -1],
        [42, 26],
        [0, -1],
        [44, -1],
        [45, 4],
        [40, -1],
        [47, -1],
        [36, 0],
        [49, -1],
        [-1, -1],
        [51, -1],
        [52, -1],
        [53, -1],
        [14, -1],
        [55, -1],
        [15, -1],
        [23, -1],
        [58, -1],
        [59, -1],
        [2, -1],
        [61, 59],
        [62, -1],
        [63, -1],
        [-1, -1],
        [65, -1],
        [66, -1],
        [67, -1],
        [68, -1],
        [37, 28],
        [69, 25],
        [71, -1],
        [72, -1],
        [50, 2],
        [74, -1],
        [12, -1],
        [18, -1],
        [77, -1],
        [78, -1],
        [79, -1],
        [43, 33],
        [81, -1],
        [82, -1],
        [83, -1],
        [84, 45],
        [85, -1],
        [86, -1],
        [-1, -1],
        [88, -1],
        [-1, -1],
        [76, 83],
        [44, -1],
        [92, -1],
        [93, -1],
        [9, -1],
        [95, 67],
        [96, -1],
        [97, -1],
        [-1, -1],
    ]
    problem_rev = 28
    problem_base = 70
    # problem_rev is a parent of problem_base, but a faulty implementation
    # could forget to remove it.
    bases = {60, 26, 70, 3, 96, 19, 98, 49, 97, 47, 1, 6}
    if problem_rev not in vecgraph[problem_base] or problem_base not in bases:
        print("Conditions have changed")
    missanc = ancestor.incrementalmissingancestors(vecgraph.__getitem__, bases)
    revs = {4, 12, 41, 28, 68, 38, 1, 30, 56, 44}
    missanc.removeancestorsfrom(revs)
    if 28 in revs:
        print("Failed!")
    else:
        print("Ok")


def genlazyancestors(revs, stoprev=0, inclusive=False):
    print(
        (
            "%% lazy ancestor set for %s, stoprev = %s, inclusive = %s"
            % (revs, stoprev, inclusive)
        )
    )
    return ancestor.lazyancestors(
        graph.get, revs, stoprev=stoprev, inclusive=inclusive
    )


def printlazyancestors(s, l):
    print('membership: %r' % [n for n in l if n in s])
    print('iteration:  %r' % list(s))


def test_lazyancestors():
    # Empty revs
    s = genlazyancestors([])
    printlazyancestors(s, [3, 0, -1])

    # Standard example
    s = genlazyancestors([11, 13])
    printlazyancestors(s, [11, 13, 7, 9, 8, 3, 6, 4, 1, -1, 0])

    # Standard with ancestry in the initial set (1 is ancestor of 3)
    s = genlazyancestors([1, 3])
    printlazyancestors(s, [1, -1, 0])

    # Including revs
    s = genlazyancestors([11, 13], inclusive=True)
    printlazyancestors(s, [11, 13, 7, 9, 8, 3, 6, 4, 1, -1, 0])

    # Test with stoprev
    s = genlazyancestors([11, 13], stoprev=6)
    printlazyancestors(s, [11, 13, 7, 9, 8, 3, 6, 4, 1, -1, 0])
    s = genlazyancestors([11, 13], stoprev=6, inclusive=True)
    printlazyancestors(s, [11, 13, 7, 9, 8, 3, 6, 4, 1, -1, 0])

    # Test with stoprev >= min(initrevs)
    s = genlazyancestors([11, 13], stoprev=11, inclusive=True)
    printlazyancestors(s, [11, 13, 7, 9, 8, 3, 6, 4, 1, -1, 0])
    s = genlazyancestors([11, 13], stoprev=12, inclusive=True)
    printlazyancestors(s, [11, 13, 7, 9, 8, 3, 6, 4, 1, -1, 0])

    # Contiguous chains: 5->4, 2->1 (where 1 is in seen set), 1->0
    s = genlazyancestors([10, 1], inclusive=True)
    printlazyancestors(s, [2, 10, 4, 5, -1, 0, 1])


# The C gca algorithm requires a real repo. These are textual descriptions of
# DAGs that have been known to be problematic, and, optionally, known pairs
# of revisions and their expected ancestor list.
dagtests = [
    (b'+2*2*2/*3/2', {}),
    (b'+3*3/*2*2/*4*4/*4/2*4/2*2', {}),
    (b'+2*2*/2*4*/4*/3*2/4', {(6, 7): [3, 5]}),
]


def test_gca():
    u = uimod.ui.load()
    for i, (dag, tests) in enumerate(dagtests):
        repo = hg.repository(u, b'gca%d' % i, create=1)
        cl = repo.changelog
        if not util.safehasattr(cl.index, 'ancestors'):
            # C version not available
            return

        debugcommands.debugbuilddag(u, repo, dag)
        # Compare the results of the Python and C versions. This does not
        # include choosing a winner when more than one gca exists -- we make
        # sure both return exactly the same set of gcas.
        # Also compare against expected results, if available.
        for a in cl:
            for b in cl:
                cgcas = sorted(cl.index.ancestors(a, b))
                pygcas = sorted(ancestor.ancestors(cl.parentrevs, a, b))
                expected = None
                if (a, b) in tests:
                    expected = tests[(a, b)]
                if cgcas != pygcas or (expected and cgcas != expected):
                    print(
                        "test_gca: for dag %s, gcas for %d, %d:" % (dag, a, b)
                    )
                    print("  C returned:      %s" % cgcas)
                    print("  Python returned: %s" % pygcas)
                    if expected:
                        print("  expected:        %s" % expected)


def main():
    seed = None
    opts, args = getopt.getopt(sys.argv[1:], 's:', ['seed='])
    for o, a in opts:
        if o in ('-s', '--seed'):
            seed = int(a, base=0)  # accepts base 10 or 16 strings

    if seed is None:
        try:
            seed = int(binascii.hexlify(os.urandom(16)), 16)
        except AttributeError:
            seed = int(time.time() * 1000)

    rng = random.Random(seed)
    test_missingancestors_explicit()
    test_missingancestors(seed, rng)
    test_lazyancestors()
    test_gca()


if __name__ == '__main__':
    main()
