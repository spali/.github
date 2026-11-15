#!/usr/bin/env bash
# Fork checks: fork-sync-stale / fork-behind (missing upstream commits),
# workflow-disabled / fork-workflows-active, fork-delete-candidate.
# Scope: inventory forks with a parent that are not mirror targets.
# Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

# check_behind REPO BRANCH PARENT PARENT_BRANCH SYNC_HOURS: SYNC_HOURS is empty
# for forks without their own sync workflow.
check_behind() {
  local repo=$1 branch=$2 parent=$3 pbranch=$4 sync=$5 body n date age
  body=$(fetch fork-behind "$repo" \
    "repos/$repo/compare/$branch...${parent%%/*}:$pbranch") || return 0
  json_out fork-behind "$repo" n -r '.ahead_by // 0' <<<"$body" || return 0
  ((n > 0)) || return 0
  if [[ -z $sync ]]; then
    finding info fork-behind "$repo" "$n commits behind upstream"
    return 0
  fi
  json_out fork-sync-stale "$repo" date -r '.commits[0].commit.committer.date // empty' <<<"$body" || return 0
  if [[ -z $date ]]; then
    parse_failed fork-sync-stale "$repo"
    return 0
  fi
  age=$(((${MONITOR_NOW:-$(date -u +%s)} - $(date -u -d "$date" +%s)) / 3600))
  if ((age > sync + 24)); then
    finding red fork-sync-stale "$repo" "$n upstream commits missing, oldest from $date"
  fi
}

# check_workflows REPO SYNCED: one call for workflow-disabled (forks with
# their own sync workflow) or fork-workflows-active (all other forks).
check_workflows() {
  local repo=$1 synced=$2 body found line n
  body=$(fetch workflow-disabled "$repo" "repos/$repo/actions/workflows?per_page=100") || return 0
  if [[ -n $synced ]]; then
    disabled_workflows workflow-disabled "$repo" found <<<"$body" || return 0
    while IFS= read -r line; do
      [[ -z $line ]] || finding red workflow-disabled "$repo" "$line"
    done <<<"$found"
  else
    json_out fork-workflows-active "$repo" n '
      [.workflows // [] | .[] | select(.state == "active")] | length' <<<"$body" || return 0
    if ((n > 0)); then
      finding info fork-workflows-active "$repo" "$n active workflows"
    fi
  fi
}

# check_delete_candidate REPO BRANCH PARENT PARENT_BRANCH: no own commits on the
# default branch, no open upstream PR from the fork, and every fork branch also
# exists upstream.
check_delete_candidate() {
  local repo=$1 branch=$2 parent=$3 pbranch=$4 body n prs mine fb pb extra
  body=$(fetch fork-delete-candidate "$repo" \
    "repos/$parent/compare/$pbranch...${repo%%/*}:${repo#*/}:$branch") || return 0
  json_out fork-delete-candidate "$repo" n -r '.ahead_by // "x"' <<<"$body" || return 0
  [[ $n == 0 ]] || return 0
  prs=$(mktemp)
  fb=$(mktemp)
  pb=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$prs' '$fb' '$pb'; trap - RETURN" RETURN
  paged fork-delete-candidate "$repo" "repos/$parent/pulls?state=open&per_page=100" \
    '{head: (.head.repo.full_name // "")}' "$prs" || return 0
  json_out fork-delete-candidate "$repo" mine --arg r "$repo" \
    '[.[] | select(.head | ascii_downcase == ($r | ascii_downcase))] | length' "$prs" || return 0
  [[ $mine == 0 ]] || return 0
  paged fork-delete-candidate "$repo" "repos/$repo/branches?per_page=100" '{name}' "$fb" || return 0
  paged fork-delete-candidate "$repo" "repos/$parent/branches?per_page=100" '{name}' "$pb" || return 0
  json_out fork-delete-candidate "$repo" extra --slurpfile p "$pb" \
    '([$p[0][].name]) as $pn | [.[] | select(.name as $n | $pn | index($n) | not)] | length' "$fb" || return 0
  [[ $extra == 0 ]] || return 0
  finding info fork-delete-candidate "$repo" "no own commits, no open pull request upstream"
}

main() {
  local forks repo branch parent pbranch sync
  if ! forks=$(jq -r --slurpfile c "$CONFIG" '
      ([$c[0].mirrors // [] | .[].target]) as $m |
      ([$c[0].forks // [] | .[] | {key: .repo, value: .sync_interval_hours}] | from_entries) as $f |
      .[] | select(.fork == true and .parent != null and ([.name] | inside($m) | not)) |
      [.name, .default_branch, .parent.name, .parent.default_branch, ($f[.name] // "" | tostring)] | @tsv' \
    "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "fork checks: cannot parse inventory"
    return 0
  fi
  while IFS=$'\t' read -r repo branch parent pbranch sync; do
    [[ -n $repo ]] || continue
    checked "$repo"
    check_behind "$repo" "$branch" "$parent" "$pbranch" "$sync"
    check_workflows "$repo" "$sync"
    check_delete_candidate "$repo" "$branch" "$parent" "$pbranch"
  done <<<"$forks"
}

main
