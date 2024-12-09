#!/usr/bin/env python3
#
# generate-branchy-bundle - generate a branch for a "large" branchy repository
#
# Copyright 2018 Octobus, contact@octobus.net
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# This script generates a repository suitable for testing delta computation
# strategies.
#
# The repository update a single "large" file with many updates. One fixed part
# of the files always get updated while the rest of the lines get updated over
# time. This update happens over many topological branches, some getting merged
# back.
#
# --lazy     will skip generating the file if one exist with the right content
#            already.
# --validate make sure the generated bundle has the expected content.


import hashlib
import os
import shutil
import subprocess
import sys
import tempfile

import mercurial.context
import mercurial.hg
import mercurial.ui

BUNDLE_NAME = 'big-file-churn.hg'

# constants for generating the repository
NB_CHANGESET = 5000
PERIOD_MERGING = 8
PERIOD_BRANCHING = 7
MOVE_BACK_MIN = 3
MOVE_BACK_RANGE = 5

# constants for generating the large file we keep updating
#
# At each revision, the beginning on the file change,
# and set of other lines changes too.
FILENAME = 'SPARSE-REVLOG-TEST-FILE'
NB_LINES = 10500
ALWAYS_CHANGE_LINES = 500
OTHER_CHANGES = 300


def build_graph():
    heads = {0}
    graph = {0: (None, None)}
    for idx in range(1, NB_CHANGESET + 1):
        p, _ = parents = [idx - 1, None]
        if (idx % PERIOD_BRANCHING) == 0:
            back = MOVE_BACK_MIN + (idx % MOVE_BACK_RANGE)
            for _ in range(back):
                p = graph.get(p, (p,))[0]
                parents[0] = p
        if (idx % PERIOD_MERGING) == 0:
            parents[1] = min(heads)
        for p in parents:
            heads.discard(p)
        heads.add(idx)
        graph[idx] = tuple(parents)
    return graph


GRAPH = build_graph()


def nextcontent(previous_content):
    """utility to produce a new file content from the previous one"""
    return hashlib.md5(previous_content).hexdigest().encode('ascii')


def filecontent(iteridx, oldcontent):
    """generate a new file content

    The content is generated according the iteration index and previous
    content"""

    # initial call
    if iteridx == 0:
        current = b''
    else:
        current = b"%d" % iteridx

    for idx in range(NB_LINES):
        do_change_line = True
        if oldcontent is not None and ALWAYS_CHANGE_LINES < idx:
            do_change_line = not ((idx - iteridx) % OTHER_CHANGES)

        if do_change_line:
            to_write = current + b'\n'
            current = nextcontent(current)
        else:
            to_write = oldcontent[idx]
        yield to_write


def merge_content(base, left, right):
    """merge two file content to produce a new one

    use unambiguous update on each side when possible, and produce a new line
    whenever a merge is needed. Similar to what the manifest would do.
    """
    for old, left, right in zip(base, left, right):
        if old == left and old == right:
            yield old
        elif old == left and old != right:
            yield right
        elif old != left and old == right:
            yield left
        else:
            yield nextcontent(left + right)


def ancestors(graph, rev):
    """return the set of ancestors of revision <rev>"""
    to_proceed = {rev}
    seen = set(to_proceed)
    while to_proceed:
        current = to_proceed.pop()
        for p in graph[current]:
            if p is None:
                continue
            if p in seen:
                continue
            to_proceed.add(p)
            seen.add(p)
    return seen


def gca(graph, left, right):
    """find the greater common ancestors of left and right

    Note that the algorithm is stupid and N² when run on all merge, however
    this should not be a too much issue given the current scale.
    """
    return max(ancestors(graph, left) & ancestors(graph, right))


def make_one_content_fn(idx, base, left, right):
    """build a function that build the content on demand

    The dependency are kept are reference to make sure they are not
    garbage-collected until we use them. Once we computed the current content,
    we make sure to drop their reference to allow them to be garbage collected.
    """

    def content_fn(idx=idx, base=base, left=left, right=right):
        if left is None:
            new = filecontent(idx, None)
        elif base is None:
            new = filecontent(idx, left())
        else:
            merged = merge_content(base(), left(), right())
            new = filecontent(idx, list(merged))
        return list(new)

    del idx
    del base
    del left
    del right

    value = None
    cf = [content_fn]
    del content_fn

    def final_fn():
        nonlocal value
        if value is None:
            content_fn = cf.pop()
            value = list(content_fn())
            del content_fn
        return value

    return final_fn


