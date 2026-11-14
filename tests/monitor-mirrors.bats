#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  load helpers/git-stub
  stub_gh
  stub_git
  FINDINGS="$BATS_TEST_TMPDIR/f.jsonl"
  INVENTORY="$BATS_TEST_TMPDIR/inventory.json"
  CONFIG="$BATS_TEST_TMPDIR/config.json"
  export FINDINGS INVENTORY CONFIG
  : >"$FINDINGS"
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-14T12:00:00Z +%s)
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-mirrors.sh"
  jq -n '{mirrors: [{target: "spali/m", source: "https://src.example/m.git", interval_hours: 24}]}' >"$CONFIG"
  inventory false 2026-11-01T00:00:00Z
}

SRC='*ls-remote --heads --tags https://src.example/m.git'
TGT='*ls-remote --heads --tags https://github.com/spali/m.git'

# inventory PRIVATE PUSHED_AT
inventory() {
  jq -n --argjson p "$1" --arg t "$2" \
    '[{name: "spali/m", private: $p, fork: false, default_branch: "main", pushed_at: $t}]' >"$INVENTORY"
}

# sha N prints a 40 character hex string.
sha() { printf '%040d' "$1"; }

# refs "NAME:N ..." prints ls-remote lines.
refs() {
  local e
  for e in "$@"; do printf '%s\t%s\n' "$(sha "${e#*:}")" "${e%%:*}"; done
}

run_script() {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].level' "$FINDINGS"; }

@test "synced mirror has no findings" {
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
  grep -q 'ls-remote --heads --tags' "$GIT_LOG"
}

@test "mirror with differing ref and old push is red" {
  refs refs/heads/main:1 refs/heads/dev:3 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:9 refs/tags/v1:2 | git_respond "$TGT" -
  run_script
  [ "$(count mirror-behind)" -eq 1 ]
  [ "$(level mirror-behind)" = red ]
  [ "$(message mirror-behind)" = "2 refs differ, last push 2026-11-01T00:00:00Z" ]
}

@test "differing ref 30 hours after the last push is fine" {
  inventory false 2026-11-13T06:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:9 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "differing ref 49 hours after the last push is red" {
  inventory false 2026-11-12T11:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:9 | git_respond "$TGT" -
  run_script
  [ "$(count mirror-behind)" -eq 1 ]
}

@test "empty public target differs" {
  refs refs/heads/main:1 | git_respond "$SRC" -
  git_respond "$TGT" /dev/null
  run_script
  [ "$(message mirror-behind)" = "1 refs differ, last push 2026-11-01T00:00:00Z" ]
}

@test "empty private target differs" {
  inventory true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  echo '[]' | gh_respond '*matching-refs/heads --paginate' -
  echo '[]' | gh_respond '*matching-refs/tags --paginate' -
  run_script
  [ "$(message mirror-behind)" = "1 refs differ, last push 2026-11-01T00:00:00Z" ]
}

@test "mirror with extra target refs only is fine" {
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:1 refs/heads/release/v1:5 refs/tags/v9:6 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "peeled tag lines are ignored" {
  { refs refs/tags/v1:2; printf '%s\t%s\n' "$(sha 7)" 'refs/tags/v1^{}'; } | git_respond "$SRC" -
  refs refs/tags/v1:2 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "unreachable mirror source is check-failed" {
  git_fail "$SRC" 'fatal: unable to access (secret-url)'
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(level check-failed)" = red ]
  [ "$(message check-failed)" = "mirror-behind: cannot read source" ]
  [ "$(count mirror-behind)" -eq 0 ]
}

@test "unreachable public target is check-failed" {
  refs refs/heads/main:1 | git_respond "$SRC" -
  git_fail "$TGT" 'fatal: repository not found'
  run_script
  [ "$(message check-failed)" = "mirror-behind: cannot read target" ]
}

@test "private target is read through the API and never named in messages" {
  inventory true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  jq -nc --arg s "$(sha 9)" '[{ref: "refs/heads/main", object: {sha: $s}}]' |
    gh_respond '*repos/spali/m/git/matching-refs/heads --paginate' -
  jq -nc --arg s "$(sha 2)" '[{ref: "refs/tags/v1", object: {sha: $s}}]' |
    gh_respond '*repos/spali/m/git/matching-refs/tags --paginate' -
  run_script
  [ "$(count mirror-behind)" -eq 1 ]
  [ "$(message mirror-behind)" = "1 refs differ, last push 2026-11-01T00:00:00Z" ]
  run ! grep -q 'github.com/spali/m' "$GIT_LOG"
}

@test "private target API failure does not leak the repository" {
  inventory true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  gh_fail '*matching-refs*' 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -ge 1 ]
}

@test "target missing from the inventory is check-failed" {
  echo '[]' >"$INVENTORY"
  refs refs/heads/main:1 | git_respond "$SRC" -
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "mirror-behind: target not visible" ]
}

@test "git runs without prompts under a timeout" {
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  grep -q "timeout 120" "$SCRIPT"
  grep -q "GIT_TERMINAL_PROMPT=0" "$SCRIPT"
}

@test "large ref lists are handled" {
  for i in $(seq 1 6000); do printf '%s\trefs/tags/v%s\n' "$(sha "$i")" "$i"; done >"$BATS_TEST_TMPDIR/big"
  [ "$(wc -c <"$BATS_TEST_TMPDIR/big")" -gt 200000 ]
  git_respond "$SRC" "$BATS_TEST_TMPDIR/big"
  { head -n 5999 "$BATS_TEST_TMPDIR/big"; printf '%s\t%s\n' "$(sha 1)" refs/tags/v6000; } |
    git_respond "$TGT" -
  run_script
  [ "$(count mirror-behind)" -eq 1 ]
  [ "$(message mirror-behind)" = "1 refs differ, last push 2026-11-01T00:00:00Z" ]
}
