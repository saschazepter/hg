# narrowspec.py - methods for working with a narrow view of a repository
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import itertools
import typing
import weakref

from .i18n import _
from .thirdparty import attr
from . import (
    error,
    match as matchmod,
    sparse,
    txnutil,
    util,
)

if typing.TYPE_CHECKING:
    import attr

# The file in .hg/store/ that indicates which paths exit in the store
FILENAME = b'narrowspec'
# The file in .hg/ that indicates which paths exit in the dirstate
DIRSTATE_FILENAME = b'narrowspec.dirstate'

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


@attr.s(hash=True)
class ShardTreeNode:
    """A node within a tree of narrow patterns.

    It is used to create a normalized representation of potentially nested
    include and exclude patterns to uniquely identify semantically equivalent
    rules, as well as generating an associated file matcher."""

    path = attr.ib(type=bytes, eq=True)
    """The path (rooted by `b""`) that this node concerns"""

    included = attr.ib(type=bool, default=True, eq=True)
    """Whether this path is included or excluded"""

    children = attr.ib(type=set, default=attr.Factory(set), eq=False)
    """The set of child nodes (describing rules for sub-paths)"""

    @staticmethod
    def from_patterns(
        includes: set[bytes], excludes: set[bytes]
    ) -> ShardTreeNode:
        """Transform includes and excludes into a compact tree of those rules."""
        # Need to include everything by default
        root_path = [b""]
        if b"" in includes or b"." in includes or not includes:
            # `clone` passes `path:.` by default which
            # is supposed to include everything. This is the wrong API IMO
            # and is a serialization detail hitting internal logic (empty
            # paths are annoying in text formats).
            # XXX find out how much we need to preserve this behavior
            includes.discard(b".")
            includes.add(b"")
            root_path = []

        # Excludes take precedence over includes (it happens that users include
        # and exclude the same paths, directly or through `--import-rules`)
        includes -= excludes

        nodes = (
            ShardTreeNode(p, p in includes)
            for p in itertools.chain(root_path, includes, excludes)
        )
        stack = []
        for node in sorted(nodes, key=lambda x: x._zero_path):
            while stack and not node._sub_path_of(stack[-1]):
                stack.pop()
            if stack:
                if stack[-1].included != node.included:
                    stack[-1].children.add(node)
            stack.append(node)
        root = stack[0]
        return root

    def matcher(self, root_path: bytes):
        """Build the matcher corresponding to this tree."""
        if not self.path:
            # We're the root node
            if self.included:
                top_matcher = matchmod.alwaysmatcher()
            else:
                top_matcher = matchmod.nevermatcher()
        else:
            top_matcher = matchmod.match(
                root_path,
                b'',
                [b'path:%s' % self.path],
            )
        if not self.children:
            return top_matcher

        subs = [n.matcher(root_path) for n in self.children]
        if len(subs) == 1:
            sub_matcher = subs[0]
        else:
            # TODO figure out a way of creating a single matcher with multiple
            # paths instead.
            sub_matcher = matchmod.unionmatcher(subs)

        if not self.path and not self.included:
            return sub_matcher
        return matchmod.differencematcher(top_matcher, sub_matcher)

    @util.propertycache
    def _zero_path(self) -> bytes:
        """A version of the `path` with `\0` instead of `/`.

        This ensures that the path and its subpath get sorted
        next to each other."""
        path = self.path
        assert b'\0' not in path
        assert not path.startswith(b'/')
        assert not path.endswith(b'/')
        if not path:
            path = b'/'
        else:
            path = b'/%s/' % path
        return path.replace(b'/', b'\0')

    def _sub_path_of(self, other: ShardTreeNode) -> bytes:
        """True if `self` is a sub-path of `other`"""
        return self._zero_path.startswith(other._zero_path)

    def flat(self) -> tuple[frozenset[bytes], frozenset[bytes]]:
        """Return the tree as two flat sets of includes and excludes"""
        inc_paths: set[bytes] = set()
        exc_paths: set[bytes] = set()
        if self.included:
            inc_paths.add(self.path)
        else:
            exc_paths.add(self.path)
        for c in self.children:
            inc, exc = c.flat()
            inc_paths.update(inc)
            exc_paths.update(exc)
        return frozenset(inc_paths), frozenset(exc_paths)


def _shard_tree_matcher(root, include, exclude):
    if exclude is None:
        exclude = set()

    # matchmod.match only works for simple cases. Nested excludes/includes
    # don't work and we need them for shapes, but only for `path:` patterns.
    #
    # `rootfilesin:` does not use the new logic yet because they make the code
    # more complex and are not needed by shapes. Maybe we'll end up
    # implementing it.
    includes_are_paths = all(p.startswith(b"path:") for p in include)
    excludes_are_paths = all(p.startswith(b"path:") for p in exclude)
    if includes_are_paths and excludes_are_paths:
        include = {p.removeprefix(b"path:") for p in include}
        exclude = {p.removeprefix(b"path:") for p in exclude}
        pattern_tree: ShardTreeNode = ShardTreeNode.from_patterns(
            include, exclude
        )
        return pattern_tree.matcher(root)


def match(root, include=None, exclude=None):
    if not include:
        # Passing empty include and empty exclude to matchmod.match()
        # gives a matcher that matches everything, so explicitly use
        # the nevermatcher.
        return matchmod.never()

    shape_matcher = _shard_tree_matcher(root, include, exclude)
    if shape_matcher is not None:
        return shape_matcher
    # Fall back to the old way of matching
    # TODO warn users?
    return matchmod.match(
        root, b'', [], include=include or [], exclude=exclude or []
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
            spec = repo.svfs.tryread(FILENAME)
    if spec is None:
        spec = repo.svfs.tryread(FILENAME)
    return parseconfig(repo.ui, spec)


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
