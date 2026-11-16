#!/usr/bin/env bash
# Checks of the repositories under managed: in the control file:
# managed-missing, managed-settings, managed-behind (branches and, unless
# tags is false, tags), rebase-pending and branch-undeclared. sync-failed runs once, in monitor-lists.sh.
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

# pushed_label PUSHED prints the last push for a message (empty or null:
# never); push_too_old PUSHED is true when it is older than 48 h or never.
pushed_label() {
  if [[ -z $1 || $1 == null ]]; then
    printf 'never\n'
  else
    printf '%s\n' "$1"
  fi
}

push_too_old() {
  [[ -z $1 || $1 == null ]] || too_old "$1"
}

# read_refs REPO UPSTREAM_URL PRIVATE SRC TGT writes the branches and tags of
# upstream (git ls-remote) and of the target (ls-remote, or the API for a
# private one) as "<ref> <sha>" lines. Returns 1 after a check-failed finding.
read_refs() {
  local repo=$1 upstream=$2 private=$3 src=$4 tgt=$5
  if ! ls_remote "$upstream" "$src"; then
    finding red check-failed "$repo" "managed-behind: cannot read upstream"
    return 1
  fi
  if [[ $private == true ]]; then
    api_refs "$repo" "$tgt" managed-behind || return 1
  elif ! ls_remote "https://github.com/$repo.git" "$tgt"; then
    finding red check-failed "$repo" "managed-behind: cannot read target"
    return 1
  fi
}

# check_tags REPO PUSHED SRC TGT: every upstream tag must exist with the same
# sha in the target (extra target tags are fine). Red only when the last
# push is older than 48 h.
check_tags() {
  local repo=$1 pushed=$2 src=$3 tgt=$4 n
  n=$(awk 'FILENAME == ARGV[1] {t[$1] = $2; next}
    $1 ~ /^refs\/tags\// && t[$1] != $2 {n++} END {print n + 0}' "$tgt" "$src")
  ((n > 0)) || return 0
  ! push_too_old "$pushed" ||
    finding red managed-behind "$repo" "$n tags differ, last push $(pushed_label "$pushed")"
}

# heads_json REFS_FILE prints the branches of a "<ref> <sha>" file as
# [{name, sha}].
heads_json() {
  jq -Rn '[inputs | split(" ") | select(length == 2 and (.[0] | startswith("refs/heads/")))
    | {name: (.[0] | ltrimstr("refs/heads/")), sha: .[1]}]' "$1"
}

# mirror_compare REPO BASE HEAD OUTVAR CHECK stores GET
# repos/REPO/compare/BASE...HEAD (two shas) in OUTVAR. Returns 3 when GitHub
# has no such comparison (404: a commit is not in the mirror yet), 1 after a
# check-failed finding of CHECK.
mirror_compare() {
  local mc_err mc_body
  mc_err=$(mktemp)
  if mc_body=$(gh api "repos/$1/compare/$2...$3" 2>"$mc_err"); then
    rm -f "$mc_err"
    printf -v "$4" '%s' "$mc_body"
    return 0
  fi
  if grep -qF '(HTTP 404)' "$mc_err"; then
    rm -f "$mc_err"
    return 3
  fi
  finding red check-failed "$1" "$5: $(err_line "$mc_err")"
  rm -f "$mc_err"
  return 1
}

