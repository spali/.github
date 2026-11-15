#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  FINDINGS="$BATS_TEST_TMPDIR/f.jsonl"
  export FINDINGS
  : >"$FINDINGS"
  MONITOR_NOW=$(date -u -d 2026-11-14T00:00:00Z +%s)
  export MONITOR_NOW
  # shellcheck source=../scripts/monitor-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
}

# gh_fail_raw MESSAGE: every gh call prints the (multi-line) message to stderr
# and fails; the shared stub keeps one response per line, so it cannot do this.
gh_fail_raw() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/gh.err"
  printf '#!/usr/bin/env bash\ncat "%s" >&2\nexit 1\n' "$BATS_TEST_TMPDIR/gh.err" >"$BATS_TEST_TMPDIR/bin/gh"
}

@test "finding writes one JSON line" {
  finding red main-red spali/x m
  [ "$(wc -l <"$FINDINGS")" -eq 1 ]
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"main-red","repo":"spali/x","message":"m"}' ]
}

@test "finding with - has null repo" {
  finding info adoption - m
  [ "$(jq -c .repo "$FINDINGS")" = null ]
}

@test "finding rejects unknown check" {
  run --separate-stderr finding red nope spali/x m
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: unknown check nope" ]
  [ ! -s "$FINDINGS" ]
}

@test "finding rejects unknown level" {
  run --separate-stderr finding blue main-red spali/x m
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: unknown level blue" ]
}

@test "finding requires FINDINGS" {
  FINDINGS= run --separate-stderr finding red main-red spali/x m
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: FINDINGS is required" ]
}

@test "MONITOR_CHECKS lists the check ids" {
  [[ " ${MONITOR_CHECKS[*]} " == *" main-red "* ]]
  [[ " ${MONITOR_CHECKS[*]} " == *" check-failed "* ]]
}

@test "fetch prints the body on success" {
  echo '{"a":1}' | gh_respond 'api repos/spali/x' -
  run --separate-stderr fetch main-red spali/x repos/spali/x
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":1}' ]
  [ ! -s "$FINDINGS" ]
}

@test "fetch and paged handle a response above 200 KB" {
  jq -cn '[range(0; 30) | {n: ., pad: ("x" * 10000), keep: .}]' >"$BATS_TEST_TMPDIR/big.json"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/big.json")" -gt 200000 ]
  gh_respond 'api repos/spali/x*' "$BATS_TEST_TMPDIR/big.json"
  run fetch main-red spali/x repos/spali/x
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 30 ]
  paged main-red spali/x repos/spali/x '{n}' "$BATS_TEST_TMPDIR/out.json"
  [ "$(jq length "$BATS_TEST_TMPDIR/out.json")" -eq 30 ]
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/out.json")" -lt 1000 ]
  [ ! -s "$FINDINGS" ]
}

@test "fetch turns a known n/a answer into skip" {
  gh_fail 'api *' 'gh: no analysis found (HTTP 404)'
  run --separate-stderr fetch code-scanning-alert spali/x repos/spali/x/code-scanning/alerts
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(wc -l <"$FINDINGS")" -eq 1 ]
  [ "$(jq -r .level "$FINDINGS")" = skip ]
  [ "$(jq -r .check "$FINDINGS")" = code-scanning-alert ]
  [ "$(jq -r .message "$FINDINGS")" = 'code-scanning-alert: gh: no analysis found (HTTP 404)' ]
}

@test "fetch treats each recorded n/a message as skip" {
  local msg
  for msg in \
    'Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)' \
    'Code scanning is not enabled for this repository. Please enable code scanning in the repository settings. (HTTP 403)' \
    'Dependabot alerts are disabled for this repository. (HTTP 403)'; do
    : >"$GH_RESPONSES"
    gh_fail 'api *' "gh: $msg"
    run fetch ruleset-main spali/x repos/spali/x/rulesets
    [ "$status" -eq 2 ]
  done
  [ "$(jq -r .level "$FINDINGS" | sort -u)" = skip ]
}

@test "fetch turns other errors into check-failed" {
  gh_fail 'api *' 'gh: API rate limit exceeded (HTTP 403)'
  run --separate-stderr fetch main-red spali/x repos/spali/x
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(jq -r .level "$FINDINGS")" = red ]
  [ "$(jq -r .check "$FINDINGS")" = check-failed ]
  [ "$(jq -r .repo "$FINDINGS")" = spali/x ]
  [ "$(jq -r .message "$FINDINGS")" = 'main-red: gh: API rate limit exceeded (HTTP 403)' ]
}

@test "fetch does not treat generic Not Found or setting-off as n/a" {
  gh_fail 'api *' 'gh: Vulnerability alerts are disabled. (HTTP 404)'
  run fetch settings-alerts spali/x repos/spali/x/vulnerability-alerts
  [ "$status" -eq 1 ]
  [ "$(jq -r .check "$FINDINGS")" = check-failed ]
}

