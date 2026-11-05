# Agentic work in Mercurial

The skill to work on this repo is at `.agents/skills/mercurial-development`.

## Calibration
- Core (storage, exchange, transactions…): a human vouches for every line; write for line-by-line review.
- UI/experimental: looser implementation is fine, but never regress core performance, break CLI compatibility, or make code harder to reason about.
- Every changeset must be understandable on its own by a human.

## Before coding
- Bug fixes in released code → `stable`, minimal. Everything else → `default`. Split mixed series so only the fix goes to `stable`.
- Reuse before writing: higher-level APIs, `vfs`, `cmdutil`, transaction and test helpers, Rust error extension traits. Logic duplicated twice → shared helper in a preparatory changeset. Extend an existing command or flag before adding one.
- New risky commands, extensions and formats start experimental or behind config. Namespaces: `debug::` (dev tools, no compat), `admin::` (maintenance), `script::` (automation), `perf::` (measurement).
- New standalone tooling that doesn't need to live in Mercurial core goes in `jif` (pure Rust, no compat guarantees yet).

## Series shape
- One intent per changeset; incidental fixes, options and doc tweaks get their own.
- Refactors (moves, extractions, renames, new arguments, annotations) come first and change no behavior.
- Every changeset builds and passes everything CI checks.
- Fold review fixes and in-series churn into the changeset concerned. Incremental steps are fine only when each is a change in its own right (simple version, then optimization).
- Introduce helpers, config and docs in the changeset that first uses and tests them, unless split off for size; then the message names the changeset that uses them.
- No stray hunks: unrelated formatting, stray files, debug output.
- Long series → multiple topics, usually stacked; self-contained changesets at the bottom, contentious ones on top.
- Out-of-scope improvements → `TODO` or an issue.
- Avoid noisy diffs: split or prepare them (e.g. a temporary `if True:` to keep indentation, removed in the next changeset).

## Commit messages
- `subject: summary of what is done` in the first line, subject must be a single word, hyphenated if needed (e.g. `rust-errors`, `changegroup-v4`). The body contains why and what behavior changes, then how if non-obvious. Only trivial changes skip the body; "easier to read" or "prepares the next change" is often enough.
- Focus on the important, use examples rather than a long sentence
- Must match the diff: right subsystem, right names, nothing claimed that isn't done. Update when reworking.
- Say where it fits: what comes next, why the work is split, any temporary state.
- Justification lives in the commit, not the MR (MR description is for meta, e.g. dependencies). Explanations of the code go in docstrings; the body may say "Explanations inline".
- Performance claims need reproducible numbers in the message (Poulpe preferred). Never claim a gain you haven't measured.
- `(#N)` at the end of the summary for fixed bug `N`; `(BC)` for incompatible changes; verbatim text in backticks; must pass commit checks.
- No tool or LLM attribution unless needed to reproduce (benchmark suite, repro script). No leftover `HG:` lines or work notes. Don't restate your prompt.

## Tests
- Every behavior change gets a test (fixes, features, options, error and refusal paths), often one extra invocation in an existing file. If impossible or not worth it, say so.
- The test fails without the change and shows before/after output; nothing sent to `/dev/null`.
- Bug fixes: first a changeset adding the test with `(known-bad-output !)`/`(missing-correct-output !)`; the fix flips them. Any needed refactor goes between, with unchanged output.
- Structure `.t` files as in "Documenting tests" in `tests/README.md`.
- Exercise hard cases: ambiguous prefixes, multiple heads, repeated options, no-ops.
- Black-box only: no `debugshell` or ad-hoc extensions in new `.t` files; no new `.py` tests (doctests for Python unit tests).
- Cover Python and Rust, and format variants as `#testcases`. Must pass `--rhg`, `--rust`, chg and all platforms; run likely flavours locally first. rhg features need a no-fallback test (usually `test-rhg.t`).
- Small cases go in the area's existing file. Reuse `tests/testlib`. Force paths and races with `devel.*` config, not hand-edited files. Check state with `hg` commands and templates, not `.hg/` files. Glob only what is truly unstable.

## Code
- Docstring every new function, class, struct, field and module (Rust: `///`, enum variants too): purpose and what it enforces for callers, not what the types say.
- Comment only the non-obvious: races, compat, API constraints, magic numbers, workarounds, invariants. If a reviewer would ask why, answer in a comment. Update comments with behavior; mark deferred work `TODO`/`XXX`.
- Names describe role (`base`/`excluded`, not `m1`/`m2`), use full words and existing Mercurial terminology. Python: `snake_case`, `CamelCase` classes.
- Code lives in the module that owns the concept; keep internals behind their owning type, generic APIs narrow. Shared Rust logic → `hg-core`, which never prints.
- Python and Rust behave identically (not structurally: don't port line by line). Only select features are Rust-only; everything works on pure Python.
- Reject unknown, invalid or ambiguous input. Errors: one line (hint also), name the offending value with context, proper error class and exit code, never a traceback; may point to a help topic. (`jif` errors may be friendlier.)
- Deprecate any feature or API with a warning for ≥1 release before removal. The CLI is public API and almost never breaks. User-visible changes get a note in `relnotes/next`. No compat breaks after the RC. Don't advertise debug commands for scripting.
- Config: `section.words-with-dashes`, no negative booleans, declared in `configitems.toml` with default and docs; dev-only knobs under `devel`. Output via `ui.formatter` (`-T` support). Help docs in the same changeset.

### Python
- Support the oldest supported version (`py-version-compat` CI); guard newer features with a comment naming the version.
- Precise annotations on new and touched code, no `Any`; semantic aliases (`HgPathT`, `RevnumT`); interfaces are `typing.Protocol`.
- Internal data is `bytes` (file names, config keys, anything that may reach output).
- Intermediate variables over nested or multi-line expressions; short branch first; explicit `is None`; enums or separate functions over boolean flags; module-level functions over closures.
- Narrow `try`/`except` on specific exceptions, never for control flow; feature-detect with `hasattr`/`getattr`.
- Internal names start with `_`. Multi-line signatures get a trailing comma.

### Rust
- No `unwrap` outside tests; `expect("<invariant>")`. User input or repo data yields errors, never panics.
- `hg-core` errors carry typed data; library crates don't implement `Display`. Convert with `From` and the existing extension traits.
- Named constants, reusing existing ones. `// Safety:` on every `unsafe`. Checked conversions (`hg-core` helpers like `u_u32`), not `as`.
- Format with the toolchain in `rust/README`; no compiler or clippy warnings; suppress with `#[expect(..., reason = "...")]`. MSRV = Debian testing at cycle start.
- Private items use visibility, not leading underscores.

## Performance
- Benchmark changes to hot or low-level code (revlog, index, dirstate, delta search, startup), refactors included, with `perf` and Poulpe. If you can't run them, say so and list the cases that need measuring.
- No micro-optimization without a measured win, and no optimizing for concerns invisible in profiling. Avoid needless work in hot paths: repeated `repo[rev]`, intermediate containers, allocations.
- Measurement tooling goes in `perf::` commands, not debug commands or scripts.

## Submission
- Before submitting a significant series, have a separate agent review it adversarially, and address its findings.

