#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  FINDINGS="$BATS_TEST_TMPDIR/f.jsonl"
  INVENTORY="$BATS_TEST_TMPDIR/inventory.json"
  CONFIG="$BATS_TEST_TMPDIR/config.json"
  export FINDINGS INVENTORY CONFIG
  : >"$FINDINGS"
  echo '{"managed":[]}' >"$CONFIG"
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-14T12:00:00Z +%s)
  unset GITHUB_WORKFLOW_REF
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-health.sh"
  jq -n '[{name: "spali/a", fork: false, default_branch: "main"}]' >"$INVENTORY"
}

# Compliant defaults for everything the script reads; tests register their own
# answers first (first match wins).
RUNS='*repos/spali/a/actions/runs?branch=main&status=completed&per_page=100'
PRS='*repos/spali/a/pulls?state=open&per_page=100 --paginate'
WFS='*repos/spali/a/actions/workflows?per_page=100'
DEP='*repos/spali/a/dependabot/alerts?state=open&per_page=100 --paginate'
CS='*repos/spali/a/code-scanning/alerts?state=open&per_page=100 --paginate'
ISS='*repos/spali/a/issues?state=open&per_page=100 --paginate'

# run_json GLOB JQ_EXPRESSION registers a response built by jq -n.
respond_jq() { jq -nc "$2" | gh_respond "$1" -; }

run_script() {
  respond_jq "$RUNS" '{workflow_runs: []}'
  respond_jq "$PRS" '[]'
  respond_jq "$WFS" '{workflows: []}'
  respond_jq "$DEP" '[]'
  respond_jq "$CS" '[]'
  respond_jq "$ISS" '[]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].level' "$FINDINGS"; }

# run_entry ID CONCLUSION CREATED [EVENT [PATH]]
run_entry() {
  jq -nc --argjson id "$1" --arg c "$2" --arg t "$3" --arg e "${4:-push}" \
    --arg p "${5:-.github/workflows/wf$1.yml}" \
    '{workflow_id: $id, name: "wf\($id)", conclusion: $c, html_url: "https://x/\($id)/\($t)", created_at: $t, event: $e, path: $p}'
}

@test "compliant repo has no findings" {
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/a" ]
}

