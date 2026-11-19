#!/usr/bin/env bash
# Checks of the forks and mirrors (fork_entries: the entries of `forks:` and
# the inventory forks). Synced ones: fork-missing, fork-settings, fork-behind
# (branches and, unless tags is false, tags), rebase-pending; pinned ones are
# not synced and get none of these. All: settings-fork-approval, funding, and forks on
# GitHub stale-branch (pull requests upstream), fork-delete-candidate and
# contribution-stale. sync-failed runs once, in monitor-lists.sh.
# Writes findings, and the kind of each fork or mirror to FORK_KINDS (see
# record_kind). Env: FINDINGS INVENTORY CONFIG (file paths), optional
# FORK_KINDS (file path).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/forks-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/forks-lib.sh"

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
# fork-missing (404) or check-failed finding.
repo_info() {
  local errf body
  errf=$(mktemp)
  if body=$(gh api "repos/$1" 2>"$errf"); then
    rm -f "$errf"
    printf -v "$2" '%s' "$body"
    return 0
  fi
  if grep -qF '(HTTP 404)' "$errf"; then
    finding red fork-missing "$1" "repository does not exist (the sync creates a fork)"
  else
    finding red check-failed "$1" "fork-missing: $(err_line "$errf")"
  fi
  rm -f "$errf"
  return 1
}

# check_settings REPO SETTINGS_JSON INFO: the five has_* of the repository
# and Actions enabled must match the declared settings.
check_settings() {
  local repo=$1 want=$2 info=$3 body diff
  body=$(fetch fork-settings "$repo" "repos/$repo/actions/permissions") || return 0
  json_out fork-settings "$repo" diff -rs --argjson want "$want" '
    (.[0] + {actions: .[1].enabled}) as $have |
    [$want | to_entries[] | select($have[.key] != .value) |
      "\(.key) is \($have[.key]), expected \(.value)"] | join("; ")' <<<"$info"$'\n'"$body" || return 0
  [[ -z $diff ]] || finding red fork-settings "$repo" "$diff"
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
    finding red check-failed "$repo" "fork-behind: cannot read upstream"
    return 1
  fi
  if [[ $private == true ]]; then
    api_refs "$repo" "$tgt" fork-behind || return 1
  elif ! ls_remote "https://github.com/$repo.git" "$tgt"; then
    finding red check-failed "$repo" "fork-behind: cannot read target"
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
    finding red fork-behind "$repo" "$n tags differ, last push $(pushed_label "$pushed")"
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
# auto (and followed): missing commits older than 48 h are fork-behind;
# manual: rebase-pending. A declared or followed branch missing in the target
# is fork-behind. The contribution branches CONTRIB (JSON array of names)
# are left out: the sync never writes them.
check_branches() {
  local repo=$1 entry=$2 default=$3 up=$4 updef=$5 contrib=$6 tb=$7 ub=$8 pushed=$9
  local list name sha onto uri usha rebase body n date rc
  json_out fork-behind "$repo" list -r --argjson e "$entry" --arg def "$default" --arg updef "$updef" \
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
      finding red fork-behind "$repo" "$name: missing in the target"
      continue
    fi
    if [[ -n $up ]]; then
      body=$(fetch fork-behind "$repo" "repos/$up/compare/$sha...$uri") || continue
    else
      if [[ $usha == - ]]; then
        finding red fork-behind "$repo" "$name: onto $onto missing upstream"
        continue
      fi
      [[ $sha != "$usha" ]] || continue
      rc=0
      mirror_compare "$repo" "$sha" "$usha" body fork-behind || rc=$?
      ((rc != 1)) || continue
      if ((rc == 3)); then
        if [[ $rebase == manual ]]; then
          finding info rebase-pending "$repo" "$name: upstream commits to rebase onto $onto"
        elif push_too_old "$pushed"; then
          finding red fork-behind "$repo" "$name: differs from upstream, last push $(pushed_label "$pushed")"
        fi
        continue
      fi
    fi
    json_out fork-behind "$repo" n -r '.ahead_by // 0' <<<"$body" || continue
    ((n > 0)) || continue
    if [[ $rebase == manual ]]; then
      finding info rebase-pending "$repo" "$name: $n upstream commits to rebase onto $onto"
      continue
    fi
    json_out fork-behind "$repo" date -r '.commits[0].commit.committer.date // empty' <<<"$body" || continue
    if [[ -z $date ]]; then
      parse_failed fork-behind "$repo"
    elif too_old "$date"; then
      finding red fork-behind "$repo" "$name: $n upstream commits missing, oldest from $date"
    fi
  done <<<"$list"
}

# PAST_QUERY: the pull requests of an author in a repository, merged and
# closed without merge (two searches, counts only).
PAST_QUERY='query($merged: String!, $closed: String!) {
  merged: search(type: ISSUE, first: 0, query: $merged) { issueCount }
  closed: search(type: ISSUE, first: 0, query: $closed) { issueCount } }'

