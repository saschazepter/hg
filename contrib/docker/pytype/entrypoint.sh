#!/usr/bin/env bash

set -euo pipefail

cd /tmp/mercurial-ci/
make local
./contrib/setup-pytype.sh
./contrib/check-pytype.sh