@test "latest run failed is red" {
  { run_entry 1 success 2026-11-10T00:00:00Z; run_entry 1 failure 2026-11-12T00:00:00Z; } |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 1 ]
  [ "$(level main-red)" = red ]
  [ "$(message main-red)" = "wf1: failure https://x/1/2026-11-12T00:00:00Z" ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "older failed run followed by success is fine" {
  { run_entry 1 failure 2026-11-10T00:00:00Z; run_entry 1 success 2026-11-12T00:00:00Z; } |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "main-red: one finding per failing workflow, pull request runs ignored" {
  {
    run_entry 1 timed_out 2026-11-12T00:00:00Z
    run_entry 2 startup_failure 2026-11-12T00:00:00Z
    run_entry 3 cancelled 2026-11-12T00:00:00Z
    run_entry 4 failure 2026-11-12T00:00:00Z pull_request
    run_entry 5 failure 2026-11-12T00:00:00Z pull_request_target
    run_entry 6 success 2026-11-12T00:00:00Z
  } | jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 2 ]
  [ "$(jq -s length "$FINDINGS")" -eq 2 ]
}

@test "renovate PR 8 days old is red, 6 days fine" {
  jq -nc '[
    {number: 7, title: "Update x", created_at: "2026-11-06T00:00:00Z", user: {login: "renovate[bot]"}},
    {number: 8, title: "Update y", created_at: "2026-11-08T12:00:00Z", user: {login: "renovate[bot]"}},
    {number: 9, title: "Human", created_at: "2026-10-01T00:00:00Z", user: {login: "spali"}}]' |
    gh_respond "$PRS" -
  run_script
  [ "$(count renovate-stale)" -eq 1 ]
  [ "$(level renovate-stale)" = red ]
  [ "$(message renovate-stale)" = "#7 Update x (8 days)" ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "disabled_inactivity is red" {
  jq -nc '{workflows: [
    {name: "Rebase Upstream", path: ".github/workflows/sync.yml", state: "disabled_inactivity"},
    {name: "CI", path: ".github/workflows/ci.yml", state: "active"},
    {name: "Manual", path: ".github/workflows/m.yml", state: "disabled_manually"}]}' |
    gh_respond "$WFS" -
  run_script
  [ "$(count workflow-disabled)" -eq 1 ]
  [ "$(level workflow-disabled)" = red ]
  [ "$(message workflow-disabled)" = "Rebase Upstream (.github/workflows/sync.yml) disabled by GitHub after 60 days of inactivity" ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "high alert is red, low alert is info" {
  jq -nc '[
    {security_advisory: {severity: "critical"}}, {security_advisory: {severity: "high"}},
    {security_advisory: {severity: "high"}}, {security_advisory: {severity: "low"}},
    {security_advisory: {severity: "medium"}}, {security_advisory: {severity: "medium"}},
    {security_advisory: {severity: "medium"}}]' | gh_respond "$DEP" -
  run_script
  [ "$(count dependabot-alert)" -eq 2 ]
  [ "$(level dependabot-alert 0)" = red ]
  [ "$(message dependabot-alert 0)" = "1 critical, 2 high" ]
  [ "$(level dependabot-alert 1)" = info ]
  [ "$(message dependabot-alert 1)" = "3 medium, 1 low" ]
}

@test "only low alerts give a single info finding" {
  jq -nc '[{security_advisory: {severity: "low"}}]' | gh_respond "$DEP" -
  run_script
  [ "$(count dependabot-alert)" -eq 1 ]
  [ "$(level dependabot-alert)" = info ]
  [ "$(message dependabot-alert)" = "1 low" ]
}

@test "alerts without a known severity count as low" {
  jq -nc '[{security_advisory: {severity: null}}, {security_advisory: {}}, {security_advisory: {severity: "weird"}}]' |
    gh_respond "$DEP" -
  run_script
  [ "$(count dependabot-alert)" -eq 1 ]
  [ "$(level dependabot-alert)" = info ]
  [ "$(message dependabot-alert)" = "3 low" ]
}

@test "code scanning severity falls back to rule.severity" {
  jq -nc '[
    {rule: {security_severity_level: "critical", severity: "note"}},
    {rule: {security_severity_level: null, severity: "error"}},
    {rule: {severity: "warning"}}, {rule: {severity: "note"}}]' | gh_respond "$CS" -
  run_script
  [ "$(count code-scanning-alert)" -eq 2 ]
  [ "$(level code-scanning-alert 0)" = red ]
  [ "$(message code-scanning-alert 0)" = "1 critical, 1 high" ]
  [ "$(level code-scanning-alert 1)" = info ]
  [ "$(message code-scanning-alert 1)" = "1 medium, 1 low" ]
}

@test "no code scanning analysis is skipped" {
  gh_fail '*spali/a/code-scanning/alerts*' 'gh: no analysis found (HTTP 404)'
  gh_fail '*spali/a/dependabot/alerts*' 'gh: Dependabot alerts are disabled for this repository. (HTTP 403)'
  run_script
  [ "$(level code-scanning-alert)" = skip ]
  [ "$(level dependabot-alert)" = skip ]
  [ "$(count check-failed)" -eq 0 ]
}

@test "an API failure is check-failed" {
  gh_fail '*spali/a/actions/workflows*' 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(level check-failed)" = red ]
}

@test "forks are out of scope" {
  jq -n '[
    {name: "spali/a", fork: false, default_branch: "main"},
    {name: "spali/fork", fork: true, default_branch: "main"}]' >"$INVENTORY"
  run_script
  run ! grep -q 'spali/fork' "$GH_LOG"
  grep -q 'spali/a/' "$GH_LOG"
}

@test "large payloads are handled" {
  head -c 250000 /dev/zero | tr '\0' x >"$BATS_TEST_TMPDIR/big"
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[
    {number: 7, title: "Update x", body: $big, created_at: "2026-11-01T00:00:00Z", user: {login: "renovate[bot]"}}]' |
    gh_respond "$PRS" -
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[
    {rule: {severity: "error", description: $big}}]' | gh_respond "$CS" -
  run_script
  [ "$(count renovate-stale)" -eq 1 ]
  [ "$(count code-scanning-alert)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}

# The monitor's own workflow in the calling repository must not turn the
# repository red because of the monitor's previous (failed) run.
@test "main-red skips the monitor's own workflow in the calling repository" {
  export GITHUB_WORKFLOW_REF='spali/a/.github/workflows/monitor.yml@refs/heads/main'
  run_entry 1 failure 2026-11-12T00:00:00Z schedule .github/workflows/monitor.yml |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 0 ]
}

@test "main-red still reports another failed workflow of the calling repository" {
  export GITHUB_WORKFLOW_REF='spali/a/.github/workflows/monitor.yml@refs/heads/main'
  { run_entry 1 failure 2026-11-12T00:00:00Z schedule .github/workflows/monitor.yml
    run_entry 2 failure 2026-11-12T00:00:00Z push .github/workflows/ci.yml; } |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 1 ]
  [[ "$(message main-red)" == wf2:* ]]
}

