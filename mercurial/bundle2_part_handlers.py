# bundle2_part_handlers.py - many part handler for bundle2
#
# Copyright 2013 Facebook, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

from .i18n import _
from .node import (
    hex,
    short,
)

from .interfaces.types import (
    UnbundleOpT,
)
from . import (
    bookmarks,
    bundle2,
    changegroup,
    error,
    exchange,
    phases,
    pushkey,
    pycompat,
    requirements,
    scmutil,
    streamclone,
    tables,
    tags,
    url,
    util,
)
from .exchanges import (
    bundle_caps,
)
from .utils import (
    urlutil,
)
from .repo import (
    vfs_options as repo_vfs_opts,
)


def init():
    """noop function that is called to make sure the module is loaded and has
    registered the necessary items.

    See `mercurial.initialization` for details"""


parthandlermapping = tables.bundle2_part_handler_mapping


def parthandler(parttype, params=()):
    """decorator that register a function as a bundle2 part handler

    eg::

        @parthandler('myparttype', ('mandatory', 'param', 'handled'))
        def myparttypehandler(...):
            '''process a part of type "my part".'''
            ...
    """
    bundle2.validateparttype(parttype)

    def _decorator(func):
        lparttype = parttype.lower()  # enforce lower case matching.
        assert lparttype not in parthandlermapping
        parthandlermapping[lparttype] = func
        func.params = frozenset(params)
        return func

    return _decorator


@parthandler(
    b'changegroup',
    (
        b'version',
        b'nbchanges',
        b'exp-sidedata',
        b'exp-wanted-sidedata',
        b'treemanifest',
        b'targetphase',
    ),
)
def handlechangegroup(op: UnbundleOpT, inpart):
    """apply a changegroup part on the repo"""
    tr = op.gettransaction()
    unpackerversion = inpart.params.get(b'version', b'01')
    # We should raise an appropriate exception here
    cg = changegroup.getunbundler(unpackerversion, inpart, None)
    # the source and url passed here are overwritten by the one contained in
    # the transaction.hookargs argument. So 'bundle2' is a placeholder
    nbchangesets = None
    if b'nbchanges' in inpart.params:
        nbchangesets = int(inpart.params.get(b'nbchanges'))
    if b'treemanifest' in inpart.params and not scmutil.istreemanifest(op.repo):
        if len(op.repo.changelog) != 0:
            raise error.Abort(
                _(
                    b"bundle contains tree manifests, but local repo is "
                    b"non-empty and does not use tree manifests"
                )
            )
        op.repo.requirements.add(requirements.TREEMANIFEST_REQUIREMENT)
        op.repo.svfs.options = repo_vfs_opts.resolve_store_vfs_options(
            op.repo.ui,
            op.repo.requirements,
            op.repo.features,
        )
        scmutil.writereporequirements(op.repo)

    extrakwargs = {}
    targetphase = inpart.params.get(b'targetphase')
    if targetphase is not None:
        extrakwargs['targetphase'] = int(targetphase)

    remote_sidedata = inpart.params.get(b'exp-wanted-sidedata')
    extrakwargs['sidedata_categories'] = bundle2.read_wanted_sidedata(
        remote_sidedata
    )

    ret = bundle2.process_changegroup(
        op,
        cg,
        tr,
        op.source,
        b'bundle2',
        expectedtotal=nbchangesets,
        **extrakwargs,
    )
    if op.reply is not None:
        # This is definitely not the final form of this
        # return. But one need to start somewhere.
        part = op.reply.newpart(b'reply:changegroup', mandatory=False)
        part.addparam(
            b'in-reply-to', pycompat.bytestr(inpart.id), mandatory=False
        )
        part.addparam(b'return', b'%i' % ret, mandatory=False)
    assert not inpart.read()


_remotechangegroupparams = tuple(
    [b'url', b'size', b'digests']
    + [b'digest:%s' % k for k in util.DIGESTS.keys()]
)


