# resourceutil.py - utility for looking up resources
#
#  Copyright 2005 K. Thananchayan <thananck@yahoo.com>
#  Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#  Copyright 2006 Vadim Gelfer <vadim.gelfer@gmail.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os
import sys
import typing

from .. import pycompat


if typing.TYPE_CHECKING:
    from typing import (
        IO,
        Iterator,
    )


def mainfrozen():
    """return True if we are a frozen executable.

    The code supports py2exe (most common, Windows only) and tools/freeze
    (portable, not much used).
    """
    return (
        hasattr(sys, "frozen")  # new py2exe
        or hasattr(sys, "importers")  # old py2exe
        or getattr(
            getattr(sys.modules.get('__main__'), '__spec__', None),
            'origin',
            None,
        )
        == 'frozen'  # tools/freeze
    )


# the location of data files matching the source code
if mainfrozen() and getattr(sys, "frozen", None) != "macosx_app":
    # executable version (py2exe) doesn't support __file__
    datapath = os.path.dirname(pycompat.sysexecutable)
    _rootpath = datapath

    # The installers store the files outside of library.zip, like
    # C:\Program Files\Mercurial\defaultrc\*.rc.  This strips the
    # leading "mercurial." off of the package name, so that these
    # pseudo resources are found in their directory next to the
    # executable.
    def _package_path(package: bytes) -> bytes:
        dirs = package.split(b".")
        assert dirs[0] == b"mercurial"
        return os.path.join(_rootpath, *dirs[1:])

else:
    datapath = os.path.dirname(os.path.dirname(pycompat.fsencode(__file__)))
    _rootpath = os.path.dirname(datapath)

    def _package_path(package: bytes) -> bytes:
        return os.path.join(_rootpath, *package.split(b"."))


try:
    # importlib.resources exists from Python 3.7; see fallback in except clause
    # further down
    from importlib import resources  # pytype: disable=import-error

    # Force loading of the resources module
    if hasattr(resources, 'files'):  # Introduced in Python 3.9
        resources.files  # pytype: disable=module-attr
    else:
        resources.open_binary  # pytype: disable=module-attr

    # py2exe raises an AssertionError if uses importlib.resources
    if getattr(sys, "frozen", None) in ("console_exe", "windows_exe"):
        raise ImportError

except (ImportError, AttributeError):
    # importlib.resources was not found (almost definitely because we're on a
    # Python version before 3.7)

    def open_resource(package: bytes, name: bytes) -> IO[bytes]:
        path = os.path.join(_package_path(package), name)
        return open(path, "rb")

    def is_resource(package: bytes, name: bytes) -> bool:
        path = os.path.join(_package_path(package), name)

        try:
            return os.path.isfile(pycompat.fsdecode(path))
        except OSError:
            return False

    def contents(package: bytes) -> Iterator[bytes]:
        path = pycompat.fsdecode(_package_path(package))

        for p in os.listdir(path):
            yield pycompat.fsencode(p)

else:
    from .. import encoding

    def open_resource(package: bytes, name: bytes) -> IO[bytes]:
        if hasattr(resources, 'files'):
            return (
                resources.files(  # pytype: disable=module-attr
                    pycompat.sysstr(package)
                )
                .joinpath(pycompat.sysstr(name))
                .open('rb')
            )
        else:
            return resources.open_binary(  # pytype: disable=module-attr
                pycompat.sysstr(package), pycompat.sysstr(name)
            )

    def is_resource(package: bytes, name: bytes) -> bool:
        if hasattr(resources, 'files'):  # Introduced in Python 3.9
            return (
                resources.files(pycompat.sysstr(package))
                .joinpath(encoding.strfromlocal(name))
                .is_file()
            )
        else:
            return resources.is_resource(  # pytype: disable=module-attr
                pycompat.sysstr(package), encoding.strfromlocal(name)
            )

    def contents(package: bytes) -> Iterator[bytes]:
        if hasattr(resources, 'files'):  # Introduced in Python 3.9
            for path in resources.files(pycompat.sysstr(package)).iterdir():
                if path.is_file():
                    yield encoding.strtolocal(path.name)
        else:
            # pytype: disable=module-attr
            for r in resources.contents(pycompat.sysstr(package)):
                # pytype: enable=module-attr
                yield encoding.strtolocal(r)