@test "main-red keeps the same path in a different repository" {
  export GITHUB_WORKFLOW_REF='spali/ctl/.github/workflows/monitor.yml@refs/heads/main'
  run_entry 1 failure 2026-11-12T00:00:00Z schedule .github/workflows/monitor.yml |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 1 ]
}

@test "main-red skips nothing when GITHUB_WORKFLOW_REF is unset" {
  run_entry 1 failure 2026-11-12T00:00:00Z schedule .github/workflows/monitor.yml |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 1 ]
}

@test "main-red: a run path with a ref suffix still matches the own workflow" {
  export GITHUB_WORKFLOW_REF='spali/a/.github/workflows/monitor.yml@refs/heads/main'
  run_entry 1 failure 2026-11-12T00:00:00Z schedule '.github/workflows/monitor.yml@refs/heads/main' |
    jq -s '{workflow_runs: .}' | gh_respond "$RUNS" -
  run_script
  [ "$(count main-red)" -eq 0 ]
}

@test "managed repositories are out of scope" {
  jq -n '[
    {name: "spali/a", fork: false, default_branch: "main"},
    {name: "spali/Managed", fork: false, default_branch: "main"}]' >"$INVENTORY"
  echo '{"managed":[{"repo":"spali/managed","upstream":"https://src.example/m.git"}]}' >"$CONFIG"
  run_script
  run ! grep -qi 'spali/managed' "$GH_LOG"
  grep -q 'spali/a/' "$GH_LOG"
}

# item NUMBER LOGIN CREATED [pr]: one entry of the open issues list.
item() {
  jq -nc --argjson n "$1" --arg u "$2" --arg t "$3" --arg pr "${4:-}" '
    {number: $n, created_at: $t, user: {login: $u, type: (if ($u | endswith("[bot]")) then "Bot" else "User" end)},
     html_url: "https://github.com/spali/a/\(if $pr == "" then "issues" else "pull" end)/\($n)"}
    + (if $pr == "" then {} else {pull_request: {url: "x"}} end)'
}

# post LOGIN TIME [TYPE]: one issue or review comment.
post() {
  jq -nc --arg u "$1" --arg t "$2" --arg ty "${3:-User}" '{created_at: $t, user: {login: $u, type: $ty}}'
}

comments() { gh_respond "*repos/spali/a/issues/$1/comments?per_page=100 --paginate" -; }

item_value() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].item' "$FINDINGS"; }

