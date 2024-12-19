#!/bin/sh

# This is a convenience script to build all of the wheels outside of the CI
# system.  It requires the cibuildwheel package to be installed, and the
# executable on PATH, as well as `msgfmt` from gettext, which can be installed
# with `brew` as follows:
#
#   $ /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
#   $ echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
#   <logout>
#   $ brew install gettext
#
# A system-wide installation of the version of python corresponding to each
# wheel is required.  They can be installed by this script by setting `CI=true`
# in the environment before running it, and providing the `sudo` password when 
# prompted.

set -e

if ! which msgfmt 2>/dev/null 1>/dev/null; then
    echo "msgfmt executable not found" >&2
    exit 1
fi

# TODO: purge the repo?

cibuildwheel --output-dir dist/wheels
