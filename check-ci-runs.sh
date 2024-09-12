#!/usr/bin/env bash

set -euo pipefail

# die [<message>]
function die() {
    local s=$?
    printf '::error::%s\n' "${1-${0##*/} failed}" >&2
    exit $((s ? s : 1))
}

# group <title>
function group() {
    printf '::group::%s\n' "$1" >&2
}

# endgroup
function endgroup() {
    printf '::endgroup::\n' >&2
}

# warn <message>
function warn() {
    printf '::warning::%s\n' "$1" >&2
}

# note <message>
function note() {
    printf '::notice::%s\n' "$1" >&2
}

# debug <message>
function debug() {
    printf '::debug::%s\n' "$1" >&2
}

# log <message>
function log() {
    printf '==> %s\n' "$1" >&2
}

# same <ref> <run_id> <workflow>
function same() {
    if [[ ,${same_ref+"${same_ref[*]}"}, == *,$1,* ]]; then
        debug "same_ref hit: $1"
        return
    fi
    if [[ ,${not_same_ref+"${not_same_ref[*]}"}, == *,$1,* ]]; then
        debug "not_same_ref hit: $1"
        return 1
    fi
    if git diff-tree --quiet "$1" HEAD -- ${pathspec+"${pathspec[@]}"}; then
        same_ref+=("$1")
        return
    else
        log "'$3' workflow run $2 does not have the same tree: $1"
        not_same_ref+=("$1")
        return 1
    fi
}

IFS=,
workflows=(${ci_workflows-})

[[ ${workflows+1} ]] || die "No CI workflows specified"

ci_started_at=${ci_run_id+$(gh run view --json startedAt --jq .startedAt "$ci_run_id")} ||
    ci_started_at=
same_ref=()
not_same_ref=()

# Read non-empty lines from `.ci-pathspec` into the `pathspec` array
group "Checking pathspec"
mapfile -t pathspec < <(
    [[ ! -f .ci-pathspec ]] || {
        log "Loading $PWD/.ci-pathspec:"
        sed -E '/^[[:blank:]]*(#|$)/d' .ci-pathspec | tee /dev/stderr
    }
)
[[ ${pathspec+1} ]] ||
    note ".ci-pathspec is empty or missing, so entire tree must match"
endgroup

while true; do
    group "Checking workflow runs"
    complete=()
    pending=()
    while IFS=$'\t' read -r sha run_id workflow started_at conclusion; do
        # Ignore the run we belong to
        [[ $run_id != "${ci_run_id-}" ]] || continue
        # Ignore runs that failed
        [[ ${conclusion:-success} == success ]] || continue
        # Ignore runs that are still in progress and started after ours,
        # otherwise we'll be waiting forever
        [[ $conclusion ]] || [[ -z $ci_started_at ]] || [[ $ci_started_at > $started_at ]] || continue
        # Ignore runs with commits not in the repo
        git rev-parse --verify --quiet "${sha}^{commit}" >/dev/null || continue
        run="$sha,$run_id,$workflow"
        if [[ $conclusion ]]; then
            complete+=("$run")
        else
            pending+=("$run")
        fi
    done < <(
        for workflow in "${workflows[@]}"; do
            log "Retrieving '$workflow' workflow runs"
            gh run list --workflow "$workflow" --limit 100 \
                --json 'conclusion,databaseId,headSha,startedAt,workflowName' \
                --jq '.[] | [.headSha, .databaseId, .workflowName, .startedAt, .conclusion] | @tsv'
        done
    )
    endgroup

    ci_required=1
    if [[ ${complete+1}${pending+1} ]]; then
        group "Checking trees"
        for run in ${complete+"${complete[@]}"}; do
            read -r sha run_id workflow <<<"$run"
            same "$sha" "$run_id" "$workflow" || continue
            log "'$workflow' workflow run $run_id succeeded with the same tree: $sha"
            ci_required=0
            endgroup
            break 2
        done

        for run in ${pending+"${pending[@]}"}; do
            read -r sha run_id workflow <<<"$run"
            same "$sha" "$run_id" "$workflow" || continue
            note "Waiting for '$workflow' workflow run $run_id to finish with the same tree: $sha"
            sleep 60
            endgroup
            continue 2
        done
        endgroup
    fi
    break
done

((!ci_required)) || log 'No successful workflow runs found with the same tree'
printf 'ci_required=%d\n' "$ci_required"
