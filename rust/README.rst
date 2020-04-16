===================
Mercurial Rust Code
===================

This directory contains various Rust code for the Mercurial project.
Rust is not required to use (or build) Mercurial, but using it
improves performance in some areas.

There are currently three independent rust projects:
- chg. An implementation of chg, in rust instead of C.
- hgcli. A experiment for starting hg in rust rather than in python,
  by linking with the python runtime. Probably meant to be replaced by
  PyOxidizer at some point.
- hg-core (and hg-cpython): implementation of some
  functionality of mercurial in rust, e.g. ancestry computations in
  revision graphs, status or pull discovery. The top-level ``Cargo.toml`` file
  defines a workspace containing these crates.

Using Rust code
===============

Local use (you need to clean previous build artifacts if you have
built without rust previously)::

  $ make PURE=--rust local # to use ./hg
  $ ./tests/run-tests.py --rust # to run all tests
  $ ./hg debuginstall | grep -i rust # to validate rust is in use
  checking Rust extensions (installed)
  checking module policy (rust+c-allow)
  checking "re2" regexp engine Rust bindings (installed)


If the environment variable ``HGWITHRUSTEXT=cpython`` is set, the Rust
extension will be used by default unless ``--no-rust``.

One day we may use this environment variable to switch to new experimental
binding crates like a hypothetical ``HGWITHRUSTEXT=hpy``.

Using the fastest ``hg status``
-------------------------------

The code for ``hg status`` needs to conform to ``.hgignore`` rules, which are
all translated into regex. 

In the first version, for compatibility and ease of development reasons, the 
Re2 regex engine was chosen until we figured out if the ``regex`` crate had
similar enough behavior.

Now that that work has been done, the default behavior is to use the ``regex``
crate, that provides a significant performance boost compared to the standard 
Python + C path in many commands such as ``status``, ``diff`` and ``commit``,

However, the ``Re2`` path remains slightly faster for our use cases and remains
a better option for getting the most speed out of your Mercurial. 

If you want to use ``Re2``, you need to install ``Re2`` following Google's 
guidelines: https://github.com/google/re2/wiki/Install.
Then, use ``HG_RUST_FEATURES=with-re2`` and 
``HG_RE2_PATH=system|<path to your re2 install>`` when building ``hg`` to 
signal the use of Re2. Using the local path instead of the "system" RE2 links
it statically.

For example::

  $ HG_RUST_FEATURES=with-re2 HG_RE2_PATH=system make PURE=--rust
  $ # OR
  $ HG_RUST_FEATURES=with-re2 HG_RE2_PATH=/path/to/re2 make PURE=--rust

Developing Rust
===============

The current version of Rust in use is ``1.34.2``, because it's what Debian
stable has. You can use ``rustup override set 1.34.2`` at the root of the repo
to make it easier on you.

Go to the ``hg-cpython`` folder::

  $ cd rust/hg-cpython

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

  $ cargo test --all

Formatting the code
-------------------

We use ``rustfmt`` to keep the code formatted at all times. For now, we are
using the nightly version because it has been stable enough and provides
comment folding.

To format the entire Rust workspace::

  $ cargo +nightly fmt

This requires you to have the nightly toolchain installed.

Additional features
-------------------

As mentioned in the section about ``hg status``, code paths using ``re2`` are
opt-in.

For example::

  $ cargo check --features with-re2

