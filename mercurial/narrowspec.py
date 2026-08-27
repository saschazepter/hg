# narrowspec.py - methods for working with a narrow view of a repository
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import weakref
from typing import BinaryIO, Iterable

from .i18n import _
from .interfaces.types import RepoT, StoreShapePatternsT
from . import (
    error,
    match as matchmod,
    policy,
    shape,
    sparse,
    txnutil,
    util,
)

shapemod_rust = policy.importrust("shape")

# The file in .hg/store/ that indicates which paths exit in the store
FILENAME = b'narrowspec'
# The file in .hg/ that indicates which paths exit in the dirstate
DIRSTATE_FILENAME = b'narrowspec.dirstate'
# The file in .hg/store that indicates which shape this repo was cloned with
# Later version will evolve to contain the narrow patterns and possibly
# evolve with widening/narrowing
SHAPE_FILENAME = b"store-shape"

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
    pat = pat.rstrip(b'/')
    _validatepattern(pat)
    return kind, pat


def _numlines(s):
    """Returns the number of lines in s, including ending empty lines."""
    # We use splitlines because it is Unicode-friendly and thus Python 3
    # compatible. However, it does not count empty lines at the end, so trick
    # it by adding a character at the end.
    return len((s + b'x').splitlines())


def _validatepattern(pat):
    """Validates the pattern and aborts if it is invalid.

    Patterns are stored in the narrowspec as newline-separated
    POSIX-style bytestring paths. There's no escaping.
    """

    # We use newlines as separators in the narrowspec file, so don't allow them
    # in patterns.
    if _numlines(pat) > 1:
        raise error.Abort(_(b'newlines are not allowed in narrowspec paths'))

    # patterns are stripped on load (see sparse.parseconfig),
    # so a pattern ending in whitespace doesn't work correctly
    if pat.strip() != pat:
        raise error.Abort(
            _(
                b'leading or trailing whitespace is not allowed '
                b'in narrowspec paths'
            )
        )

    components = pat.split(b'/')
    if b'.' in components or b'..' in components:
        raise error.Abort(
            _(b'"." and ".." are not allowed in narrowspec paths')
        )

    if pat != b'' and b'' in components:
        raise error.Abort(
            _(b'empty path components are not allowed in narrowspec paths')
        )


def normalizepattern(pattern, defaultkind=b'path'):
    """Returns the normalized version of a text-format pattern.

    If the pattern has no kind, the default will be added.
    """
    kind, pat = matchmod._patsplit(pattern, defaultkind)
    return b'%s:%s' % normalizesplitpattern(kind, pat)


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
    with util.timedcm('narrowspec.validatepatterns(pats size=%d)', len(pats)):
        if not isinstance(pats, set):
            raise error.ProgrammingError(
                b'narrow patterns should be a set; got %r' % pats
            )

        for pat in pats:
            if not pat.startswith(VALID_PREFIXES):
                # Use a Mercurial exception because this can happen due to user
                # bugs (e.g. manually updating spec file).
                raise error.Abort(
                    _(b'invalid prefix on narrow pattern: %s') % pat,
                    hint=_(
                        b'narrow patterns must begin with one of '
                        b'the following: %s'
                    )
                    % b', '.join(VALID_PREFIXES),
                )


def format(includes, excludes):
    output = b''
    if includes:
        output += b'[include]\n'
        for i in sorted(includes - excludes):
            output += i + b'\n'
    if excludes:
        output += b'[exclude]\n'
        for e in sorted(excludes):
            output += e + b'\n'
    return output


def match(root, include=None, exclude=None, warn=None):
    if not include:
        # Passing empty include and empty exclude to matchmod.match()
        # gives a matcher that matches everything, so explicitly use
        # the nevermatcher.
        return matchmod.never()

    shape_matcher = shape.shard_tree_matcher(root, include, exclude, warn=warn)
    if shape_matcher is not None:
        return shape_matcher
    # Fall back to the old way of matching
    # TODO warn users?
    return matchmod.match(
        root,
        b'',
        [],
        include=include or [],
        exclude=exclude or [],
        warn=warn,
    )


