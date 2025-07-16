#!/bin/sh
set -ue

# define various useful location
this_dir=$(dirname "$0")
repo_root=$(hg root --cwd "$this_dir")
rel_bin_dir=".hg/dev-tools/bin"
bin_dir="$repo_root/$rel_bin_dir/"
env_dir="$repo_root/.hg/dev-tools/venv/"
config_path="$repo_root/.hg/dev-tools/fix-conf.rc"
export PIPX_HOME="$env_dir"
export PIPX_BIN_DIR="$bin_dir"

# TODO: we should make a symlink to `$bin_dir` in the working copy to make the
# tools available easily.

if ! (hg debugrequires | grep share-safe -q ); then
    echo 'the repository is not share-safe, upgrade your repo' >&2
    echo '(see hg help config.format.use-share-safe)' >&2
    exit 128
fi


# fetch the black version in the toml is not easy and won't work as "23" is not
# understood by pip as is.
#
# TODO: use a more precise black version in the pyproject.toml
# TODO: rewrite this script in Python as python3.11 has native toml support
pipx install black==23.12.1 --force --quiet --quiet

# TODO: install/ensure rustfmt and clangformat
# (or at least adjust configuration accordingly)

# adjust the black path to point to the one we just installed.
cp "$repo_root/contrib/fix-conf.rc" "$config_path"
sed -i "s;black:command = black;black:command = $rel_bin_dir/black;" "$config_path"


# ensure the configuration for fix is included.
#
# We include it on a per-share basis because the relative tool path is resolved
# from the repository root, so each share needs its own setup.
#
# In addition, each share could be on revision using different version/config,
# so keeping things separated seems simpler.
if ! ( \
    hg -R "$repo_root" config --debug -T '{source}\n' \
    | grep -q "$config_path" \
); then
    echo "%include dev-tools/fix-conf.rc" >> .hg/hgrc-not-shared
fi
