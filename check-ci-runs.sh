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

# log <message>
function log() {
    printf '==> %s\n' "$1" >&2
}

# run <command> [<argument>...]
function run() {
    printf '%q%s\n' "$1" "${2+$(shift && printf ' %q' "$@")}" >&2
    "$@"
}

# same <ref>
function same() {
    run git diff-tree --quiet "$1" HEAD -- ${pathspec+"${pathspec[@]}"}
}

IFS=,
workflows=(${ci_workflows-})

[[ ${workflows+1} ]] || die "No CI workflows specified"

ci_started_at=${ci_run_id+$(gh run view --json startedAt --jq .startedAt "$ci_run_id")} ||
    ci_started_at=

# Read non-empty lines from `.ci-pathspec` into the `pathspec` array
group "Loading pathspec"
mapfile -t pathspec < <(
    [[ -f .ci-pathspec ]] || {
        note "Repository has no .ci-pathspec file, so entire tree must match"
        exit
    }
    log "Reading $PWD/.ci-pathspec"
    sed -E '/^[[:blank:]]*(#|$)/d' .ci-pathspec
)
endgroup

group "Checking workflow runs"
complete=()
pending=()
while IFS=$'\t' read -r sha run_id workflow started_at conclusion; do
    # Ignore the run we belong to
    [[ $run_id != "${ci_run_id-}" ]] || continue
    # Ignore runs that failed
    [[ ${conclusion:-success} == success ]] || continue
    # Ignore runs that are still in progress and started after ours, otherwise
    # we'll be waiting forever
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
    group "Comparing trees"
    for run in ${complete+"${complete[@]}"}; do
        read -r sha run_id workflow <<<"$run"
        same "$sha" || continue
        log "'$workflow' workflow run $run_id succeeded with the same tree: $sha"
        ci_required=0
        break
    done

    if ((ci_required)); then
        for run in ${pending+"${pending[@]}"}; do
            read -r sha run_id workflow <<<"$run"
            same "$sha" || continue
            log "'$workflow' workflow run $run_id is in progress with the same tree: $sha"
            endgroup
            exit 3
        done
    fi
    endgroup
fi

((!ci_required)) || log 'No successful workflow runs found with the same tree'
printf 'ci_required=%d\n' "$ci_required"
