#!/usr/bin/env bash
# Fork checks: fork-sync-stale / fork-behind (missing upstream commits),
# workflow-disabled / fork-workflows-active, fork-delete-candidate,
# contribution-stale, branch-undeclared (info).
# Scope: inventory forks with a parent that are neither mirror targets nor
# managed (monitor-managed.sh checks those).
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

# check_delete_candidate REPO BRANCH PARENT PARENT_BRANCH PRS_FILE: no own
# commits on the default branch, no open upstream PR from the fork, and every
# fork branch also exists upstream or was the head of a closed or merged
# upstream PR from the fork (contribution done). PRS_FILE: the open upstream
# pulls, [{head_repo, head_ref, number, created_at, html_url}].
check_delete_candidate() {
  local repo=$1 branch=$2 parent=$3 pbranch=$4 prs=$5 body n mine fb pb cl extra
  body=$(fetch fork-delete-candidate "$repo" \
    "repos/$parent/compare/$pbranch...${repo%%/*}:${repo#*/}:$branch") || return 0
  json_out fork-delete-candidate "$repo" n -r '.ahead_by // "x"' <<<"$body" || return 0
  [[ $n == 0 ]] || return 0
  json_out fork-delete-candidate "$repo" mine --arg r "$repo" \
    '[.[] | select(.head_repo | ascii_downcase == ($r | ascii_downcase))] | length' "$prs" || return 0
  [[ $mine == 0 ]] || return 0
  fb=$(mktemp)
  pb=$(mktemp)
  cl=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$fb' '$pb' '$cl'; trap - RETURN" RETURN
  paged fork-delete-candidate "$repo" "repos/$repo/branches?per_page=100" '{name}' "$fb" || return 0
  paged fork-delete-candidate "$repo" "repos/$parent/branches?per_page=100" '{name}' "$pb" || return 0
  json_out fork-delete-candidate "$repo" extra --slurpfile p "$pb" \
    '([$p[0][].name]) as $pn | [.[] | select(.name as $n | $pn | index($n) | not) | .name]' "$fb" || return 0
  if [[ $extra != '[]' ]]; then
    paged fork-delete-candidate "$repo" "repos/$parent/pulls?state=closed&per_page=100" \
      '{head_repo: (.head.repo.full_name // ""), head_ref: .head.ref}' "$cl" || return 0
    json_out fork-delete-candidate "$repo" extra --arg r "$repo" --argjson e "$extra" \
      '[.[] | select(.head_repo | ascii_downcase == ($r | ascii_downcase)) | .head_ref] as $done |
       [$e[] | select(IN($done[]) | not)] | length' "$cl" || return 0
    [[ $extra == 0 ]] || return 0
  fi
  finding info fork-delete-candidate "$repo" "no own commits, no open pull request upstream"
}

# check_contributions REPO PRS_FILE: open upstream PRs from the fork older than
# 90 days.
check_contributions() {
  local repo=$1 prs=$2 rows n days url
  json_out contribution-stale "$repo" rows -r --arg r "$repo" --argjson now "${MONITOR_NOW:-$(date -u +%s)}" '
    .[] | select((.head_repo | ascii_downcase) == ($r | ascii_downcase)) |
    (($now - (.created_at | fromdateiso8601)) / 86400 | floor) as $d |
    select($d > 90) | [.number, $d, .html_url] | @tsv' "$prs" || return 0
  while IFS=$'\t' read -r n days url; do
    [[ -z $n ]] || finding info contribution-stale "$repo" "PR #$n open for $days days: $url"
  done <<<"$rows"
}

# check_undeclared REPO BRANCH PARENT PARENT_BRANCH PRS_FILE: no sync manages
# an unmanaged fork, so every branch with own commits counts; the default
# BRANCH is compared with PARENT_BRANCH.
check_undeclared() {
  local repo=$1 branch=$2 parent=$3 pbranch=$4 prs=$5 found b n
  found=$(undeclared_branches branch-undeclared "$repo" "$parent" "$pbranch" '[]' "$prs" "$branch") || true
  while IFS=$'\t' read -r b n; do
    [[ -z $b ]] || finding info branch-undeclared "$repo" "$b: $n own commits, not declared in repos.yml"
  done <<<"$found"
}

main() {
  local forks repo branch parent pbranch sync prs
  if ! forks=$(jq -r --slurpfile c "$CONFIG" '
      ([$c[0].mirrors // [] | .[].target]) as $m |
      ([$c[0].managed // [] | .[].repo | ascii_downcase]) as $mg |
      ([$c[0].forks // [] | .[] | {key: .repo, value: .sync_interval_hours}] | from_entries) as $f |
      .[] | select(.fork == true and .parent != null and ([.name] | inside($m) | not)) |
      select(.name | ascii_downcase | IN($mg[]) | not) |
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
    prs=$(mktemp)
    if paged fork-delete-candidate "$repo" "repos/$parent/pulls?state=open&per_page=100" \
      '{head_repo: (.head.repo.full_name // ""), head_ref: .head.ref, number, created_at, html_url}' "$prs"; then
      check_delete_candidate "$repo" "$branch" "$parent" "$pbranch" "$prs"
      check_contributions "$repo" "$prs"
      check_undeclared "$repo" "$branch" "$parent" "$pbranch" "$prs"
    fi
    rm -f "$prs"
  done <<<"$forks"
}

main
