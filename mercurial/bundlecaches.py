# bundlecaches.py - utility to deal with pre-computed bundle for servers
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.

from __future__ import annotations

import collections
import re
import typing

from typing import (
    cast,
)

from .i18n import _

from .thirdparty import attr

# Force pytype to use the non-vendored package
if typing.TYPE_CHECKING:
    # noinspection PyPackageRequirements
    import attr

from . import (
    error,
    requirements as requirementsmod,
    sslutil,
    url as urlmod,
    util,
)
from .utils import stringutil

urlreq = util.urlreq

CB_MANIFEST_FILE = b'clonebundles.manifest'
CLONEBUNDLESCHEME = b"peer-bundle-cache://"


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


SUPPORTED_CLONEBUNDLE_SCHEMES = [
    b"http://",
    b"https://",
    b"largefile://",
    CLONEBUNDLESCHEME,
]


@attr.s
class bundlespec:
    compression = attr.ib()
    wirecompression = attr.ib()
    version = attr.ib()
    wireversion = attr.ib()
    # parameters explicitly overwritten by the config or the specification
    _explicit_params = attr.ib()
    # default parameter for the version
    #
    # Keeping it separated is useful to check what was actually overwritten.
    _default_opts = attr.ib()

    @property
    def params(self):
        return collections.ChainMap(self._explicit_params, self._default_opts)

    @property
    def contentopts(self):
        # kept for Backward Compatibility concerns.
        return self.params

    def set_param(self, key, value, overwrite=True):
        """Set a bundle parameter value.

        Will only overwrite if overwrite is true"""
        if overwrite or key not in self._explicit_params:
            self._explicit_params[key] = value

    def as_spec(self):
        parts = [b"%s-%s" % (self.compression, self.version)]
        for param, raw_value in sorted(self._explicit_params.items()):
            if isinstance(raw_value, bool):
                value = b"yes" if raw_value else b"no"
            else:
                value = raw_value
            parts.append(b'%s=%s' % (param, value))
        return b';'.join(parts)


# Maps bundle version human names to changegroup versions.
_bundlespeccgversions = {
    b'v1': b'01',
    b'v2': b'02',
    b'v3': b'03',
    b'packed1': b's1',
    b'bundle2': b'02',  # legacy
}

# Maps bundle version with content opts to choose which part to bundle
_bundlespeccontentopts: dict[bytes, dict[bytes, bool | bytes]] = {
    b'v1': {
        b'changegroup': True,
        b'cg.version': b'01',
        b'obsolescence': False,
        b'phases': False,
        b'tagsfnodescache': False,
        b'revbranchcache': False,
    },
    b'v2': {
        b'changegroup': True,
        b'cg.version': b'02',
        b'obsolescence': False,
        b'phases': False,
        b'tagsfnodescache': True,
        b'revbranchcache': True,
    },
    b'v3': {
        b'changegroup': True,
        b'cg.version': b'03',
        b'obsolescence': False,
        b'phases': True,
        b'tagsfnodescache': True,
        b'revbranchcache': True,
    },
    b'streamv2': {
        b'changegroup': False,
        b'cg.version': b'02',
        b'obsolescence': False,
        b'phases': False,
        b"stream": b"v2",
        b'tagsfnodescache': False,
        b'revbranchcache': False,
    },
    b'streamv3-exp': {
        b'changegroup': False,
        b'cg.version': b'03',
        b'obsolescence': False,
        b'phases': False,
        b"stream": b"v3-exp",
        b'tagsfnodescache': False,
        b'revbranchcache': False,
    },
    b'packed1': {
        b'cg.version': b's1',
    },
    b'bundle2': {  # legacy
        b'cg.version': b'02',
    },
}
_bundlespeccontentopts[b'bundle2'] = _bundlespeccontentopts[b'v2']

# Compression engines allowed in version 1. THIS SHOULD NEVER CHANGE.
_bundlespecv1compengines = {b'gzip', b'bzip2', b'none'}


def param_bool(key, value):
    """make a boolean out of a parameter value"""
    b = stringutil.parsebool(value)
    if b is None:
        msg = _(b"parameter %s should be a boolean ('%s')")
        msg %= (key, value)
        raise error.InvalidBundleSpecification(msg)
    return b


