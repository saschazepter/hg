# bundlecaches.py - basis utility to deal with clone bundle manifests
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
#
# Has few import on purposes, see mercurial.bundlecaches for more advanced logic.

from __future__ import annotations

CB_MANIFEST_FILE = b'clonebundles.manifest'


def get_manifest(repo) -> bytes:
    """get the bundle manifest to be served to a client from a server"""
    raw_text = repo.vfs.tryread(CB_MANIFEST_FILE)
    entries = [e.split(b' ', 1) for e in raw_text.splitlines()]

    new_lines = []
    for e in entries:
        url = alter_bundle_url(repo, e[0])
        if len(e) == 1:
            line = url + b'\n'
        else:
            line = b"%s %s\n" % (url, e[1])
        new_lines.append(line)
    return b''.join(new_lines)


def alter_bundle_url(repo, url: bytes) -> bytes:
    """a function that exist to help extension and hosting to alter the url

    This will typically be used to inject authentication information in the url
    of cached bundles."""
    return url
