#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-issue.sh"
  REPORT="$BATS_TEST_TMPDIR/report.md"
  printf '## Maintenance monitor\n\n1 red · 0 info · 0 not checked\n' >"$REPORT"
  export MONITOR_ISSUE_REPO=spali/ctl
  export ISSUE_TOKEN=issue-token
  export GH_TOKEN=read-token
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-15T05:17:00Z +%s)
  unset GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID
  TITLE='Maintenance monitor: 1 red · 0 info'
}

# issues JSON answers the open-issue listing.
issues() { gh_respond '*repos/spali/ctl/issues?state=open&labels=maintenance-monitor*' - <<<"$1"; }

# sent N prints the request body of call N (1-based line of the gh log).
sent() { cat "$GH_INPUTS/$1"; }

@test "creates the issue when none is open (label exists)" {
  issues '[]'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  run gh_calls
  [ "${lines[0]}" = "api repos/spali/ctl/labels/maintenance-monitor" ]
  [ "${lines[1]}" = "api repos/spali/ctl/issues?state=open&labels=maintenance-monitor&per_page=100 --paginate" ]
  [[ ${lines[2]} == "api -X POST repos/spali/ctl/issues --input "* ]]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(sent 3 | jq -c '[.title, .labels]')" = '["Maintenance monitor: 1 red · 0 info",["maintenance-monitor"]]' ]
  # the body is the report as it is: no footer (time and run are in the
  # summary line of the report)
  sent 3 | jq -j .body >"$BATS_TEST_TMPDIR/body.md"
  cmp "$BATS_TEST_TMPDIR/body.md" "$REPORT"
}

@test "creates the label first when GET answers 404" {
  gh_fail '*labels/maintenance-monitor' 'gh: Not Found (HTTP 404)'
  issues '[]'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  run gh_calls
  [ "${lines[1]}" = "api -X POST repos/spali/ctl/labels -f name=maintenance-monitor -f color=0e8a16 -f description=Overview of the maintenance monitor" ]
  [[ ${lines[3]} == "api -X POST repos/spali/ctl/issues --input "* ]]
  [ "${#lines[@]}" -eq 4 ]
}

@test "a failing label creation fails the run" {
  gh_fail '*labels/maintenance-monitor' 'gh: Not Found (HTTP 404)'
  gh_fail '*-X POST repos/spali/ctl/labels*' 'gh: Forbidden (HTTP 403)'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: creating label maintenance-monitor failed: gh: Forbidden (HTTP 403)" ]
}

@test "updates the open issue with the lowest number and ignores pull requests" {
  issues '[{"number":9,"title":"old"},{"number":3,"pull_request":{"url":"x"}},{"number":7,"title":"old"}]'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run gh_calls
  [[ ${lines[2]} == "api -X PATCH repos/spali/ctl/issues/7 --input "* ]]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(sent 3 | jq -c 'keys')" = '["body","title"]' ]
  [ "$(sent 3 | jq -r .title)" = "$TITLE" ]
}

@test "only pull requests with the label means a new issue" {
  issues '[{"number":3,"pull_request":{"url":"x"}}]'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  run gh_calls
  [[ ${lines[2]} == "api -X POST repos/spali/ctl/issues --input "* ]]
}

@test "reads every page of the listing" {
  { echo '[{"number":9}]'; echo '[{"number":4}]'; } | gh_respond '*issues?state=open*' -
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  [[ "$(gh_calls)" == *"-X PATCH repos/spali/ctl/issues/4 "* ]]
}

@test "uses ISSUE_TOKEN for its own gh calls only" {
  issues '[]'
  run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$GH_TOKENS")" -eq 3 ]
  [ "$(sort -u "$GH_TOKENS")" = issue-token ]
}

@test "the body never goes through argv" {
  issues '[]'
  run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  [ -s "$GH_INPUTS/3" ]
  [[ "$(sent 3 | jq -r .body)" == *"red · 0 info · 0 not checked"* ]]
  [[ "$(gh_calls)" != *"red · 0 info · 0 not checked"* ]]
}

@test "the body has no footer, also with the run variables set" {
  issues '[]'
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=spali/ctl GITHUB_RUN_ID=42 \
    run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  sent 3 | jq -j .body >"$BATS_TEST_TMPDIR/body.md"
  cmp "$BATS_TEST_TMPDIR/body.md" "$REPORT"
  run ! grep -qiE 'updated|\[run\]' "$BATS_TEST_TMPDIR/body.md"
}

# long_report LINES writes a report of numbered lines of 80 bytes each.
long_report() {
  { echo '## Maintenance monitor'; echo
    for i in $(seq 1 "$1"); do printf 'line %06d %s\n' "$i" "$(head -c 62 /dev/zero | tr '\0' x)"; done; } >"$REPORT"
}

@test "a report above GitHub's limit is cut at a line boundary with a note" {
  long_report 1000
  [ "$(stat -c %s "$REPORT")" -gt 65536 ]
  issues '[]'
  GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=spali/ctl GITHUB_RUN_ID=42 \
    run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  sent 3 | jq -j .body >"$BATS_TEST_TMPDIR/body.md"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/body.md")" -le 65536 ]
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/body.md")" -gt 65000 ]
  [ "$(tail -n1 "$BATS_TEST_TMPDIR/body.md")" = '… truncated, see the run summary.' ]
  # every kept report line is complete and in order
  kept=$(grep -c '^line ' "$BATS_TEST_TMPDIR/body.md")
  [ "$kept" -lt 1000 ]
  [ "$(grep '^line ' "$BATS_TEST_TMPDIR/body.md" | tail -n1)" = "$(sed -n "$((kept + 2))p" "$REPORT")" ]
}