# mapping of known parameter name need their value processed
bundle_spec_param_processing = {
    b"obsolescence": param_bool,
    b"obsolescence-mandatory": param_bool,
    b"phases": param_bool,
    b"changegroup": param_bool,
    b"tagsfnodescache": param_bool,
    b"revbranchcache": param_bool,
}


def _parseparams(s):
    """parse bundlespec parameter section

    input: "comp-version;params" string

    return: (spec; {param_key: param_value})
    """
    if b';' not in s:
        return s, {}

    params = {}
    version, paramstr = s.split(b';', 1)

    err = _(b'invalid bundle specification: missing "=" in parameter: %s')
    for p in paramstr.split(b';'):
        if b'=' not in p:
            msg = err % p
            raise error.InvalidBundleSpecification(msg)

        key, value = p.split(b'=', 1)
        key = urlreq.unquote(key)
        value = urlreq.unquote(value)
        process = bundle_spec_param_processing.get(key)
        if process is not None:
            value = process(key, value)
        params[key] = value

    return version, params


def parsebundlespec(repo, spec, strict=True):
    """Parse a bundle string specification into parts.

    Bundle specifications denote a well-defined bundle/exchange format.
    The content of a given specification should not change over time in
    order to ensure that bundles produced by a newer version of Mercurial are
    readable from an older version.

    The string currently has the form:

       <compression>-<type>[;<parameter0>[;<parameter1>]]

    Where <compression> is one of the supported compression formats
    and <type> is (currently) a version string. A ";" can follow the type and
    all text afterwards is interpreted as URI encoded, ";" delimited key=value
    pairs.

    If ``strict`` is True (the default) <compression> is required. Otherwise,
    it is optional.

    Returns a bundlespec object of (compression, version, parameters).
    Compression will be ``None`` if not in strict mode and a compression isn't
    defined.

    An ``InvalidBundleSpecification`` is raised when the specification is
    not syntactically well formed.

    An ``UnsupportedBundleSpecification`` is raised when the compression or
    bundle type/version is not recognized.

    Note: this function will likely eventually return a more complex data
    structure, including bundle2 part information.
    """
    if strict and b'-' not in spec:
        raise error.InvalidBundleSpecification(
            _(
                b'invalid bundle specification; '
                b'must be prefixed with compression: %s'
            )
            % spec
        )

    pre_args = spec.split(b';', 1)[0]
    if b'-' in pre_args:
        compression, version = spec.split(b'-', 1)

        if compression not in util.compengines.supportedbundlenames:
            raise error.UnsupportedBundleSpecification(
                _(b'%s compression is not supported') % compression
            )

        version, params = _parseparams(version)

        if version not in _bundlespeccontentopts:
            raise error.UnsupportedBundleSpecification(
                _(b'%s is not a recognized bundle version') % version
            )
    else:
        # Value could be just the compression or just the version, in which
        # case some defaults are assumed (but only when not in strict mode).
        assert not strict

        spec, params = _parseparams(spec)

        if spec in util.compengines.supportedbundlenames:
            compression = spec
            version = b'v1'
            # Generaldelta repos require v2.
            if requirementsmod.GENERALDELTA_REQUIREMENT in repo.requirements:
                version = b'v2'
            elif requirementsmod.REVLOGV2_REQUIREMENT in repo.requirements:
                version = b'v2'
            # Modern compression engines require v2.
            if compression not in _bundlespecv1compengines:
                version = b'v2'
        elif spec in _bundlespeccontentopts:
            if spec == b'packed1':
                compression = b'none'
            else:
                compression = b'bzip2'
            version = spec
        else:
            raise error.UnsupportedBundleSpecification(
                _(b'%s is not a recognized bundle specification') % spec
            )

    # Bundle version 1 only supports a known set of compression engines.
    if version == b'v1' and compression not in _bundlespecv1compengines:
        raise error.UnsupportedBundleSpecification(
            _(b'compression engine %s is not supported on v1 bundles')
            % compression
        )

    # The specification for stream bundles can optionally declare the data formats
    # required to apply it. If we see this metadata, compare against what the
    # repo supports and error if the bundle isn't compatible.
    if b'requirements' in params:
        requirements = set(cast(bytes, params[b'requirements']).split(b','))
        relevant_reqs = (
            requirements - requirementsmod.STREAM_IGNORABLE_REQUIREMENTS
        )
        # avoid cycle (not great for pytype)
        from . import localrepo

        supported_req = localrepo.gathersupportedrequirements(repo.ui)
        missing_reqs = relevant_reqs - supported_req
        if missing_reqs:
            raise error.UnsupportedBundleSpecification(
                _(b'missing support for repository features: %s')
                % b', '.join(sorted(missing_reqs))
            )

    # Compute contentopts based on the version
    if b"stream" in params:
        # This case is fishy as this mostly derails the version selection
        # mechanism. `stream` bundles are quite specific and used differently
        # as "normal" bundles.
        #
        # (we should probably define a cleaner way to do this and raise a
        # warning when the old way is encountered)
        if params[b"stream"] == b"v2":
            version = b"streamv2"
        if params[b"stream"] == b"v3-exp":
            version = b"streamv3-exp"
    contentopts = _bundlespeccontentopts.get(version, {}).copy()
    if version == b"streamv2" or version == b"streamv3-exp":
        # streamv2 have been reported as "v2" for a while.
        version = b"v2"

    engine = util.compengines.forbundlename(compression)
    compression, wirecompression = engine.bundletype()
    wireversion = _bundlespeccontentopts[version][b'cg.version']

    return bundlespec(
        compression, wirecompression, version, wireversion, params, contentopts
    )