# check_branches REPO ENTRY DEFAULT UPSTREAM_REPO UPSTREAM_DEFAULT CONTRIB TB
# UB PUSHED compares the default branch (unless declared) with the upstream
# default branch, each declared branch with its onto upstream and each
# upstream branch that matches a follow pattern (not the default, not
# declared) with the target branch of the same name. TB: the target branches
# [{name, sha}]; UB: the upstream branches [{name, sha}] (forks: the sha is
# not needed). A fork is compared in UPSTREAM_REPO (branch names
# URL-encoded); a mirror (UPSTREAM_REPO empty) in the mirror itself, which
# fails when the upstream commit is not there yet: the branch then differs
# and only the last push PUSHED tells its age.
# auto (and followed): missing commits older than 48 h are managed-behind;
# manual: rebase-pending. A declared or followed branch missing in the target
# is managed-behind. The contribution branches CONTRIB (JSON array of names)
# are left out: the sync never writes them.
check_branches() {
  local repo=$1 entry=$2 default=$3 up=$4 updef=$5 contrib=$6 tb=$7 ub=$8 pushed=$9
  local list name sha onto uri usha rebase body n date rc
  json_out managed-behind "$repo" list -r --argjson e "$entry" --arg def "$default" --arg updef "$updef" \
    --argjson c "$contrib" --slurpfile u "$ub" '
    (map({key: .name, value: .sha}) | from_entries) as $sha |
    ($u[0] | map({key: .name, value: (.sha // "-")}) | from_entries) as $usha |
    [$e.branches[].name] as $decl |
    [$u[0][].name | select(. as $n | . != $def and (IN($decl[]) | not)
      and any($e.follow // [] | .[]; . as $re | $n | test("^(?:" + $re + ")$")))
     | {name: ., onto: ., rebase: "auto"}] as $fol |
    (if ($def | IN($decl[]) | not) then [{name: $def, onto: $updef, rebase: "auto"}] else [] end)
      + $e.branches + $fol |
    .[] | select(.name | IN($c[]) | not)
    | [.name, ($sha[.name] // "-"), .onto, (.onto | @uri), ($usha[.onto] // "-"), .rebase] | @tsv' "$tb" || return 0
  while IFS=$'\t' read -r name sha onto uri usha rebase; do
    [[ -n $name ]] || continue
    if [[ $sha == - ]]; then
      finding red managed-behind "$repo" "$name: missing in the target"
      continue
    fi
    if [[ -n $up ]]; then
      body=$(fetch managed-behind "$repo" "repos/$up/compare/$sha...$uri") || continue
    else
      if [[ $usha == - ]]; then
        finding red managed-behind "$repo" "$name: onto $onto missing upstream"
        continue
      fi
      [[ $sha != "$usha" ]] || continue
      rc=0
      mirror_compare "$repo" "$sha" "$usha" body managed-behind || rc=$?
      ((rc != 1)) || continue
      if ((rc == 3)); then
        if [[ $rebase == manual ]]; then
          finding info rebase-pending "$repo" "$name: upstream commits to rebase onto $onto"
        elif push_too_old "$pushed"; then
          finding red managed-behind "$repo" "$name: differs from upstream, last push $(pushed_label "$pushed")"
        fi
        continue
      fi
    fi
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

# check_undeclared REPO ENTRY DEFAULT UPSTREAM_REPO UPSTREAM_DEFAULT PRS_FILE
# (forks): the default branch counts only when it is not declared; it is
# compared with the upstream default branch (the sync moves it there).
check_undeclared() {
  local repo=$1 entry=$2 default=$3 up=$4 updef=$5 prs=$6 found branch n
  found=$(undeclared_branches branch-undeclared "$repo" "$up" "$updef" \
    "$(jq -c '[.branches[].name]' <<<"$entry")" "$prs" "$default") || true
  while IFS=$'\t' read -r branch n; do
    [[ -z $branch ]] || finding red branch-undeclared "$repo" "$branch: $n own commits, not declared in repos.yml"
  done <<<"$found"
}

# mirror_undeclared REPO ENTRY DEFAULT UPSTREAM_DEFAULT TB UB SRC: the rule
# of check_undeclared for a mirror, compared in the mirror itself. The default
# branch and the followed branches (the sync moves them) count own commits
# against UPSTREAM_DEFAULT (default) or the upstream branch of the same name;
# when the upstream commit is not in the mirror, they are left to
# managed-behind. Any other branch is not synced, so its copy of an upstream
# branch may be stale and its commits cannot be told apart from own ones: it
# is no finding when its tip is the sha of an upstream ref (SRC: the upstream
# "<ref> <sha>" lines), else it is compared with the mirror's own default
# branch and is info when it is ahead.
mirror_undeclared() {
  local repo=$1 entry=$2 default=$3 updef=$4 tb=$5 ub=$6 src=$7
  local list branch sha usha moved uri body n rc
  json_out branch-undeclared "$repo" list -r --argjson e "$entry" --arg def "$default" --arg updef "$updef" \
    --slurpfile u "$ub" --rawfile s "$src" '
    ($u[0] | map({key: .name, value: .sha}) | from_entries) as $usha |
    [$s | split("\n")[] | split(" ") | select(length == 2) | .[1]] as $ushas |
    [$e.branches[].name] as $decl |
    .[] | select(.name | IN($decl[]) | not) | .name as $n |
    ($n == $def or any($e.follow // [] | .[]; . as $re | $n | test("^(?:" + $re + ")$"))) as $moved |
    (if $n != $def and $usha[$n] then $n else $updef end) as $base |
    select($moved or (.sha | IN($ushas[]) | not)) |
    [$n, .sha, ($usha[$base] // "-"), $moved, ($n | @uri)] | @tsv' "$tb" || return 0
  while IFS=$'\t' read -r branch sha usha moved uri; do
    [[ -n $branch ]] || continue
    if [[ $moved != true ]]; then
      rc=0
      mirror_compare "$repo" "$(jq -rn --arg d "$default" '$d | @uri')" "$uri" body branch-undeclared || rc=$?
      ((rc == 0)) || continue
      json_out branch-undeclared "$repo" n -r '.ahead_by // 0' <<<"$body" || continue
      ((n == 0)) ||
        finding info branch-undeclared "$repo" "$branch: differs from upstream, not followed (own commits or a stale upstream copy)"
      continue
    fi
    [[ $usha != - && $sha != "$usha" ]] || continue
    rc=0
    mirror_compare "$repo" "$usha" "$sha" body branch-undeclared || rc=$?
    # 3: the upstream commit is not in the mirror yet, left to managed-behind
    ((rc == 0)) || continue
    json_out branch-undeclared "$repo" n -r '.ahead_by // 0' <<<"$body" || continue
    ((n == 0)) || finding red branch-undeclared "$repo" "$branch: $n own commits, not declared in repos.yml"
  done <<<"$list"
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

# check_fork REPO ENTRY DEFAULT PUSHED PRS_FILE TMPDIR
check_fork() {
  local repo=$1 entry=$2 default=$3 pushed=$4 prs=$5 tmp=$6 up updef body contrib='[]' pulls=0
  up=$(jq -r .upstream_repo <<<"$entry")
  if open_pulls "$repo" "$up" "$prs" contrib; then
    pulls=1
  fi
  if [[ $(jq -r .tags <<<"$entry") == true ]] &&
    read_refs "$repo" "$(jq -r .upstream <<<"$entry")" "$PRIVATE" "$tmp/src" "$tmp/tgt"; then
    check_tags "$repo" "$pushed" "$tmp/src" "$tmp/tgt"
  fi
  body=$(fetch managed-behind "$repo" "repos/$up") || return 0
  json_out managed-behind "$repo" updef -r '.default_branch // empty' <<<"$body" || return 0
  if [[ -z $updef ]]; then
    parse_failed managed-behind "$repo"
    return 0
  fi
  paged managed-behind "$repo" "repos/$repo/branches?per_page=100" '{name, sha: .commit.sha}' "$tmp/tb" || return 0
  if [[ $(jq -r '.follow | length' <<<"$entry") -gt 0 ]]; then
    paged managed-behind "$repo" "repos/$up/branches?per_page=100" '{name}' "$tmp/ub" || return 0
  else
    echo '[]' >"$tmp/ub"
  fi
  check_branches "$repo" "$entry" "$default" "$up" "$updef" "$contrib" "$tmp/tb" "$tmp/ub" "$pushed"
  ((pulls == 0)) || check_undeclared "$repo" "$entry" "$default" "$up" "$updef" "$prs"
}

# check_mirror REPO ENTRY DEFAULT PUSHED TMPDIR: the upstream is not on
# github.com, so its refs come from git ls-remote and comparisons run in the
# mirror. A mirror has no upstream pull requests (no contribution branches).
check_mirror() {
  local repo=$1 entry=$2 default=$3 pushed=$4 tmp=$5 upstream updef
  upstream=$(jq -r .upstream <<<"$entry")
  read_refs "$repo" "$upstream" "$PRIVATE" "$tmp/src" "$tmp/tgt" || return 0
  [[ $(jq -r .tags <<<"$entry") != true ]] || check_tags "$repo" "$pushed" "$tmp/src" "$tmp/tgt"
  if ! updef=$(remote_head "$upstream") || [[ -z $updef ]]; then
    finding red check-failed "$repo" "managed-behind: cannot read the upstream default branch"
    return 0
  fi
  heads_json "$tmp/tgt" >"$tmp/tb"
  heads_json "$tmp/src" >"$tmp/ub"
  check_branches "$repo" "$entry" "$default" "" "$updef" '[]' "$tmp/tb" "$tmp/ub" "$pushed"
  mirror_undeclared "$repo" "$entry" "$default" "$updef" "$tmp/tb" "$tmp/ub" "$tmp/src"
}

# check_repo REPO ENTRY PRS_FILE (a temporary file for the open pulls)
check_repo() {
  local repo=$1 entry=$2 prs=$3 info fields default pushed tmp
  repo_info "$repo" info || return 0
  json_out managed-missing "$repo" fields -r '[.default_branch, .private, .pushed_at] | @tsv' <<<"$info" || return 0
  IFS=$'\t' read -r default PRIVATE pushed <<<"$fields"
  check_settings "$repo" "$(jq -c .settings <<<"$entry")" "$info"
  tmp=$(mktemp -d)
  if [[ $(jq -r .kind <<<"$entry") == fork ]]; then
    check_fork "$repo" "$entry" "$default" "$pushed" "$prs" "$tmp"
  else
    check_mirror "$repo" "$entry" "$default" "$pushed" "$tmp"
  fi
  rm -rf "$tmp"
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
