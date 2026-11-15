#!/usr/bin/env bash
# Settings and ruleset checks for central repositories: settings-merge,
# settings-alerts, settings-pvr, settings-actions, ruleset-main, ruleset-tags
# (expected values: README "Set up a new repository", steps 6 and 7).
# Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

# report CHECK REPO PROBLEMS: one red finding when PROBLEMS is not empty.
report() {
  [[ -z $3 ]] || finding red "$1" "$2" "$3"
}

# check_json CHECK REPO PATH PROGRAM [JQ_ARGS...] reads PATH and reports what
# PROGRAM (which prints the problems joined by "; ") finds.
check_json() {
  local check=$1 repo=$2 body problems program=$4
  body=$(fetch "$check" "$repo" "$3") || return 0
  shift 4
  json_out "$check" "$repo" problems -r "$@" "$program" <<<"$body" || return 0
  report "$check" "$repo" "$problems"
}

# shellcheck disable=SC2016 # jq programs, $vars are jq variables
# check_merge REPO reads the merge settings with GraphQL: the REST repository
# answers null for them to an app token without write access.
MERGE_QUERY='query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    deleteBranchOnMerge squashMergeCommitTitle
  }
}'
check_merge() {
  local body problems
  body=$(fetch settings-merge "$1" graphql -f query="$MERGE_QUERY" \
    -f owner="${1%%/*}" -f name="${1#*/}") || return 0
  json_out settings-merge "$1" problems -r \
    '.data.repository | if . == null then error("no repository") else . end |
     {allow_merge_commit: .mergeCommitAllowed,
      allow_squash_merge: .squashMergeAllowed,
      allow_rebase_merge: .rebaseMergeAllowed,
      delete_branch_on_merge: .deleteBranchOnMerge,
      squash_merge_commit_title: .squashMergeCommitTitle} as $r |
     {allow_merge_commit: false, allow_squash_merge: true,
       allow_rebase_merge: true, delete_branch_on_merge: true,
       squash_merge_commit_title: "PR_TITLE"} | to_entries |
     map(select($r[.key] != .value) |
       "\(.key): got \($r[.key] | tojson), want \(.value | tojson)") | join("; ")' \
    <<<"$body" || return 0
  report settings-merge "$1" "$problems"
}

check_actions() {
  check_json settings-actions "$1" "repos/$1/actions/permissions/workflow" \
    '. as $r | {default_workflow_permissions: "read",
       can_approve_pull_request_reviews: false} | to_entries |
     map(select($r[.key] != .value) |
       "\(.key): got \($r[.key] | tojson), want \(.value | tojson)") | join("; ")'
}

# check_alerts REPO: the endpoint answers 204 when on and 404
# "Vulnerability alerts are disabled." when off (a red setting, not an n/a).
check_alerts() {
  local repo=$1 errf err line
  errf=$(mktemp)
  if gh api "repos/$repo/vulnerability-alerts" >/dev/null 2>"$errf"; then
    rm -f "$errf"
    return 0
  fi
  err=$(<"$errf")
  line=$(err_line "$errf")
  rm -f "$errf"
  if [[ $err == *'Vulnerability alerts are disabled.'* ]]; then
    finding red settings-alerts "$repo" "Dependabot alerts are off"
    return 0
  fi
  finding red check-failed "$repo" "settings-alerts: $line"
}

# check_pvr REPO PRIVATE: the endpoint answers a generic 404 for private
# repositories, so those are skipped without a call.
check_pvr() {
  local repo=$1
  if [[ $2 == true ]]; then
    finding skip settings-pvr "$repo" "private repository"
    return 0
  fi
  check_json settings-pvr "$repo" "repos/$repo/private-vulnerability-reporting" \
    'if .enabled == true then "" else "enabled: got \(.enabled | tojson), want true" end'
}

# Problems of a ruleset detail on stdin; $kind is main or tags. Prints them
# joined by "; ".
RULESET_PROBLEMS='
  def want(field; got; want):
    if got == want then empty
    else "\(field): got \(got | tojson), want \(want | tojson)" end;
  . as $r |
  ($r.rules // [] | map(.type)) as $types |
  ($r.conditions.ref_name // {}) as $ref |
  ([
    want("target"; $r.target; (if $kind == "main" then "branch" else "tag" end)),
    want("enforcement"; $r.enforcement; "active"),
    want("bypass_actors"; ($r.bypass_actors // [] | length); 0),
    want("include"; $ref.include; (if $kind == "main" then ["~DEFAULT_BRANCH"] else ["refs/tags/v*"] end)),
    (if $kind == "tags" then want("exclude"; $ref.exclude; ["refs/tags/v*-next", "refs/tags/v*-pr.*"]) else empty end),
    (if $kind == "tags" then want("rules"; $types; ["update"])
     else
       (("deletion", "non_fast_forward") as $t |
        if $types | index($t) then empty else "rule \($t): missing" end),
       (([$r.rules[] | select(.type == "pull_request")] | first) as $pr |
        if $pr == null then "rule pull_request: missing"
        else want("rule pull_request.allowed_merge_methods";
                  ($pr.parameters.allowed_merge_methods // [] | sort); ["rebase", "squash"]) end),
       (([$r.rules[] | select(.type == "required_status_checks")] | first) as $sc |
        if $sc == null then "rule required_status_checks: missing"
        elif ($sc.parameters.required_status_checks // [] | map(.context) | index("pr / check")) then empty
        else "rule required_status_checks: context pr / check missing" end)
     end)
  ] | join("; "))'

# check_rulesets REPO
check_rulesets() {
  local repo=$1 list rc=0 kind check name missing id
  list=$(fetch ruleset-main "$repo" "repos/$repo/rulesets") || rc=$?
  if [[ $rc -eq 2 ]]; then
    finding skip ruleset-tags "$repo" "rulesets not available"
    return 0
  fi
  [[ $rc -eq 0 ]] || return 0
  for kind in main tags; do
    check=ruleset-$kind
    if [[ $kind == main ]]; then
      name=main
      missing="ruleset main missing"
    else
      name="release tags"
      missing="ruleset release tags missing"
    fi
    json_out "$check" "$repo" id -r --arg n "$name" \
      '[.[] | select(.name == $n) | .id] | first // empty' <<<"$list" || continue
    if [[ -z $id ]]; then
      finding red "$check" "$repo" "$missing"
      continue
    fi
    check_json "$check" "$repo" "repos/$repo/rulesets/$id" \
      "$RULESET_PROBLEMS" --arg kind "$kind"
  done
}

main() {
  local repos repo private
  if ! repos=$(jq -r '.[] | select(.central) | [.name, (.private | tostring)] | @tsv' "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "settings checks: cannot parse inventory"
    return 0
  fi
  while IFS=$'\t' read -r repo private; do
    [[ -n $repo ]] || continue
    check_merge "$repo"
    check_alerts "$repo"
    check_pvr "$repo" "$private"
    check_actions "$repo"
    check_rulesets "$repo"
  done <<<"$repos"
}

main
