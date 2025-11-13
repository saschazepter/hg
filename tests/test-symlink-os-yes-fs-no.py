import os
import sys
import time
from mercurial import (
    commands,
    initialization,
    policy,
    pycompat,
    ui as uimod,
    util,
)
from mercurial.repo import factory

initialization.init()

TESTDIR = os.environ["TESTDIR"]
BUNDLEPATH = os.path.join(TESTDIR, 'bundles', 'test-no-symlinks.hg')
SKIPPED_RETURN_CODE = 80  # SKIPPED_STATUS defined in run-tests.py

if policy.importrust('revlog') is not None:
    # Rust cannot be monkey-patched and has no support for systems without
    # symlinks yet.
    sys.exit(SKIPPED_RETURN_CODE)

# only makes sense to test on os which supports symlinks
if not getattr(os, "symlink", False):
    sys.exit(SKIPPED_RETURN_CODE)

u = uimod.ui.load()
# hide outer repo
factory.peer(u, {}, b'.', create=True)

# unbundle with symlink support
factory.peer(u, {}, b'test0', create=True)

repo = factory.repository(u, b'test0')
commands.unbundle(u, repo, pycompat.fsencode(BUNDLEPATH), update=True)

# wait a bit, or the status call wont update the dirstate
time.sleep(1)
commands.status(u, repo)


# now disable symlink support -- this is what os.symlink would do on a
# non-symlink file system
def symlink_failure(src, dst):
    raise OSError(1, "Operation not permitted")


os.symlink = symlink_failure


def islink_failure(path):
    return False


os.path.islink = islink_failure

# dereference links as if a Samba server has exported this to a
# Windows client
for f in b'test0/a.lnk', b'test0/d/b.lnk':
    os.unlink(f)
    fp = open(f, 'wb')
    fp.write(util.readfile(f[:-4]))
    fp.close()

# reload repository
u = uimod.ui.load()
repo = factory.repository(u, b'test0')
commands.status(u, repo)

# try unbundling a repo which contains symlinks
u = uimod.ui.load()

repo = factory.repository(u, b'test1', create=True)
commands.unbundle(u, repo, pycompat.fsencode(BUNDLEPATH), update=True)
