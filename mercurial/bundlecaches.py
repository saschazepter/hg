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
    from .interfaces.types import RepoT

from . import (
    error,
    requirements as requirementsmod,
    sslutil,
    url as urlmod,
    util,
)
from .exchanges import bundle_cache
from .repo import (
    requirements as repo_req,
)
from .utils import stringutil

urlreq = util.urlreq

CB_MANIFEST_FILE = bundle_cache.CB_MANIFEST_FILE
CLONEBUNDLESCHEME = b"peer-bundle-cache://"

SUPPORTED_CLONEBUNDLE_SCHEMES = [
    b"http://",
    b"https://",
    b"largefile://",
    CLONEBUNDLESCHEME,
]

# Bundlespec parameters a client must understand to safely use the bundle.
MANDATORY_BUNDLE_SPEC_PARAMS: set[bytes] = {
    b"requirements",
    b"store-fingerprint",
    b"stream",
}

# Bundlespec params copied over to the manifest line parameters for easier
# filtering. They get uppercased on the way to indicate they are reserved for
# use by Mercurial, which is different from the uppercase that indicates
# mandatory bundlespec params.
#
# TODO: stop forwarding these params, it's confusing to have uppercase indicate
# two different things for the same params
FORWARDED_SPEC_PARAMS = [
    b"store-fingerprint",
    b"shard-id",
    b"bundle-group-id",
    b"bundle-group-top-level",
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
            parts.append(b'%s=%s' % (canonical_param_name(param), value))
        return b';'.join(parts)


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


# Every bundlespec parameter this version of Mercurial knows about.
#
# Mercurial rejects bundles with mandatory (uppercase) parameters that aren't
# in this set.
#
# Extensions that extend the parameter set must extend KNOWN_BUNDLE_SPEC_PARAMS
# to do so.
#
# TODO: the value of the parameter might be important in some case, we so need
# to extend this logic with a way to validate the mandatory parameter value.
KNOWN_BUNDLE_SPEC_PARAMS: set[bytes] = set().union(
    *_bundlespeccontentopts.values(),
    bundle_spec_param_processing,
    MANDATORY_BUNDLE_SPEC_PARAMS,
    FORWARDED_SPEC_PARAMS,
    {b"requirements"},
)


def canonical_param_name(key: bytes) -> bytes:
    """The name to use when writing this parameter into a bundlespec.

    All caps for mandatory parameters, lowercase for advisory parameters.
    """
    if key in MANDATORY_BUNDLE_SPEC_PARAMS:
        return key.upper()
    return key.lower()


# TODO consolidate the different functions parsing manifest lines and
# bundlespecs
def _partition_param(param: bytes) -> tuple[bytes, bytes, bytes]:
    """Split a bundlespec parameter into its name, separator and value.

    The separator is usually a literal "=", but `_formatrequirementsparams`
    escapes it along with the name, so it can also be "%3D" (never "%3d").

    >>> _partition_param(b'stream=v2')
    (b'stream', b'=', b'v2')
    >>> _partition_param(b'requirements%3Dstore%2Cfncache')
    (b'requirements', b'%3D', b'store%2Cfncache')
    >>> _partition_param(b'requirements%3Da=b=c')
    (b'requirements', b'%3D', b'a=b=c')
    """
    name, sep, value = param.partition(b'=')
    esc_name, esc_sep, esc_value = param.partition(urlreq.quote(b'='))
    # Pick the separator that occurred first
    if len(esc_name) < len(name):
        return esc_name, esc_sep, esc_value
    return name, sep, value


def canonicalize_spec_params(spec: bytes) -> bytes:
    """Uppercase the mandatory parameter names of a bundlespec.

    >>> canonicalize_spec_params(b'none-v2;stream=v2;phases=yes')
    b'none-v2;STREAM=v2;phases=yes'
    >>> canonicalize_spec_params(b'none-packed1;requirements%3Dstore%2Cfncache')
    b'none-packed1;REQUIREMENTS%3Dstore%2Cfncache'
    >>> canonicalize_spec_params(b'none-v2')
    b'none-v2'
    """
    head, sep, paramstr = spec.partition(b';')
    params = []
    for param in paramstr.split(b';'):
        raw_name, param_sep, value = _partition_param(param)
        name = urlreq.unquote(raw_name)
        if name in MANDATORY_BUNDLE_SPEC_PARAMS:
            raw_name = urlreq.quote(name.upper())
        params.append(raw_name + param_sep + value)

    return head + sep + b';'.join(params)


def _parseparams(s):
    """parse bundlespec parameter section

    input: "comp-version;params" string

    Parameter names are normalized to lowercase so that from this point on only
    lowercase needs to be handled.

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
        if not key.isupper() and not key.islower():
            msg = _(
                b'invalid bundle specification: parameter name must be either '
                b'all uppercase (mandatory) or all lowercase (advisory): %s'
            )
            raise error.InvalidBundleSpecification(msg % key)
        is_mandatory = key.isupper()
        key = key.lower()
        if is_mandatory and key not in KNOWN_BUNDLE_SPEC_PARAMS:
            msg = _(b'unsupported mandatory bundle specification parameter: %s')
            raise error.UnsupportedBundleSpecification(msg % key)
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

        if (
            compression not in util.compengines.supportedbundlenames
            or not util.compengines[
                util.compengines._bundlenames[compression]
            ].available()
        ):
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
        supported_req = repo_req.gather_supported_requirements(repo.ui)
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
        attrs = parse_clonebundle_manifest_line(repo, line)
        if attrs is not None:
            m.append(attrs)
    return m


# Mandatory params that old clients unaware of mandatory bundlespec params
# already act on under their lowercase names.
#
# `downgrade_manifest_lines` consults this when serving a client that didn't
# pass the `mandatory_params` arg. Params in this set are understood by these
# old clients, so they are rewritten in lowercase for the client to read. Any
# other uppercase param means the client cannot use the entry at all, so the
# whole line is dropped on its behalf.
LEGACY_CLIENT_MANDATORY_PARAMS: set[bytes] = {
    b"requirements",
    b"store-fingerprint",
    b"stream",
}


def _downgrade_bundlespec(spec: bytes) -> bytes | None:
    """Rewrite a bundlespec for a client unaware of mandatory parameters.

    Returns None if the client cannot handle it and the entry must be dropped.

    >>> _downgrade_bundlespec(b'none-v2;STREAM=v2;phases=yes')
    b'none-v2;stream=v2;phases=yes'
    >>> _downgrade_bundlespec(b'none-v2;STREAM=v2;SHARD-ID=ab12')
    """
    head, sep, paramstr = spec.partition(b';')
    params = []
    for param in paramstr.split(b';'):
        key, param_sep, value = _partition_param(param)
        name = urlreq.unquote(key)
        is_mandatory = name.isupper()
        if is_mandatory and name.lower() not in LEGACY_CLIENT_MANDATORY_PARAMS:
            return None
        params.append(urlreq.quote(name.lower()) + param_sep + value)

    return head + sep + b';'.join(params)


def downgrade_manifest_lines(lines: list[bytes]) -> list[bytes]:
    """Rewrite manifest lines for a client unaware of mandatory parameters.

    Leaves all lowercase (advisory) params unchanged. For uppercase (mandatory)
    params, if it is a param that old clients already act on under its lowercase
    name, lowercase it for the client. Otherwise, drop the entire entry.

    >>> downgrade_manifest_lines([
    ...     b'http://a BUNDLESPEC=none-v2;STREAM=v2\\n',
    ...     b'http://b BUNDLESPEC=none-v2;SHARD-ID=ab\\n',
    ... ])
    [b'http://a BUNDLESPEC=none-v2;stream=v2\\n']
    """
    new_lines = []
    for line in lines:
        fields = []
        for field in line.split():
            key, eq, value = field.partition(b'=')
            if urlreq.unquote(key) == b'BUNDLESPEC':
                spec = _downgrade_bundlespec(value)
                if spec is None:
                    break
                field = key + eq + spec
            fields.append(field)
        else:
            new_lines.append(b' '.join(fields) + b'\n')
    return new_lines


def parse_clonebundle_manifest_line(
    repo: RepoT, line: bytes
) -> dict[bytes, bytes] | None:
    fields = line.split()
    if not fields:
        return

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
                raw_dc = bundlespec.params.get(b"delta-compression")
                if raw_dc is not None:
                    attrs[b'DELTA-COMPRESSION'] = raw_dc.split(b',')
                attrs[b'VERSION'] = bundlespec.version
                for param in FORWARDED_SPEC_PARAMS:
                    if value := bundlespec.params.get(param):
                        attrs[param.upper()] = value
            except error.InvalidBundleSpecification:
                pass
            except error.UnsupportedBundleSpecification:
                pass
    return attrs


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

if typing.TYPE_CHECKING:
    EntryT = dict[bytes, typing.Any]

NO_GRP_MSG = b"filtering %s because it has shard-id without bundle-group-id\n"


def filterclonebundleentries(
    repo,
    entries: list[EntryT],
    streamclonerequested=False,
    pullbundles=False,
    store_fingerprints: list[bytes] | None = None,
    shards_sets: list[set[bytes]] | None = None,
) -> list[EntryT]:
    """Remove incompatible clone bundle manifest entries.

    Accepts a list of entries parsed with ``parseclonebundlesmanifest``
    and returns a new list consisting of only the entries that this client
    should be able to apply.

    There is no guarantee we'll be able to apply all returned entries because
    the metadata we use to filter on may be missing or wrong.
    """

    newentries: list[EntryT] = []
    # gather the set of shards available for each group.
    shards_groups = collections.defaultdict(set)
    for entry in entries:
        url = entry.get(b'URL')
        if url is None:
            repo.ui.debug(b'filtering entry with no url\n')
            continue
        if not pullbundles and not any(
            url.startswith(scheme) for scheme in SUPPORTED_CLONEBUNDLE_SCHEMES
        ):
            repo.ui.debug(
                b'filtering %s because not a supported clonebundle scheme\n'
                % url
            )
            continue

        supported = util.compengines.supported_wire_delta_compression()
        unknown_compression = None
        for c in entry.get(b'DELTA-COMPRESSION', []):
            if c not in supported:
                unknown_compression = c
                break
        if unknown_compression is not None:
            msg = b'filtering %s because delta-compression is not supported: %s'
            repo.ui.debug(msg % (url, unknown_compression))
            continue

        entry_store_fp = entry.get(b"STORE-FINGERPRINT")
        # bundle with shard id need to be filtered later, when we know which
        # group id have the complete set of shards we needs.
        has_shard_id = b"SHARD-ID" in entry
        if store_fingerprints is None and has_shard_id:
            # XXX strictly speaking, we could use sharded bundle for a full
            # clone, but this isn't something we do for now.
            msg = b'filtering %s because it is sharded bundle\n'
            msg %= url
            repo.ui.debug(msg)
            continue
        elif store_fingerprints is None and entry_store_fp is None:
            pass  # expectation match, we can continue the filtering
        elif store_fingerprints is None and entry_store_fp is not None:
            msg = b'filtering %s because it uses a store-shape\n'
            msg %= url
            repo.ui.debug(msg)
            continue
        elif (
            store_fingerprints is not None
            and entry_store_fp is None
            and not has_shard_id
        ):
            msg = b'filtering %s because it does not use store-shape\n'
            msg %= url
            repo.ui.debug(msg)
            continue
        elif (not has_shard_id) and entry_store_fp not in store_fingerprints:
            msg = (
                b'filtering %s because its store-shape is not the requested '
                b'one; %s not in (%s)\n'
            )
            msg %= (url, entry_store_fp, b', '.join(store_fingerprints))
            repo.ui.debug(msg)
            continue

        spec = entry.get(b'BUNDLESPEC')
        if spec:
            try:
                bundlespec = parsebundlespec(repo, spec, strict=True)

                # If a stream clone was requested, filter out non-streamclone
                # entries.
                if isstreamclonespec(bundlespec):
                    if (
                        streamclonerequested is not None
                        and not streamclonerequested
                    ):
                        repo.ui.debug(
                            b'filtering %s because it is a stream clonebundle\n'
                            % url
                        )
                        continue
                elif streamclonerequested:
                    repo.ui.debug(
                        b'filtering %s because it is not a stream clonebundle\n'
                        % url
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

        # gather the set of available shard-id in each group for further
        # filtering outside of this loop
        if b"SHARD-ID" in entry:
            group_id = entry.get(b"BUNDLE-GROUP-ID")
            if group_id is None:
                url = entry.get(b'URL', b'(unknown url)')
                repo.ui.debug(NO_GRP_MSG % url)
                continue
            # XXX need proper error handling at some point
            shard_id = entry[b"SHARD-ID"]
            shards_groups[group_id].add(shard_id)
        elif b"BUNDLE-GROUP-ID" in entry:
            assert False
        newentries.append(entry)

    # find all the group that can accomodate at least one of the requested shards set
    valid_groups = {}
    for group_id, shards in shards_groups.items():
        for valid_set in shards_sets:
            if valid_set.issubset(shards):
                valid_groups[group_id] = valid_set
                break

    # only keeps sharded bundle that can build a valid sets
    final = []
    for entry in newentries:
        group_id = entry.get(b"BUNDLE-GROUP-ID")
        url = entry.get(b'URL', b'(unknown url)')
        shard_id = entry.get(b"SHARD-ID")
        if group_id is None:
            # not sharded, already filtered above
            final.append(entry)
        elif group_id not in valid_groups:
            msg = b'filtering %s because bundle group %s is missing some required shards\n'
            msg %= (url, group_id)
            repo.ui.debug(msg)
        elif shard_id not in valid_groups[group_id]:
            msg = b'filtering %s because shard %s is not requested\n'
            msg %= (url, shard_id)
            repo.ui.debug(msg)
        else:
            final.append(entry)
    return final


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


def best_clonebundles(ui, entries):
    """pick the prefered set of clone bundle to use

    That list is usually of size 1 unless sharded bundle are used.

    When sharded bundle are used, their should be a consisted set bundles from
    an atomic generation that hold all the necesssary data for the clone.
    """
    assert len(entries) > 0
    entries = sortclonebundleentries(ui, entries)
    first = entries[0]
    group_id = first.get(b"BUNDLE-GROUP-ID")
    if group_id is None:
        final = entries[:1]
    else:
        # The prefered bundle is sharded, we need to select the full group
        final = []
        top_group = None
        # But we should only select one bundle for each shard
        seen_shards = set()
        for e in entries:
            if e.get(b"BUNDLE-GROUP-ID") == group_id:
                shard_id = e[b"SHARD-ID"]
                if shard_id not in seen_shards:
                    seen_shards.add(shard_id)
                    if b"BUNDLE-GROUP-TOP-LEVEL" in e:
                        # XXX needs proper error handling as some point.
                        assert top_group is None
                        top_group = e
                    else:
                        final.append(e)
        # XXX needs proper error handling as some point.
        assert top_group is not None
        final.insert(0, top_group)
    return final


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