@test "unanswered: issue of another user without answer is red with its item" {
  item 5 other 2026-11-04T10:00:00Z | jq -s . | gh_respond "$ISS" -
  run_script
  [ "$(count unanswered)" -eq 1 ]
  [ "$(level unanswered)" = red ]
  [ "$(message unanswered)" = "issue #5 waits for an answer for 10 days: https://github.com/spali/a/issues/5" ]
  [ "$(item_value unanswered)" = 5 ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "unanswered: a young item is skipped without further calls" {
  item 5 other 2026-11-11T10:00:00Z | jq -s . | gh_respond "$ISS" -
  run_script
  [ "$(count unanswered)" -eq 0 ]
  run ! grep -q 'issues/5/' "$GH_LOG"
}

@test "unanswered: an item opened by the owner without other posts is fine" {
  item 5 spali 2026-10-01T10:00:00Z | jq -s . | gh_respond "$ISS" -
  run_script
  [ "$(count unanswered)" -eq 0 ]
}

@test "unanswered: a follow-up after the owner answered counts again" {
  item 5 other 2026-10-01T10:00:00Z | jq -s . | gh_respond "$ISS" -
  { post spali 2026-11-05T10:00:00Z; post other 2026-11-06T10:00:00Z; } | jq -s . | comments 5
  run_script
  [ "$(count unanswered)" -eq 1 ]
  [ "$(message unanswered)" = "issue #5 waits for an answer for 8 days: https://github.com/spali/a/issues/5" ]
}

@test "unanswered: the owner having the last word is fine even when old" {
  item 5 other 2026-09-01T10:00:00Z | jq -s . | gh_respond "$ISS" -
  { post other 2026-09-02T10:00:00Z; post spali 2026-09-03T10:00:00Z; } | jq -s . | comments 5
  run_script
  [ "$(count unanswered)" -eq 0 ]
}

@test "unanswered: bot comments are ignored" {
  item 5 other 2026-11-04T10:00:00Z | jq -s . | gh_respond "$ISS" -
  { post helper 2026-11-12T10:00:00Z Bot; post 'x[bot]' 2026-11-13T10:00:00Z; } | jq -s . | comments 5
  run_script
  [ "$(count unanswered)" -eq 1 ]
  [ "$(message unanswered)" = "issue #5 waits for an answer for 10 days: https://github.com/spali/a/issues/5" ]
}

@test "unanswered: an item opened by a bot is skipped without further calls" {
  { item 5 'renovate[bot]' 2026-10-01T10:00:00Z pr
    item 6 helper 2026-10-01T10:00:00Z | jq -c '.user.type = "Bot"'; } | jq -s . | gh_respond "$ISS" -
  run_script
  [ "$(count unanswered)" -eq 0 ]
  run ! grep -Eq 'issues/[56]/|pulls/[56]/' "$GH_LOG"
}

@test "unanswered: a review by another user is the newest post of a pull request" {
  item 7 spali 2026-10-01T10:00:00Z pr | jq -s . | gh_respond "$ISS" -
  post spali 2026-11-01T10:00:00Z | jq -s . | comments 7
  jq -nc '[
    {submitted_at: "2026-11-05T10:00:00Z", state: "COMMENTED", body: "why?", user: {login: "other", type: "User"}},
    {submitted_at: "2026-11-06T10:00:00Z", state: "COMMENTED", body: "", user: {login: "empty", type: "User"}},
    {submitted_at: "2026-11-07T10:00:00Z", state: "PENDING", body: "draft", user: {login: "late", type: "User"}}]' |
    gh_respond '*repos/spali/a/pulls/7/reviews?per_page=100 --paginate' -
  post spali 2026-11-02T10:00:00Z | jq -s . |
    gh_respond '*repos/spali/a/pulls/7/comments?per_page=100 --paginate' -
  run_script
  [ "$(count unanswered)" -eq 1 ]
  [ "$(message unanswered)" = "pull request #7 waits for an answer for 9 days: https://github.com/spali/a/pull/7" ]
  [ "$(item_value unanswered)" = 7 ]
}

@test "unanswered: an issue needs no pull request calls" {
  item 5 other 2026-11-04T10:00:00Z | jq -s . | gh_respond "$ISS" -
  run_script
  grep -q 'repos/spali/a/issues/5/comments' "$GH_LOG"
  run ! grep -q 'pulls/5/' "$GH_LOG"
}

@test "unanswered: a newer review comment of the owner answers a pull request" {
  item 7 other 2026-10-01T10:00:00Z pr | jq -s . | gh_respond "$ISS" -
  post spali 2026-11-10T10:00:00Z | jq -s . |
    gh_respond '*repos/spali/a/pulls/7/comments?per_page=100 --paginate' -
  run_script
  [ "$(count unanswered)" -eq 0 ]
}

@test "unanswered: the days come from the config" {
  echo '{"managed":[],"unanswered":{"days":14}}' >"$CONFIG"
  item 5 other 2026-11-04T10:00:00Z | jq -s . | gh_respond "$ISS" -
  run_script
  [ "$(count unanswered)" -eq 0 ]
  run ! grep -q 'issues/5/' "$GH_LOG"
}

@test "unanswered: an API error on the issues list is check-failed" {
  gh_fail "$ISS" 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "unanswered: gh: Server Error (HTTP 502)" ]
}

@test "unanswered: an API error on the comments is check-failed" {
  item 5 other 2026-11-04T10:00:00Z | jq -s . | gh_respond "$ISS" -
  gh_fail '*repos/spali/a/issues/5/comments*' 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count unanswered)" -eq 0 ]
}