def parseconfig(ui, spec):
    # maybe we should care about the profiles returned too
    includepats, excludepats, profiles = sparse.parseconfig(ui, spec, b'narrow')
    if profiles:
        raise error.Abort(
            _(
                b"including other spec files using '%include' is not"
                b" supported in narrowspec"
            )
        )

    validatepatterns(includepats)
    validatepatterns(excludepats)

    return includepats, excludepats


def load(repo):
    # Treat "narrowspec does not exist" the same as "narrowspec file exists
    # and is empty".
    spec = None
    if txnutil.mayhavepending(repo.root):
        pending_path = b"%s.pending" % FILENAME
        if repo.svfs.exists(pending_path):
            spec = repo.svfs.tryread(pending_path)
    if spec is None:
        spec = repo.svfs.tryread(FILENAME)
    return parseconfig(repo.ui, spec)


def load_store_shape(repo: RepoT) -> str | None:
    """Returns the current store shape name for `repo`.

    Used by the repo to load its own store shape."""
    shape = None
    contents = None
    if txnutil.mayhavepending(repo.root):
        pending_path = b"%s.pending" % SHAPE_FILENAME
        if repo.svfs.exists(pending_path):
            try:
                contents = repo.svfs.read(pending_path)
            except FileNotFoundError:
                return None
    if contents is None:
        try:
            contents = repo.svfs.read(SHAPE_FILENAME)
        except FileNotFoundError:
            return None

    shape = parse_shape(contents)
    return shape


def _decode_shape(name: bytes) -> str:
    """decode and valide a shape name"""
    try:
        return name.decode()
    except UnicodeDecodeError:
        msg = _(b"store-shape contains invalid UTF8")
        raise error.Abort(msg)


def parse_shape(contents: bytes) -> str:
    """Parse the contents of the file `SHAPE_FILENAME` to return the shape name.

    See the format in `write_shape`"""
    lines = contents.splitlines()
    if not lines:
        raise error.CorruptedFormat(_(b"empty store-hape file"))
    try:
        version = int(lines[0])
    except ValueError:
        raise error.CorruptedFormat(_(b"invalid store-hape version line"))
    if version != 0:
        msg = _(b"unknown store-hape version number: %d")
        raise error.CorruptedFormat(msg % version)
    if len(lines) != 2:
        msg = _(b"too many lines in store-hape: expected 2, got %d")
        raise error.CorruptedFormat(msg % len(lines))
    shape = _decode_shape(lines[1])
    return shape


def write_shape(file: BinaryIO, name):
    """Write version 0 of the contents of `SHAPE_FILENAME`.

    V0 format is experimental and subject to change.
    It is line-delimited:
        - The literal ascii byte "0", as a version number
        - The bytes of the shape name, which must be UTF8.
        - A single empty line to make it simpler to display

    A later version will include the shape's patterns and will replace the
    narrowspec.
    """
    _decode_shape(name)  # validate the name
    file.write(b"0\n%s\n" % name)


def patterns_for_shape(
    repo: RepoT,
    name: bytes,
    fingerprint: bytes | None,
) -> StoreShapePatternsT:
    """Return the (legacy) include and exclude patterns for this shape.

    `fingerprint` is the expected fingerprint to check against"""
    if shapemod_rust is None:
        raise error.ProgrammingError("called `get_shape` without Rust support")
    as_str = _decode_shape(name)

    store_shards = shapemod_rust.get_store_shards(repo.root)
    shape = store_shards.shape(as_str)
    if shape is None:
        raise error.Abort(b"shape not found on remote: '%s'" % name)
    if fingerprint is not None:
        server_fingerprint = shape.fingerprint()
        if fingerprint != server_fingerprint:
            msg = (
                b"fingerprint mismatch for shape '%s'\n"
                b"  server: '%s'\n  client: '%s'"
            )
            msg = msg % (name, fingerprint, server_fingerprint)
            raise error.Abort(msg)
    includes, excludes = shape.patterns()
    legacy_includes, legacy_excludes = to_legacy_patterns(includes, excludes)

    return legacy_includes, legacy_excludes


