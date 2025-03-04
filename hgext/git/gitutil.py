"""utilities to assist in working with pygit2"""

from __future__ import annotations

from mercurial.node import bin, sha1nodeconstants

pygit2_module = None


def get_pygit2():
    global pygit2_module
    if pygit2_module is None:
        try:
            import pygit2 as pygit2_module  # pytype: disable=import-error

            pygit2_module.InvalidSpecError
        except (ImportError, AttributeError):
            pass
    return pygit2_module


def pygit2_version():
    mod = get_pygit2()
    v = "N/A"

    if mod:
        try:
            v = mod.__version__
        except AttributeError:
            pass

    return b"(pygit2 %s)" % v.encode("utf-8")


def togitnode(n):
    """Wrapper to convert a Mercurial binary node to a unicode hexlified node.

    pygit2 and sqlite both need nodes as strings, not bytes.
    """
    assert len(n) == 20
    return n.hex()


def fromgitnode(n):
    """Opposite of togitnode."""
    assert len(n) == 40
    return bin(n)


nullgit = togitnode(sha1nodeconstants.nullid)
