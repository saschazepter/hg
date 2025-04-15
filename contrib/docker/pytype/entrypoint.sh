#!/usr/bin/env bash

set -euo pipefail

cd /tmp/mercurial-ci/
./contrib/check-pytype.sh