def build_content_graph(graph):
    """produce file content for all revision

    The content will be generated on demande and cached. Cleanup the
    dictionnary are you use it to reduce memory usage.
    """
    content = {}
    for idx, (p1, p2) in graph.items():
        base = left = right = None
        if p1 is not None:
            left = content[p1]
            if p2 is not None:
                right = content[p2]
                base_rev = gca(graph, p1, p2)
                base = content[base_rev]
        content[idx] = make_one_content_fn(idx, base, left, right)
    return content


CONTENT = build_content_graph(GRAPH)


def hg(command, *args):
    """call a mercurial command with appropriate config and argument"""
    env = os.environ.copy()
    if 'CHGHG' in env:
        full_cmd = ['chg']
    else:
        full_cmd = ['hg']
    full_cmd.append('--quiet')
    full_cmd.append(command)
    if command == 'commit':
        # reproducible commit metadata
        full_cmd.extend(['--date', '0 0', '--user', 'test'])
    elif command == 'merge':
        # avoid conflicts by picking the local variant
        full_cmd.extend(['--tool', ':merge-local'])
    full_cmd.extend(args)
    env['HGRCPATH'] = ''
    return subprocess.check_call(full_cmd, env=env)


def write_repo(path):
    """write repository content in memory"""
    repo = mercurial.hg.repository(
        mercurial.ui.ui.load(),
        path=path.encode('utf-8'),
    )
    nodemap = {None: repo.nodeconstants.nullid}
    with repo.lock(), repo.transaction(b'bundle-generation'):
        for idx, (p1, p2) in GRAPH.items():
            if sys.stdout.isatty():
                print("generating commit #%d/%d" % (idx, NB_CHANGESET))

            file_fn = lambda repo, memctx, path: mercurial.context.memfilectx(
                repo,
                memctx,
                path,
                data=b''.join(CONTENT.pop(idx)()),
            )

            mc = mercurial.context.memctx(
                repo,
                (nodemap[p1], nodemap[p2]),
                b'commit #%d' % idx if idx else b'initial commit',
                [FILENAME.encode('ascii')],
                file_fn,
                user=b"test",
                date=(0, 0),
            )
            nodemap[idx] = repo.commitctx(mc)


def compute_md5(target):
    with open(target, 'rb') as bundle:
        data = bundle.read()
        return hashlib.md5(data).hexdigest()


def write_md5(target, md5):
    with open(target + '.md5', 'wb') as md5file:
        md5file.write(md5.encode('ascii') + b'\n')


def read_md5(target):
    with open(target + '.md5', 'rb') as md5file:
        return md5file.read().strip().decode('ascii')


def up_to_date_target(target):
    """return true if the file already exist at the right"""
    try:
        found = compute_md5(target)
        expected = read_md5(target)
    except OSError:
        return False
    return found == expected


def run(target, validate=False):
    tmpdir = tempfile.mkdtemp(prefix='tmp-hg-test-big-file-bundle-')
    cwd = os.getcwd()
    try:
        os.chdir(tmpdir)
        hg(
            'init',
            '--config',
            'format.maxchainlen=%d' % NB_CHANGESET,
        )
        write_repo(tmpdir)
        hg('bundle', '--all', target, '--config', 'devel.bundle.delta=p1')
        digest = compute_md5(target)
        if not validate:
            write_md5(target, digest)
        else:
            expected = read_md5(target)
            if expected != digest:
                msg = "bundle generated does not match the expected content\n"
                msg += "    expected: %s\n" % expected
                msg += "    got:      %s" % digest
                print(msg, file=sys.stderr)
                return 1
    finally:
        # Windows does not let you remove the current working directory
        os.chdir(cwd)
        shutil.rmtree(tmpdir)
    return 0


if __name__ == '__main__':
    orig = os.path.realpath(os.path.dirname(sys.argv[0]))
    target = os.path.join(orig, os.pardir, 'cache', BUNDLE_NAME)
    lazy = '--lazy' in sys.argv[1:]
    validate = '--validate' in sys.argv[1:]
    if lazy and up_to_date_target(target):
        sys.exit(0)
    sys.exit(run(target, validate=validate))
