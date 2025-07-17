===================
Mercurial Rust Code
===================

This directory contains various Rust code for the Mercurial project.
Rust is not required to use (or build) Mercurial, but using it
improves performance in some areas.

There are currently four independent Rust projects:

- chg. An implementation of chg, in Rust instead of C.
- hgcli. A project that provides a (mostly) self-contained "hg" binary,
  for ease of deployment and a bit of speed, using PyOxidizer. See
  ``hgcli/README.md``.
- hg-core (and hg-pyo3): implementation of some
  functionality of mercurial in Rust, e.g. ancestry computations in
  revision graphs, status or pull discovery. The top-level ``Cargo.toml`` file
  defines a workspace containing these crates.
- rhg: a pure Rust implementation of Mercurial, with a fallback mechanism for
  unsupported invocations. It reuses the logic ``hg-core`` but
  completely forgoes interaction with Python. See
  ``rust/rhg/README.md`` for more details.
  .. warning::
    rhg should not yet be packaged for distribution without a warning that
    certain rough edges may be encountered, detailed in its README.

Using Rust code
===============

Local use (you need to clean previous build artifacts if you have
built without rust previously)::

  $ make PURE=--rust local # to use ./hg
  $ ./tests/run-tests.py --rust # to run all tests
  $ ./hg debuginstall | grep -i rust # to validate rust is in use
  checking Rust extensions (installed)
  checking module policy (rust+c-allow)


**note: the HGWITHRUSTEXT environment variable is deprecated and will be removed
in Mercurial 7.1, do not use it.**
If the environment variable ``HGWITHRUSTEXT=cpython`` is set, the Rust
extension will be used by default unless ``--no-rust``.

One day we may use this environment variable to switch to new experimental
binding crates like a hypothetical ``HGWITHRUSTEXT=hpy``.

Special features
================

In the future, compile-time opt-ins may be added
to the ``features`` section in ``hg-pyo3/Cargo.toml``.

To use features from the Makefile, use the ``HG_RUST_FEATURES`` environment
variable: for instance ``HG_RUST_FEATURES="some-feature other-feature"``.

Profiling and tracing
=====================

The terminology below assumes the oversimplification of profiling being mostly
sampling-based or an otherwise statistical way of looking at the performance
of Mercurial, whereas tracing is the deliberate attempt at looking into all
relevant events, determined by explicit tracing code.

The line is blurred when using things like Intel Processor Trace, but if you're
using Intel PT, you probably know.

Profiling
---------

Creating a ``.cargo/config`` file with the following content enables
debug information in optimized builds. This make profiles more informative
with source file name and line number for Rust stack frames and
(in some cases) stack frames for Rust functions that have been inlined::

  [profile.release]
  debug = true

