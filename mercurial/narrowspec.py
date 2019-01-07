# narrowspec.py - methods for working with a narrow view of a repository
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import absolute_import

import errno

from .i18n import _
from . import (
    error,
    match as matchmod,
    merge,
    repository,
    sparse,
    util,
)

# The file in .hg/store/ that indicates which paths exit in the store
FILENAME = 'narrowspec'
# The file in .hg/ that indicates which paths exit in the dirstate
DIRSTATE_FILENAME = 'narrowspec.dirstate'

# Pattern prefixes that are allowed in narrow patterns. This list MUST
# only contain patterns that are fast and safe to evaluate. Keep in mind
# that patterns are supplied by clients and executed on remote servers
# as part of wire protocol commands. That means that changes to this
# data structure influence the wire protocol and should not be taken
# lightly - especially removals.
VALID_PREFIXES = (
    b'path:',
    b'rootfilesin:',
)

def normalizesplitpattern(kind, pat):
    """Returns the normalized version of a pattern and kind.

    Returns a tuple with the normalized kind and normalized pattern.
    """
    pat = pat.rstrip('/')
    _validatepattern(pat)
    return kind, pat

def _numlines(s):
    """Returns the number of lines in s, including ending empty lines."""
    # We use splitlines because it is Unicode-friendly and thus Python 3
    # compatible. However, it does not count empty lines at the end, so trick
    # it by adding a character at the end.
    return len((s + 'x').splitlines())

def _validatepattern(pat):
    """Validates the pattern and aborts if it is invalid.

    Patterns are stored in the narrowspec as newline-separated
    POSIX-style bytestring paths. There's no escaping.
    """

    # We use newlines as separators in the narrowspec file, so don't allow them
    # in patterns.
    if _numlines(pat) > 1:
        raise error.Abort(_('newlines are not allowed in narrowspec paths'))

    components = pat.split('/')
    if '.' in components or '..' in components:
        raise error.Abort(_('"." and ".." are not allowed in narrowspec paths'))

def normalizepattern(pattern, defaultkind='path'):
    """Returns the normalized version of a text-format pattern.

    If the pattern has no kind, the default will be added.
    """
    kind, pat = matchmod._patsplit(pattern, defaultkind)
    return '%s:%s' % normalizesplitpattern(kind, pat)

def parsepatterns(pats):
    """Parses an iterable of patterns into a typed pattern set.

    Patterns are assumed to be ``path:`` if no prefix is present.
    For safety and performance reasons, only some prefixes are allowed.
    See ``validatepatterns()``.

    This function should be used on patterns that come from the user to
    normalize and validate them to the internal data structure used for
    representing patterns.
    """
    res = {normalizepattern(orig) for orig in pats}
    validatepatterns(res)
    return res

def validatepatterns(pats):
    """Validate that patterns are in the expected data structure and format.

    And that is a set of normalized patterns beginning with ``path:`` or
    ``rootfilesin:``.

    This function should be used to validate internal data structures
    and patterns that are loaded from sources that use the internal,
    prefixed pattern representation (but can't necessarily be fully trusted).
    """
    if not isinstance(pats, set):
        raise error.ProgrammingError('narrow patterns should be a set; '
                                     'got %r' % pats)

    for pat in pats:
        if not pat.startswith(VALID_PREFIXES):
            # Use a Mercurial exception because this can happen due to user
            # bugs (e.g. manually updating spec file).
            raise error.Abort(_('invalid prefix on narrow pattern: %s') % pat,
                              hint=_('narrow patterns must begin with one of '
                                     'the following: %s') %
                                   ', '.join(VALID_PREFIXES))

def format(includes, excludes):
    output = '[include]\n'
    for i in sorted(includes - excludes):
        output += i + '\n'
    output += '[exclude]\n'
    for e in sorted(excludes):
        output += e + '\n'
    return output

def match(root, include=None, exclude=None):
    if not include:
        # Passing empty include and empty exclude to matchmod.match()
        # gives a matcher that matches everything, so explicitly use
        # the nevermatcher.
        return matchmod.never(root, '')
    return matchmod.match(root, '', [], include=include or [],
                          exclude=exclude or [])

def parseconfig(ui, spec):
    # maybe we should care about the profiles returned too
    includepats, excludepats, profiles = sparse.parseconfig(ui, spec, 'narrow')
    if profiles:
        raise error.Abort(_("including other spec files using '%include' is not"
                            " supported in narrowspec"))

    validatepatterns(includepats)
    validatepatterns(excludepats)

    return includepats, excludepats

def load(repo):
    try:
        spec = repo.svfs.read(FILENAME)
    except IOError as e:
        # Treat "narrowspec does not exist" the same as "narrowspec file exists
        # and is empty".
        if e.errno == errno.ENOENT:
            return set(), set()
        raise

    return parseconfig(repo.ui, spec)

def save(repo, includepats, excludepats):
    validatepatterns(includepats)
    validatepatterns(excludepats)
    spec = format(includepats, excludepats)
    repo.svfs.write(FILENAME, spec)

def copytoworkingcopy(repo, tr):
    if tr:
        def write(file):
            spec = repo.svfs.read(FILENAME)
            file.write(spec)
            file.close()
        tr.addfilegenerator('narrowspec', (DIRSTATE_FILENAME,), write,
                            location='plain')
    else:
        spec = repo.svfs.read(FILENAME)
        repo.vfs.write(DIRSTATE_FILENAME, spec)

