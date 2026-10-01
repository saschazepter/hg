# __init__.py - narrowhg extension
#
# Copyright 2017 Google, Inc.
#
# This software may be used and distributed according to the terms of the
# GNU General Public License version 2 or any later version.
"""create clones which fetch history data for subsets of files (EXPERIMENTAL)

Only the server holds the full store: narrow clones will have the full history
of fewer files in their store.

Concepts
--------

The narrow extension introduces a number of concepts that are detailed below.

Shape (experimental)
....................

The shape is the set of paths to consider for clients of the narrow server.
It does so through the entire history, regardless the state of these
files in the heads of the repository (deleted, for example).

Fingerprint
...........

Every shape corresponds to a normalized and minimal set of included and excluded
paths in a repository's store. This normalization ensures that we can derive a
fingerprint, meaning that two shapes with the same fingerprint mean they match
the same set of paths.

Checking the fingerprint of a narrow clone can be done by running::

    $ hg admin::narrow-client --store-fingerprint

Fingerprints are displayed as ``shapeXY-<hex>``, where ``XY`` is the version
of the fingerprint computation and ``<hex>`` is the resulting hexadecimal
digest. Shards (see below) have fingerprints too, displayed as
``shardXY-<hex>``: they are computed the same way, but shards and shapes are
distinct objects, so the prefix makes it explicit which one a fingerprint
identifies.

We guarantee no stability of version ``00`` fingerprints.

Profile
.......

A profile is a preset of a shape created by server administrators. It allows
clients to select one or more of these profiles for their repo's shape. For
example, one clone can have a shape combining two profiles, with the name for
such a shape being `profile-1,profile-2`.

Shards
......

Shards are used server-side to slice the store. Each shard is defined as a set
of paths it contains: files or directories matching each path will be included
in that shard. Moreover shards are mutually exclusive, meaning that a given file
can only ever be in one shard and one shard only. When a shard's path matches a
directory, the shard contains all files in that directory's tree, except for
those matched by a more deeply nested shard.

Example
.......

Given the following store, representing all files ever known to the repository::

  .
  ├── file1
  ├── file2
  └── foo
      └── bar
          ├── baz
          │   ├── file1
          │   └── file2
          └── confidential
              ├── confidential-file1
              └── confidential-file2

One could define the following shards::

  * ``foo``, that includes ``foo``
  * ``foo.confidential``, that includes ``foo/bar/confidential``

This would mean that shard ``foo`` contains::

    * ``foo/bar/baz/file1``
    * ``foo/bar/baz/file2``

And shard ``foo.confidential`` contains::

    * ``foo/bar/confidential/confidential-file1``
    * ``foo/bar/confidential/confidential-file2``

In this example, ``file1`` and ``file2`` are not contained in any explicitly
defined shard. As a result, they are contained by the implicit ``base`` shard.

It is important to note that adding a new shard (e.g. that includes `file1` and
``file2``) would remove its paths from any shard that previously contained them
(in this case, only ``base``).

Server-side, shards are used to define profiles, which are sets of shards. Each
profile defines the shards it includes, hence excluding the contents of all
other shards.

In our above example, we could define a ``foo.full`` profile that includes both
the ``foo`` and ``foo.confidential`` shards, giving us a profile with the full
``foo`` store subtree. Note that shards and profiles share the same namespace,
so this profile could not also be named ``foo``.

To simplify the creation of profiles, a profile can include other profiles in
addition to shards: another profile could include ``foo.full`` along with other
shards or profiles.

Only *public* profiles can be used on their own, private profiles are only
building blocks for other profiles.

Note that the set of paths in the current working copy may only be a subset of
the the store. In our example, we can imagine that
``foo/bar/confidential-module`` has been split into the files in
``foo/bar/confidential`` and removed from the working copy.

In addition to the implicit ``base`` shard, there is also the implicit
``.hg-files`` shard, which contains special paths used by Mercurial::

    * ``.hgignore``
    * ``.hgtags``
    * ``.hgsub``
    * ``.hgsubstate``

This shard will be automatically included in every ``Shape`` to make sure
Mercurial has the data it needs to operate on each revision.

Finally, there is the implicit public ``full`` profile, which includes every
shard.

Narrowspec (legacy)
...................

Note: the narrowspec in its current form will be phased out in favor of the
``Shape`` system within the next few versions of Mercurial, as of Mercurial 7.2.
See the ``Shapes vs narrowspec`` section below.

The ``narrowspec`` is a client-side configuration that consists of expressions
to match remote files and/or directories that should be pulled
into a client. The ``narrowspec`` has *include* and *exclude* expressions,
with excludes always trumping includes: that is, if a file matches an exclude
expression, it will be excluded even if it also matches an include expression.
Excluding files that were never included has no effect.

Each included or excluded entry is in the format described by
:hg:`help patterns`, but can only use ``path:`` or ``rootfilesin:``, except
when using ``Shard`` and ``Shape`` where you can only use ``path:``.

Shapes vs narrowspec
....................

The ``narrowspec`` was introduced alongside the experimental narrow extension
back in 2018.  It enabled the client to chose exactly what it cares about from
the server, with the server merely cooperating with the patterns that the
client asks for.

Unless this flexibility becomes really important for someone in the future,
the current direction is to deprecate the narrowspec usage and remove its
support entirely in later versions in favor of store shapes.

Here the advantages of store shapes::

  * We can define clonebundles for usual patterns
  * We can nest and generally compose includes and excludes
  * We can generate a fingerprint for equivalent patterns
  * We can require that the server and the client agree on patterns
  * Client are made aware of changes on the server, invalidating their patterns
  * A solid permissions system could be built on top of store shapes
  * Some legacy problems (e.g. CLI parsing) will be solved

Some of these points could be (and have been) bolted on top of the original
implementation, but we would not go very far.

Usage
-----

Server configuration
....................

For Mercurial 7.2, the ``.hg/store/server-shapes`` file is a TOML file,
maintained by the narrow server's administrators.

**Warning**: modify it with :hg:`admin::narrow-server --shape-update`, which
checks that the update is safe (see ``Updating the shapes config`` below).
Editing the file by hand is unsupported and will likely result in unexpected
client breakage.

The current (experimental!) format is the following::

  * ``version`` (required): its value must be ``0``
  * ``[[shards]]`` (required): a list of <shardconfig>
  * ``[[profiles]]`` (optional): a list of <profileconfig>
  * <shardconfig>:

    * ``name`` (required): canonical name for this shard.
    * ``paths`` (required): A list of UTF8 paths that this shard concerns,
        relative to the repo root.
    * ``read-write-access`` (optional): A list of opaque identifiers for who
        can read and write this shard. **Not enforced by Mercurial**, see
        below.

  * <profileconfig>:

    * ``name`` (required): canonical name for this profile.
    * ``includes`` (required): A list of the names of the shards and profiles
        that make up this profile.
    * ``public`` (optional): If ``true``, this profile can be requested by
        name in the UI and over the wire protocol. Otherwise, by default, it
        can only be used within this config in the ``includes`` of other
        profiles.

Constraints::

  * Profiles and shards share the same namespace: a name must be unique within
    the config
  * Names must only contain bytes that are either lowercase alphanumeric
    ascii, dot or hyphen
  * ``full``, ``base`` and ``.hg-files`` are reserved names
  * At least one shard must be defined
  * ``read-write-access`` values follow the same rules as names
  * ``paths`` and ``includes`` cannot be empty
  * Profiles cannot form a cycle through their ``includes``
  * A given path cannot be in more than one shard
  * ``paths`` must be a list of UTF8 paths. Support for non-UTF8 paths will be
    added in an upcoming version, via an ``encoded_paths`` field
  * ``paths`` must be a list of syntactically valid paths relative to the
    repository root (no ``\\n``, ``\\r`` or ``\\x00``, no consecutive slash, no
    slashes at the start or end, etc.)

Example::

    version = 0

    [[shards]]
    name = "foo-files"
    paths = ["foo", "bar.txt", "baz/nested"]

    [[shards]]
    name = "subproject1"
    paths = ["subproject1", "utils/only-this-dir"]
    read-write-access = ["backend-team", "release.managers"]

    [[shards]]
    name = "subproject2"
    paths = ["subproject2"]

    [[profiles]]
    name = "foo"
    includes = ["foo-files"]
    public = true

    [[profiles]]
    name = "backend"
    includes = ["subproject1", "subproject2"]

    [[profiles]]
    name = "full-stack"
    includes = ["backend", "foo"]
    public = true

Access control
..............

**WARNING**: Mercurial does *not* enforce ``read-write-access`` at the moment.
Any client that can access the repository can read the contents of every
shard, and any client that can push to it can write to every shard,
regardless of what it says. Enforcing it is planned for a future version of
Mercurial.

For now, ``read-write-access`` is only defined on shards to help external
systems (e.g. a hosting platform, or a proxy in front of the server) that
implement their own access control, so that they can use the same
configuration as the one defining the store's shards. Mercurial only checks
that its values are valid. Changing ``read-write-access`` is neither a
reshaping nor a resharding.

The ``read-write-access`` of every shard can be listed by shard id (as found
in sharded bundles) with::

  $ hg admin::narrow-server --store-shards -Tjson

Updating the profiles config
............................

Use :hg:`admin::narrow-server --shape-update` to replace the config. The
command refuses updates that violate any of the invariants described below.

(1) Shape fingerprints should not change

A profile should keep the same fingerprint for as long as there are clones using
it. Clients pin themselves to the fingerprint of the profile they cloned, so
redefining one means every one of them has to re-sync at the same time.
Instead of changing the profile directly, do the following::

  1. Add the new view under a new profile name.
  2. Move clients over to the new profile.
  3. Once nobody is cloned at the old profile, remove it.

Passing ``--override-fingerprint-change-check`` skips this check. You should
rarely want this: it is the update that forces every client cloned at that
shape to re-sync at once.

(2) Resharding OR reshaping

An update must be only one of the following, never both at once::

  * a *reshaping*: adding or removing a public profile (making a profile public
    or non-public counts as adding or removing it).
  * a *resharding*: changing how the store is partitioned. For example, a
    single shard with ``paths = ["foo"]`` partitions the store into "paths
    under foo/" and everything else. Adding another shard with any other path
    (whether or not it is under foo/) partitions it once more.

Note that shards and profiles are not independent, so a resharding may have to
touch the profiles as well to avoid changing fingerprints. A shard is judged by
the files it ends up owning, not by the ``paths`` it declares: adding a shard
takes files away from whichever shard held them before, so a single edit can
change several shards.

As a result, most real changes take two updates. For example, to add a new shard
and publish a profile for it::

  1. Add the shard and add its name to the ``includes`` of every profile that
     already covered those paths. Those profiles then still cover the same files
     and keep their fingerprint, so this is a pure resharding. The previous
     ``server-shapes`` files will be saved and used to serve existing sharded
     bundles.
  2. Generate the new bundles and add them to the clonebundle manifest.
  3. Clear the saved configs with
     :hg:`admin::narrow-server --shape-clear-previous`. They exist to keep old
     bundles usable and are no longer needed after step 2.
  4. Add the profile that includes the new shard. No shard changes, so this is a
     pure reshaping. It is allowed because the previous configs have been
     cleared, indicating that new bundles are ready and being advertised.
  5. Clients can begin using the new profile.

Passing ``--override-reshape-and-reshard-check`` applies the update regardless.
You should rarely want this: a mixed update can publish a profile before the
necessary bundles are generated.

(3) No reshaping while previous configs are saved

A reshaping is refused while previous ``server-shapes`` configs are still saved
(see steps 3-4 in the example above). Saved configs are used to continue
serving bundles from before a resharding, so clearing the configs indicates
that new bundles for the resharding are ready and any reshapes will be covered.

A server that does not serve sharded clone bundles has nothing to wait for and
can clear the saved configs right away.

Passing ``--override-saved-configs-check`` applies the update regardless. You
should rarely want this if you are using sharded bundles: the profile you change
may have no matching bundles until the ones for the current config are
generated and advertised.

Bundle generation
.................

Server administrators manually (and likely frequently) create streaming
clonebundles for every shape and expose them in the server clonebundle manifest
with their fingerprint. In future versions, non-streaming clonebundles will
be supported and their generations more automated.

You may generate the bundles with the following::

  $ hg bundle --all --type"none-v2;stream-v2;shape=my-shape" ../bundle.hg
  $ bundlespec="$(hg debugbundle --spec ../bundle.hg)"
  $ # [move bundle to static server or to `.hg/bundle-cache` for inline serving]
  $ bundleentry="https://static.com/bundle.hg BUNDLESPEC=$bundlespec"
  $ # [or use inline SSH clonebundles]
  $ bundleentry="peer-bundle-cache://bundle.hg BUNDLESPEC=$bundlespec"
  $ echo $bundleentry >> .hg/clonebundles.manifest

Several profile names separated by commas, as in
``shape=my-profile,other-profile``, produce a bundle for their composite shape,
which clients tracking these profiles together will use. Sharded bundles serve
such clients as well, since the shards of a composite shape are those of its
profiles.

You can export the includes and exclude patterns for every profile and give
them manually to clients::

  $ hg admin::narrow-server --shape-narrow-patterns my-profile
  [exclude]
  path:foo
  path:bar

Comma-separated profile names designate their composite shape, which covers
every file that any of them covers::

  $ hg admin::narrow-server --shape-narrow-patterns my-profile,other-profile
  [exclude]
  path:foo

Clients can then use said patterns when doing a narrow stream clone, which
matches the fingerprint from the patterns with that of the server clonebundles::

  $ hg clone --narrow --narrowspec $NARROWSPECFILE

Client
......

Clients clone a shape by name::

  $ hg clone --store-shape my-profile ssh://server/repo

Comma-separated names clone their composite shape, which covers every file
that any of them covers::

  $ hg clone --store-shape my-profile,other-profile ssh://server/repo

TODO explain current client-side config and how it might evolve (storing the
shape, fingerprint, etc.).
"""

