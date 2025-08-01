# clone.py - high level logic for cloning
#
# Copyright 2005-2007 Olivia Mackall <olivia@selenic.com>
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import os

from ..i18n import _

from .. import (
    error,
    narrowspec,
    requirements,
    util,
)
from . import (
    update as up_impl,
)
from ..repo import factory as repo_factory
from ..utils import (
    urlutil,
)


# shared features
sharedbookmarks = b'bookmarks'


def default_dest(source):
    """return default destination of clone if none is given

    >>> default_dest(b'foo')
    'foo'
    >>> default_dest(b'/foo/bar')
    'bar'
    >>> default_dest(b'/')
    ''
    >>> default_dest(b'')
    ''
    >>> default_dest(b'http://example.org/')
    ''
    >>> default_dest(b'http://example.org/foo/')
    'foo'
    """
    path = urlutil.url(source).path
    if not path:
        return b''
    return os.path.basename(os.path.normpath(path))


def share(
    ui,
    source,
    dest=None,
    update=True,
    bookmarks=True,
    defaultpath=None,
    relative=False,
):
    '''create a shared repository'''

    not_local_msg = _(b'can only share local repositories')
    if hasattr(source, 'local'):
        if source.local() is None:
            raise error.Abort(not_local_msg)
    elif not repo_factory.is_local(source):
        # XXX why are we getting bytes here ?
        raise error.Abort(not_local_msg)

    if not dest:
        dest = default_dest(source)
    else:
        dest = urlutil.get_clone_path_obj(ui, dest).loc

    if isinstance(source, bytes):
        source_path = urlutil.get_clone_path_obj(ui, source)
        srcrepo = repo_factory.repository(ui, source_path.loc)
        branches = (source_path.branch, [])
        rev, checkout = urlutil.add_branch_revs(
            srcrepo,
            srcrepo,
            branches,
            None,
        )
    else:
        srcrepo = source.local()
        checkout = None

    shareditems = set()
    if bookmarks:
        shareditems.add(sharedbookmarks)

    r = repo_factory.repository(
        ui,
        dest,
        create=True,
        createopts={
            b'sharedrepo': srcrepo,
            b'sharedrelative': relative,
            b'shareditems': shareditems,
        },
    )

    post_share(srcrepo, r, defaultpath=defaultpath)
    r = repo_factory.repository(ui, dest)
    _post_share_update(r, update, checkout=checkout)
    return r


def post_share(sourcerepo, destrepo, defaultpath=None):
    """Called after a new shared repo is created.

    The new repo only has a requirements file and pointer to the source.
    This function configures additional shared data.

    Extensions can wrap this function and write additional entries to
    destrepo/.hg/shared to indicate additional pieces of data to be shared.
    """
    default = defaultpath or sourcerepo.ui.config(b'paths', b'default')
    if default:
        template = b'[paths]\ndefault = %s\n'
        destrepo.vfs.write(b'hgrc', util.tonativeeol(template % default))
    if requirements.NARROW_REQUIREMENT in sourcerepo.requirements:
        with destrepo.wlock(), destrepo.lock(), destrepo.transaction(
            b"narrow-share"
        ):
            narrowspec.copytoworkingcopy(destrepo)


def _post_share_update(repo, update, checkout=None):
    """Maybe perform a working directory update after a shared repo is created.

    ``update`` can be a boolean or a revision to update to.
    """
    if not update:
        return

    repo.ui.status(_(b"updating working directory\n"))
    if update is not True:
        checkout = update
    for test in (checkout, b'default', b'tip'):
        if test is None:
            continue
        try:
            uprev = repo.lookup(test)
            break
        except error.RepoLookupError:
            continue
    up_impl.update(repo, uprev)
