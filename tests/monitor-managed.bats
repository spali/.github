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
  echo '[]' >"$INVENTORY"
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-14T12:00:00Z +%s)
  export GITHUB_REPOSITORY=ctl/x
  unset MONITOR_SKIP_SYNC MONITOR_CHECKED
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-managed.sh"
  # a fork: default branch main (upstream default dev), feat rebased
  # automatically onto main, wip rebased by hand onto dev
  jq -n '{version: 1, managed: [{repo: "spali/f", upstream: "https://github.com/up/f.git",
    branches: {feat: {onto: "main", rebase: "auto"}, wip: {onto: "dev", rebase: "manual"}}}]}' >"$CONFIG"
}

# sha N prints a 40 character hex string.
sha() { printf '%040d' "$1"; }

REPO='*api repos/spali/f'
ACT='*repos/spali/f/actions/permissions'
UP='*api repos/up/f'
TB='*repos/spali/f/branches?per_page=100 --paginate'
UB='*repos/up/f/branches?per_page=100 --paginate'
PRS='*repos/up/f/pulls?state=open&per_page=100 --paginate'
MAIN="*repos/up/f/compare/$(sha 1)...dev"
FEAT="*repos/up/f/compare/$(sha 2)...main"
WIP="*repos/up/f/compare/$(sha 3)...dev"
SYNC='*repos/ctl/x/actions/workflows/sync.yml/runs?per_page=1&status=completed'

respond_jq() { jq -nc "$2" | gh_respond "$1" -; }

# behind N DATE: a compare answer with N commits missing, the oldest from DATE.
behind() { printf '{ahead_by: %s, commits: [{commit: {committer: {date: "%s"}}}]}' "$1" "$2"; }

# Compliant defaults for everything the script reads; tests register their own
# answers first (first match wins).
run_script() {
  respond_jq "$SYNC" '{workflow_runs: [{conclusion: "success", html_url: "https://github.com/ctl/x/actions/runs/1"}]}'
  respond_jq "$REPO" '{default_branch: "main", private: false, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: false, has_pull_requests: false, has_wiki: false, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: false}'
  respond_jq "$UP" '{default_branch: "dev"}'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}}]' |
    gh_respond "$TB" -
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}]'
  respond_jq "$PRS" '[]'
  respond_jq '*repos/up/f/compare/*' '{ahead_by: 0, commits: []}'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].level' "$FINDINGS"; }
repo_of() { jq -rs --arg c "$1" 'map(select(.check == $c)) | .[0].repo' "$FINDINGS"; }

@test "compliant managed fork has no findings" {
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/f" ]
}

@test "missing repository is managed-missing" {
  gh_fail "$REPO" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(count managed-missing)" -eq 1 ]
  [ "$(level managed-missing)" = red ]
  [ "$(message managed-missing)" = "managed repository does not exist (the sync creates it)" ]
}

@test "missing repo stops the other checks" {
  gh_fail "$REPO" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
  run ! grep -E 'repos/(spali|up)/f/' "$GH_LOG"
}

@test "settings that differ are managed-settings" {
  respond_jq "$REPO" '{default_branch: "main", private: false, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: true, has_pull_requests: false, has_wiki: true, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: true}'
  run_script
  [ "$(count managed-settings)" -eq 1 ]
  [ "$(level managed-settings)" = red ]
  [ "$(message managed-settings)" = "has_issues is true, expected false; has_wiki is true, expected false; actions is true, expected false" ]
}

@test "declared settings exceptions are expected" {
  jq '.managed[0].settings = {has_issues: true, actions: true}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$REPO" '{default_branch: "main", private: false, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: true, has_pull_requests: false, has_wiki: false, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: true}'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "default branch behind upstream default is managed-behind" {
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(level managed-behind)" = red ]
  [ "$(message managed-behind)" = "main: 3 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
}

@test "auto branch behind its onto is managed-behind" {
  respond_jq "$FEAT" "$(behind 2 2026-11-10T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(message managed-behind)" = "feat: 2 upstream commits missing, oldest from 2026-11-10T00:00:00Z" ]
}