def parseclonebundlesmanifest(repo, s):
    """Parses the raw text of a clone bundles manifest.

    Returns a list of dicts. The dicts have a ``URL`` key corresponding
    to the URL and other keys are the attributes for the entry.
    """
    m = []
    for line in s.splitlines():
        fields = line.split()
        if not fields:
            continue
        attrs = {b'URL': fields[0]}
        for rawattr in fields[1:]:
            key, value = rawattr.split(b'=', 1)
            key = util.urlreq.unquote(key)
            value = util.urlreq.unquote(value)
            attrs[key] = value

            # Parse BUNDLESPEC into components. This makes client-side
            # preferences easier to specify since you can prefer a single
            # component of the BUNDLESPEC.
            if key == b'BUNDLESPEC':
                try:
                    bundlespec = parsebundlespec(repo, value)
                    attrs[b'COMPRESSION'] = bundlespec.compression
                    attrs[b'VERSION'] = bundlespec.version
                except error.InvalidBundleSpecification:
                    pass
                except error.UnsupportedBundleSpecification:
                    pass

        m.append(attrs)

    return m


def isstreamclonespec(bundlespec):
    # Stream clone v1
    if bundlespec.wirecompression == b'UN' and bundlespec.wireversion == b's1':
        return True

    # Stream clone v2
    if (
        bundlespec.wirecompression == b'UN'
        and bundlespec.wireversion == b'02'
        and bundlespec.contentopts.get(b'stream', None) in (b"v2", b"v3-exp")
    ):
        return True

    return False


digest_regex = re.compile(b'^[a-z0-9]+:[0-9a-f]+(,[a-z0-9]+:[0-9a-f]+)*$')


