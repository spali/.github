#!/usr/bin/env bash
# Checks of the repositories under managed: in the control file:
# managed-missing, managed-settings, managed-behind, rebase-pending and
# branch-undeclared (forks only), plus sync-failed (repository -): the newest
# completed run of the workflow sync.yml in the control repository.
# Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths),
# GITHUB_REPOSITORY (the control repository; unset: sync-failed is skipped),
# MONITOR_SKIP_SYNC (non-empty: another job checks sync-failed).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/managed-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/managed-lib.sh"

need_env FINDINGS INVENTORY CONFIG

# Upstream commits missing longer than this are red: the sync interval
# (24 h) plus 24 h.
BEHIND_HOURS=48

# hours_since ISO8601 prints whole hours elapsed (now is $MONITOR_NOW).
hours_since() {
  echo $(((${MONITOR_NOW:-$(date -u +%s)} - $(date -u -d "$1" +%s)) / 3600))
}

check_sync() {
  local body url
  [[ -z ${MONITOR_SKIP_SYNC:-} ]] || return 0
  if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
    finding skip sync-failed - "sync-failed: no control repository (local run)"
    return 0
  fi
  body=$(fetch sync-failed - \
    "repos/$GITHUB_REPOSITORY/actions/workflows/sync.yml/runs?per_page=1&status=completed") || return 0
  json_out sync-failed - url -r '
    .workflow_runs // [] | first // empty | select(.conclusion != "success") | .html_url' <<<"$body" || return 0
  [[ -z $url ]] || finding red sync-failed - "last sync run failed: $url"
}

# repo_info REPO OUTVAR stores GET repos/REPO in OUTVAR. Returns 1 after a
# managed-missing (404) or check-failed finding.
repo_info() {
  local errf body
  errf=$(mktemp)
  if body=$(gh api "repos/$1" 2>"$errf"); then
    rm -f "$errf"
    printf -v "$2" '%s' "$body"
    return 0
  fi
  if grep -qF '(HTTP 404)' "$errf"; then
    finding red managed-missing "$1" "managed repository does not exist (the sync creates it)"
  else
    finding red check-failed "$1" "managed-missing: $(err_line "$errf")"
  fi
  rm -f "$errf"
  return 1
}

# check_settings REPO SETTINGS_JSON INFO: the five has_* of the repository
# and Actions enabled must match the declared settings.
check_settings() {
  local repo=$1 want=$2 info=$3 body diff
  body=$(fetch managed-settings "$repo" "repos/$repo/actions/permissions") || return 0
  json_out managed-settings "$repo" diff -rs --argjson want "$want" '
    (.[0] + {actions: .[1].enabled}) as $have |
    [$want | to_entries[] | select($have[.key] != .value) |
      "\(.key) is \($have[.key]), expected \(.value)"] | join("; ")' <<<"$info"$'\n'"$body" || return 0
  [[ -z $diff ]] || finding red managed-settings "$repo" "$diff"
}

