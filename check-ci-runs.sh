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
    in_group=1
}

# endgroup
function endgroup() {
    if ((in_group)); then
        printf '::endgroup::\n' >&2
        in_group=0
    fi
}

# warning <message>
function warning() {
    printf '::warning::%s\n' "$1" >&2
}

# notice <message>
function notice() {
    printf '::notice::%s\n' "$1" >&2
}

# debug <message>
function debug() {
    printf '::debug::%s\n' "$1" >&2
}

# log <message>
function log() {
    printf -- '-> %s\n' "$1" >&2
}

# cmd <command> [<argument>...]
function cmd() {
    printf -- '->%s\n' "$(printf ' %q' "$@")" >&2
    "$@"
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
        log "'$3' run $2 has different tree: $1"
        not_same_ref+=("$1")
        return 1
    fi
}

IFS=,

workflows=(${ci_workflows-})

in_group=0
same_ref=()
not_same_ref=()

[[ ${workflows+1} ]] || die "No CI workflows specified"

ci_started_at=${ci_run_id+$(
    gh run view --json startedAt --jq .startedAt "$ci_run_id"
)} || ci_started_at=

artifact_dir=$(mktemp -d)

trap endgroup EXIT

# Read non-empty lines from `.ci-pathspec` into the `pathspec` array
group "Checking pathspec"
mapfile -t pathspec < <(
    [[ ! -f .ci-pathspec ]] || {
        log "Loading $PWD/.ci-pathspec:"
        sed -E '/^[[:blank:]]*(#|$)/d' .ci-pathspec | tee /dev/stderr
    }
)
[[ ${pathspec+1} ]] ||
    notice ".ci-pathspec is empty or missing, so entire tree must match"
endgroup

group "Checking tree"
if [[ ! ${pathspec+1} ]]; then
    tree=$(git rev-parse "HEAD^{tree}")
else
    dirty=1
    git status --porcelain | grep . >/dev/null ||
        { [[ ${PIPESTATUS[*]} == 0,1 ]] && dirty=0; } || die
    ((!dirty)) || die "Working tree is dirty"

    commit=$(git rev-parse HEAD)
    checkout=$(git rev-parse --abbrev-ref HEAD)
    if [[ $checkout == HEAD ]]; then
        checkout=$commit
    else
        cmd git -c advice.detachedHead=false checkout "$commit"
    fi
    cmd git rm -rf --quiet .
    cmd git checkout "$commit" -- "${pathspec[@]}"
    tree=$(cmd git write-tree)
    cmd git checkout --force "$checkout"
fi >&2
printf '%s\n' "$tree" >"$artifact_dir/tree"
log "Tree object for this run: $tree"
endgroup

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
    [[ $conclusion ]] || [[ ! $ci_started_at ]] || [[ $ci_started_at > $started_at ]] || continue
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
        log "Retrieving '$workflow' runs"
        gh run list --workflow "$workflow" --limit 100 \
            --json 'conclusion,databaseId,headSha,startedAt,workflowName' \
            --jq '.[] | [.headSha, .databaseId, .workflowName, .startedAt, .conclusion] | @tsv'
    done | sort -k4,4r
)

ci_required=1
for run in ${complete+"${complete[@]}"}; do
    read -r sha run_id workflow <<<"$run"
    same "$sha" "$run_id" "$workflow" || continue
    notice "'$workflow' run $run_id succeeded with same tree: $sha"
    ci_required=0
    unset pending
    break
done

for run in ${pending+"${pending[@]}"}; do
    read -r sha run_id workflow <<<"$run"
    same "$sha" "$run_id" "$workflow" || continue
    log "Waiting for '$workflow' run $run_id to finish"
    cmd gh run watch --exit-status "$run_id" &>/dev/null || continue
    notice "'$workflow' run $run_id succeeded with same tree: $sha"
    ci_required=0
    break
done

endgroup

((!ci_required)) || log 'No successful workflow runs found with the same tree'

printf '%s=%s\n' \
    artifact_dir "$artifact_dir" \
    ci_required "$ci_required"