from __future__ import annotations

from mercurial import (
    localrepo,
    registrar,
    requirements,
)


from . import (
    narrowbundle2,
    narrowcommands,
    narrowrepo,
    narrowtemplates,
    narrowwirepeer,
)

# Note for extension authors: ONLY specify testedwith = 'ships-with-hg-core' for
# extensions which SHIP WITH MERCURIAL. Non-mainline extensions should
# be specifying the version(s) of Mercurial they are tested with, or
# leave the attribute unspecified.
testedwith = b'ships-with-hg-core'

configtable = {}
configitem = registrar.configitem(configtable)
# Narrowhg *has* support for serving ellipsis nodes (which are used at
# least by Google's internal server), but that support is pretty
# fragile and has a lot of problems on real-world repositories that
# have complex graph topologies. This could probably be corrected, but
# absent someone needing the full support for ellipsis nodes in
# repositories with merges, it's unlikely this work will get done. As
# of this writining in late 2017, all repositories large enough for
# ellipsis nodes to be a hard requirement also enforce strictly linear
# history for other scaling reasons.
configitem(
    b'experimental',
    b'narrowservebrokenellipses',
    default=False,
    alias=[(b'narrow', b'serveellipses')],
)

# Export the commands table for Mercurial to see.
cmdtable = narrowcommands.table


def featuresetup(ui, features):
    features.add(requirements.NARROW_REQUIREMENT)


def uisetup(ui):
    """Wraps user-facing mercurial commands with narrow-aware versions."""
    localrepo.featuresetupfuncs.add(featuresetup)
    narrowbundle2.setup()
    narrowcommands.setup()
    narrowwirepeer.uisetup()


def reposetup(ui, repo):
    """Wraps local repositories with narrow repo support."""
    if not repo.local():
        return

    repo.ui.setconfig(b'experimental', b'narrow', True, b'narrow-ext')
    if repo.is_narrow:
        narrowrepo.wraprepo(repo)
        narrowwirepeer.reposetup(repo)


templatekeyword = narrowtemplates.templatekeyword
revsetpredicate = narrowtemplates.revsetpredicate