@test "behind less than 48 h is no finding" {
  respond_jq "$MAIN" "$(behind 1 2026-11-12T13:00:00Z)"
  respond_jq "$FEAT" "$(behind 1 2026-11-12T13:00:00Z)"
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "behind more than 48 h is red" {
  respond_jq "$MAIN" "$(behind 1 2026-11-12T11:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 1 ]
}

@test "declared default branch follows its declaration" {
  jq '.managed[0].branches.main = {onto: "dev", rebase: "manual"}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 0 ]
  [ "$(count rebase-pending)" -eq 1 ]
  [ "$(message rebase-pending)" = "main: 3 upstream commits to rebase onto dev" ]
}

@test "manual branch behind its onto is rebase-pending" {
  respond_jq "$WIP" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count rebase-pending)" -eq 1 ]
  [ "$(level rebase-pending)" = info ]
  [ "$(message rebase-pending)" = "wip: 2 upstream commits to rebase onto dev" ]
  [ "$(count managed-behind)" -eq 0 ]
}

@test "declared branch missing in the target is not compared" {
  jq -nc --arg a "$(sha 1)" '[{name: "main", commit: {sha: $a}}]' | gh_respond "$TB" -
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -F "compare/$(sha 2)" "$GH_LOG"
}

@test "undeclared branch with own commits is branch-undeclared" {
  jq -nc --arg a "$(sha 1)" --arg d "$(sha 4)" --arg e "$(sha 5)" \
    '[{name: "main", commit: {sha: $a}}, {name: "extra", commit: {sha: $d}}, {name: "dev", commit: {sha: $e}}]' |
    gh_respond "$TB" -
  respond_jq '*repos/up/f/compare/dev...spali:f:extra' '{ahead_by: 2}'
  respond_jq '*repos/up/f/compare/dev...spali:f:dev' '{ahead_by: 1}'
  run_script
  [ "$(count branch-undeclared)" -eq 2 ]
  [ "$(level branch-undeclared)" = red ]
  [ "$(message branch-undeclared 0)" = "extra: 2 own commits, not declared in repos.yml" ]
  [ "$(message branch-undeclared 1)" = "dev: 1 own commits, not declared in repos.yml" ]
}

@test "undeclared branch is compared with the upstream branch of the same name" {
  respond_jq '*repos/up/f/compare/main...spali:f:main' '{ahead_by: 4}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(message branch-undeclared)" = "main: 4 own commits, not declared in repos.yml" ]
  run ! grep -F 'compare/dev...spali:f:main' "$GH_LOG"
}

@test "contribution branch is not undeclared" {
  jq -nc --arg a "$(sha 1)" --arg d "$(sha 4)" \
    '[{name: "main", commit: {sha: $a}}, {name: "fix-x", commit: {sha: $d}}]' | gh_respond "$TB" -
  respond_jq "$PRS" '[{head: {repo: {full_name: "other/f"}, ref: "main"}},
    {head: {repo: null, ref: "fix-x"}}, {head: {repo: {full_name: "Spali/F"}, ref: "fix-x"}}]'
  respond_jq '*repos/up/f/compare/dev...spali:f:fix-x' '{ahead_by: 3}'
  run_script
  [ "$(count branch-undeclared)" -eq 0 ]
  run ! grep -F 'spali:f:fix-x' "$GH_LOG"
}

@test "API error is check-failed" {
  gh_fail "$MAIN" 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(level check-failed)" = red ]
  [ "$(repo_of check-failed)" = spali/f ]
  [ "$(count managed-behind)" -eq 0 ]
}

@test "repository API error other than 404 is check-failed" {
  gh_fail "$REPO" 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "managed-missing: gh: Server Error (HTTP 502)" ]
  [ "$(count managed-missing)" -eq 0 ]
}

@test "failed sync run is sync-failed" {
  respond_jq "$SYNC" '{workflow_runs: [{conclusion: "failure", html_url: "https://github.com/ctl/x/actions/runs/9"}]}'
  run_script
  [ "$(count sync-failed)" -eq 1 ]
  [ "$(level sync-failed)" = red ]
  [ "$(repo_of sync-failed)" = null ]
  [ "$(message sync-failed)" = "last sync run failed: https://github.com/ctl/x/actions/runs/9" ]
}