# check_refs REPO ENTRY PRIVATE PUSHED: every upstream branch and tag must
# exist with the same sha in the target (declared branches excepted, they
# are rebased). Red only when the last push is older than BEHIND_HOURS.
check_refs() {
  local repo=$1 entry=$2 private=$3 pushed=$4 upstream src tgt skip n
  upstream=$(jq -r .upstream <<<"$entry")
  src=$(mktemp)
  tgt=$(mktemp)
  skip=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$src' '$tgt' '$skip'; trap - RETURN" RETURN
  jq -r '.branches[] | "refs/heads/\(.name)"' <<<"$entry" >"$skip"
  if ! ls_remote "$upstream" "$src"; then
    finding red check-failed "$repo" "managed-behind: cannot read upstream"
    return 0
  fi
  if [[ $private == true ]]; then
    api_refs "$repo" "$tgt" managed-behind || return 0
  elif ! ls_remote "https://github.com/$repo.git" "$tgt"; then
    finding red check-failed "$repo" "managed-behind: cannot read target"
    return 0
  fi
  n=$(awk 'FILENAME == ARGV[1] {s[$1]; next} FILENAME == ARGV[2] {t[$1] = $2; next}
    !($1 in s) && t[$1] != $2 {n++} END {print n + 0}' "$skip" "$tgt" "$src")
  ((n > 0)) || return 0
  if [[ -z $pushed || $pushed == null ]]; then
    finding red managed-behind "$repo" "$n refs differ, last push never"
  elif (($(hours_since "$pushed") > BEHIND_HOURS)); then
    finding red managed-behind "$repo" "$n refs differ, last push $pushed"
  fi
}

# check_branches REPO ENTRY DEFAULT UPSTREAM_REPO UPSTREAM_DEFAULT: compares
# each declared branch (and, with refs default, the undeclared default branch
# onto the upstream default branch) with its onto upstream. auto: missing
# commits older than BEHIND_HOURS are managed-behind; manual: rebase-pending.
check_branches() {
  local repo=$1 entry=$2 default=$3 up=$4 updef=$5 tb list name sha onto rebase body n date
  tb=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$tb'; trap - RETURN" RETURN
  paged managed-behind "$repo" "repos/$repo/branches?per_page=100" '{name, sha: .commit.sha}' "$tb" || return 0
  json_out managed-behind "$repo" list -r --argjson e "$entry" --arg def "$default" --arg updef "$updef" '
    (map({key: .name, value: .sha}) | from_entries) as $sha |
    (if $e.refs == "default" and ($def | IN($e.branches[].name) | not)
     then [{name: $def, onto: $updef, rebase: "auto"}] else [] end) + $e.branches |
    .[] | select($sha[.name] != null) | [.name, $sha[.name], .onto, .rebase] | @tsv' "$tb" || return 0
  while IFS=$'\t' read -r name sha onto rebase; do
    [[ -n $name ]] || continue
    body=$(fetch managed-behind "$repo" "repos/$up/compare/$sha...$onto") || continue
    json_out managed-behind "$repo" n -r '.ahead_by // 0' <<<"$body" || continue
    ((n > 0)) || continue
    if [[ $rebase == manual ]]; then
      finding info rebase-pending "$repo" "$name: $n upstream commits to rebase onto $onto"
      continue
    fi
    json_out managed-behind "$repo" date -r '.commits[0].commit.committer.date // empty' <<<"$body" || continue
    if [[ -z $date ]]; then
      parse_failed managed-behind "$repo"
    elif (($(hours_since "$date") > BEHIND_HOURS)); then
      finding red managed-behind "$repo" "$name: $n upstream commits missing, oldest from $date"
    fi
  done <<<"$list"
}

# check_undeclared REPO ENTRY UPSTREAM_REPO UPSTREAM_DEFAULT
check_undeclared() {
  local repo=$1 entry=$2 up=$3 updef=$4 prs found branch n
  prs=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$prs'; trap - RETURN" RETURN
  paged branch-undeclared "$repo" "repos/$up/pulls?state=open&per_page=100" \
    '{head_repo: (.head.repo.full_name // ""), head_ref: .head.ref}' "$prs" || return 0
  found=$(undeclared_branches branch-undeclared "$repo" "$up" "$updef" \
    "$(jq -c '[.branches[].name]' <<<"$entry")" "$prs") || true
  while IFS=$'\t' read -r branch n; do
    [[ -z $branch ]] || finding red branch-undeclared "$repo" "$branch: $n own commits, not declared in repos.yml"
  done <<<"$found"
}

check_repo() {
  local repo=$1 entry=$2 info fields default private pushed body up updef
  repo_info "$repo" info || return 0
  json_out managed-missing "$repo" fields -r '[.default_branch, .private, .pushed_at] | @tsv' <<<"$info" || return 0
  IFS=$'\t' read -r default private pushed <<<"$fields"
  check_settings "$repo" "$(jq -c .settings <<<"$entry")" "$info"
  if [[ $(jq -r .refs <<<"$entry") == all ]]; then
    check_refs "$repo" "$entry" "$private" "$pushed"
  fi
  [[ $(jq -r .kind <<<"$entry") == fork ]] || return 0
  up=$(jq -r .upstream_repo <<<"$entry")
  body=$(fetch managed-behind "$repo" "repos/$up") || return 0
  json_out managed-behind "$repo" updef -r '.default_branch // empty' <<<"$body" || return 0
  if [[ -z $updef ]]; then
    parse_failed managed-behind "$repo"
    return 0
  fi
  check_branches "$repo" "$entry" "$default" "$up" "$updef"
  check_undeclared "$repo" "$entry" "$up" "$updef"
}

main() {
  local entries entry repo
  check_sync
  if ! entries=$(managed_entries "$CONFIG" 2>/dev/null); then
    finding red check-failed - "managed checks: cannot parse config"
    return 0
  fi
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    repo=$(jq -r .repo <<<"$entry")
    checked "$repo"
    check_repo "$repo" "$entry"
  done <<<"$entries"
}

main
