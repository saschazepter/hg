#!/bin/bash

# Intended to run within docker using image:
#
#  registry.heptapod.net/mercurial/ci-images/core-wheel-x86_64-c:v3.0
#
# we might want to factor most of this with the associated mercurial-core CI
# definition. (i.e. move this script into a place where the CI can directly call it for its purpose)

set -e -x

PYTHON_TARGETS="cp39-cp39 cp310-cp310 cp311-cp311 cp312-cp312 cp313-cp313 cp314-cp314 cp315-cp315"

# We need to copy the repository to ensure:
# (1) we don't wrongly write roots files in the repository (or any other wrong
#     users)
# (2) we don't reuse pre-compiled extension built outside for manylinux and
#     therefor not compatible.
cp -r /src/ /tmp/src/
cd /tmp/src/
# clear potentially cached artifact from the host
# (we could narrow this purge probably)
hg purge \
    --ignored \
    --no-confirm


if [ ! -e /src/dist/ ]; then
    mkdir -p /src/dist
    chown "$(stat /src/ -c %u:%g)" /src/dist/
fi

# Build the wheel for one Python version.
#
# This runs in the background, so that all versions are built at the same time.
# Each build has its own directory, containing:
# - src/:      its own copy of the repository, since building writes files in
#              the source tree,
# - repaired/: the resulting wheel,
# - success:   an empty file, created once the wheel is ready.
build_one() {
    py=$1
    build_dir="/tmp/wheels/$py"
    tmp_wd="$build_dir/repaired"
    mkdir -p "$tmp_wd"
    cp -r /tmp/src/ "$build_dir/src"
    cd "$build_dir/src"
    # build a new wheel
    contrib/build-one-linux-wheel.sh "$py" "$tmp_wd"
    # fix the owner back to the repository owner
    chown "$(stat /src/ -c %u:%g)" "$tmp_wd"/*.whl
    mv "$tmp_wd"/*.whl /src/dist/
    touch "$build_dir/success"
}

# Background jobs ignore ctrl-c, so terminate the whole process group (the
# builds and this script) ourselves when it happens.
trap 'kill 0' INT

# Start all builds, each with its own log to keep the output readable.
#
# Set HG_WHEELS_SEQUENTIAL to a non-empty value to build one wheel at a time,
# for example to limit the load on the machine. The output of each build is
# then also displayed as it comes.
for py in $PYTHON_TARGETS; do
    echo "build wheel for $py"
    # cleanup any previous build
    rm -rf "/tmp/wheels/$py"
    mkdir -p "/tmp/wheels/$py"
    if [ -n "$HG_WHEELS_SEQUENTIAL" ]; then
        build_one "$py" 2>&1 | tee "/tmp/wheels/$py/build.log" &
        wait
    else
        build_one "$py" > "/tmp/wheels/$py/build.log" 2>&1 &
    fi
done

# Wait for all builds to finish
wait

# Report the result of each build, showing its log if it failed
all_succeeded=yes
for py in $PYTHON_TARGETS; do
    if [ -e "/tmp/wheels/$py/success" ]; then
        echo "built wheel for $py"
    else
        echo "FAILED to build wheel for $py" >&2
        cat "/tmp/wheels/$py/build.log" >&2
        all_succeeded=no
    fi
done

if [ "$all_succeeded" = no ]; then
    exit 1
fi
