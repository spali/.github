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
  echo '{"forks":[]}' >"$CONFIG"
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
APERMS='*repos/spali/a/actions/permissions'
APPROVAL='*repos/spali/a/actions/permissions/fork-pr-contributor-approval'
MERGE='*graphql*mergeCommitAllowed*owner=spali*name=a'
FUNDING='*graphql*fundingLinks*owner=spali*name=a'
BRANCHES='*repos/spali/a/branches?per_page=100 --paginate'
FIX="$BATS_TEST_DIRNAME/fixtures/monitor"

# merge_json [FILTER]: the recorded compliant merge settings (GraphQL; REST
# answers null for them to an app token), with an optional jq filter.
merge_json() { jq -c "${1:-.}" "$FIX/settings-merge.json" | gh_respond "$MERGE" -; }

# funding_json LINKS ENABLED: the number of funding links and the sponsor button.
funding_json() {
  respond_jq "$FUNDING" "{data: {repository: {hasSponsorshipsEnabled: $2,
    fundingLinks: [range($1) | {platform: \"GITHUB\"}]}}}"
}

# pulls_on BRANCH JSON: the pulls of spali/a with head spali:BRANCH (all states).
pulls_on() { respond_jq "*repos/spali/a/pulls?state=all&head=spali:$1&per_page=100 --paginate" "$2"; }

# pull REF NUMBER STATE MERGED_AT HEAD_SHA [HEAD_REPO]: one pull request of the API.
pull() {
  local ref=$1
  shift
  jq -nc --arg ref "$ref" --argjson n "$1" --arg s "$2" --arg m "$3" --arg sha "$4" --arg hr "${5:-spali/a}" \
    '{number: $n, state: $s, merged_at: (if $m == "" then null else $m end), created_at: "2026-11-01T00:00:00Z",
      html_url: "https://github.com/spali/a/pull/\($n)", head: {ref: $ref, sha: $sha, repo: {full_name: $hr}}}'
}

# run_json GLOB JQ_EXPRESSION registers a response built by jq -n.
respond_jq() { jq -nc "$2" | gh_respond "$1" -; }

run_script() {
  respond_jq "$RUNS" '{workflow_runs: []}'
  respond_jq "$PRS" '[]'
  respond_jq "$WFS" '{workflows: []}'
  respond_jq "$DEP" '[]'
  respond_jq "$CS" '[]'
  respond_jq "$ISS" '[]'
  respond_jq "$APERMS" '{enabled: true}'
  respond_jq "$APPROVAL" '{approval_policy: "all_external_contributors"}'
  funding_json 0 true
  merge_json
  respond_jq "$BRANCHES" '[{name: "main", commit: {sha: "m1"}}]'
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

@test "repositories under forks: are out of scope" {
  jq -n '[
    {name: "spali/a", fork: false, default_branch: "main"},
    {name: "spali/Managed", fork: false, default_branch: "main"}]' >"$INVENTORY"
  echo '{"forks":[{"repo":"spali/managed","upstream":"https://src.example/m.git"}]}' >"$CONFIG"
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
  echo '{"forks":[],"unanswered":{"days":14}}' >"$CONFIG"
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

@test "unanswered: a review comment by another user is the newest post" {
  item 7 spali 2026-10-01T10:00:00Z pr | jq -s . | gh_respond "$ISS" -
  post spali 2026-11-01T10:00:00Z | jq -s . | comments 7
  post other 2026-11-03T10:00:00Z | jq -s . |
    gh_respond '*repos/spali/a/pulls/7/comments?per_page=100 --paginate' -
  run_script
  [ "$(count unanswered)" -eq 1 ]
  [ "$(message unanswered)" = "pull request #7 waits for an answer for 11 days: https://github.com/spali/a/pull/7" ]
}

@test "unanswered: the owner login is compared without case" {
  item 5 other 2026-10-01T10:00:00Z | jq -s . | gh_respond "$ISS" -
  post Spali 2026-11-01T10:00:00Z | jq -s . | comments 5
  run_script
  [ "$(count unanswered)" -eq 0 ]
}

@test "unanswered: an approving review of the owner without body answers" {
  item 7 other 2026-10-01T10:00:00Z pr | jq -s . | gh_respond "$ISS" -
  jq -nc '[{submitted_at: "2026-11-10T10:00:00Z", state: "APPROVED", body: "", user: {login: "spali", type: "User"}}]' |
    gh_respond '*repos/spali/a/pulls/7/reviews?per_page=100 --paginate' -
  run_script
  [ "$(count unanswered)" -eq 0 ]
}

@test "unanswered: an ignored open item answered by the owner still emits the ignored finding without calls" {
  echo '{"forks":[],"ignores":[{"repo":"Spali/A","check":"unanswered","item":5,"reason":"r"}]}' >"$CONFIG"
  { item 5 other 2026-09-01T10:00:00Z; item 7 other 2026-09-01T10:00:00Z pr; } | jq -s . | gh_respond "$ISS" -
  { post other 2026-09-02T10:00:00Z; post spali 2026-09-03T10:00:00Z; } | jq -s . | comments 5
  run_script
  [ "$(message unanswered 0)" = "issue #5 is open (ignored)" ]
  [ "$(item_value unanswered 0)" = 5 ]
  run ! grep -Eq 'issues/5/|pulls/5/' "$GH_LOG"
}

@test "unanswered: an ignored open pull request emits the ignored finding" {
  echo '{"forks":[],"ignores":[{"repo":"spali/a","check":"unanswered","item":7,"reason":"r"}]}' >"$CONFIG"
  item 7 spali 2026-11-13T10:00:00Z pr | jq -s . | gh_respond "$ISS" -
  run_script
  [ "$(count unanswered)" -eq 1 ]
  [ "$(message unanswered)" = "pull request #7 is open (ignored)" ]
  [ "$(item_value unanswered)" = 7 ]
}

@test "fork approval red is reported for the repository" {
  respond_jq "$APPROVAL" '{approval_policy: "first_time_contributors"}'
  run_script
  [ "$(count settings-fork-approval)" -eq 1 ]
  [ "$(level settings-fork-approval)" = red ]
  [ "$(message settings-fork-approval)" = 'approval_policy: got "first_time_contributors", want "all_external_contributors"' ]
  [ "$(jq -rs 'map(select(.check == "settings-fork-approval")) | .[0].repo' "$FINDINGS")" = spali/a ]
}

@test "private repository skips fork approval" {
  jq -n '[{name: "spali/a", fork: false, private: true, default_branch: "main"}]' >"$INVENTORY"
  run_script
  [ "$(count settings-fork-approval)" -eq 1 ]
  [ "$(level settings-fork-approval)" = skip ]
  [ "$(message settings-fork-approval)" = "private repository" ]
  run ! grep -q fork-pr-contributor-approval "$GH_LOG"
}

@test "settings-merge names each differing field" {
  merge_json '.data.repository.mergeCommitAllowed = true | .data.repository.squashMergeCommitTitle = "COMMIT_OR_PR_TITLE"'
  run_script
  [ "$(count settings-merge)" -eq 1 ]
  [ "$(level settings-merge)" = red ]
  [ "$(message settings-merge)" = 'allow_merge_commit: got true, want false; squash_merge_commit_title: got "COMMIT_OR_PR_TITLE", want "PR_TITLE"' ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "settings-merge reads GraphQL, not the REST repository" {
  run_script
  grep -q 'graphql' "$GH_LOG"
  run ! grep -qx 'api repos/spali/a' "$GH_LOG"
}

@test "settings-merge without a repository in the answer is check-failed" {
  merge_json '.data.repository = null'
  run_script
  [ "$(count settings-merge)" -eq 0 ]
  [ "$(message check-failed)" = "settings-merge: cannot parse API response" ]
}

@test "settings-merge: a failing call is check-failed, never green" {
  gh_fail "$MERGE" 'Server Error (HTTP 500)'
  run_script
  [ "$(count settings-merge)" -eq 0 ]
  [ "$(message check-failed)" = "settings-merge: Server Error (HTTP 500)" ]
}

@test "settings-merge checks non-central repositories too" {
  jq -n '[{name: "spali/a", fork: false, central: false, default_branch: "main"}]' >"$INVENTORY"
  merge_json '.data.repository.deleteBranchOnMerge = false'
  run_script
  [ "$(message settings-merge)" = 'delete_branch_on_merge: got false, want true' ]
}

# renovate_file ALIAS JSON_TEXT: merge settings with a Renovate config blob
# under ALIAS (r0 renovate.json … r2 .github/renovate.json, see RENOVATE_FILES).
renovate_file() { merge_json ".data.repository.$1 = {text: $(jq -Rs . <<<"$2")}${3:+ | $3}"; }

private_inventory() {
  jq -n '[{name: "spali/a", fork: false, private: true, default_branch: "main"}]' >"$INVENTORY"
}

@test "renovate-automerge: no Renovate config, no finding and no auto-merge setting wanted" {
  merge_json '.data.repository.autoMergeAllowed = false'
  run_script
  [ "$(jq -s length "$FINDINGS")" -eq 0 ]
}

@test "renovate-automerge: a compliant public repository has no finding" {
  renovate_file r2 '{"platformAutomerge": true, "automergeStrategy": "rebase"}'
  run_script
  [ "$(jq -s length "$FINDINGS")" -eq 0 ]
}

@test "renovate-automerge: platformAutomerge may be left at the default in a public repository" {
  renovate_file r2 '{"automergeStrategy": "rebase"}'
  run_script
  [ "$(jq -s length "$FINDINGS")" -eq 0 ]
}

@test "renovate-automerge: names the file and each differing key" {
  renovate_file r2 '{"platformAutomerge": false}'
  run_script
  [ "$(count renovate-automerge)" -eq 1 ]
  [ "$(level renovate-automerge)" = red ]
  [ "$(message renovate-automerge)" = '.github/renovate.json: platformAutomerge: got false, want true; automergeStrategy: got null, want "rebase"' ]
}

@test "renovate-automerge: a public repository with a Renovate config needs allow_auto_merge" {
  renovate_file r2 '{"automergeStrategy": "rebase"}' '.data.repository.autoMergeAllowed = false'
  run_script
  [ "$(count renovate-automerge)" -eq 0 ]
  [ "$(message settings-merge)" = 'allow_auto_merge: got false, want true' ]
}

@test "renovate-automerge: a private repository needs platformAutomerge false, not allow_auto_merge" {
  private_inventory
  renovate_file r2 '{"automergeStrategy": "rebase"}' '.data.repository.autoMergeAllowed = false'
  run_script
  [ "$(count settings-merge)" -eq 0 ]
  [ "$(message renovate-automerge)" = '.github/renovate.json: platformAutomerge: got null, want false' ]
}

@test "renovate-automerge: a compliant private repository has no finding" {
  private_inventory
  renovate_file r2 '{"platformAutomerge": false, "automergeStrategy": "rebase"}' '.data.repository.autoMergeAllowed = false'
  run_script
  [ "$(count renovate-automerge)" -eq 0 ]
  [ "$(count settings-merge)" -eq 0 ]
}

@test "renovate-automerge: the first config file in Renovate's order wins" {
  merge_json '.data.repository.r0 = {text: "{\"automergeStrategy\": \"squash\"}"}
    | .data.repository.r2 = {text: "{\"automergeStrategy\": \"rebase\"}"}'
  run_script
  [ "$(message renovate-automerge)" = 'renovate.json: automergeStrategy: got "squash", want "rebase"' ]
}

@test "renovate-automerge: a config jq cannot parse is check-failed" {
  renovate_file r3 '{automergeStrategy: "rebase", // JSON5
}'
  run_script
  [ "$(count renovate-automerge)" -eq 0 ]
  [ "$(message check-failed)" = 'renovate-automerge: cannot parse .github/renovate.json5' ]
}

@test "renovate-automerge: the merge query reads the auto-merge setting and the config files" {
  run_script
  grep -q 'autoMergeAllowed' "$GH_LOG"
  grep -qF 'HEAD:.github/renovate.json' "$GH_LOG"
  grep -qF 'HEAD:.renovaterc.json5' "$GH_LOG"
}

@test "stale-branch: a merged branch at the merged head is red with the pull request as item" {
  respond_jq "$BRANCHES" '[{name: "main", commit: {sha: "m1"}}, {name: "feat/x", commit: {sha: "s1"}}]'
  pull feat/x 5 closed 2026-11-10T00:00:00Z s1 | jq -s . | gh_respond '*pulls?state=all&head=spali:feat%2Fx&*' -
  run_script
  [ "$(count stale-branch)" -eq 1 ]
  [ "$(level stale-branch)" = red ]
  [ "$(message stale-branch)" = "feat/x: pull request #5 is merged, delete the branch" ]
  [ "$(jq -rs 'map(select(.check == "stale-branch")) | .[0].item' "$FINDINGS")" = 5 ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "stale-branch: commits after the merge are info" {
  respond_jq "$BRANCHES" '[{name: "main", commit: {sha: "m1"}}, {name: "b", commit: {sha: "new"}}]'
  pull b 5 closed 2026-11-10T00:00:00Z old | jq -s . | gh_respond '*pulls?state=all&head=spali:b&*' -
  run_script
  [ "$(level stale-branch)" = info ]
  [ "$(message stale-branch)" = "b: pull request #5 is merged, the branch has newer commits" ]
}

@test "stale-branch: the newest merged pull request counts" {
  respond_jq "$BRANCHES" '[{name: "main", commit: {sha: "m1"}}, {name: "b", commit: {sha: "s2"}}]'
  { pull b 4 closed 2026-11-01T00:00:00Z s1; pull b 6 closed 2026-11-12T00:00:00Z s2; pull b 7 closed "" s3; } |
    jq -s . | gh_respond '*pulls?state=all&head=spali:b&*' -
  run_script
  [ "$(level stale-branch)" = red ]
  [[ $(message stale-branch) == "b: pull request #6 is merged"* ]]
}

@test "stale-branch: an open pull request, a closed unmerged one or another head repository is no finding" {
  respond_jq "$BRANCHES" '[{name: "main", commit: {sha: "m1"}}, {name: "o", commit: {sha: "s1"}},
    {name: "c", commit: {sha: "s1"}}, {name: "f", commit: {sha: "s1"}}]'
  { pull o 1 closed 2026-11-01T00:00:00Z s1; pull o 2 open "" s1; } | jq -s . | gh_respond '*head=spali:o&*' -
  pull c 3 closed "" s1 | jq -s . | gh_respond '*head=spali:c&*' -
  pull f 4 closed 2026-11-01T00:00:00Z s1 other/a | jq -s . | gh_respond '*head=spali:f&*' -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "stale-branch: one query per branch, never for the default branch" {
  respond_jq "$BRANCHES" '[{name: "main", commit: {sha: "m1"}}, {name: "a", commit: {sha: "1"}}, {name: "b", commit: {sha: "2"}}]'
  run_script
  [ "$(grep -c 'pulls?state=all' "$GH_LOG")" -eq 2 ]
  run ! grep -q 'head=spali:main' "$GH_LOG"
}

@test "stale-branch: an API error is check-failed" {
  gh_fail "$BRANCHES" 'Server Error (HTTP 500)'
  run_script
  [ "$(message check-failed)" = "stale-branch: Server Error (HTTP 500)" ]
}

@test "funding: FUNDING.yml with the sponsor button off is info" {
  funding_json 2 false
  run_script
  [ "$(count funding)" -eq 1 ]
  [ "$(level funding)" = info ]
  [ "$(message funding)" = "FUNDING.yml exists, but the sponsor button is off" ]
}

@test "funding: FUNDING.yml with the sponsor button on is fine" {
  funding_json 2 true
  run_script
  [ "$(count funding)" -eq 0 ]
}

@test "funding: no FUNDING.yml is fine with either setting" {
  for enabled in true false; do
    : >"$FINDINGS"
    : >"$GH_RESPONSES"
    funding_json 0 "$enabled"
    run_script
    [ "$(count funding)" -eq 0 ]
  done
}

@test "funding: an unreadable answer is check-failed" {
  for answer in '{data: {repository: null}}' '{data: {repository: {fundingLinks: [{platform: "GITHUB"}]}}}'; do
    : >"$FINDINGS"
    : >"$GH_RESPONSES"
    respond_jq "$FUNDING" "$answer"
    run_script
    [ "$(count funding)" -eq 0 ]
    [ "$(count check-failed)" -eq 1 ]
    [[ $(message check-failed) == "funding: "* ]]
  done
}
