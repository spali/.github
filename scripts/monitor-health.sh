#!/usr/bin/env bash
# Health checks for owned, non-fork, non-mirror repositories: main-red,
# renovate-stale, workflow-disabled, dependabot-alert, code-scanning-alert.
# Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

# check_main_red REPO BRANCH: the latest completed run per workflow on the
# default branch (pull request events ignored) must not have failed.
check_main_red() {
  local repo=$1 body failed line
  body=$(fetch main-red "$repo" \
    "repos/$repo/actions/runs?branch=$2&status=completed&per_page=100") || return 0
  json_out main-red "$repo" failed -r '
    [.workflow_runs // [] | .[] |
      select(.event != "pull_request" and .event != "pull_request_target") |
      {workflow_id, name, conclusion, html_url, created_at, event}] |
    group_by(.workflow_id) | map(max_by(.created_at)) | .[] |
    select(.conclusion == "failure" or .conclusion == "timed_out" or .conclusion == "startup_failure") |
    "\(.name): \(.conclusion) \(.html_url)"' <<<"$body" || return 0
  while IFS= read -r line; do
    [[ -z $line ]] || finding red main-red "$repo" "$line"
  done <<<"$failed"
}

check_renovate() {
  local repo=$1 tmp pr n title created d
  tmp=$(mktemp)
  if paged renovate-stale "$repo" "repos/$repo/pulls?state=open&per_page=100" \
    '{number, title, created_at, user: {login: .user.login}}' "$tmp"; then
    if pr=$(jq -r '.[] | select(.user.login == "renovate[bot]") |
        [.number, .created_at, .title] | @tsv' "$tmp" 2>/dev/null); then
      while IFS=$'\t' read -r n created title; do
        [[ -n $n ]] || continue
        d=$(days_since "$created")
        if ((d > 7)); then
          finding red renovate-stale "$repo" "#$n $title ($d days)"
        fi
      done <<<"$pr"
    else
      parse_failed renovate-stale "$repo"
    fi
  fi
  rm -f "$tmp"
}

check_workflows() {
  local repo=$1 body found line
  body=$(fetch workflow-disabled "$repo" "repos/$repo/actions/workflows?per_page=100") || return 0
  disabled_workflows workflow-disabled "$repo" found <<<"$body" || return 0
  while IFS= read -r line; do
    [[ -z $line ]] || finding red workflow-disabled "$repo" "$line"
  done <<<"$found"
}

# check_alerts CHECK REPO PATH SEVERITY_JQ: SEVERITY_JQ maps one alert to
# critical, high, medium or low. Red finding for critical/high, info for
# medium/low, zero counts omitted.
check_alerts() {
  local check=$1 repo=$2 tmp red info
  tmp=$(mktemp)
  if paged "$check" "$repo" "$3" "$4" "$tmp"; then
    if json_out "$check" "$repo" red -r '
         [.[] | select(. == "critical" or . == "high")] |
         [("critical", "high") as $s | (map(select(. == $s)) | length) as $n |
          select($n > 0) | "\($n) \($s)"] | join(", ")' "$tmp" &&
      json_out "$check" "$repo" info -r '
         [.[] | select(. == "medium" or . == "low")] |
         [("medium", "low") as $s | (map(select(. == $s)) | length) as $n |
          select($n > 0) | "\($n) \($s)"] | join(", ")' "$tmp"; then
      [[ -z $red ]] || finding red "$check" "$repo" "$red"
      [[ -z $info ]] || finding info "$check" "$repo" "$info"
    fi
  fi
  rm -f "$tmp"
}

main() {
  local repos repo branch
  if ! repos=$(jq -r --slurpfile c "$CONFIG" '
      ([$c[0].mirrors // [] | .[].target]) as $m |
      .[] | select(.fork == false and ([.name] | inside($m) | not)) |
      [.name, .default_branch] | @tsv' "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "health checks: cannot parse inventory"
    return 0
  fi
  while IFS=$'\t' read -r repo branch; do
    [[ -n $repo ]] || continue
    check_main_red "$repo" "$branch"
    check_renovate "$repo"
    check_workflows "$repo"
    check_alerts dependabot-alert "$repo" \
      "repos/$repo/dependabot/alerts?state=open&per_page=100" \
      '((.security_advisory.severity // "low") | if IN("critical", "high", "medium", "low") then . else "low" end)'
    check_alerts code-scanning-alert "$repo" \
      "repos/$repo/code-scanning/alerts?state=open&per_page=100" \
      '(.rule.security_severity_level // ({error: "high", warning: "medium", note: "low"}[.rule.severity // ""]) // "low")'
  done <<<"$repos"
}

main
