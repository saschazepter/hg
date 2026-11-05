---
name: mercurial-development
description: How to build, test and handle changesets efficiently in the Mercurial repository itself. Use when running Mercurial's tests (including jif), building it, or inspecting and rewriting history in this repository.
---

# Working on Mercurial

## Running tests

- Run tests from the repository root with `python3 tests/run-tests.py`.
  - The runner builds and installs Mercurial into a temporary directory for
    each run, in the flavor you ask for, so you never need to build first.
  - Rust is compiled incrementally in `rust/target`, so later runs only
    rebuild what changed.
- Pick the flavor the change needs:
  - default: Python with C extensions;
  - `--rust`: also the Rust extensions;
  - `--pure`: Python only;
  - `--no-rust`: ignore compiled Rust;
  - `--rhg`: use `rhg` as `hg`, always use with --rust;
  - `--chg`: use `chg`;
  - `--jif`: also install the `jf` binary (see below).
- Off-by-default cargo features of the Rust extensions are enabled with
  `HG_RUST_FEATURES`, for example `HG_RUST_FEATURES=full-tracing`.
- Do not use `--local`.

### Spending little time and output

- **Choosing tests:**
  - narrow your test runs by naming the tests you need.
  - `test-foo.t#case` runs one case of a file that has `#testcases`.
  - `-k WORD` runs tests matching a keyword.
- **After a failure:**
  - `-f` stops at the first failure.
  - `-R` restarts from the last failure.
  - `-r` reruns only the failed tests.
- **Output:**
  - Always use `--nodiff`.
  - Do not limit the number of output lines, `--nodiff` is enough.
  - The runner writes a test's actual output to `test-foo.t.err`, next to the
    test file. Read the diff to judge it.
  - Accept new output, once it is right, by copying the `.err` file over the
    test file. `-i` prompts interactively, which agents can't answer.
  - `--keep-tmpdir`, or `--tmpdir DIR`, keeps the test's repositories so you
    can inspect them after a failure. Use it only when necessary.
  - `-d` prints the test's output live instead of diffing it, Only to debug a test
    that hangs.
- **Parallelism:** `-j N` sets the number of parallel jobs (default: the CPU
  count). Use the default unless intructed otherwise.

### Rust-only checks

- In `rust/`, run `cargo test -p <crate>` and `cargo clippy -p <crate> --tests`
  for the crates you touched rather than the whole workspace.
- Off-by-default features need `--features` to be built and linted at all.
- To check all crates and features, use `make rust-tests` and `make cargo-clippy`
- `cargo update -w --locked` checks that `Cargo.lock` is current.

### Checks before committing

- `tests/run-tests.py test-check-code.t test-check-format.t tests/test-check-commit.t
  test-check-module-imports.t test-check-rust-format.t`. The rustfmt nightly
  is pinned in `test-check-rust-format.t`.

## jif

- `rust/jif` is the crate of `jf`, a Rust-only frontend that works on
  Mercurial repositories without Python.
- Its `.t` tests start with `#require jif` and need `--jif` to run, for
  example `python3 tests/run-tests.py --jif test-jif.t`.
- Under `rust/`, `cargo run -p jif --bin jf -- <args>` runs it directly for a
  quick manual check.

## Building in place

Only build in place to check something by hand outside the tests:
- Very rarely needed.
- Make sure to stay contained to your test space and not affect anything on the system.
- `make local` builds the C extensions; run the result with `./hg`.
- `make local FLAVOR=--rust` adds the Rust extensions. A plain `make local`
  switches back to the C flavor, so pass the flavor on every rebuild.
- `FLAVOR` takes the same argument as run-tests.py

## Version control

- **Tools:** this repository uses Mercurial with the `evolve` and `topic`
  extensions; never use git commands on it.
- **Check the working copy** for command that may modify it (like commit)
- **Refer to changesets by node ID,** never by revision number:
  - Get IDs with `hg stack -v` whenever possible.
  - Otherwise get IDs with `hg log -r REVSET -T '{node|short} {desc|firstline}\n'`;
- **Keep output small.** History and the evolve state can be huge:
  - use `hg stack` to see the state of the current topic;
  - always give `-r` a narrow revset, such as `topic#stack`, `.`, `draft() and
    ancestors(.)` or `orphan() and topic#stack`;
  - `hg obslog` to gather information about history rewriting.
    - See rewrite effect using `hg obslog --patch -f`
  - never run a bare `hg log -G -r 'draft()'`;
  - set `HGPLAIN=1` for stable, unlocalised output without a pager;
  - use `-T` templates instead of parsing default output.
  - use `HGMERGE=":merge3"`
- **Read without updating the working copy:** `hg cat -r NODE FILE`,
  `hg diff -c NODE`, `hg export -r NODE` and `hg status --change NODE` don't
  touch it, so they're safe while something else runs in the checkout.
- **Work in a topic:** run `hg topic <name>` before the first commit.
  Changesets stay `draft`.
- **Rewrite** with `hg amend`, `hg uncommit`, `hg fold` or `hg split`, …
  - Rewriting history and evolving are two separate tasks, do not evolve orphans unless asked.
  - Use `hg next` and `hg prev` when possible.
  - Only evolve exactly what you need. use `hg evolve --rev <REVSET>` when `hg
    next` is not suitable.
  - Never use `--any` or `--all`.
  - On conflicts, edit the files, then run `hg resolve --mark` and `hg continue`.
  - When rebasing, explicitly select revisions: `hg rebase --rev REV --dest REV`
- **Never push or publish** (`hg phase --public`) unless asked.
