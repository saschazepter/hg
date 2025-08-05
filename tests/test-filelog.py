#!/usr/bin/env python3
"""
Tests the behavior of filelog w.r.t. data starting with '\1\n'
"""

from mercurial.node import hex
from mercurial import (
    ui as uimod,
)
from mercurial.repo import factory

myui = uimod.ui.load()
repo = factory.repository(myui, path=b'.', create=True)

fl = repo.file(b'foobar', writable=True)


def addrev(text, renamed=False):
    if renamed:
        # data doesn't matter. Just make sure filelog.renamed() returns True
        meta = {b'copyrev': hex(repo.nullid), b'copy': b'bar'}
    else:
        meta = {}

    lock = t = None
    try:
        lock = repo.lock()
        t = repo.transaction(b'commit')
        node = fl.add(text, meta, t, 0, repo.nullid, repo.nullid)
        return node
    finally:
        if t:
            t.close()
        if lock:
            lock.release()


def error(text):
    print('ERROR: ' + text)


textwith = b'\1\nfoo'
without = b'foo'

node = addrev(textwith)
if not textwith == fl.read(node):
    error('filelog.read for data starting with \\1\\n')
if fl.cmp(node, textwith) or not fl.cmp(node, without):
    error('filelog.cmp for data starting with \\1\\n')
if fl.size(0) != len(textwith):
    error('filelog.size for data starting with \\1\\n')

node = addrev(textwith, renamed=True)
if not textwith == fl.read(node):
    error('filelog.read for a renaming + data starting with \\1\\n')
if fl.cmp(node, textwith) or not fl.cmp(node, without):
    error('filelog.cmp for a renaming + data starting with \\1\\n')
if fl.size(1) != len(textwith):
    error('filelog.size for a renaming + data starting with \\1\\n')

print('OK.')
