# bundle_caps.py - dealing with producing and consuming bundle capabilities
#
# Copyright 2013-2025  Pierre-Yves David <pierre-yves.david@octobus.net>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations


from ..interfaces.types import (
    Capabilities,
)

from .. import (
    changegroup,
    error,
    obsolete,
    util,
)


# These are only the static capabilities.
# Check the 'getrepocaps' function for the rest.
capabilities: Capabilities = {
    b'HG20': (),
    b'bookmarks': (),
    b'error': (b'abort', b'unsupportedcontent', b'pushraced', b'pushkey'),
    b'listkeys': (),
    b'pushkey': (),
    b'digests': tuple(sorted(util.DIGESTS.keys())),
    b'remote-changegroup': (b'http', b'https'),
    b'hgtagsfnodes': (),
    b'phases': (b'heads',),
    b'stream': (b'v2',),
}


# TODO: drop the default value for 'role'
def get_repo_caps(repo, allowpushback: bool = False, role=None) -> Capabilities:
    """return the bundle2 capabilities for a given repo

    Exists to allow extensions (like evolution) to mutate the capabilities.

    The returned value is used for servers advertising their capabilities as
    well as clients advertising their capabilities to servers as part of
    bundle2 requests. The ``role`` argument specifies which is which.
    """
    if role not in (b'client', b'server'):
        raise error.ProgrammingError(b'role argument must be client or server')

    caps = capabilities.copy()
    caps[b'changegroup'] = tuple(
        sorted(changegroup.supportedincomingversions(repo))
    )
    if obsolete.isenabled(repo, obsolete.exchangeopt):
        supportedformat = tuple(b'V%i' % v for v in obsolete.formats)
        caps[b'obsmarkers'] = supportedformat
    if allowpushback:
        caps[b'pushback'] = ()
    cpmode = repo.ui.config(b'server', b'concurrent-push-mode')
    if cpmode == b'check-related':
        caps[b'checkheads'] = (b'related',)
    if b'phases' in repo.ui.configlist(b'devel', b'legacy.exchange'):
        caps.pop(b'phases')

    # Don't advertise stream clone support in server mode if not configured.
    if role == b'server':
        streamsupported = repo.ui.configbool(
            b'server', b'uncompressed', untrusted=True
        )
        featuresupported = repo.ui.configbool(b'server', b'bundle2.stream')

        if not streamsupported or not featuresupported:
            caps.pop(b'stream')
    # Else always advertise support on client, because payload support
    # should always be advertised.

    if repo.ui.configbool(b'experimental', b'stream-v3'):
        if b'stream' in caps:
            caps[b'stream'] += (b'v3-exp',)

    # b'rev-branch-cache is no longer advertised, but still supported
    # for legacy clients.

    return caps
