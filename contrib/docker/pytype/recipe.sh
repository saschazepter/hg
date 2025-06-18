#!/usr/bin/env bash
: ${HG_CI_REG:=registry.heptapod.net/mercurial/ci-images}
: ${HG_CI_IMAGE_TAG:=v3.2}


# find repo-root without calling hg as this might be run with sudo
THIS="$(readlink -m "$0")"
HERE="$(dirname "$THIS")"
HG_ROOT="$(readlink -m "$HERE"/../../..)"
echo source mercurial repository: "$HG_ROOT"

# find actual user as this might be run with sudo
if [ -n "$SUDO_UID" ]; then
    ACTUAL_UID="$SUDO_UID"
else
    ACTUAL_UID="$(id -u)"
fi
if [ -n "$SUDO_GID" ]; then
    ACTUAL_GID="$SUDO_GID"
else
    ACTUAL_GID="$(id -g)"
fi
echo using user "$ACTUAL_UID:$ACTUAL_GID"
if groups | egrep -q '\<(docker|root)\>' ; then
    docker run --rm -it \
        --user "$ACTUAL_UID:$ACTUAL_GID" \
        -v "$HG_ROOT:/tmp/mercurial-ci" \
        -w "/tmp/mercurial-ci" \
        "$HG_CI_REG/hg-core-pytype:$HG_CI_IMAGE_TAG" \
        ./contrib/check-pytype.sh
else
    echo "user not in the docker group" >&2
    echo "(consider running this with \`sudo\`)" >&2
    exit 255
fi
