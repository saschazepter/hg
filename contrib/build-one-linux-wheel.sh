#!/bin/bash
# build a single linux wheel within a prepared imaged based on manylinux images
#
#
#
set -eu

if [ $# -lt 2 ]; then
    echo "usage $0 PYTHONTAG DEST_DIR [FLAVOR]" >&2
    echo "" >&2
    echo 'PYTHONTAG should be of the form "cp310-cp310"' >&2
    exit 64
fi
py_tag=$1
destination_directory=$2
flavor=${3:-c}


flavor_arg=""
if [[ "${flavor}" == "c" ]]; then
    :
elif [[ "$flavor" == "rust" ]]; then
    flavor_arg="--config-setting=--global-option=--rust"
elif [[ "$flavor" == "rhg" ]]; then
    flavor_arg="--config-setting=--global-option=--rust --config-setting=--global-option=--rhg  --config-setting=--global-option=--jif"
else
    echo "unknown flavor: \"$flavor\""
    exit 96
fi


tmp_wheel_dir=./tmp-wheelhouse

if [ -e $tmp_wheel_dir ]; then
    rm -rf $tmp_wheel_dir
fi

if [[ -n "$flavor_arg" ]]; then
    /opt/python/$py_tag/bin/python -m build --outdir $tmp_wheel_dir $flavor_arg
else
    /opt/python/$py_tag/bin/python -m build --outdir $tmp_wheel_dir
fi
# adjust it to make it universal
auditwheel repair $tmp_wheel_dir/*.whl -w $destination_directory
