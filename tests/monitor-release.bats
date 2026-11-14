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
  echo '{}' >"$CONFIG"
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-14T12:00:00Z +%s)
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-release.sh"
  # one central repo, no pins, plus a non-central one that must be ignored
  inventory '[]'
}

# inventory PINS_JSON writes spali/a (central) with the given pins.
inventory() {
  jq -n --argjson pins "$1" '[
    {name: "spali/a", central: true, pins: $pins},
    {name: "spali/skip", central: false, pins: []}]' >"$INVENTORY"
}

# latest_release TAG PUBLISHED answers the spali/.github lookups.
latest_release() {
  jq -cn --arg t "$1" --arg p "$2" '{tag_name: $t, published_at: $p}' |
    gh_respond '*spali/.github/releases/latest*' -
  jq -cn '{sha: "ffffffffffffffffffffffffffffffffffffffff"}' |
    gh_respond "*spali/.github/commits/$1*" -
}

releases() { gh_respond '*spali/a/releases?per_page=100*' - <<<"$1"; }
pulls() { gh_respond '*spali/a/pulls*' - <<<"$1"; }
tags() { gh_respond '*spali/a/tags*' - <<<"$1"; }

# Registered responses are first-match-wins: a test's own answers come first,
# the defaults (appended here) only fill what it did not set.
run_script() {
  latest_release v1.1.0 2026-11-01T00:00:00Z
  releases '[]'
  pulls '[]'
  tags '[]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

# count CHECK prints the number of findings of that check.
count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" 'map(select(.check == $c)) | .[0].message' "$FINDINGS"; }

@test "dev build of closed PR 7 is red" {
  releases '[{"tag_name":"v1.0.0-pr.7","draft":false,"prerelease":true}]'
  pulls '[{"number":8}]'
  run_script
  [ "$(count devbuild-closed-pr)" -eq 1 ]
  [ "$(message devbuild-closed-pr)" = "v1.0.0-pr.7: PR #7 is not open" ]
  [ "$(jq -rs '.[0].level' "$FINDINGS")" = red ]
  [ "$(jq -rs '.[0].repo' "$FINDINGS")" = spali/a ]
}

@test "dev build of open PR 7 is fine" {
  releases '[{"tag_name":"v1.0.0-pr.7","draft":false,"prerelease":true}]'
  pulls '[{"number":7}]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "orphan -next tag is red" {
  tags '[{"name":"v1.0.0-next","commit":{"sha":"abc"}}]'
  run_script
  [ "$(count orphan-tag)" -eq 1 ]
  [ "$(message orphan-tag)" = "v1.0.0-next has no release" ]
}

@test "orphan PR tag is red" {
  tags '[{"name":"v1.0.0-pr.3","commit":{"sha":"abc"}},{"name":"v1.0.0","commit":{"sha":"abc"}}]'
  run_script
  [ "$(count orphan-tag)" -eq 1 ]
  [ "$(message orphan-tag)" = "v1.0.0-pr.3 has no release" ]
}

@test "-next tag with a release is fine" {
  tags '[{"name":"v1.0.0-next","commit":{"sha":"abc"}}]'
  releases '[{"tag_name":"v1.0.0-next","draft":false,"prerelease":true,"created_at":"2026-11-10T00:00:00Z","published_at":"2026-11-10T00:00:00Z"}]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "two drafts are red" {
  releases '[{"tag_name":"v1.0.0","draft":true,"prerelease":false,"published_at":null},{"tag_name":"v1.1.0","draft":true,"prerelease":false,"published_at":null}]'
  run_script
  [ "$(count several-drafts)" -eq 1 ]
  [ "$(message several-drafts)" = "drafts: v1.0.0, v1.1.0" ]
}

@test "one draft is fine" {
  releases '[{"tag_name":"v1.0.0","draft":true,"prerelease":false,"published_at":null}]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "-next older than last release is red" {
  releases '[{"tag_name":"v1.0.0","draft":false,"prerelease":false,"created_at":"2026-11-05T00:00:00Z","published_at":"2026-11-05T00:00:00Z"},
    {"tag_name":"v1.1.0-next","draft":false,"prerelease":true,"created_at":"2026-11-01T00:00:00Z","published_at":"2026-11-01T00:00:00Z"},
    {"tag_name":"v1.2.0","draft":true,"prerelease":false,"created_at":"2026-11-09T00:00:00Z","published_at":null}]'
  run_script
  [ "$(count next-stale)" -eq 1 ]
  [ "$(message next-stale)" = "v1.1.0-next is older than v1.0.0" ]
}

@test "-next newer than last release is fine" {
  releases '[{"tag_name":"v1.0.0","draft":false,"prerelease":false,"created_at":"2026-11-01T00:00:00Z","published_at":"2026-11-01T00:00:00Z"},
    {"tag_name":"v1.1.0-next","draft":false,"prerelease":true,"created_at":"2026-11-05T00:00:00Z","published_at":"2026-11-05T00:00:00Z"}]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "pin behind an 8-day-old release is red" {
  latest_release v1.1.0 2026-11-06T00:00:00Z
  inventory '[{"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"}]'
  run_script
  [ "$(count pin-behind)" -eq 1 ]
  [ "$(message pin-behind)" = "pr.yml pinned to v1.0.0, latest v1.1.0" ]
}

@test "pin behind a 3-day-old release is fine" {
  latest_release v1.1.0 2026-11-11T12:00:00Z
  inventory '[{"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"}]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "pin on the latest sha is fine" {
  inventory '[{"workflow":"pr.yml","sha":"ffffffffffffffffffffffffffffffffffffffff","version":"v1.1.0"}]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "duplicate pins give one finding, sha7 without version" {
  inventory '[{"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"},
    {"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"},
    {"workflow":"release.yml","sha":"1234567890abcdef1234567890abcdef12345678","version":null}]'
  run_script
  [ "$(count pin-behind)" -eq 1 ]
  [ "$(message pin-behind)" = "pr.yml pinned to v1.0.0, release.yml pinned to 1234567, latest v1.1.0" ]
}

@test "reads two pages of releases" {
  { echo '[{"tag_name":"v1.0.0-pr.1","draft":false,"prerelease":true}]'
    echo '[{"tag_name":"v1.0.0-pr.2","draft":false,"prerelease":true}]'; } | releases "$(cat)"
  run_script
  [ "$(count devbuild-closed-pr)" -eq 2 ]
  [[ "$(gh_calls)" == *"repos/spali/a/releases?per_page=100 --paginate"* ]]
}

@test "failed releases call gives check-failed and other checks still run" {
  gh_fail '*spali/a/releases?per_page=100*' 'gh: Server Error (HTTP 502)'
  latest_release v1.1.0 2026-11-06T00:00:00Z
  inventory '[{"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"}]'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count pin-behind)" -eq 1 ]
  [ "$(count devbuild-closed-pr)" -eq 0 ]
  [[ "$(gh_calls)" != *spali/a/tags* ]]
}

@test "failed spali/.github lookup skips pin-behind" {
  gh_fail '*spali/.github/releases/latest*' 'gh: Server Error (HTTP 500)'
  inventory '[{"workflow":"pr.yml","sha":"6f26c6b1dcac0797c52055241f0cfb74a797ebe3","version":"v1.0.0"}]'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count pin-behind)" -eq 0 ]
}

@test "non-central repos are not queried" {
  run_script
  [[ "$(gh_calls)" != *spali/skip* ]]
}
