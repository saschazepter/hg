#!/bin/bash
# A small script to cleanup old CI-pipeline that accumulate over time


d="`date -d '-1 month' --iso-8601`T00:00:00Z"

PROJECT_ID=22

token=$1

if [ -z $token ]; then
    echo "USAGE: $0 GITLAB_TOKEN" >&2
    exit 64
fi

get_ids() {
    curl --silent "https://foss.heptapod.net/api/v4/projects/$PROJECT_ID/pipelines?updated_before=$d&per_page=100" | python3 -m json.tool | grep -E '"\bid": ([0-9]+),' | grep -oE '[0-9]+'
}

ids=`get_ids`
while [ -n "$ids" ]; do
    echo '#########'
    for pipeline_id  in $ids; do
        echo "deleting pipeline #$pipeline_id"
        url="https://foss.heptapod.net/api/v4/projects/$PROJECT_ID/pipelines/$pipeline_id"
        echo $url
        curl \
            --header "PRIVATE-TOKEN: $token"\
            --request "DELETE"\
            $url
    done
    ids=`get_ids`
    if [ -n "$ids" ]; then
        sleep 1
    fi
done
