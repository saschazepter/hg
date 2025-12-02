#!/bin/bash

set -eu

# Sparse-revlog usually shows the most gain on Manifest. However, it is simpler
# to general an appropriate file, so we test with a single file instead. The
# goal is to observe intermediate snapshot being created.
#
# We need a large enough file. Part of the content needs to be replaced
# repeatedly while some of it changes rarely.

bundlepath="$TESTDIR/artifacts/cache/big-file-churn.hg"
expectedhash=`cat "$bundlepath".md5`

LAZY_GEN="--lazy"
if [ "$SLOW" == "1" ]; then
    LAZY_GEN=""
fi

if [ "$PURE" == "1" ]; then
    if [ ! -f "$bundlepath" ]; then
        echo 'skipped: missing artifact, run "'"$TESTDIR"'/artifacts/scripts/generate-churning-bundle.py"' > "$TESTTMP/SKIPPED"
        exit
    fi
    currenthash=`f -M "$bundlepath" | cut -d = -f 2`
    if [ "$currenthash" != "$expectedhash" ]; then
        echo 'skipped: outdated artifact, md5 "'"$currenthash"'" expected "'"$expectedhash"'" run "'"$TESTDIR"'/artifacts/scripts/generate-churning-bundle.py"' > "$TESTTMP/SKIPPED"
        exit
    fi
fi

# If the validation fails, either something is broken or the expected md5 need
# updating.  To update the md5, invoke the script without --validate

"$TESTDIR"/artifacts/scripts/generate-churning-bundle.py --validate $LAZY_GEN > /dev/null

cat >> $HGRCPATH << EOF
[format]
sparse-revlog = yes
maxchainlen = 15
revlog-compression=zlib
[storage]
revlog.optimize-delta-parent-choice = yes
revlog.reuse-external-delta-parent = no
revlog.reuse-external-delta = no
revlog.reuse-external-delta-compression = no
delta-fold-estimate = always
[format]
use-delta-info-flags=$DELTA_INFO
EOF

hg init sparse-repo
hg -R sparse-repo unbundle $bundlepath
hg -R sparse-repo update
hg --cwd sparse-repo debugrevlog "SPARSE-REVLOG-TEST-FILE" > ./revlog-stats-reference.txt
