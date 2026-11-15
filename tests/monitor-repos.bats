#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  FINDINGS="$BATS_TEST_TMPDIR/f.jsonl"
  export FINDINGS
  : >"$FINDINGS"
  unset GITHUB_ACTIONS
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-repos.sh"
}

# repo NAME [private] [fork] [archived] [owner] prints one repository object.
repo() {
  jq -cn --arg name "$1" --argjson private "${2:-false}" --argjson fork "${3:-false}" \
    --argjson archived "${4:-false}" --arg owner "${5:-spali}" \
    '{full_name: $name, name: ($name | split("/")[1]), private: $private, fork: $fork,
      archived: $archived, default_branch: "main", pushed_at: "2026-11-01T00:00:00Z",
      owner: {login: $owner}}'
}

# user_repos OBJECT... answers the local listing as one array.
user_repos() {
  printf '%s\n' "$@" | jq -s . | gh_respond '*user/repos*' -
}

@test "uses user/repos outside Actions" {
  user_repos "$(repo spali/a)"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].name' <<<"$output")" = spali/a ]
  [[ "$(gh_calls)" == *"user/repos?affiliation=owner"* ]]
  [[ "$(gh_calls)" != *installation/repositories* ]]
  [ -z "$stderr" ]
}

@test "uses installation/repositories in Actions" {
  jq -cn --argjson r "$(repo spali/a)" '{repositories: [$r]}' | gh_respond '*installation/repositories*' -
  GITHUB_ACTIONS=true run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].name' <<<"$output")" = spali/a ]
  [[ "$(gh_calls)" != *user/repos* ]]
}

@test "reads all pages" {
  { for i in $(seq 1 100); do repo "spali/r$i"; done; } | jq -s . >"$BATS_TEST_TMPDIR/p1"
  repo spali/r101 | jq -s . >"$BATS_TEST_TMPDIR/p2"
  cat "$BATS_TEST_TMPDIR/p1" "$BATS_TEST_TMPDIR/p2" | gh_respond '*user/repos*' -
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 101 ]
}

@test "reads all pages in Actions" {
  { jq -cn --argjson r "$(repo spali/a)" '{repositories: [$r]}'
    jq -cn --argjson r "$(repo spali/b)" '{repositories: [$r]}'; } | gh_respond '*installation/repositories*' -
  GITHUB_ACTIONS=true run --separate-stderr "$SCRIPT"
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = spali/a,spali/b ]
}

@test "drops archived and foreign repos" {
  user_repos "$(repo spali/keep)" "$(repo spali/old false false true)" "$(repo other/x false false false other)"
  run --separate-stderr "$SCRIPT"
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = spali/keep ]
}

@test "detects central repos and pins" {
  user_repos "$(repo spali/a)"
  gh_respond '*contents/.github/workflows?ref=main' - <<'JSON'
[{"name":"pr.yml","type":"file"},{"name":"README.md","type":"file"},{"name":"sub.yml","type":"dir"},{"name":"plain.yaml","type":"file"}]
JSON
  gh_respond '*contents/.github/workflows/pr.yml?ref=main' - <<'YML'
jobs:
  pr:
    uses: spali/.github/.github/workflows/pr.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
YML
  gh_respond '*contents/.github/workflows/plain.yaml?ref=main' - <<'YML'
jobs:
  x:
    uses: spali/.github/.github/workflows/release.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3
YML
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0].central' <<<"$output")" = true ]
  [ "$(jq -c '.[0].pins' <<<"$output")" = '[{"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"},{"workflow":"release.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":null}]' ]
  [[ "$(gh_calls)" == *"Accept: application/vnd.github.raw"* ]]
  [[ "$(gh_calls)" != *README.md* ]]
  [[ "$(gh_calls)" != *sub.yml* ]]
  [ ! -s "$FINDINGS" ]
}

@test "a repo that only calls the monitor workflows is not central" {
  user_repos "$(repo spali/ctl true)"
  gh_respond '*contents/.github/workflows?ref=main' - <<'JSON'
[{"name":"monitor.yml","type":"file"},{"name":"config.yml","type":"file"}]
JSON
  gh_respond '*contents/.github/workflows/monitor.yml?ref=main' - <<'YML'
jobs:
  monitor:
    uses: spali/.github/.github/workflows/monitor.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
YML
  gh_respond '*contents/.github/workflows/config.yml?ref=main' - <<'YML'
jobs:
  config:
    uses: spali/.github/.github/workflows/monitor-config.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
YML
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0] | [.central, (.pins | map(.workflow))]' <<<"$output")" = '[false,["monitor.yml","monitor-config.yml"]]' ]
}

@test "a repo that pins the monitor and another workflow is central" {
  user_repos "$(repo spali/a)"
  gh_respond '*contents/.github/workflows?ref=main' - <<'JSON'
[{"name":"x.yml","type":"file"}]
JSON
  gh_respond '*contents/.github/workflows/x.yml?ref=main' - <<'YML'
jobs:
  a:
    uses: spali/.github/.github/workflows/monitor.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
  b:
    uses: spali/.github/.github/workflows/pr.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
YML
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0].central' <<<"$output")" = true ]
}

@test "output has the documented shape" {
  user_repos "$(repo spali/a true)"
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0]' <<<"$output")" = '{"name":"spali/a","private":true,"fork":false,"default_branch":"main","pushed_at":"2026-11-01T00:00:00Z","central":false,"pins":[],"parent":null}' ]
}