@parthandler(b'remote-changegroup', _remotechangegroupparams)
def handleremotechangegroup(op: UnbundleOpT, inpart):
    """apply a bundle10 on the repo, given an url and validation information

    All the information about the remote bundle to import are given as
    parameters. The parameters include:
      - url: the url to the bundle10.
      - size: the bundle10 file size. It is used to validate what was
        retrieved by the client matches the server knowledge about the bundle.
      - digests: a space separated list of the digest types provided as
        parameters.
      - digest:<digest-type>: the hexadecimal representation of the digest with
        that name. Like the size, it is used to validate what was retrieved by
        the client matches what the server knows about the bundle.

    When multiple digest types are given, all of them are checked.
    """
    try:
        raw_url = inpart.params[b'url']
    except KeyError:
        raise error.Abort(_(b'remote-changegroup: missing "%s" param') % b'url')
    parsed_url = urlutil.url(raw_url)
    if parsed_url.scheme not in bundle_caps.capabilities[b'remote-changegroup']:
        raise error.Abort(
            _(b'remote-changegroup does not support %s urls')
            % parsed_url.scheme
        )

    try:
        size = int(inpart.params[b'size'])
    except ValueError:
        raise error.Abort(
            _(b'remote-changegroup: invalid value for param "%s"') % b'size'
        )
    except KeyError:
        raise error.Abort(
            _(b'remote-changegroup: missing "%s" param') % b'size'
        )

    digests = {}
    for typ in inpart.params.get(b'digests', b'').split():
        param = b'digest:%s' % typ
        try:
            value = inpart.params[param]
        except KeyError:
            raise error.Abort(
                _(b'remote-changegroup: missing "%s" param') % param
            )
        digests[typ] = value

    real_part = util.digestchecker(url.open(op.ui, raw_url), size, digests)

    tr = op.gettransaction()

    cg = exchange.readbundle(op.repo.ui, real_part, raw_url)
    if not isinstance(cg, changegroup.cg1unpacker):
        raise error.Abort(
            _(b'%s: not a bundle version 1.0') % urlutil.hidepassword(raw_url)
        )
    ret = bundle2.process_changegroup(
        op,
        cg,
        tr,
        op.source,
        b'bundle2',
    )
    if op.reply is not None:
        # This is definitely not the final form of this
        # return. But one need to start somewhere.
        part = op.reply.newpart(b'reply:changegroup')
        part.addparam(
            b'in-reply-to', pycompat.bytestr(inpart.id), mandatory=False
        )
        part.addparam(b'return', b'%i' % ret, mandatory=False)
    try:
        real_part.validate()
    except error.Abort as e:
        raise error.Abort(
            _(b'bundle at %s is corrupted:\n%s')
            % (urlutil.hidepassword(raw_url), e.message)
        )
    assert not inpart.read()


@parthandler(b'reply:changegroup', (b'return', b'in-reply-to'))
def handlereplychangegroup(op: UnbundleOpT, inpart):
    ret = int(inpart.params[b'return'])
    replyto = int(inpart.params[b'in-reply-to'])
    op.records.add(b'changegroup', {b'return': ret}, replyto)


@parthandler(b'check:bookmarks')
def handlecheckbookmarks(op, inpart):
    """check location of bookmarks

    This part is to be used to detect push race regarding bookmark, it
    contains binary encoded (bookmark, node) tuple. If the local state does
    not marks the one in the part, a PushRaced exception is raised
    """
    bookdata = bookmarks.binarydecode(op.repo, inpart)

    msgstandard = (
        b'remote repository changed while pushing - please try again '
        b'(bookmark "%s" move from %s to %s)'
    )
    msgmissing = (
        b'remote repository changed while pushing - please try again '
        b'(bookmark "%s" is missing, expected %s)'
    )
    msgexist = (
        b'remote repository changed while pushing - please try again '
        b'(bookmark "%s" set on %s, expected missing)'
    )
    for book, node in bookdata:
        currentnode = op.repo._bookmarks.get(book)
        if currentnode != node:
            if node is None:
                finalmsg = msgexist % (book, short(currentnode))
            elif currentnode is None:
                finalmsg = msgmissing % (book, short(node))
            else:
                finalmsg = msgstandard % (
                    book,
                    short(node),
                    short(currentnode),
                )
            raise error.PushRaced(finalmsg)


@parthandler(b'check:heads')
def handlecheckheads(op: UnbundleOpT, inpart):
    """check that head of the repo did not change

    This is used to detect a push race when using unbundle.
    This replaces the "heads" argument of unbundle."""
    h = inpart.read(20)
    heads = []
    while len(h) == 20:
        heads.append(h)
        h = inpart.read(20)
    assert not h
    # Trigger a transaction so that we are guaranteed to have the lock now.
    if op.ui.configbool(b'experimental', b'bundle2lazylocking'):
        op.gettransaction()
    if sorted(heads) != sorted(op.repo.heads()):
        raise error.PushRaced(
            b'remote repository changed while pushing - please try again'
        )


