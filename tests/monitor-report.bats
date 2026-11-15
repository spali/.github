#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPORT="$BATS_TEST_DIRNAME/../scripts/monitor-report.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
  export FINDINGS="$FIX/findings.jsonl"
  export CONFIG="$FIX/config.json"
}

# findings sets $FINDINGS to the lines on stdin.
findings() {
  cat >"$BATS_TEST_TMPDIR/findings.jsonl"
  export FINDINGS="$BATS_TEST_TMPDIR/findings.jsonl"
}

# config sets $CONFIG to the JSON on stdin.
config() {
  cat >"$BATS_TEST_TMPDIR/config.json"
  export CONFIG="$BATS_TEST_TMPDIR/config.json"
}

@test "exits 1 with an open red finding" {
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == "## Maintenance monitor"* ]]
  [[ $output == *"2 red · 1 info · 1 skipped"* ]]
  [[ $output == *"| spali/pub | merge commits allowed |"* ]]
}

@test "exits 0 with only info and skip" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"spali/other","message":"m"}
{"level":"skip","check":"code-scanning-alert","repo":"spali/pub","message":"n/a"}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red · 1 info · 1 skipped"* ]]
  [[ $output != *"### Red"* ]]
  [[ $output != *"code-scanning-alert"* ]]
}

@test "names every repo and message, private or not" {
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"| spali/secret-repo | CI failed: https://api.github.com/repos/spali/secret-repo/actions/runs |"* ]]
  [[ $output != *"[private]"* ]]
}

@test "writes only to stdout" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == "## Maintenance monitor"* ]]
  [ -z "$stderr" ]
  [ ! -e "$GITHUB_STEP_SUMMARY" ]
}

@test "ignore-unused of a repo not in any finding is listed with its repo" {
  findings </dev/null
  config <<'J'
{"ignores":[{"repo":"spali/gone","check":"adoption","reason":"hush"}]}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red · 1 info · 0 skipped"* ]]
  [[ $output == *"#### \`ignore-unused\`"* ]]
  [[ $output == *"| spali/gone | unused ignore: hush |"* ]]
}

@test "a non-string message is rendered, not fatal" {
  findings <<'J'
{"level":"red","check":"check-failed","repo":null,"message":{"url":"x"}}
J
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *'| - | {"url":"x"} |'* ]]
  [ -z "$stderr" ]
}

@test "findings above 200 KB are rendered completely" {
  jq -cn 'range(0; 30) | {level: "red", check: "main-red", repo: "spali/r\(.)", message: ("x" * 10000)}' >"$BATS_TEST_TMPDIR/big.jsonl"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/big.jsonl")" -gt 200000 ]
  export FINDINGS="$BATS_TEST_TMPDIR/big.jsonl"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"30 red · 0 info · 0 skipped"* ]]
  [[ $output == *"| spali/r29 |"* ]]
  [ -z "$stderr" ]
}

@test "empty findings file exits 0" {
  findings </dev/null
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red · 0 info · 0 skipped"* ]]
}

@test "ignore removes a red finding and exits 0" {
  findings <<'J'
{"level":"red","check":"settings-merge","repo":"spali/pub","message":"merge commits allowed"}
J
  config <<'J'
{"ignores":[{"repo":"spali/pub","check":"settings-merge","reason":"intended"}]}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red · 0 info · 0 skipped"* ]]
  [[ $output != *"merge commits"* ]]
}

@test "unused ignore becomes info" {
  config <<'J'
{"ignores":[{"repo":"spali/pub","check":"adoption","reason":"typo?"}]}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"2 red · 2 info · 1 skipped"* ]]
  [[ $output == *"| spali/pub | unused ignore: typo? |"* ]]
}

@test "sections are sorted and pipes escaped" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"spali/pub","message":"a | b"}
{"level":"red","check":"settings-pvr","repo":"spali/pub","message":"x"}
{"level":"red","check":"main-red","repo":"spali/pub","message":"y"}
{"level":"red","check":"main-red","repo":"spali/other","message":"z"}
J
  run "$REPORT"
  [[ $output == *'| spali/pub | a \| b |'* ]]
  red=${output%%### Info*}
  [[ $output == *"### Red"*"### Info"* ]]
  # main-red (other, pub) before settings-pvr
  [[ $red == *"main-red"*"spali/other"*"spali/pub"*"settings-pvr"* ]]
}