# past_pulls REPO PARENT prints the past pull requests of the owner of REPO
# in PARENT as one JSON object {merged, closed} (counts), or {merged: null,
# closed: null} when they are not available (a check-failed finding).
past_pulls() {
  local repo=$1 body counts q="repo:$2 is:pr author:${1%%/*}"
  if body=$(fetch fork-delete-candidate "$repo" graphql -f query="$PAST_QUERY" \
    -f merged="$q is:merged" -f closed="$q is:closed is:unmerged") &&
    json_out fork-delete-candidate "$repo" counts -c '.data
      | {merged: .merged.issueCount, closed: .closed.issueCount}
      | if (.merged | type) == "number" and (.closed | type) == "number" then . else error("no counts") end' <<<"$body"; then
    printf '%s\n' "$counts"
  else
    echo '{"merged":null,"closed":null}'
  fi
}

# record_kind REPO KIND PINNED OWN PULLS_JSON UPSTREAM [PAST_JSON] appends the
# kind of a fork or mirror to $FORK_KINDS (if set) as one JSON line {repo,
# kind (contribution, customized, unchanged, or unknown when the own commits
# are not known: a mirror), pinned, own (own commits on the default branch,
# null when not known), merged and closed (past upstream pull requests of the
# owner, merged and closed without merge; null when not known: a mirror),
# pulls (numbers of the open upstream pull requests from it), upstream}: the
# report lists them.
record_kind() {
  local past=${7:-}
  [[ -n ${FORK_KINDS:-} ]] || return 0
  [[ -n $past ]] || past='{"merged":null,"closed":null}'
  jq -cn --arg repo "$1" --arg kind "$2" --argjson pinned "$3" --argjson own "$4" \
    --argjson pulls "$5" --arg upstream "$6" \
    --argjson past "$past" \
    '{repo: $repo, kind: $kind, pinned: $pinned, own: $own, merged: $past.merged, closed: $past.closed,
      pulls: $pulls, upstream: $upstream}' >>"$FORK_KINDS"
}

# fork_kind REPO BRANCH PARENT PARENT_BRANCH PRS_FILE PINNED prints the number
# of own commits of the default BRANCH against PARENT_BRANCH and records the
# kind of the fork: contribution (an open upstream pull request from it, in
# PRS_FILE), customized (own commits) or unchanged. Prints nothing when the
# comparison is not available (a check-failed finding on an API error).
fork_kind() {
  local repo=$1 branch=$2 parent=$3 pbranch=$4 prs=$5 pinned=$6 body n pulls past kind=unchanged
  body=$(fetch fork-delete-candidate "$repo" \
    "repos/$parent/compare/$(uri "$pbranch")...${repo%%/*}:${repo#*/}:$(uri "$branch")") || return 0
  json_out fork-delete-candidate "$repo" n -r '.ahead_by // "x"' <<<"$body" || return 0
  [[ $n =~ ^[0-9]+$ ]] || return 0
  json_out fork-delete-candidate "$repo" pulls -c --arg r "$repo" \
    '[.[] | select(.head_repo | ascii_downcase == ($r | ascii_downcase)) | .number] | unique' "$prs" || return 0
  if [[ $pulls != '[]' ]]; then
    kind=contribution
  elif ((n > 0)); then
    kind=customized
  fi
  [[ -z ${FORK_KINDS:-} ]] || past=$(past_pulls "$repo" "$parent")
  record_kind "$repo" "$kind" "$pinned" "$n" "$pulls" "$parent" "${past:-}"
  printf '%s\n' "$n"
}