def save(repo, includepats, excludepats):
    repo = repo.unfiltered()

    validatepatterns(includepats)
    validatepatterns(excludepats)
    spec = format(includepats, excludepats)

    tr = repo.currenttransaction()
    if tr is None:
        m = "changing narrow spec outside of a transaction"
        raise error.ProgrammingError(m)
    else:
        # the roundtrip is sometime different
        # not taking any chance for now
        value = parseconfig(repo.ui, spec)
        reporef = weakref.ref(repo)

        def clean_pending(tr):
            r = reporef()
            if r is not None:
                r._pending_narrow_pats = None

        tr.addpostclose(b'narrow-spec', clean_pending)
        tr.addabort(b'narrow-spec', clean_pending)
        repo._pending_narrow_pats = value

        def write_spec(f):
            f.write(spec)

        tr.addfilegenerator(
            # XXX think about order at some point
            b"narrow-spec",
            (FILENAME,),
            write_spec,
            location=b'store',
        )


def copytoworkingcopy(repo):
    repo = repo.unfiltered()
    tr = repo.currenttransaction()
    spec = format(*repo.narrowpats)
    if tr is None:
        m = "changing narrow spec outside of a transaction"
        raise error.ProgrammingError(m)
    else:
        reporef = weakref.ref(repo)

        def clean_pending(tr):
            r = reporef()
            if r is not None:
                r._pending_narrow_pats_dirstate = None

        tr.addpostclose(b'narrow-spec-dirstate', clean_pending)
        tr.addabort(b'narrow-spec-dirstate', clean_pending)
        repo._pending_narrow_pats_dirstate = repo.narrowpats

        def write_spec(f):
            f.write(spec)

        tr.addfilegenerator(
            # XXX think about order at some point
            b"narrow-spec-dirstate",
            (DIRSTATE_FILENAME,),
            write_spec,
            location=b'plain',
        )


def restrictpatterns(req_includes, req_excludes, repo_includes, repo_excludes):
    r"""Restricts the patterns according to repo settings,
    results in a logical AND operation

    :param req_includes: requested includes
    :param req_excludes: requested excludes
    :param repo_includes: repo includes
    :param repo_excludes: repo excludes
    :return: include patterns, exclude patterns, and invalid include patterns.
    """
    res_excludes = set(req_excludes)
    res_excludes.update(repo_excludes)
    invalid_includes = []
    if not req_includes:
        res_includes = set(repo_includes)
    elif b'path:.' not in repo_includes:
        res_includes = []
        for req_include in req_includes:
            req_include = util.expandpath(util.normpath(req_include))
            if req_include in repo_includes:
                res_includes.append(req_include)
                continue
            valid = False
            for repo_include in repo_includes:
                if req_include.startswith(repo_include + b'/'):
                    valid = True
                    res_includes.append(req_include)
                    break
            if not valid:
                invalid_includes.append(req_include)
        if len(res_includes) == 0:
            res_excludes = {b'path:.'}
        else:
            res_includes = set(res_includes)
    else:
        res_includes = set(req_includes)
    return res_includes, res_excludes, invalid_includes


def checkworkingcopynarrowspec(repo):
    # Avoid infinite recursion when updating the working copy
    if getattr(repo, '_updatingnarrowspec', False):
        return
    storespec = repo.narrowpats
    wcspec = repo._pending_narrow_pats_dirstate
    if wcspec is None:
        oldspec = repo.vfs.tryread(DIRSTATE_FILENAME)
        wcspec = parseconfig(repo.ui, oldspec)
    if wcspec != storespec:
        raise error.StateError(
            _(b"working copy's narrowspec is stale"),
            hint=_(b"run 'hg tracked --update-working-copy'"),
        )


def to_legacy_patterns(
    includes: Iterable[bytes],
    excludes: Iterable[bytes],
) -> StoreShapePatternsT:
    """Convert plain paths-based patterns (from a shape) to the legacy
    narrowspec format"""
    # TODO remove this once we move all of the verification, fingerprinting
    # and other code to the new system.
    legacy_includes = {b"path:%s" % p if p else b'path:.' for p in includes}
    legacy_excludes = {b"path:%s" % p if p else b'path:.' for p in excludes}

    validatepatterns(legacy_includes)
    validatepatterns(legacy_excludes)
    return legacy_includes, legacy_excludes