@parthandler(b'check:updated-heads')
def handlecheckupdatedheads(op: UnbundleOpT, inpart):
    """check for race on the heads touched by a push

    This is similar to 'check:heads' but focus on the heads actually updated
    during the push. If other activities happen on unrelated heads, it is
    ignored.

    This allow server with high traffic to avoid push contention as long as
    unrelated parts of the graph are involved."""
    h = inpart.read(20)
    heads = []
    while len(h) == 20:
        heads.append(h)
        h = inpart.read(20)
    assert not h
    # trigger a transaction so that we are guaranteed to have the lock now.
    if op.ui.configbool(b'experimental', b'bundle2lazylocking'):
        op.gettransaction()

    currentheads = set()
    for ls in op.repo.branchmap().iterheads():
        currentheads.update(ls)

    for h in heads:
        if h not in currentheads:
            raise error.PushRaced(
                b'remote repository changed while pushing - '
                b'please try again'
            )


@parthandler(b'check:phases')
def handlecheckphases(op: UnbundleOpT, inpart):
    """check that phase boundaries of the repository did not change

    This is used to detect a push race.
    """
    phasetonodes = phases.binarydecode(inpart)
    unfi = op.repo.unfiltered()
    cl = unfi.changelog
    phasecache = unfi._phasecache
    msg = (
        b'remote repository changed while pushing - please try again '
        b'(%s is %s expected %s)'
    )
    for expectedphase, nodes in phasetonodes.items():
        for n in nodes:
            actualphase = phasecache.phase(unfi, cl.rev(n))
            if actualphase != expectedphase:
                finalmsg = msg % (
                    short(n),
                    phases.phasenames[actualphase],
                    phases.phasenames[expectedphase],
                )
                raise error.PushRaced(finalmsg)


@parthandler(b'output')
def handleoutput(op: UnbundleOpT, inpart):
    """forward output captured on the server to the client"""
    for line in inpart.read().splitlines():
        op.ui.status(_(b'remote: %s\n') % line)


@parthandler(b'replycaps')
def handlereplycaps(op: UnbundleOpT, inpart):
    """Notify that a reply bundle should be created

    The payload contains the capabilities information for the reply"""
    caps = bundle2.decodecaps(inpart.read())
    if op.reply is None:
        op.reply = bundle2.bundle20(op.ui, caps)


@parthandler(b'error:abort', (b'message', b'hint'))
def handleerrorabort(op: UnbundleOpT, inpart):
    """Used to transmit abort error over the wire"""
    raise bundle2.AbortFromPart(
        inpart.params[b'message'], hint=inpart.params.get(b'hint')
    )


@parthandler(
    b'error:pushkey',
    (b'namespace', b'key', b'new', b'old', b'ret', b'in-reply-to'),
)
def handleerrorpushkey(op: UnbundleOpT, inpart):
    """Used to transmit failure of a mandatory pushkey over the wire"""
    kwargs = {}
    for name in (b'namespace', b'key', b'new', b'old', b'ret'):
        value = inpart.params.get(name)
        if value is not None:
            kwargs[name] = value
    raise error.PushkeyFailed(
        inpart.params[b'in-reply-to'], **pycompat.strkwargs(kwargs)
    )


@parthandler(b'error:unsupportedcontent', (b'parttype', b'params'))
def handleerrorunsupportedcontent(op: UnbundleOpT, inpart):
    """Used to transmit unknown content error over the wire"""
    kwargs = {}
    parttype = inpart.params.get(b'parttype')
    if parttype is not None:
        kwargs[b'parttype'] = parttype
    params = inpart.params.get(b'params')
    if params is not None:
        kwargs[b'params'] = params.split(b'\0')

    raise error.BundleUnknownFeatureError(**pycompat.strkwargs(kwargs))


@parthandler(b'error:pushraced', (b'message',))
def handleerrorpushraced(op: UnbundleOpT, inpart):
    """Used to transmit push race error over the wire"""
    raise error.ResponseError(_(b'push failed:'), inpart.params[b'message'])


@parthandler(b'listkeys', (b'namespace',))
def handlelistkeys(op: UnbundleOpT, inpart):
    """retrieve pushkey namespace content stored in a bundle2"""
    namespace = inpart.params[b'namespace']
    r = pushkey.decodekeys(inpart.read())
    op.records.add(b'listkeys', (namespace, r))