# check_delete_candidate REPO OWN PARENT PRS_FILE FB_FILE: no own commits
# (OWN, from fork_kind) on the default branch, no open upstream PR from the
# fork, and every fork branch also exists upstream or was the head of a closed
# or merged upstream PR from the fork (contribution done). PRS_FILE: the open
# upstream pulls of the fork branches, [{head_repo, head_ref, number,
# created_at, html_url}]; FB_FILE: the fork branches, [{name}].
check_delete_candidate() {
  local repo=$1 n=$2 parent=$3 prs=$4 fb=$5 mine pb cl extra
  [[ $n == 0 ]] || return 0
  json_out fork-delete-candidate "$repo" mine --arg r "$repo" \
    '[.[] | select(.head_repo | ascii_downcase == ($r | ascii_downcase))] | length' "$prs" || return 0
  [[ $mine == 0 ]] || return 0
  pb=$(mktemp)
  cl=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$pb' '$cl'; trap - RETURN" RETURN
  paged fork-delete-candidate "$repo" "repos/$parent/branches?per_page=100" '{name}' "$pb" || return 0
  json_out fork-delete-candidate "$repo" extra --slurpfile p "$pb" \
    '([$p[0][].name]) as $pn | [.[] | select(.name as $n | $pn | index($n) | not) | .name]' "$fb" || return 0
  if [[ $extra != '[]' ]]; then
    head_pulls fork-delete-candidate "$repo" "$parent" closed "$extra" "$cl" || return 0
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
  paged contribution-stale "$repo" "repos/$repo/branches?per_page=100" '{name}' "$tb" || return 1
  head_pulls contribution-stale "$repo" "$up" open "$(jq -c 'map(.name)' "$tb")" "$prs" || return 1
  json_out contribution-stale "$repo" "$4" -c --arg r "$repo" \
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
  body=$(fetch fork-behind "$repo" "repos/$up") || return 0
  json_out fork-behind "$repo" updef -r '.default_branch // empty' <<<"$body" || return 0
  if [[ -z $updef ]]; then
    parse_failed fork-behind "$repo"
    return 0
  fi
  paged fork-behind "$repo" "repos/$repo/branches?per_page=100" '{name, sha: .commit.sha}' "$tmp/tb" || return 0
  check_stale_branches "$repo" "$default" "$up" "$tmp/tb"
  if [[ $(jq -r '.follow | length' <<<"$entry") -gt 0 ]]; then
    paged fork-behind "$repo" "repos/$up/branches?per_page=100" '{name}' "$tmp/ub" || return 0
  else
    echo '[]' >"$tmp/ub"
  fi
  check_branches "$repo" "$entry" "$default" "$up" "$updef" "$contrib" "$tmp/tb" "$tmp/ub" "$pushed"
  if ((pulls)); then
    check_delete_candidate "$repo" "$(fork_kind "$repo" "$default" "$up" "$updef" "$prs" false)" "$up" "$prs" "$tmp/tb"
    check_contributions "$repo" "$prs"
  fi
}

# check_pinned_fork REPO ENTRY DEFAULT PRS_FILE TMPDIR: a pinned fork is not
# synced: only its branches of merged pull requests, whether it is still
# needed and its old pull requests upstream.
check_pinned_fork() {
  local repo=$1 entry=$2 default=$3 prs=$4 tmp=$5 up updef body contrib
  up=$(jq -r .upstream_repo <<<"$entry")
  paged fork-delete-candidate "$repo" "repos/$repo/branches?per_page=100" '{name, sha: .commit.sha}' "$tmp/tb" || return 0
  check_stale_branches "$repo" "$default" "$up" "$tmp/tb"
  open_pulls "$repo" "$up" "$prs" contrib || return 0
  body=$(fetch fork-delete-candidate "$repo" "repos/$up") || return 0
  json_out fork-delete-candidate "$repo" updef -r '.default_branch // empty' <<<"$body" || return 0
  if [[ -z $updef ]]; then
    parse_failed fork-delete-candidate "$repo"
    return 0
  fi
  check_delete_candidate "$repo" "$(fork_kind "$repo" "$default" "$up" "$updef" "$prs" true)" "$up" "$prs" "$tmp/tb"
  check_contributions "$repo" "$prs"
}

