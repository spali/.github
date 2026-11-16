#!/usr/bin/env bash
# Checks of the repositories under managed: in the control file:
# managed-missing, managed-settings, managed-behind, rebase-pending and
# branch-undeclared (forks only). sync-failed runs once, in monitor-lists.sh.
# Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/managed-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/managed-lib.sh"

need_env FINDINGS INVENTORY CONFIG

# Upstream changes missing longer than this (seconds) are red: the sync
# interval (24 h) plus 24 h.
BEHIND_SECONDS=$((48 * 3600))

# too_old ISO8601: true when the time is more than BEHIND_SECONDS before now
# ($MONITOR_NOW).
too_old() {
  (((${MONITOR_NOW:-$(date -u +%s)} - $(date -u -d "$1" +%s)) > BEHIND_SECONDS))
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

# check_refs REPO ENTRY PRIVATE PUSHED CONTRIB: every upstream branch and tag
# must exist with the same sha in the target (declared branches excepted,
# they are rebased, and the contribution branches CONTRIB, a JSON array of
# names the sync never writes). Red only when the last push is older than
# 48 h.
check_refs() {
  local repo=$1 entry=$2 private=$3 pushed=$4 contrib=$5 upstream src tgt skip n
  upstream=$(jq -r .upstream <<<"$entry")
  src=$(mktemp)
  tgt=$(mktemp)
  skip=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$src' '$tgt' '$skip'; trap - RETURN" RETURN
  jq -r --argjson c "$contrib" '.branches[].name, $c[] | "refs/heads/\(.)"' <<<"$entry" >"$skip"
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
  elif too_old "$pushed"; then
    finding red managed-behind "$repo" "$n refs differ, last push $pushed"
  fi
}

# check_branches REPO ENTRY DEFAULT UPSTREAM_REPO UPSTREAM_DEFAULT CONTRIB:
# compares each declared branch (and, with refs default, the undeclared
# default branch onto the upstream default branch) with its onto upstream,
# and each upstream branch that matches a follow pattern (not the default,
# not declared) with the target branch of the same name.
# auto (and followed): missing commits older than 48 h are managed-behind;
# manual: rebase-pending. A declared or followed branch missing in the target
# is managed-behind. The contribution branches CONTRIB (JSON array of names)
# are left out: the sync never writes them.
check_branches() {
  local repo=$1 entry=$2 default=$3 up=$4 updef=$5 contrib=$6 tb ub list name sha onto rebase body n date
  tb=$(mktemp)
  ub=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$tb' '$ub'; trap - RETURN" RETURN
  paged managed-behind "$repo" "repos/$repo/branches?per_page=100" '{name, sha: .commit.sha}' "$tb" || return 0
  if [[ $(jq -r '.follow // [] | length' <<<"$entry") -gt 0 ]]; then
    paged managed-behind "$repo" "repos/$up/branches?per_page=100" '{name}' "$ub" || return 0
  else
    echo '[]' >"$ub"
  fi
  json_out managed-behind "$repo" list -r --argjson e "$entry" --arg def "$default" --arg updef "$updef" \
    --argjson c "$contrib" --slurpfile u "$ub" '
    (map({key: .name, value: .sha}) | from_entries) as $sha |
    [$e.branches[].name] as $decl |
    [$u[0][].name | select(. as $n | . != $def and (IN($decl[]) | not)
      and any($e.follow // [] | .[]; . as $re | $n | test("^(?:" + $re + ")$")))
     | {name: ., onto: ., rebase: "auto"}] as $fol |
    (if $e.refs == "default" and ($def | IN($decl[]) | not)
     then [{name: $def, onto: $updef, rebase: "auto"}] else [] end) + $e.branches + $fol |
    .[] | select(.name | IN($c[]) | not) | [.name, ($sha[.name] // "-"), .onto, .rebase] | @tsv' "$tb" || return 0
  while IFS=$'\t' read -r name sha onto rebase; do
    [[ -n $name ]] || continue
    if [[ $sha == - ]]; then
      finding red managed-behind "$repo" "$name: missing in the target"
      continue
    fi
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
    elif too_old "$date"; then
      finding red managed-behind "$repo" "$name: $n upstream commits missing, oldest from $date"
    fi
  done <<<"$list"
}

# check_undeclared REPO ENTRY DEFAULT UPSTREAM_REPO UPSTREAM_DEFAULT PRS_FILE:
# the default branch counts only when it is not declared. With refs default
# it is compared with the upstream default branch (the sync moves it there);
# with refs all like any other branch (the sync mirrors it by name).
check_undeclared() {
  local repo=$1 entry=$2 default=$3 up=$4 updef=$5 prs=$6 found branch n tdef=
  [[ $(jq -r .refs <<<"$entry") != default ]] || tdef=$default
  found=$(undeclared_branches branch-undeclared "$repo" "$up" "$updef" \
    "$(jq -c '[.branches[].name]' <<<"$entry")" "$prs" "$tdef") || true
  while IFS=$'\t' read -r branch n; do
    [[ -z $branch ]] || finding red branch-undeclared "$repo" "$branch: $n own commits, not declared in repos.yml"
  done <<<"$found"
}

# open_pulls REPO UPSTREAM_REPO PRS_FILE CONTRIB_VAR writes the open upstream
# pulls with a branch of REPO as head ([{head_repo, head_ref, ...}], looked up
# per branch, never all upstream pulls) to PRS_FILE and stores the head
# branches of those from REPO (JSON array) in CONTRIB_VAR. On an API error the
# finding is recorded, CONTRIB_VAR is [] and it returns 1.
open_pulls() {
  local repo=$1 up=$2 prs=$3 tb
  printf -v "$4" '%s' '[]'
  tb=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$tb'; trap - RETURN" RETURN
  paged branch-undeclared "$repo" "repos/$repo/branches?per_page=100" '{name}' "$tb" || return 1
  head_pulls branch-undeclared "$repo" "$up" open "$(jq -c 'map(.name)' "$tb")" "$prs" || return 1
  json_out branch-undeclared "$repo" "$4" -c --arg r "$repo" \
    '[.[] | select((.head_repo // "" | ascii_downcase) == ($r | ascii_downcase)) | .head_ref]' "$prs"
}

# check_repo REPO ENTRY PRS_FILE (a temporary file for the open pulls)
check_repo() {
  local repo=$1 entry=$2 prs=$3 info fields default private pushed body up updef contrib='[]' pulls=0
  repo_info "$repo" info || return 0
  json_out managed-missing "$repo" fields -r '[.default_branch, .private, .pushed_at] | @tsv' <<<"$info" || return 0
  IFS=$'\t' read -r default private pushed <<<"$fields"
  check_settings "$repo" "$(jq -c .settings <<<"$entry")" "$info"
  if [[ $(jq -r .kind <<<"$entry") == fork ]]; then
    up=$(jq -r .upstream_repo <<<"$entry")
    if open_pulls "$repo" "$up" "$prs" contrib; then
      pulls=1
    fi
  fi
  if [[ $(jq -r .refs <<<"$entry") == all ]]; then
    check_refs "$repo" "$entry" "$private" "$pushed" "$contrib"
  fi
  [[ $(jq -r .kind <<<"$entry") == fork ]] || return 0
  body=$(fetch managed-behind "$repo" "repos/$up") || return 0
  json_out managed-behind "$repo" updef -r '.default_branch // empty' <<<"$body" || return 0
  if [[ -z $updef ]]; then
    parse_failed managed-behind "$repo"
    return 0
  fi
  check_branches "$repo" "$entry" "$default" "$up" "$updef" "$contrib"
  ((pulls == 0)) || check_undeclared "$repo" "$entry" "$default" "$up" "$updef" "$prs"
}

main() {
  local entries entry repo prs
  if ! entries=$(managed_entries "$CONFIG" 2>/dev/null); then
    finding red check-failed - "managed checks: cannot parse config"
    return 0
  fi
  while IFS= read -r entry; do
    [[ -n $entry ]] || continue
    repo=$(jq -r .repo <<<"$entry")
    checked "$repo"
    prs=$(mktemp)
    check_repo "$repo" "$entry" "$prs"
    rm -f "$prs"
  done <<<"$entries"
}

main