@parthandler(b'pushkey', (b'namespace', b'key', b'old', b'new'))
def handlepushkey(op: UnbundleOpT, inpart):
    """process a pushkey request"""
    dec = pushkey.decode
    namespace = dec(inpart.params[b'namespace'])
    key = dec(inpart.params[b'key'])
    old = dec(inpart.params[b'old'])
    new = dec(inpart.params[b'new'])
    # Grab the transaction to ensure that we have the lock before performing the
    # pushkey.
    if op.ui.configbool(b'experimental', b'bundle2lazylocking'):
        op.gettransaction()
    ret = op.repo.pushkey(namespace, key, old, new)
    record = {b'namespace': namespace, b'key': key, b'old': old, b'new': new}
    op.records.add(b'pushkey', record)
    if op.reply is not None:
        rpart = op.reply.newpart(b'reply:pushkey')
        rpart.addparam(
            b'in-reply-to', pycompat.bytestr(inpart.id), mandatory=False
        )
        rpart.addparam(b'return', b'%i' % ret, mandatory=False)
    if inpart.mandatory and not ret:
        kwargs = {}
        for key in (b'namespace', b'key', b'new', b'old', b'ret'):
            if key in inpart.params:
                kwargs[key] = inpart.params[key]
        raise error.PushkeyFailed(
            partid=b'%d' % inpart.id, **pycompat.strkwargs(kwargs)
        )


@parthandler(b'bookmarks')
def handlebookmark(op, inpart):
    """transmit bookmark information

    The part contains binary encoded bookmark information.

    The exact behavior of this part can be controlled by the 'bookmarks' mode
    on the bundle operation.

    When mode is 'apply' (the default) the bookmark information is applied as
    is to the unbundling repository. Make sure a 'check:bookmarks' part is
    issued earlier to check for push races in such update. This behavior is
    suitable for pushing.

    When mode is 'records', the information is recorded into the 'bookmarks'
    records of the bundle operation. This behavior is suitable for pulling.
    """
    changes = bookmarks.binarydecode(op.repo, inpart)

    pushkeycompat = op.repo.ui.configbool(
        b'server', b'bookmarks-pushkey-compat'
    )
    bookmarksmode = op.modes.get(b'bookmarks', b'apply')

    if bookmarksmode == b'apply':
        tr = op.gettransaction()
        bookstore = op.repo._bookmarks
        if pushkeycompat:
            allhooks = []
            for book, node in changes:
                hookargs = tr.hookargs.copy()
                hookargs[b'pushkeycompat'] = b'1'
                hookargs[b'namespace'] = b'bookmarks'
                hookargs[b'key'] = book
                hookargs[b'old'] = hex(bookstore.get(book, b''))
                hookargs[b'new'] = hex(node if node is not None else b'')
                allhooks.append(hookargs)

            for hookargs in allhooks:
                op.repo.hook(
                    b'prepushkey', throw=True, **pycompat.strkwargs(hookargs)
                )

        for book, node in changes:
            if bookmarks.isdivergent(book):
                msg = _(b'cannot accept divergent bookmark %s!') % book
                raise error.Abort(msg)

        bookstore.applychanges(op.repo, op.gettransaction(), changes)

        if pushkeycompat:

            def runhook(unused_success):
                for hookargs in allhooks:
                    op.repo.hook(b'pushkey', **pycompat.strkwargs(hookargs))

            op.repo._afterlock(runhook)

    elif bookmarksmode == b'records':
        for book, node in changes:
            record = {b'bookmark': book, b'node': node}
            op.records.add(b'bookmarks', record)
    else:
        raise error.ProgrammingError(
            b'unknown bookmark mode: %s' % bookmarksmode
        )


@parthandler(b'phase-heads')
def handlephases(op: UnbundleOpT, inpart):
    """apply phases from bundle part to repo"""
    headsbyphase = phases.binarydecode(inpart)
    phases.updatephases(op.repo.unfiltered(), op.gettransaction, headsbyphase)


@parthandler(b'reply:pushkey', (b'return', b'in-reply-to'))
def handlepushkeyreply(op: UnbundleOpT, inpart):
    """retrieve the result of a pushkey request"""
    ret = int(inpart.params[b'return'])
    partid = int(inpart.params[b'in-reply-to'])
    op.records.add(b'pushkey', {b'return': ret}, partid)


