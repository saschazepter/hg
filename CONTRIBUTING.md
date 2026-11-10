# Mercurial's Contributing guidelines

## Development dependencies

### Required dependencies

- Python (see `project.requires-python` in `pyproject.toml`) with `venv` and
  `pip`

- `make` with few other standard Unix tools (`diff`, `grep`, `unzip`, `gunzip`,
  `bunzip2` and `sed`)

  For Windows, see `contrib/install-windows-dependencies.ps1`.

### Optional dependencies

- Mercurial contributors should install a quite recent Mercurial with the
  extensions `evolve` and `topic` activated.

- A C compiler and Python headers (typically Debian package `python3-dev` or
  Microsoft Build Tools for Visual Studio on Windows)

- `msgfmt` from the Debian package `gettext` (used to build the translations)

- [Rust tools](https://www.rust-lang.org/tools/install) (see `rust/README.md`)

#### Note on installation

Mercurial is a Python application that can be installed with
[pipx](https://pipx.pypa.io) and `uv tool`. UV is a Rust application that can
also be installed with pipx or with [its own
installer](https://docs.astral.sh/uv/getting-started/installation/).


## What reviewers expects from a merge request

The point of the rest of this document is to try to explicitly document every
tacit "rule" that has been used over the years, so they feel less arbitrary, can
be discussed more explicitly and relaxed on a case-by-base basis.

Feel free to send feedback. Guiding principles here can be discussed, adjusted,
removed, etc. Maintainers may have the final say, but it is *extremely* unlikely
that this long document is perfect.

### A note on agentic work

If you want to use coding agents, note that they can do most of the more
mechanical work in this document: it is rewritten in a more directive manner in
`AGENTS.md`. Please still read this agentic coding policy and read through the
document to get an understanding of our goals. Have every significant series go
through another agent’s adversarial review.

- **Core work** (storage, exchange, transactions, etc.): you take responsibility
  for 100% of your contribution, however you produced it. Review your own series
  yourself, even after an agentic review, which is encouraged.
- **UI and experimental work:** you are still responsible for what you send, and
  you must understand its tests, invariants and expected behavior. The
  implementation can get less scrutiny, as long as it does not significantly
  affect other people's work: performance regressions in the core, breaking CLI
  compatibility, or refactors that make the codebase harder for humans to reason
  about will most likely be refused.
- **History hygiene still applies.** Agents are very good at rebasing, splitting
  and extracting code to follow these guidelines. Humans remain responsible for
  broken code, security fixes and regressions, and must be able to understand
  each commit. We suspect it probably also helps current agents produce coherent
  series and think harder about the direction and quality of the code.

### Before you start

- **Pick the right branch.** Fixes for bugs in released code go to `stable`, so
  they ship in the next point release. New features, commands, refactors,
  cleanups and anything large or risky go to `default`. Keep changes on `stable`
  minimal: if a series mixes both, split it so that only the fix lands on
  `stable`.

- **Look for what already exists.** Before writing a helper, check whether core
  already has one: higher-level APIs, `vfs` and `cmdutil` helpers, transaction
  helpers, test helpers, the Rust error extension traits. If the same logic
  appears a second or third time, extract it into one shared helper, ideally in
  a preparatory changeset. Before adding a command or a flag, check whether an
  existing one can be extended or refactored.

- **Start new things as experimental.** In Mercurial itself, new risky commands,
  extensions and formats start as experimental, or behind a config option, so
  they can still change shape. New commands go in the right namespace: `debug::`
  for developer tools without compatibility guarantees, `admin::` for
  maintenance commands, and `script::` for interfaces meant for automation. In
  `jif`, no backwards compatibility is guaranteed yet, consider adding new
  features there.

- **Mind the release cycle.** During the freeze before a release, only bug fixes
  are reviewed and landed. Features, even experimental ones, and big refactors
  wait for the next cycle. Large series that are prone to bitrot are best sent
  early in a cycle.

### Shaping your series

- **One intent per changeset.** Each changeset carries one logical change with
  its own justification. A bug fix found along the way, an extra option or a doc
  tweak goes in its own changeset. Each one can then be reviewed and bisected on
  its own, and land as soon as it is ready.

- **Refactors come first.** Code moves, extractions, renames, new arguments and
  type annotations go in earlier changesets that do not change behavior. The
  behavior change then stays small and readable. A changeset presented as a
  refactor must not hide a semantic change.

- **Every changeset builds and passes the tests.** Mercurial history does not
  contain broken changesets. This covers everything the CI would cover, see the
  section about tests below.

- **Fold fixes into the changeset they fix**. Integrate review feedback by
  amending the changeset concerned, not by stacking “fix previous commit”
  changesets on top. The same goes for churn within a series: if a later
  changeset only corrects, moves or renames what an earlier one just added, fold
  it into that earlier changeset. Building something up over several changesets
  is fine when each step is a change in its own right, such as a simple version
  followed by an optimization.

- **Introduce code where it is first used.** A helper, config option or piece of
  documentation arrives in the changeset that first uses and tests it, not
  earlier. The exception is a large addition split off to keep each diff
  reviewable: its commit message then says which later changeset puts it to use.

- **Leave stray hunks out.** Unrelated whitespace or formatting changes,
  accidentally added files and debug output are flagged even when harmless.

- **Keep long series manageable.** Cut a long series into two or three MRs or
  stacked topics that can each find a review slot. Put self-contained changesets
  at the bottom, so they can land while the rest is discussed, and contentious
  ones at the end, where they can be dropped.

- **Stay in scope.** Improvements that go beyond the series' purpose are not
  required in it. Record them as a `TODO` in the code or as an issue, and let
  the series land.

- **Keep diffs readable.** If a change would produce a long, confusing or noisy
  diff, split it or prepare it, for example with a temporary `if True:` block
  that keeps the indentation unchanged and goes away in the next changeset.
  (Basically external diffing is usually lackluster)

### Commit messages

Reviewers read the commit message as carefully as the code, and it is what later
archaeology relies on.

- **Describe what the changeset actually does.** The message has to match the
  diff: the right subsystem, the right names, nothing claimed that is not done.
  Update the messages when the series is reworked.
- **Follow the standard form** The first line is `topic: <summary of what is
  done>`, then a paragraph of why it’s done, followed by possible clarifications
  on how the change is made.
- **Explain why.** The body says why we want the change, what behavior changes
  and how the change achieves what it claims. Only truly trivial changes, such
  as typo fixes, can do without a body. Most simple changes have a justification
  like “it’s easier to read” or “the next change will introduce a semantic
  change”
- **Say where the changeset fits.** If it prepares later work or leaves
  something in a temporary state, say what comes next and why the work is split.
- **Put the explanation in the commit, not only in the MR.** The MR page is not
  part of history. The MR description is for meta concerns, such as which other
  MR this one is based on.
- **Move lasting explanations into the code.** What explains the code rather
  than the change belongs in a docstring or the documentation, and the body can
  point there ("Explanations inline").
- **Back important performance claims with numbers.** Measure the actual
  difference on precise, reproducible cases, and put the numbers in the commit
  message of the changeset concerned, ideally using Poulpe.
- **Use the conventions.** Reference a fixed bug as `(#N)` at the end of
  the summary line. Mark backward-incompatible changes with `(BC)`. Put verbatim
  text in backticks. Make sure the message passes the commit checks.
- **No tool attribution.** Commit messages do not credit tools, including LLMs,
  unless the tool matters to reproduce something about the change, such as a
  benchmark suite or a repro script.
- **Proofread.** No leftover `HG:` lines, work notes, or typos that change the
  meaning.

### Tests

- **Every change comes with a test.** Bug fixes, new features, new options and
  flags, error paths and refusal paths all get one, even a minimal one, often a
  single extra invocation in an existing test. If a test is impossible or not
  worth it, say so explicitly in the MR.

- **The tests should prove the change.** It fails without the change and shows
  the effect: the state before and after, the relevant output, nothing thrown
  away to `/dev/null`. For a bug fix, add the test in an earlier changeset that
  records the wrong output with `(known-bad-output !)` and
  `(missing-correct-output !)`. The fix then flips those lines. If the fix needs
  a refactor, put the refactor between the two, so the unchanged test output
  shows it does not change behavior.

- **Explain what each case checks.** Structure `.t` files with ReST-style titles
  (`====` for groups, `----` for each case, plus a setup section), and say in
  prose which scenario each case reproduces and what result is expected. See
  "Documenting tests" in `tests/README.md`.

- **Test the hard cases.** Use inputs awkward enough to exercise the logic:
  ambiguous prefixes, several heads, repeated options, no-op operations. A
  happy-path test alone is not enough.

- **Don't test the implementation.** New `.t` tests do not rely on
  implementation details, through `debugshell` or ad-hoc Python extensions, so
  they keep working across implementations. For the same reason, `.py` tests are
  discouraged: use doctests for unit tests.

- **Cover every implementation and flavor.** When behavior is shared by Python
  and Rust, or exists in several formats, test each of them. Express format
  variants as `#testcases` in the test, not as global flags. The suite must pass
  in every flavor (`--rhg`, `--rust`, chg) and on every platform. rhg features
  need a test that runs without falling back to Python, typically in
  `test-rhg.t`. CI covers more flavors than a local machine, but running the
  affected tests in the likely flavors first saves CI time and review rounds.

- **Use the suite's infrastructure.**
  - Put small cases in the existing test file for that area, and create a new
    file only for a substantial set of cases.
  - `.py` tests are discouraged because they are tied to the implementation,
    prefer doctests for unit-tests
  - Reuse the `tests/testlib` helpers.
  - Open race windows and force code paths with `devel.*` config options rather
    than hand-edited files.
  - Check repository state with `hg` commands and templates rather than by
    reading files under `.hg/`.
  - Glob only what is genuinely unstable.

### Code

- **Document what you add.** Every new function, class, struct, field and module
  gets at least a short docstring saying what it is for, and what it enforces
  for callers. In Rust, use `///` on every new item, enum variants included.
  Don't repeat what the types already say.

- **Comment the non-obvious, sparingly.** Inline comments say why code is
  written the way it is: race windows, compatibility concerns, API constraints,
  magic numbers, workarounds, shortcuts and the invariants the code relies on.
  They can also mark the sections of a long function. If a reviewer had to ask
  why something is there, the answer belongs in a comment, not only in the
  review thread. Don't paraphrase simple code.

- **Keep comments accurate.** A change in behavior updates the docstrings and
  comments involved. Mark temporary code, known limitations and deferred work
  with `TODO` or `XXX`, so they are not lost.

- **Name things after their role.** A name says what a value is for (`base` and
  `excluded`, not `m1` and `m2`), not how it is implemented. Avoid generic or
  overloaded terms, use full words, and reuse the terminology Mercurial already
  has. In Python : new names use underscores, and classes use CamelCase.

- **Put code where its concept lives.** Code belongs in the module that owns the
  concept, not in the feature that first needed it. Keep internals behind the
  type that owns them, and keep generic APIs narrow. Shared Rust logic goes in
  `hg-core`, which never prints and leaves user-facing messages to its
  consumers.

- **Python and Rust behave the same.** In Mercurial, a behavior change on one
  side is mirrored on the other. Only select features are Rust-only; everything
  else must also work for pure-Python installations. Parity is about behavior,
  not structure: do not port Python line by line into Rust. For new
  functionality, consider the pure Rust `jif`.

- **Be strict with input.** Reject what is unknown, invalid or ambiguous instead
  of guessing. Error messages name the offending value and give the context
  needed to debug. User-facing failures use the proper error class and exit
  code, never a traceback. Errors and hints are one line, and can point to a
  help topic for more. This is not true in `jif`, whose errors can be more
  friendly.

- **Keep compatibility.**
  - Deprecate a feature or API for at least one release, with a warning, before
    removing it.
  - The CLI is Mercurial's public API: it stays backwards compatible, and we
    almost never break it.
  - Call out every user-visible behavior change, and add a release note under
    `relnotes/next`.
  - Do not break compatibility once the release candidate is out.
  - Debug commands carry no compatibility guarantee, so do not advertise them
    for scripting.

- **Configuration and output.**
  - Config options follow the naming guideline (`section.words-with-dashes`, no
    negative booleans).
  - Declare every option in `configitems.toml` with a default and documentation.
  - Keep developer-only knobs in `devel` options.
  - Route command output through `ui.formatter`, so it accepts `-T` templates.
  - Document new user-facing features in the help, in the same changeset.

#### Python

- **Support the oldest supported Python version.** Mercurial supports each
  Python version until its end of life, or longer if important parts of the
  community still rely on it. The `py-version-compat` CI jobs check this. Guard
  newer features explicitly, with a comment naming the version.
- **Annotate new and touched code** with real Python 3 annotations. Make them
  precise rather than widened or `Any`, and use the project's semantic aliases
  (`HgPathT`, `RevnumT`). Interfaces are `typing.Protocol` classes.
- **Keep data as `bytes`** internally, for file names, config keys and anything
  that may reach output.
- **Prefer plain, readable code.**
  - Use intermediate variables rather than long nested expressions. Avoid
    expressions or statements that spawn multiple lines.
  - Put the short branch first.
  - Compare against `None` explicitly.
  - Use enums or separate functions rather than boolean flags.
  - Use module-level functions rather than closures.
- **Keep `try`/`except` narrow.** Catch the specific exception, and do not use
  exceptions for ordinary control flow. Detect features with `hasattr` or
  `getattr`.
- Mark internal names with a leading `_`.
- When function declarations don’t fit in a single line, add a trailing comma so
  `black` puts one argument per line.

#### Rust

- **No bare `unwrap` outside tests.** Use `expect` with a message stating the
  invariant. Anything that user input or repository data can trigger returns an
  error rather than panicking.
- **`hg-core` errors carry typed data, not strings,** and library crates do not
  implement `Display`. Formatting messages is the consumer's job. Convert errors
  with `From` and the existing extension traits.
- **Name literal constants,** and reuse existing ones.
- **Justify every `unsafe` block** with a `// Safety:` comment.
- **Use checked conversions** rather than `as` casts. See utilities in
  `hg-core`, e.g. `u_u32`.
- **Format and lint.** Format with the toolchain documented in `rust/README`,
  and fix compiler and clippy warnings. Suppress a lint with `#[expect(...)]`
  and a reason. The minimum Rust version tracks Debian testing at the start of
  the Mercurial cycle.
- **No leading underscores** for private items. Use visibility instead.

### Performance

- **Benchmark changes to hot or low-level code before merging, refactors
  included,** to show there is no regression. Revlog, index, dirstate, delta
  search, startup, etc.. Use the `perf` extension and the Poulpe benchmark
  suite.
- **Let measurements decide.** Micro-optimizations without a measured win are
  dropped, and concerns invisible in profiling wait until they show up.
- **Avoid needless work in hot paths.** Repeated `repo[rev]` lookups,
  intermediate containers and needless allocations all add up.
- **Put measurement tooling in `perf::` commands**, not in debug commands or
  separate scripts.

### Submitting and review

- **Add `@mercurial.review` as a reviewer** on every MR, so it shows up in the
  shared review dashboard (the default template should already do this for you).
  You can still ping a specific person.
- Assign yourself to your own MR, it makes the listing of MR in review clearer
  for reviewers.
- **Make CI pass before asking for review.** That means `check-code`, the
  formatters, the type checker and every build flavor. Fix formatting in each
  changeset with `hg fix` (`make format-stack` for the whole topic), not in a
  fix-up commit.
- **Mark an MR that is not ready as Draft.** Reviewers do not review drafts (and
  barely see them).
- **Leave thread resolution to the reviewer.** The person who opened a thread
  resolves it after checking your answer or fix.
- **Expect reviewers to fix small things in flight.** For typos, small renames
  and formatting, a reviewer usually amends the series while landing it, rather
  than asking for another round. Pull what the reviewer pushed before stacking
  more work on top.
- **Not every comment blocks.** Reviewers say which feedback blocks landing and
  which is a nit or a follow-up. Review is a discussion, defending your opinion
  is always welcome. Some feedback may be deferred to follow up on requests,
  etc.
- **Large or unfamiliar changes may wait for a second reviewer.** A UI change, a
  toolchain bump or a large series may wait for a second approval.
- **Core developers do not merge alone what they co-wrote,** and merge their own
  MRs only when those bring no new code (e.g. clean merge, release tags).
