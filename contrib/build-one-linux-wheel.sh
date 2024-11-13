#!/bin/bash
# build a single linux wheel within a prepared imaged based on manylinux images
#
#
#
set -eu

# enforce that the translation are built
export MERCURIAL_SETUP_FORCE_TRANSLATIONS=1

if [ $# -lt 2 ]; then
    echo "usage $0 PYTHONTAG DEST_DIR" >&2
    echo "" >&2
    echo 'PYTHONTAG should be of the form "cp310-cp310"' >&2
    exit 64
fi
py_tag=$1
destination_directory=$2


tmp_wheel_dir=./tmp-wheelhouse

if [ -e $tmp_wheel_dir ]; then
    rm -rf $tmp_wheel_dir
fi
/opt/python/$py_tag/bin/python setup.py bdist_wheel --dist-dir $tmp_wheel_dir
# adjust it to make it universal
auditwheel repair $tmp_wheel_dir/*.whl -w $destination_directory