@parthandler(b'obsmarkers')
def handleobsmarker(op: UnbundleOpT, inpart):
    """add a stream of obsmarkers to the repo"""
    tr = op.gettransaction()
    markerdata = inpart.read()
    if op.ui.config(b'experimental', b'obsmarkers-exchange-debug'):
        op.ui.writenoi18n(
            b'obsmarker-exchange: %i bytes received\n' % len(markerdata)
        )
    # The mergemarkers call will crash if marker creation is not enabled.
    # we want to avoid this if the part is advisory.
    if not inpart.mandatory and op.repo.obsstore.readonly:
        op.repo.ui.debug(
            b'ignoring obsolescence markers, feature not enabled\n'
        )
        return
    new = op.repo.obsstore.mergemarkers(tr, markerdata)
    op.repo.invalidatevolatilesets()
    op.records.add(b'obsmarkers', {b'new': new})
    if op.reply is not None:
        rpart = op.reply.newpart(b'reply:obsmarkers')
        rpart.addparam(
            b'in-reply-to', pycompat.bytestr(inpart.id), mandatory=False
        )
        rpart.addparam(b'new', b'%i' % new, mandatory=False)


@parthandler(b'reply:obsmarkers', (b'new', b'in-reply-to'))
def handleobsmarkerreply(op: UnbundleOpT, inpart):
    """retrieve the result of a pushkey request"""
    ret = int(inpart.params[b'new'])
    partid = int(inpart.params[b'in-reply-to'])
    op.records.add(b'obsmarkers', {b'new': ret}, partid)


@parthandler(b'hgtagsfnodes')
def handlehgtagsfnodes(op: UnbundleOpT, inpart):
    """Applies .hgtags fnodes cache entries to the local repo.

    Payload is pairs of 20 byte changeset nodes and filenodes.
    """
    # Grab the transaction so we ensure that we have the lock at this point.
    if op.ui.configbool(b'experimental', b'bundle2lazylocking'):
        op.gettransaction()
    cache = tags.hgtagsfnodescache(op.repo.unfiltered())

    count = 0
    while True:
        node = inpart.read(20)
        fnode = inpart.read(20)
        if len(node) < 20 or len(fnode) < 20:
            op.ui.debug(b'ignoring incomplete received .hgtags fnodes data\n')
            break
        cache.setfnode(node, fnode)
        count += 1

    cache.write()
    op.ui.debug(b'applied %i hgtags fnodes cache entries\n' % count)


@parthandler(b'cache:rev-branch-cache')
def handlerbc(op: UnbundleOpT, inpart):
    """Legacy part, ignored for compatibility with bundles from or
    for Mercurial before 5.7. Newer Mercurial computes the cache
    efficiently enough during unbundling that the additional transfer
    is unnecessary."""


@parthandler(b'pushvars')
def bundle2getvars(op: UnbundleOpT, part):
    '''unbundle a bundle2 containing shellvars on the server'''
    # An option to disable unbundling on server-side for security reasons
    if op.ui.configbool(b'push', b'pushvars.server'):
        hookargs = {}
        for key, value in part.advisoryparams:
            key = key.upper()
            # We want pushed variables to have USERVAR_ prepended so we know
            # they came from the --pushvar flag.
            key = b"USERVAR_" + key
            hookargs[key] = value
        op.addhookargs(hookargs)


@parthandler(b'stream2', (b'requirements', b'filecount', b'bytecount'))
def handlestreamv2bundle(op: UnbundleOpT, part):
    requirements = util.urlreq.unquote(part.params[b'requirements'])
    requirements = requirements.split(b',') if requirements else []
    filecount = int(part.params[b'filecount'])
    bytecount = int(part.params[b'bytecount'])

    repo = op.repo
    if len(repo):
        msg = _(b'cannot apply stream clone to non empty repository')
        raise error.Abort(msg)

    repo.ui.debug(b'applying stream bundle\n')
    streamclone.applybundlev2(repo, part, filecount, bytecount, requirements)


@parthandler(b'stream3-exp', (b'requirements',))
def handlestreamv3bundle(op: UnbundleOpT, part):
    requirements = util.urlreq.unquote(part.params[b'requirements'])
    requirements = requirements.split(b',') if requirements else []

    repo = op.repo
    if len(repo):
        msg = _(b'cannot apply stream clone to non empty repository')
        raise error.Abort(msg)

    repo.ui.debug(b'applying stream bundle\n')
    streamclone.applybundlev3(repo, part, requirements)
