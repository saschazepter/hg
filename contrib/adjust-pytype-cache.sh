#!/bin/bash

set -e
set -u
set -o pipefail

cd "$(hg root)"

if [ ! -e .pytype ]; then
    echo "no cache available" >&2
    exit 0
fi

if [ ! -e .pytype/CACHE_COMMIT ]; then
    echo "no cache origin information" >&2
    echo "purging the cache" >&2
    rm -rf .pytype
    exit 0
fi

SOURCE_COMMIT=`cat .pytype/CACHE_COMMIT`

if ! hg log --rev "id($SOURCE_COMMIT)" -T 'HAS MATCH' | grep -q 'HAS MATCH' ; then
    echo "unknown cache source" >&2
    echo "purging the cache" >&2
    rm -rf .pytype
    exit 0
fi

### lets fiddle with time stamp !
# ninja use timestamp for its cache validation

changed=`hg status --no-status --removed --added --modified --rev "id($SOURCE_COMMIT)" | wc -l`
echo "reusing cache from $SOURCE_COMMIT ($changed file changes)" >&2
# first mark the cache content as newer than the repostiory content
sleep 1
find .pytype -exec touch '{}' ';'

# then update the timestamp of the file changed between the cache source and the changeset we test
sleep 1
hg status --no-status --added --modified --rev "id($SOURCE_COMMIT)" | while read f; do
    touch "$f"
done
