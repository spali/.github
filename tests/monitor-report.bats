#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPORT="$BATS_TEST_DIRNAME/../scripts/monitor-report.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
  export FINDINGS="$FIX/findings.jsonl"
  export INVENTORY="$FIX/inventory.json"
  export CONFIG="$FIX/config.json"
  unset GITHUB_STEP_SUMMARY GITHUB_ACTIONS MONITOR_UNMASK
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
{"ignores":[{"repo":"spali/pub","check":"settings-merge","reason":"intended","private":false}]}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red · 0 info · 0 skipped"* ]]
  [[ $output != *"merge commits"* ]]
}

@test "unused ignore becomes info" {
  config <<'J'
{"ignores":[{"repo":"spali/pub","check":"adoption","reason":"typo?","private":false}]}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"2 red · 2 info · 1 skipped"* ]]
  [[ $output == *"| spali/pub | unused ignore: typo? |"* ]]
}

@test "unused private ignores are only counted" {
  findings </dev/null
  config <<'J'
{"ignores":[{"repo":"spali/secret-repo","check":"adoption","reason":"hush","private":true},
 {"repo":"spali/secret-repo","check":"main-red","reason":"hush","private":true}]}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red · 2 info · 0 skipped"* ]]
  [[ $output == *"ignore-unused: 2 private ignore(s)"* ]]
  [[ $output != *"secret-repo"* ]]
  [[ $output != *"hush"* ]]
}

@test "private repo shows only a count" {
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *secret-repo* ]]
  grep -q 'main-red: 1 private repo(s)' <<<"$output"
}

@test "repo missing from the inventory is private" {
  findings <<'J'
{"level":"red","check":"main-red","repo":"spali/archived-thing","message":"CI failed in spali/archived-thing"}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *archived-thing* ]]
  grep -q 'main-red: 1 private repo(s)' <<<"$output"
}

@test "private repo names are masked in public findings" {
  findings <<'J'
{"level":"red","check":"check-failed","repo":null,"message":"x: gh: Not Found https://api.github.com/repos/spali/secret-repo/rulesets (HTTP 404)"}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *secret-repo* ]]
  [[ $output == *"https://api.github.com/repos/[private]/rulesets"* ]]
}

@test "short names mask on word boundaries only" {
  findings <<'J'
{"level":"red","check":"check-failed","repo":null,"message":"secret-repo-x and my.secret-repo, (secret-repo)"}
J
  run "$REPORT"
  [[ $output == *"secret-repo-x and my.secret-repo, ([private])"* ]]
}

@test "MONITOR_UNMASK=1 shows private details locally" {
  MONITOR_UNMASK=1 run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"| spali/secret-repo | CI failed: https://api.github.com/repos/spali/secret-repo/actions/runs |"* ]]
  [[ $output != *"private repo(s)"* ]]
}

@test "MONITOR_UNMASK is ignored in Actions" {
  MONITOR_UNMASK=1 GITHUB_ACTIONS=true run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *secret-repo* ]]
  grep -q 'main-red: 1 private repo(s)' <<<"$output"
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

@test "writes to GITHUB_STEP_SUMMARY and prints nothing" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run "$REPORT"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  grep -q '## Maintenance monitor' "$GITHUB_STEP_SUMMARY"
  run ! grep -q secret-repo "$GITHUB_STEP_SUMMARY"
}

@test "names followed by a dot, and case variants, are masked" {
  findings <<'J'
{"level":"red","check":"check-failed","repo":null,"message":"a spali/secret-repo. b https://github.com/spali/secret-repo.git c secret-repo. d Spali/Secret-Repo e SECRET-REPO"}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ ${output,,} != *secret-repo* ]]
  [[ $output == *"a [private]. b https://github.com/[private].git c [private]. d [private] e [private] |"* ]]
}

@test "a non-string message does not leak through stderr" {
  findings <<'J'
{"level":"red","check":"check-failed","repo":null,"message":{"url":"spali/secret-repo"}}
J
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $stderr != *secret-repo* ]]
  [[ $output != *secret-repo* ]]
}
