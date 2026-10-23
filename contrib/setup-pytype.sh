#!/bin/sh
set -ue

# Install pytype (and importlab) in the per-share dev-tools directory.
#
# This mirrors what the `hg-core-pytype` CI image does so that `make pytype`
# gives the same result as the CI job without having to use docker.

# define various useful location
this_dir=$(dirname "$0")
repo_root=$(hg root --cwd "$this_dir")
bin_dir="$repo_root/.hg/dev-tools/bin/"
env_dir="$repo_root/.hg/dev-tools/venv/"
export PIPX_HOME="$env_dir"
export PIPX_BIN_DIR="$bin_dir"

# pytype 2024.10.11 is the final release of pytype and it does not run on
# Python 3.13 or later. We pin Python 3.11 to match the CI image.
#
# If the CI image upgrade to 3.12, we should change the target python too.
pytype_version="2024.10.11"
pytype_python="python3.11"

if ! command -v "$pytype_python" > /dev/null 2>&1; then
    echo "$pytype_python not found, it is required to run pytype" >&2
    exit 128
fi

# pipx ignores --python when reinstalling over an existing venv (even with
# --force), so start from a clean slate to make sure the pin is honored.
if pipx list --short | grep -q '^pytype '; then
    pipx uninstall pytype --quiet
fi
pipx install "pytype==$pytype_version" --python "$pytype_python" --quiet

# `importlab` is a dependency of pytype that check-pytype.sh uses directly (in
# its --import-graph mode). pipx only exposes the entry points of the package
# it installs, so we link it by hand (as the CI image does).
ln -sf "${env_dir}venvs/pytype/bin/importlab" "${bin_dir}importlab"