# check_mirror REPO ENTRY DEFAULT PUSHED TMPDIR: the upstream is not on
# github.com, so its refs come from git ls-remote and comparisons run in the
# mirror. A mirror has no upstream pull requests (no contribution branches)
# and is never a delete candidate.
check_mirror() {
  local repo=$1 entry=$2 default=$3 pushed=$4 tmp=$5 upstream updef
  upstream=$(jq -r .upstream <<<"$entry")
  read_refs "$repo" "$upstream" "$PRIVATE" "$tmp/src" "$tmp/tgt" || return 0
  [[ $(jq -r .tags <<<"$entry") != true ]] || check_tags "$repo" "$pushed" "$tmp/src" "$tmp/tgt"
  if ! updef=$(remote_head "$upstream") || [[ -z $updef ]]; then
    finding red check-failed "$repo" "fork-behind: cannot read the upstream default branch"
    return 0
  fi
  heads_json "$tmp/tgt" >"$tmp/tb"
  heads_json "$tmp/src" >"$tmp/ub"
  check_branches "$repo" "$entry" "$default" "" "$updef" '[]' "$tmp/tb" "$tmp/ub" "$pushed"
  record_kind "$repo" unknown false null '[]' "$upstream"
}

# with_upstream ENTRY INFO prints ENTRY with the parent of the repository
# (INFO: GET repos/REPO) as upstream when it has none; fails when it is no
# fork on GitHub either.
with_upstream() {
  local parent
  if [[ $(jq -r '.upstream // ""' <<<"$1") != "" ]]; then
    printf '%s\n' "$1"
    return 0
  fi
  parent=$(jq -r 'select(.fork == true) | .parent.full_name // empty' <<<"$2")
  [[ -n $parent ]] || return 1
  jq -c --arg p "$parent" '.upstream = "https://github.com/\($p)" | .upstream_repo = $p | .kind = "fork"' <<<"$1"
}

# check_repo REPO ENTRY PRS_FILE (a temporary file for the open pulls)
check_repo() {
  local repo=$1 entry=$2 prs=$3 info fields default pushed tmp pinned
  repo_info "$repo" info || return 0
  json_out fork-missing "$repo" fields -r '[.default_branch, .private, .pushed_at] | @tsv' <<<"$info" || return 0
  IFS=$'\t' read -r default PRIVATE pushed <<<"$fields"
  pinned=$(jq -r .pinned <<<"$entry")
  if [[ $(jq -r '.archived // false' <<<"$info") == true ]]; then
    [[ $pinned == true ]] ||
      finding red fork-settings "$repo" 'archived but synced: pin it or remove its entry from `forks:`'
    return 0
  fi
  check_fork_approval "$repo" "$PRIVATE"
  check_funding "$repo" fork
  if ! entry=$(with_upstream "$entry" "$info"); then
    finding red check-failed "$repo" 'fork-behind: no upstream: not a fork on GitHub, set upstream under `forks:`'
    return 0
  fi
  tmp=$(mktemp -d)
  if [[ $pinned == true ]]; then
    if [[ $(jq -r .kind <<<"$entry") == fork ]]; then
      check_pinned_fork "$repo" "$entry" "$default" "$prs" "$tmp"
    else
      record_kind "$repo" unknown true null '[]' "$(jq -r .upstream <<<"$entry")"
    fi
  else
    check_settings "$repo" "$(jq -c .settings <<<"$entry")" "$info"
    if [[ $(jq -r .kind <<<"$entry") == fork ]]; then
      check_fork "$repo" "$entry" "$default" "$pushed" "$prs" "$tmp"
    else
      check_mirror "$repo" "$entry" "$default" "$pushed" "$tmp"
    fi
  fi
  rm -rf "$tmp"
}

main() {
  local entries entry repo prs
  if ! entries=$(fork_entries "$CONFIG" "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "fork checks: cannot parse the config or inventory"
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
