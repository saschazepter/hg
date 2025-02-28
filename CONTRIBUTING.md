# Mercurial's Contributing guidelines

Our full contribution guidelines are in our wiki, please see:

<https://www.mercurial-scm.org/wiki/ContributingChanges>

If you just want a checklist to follow, you can go straight to

<https://www.mercurial-scm.org/wiki/ContributingChanges#Submission_checklist>

If you can't run the entire testsuite for some reason (it can be
difficult on Windows), please at least run `contrib/check-code.py` on
any files you've modified and run `python contrib/check-commit` on any
commits you've made (for example, `python contrib/check-commit
273ce12ad8f1` will report some style violations on a very old commit).

## Development dependencies

### Required dependencies

- Python (see `project.requires-python` in `pyproject.toml`) with `venv` and `pip`

- `make` with few other standard Unix tools (`diff`, `grep`, `unzip`, `gunzip`, `bunzip2` and `sed`)

  For Windows, see `contrib/install-windows-dependencies.ps1`.

### Optional dependencies

- Mercurial contributors should install a quite recent Mercurial with the
  extensions `evolve` and `topic` activated.

- A C compiler and Python headers (typically Debian package `python3-dev`
  or Microsoft Build Tools for Visual Studio on Windows)

- `msgfmt` from the Debian package `gettext` (used to build the translations)

- [Rust tools](https://www.rust-lang.org/tools/install) (see `rust/README.rst`)

#### Note on installation

Mercurial is a Python application that can be installed with
[pipx](https://pipx.pypa.io) and `uv tool`. UV is a Rust application that can also be
installed with pipx or with
[its own installer](https://docs.astral.sh/uv/getting-started/installation/).

