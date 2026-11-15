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
  echo '{"mirrors":[],"forks":[]}' >"$CONFIG"
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-14T12:00:00Z +%s)
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-forks.sh"
  jq -n '[{name: "spali/f", fork: true, default_branch: "main",
    parent: {name: "up/f", default_branch: "dev"}}]' >"$INVENTORY"
}

BEHIND='*repos/spali/f/compare/main...up:dev'
WFS='*repos/spali/f/actions/workflows?per_page=100'
OWN='*repos/up/f/compare/dev...spali:f:main'
PRS='*repos/up/f/pulls?state=open&per_page=100 --paginate'
FB='*repos/spali/f/branches?per_page=100 --paginate'
PB='*repos/up/f/branches?per_page=100 --paginate'

respond_jq() { jq -nc "$2" | gh_respond "$1" -; }

# Defaults: in sync, one active workflow, own commits present (no candidate).
run_script() {
  respond_jq "$BEHIND" '{ahead_by: 0, commits: []}'
  respond_jq "$WFS" '{workflows: []}'
  respond_jq "$OWN" '{ahead_by: 1}'
  respond_jq "$PRS" '[]'
  respond_jq "$FB" '[{name: "main"}]'
  respond_jq "$PB" '[{name: "dev"}, {name: "main"}]'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].level' "$FINDINGS"; }

synced() { echo '{"forks":[{"repo":"spali/f","sync_interval_hours":168}],"mirrors":[]}' >"$CONFIG"; }

@test "compliant fork has no findings" {
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/f" ]
}

@test "synced fork 3 days behind is red" {
  synced
  respond_jq "$BEHIND" '{ahead_by: 7, commits: [{commit: {committer: {date: "2026-11-01T00:00:00Z"}}}]}'
  run_script
  [ "$(count fork-sync-stale)" -eq 1 ]
  [ "$(level fork-sync-stale)" = red ]
  [ "$(message fork-sync-stale)" = "7 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
  [ "$(count fork-behind)" -eq 0 ]
}

@test "synced fork with a commit from 10 hours ago missing is fine" {
  synced
  respond_jq "$BEHIND" '{ahead_by: 1, commits: [{commit: {committer: {date: "2026-11-14T02:00:00Z"}}}]}'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "synced fork with a commit missing 178 hours is within the grace" {
  synced
  respond_jq "$BEHIND" '{ahead_by: 1, commits: [{commit: {committer: {date: "2026-11-07T02:00:00Z"}}}]}'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "synced fork with a commit missing 193 hours is red" {
  synced
  respond_jq "$BEHIND" '{ahead_by: 1, commits: [{commit: {committer: {date: "2026-11-06T11:00:00Z"}}}]}'
  run_script
  [ "$(count fork-sync-stale)" -eq 1 ]
}

@test "unsynced fork behind is info" {
  respond_jq "$BEHIND" '{ahead_by: 4, commits: [{commit: {committer: {date: "2026-01-01T00:00:00Z"}}}]}'
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = info ]
  [ "$(message fork-behind)" = "4 commits behind upstream" ]
  [ "$(count fork-sync-stale)" -eq 0 ]
}

@test "synced fork reports disabled workflows, not active ones" {
  synced
  jq -nc '{workflows: [
    {name: "Rebase Upstream", path: ".github/workflows/sync.yml", state: "disabled_inactivity"},
    {name: "CI", path: ".github/workflows/ci.yml", state: "active"}]}' | gh_respond "$WFS" -
  run_script
  [ "$(count workflow-disabled)" -eq 1 ]
  [ "$(level workflow-disabled)" = red ]
  [ "$(message workflow-disabled)" = "Rebase Upstream (.github/workflows/sync.yml) disabled by GitHub after 60 days of inactivity" ]
  [ "$(count fork-workflows-active)" -eq 0 ]
  [ "$(grep -c 'actions/workflows' "$GH_LOG")" -eq 1 ]
}

@test "other fork with active workflows is info" {
  jq -nc '{workflows: [
    {name: "A", path: "a.yml", state: "active"}, {name: "B", path: "b.yml", state: "active"},
    {name: "C", path: "c.yml", state: "disabled_inactivity"}]}' | gh_respond "$WFS" -
  run_script
  [ "$(count fork-workflows-active)" -eq 1 ]
  [ "$(level fork-workflows-active)" = info ]
  [ "$(message fork-workflows-active)" = "2 active workflows" ]
  [ "$(count workflow-disabled)" -eq 0 ]
  [ "$(grep -c 'actions/workflows' "$GH_LOG")" -eq 1 ]
}

@test "pure fork without PR is a delete candidate" {
  respond_jq "$OWN" '{ahead_by: 0}'
  run_script
  [ "$(count fork-delete-candidate)" -eq 1 ]
  [ "$(level fork-delete-candidate)" = info ]
  [ "$(message fork-delete-candidate)" = "no own commits, no open pull request upstream" ]
}

@test "fork with own branch commits is not a candidate" {
  respond_jq "$OWN" '{ahead_by: 2}'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "fork with a branch missing upstream is not a candidate" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}, {name: "feature"}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "fork with an open upstream PR is not a candidate" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$PRS" '[{head: {repo: {full_name: "other/x"}}}, {head: {repo: null}}, {head: {repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "open PRs of other forks and deleted head repos do not block" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$PRS" '[{head: {repo: {full_name: "other/x"}}}, {head: {repo: null}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 1 ]
}

@test "fork without parent, non-forks and mirror targets are out of scope" {
  jq -n '[
    {name: "spali/orphan", fork: true, default_branch: "main", parent: null},
    {name: "spali/plain", fork: false, default_branch: "main", parent: null},
    {name: "spali/m", fork: true, default_branch: "main", parent: {name: "up/m", default_branch: "main"}}]' >"$INVENTORY"
  echo '{"mirrors":[{"target":"spali/m"}],"forks":[]}' >"$CONFIG"
  run_script
  [ ! -s "$GH_LOG" ]
  [ ! -s "$FINDINGS" ]
}

@test "an API failure is check-failed" {
  gh_fail '*repos/spali/f/compare/*' 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -ge 1 ]
  [ "$(level check-failed)" = red ]
}

@test "large payloads are handled" {
  synced
  head -c 250000 /dev/zero | tr '\0' x >"$BATS_TEST_TMPDIR/big"
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '{ahead_by: 2, commits: [
    {commit: {message: $big, committer: {date: "2026-11-01T00:00:00Z"}}}]}' | gh_respond "$BEHIND" -
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[{head: {repo: {full_name: "o/x"}}, body: $big}]' | gh_respond "$PRS" -
  run_script
  [ "$(count fork-sync-stale)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}