@test "no sync run yet is no finding" {
  respond_jq "$SYNC" '{total_count: 0, workflow_runs: []}'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "local run skips sync-failed" {
  unset GITHUB_REPOSITORY
  run_script
  [ "$(count sync-failed)" -eq 1 ]
  [ "$(level sync-failed)" = skip ]
  [ "$(message sync-failed)" = "sync-failed: no control repository (local run)" ]
  run ! grep -F 'sync.yml' "$GH_LOG"
}

@test "MONITOR_SKIP_SYNC leaves sync-failed to another job" {
  export MONITOR_SKIP_SYNC=1
  respond_jq "$SYNC" '{workflow_runs: [{conclusion: "failure", html_url: "u"}]}'
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -F 'sync.yml' "$GH_LOG"
}

# --- mirrors and refs: all -----------------------------------------------

SRC='*ls-remote --heads --tags https://src.example/m.git'
TGT='*ls-remote --heads --tags https://github.com/spali/m.git'
MREPO='*api repos/spali/m'

# refs "NAME:N ..." prints ls-remote lines.
refs() {
  local e
  for e in "$@"; do printf '%s\t%s\n' "$(sha "${e#*:}")" "${e%%:*}"; done
}

mirror() {
  jq -n '{version: 1, managed: [{repo: "spali/m", upstream: "https://src.example/m.git"}]}' >"$CONFIG"
  respond_jq '*api repos/spali/m/actions/permissions' '{enabled: false}'
}

# mirror_repo PRIVATE PUSHED_AT
mirror_repo() {
  respond_jq "$MREPO" "{default_branch: \"main\", private: $1, pushed_at: \"$2\",
    has_issues: false, has_pull_requests: false, has_wiki: false, has_discussions: false, has_projects: false}"
}

@test "synced mirror has no findings" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:1 refs/tags/v1:2 refs/heads/extra:7 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -F 'compare' "$GH_LOG"
  run ! grep -F 'branches' "$GH_LOG"
}

@test "mirror with differing refs is managed-behind" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/heads/dev:3 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:9 refs/tags/v1:2 | git_respond "$TGT" -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(level managed-behind)" = red ]
  [ "$(message managed-behind)" = "2 refs differ, last push 2026-11-01T00:00:00Z" ]
}

@test "mirror pushed less than 48 h ago is no finding" {
  mirror
  mirror_repo false 2026-11-12T13:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:9 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "private mirror is read through the API" {
  mirror
  mirror_repo true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  jq -nc --arg s "$(sha 9)" '[{ref: "refs/heads/main", object: {sha: $s}}]' |
    gh_respond '*repos/spali/m/git/matching-refs/heads --paginate' -
  echo '[]' | gh_respond '*repos/spali/m/git/matching-refs/tags --paginate' -
  run_script
  [ "$(message managed-behind)" = "1 refs differ, last push 2026-11-01T00:00:00Z" ]
  run ! grep -q 'github.com/spali/m' "$GIT_LOG"
}

@test "private mirror API failure is check-failed of managed-behind" {
  mirror
  mirror_repo true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  gh_fail '*matching-refs*' 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "managed-behind: gh: Server Error (HTTP 502)" ]
}

@test "unreachable upstream is check-failed" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  git_fail "$SRC" 'fatal: unable to access'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "managed-behind: cannot read upstream" ]
}

@test "fork with refs all compares refs except declared branches" {
  jq '.managed[0].refs = "all"' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  refs refs/heads/dev:1 refs/heads/main:5 refs/heads/feat:6 refs/heads/wip:7 refs/tags/v1:8 |
    git_respond '*ls-remote --heads --tags https://github.com/up/f.git' -
  refs refs/heads/dev:1 refs/heads/main:5 refs/heads/feat:2 refs/heads/wip:3 |
    git_respond '*ls-remote --heads --tags https://github.com/spali/f.git' -
  respond_jq "$WIP" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(message managed-behind)" = "1 refs differ, last push 2026-11-01T00:00:00Z" ]
  [ "$(count rebase-pending)" -eq 1 ]
  # the default branch is part of the ref comparison, not compared on its own
  run ! grep -F "compare/$(sha 1)...dev" "$GH_LOG"
}

@test "several managed repositories are all checked" {
  jq '.managed += [{repo: "spali/m", upstream: "https://src.example/m.git"}]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  gh_fail "$MREPO" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "$(printf 'spali/f\nspali/m')" ]
  [ "$(count managed-missing)" -eq 1 ]
  [ "$(repo_of managed-missing)" = spali/m ]
}

@test "large payloads are handled" {
  head -c 250000 /dev/zero | tr '\0' x >"$BATS_TEST_TMPDIR/big"
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '{ahead_by: 2, commits: [
    {commit: {message: $big, committer: {date: "2026-11-01T00:00:00Z"}}}]}' | gh_respond "$MAIN" -
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[{head: {repo: {full_name: "o/x"}, ref: "main"}, body: $big}]' | gh_respond "$PRS" -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}
