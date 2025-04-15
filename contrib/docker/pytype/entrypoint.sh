#!/usr/bin/env bash

set -euo pipefail

cd /tmp/mercurial-ci/
make local
./contrib/check-pytype.sh
