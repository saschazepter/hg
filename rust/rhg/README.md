# `rhg`

The `rhg` executable implements a subset of the functionnality of `hg`
using only Rust, to avoid the startup cost of a Python interpreter.
This subset is initially small but grows over time as `rhg` is improved.
When fallback to the Python implementation is configured (see below),
`rhg` aims to be a drop-in replacement for `hg` that should behave the same,
except that some commands run faster.

## Rough edges: a warning (also to packagers)

`rhg` should not be packaged for distribution without a warning that it is
experimental and that some rough edges exist, in order of worse to less bad:
  * A node/rev that is ambiguous with a name (tag, bookmark, topic, branch)
    will result in the command using the node/rev instead of the name, because
    names are not implemented yet. For example, `rhg cat -r abc` will resolve
    the `abc` node prefix and not look for the `abc` name.
  * some config options may be ignored entirely (this is a bug, please report)
  * pager support is not implemented yet
  * minor errors may be silenced
  * some error messages or error behavior may be slightly different
  * some warning and/or error output may do lossy encoding
  * other "terminal behavior" may be different, like color handling, etc.
  * rhg may be overly cautious in falling back
  * possibly other things we haven't caught yet

With this in mind, `rhg` has been used in production successfully for years now,
and is reasonably well tested, so feel free to use it with these warnings
in mind.

## Building

To compile `rhg`, either run `cargo build --release` from this `rust/rhg/`
directory, or run `make build-rhg` from the repository root.
The executable can then be found at `rust/target/release/rhg`.

## Mercurial configuration

`rhg` reads Mercurial configuration from the usual sources:
the user’s `~/.hgrc`, a repository’s `.hg/hgrc`, command line `--config`, etc.
It has some specific configuration in the `[rhg]` section.

See `hg help config.rhg` for details.

## Installation and configuration example

For example, to install `rhg` as `hg` for the current user with fallback to
the system-wide install of Mercurial, and allow it to run even though the
`rebase` and `absorb` extensions are enabled, on a Unix-like platform:

* Build `rhg` (see above)
* Make sure the `~/.local/bin` exists and is in `$PATH`
* From the repository root, make a symbolic link with
  `ln -s rust/target/release/rhg ~/.local/bin/hg`
* Configure `~/.hgrc` with:

```
[rhg]
on-unsupported = fallback
fallback-executable = /usr/bin/hg
allowed-extensions = rebase, absorb
```

* Check that the output of running
  `hg notarealsubcommand`
  starts with `hg: unknown command`, which indicates fallback.

* Check that the output of running
  `hg notarealsubcommand --config rhg.on-unsupported=abort`
  starts with `unsupported feature:`.