``py-spy`` (https://github.com/benfred/py-spy) can be used to
construct a single profile with rust functions and python functions
(as opposed to ``hg --profile``, which attributes time spent in rust
to some unlucky python code running shortly after the rust code, and
as opposed to tools for native code like ``perf``, which attribute
time to the python interpreter instead of python functions).

Example usage::

  $ make PURE=--rust local # Don't forget to recompile after a code change
  $ py-spy record --native --output /tmp/profile.svg -- ./hg ...

Tracing
-------

Simple stderr
~~~~~~~~~~~~~

Setting the environment variable ``RUST_LOG`` to any valid level (``error``,
``warn``, ``info``, ``debug`` and ``trace``, in ascending order of verbosity)
will make hg print a few high level rust-related performance numbers to stderr.
It can also indicate why the rust code cannot be used (say, using lookarounds
in hgignore). ``RUST_LOG`` usage can be further refined, please refer to the
``tracing-subscriber`` rust crate for more details on ``EnvFilter``.

Example::

  $ make build-rhg
  $ RUST_LOG=trace rust/target/release/rhg status > /dev/null
  2025-03-04T12:14:42.336153Z DEBUG hg::utils: Capped the rayon threadpool to 16 threads
  2025-03-04T12:14:42.336901Z DEBUG config_setup: rhg: close time.busy=730µs time.idle=2.56µs
  2025-03-04T12:14:42.338668Z DEBUG repo setup:configitems.toml: hg::config::config_items: close time.busy=1.70ms time.idle=270ns
  2025-03-04T12:14:42.338682Z DEBUG repo setup: rhg: close time.busy=1.77ms time.idle=471ns
  2025-03-04T12:14:42.338716Z DEBUG main_with_result:CLI and command setup:new_v2: hg::dirstate::dirstate_map: close time.busy=291ns time.idle=210ns
  2025-03-04T12:14:42.354094Z DEBUG main_with_result:CLI and command setup:blackbox: rhg: close time.busy=15.2ms time.idle=622ns
  2025-03-04T12:14:42.354107Z DEBUG main_with_result:CLI and command setup: rhg: close time.busy=15.4ms time.idle=270ns
  2025-03-04T12:14:42.356250Z DEBUG main_with_result:rhg status:status:build_regex_match:re_matcher: hg::matchers: close time.busy=961µs time.idle=541ns
  2025-03-04T12:14:42.356291Z DEBUG main_with_result:rhg status:status:build_regex_match: hg::matchers: close time.busy=1.69ms time.idle=420ns
  2025-03-04T12:14:42.374671Z DEBUG main_with_result:rhg status:status: hg::dirstate::status: close time.busy=20.5ms time.idle=532ns
  2025-03-04T12:14:42.374700Z DEBUG main_with_result:rhg status: rhg::commands::status: close time.busy=20.6ms time.idle=470ns
  2025-03-04T12:14:42.380897Z DEBUG main_with_result:blackbox: rhg: close time.busy=6.19ms time.idle=932ns
  2025-03-04T12:14:42.380918Z DEBUG main_with_result: rhg: close time.busy=42.2ms time.idle=211ns

Full timeline view
~~~~~~~~~~~~~~~~~~

If compiled with the ``full-tracing`` feature, two things happen:
  - ``RUST_LOG`` writes a chrome-trace to a file instead of logging to stderr
  - More (maybe extremely) verbose tracing is available at the ``trace`` level
    that would otherwise get compiled out entirely.

The file defaults to ``./trace-{unix epoch in micros}.json``, but can be
overridden via the ``HG_TRACE_PATH`` environment variable.

Example::
  $ HG_RUST_FEATURES="full-tracing" make local PURE=--rust
  $ HG_TRACE_PATH=/tmp/trace.json RUST_LOG=debug ./hg st > /dev/null

In this case, opening ``/tmp/trace.json`` in `ui.perfetto.dev` will show a
timeline of all recorded spans and events, which can be very useful for making
sense of what is happening.

Developing Rust
===============

Minimum Supported Rust Version
------------------------------

The minimum supported rust version (MSRV) is specified in the `Clippy`_
configuration file at ``rust/clippy.toml``. It is set to be ``1.85.1`` as of
this writing, but keep in mind that the authoritative value is the one
from the configuration file.

We bump it from time to time, with the general rule being that our
MSRV should not be greater that the version of the Rust toolchain
shipping with Debian testing, so that the Rust enhanced Mercurial can
be eventually packaged in Debian.

To ensure that you are not depending on features introduced in later
versions, you can issue ``rustup override set x.y.z`` at the root of
the repository.

Build and development
---------------------

Go to the ``hg-pyo3`` folder::

  $ cd rust/hg-pyo3

Or, only the ``hg-core`` folder. Be careful not to break compatibility::

  $ cd rust/hg-core

Simply run::

   $ cargo build --release

It is possible to build without ``--release``, but it is not
recommended if performance is of any interest: there can be an order
of magnitude of degradation when removing ``--release``.

For faster builds, you may want to skip code generation::

  $ cargo check

For even faster typing::

  $ cargo c

You can run only the rust-specific tests (as opposed to tests of
mercurial as a whole) with::

  $ cargo test --all --no-default-features

Formatting the code
-------------------

We use ``rustfmt`` to keep the code formatted at all times. For now, we are
using the nightly version because it has been stable enough and provides
comment folding.

Our CI enforces that the code does not need reformatting. Before
submitting your changes, please format the entire Rust workspace by running::


  $ cargo +nightly fmt

This requires you to have the nightly toolchain installed.

Linting: code sanity
--------------------

We're using `Clippy`_, the standard code diagnosis tool of the Rust
community.

Our CI enforces that the code is free of Clippy warnings, so you might
want to run it on your side before submitting your changes. Simply do::

  $ cargo clippy

from the top of the Rust workspace. Clippy is part of the default
``rustup`` install, so it should work right away. In case it would
not, you can install it with ``rustup component add``.


.. _Clippy: https://doc.rust-lang.org/stable/clippy/
