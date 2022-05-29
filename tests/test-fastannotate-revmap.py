import os
import tempfile

from mercurial import (
    pycompat,
    util,
)

from hgext.fastannotate import error, revmap


def genhsh(i):
    return pycompat.bytechr(i) + b'\0' * 19


def gettemppath():
    fd, path = tempfile.mkstemp()
    os.close(fd)
    os.unlink(path)
    return path


def ensure(condition):
    if not condition:
        raise RuntimeError('Unexpected')


def testbasicreadwrite():
    path = gettemppath()

    rm = revmap.revmap(path)
    ensure(rm.maxrev == 0)
    for i in range(5):
        ensure(rm.rev2hsh(i) is None)
    ensure(rm.hsh2rev(b'\0' * 20) is None)

    paths = [
        b'',
        b'a',
        None,
        b'b',
        b'b',
        b'c',
        b'c',
        None,
        b'a',
        b'b',
        b'a',
        b'a',
    ]
    for i in range(1, 5):
        ensure(rm.append(genhsh(i), sidebranch=(i & 1), path=paths[i]) == i)

    ensure(rm.maxrev == 4)
    for i in range(1, 5):
        ensure(rm.hsh2rev(genhsh(i)) == i)
        ensure(rm.rev2hsh(i) == genhsh(i))

    # re-load and verify
    rm.flush()
    rm = revmap.revmap(path)
    ensure(rm.maxrev == 4)
    for i in range(1, 5):
        ensure(rm.hsh2rev(genhsh(i)) == i)
        ensure(rm.rev2hsh(i) == genhsh(i))
        ensure(bool(rm.rev2flag(i) & revmap.sidebranchflag) == bool(i & 1))

    # append without calling save() explicitly
    for i in range(5, 12):
        ensure(
            rm.append(genhsh(i), sidebranch=(i & 1), path=paths[i], flush=True)
            == i
        )

    # re-load and verify
    rm = revmap.revmap(path)
    ensure(rm.maxrev == 11)
    for i in range(1, 12):
        ensure(rm.hsh2rev(genhsh(i)) == i)
        ensure(rm.rev2hsh(i) == genhsh(i))
        ensure(rm.rev2path(i) == paths[i] or paths[i - 1])
        ensure(bool(rm.rev2flag(i) & revmap.sidebranchflag) == bool(i & 1))

    os.unlink(path)

    # missing keys
    ensure(rm.rev2hsh(12) is None)
    ensure(rm.rev2hsh(0) is None)
    ensure(rm.rev2hsh(-1) is None)
    ensure(rm.rev2flag(12) is None)
    ensure(rm.rev2path(12) is None)
    ensure(rm.hsh2rev(b'\1' * 20) is None)

    # illformed hash (not 20 bytes)
    try:
        rm.append(b'\0')
        ensure(False)
    except Exception:
        pass


def testcorruptformat():
    path = gettemppath()

    # incorrect header
    with open(path, 'wb') as f:
        f.write(b'NOT A VALID HEADER')
    try:
        revmap.revmap(path)
        ensure(False)
    except error.CorruptedFileError:
        pass

    # rewrite the file
    os.unlink(path)
    rm = revmap.revmap(path)
    rm.append(genhsh(0), flush=True)

    rm = revmap.revmap(path)
    ensure(rm.maxrev == 1)

    # corrupt the file by appending a byte
    size = os.stat(path).st_size
    with open(path, 'ab') as f:
        f.write(b'\xff')
    try:
        revmap.revmap(path)
        ensure(False)
    except error.CorruptedFileError:
        pass

    # corrupt the file by removing the last byte
    ensure(size > 0)
    with open(path, 'wb') as f:
        f.truncate(size - 1)
    try:
        revmap.revmap(path)
        ensure(False)
    except error.CorruptedFileError:
        pass

    os.unlink(path)


def testcopyfrom():
    path = gettemppath()
    rm = revmap.revmap(path)
    for i in range(1, 10):
        ensure(
            rm.append(genhsh(i), sidebranch=(i & 1), path=(b'%d' % (i // 3)))
            == i
        )
    rm.flush()

    # copy rm to rm2
    rm2 = revmap.revmap()
    rm2.copyfrom(rm)
    path2 = gettemppath()
    rm2.path = path2
    rm2.flush()

    # two files should be the same
    ensure(len({util.readfile(p) for p in [path, path2]}) == 1)

    os.unlink(path)
    os.unlink(path2)


class fakefctx:
    def __init__(self, node, path=None):
        self._node = node
        self._path = path

    def node(self):
        return self._node

    def path(self):
        return self._path


def testcontains():
    path = gettemppath()

    rm = revmap.revmap(path)
    for i in range(1, 5):
        ensure(rm.append(genhsh(i), sidebranch=(i & 1)) == i)

    for i in range(1, 5):
        ensure(((genhsh(i), None) in rm) == ((i & 1) == 0))
        ensure((fakefctx(genhsh(i)) in rm) == ((i & 1) == 0))
    for i in range(5, 10):
        ensure(fakefctx(genhsh(i)) not in rm)
        ensure((genhsh(i), None) not in rm)

    # "contains" checks paths
    rm = revmap.revmap()
    for i in range(1, 5):
        ensure(rm.append(genhsh(i), path=(b'%d' % (i // 2))) == i)
    for i in range(1, 5):
        ensure(fakefctx(genhsh(i), path=(b'%d' % (i // 2))) in rm)
        ensure(fakefctx(genhsh(i), path=b'a') not in rm)


def testlastnode():
    path = gettemppath()
    ensure(revmap.getlastnode(path) is None)
    rm = revmap.revmap(path)
    ensure(revmap.getlastnode(path) is None)
    for i in range(1, 10):
        hsh = genhsh(i)
        rm.append(hsh, path=(b'%d' % (i // 2)), flush=True)
        ensure(revmap.getlastnode(path) == hsh)
        rm2 = revmap.revmap(path)
        ensure(rm2.rev2hsh(rm2.maxrev) == hsh)


testbasicreadwrite()
testcorruptformat()
testcopyfrom()
testcontains()
testlastnode()