def filterclonebundleentries(
    repo, entries, streamclonerequested=False, pullbundles=False
):
    """Remove incompatible clone bundle manifest entries.

    Accepts a list of entries parsed with ``parseclonebundlesmanifest``
    and returns a new list consisting of only the entries that this client
    should be able to apply.

    There is no guarantee we'll be able to apply all returned entries because
    the metadata we use to filter on may be missing or wrong.
    """
    newentries = []
    for entry in entries:
        url = entry.get(b'URL')
        if not pullbundles and not any(
            [url.startswith(scheme) for scheme in SUPPORTED_CLONEBUNDLE_SCHEMES]
        ):
            repo.ui.debug(
                b'filtering %s because not a supported clonebundle scheme\n'
                % url
            )
            continue

        spec = entry.get(b'BUNDLESPEC')
        if spec:
            try:
                bundlespec = parsebundlespec(repo, spec, strict=True)

                # If a stream clone was requested, filter out non-streamclone
                # entries.
                if streamclonerequested and not isstreamclonespec(bundlespec):
                    repo.ui.debug(
                        b'filtering %s because not a stream clone\n' % url
                    )
                    continue

            except error.InvalidBundleSpecification as e:
                repo.ui.debug(stringutil.forcebytestr(e) + b'\n')
                continue
            except error.UnsupportedBundleSpecification as e:
                repo.ui.debug(
                    b'filtering %s because unsupported bundle '
                    b'spec: %s\n' % (url, stringutil.forcebytestr(e))
                )
                continue
        # If we don't have a spec and requested a stream clone, we don't know
        # what the entry is so don't attempt to apply it.
        elif streamclonerequested:
            repo.ui.debug(
                b'filtering %s because cannot determine if a stream '
                b'clone bundle\n' % url
            )
            continue

        if b'REQUIRESNI' in entry and not sslutil.hassni:
            repo.ui.debug(b'filtering %s because SNI not supported\n' % url)
            continue

        if b'REQUIREDRAM' in entry:
            try:
                requiredram = util.sizetoint(entry[b'REQUIREDRAM'])
            except error.ParseError:
                repo.ui.debug(
                    b'filtering %s due to a bad REQUIREDRAM attribute\n' % url
                )
                continue
            actualram = repo.ui.estimatememory()
            if actualram is not None and actualram * 0.66 < requiredram:
                repo.ui.debug(
                    b'filtering %s as it needs more than 2/3 of system memory\n'
                    % url
                )
                continue

        if b'DIGEST' in entry:
            if not digest_regex.match(entry[b'DIGEST']):
                repo.ui.debug(
                    b'filtering %s due to a bad DIGEST attribute\n' % url
                )
                continue
            supported = 0
            seen = {}
            for digest_entry in entry[b'DIGEST'].split(b','):
                algo, digest = digest_entry.split(b':')
                if algo not in seen:
                    seen[algo] = digest
                elif seen[algo] != digest:
                    repo.ui.debug(
                        b'filtering %s due to conflicting %s digests\n'
                        % (url, algo)
                    )
                    supported = 0
                    break
                digester = urlmod.digesthandler.digest_algorithms.get(algo)
                if digester is None:
                    continue
                if len(digest) != digester().digest_size * 2:
                    repo.ui.debug(
                        b'filtering %s due to a bad %s digest\n' % (url, algo)
                    )
                    supported = 0
                    break
                supported += 1
            else:
                if supported == 0:
                    repo.ui.debug(
                        b'filtering %s due to lack of supported digest\n' % url
                    )
            if supported == 0:
                continue

        newentries.append(entry)

    return newentries


class clonebundleentry:
    """Represents an item in a clone bundles manifest.

    This rich class is needed to support sorting since sorted() in Python 3
    doesn't support ``cmp`` and our comparison is complex enough that ``key=``
    won't work.
    """

    def __init__(self, value, prefers):
        self.value = value
        self.prefers = prefers

    def _cmp(self, other):
        for prefkey, prefvalue in self.prefers:
            avalue = self.value.get(prefkey)
            bvalue = other.value.get(prefkey)

            # Special case for b missing attribute and a matches exactly.
            if avalue is not None and bvalue is None and avalue == prefvalue:
                return -1

            # Special case for a missing attribute and b matches exactly.
            if bvalue is not None and avalue is None and bvalue == prefvalue:
                return 1

            # We can't compare unless attribute present on both.
            if avalue is None or bvalue is None:
                continue

            # Same values should fall back to next attribute.
            if avalue == bvalue:
                continue

            # Exact matches come first.
            if avalue == prefvalue:
                return -1
            if bvalue == prefvalue:
                return 1

            # Fall back to next attribute.
            continue

        # If we got here we couldn't sort by attributes and prefers. Fall
        # back to index order.
        return 0

    def __lt__(self, other):
        return self._cmp(other) < 0

    def __gt__(self, other):
        return self._cmp(other) > 0

    def __eq__(self, other):
        return self._cmp(other) == 0

    def __le__(self, other):
        return self._cmp(other) <= 0

    def __ge__(self, other):
        return self._cmp(other) >= 0

    def __ne__(self, other):
        return self._cmp(other) != 0


def sortclonebundleentries(ui, entries):
    prefers = ui.configlist(b'ui', b'clonebundleprefers')
    if not prefers:
        return list(entries)

    def _split(p):
        if b'=' not in p:
            hint = _(b"each comma separated item should be key=value pairs")
            raise error.Abort(
                _(b"invalid ui.clonebundleprefers item: %s") % p, hint=hint
            )
        return p.split(b'=', 1)

    prefers = [_split(p) for p in prefers]

    items = sorted(clonebundleentry(v, prefers) for v in entries)
    return [i.value for i in items]