@test "repo without workflows directory is not central and has no finding" {
  user_repos "$(repo spali/a)"
  gh_fail '*contents/.github/workflows?ref=main' 'gh: Not Found (HTTP 404)'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0] | [.central, .pins]' <<<"$output")" = '[false,[]]' ]
  [ ! -s "$FINDINGS" ]
}

@test "empty repository is not central and has no finding" {
  user_repos "$(repo spali/a)"
  gh_fail '*contents/.github/workflows?ref=main' 'This repository is empty. (HTTP 409)'
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0].central' <<<"$output")" = false ]
  [ ! -s "$FINDINGS" ]
}

@test "other workflow directory failure is a red finding" {
  user_repos "$(repo spali/a)"
  gh_fail '*contents/.github/workflows?ref=main' 'gh: Server Error (HTTP 502)'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0].central' <<<"$output")" = false ]
  [ "$(jq -r '.check + "|" + .repo + "|" + .message' "$FINDINGS")" = 'check-failed|spali/a|inventory: gh: Server Error (HTTP 502)' ]
}

@test "unreadable workflow file is a red finding and skipped" {
  user_repos "$(repo spali/a)"
  gh_respond '*contents/.github/workflows?ref=main' - <<'JSON'
[{"name":"pr.yml","type":"file"}]
JSON
  gh_fail '*contents/.github/workflows/pr.yml*' 'gh: Server Error (HTTP 500)'
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0] | [.central, .pins]' <<<"$output")" = '[false,[]]' ]
  [ "$(jq -r .check "$FINDINGS")" = check-failed ]
}

@test "fork gets its parent and no workflow scan" {
  user_repos "$(repo spali/f false true)"
  gh_respond '*repos/spali/f' - <<'JSON'
{"parent":{"full_name":"up/f","default_branch":"master"}}
JSON
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0].parent' <<<"$output")" = '{"name":"up/f","default_branch":"master"}' ]
  [ "$(jq -c '.[0] | [.central, .pins]' <<<"$output")" = '[false,[]]' ]
  [[ "$(gh_calls)" != *contents* ]]
}

@test "fork parent lookup failure gives null parent and a finding" {
  user_repos "$(repo spali/f false true)"
  gh_fail '*repos/spali/f' 'gh: Server Error (HTTP 500)'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0].parent' <<<"$output")" = null ]
  [ "$(jq -r .check "$FINDINGS")" = check-failed ]
}

@test "output is sorted by name" {
  user_repos "$(repo spali/b)" "$(repo spali/a)"
  run --separate-stderr "$SCRIPT"
  [ "$(jq -r 'map(.name) | join(",")' <<<"$output")" = spali/a,spali/b ]
}

@test "empty inventory is a red finding" {
  user_repos
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [ "$(jq -r '.level + "|" + .check + "|" + .message' "$FINDINGS")" = 'red|check-failed|inventory: no repositories visible' ]
}

@test "listing failure prints [] with the fetch finding only" {
  gh_fail '*user/repos*' 'gh: Server Error (HTTP 500)'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [ "$(wc -l <"$FINDINGS")" -eq 1 ]
  [[ "$(jq -r .message "$FINDINGS")" == *"(HTTP 500)" ]]
}

@test "listing that is not JSON is a red parse failure, prints [] and leaves stderr empty" {
  printf '<html><body>Bad gateway</body></html>\n' | gh_respond '*user/repos*' -
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
  [ -z "$stderr" ]
  [ "$(wc -l <"$FINDINGS")" -eq 1 ]
  [ "$(jq -r '.level + "|" + .check + "|" + .message' "$FINDINGS")" = 'red|check-failed|inventory: cannot parse API response' ]
}

@test "listing that is not JSON in Actions leaves stderr empty" {
  printf '<html></html>\n' | gh_respond '*installation/repositories*' -
  GITHUB_ACTIONS=true run --separate-stderr "$SCRIPT"
  [ "$output" = '[]' ]
  [ -z "$stderr" ]
  [ "$(jq -r .check "$FINDINGS")" = check-failed ]
}

@test "unparsable workflow directory listing leaves stderr empty" {
  user_repos "$(repo spali/a)"
  printf 'not json\n' | gh_respond '*contents/.github/workflows?ref=main' -
  run --separate-stderr "$SCRIPT"
  [ -z "$stderr" ]
}

@test "a commented-out uses line is not a pin" {
  user_repos "$(repo spali/a)"
  gh_respond '*contents/.github/workflows?ref=main' - <<'JSON'
[{"name":"pr.yml","type":"file"}]
JSON
  gh_respond '*contents/.github/workflows/pr.yml?ref=main' - <<'YML'
jobs:
  pr:
    # uses: spali/.github/.github/workflows/pr.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
    steps:
      - uses: spali/.github/.github/workflows/x.yml@6f26c6b1dcac0797c52055241f0cfb74a797ebe3 # v1.0.0
YML
  run --separate-stderr "$SCRIPT"
  [ "$(jq -c '.[0].pins | map(.workflow)' <<<"$output")" = '["x.yml"]' ]
}

@test "a listing above 200 KB is read completely" {
  { for i in $(seq 1 30); do repo "spali/r$i" | jq -c '. + {pad: ("x" * 10000)}'; done; } |
    jq -s . >"$BATS_TEST_TMPDIR/big.json"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/big.json")" -gt 200000 ]
  gh_respond '*user/repos*' "$BATS_TEST_TMPDIR/big.json"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 30 ]
  [ -z "$stderr" ]
}