def savebackup(repo, backupname):
    if repository.NARROW_REQUIREMENT not in repo.requirements:
        return
    svfs = repo.svfs
    svfs.tryunlink(backupname)
    util.copyfile(svfs.join(FILENAME), svfs.join(backupname), hardlink=True)

def restorebackup(repo, backupname):
    if repository.NARROW_REQUIREMENT not in repo.requirements:
        return
    util.rename(repo.svfs.join(backupname), repo.svfs.join(FILENAME))

def clearbackup(repo, backupname):
    if repository.NARROW_REQUIREMENT not in repo.requirements:
        return
    repo.svfs.unlink(backupname)

def restrictpatterns(req_includes, req_excludes, repo_includes, repo_excludes):
    r""" Restricts the patterns according to repo settings,
    results in a logical AND operation

    :param req_includes: requested includes
    :param req_excludes: requested excludes
    :param repo_includes: repo includes
    :param repo_excludes: repo excludes
    :return: include patterns, exclude patterns, and invalid include patterns.

    >>> restrictpatterns({'f1','f2'}, {}, ['f1'], [])
    (set(['f1']), {}, [])
    >>> restrictpatterns({'f1'}, {}, ['f1','f2'], [])
    (set(['f1']), {}, [])
    >>> restrictpatterns({'f1/fc1', 'f3/fc3'}, {}, ['f1','f2'], [])
    (set(['f1/fc1']), {}, [])
    >>> restrictpatterns({'f1_fc1'}, {}, ['f1','f2'], [])
    ([], set(['path:.']), [])
    >>> restrictpatterns({'f1/../f2/fc2'}, {}, ['f1','f2'], [])
    (set(['f2/fc2']), {}, [])
    >>> restrictpatterns({'f1/../f3/fc3'}, {}, ['f1','f2'], [])
    ([], set(['path:.']), [])
    >>> restrictpatterns({'f1/$non_exitent_var'}, {}, ['f1','f2'], [])
    (set(['f1/$non_exitent_var']), {}, [])
    """
    res_excludes = set(req_excludes)
    res_excludes.update(repo_excludes)
    invalid_includes = []
    if not req_includes:
        res_includes = set(repo_includes)
    elif 'path:.' not in repo_includes:
        res_includes = []
        for req_include in req_includes:
            req_include = util.expandpath(util.normpath(req_include))
            if req_include in repo_includes:
                res_includes.append(req_include)
                continue
            valid = False
            for repo_include in repo_includes:
                if req_include.startswith(repo_include + '/'):
                    valid = True
                    res_includes.append(req_include)
                    break
            if not valid:
                invalid_includes.append(req_include)
        if len(res_includes) == 0:
            res_excludes = {'path:.'}
        else:
            res_includes = set(res_includes)
    else:
        res_includes = set(req_includes)
    return res_includes, res_excludes, invalid_includes

# These two are extracted for extensions (specifically for Google's CitC file
# system)
def _deletecleanfiles(repo, files):
    for f in files:
        repo.wvfs.unlinkpath(f)

def _writeaddedfiles(repo, pctx, files):
    actions = merge.emptyactions()
    addgaction = actions[merge.ACTION_GET].append
    mf = repo['.'].manifest()
    for f in files:
        if not repo.wvfs.exists(f):
            addgaction((f, (mf.flags(f), False), "narrowspec updated"))
    merge.applyupdates(repo, actions, wctx=repo[None],
                       mctx=repo['.'], overwrite=False)

def checkworkingcopynarrowspec(repo):
    storespec = repo.svfs.tryread(FILENAME)
    wcspec = repo.vfs.tryread(DIRSTATE_FILENAME)
    if wcspec != storespec:
        raise error.Abort(_("working copy's narrowspec is stale"),
                          hint=_("run 'hg tracked --update-working-copy'"))

def updateworkingcopy(repo):
    oldspec = repo.vfs.tryread(DIRSTATE_FILENAME)
    newspec = repo.svfs.tryread(FILENAME)

    oldincludes, oldexcludes = parseconfig(repo.ui, oldspec)
    newincludes, newexcludes = parseconfig(repo.ui, newspec)
    oldmatch = match(repo.root, include=oldincludes, exclude=oldexcludes)
    newmatch = match(repo.root, include=newincludes, exclude=newexcludes)
    addedmatch = matchmod.differencematcher(newmatch, oldmatch)
    removedmatch = matchmod.differencematcher(oldmatch, newmatch)

    ds = repo.dirstate
    lookup, status = ds.status(removedmatch, subrepos=[], ignored=False,
                               clean=True, unknown=False)
    _deletecleanfiles(repo, status.clean)
    trackeddirty = lookup + status.modified + status.added
    for f in sorted(trackeddirty):
        repo.ui.status(_('not deleting possibly dirty file %s\n') % f)
    for f in status.clean + trackeddirty:
        ds.drop(f)

    repo.narrowpats = newincludes, newexcludes
    repo._narrowmatch = newmatch
    pctx = repo['.']
    newfiles = [f for f in pctx.manifest().walk(addedmatch) if f not in ds]
    for f in newfiles:
        ds.normallookup(f)
    _writeaddedfiles(repo, pctx, newfiles)