@test "fetch uses the HTTP line of a multi-line error" {
  gh_fail_raw $'gh: This API operation needs the "admin:repo_hook" scope.\ngh: Resource not accessible (HTTP 403)\nmore text'
  run --separate-stderr fetch main-red spali/x repos/spali/x
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  [ "$(jq -r .message "$FINDINGS")" = 'main-red: gh: Resource not accessible (HTTP 403)' ]
}

@test "fetch falls back to the first non-empty line" {
  gh_fail_raw $'\n\ngh: connection refused\nsecond'
  run fetch main-red spali/x repos/spali/x
  [ "$status" -eq 1 ]
  [ "$(jq -r .message "$FINDINGS")" = 'main-red: gh: connection refused' ]
}

@test "fetch stays silent on failure" {
  gh_fail 'api *' 'gh: boom (HTTP 500)'
  run --separate-stderr fetch main-red - repos/spali/x
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  [ "$(jq -r .repo "$FINDINGS")" = null ]
}

@test "days_since counts whole days" {
  [ "$(days_since 2026-11-06T12:00:00Z)" = 7 ]
}

@test "days_since without MONITOR_NOW uses the current time" {
  unset MONITOR_NOW
  [ "$(days_since "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" = 0 ]
}

@test "sourcing prints nothing" {
  run bash -c 'source "$1"' _ "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "parse_failed records a check-failed finding" {
  parse_failed settings-merge spali/x
  [ "$(jq -r '[.level, .check, .repo, .message] | join("|")' "$FINDINGS")" = "red|check-failed|spali/x|settings-merge: cannot parse API response" ]
}

@test "paged reads all pages and keeps only the given fields" {
  printf '[{"a":1,"x":"big"}]\n[{"a":2,"x":"big"}]\n' | gh_respond '*repos/spali/x/things*' -
  paged main-red spali/x 'repos/spali/x/things?per_page=100' '{a}' "$BATS_TEST_TMPDIR/out.json"
  [ "$(jq -c . "$BATS_TEST_TMPDIR/out.json")" = '[{"a":1},{"a":2}]' ]
  [ ! -s "$FINDINGS" ]
}

@test "paged records check-failed for unparsable JSON and a failing call" {
  echo 'not json' | gh_respond '*repos/spali/x/bad*' -
  run paged main-red spali/x 'repos/spali/x/bad' '{a}' "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.message' "$FINDINGS")" = "main-red: cannot parse API response" ]
  : >"$FINDINGS"
  gh_fail '*repos/spali/x/boom*' 'boom (HTTP 500)'
  run paged main-red spali/x 'repos/spali/x/boom' '{a}' "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -eq 1 ]
  [ "$(jq -r '.check' "$FINDINGS")" = check-failed ]
}

@test "json_out stores jq output in the variable" {
  json_out main-red spali/x result -r '.a' <<<'{"a":"v"}'
  [ "$result" = v ]
  [ ! -s "$FINDINGS" ]
}

@test "json_out records check-failed on a jq failure" {
  run json_out main-red spali/x result -r '.a' <<<'not json'
  [ "$status" -eq 1 ]
  [ "$(jq -r '.message' "$FINDINGS")" = "main-red: cannot parse API response" ]
}

@test "err_line prefers the HTTP line, else the first non-empty line" {
  printf 'gh: hint\ngh: Forbidden (HTTP 403)\nmore\n' >"$BATS_TEST_TMPDIR/e1"
  [ "$(err_line "$BATS_TEST_TMPDIR/e1")" = 'gh: Forbidden (HTTP 403)' ]
  printf '\n\ngh: connection refused\nsecond\n' >"$BATS_TEST_TMPDIR/e2"
  [ "$(err_line "$BATS_TEST_TMPDIR/e2")" = 'gh: connection refused' ]
  : >"$BATS_TEST_TMPDIR/e3"
  [ -z "$(err_line "$BATS_TEST_TMPDIR/e3")" ]
}

@test "disabled_workflows lists workflows disabled for inactivity" {
  body='{"workflows":[{"name":"Sync","path":".github/workflows/sync.yml","state":"disabled_inactivity"},{"name":"B","path":"b.yml","state":"active"}]}'
  disabled_workflows workflow-disabled spali/x out <<<"$body"
  [ "$out" = 'Sync (.github/workflows/sync.yml) disabled by GitHub after 60 days of inactivity' ]
  run --separate-stderr disabled_workflows workflow-disabled spali/x out <<<'<html>'
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  [ "$(jq -r .check "$FINDINGS")" = check-failed ]
}
