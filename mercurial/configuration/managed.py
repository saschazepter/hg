# machine managed configuration files
#
# The values Mercurial is told to write (see `hg config --set`) live in a file
# of its own, included from the top of the file the user edits by hand. That
# way the hand written file is never rewritten, and its content always wins.

from __future__ import annotations

import os

# machine writes go to "<hgrc><-suffix>[.<ext>]"
SUFFIX = b'-managed'

HEADER = (
    b"# This file is managed by Mercurial, do not edit it by hand.\n"
    b"# Use `hg config --set` to change the values it holds.\n"
)


def sibling(path: bytes) -> bytes:
    """return the path of the machine-managed companion of config file `path`"""
    core, ext = os.path.splitext(path)
    return core + SUFFIX + ext


def inject_include(base_content: bytes, target: bytes) -> bytes:
    """return `base_content` with a single `%include` of `target` on top

    The include must stay the first line. Manually set value always wins.

    >>> inject_include(b'[ui]\\nusername = Foo\\n', b'.hgrc.managed')
    b'%include .hgrc.managed\\n[ui]\\nusername = Foo\\n'
    >>> inject_include(b'%include .hgrc.managed\\n', b'.hgrc.managed')
    b'%include .hgrc.managed\\n'
    >>> inject_include(b'no newline', b'.hgrc.managed')
    b'%include .hgrc.managed\\nno newline\\n'
    >>> inject_include(
    ...     b'[ui]\\nusername = Foo\\n%include .hgrc.managed\\n',
    ...     b'.hgrc.managed',
    ... )
    b'%include .hgrc.managed\\n[ui]\\nusername = Foo\\n'
    """
    # `%include` is resolved relative to the including file, and both files
    # live in the same directory, so a bare basename is enough (and stays
    # valid if the configuration directory is moved around).
    include_line = b"%%include %s" % target
    lines = base_content.splitlines(True)
    if lines and lines[0].rstrip() == include_line:
        # already included first, nothing to do
        return base_content
    # drop any occurrence further down before re-inserting it at the top
    lines = [l for l in lines if l.rstrip() != include_line]
    base_content = b"".join(lines)
    if base_content and not base_content.endswith(b'\n'):
        base_content += b'\n'
    return include_line + b"\n" + base_content