@test "a cut inside an open details block closes it before the note" {
  issues '[]'
  { echo '## Maintenance monitor'; echo
    echo '<details open><summary>s</summary>'; echo
    echo '| Repository | Details | Fix at |'; echo '| --- | --- | --- |'
    for i in $(seq 1 1000); do printf '| r%06d | %s | |\n' "$i" "$(head -c 62 /dev/zero | tr '\0' x)"; done
    echo; echo '</details>'; } >"$REPORT"
  run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  sent 3 | jq -j .body >"$BATS_TEST_TMPDIR/body.md"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/body.md")" -le 65536 ]
  [ "$(grep -c '^<details' "$BATS_TEST_TMPDIR/body.md")" -eq "$(grep -c '^</details>$' "$BATS_TEST_TMPDIR/body.md")" ]
  # the table ends, the block closes, then the note
  [ "$(tail -n4 "$BATS_TEST_TMPDIR/body.md")" = $'\n</details>\n\n… truncated, see the run summary.' ]
}

@test "a complete last line is kept when the cut falls right after a newline" {
  issues '[]'
  tail2=$(printf '\n%s\n' '… truncated, see the run summary.' | wc -c)
  budget=$((65536 - tail2))
  { head -c "$((budget - 1))" /dev/zero | tr '\0' k; echo
    for i in 1 2 3; do printf 'extra %s %0100d\n' "$i" 0; done; } >"$REPORT"
  run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  sent 3 | jq -j .body >"$BATS_TEST_TMPDIR/body.md"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/body.md")" -eq 65536 ]
  [ "$(head -c 10 "$BATS_TEST_TMPDIR/body.md")" = kkkkkkkkkk ]
  run ! grep -q '^extra' "$BATS_TEST_TMPDIR/body.md"
}

@test "a report that just fits is not cut" {
  issues '[]'
  long_report 100
  # pad to exactly the limit
  pad=$((65536 - $(stat -c %s "$REPORT")))
  head -c "$((pad - 1))" /dev/zero | tr '\0' y >>"$REPORT"
  echo >>"$REPORT"
  [ "$(stat -c %s "$REPORT")" -eq 65536 ]
  run "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  sent 3 | jq -j .body >"$BATS_TEST_TMPDIR/body.md"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/body.md")" -eq 65536 ]
  run ! grep -qF 'truncated' "$BATS_TEST_TMPDIR/body.md"
}

@test "a report and an issue listing above 200 KB are handled" {
  long_report 3000
  [ "$(stat -c %s "$REPORT")" -gt 200000 ]
  jq -cn '[range(0; 30) | {number: (100 - .), title: "t", body: ("z" * 10000)}]' >"$BATS_TEST_TMPDIR/big.json"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/big.json")" -gt 200000 ]
  gh_respond '*issues?state=open*' "$BATS_TEST_TMPDIR/big.json"
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ "$(gh_calls)" == *"-X PATCH repos/spali/ctl/issues/71 "* ]]
  [ "$(sent 3 | jq -j .body | wc -c)" -le 65536 ]
}

@test "a label lookup error other than 404 fails and writes nothing" {
  gh_fail '*labels/maintenance-monitor' 'gh: Internal Server Error (HTTP 500)'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: reading label maintenance-monitor failed: gh: Internal Server Error (HTTP 500)" ]
  [ "$(gh_calls | wc -l)" -eq 1 ]
}

@test "a failing issue listing fails" {
  gh_fail '*issues?state=open*' 'gh: Bad Gateway (HTTP 502)'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: listing issues failed: gh: Bad Gateway (HTTP 502)" ]
}

@test "an unparsable issue listing fails" {
  issues 'not json'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: listing issues failed: cannot parse API response" ]
}

@test "a failing PATCH exits 1 with one error line" {
  issues '[{"number":5}]'
  gh_fail '*-X PATCH*' $'gh: Validation Failed (HTTP 422)\nextra hint line'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: updating issue #5 failed: gh: Validation Failed (HTTP 422)" ]
}

@test "a failing POST exits 1 with one error line" {
  issues '[]'
  gh_fail '*-X POST repos/spali/ctl/issues*' 'gh: Resource not accessible by integration (HTTP 403)'
  run --separate-stderr "$SCRIPT" "$REPORT" "$TITLE"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: creating the issue failed: gh: Resource not accessible by integration (HTTP 403)" ]
}

@test "missing arguments, report file and env fail" {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $stderr == "error: usage"* ]]
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/nope.md" t
  [ "$status" -eq 1 ]
  [[ $stderr == *"cannot read file" ]]
  ISSUE_TOKEN= run --separate-stderr "$SCRIPT" "$REPORT" t
  [ "$stderr" = "error: ISSUE_TOKEN is required" ]
  MONITOR_ISSUE_REPO= run --separate-stderr "$SCRIPT" "$REPORT" t
  [ "$stderr" = "error: MONITOR_ISSUE_REPO is required" ]
  [ ! -s "$GH_LOG" ]
}
