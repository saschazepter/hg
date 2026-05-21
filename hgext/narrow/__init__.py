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

A shape is used to define a set of paths to consider for clients of the narrow
server. And it does so through the entire history, regardless the state of these
files in the heads of the repository (deleted, for example).

As of Mercurial 7.2, only a limited scope of all planned shape-related features
have been implemented. Shapes are only directly interacted with by server
administrators. They can be used to generate narrowspecs (used by clients) and
to create narrow streaming clonebundles.

This means that as of Mercurial 7.2, clients have no knowledge of shapes and
must be given the set of narrow patterns by server administrators in order to
use a streaming clonebundle for a given shape::

    $ hg clone server --narrow --narrowspec NARROW_SPEC_FILE

Fingerprint
...........

Every shape corresponds to a normalized and minimal set of included and excluded
paths in a repository's store. This normalization ensures that we can derive a
fingerprint, meaning that two shapes with the same fingerprint mean they match
the same set of paths.

Checking the fingerprint of a narrow clone can be done by running::

    $ hg admin::narrow-client --store-fingerprint

For now, we guarantee no stability of the fingerprints. Before we take shapes
out of experimental, we will have a fingerprint versioning scheme, to allow
for future changes with no confusion.

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

Server-side, shards are used to define shapes, which are sets of shards. Each
shape defines the shards it includes, hence excluding the contents of all other
shards.

To simplify the creation of shapes, we can compose shards together by defining
explicit dependencies between shards. In our above example, we could define a
``foo.full`` (that does not itself have to define any paths), but requires both
``foo`` and ``foo.confidential``, giving us a shard with the full ``foo`` store
subtree.

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

For Mercurial 7.2, the ``.hg/store/server-shapes`` file is a TOML file, to be
created and modified directly by the narrow server's administrators.

**Warning**: using dedicated ``hg`` command to modify the shapes config will
become mandatory in future releases, once such a command exists,
as changing shapes can lead to (sometimes surprising) client breakage.

The current (experimental!) format is the following::

  * ``version`` (required): its value must be ``0``
  * ``shards`` (required): a list of <shardconfig>
  * <shardconfig>:

    * ``name`` (required): canonical name for this shard.
    * ``paths`` (optional): A list of UTF8 paths that this shard concerns,
        relative to the repo root.
    * ``requires`` (optional): A list of the names of the shards that this
        shard depends on.
    * ``shape`` (optional): If ``true``, this as a user-accessible shape.

Constraints::

  * Shard names must be unique within the config
  * Shard names must only contain bytes that are either lowercase alphanumeric
    ascii, dot or hyphen
  * ``full``, ``base`` and ``.hg-files`` are reserved shard names
  * Each <shardconfig> must define one of ``requires`` or ``paths``, or both
  * Shard requirements cannot form a cycle
  * A given path cannot be in more than one shard
  * ``paths`` must be a list of UTF8 paths. Support for non-UTF8 paths will be
    added in an upcoming version, via an ``encoded_paths`` field
  * ``paths`` must be a list of syntactically valid paths relative to the
    repository root (no ``\\n``, ``\\r`` or ``\\x00``, no consecutive slash, no
    slashes at the start or end, etc.)

Example::

    version = 0

    [[shards]]
    name = "foo"
    paths = ["foo", "bar.txt", "baz/nested"]
    shape = true

    [[shards]]
    name = "subproject1"
    paths = ["subproject1", "utils/only-this-dir"]

    [[shards]]
    name = "backend"
    paths = ["subproject2"]
    requires = ["subproject1"]
    shape = true

    [[shards]]
    name = "full-stack"
    requires = ["backend", "foo"]
    shape = true

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

You can export the includes and exclude patterns for every shape and give
them manually to clients::

  $ hg admin::narrow-server --shape-narrow-patterns my-shape
  [exclude]
  path:foo
  path:bar

Clients can then use said patterns when doing a narrow stream clone, which
matches the fingerprint from the patterns with that of the server clonebundles::

  $ hg clone --narrow --narrowspec $NARROWSPECFILE

Client
......

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
