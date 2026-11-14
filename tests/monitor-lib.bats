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
  [[ " ${MONITOR_CHECKS[*]} " == *" public-config-private-repo "* ]]
}

@test "fetch prints the body on success" {
  echo '{"a":1}' | gh_respond 'api repos/spali/x' -
  run --separate-stderr fetch main-red spali/x repos/spali/x
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":1}' ]
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
