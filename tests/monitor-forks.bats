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
  echo '{"managed":[]}' >"$CONFIG"
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-14T12:00:00Z +%s)
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-forks.sh"
  jq -n '[{name: "spali/f", fork: true, default_branch: "main",
    parent: {name: "up/f", default_branch: "dev"}}]' >"$INVENTORY"
}

BEHIND='*repos/spali/f/compare/main...up:dev'
WFS='*repos/spali/f/actions/workflows?per_page=100'
PERMS='*repos/spali/f/actions/permissions'
APPROVAL='*repos/spali/f/actions/permissions/fork-pr-contributor-approval'
OWN='*repos/up/f/compare/dev...spali:f:main'
# pulls are looked up per fork branch: PRS/CLOSED answer every branch,
# open_on/closed_on BRANCH JSON one branch (the URL-encoded name)
PRS='*repos/up/f/pulls?state=open&head=spali:*&per_page=100 --paginate'
FB='*repos/spali/f/branches?per_page=100 --paginate'
PB='*repos/up/f/branches?per_page=100 --paginate'
FEATURE='*repos/up/f/compare/dev...spali:f:feature'
CLOSED='*repos/up/f/pulls?state=closed&head=spali:*&per_page=100 --paginate'

respond_jq() { jq -nc "$2" | gh_respond "$1" -; }
open_on() { respond_jq "*repos/up/f/pulls?state=open&head=spali:$1&per_page=100 --paginate" "$2"; }
closed_on() { respond_jq "*repos/up/f/pulls?state=closed&head=spali:$1&per_page=100 --paginate" "$2"; }

# Defaults: in sync, one active workflow, no own commits, a branch feature
# that upstream does not have (no candidate).
run_script() {
  respond_jq "$BEHIND" '{ahead_by: 0, commits: []}'
  respond_jq "$PERMS" '{enabled: true}'
  respond_jq "$APPROVAL" '{approval_policy: "all_external_contributors"}'
  respond_jq "$WFS" '{workflows: []}'
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$PRS" '[]'
  respond_jq "$FB" '[{name: "main"}, {name: "feature"}]'
  respond_jq "$PB" '[{name: "dev"}, {name: "main"}]'
  respond_jq "$CLOSED" '[]'
  respond_jq "$FEATURE" '{ahead_by: 0}'
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].level' "$FINDINGS"; }

@test "compliant fork has no findings" {
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/f" ]
}

@test "fork behind is info" {
  respond_jq "$BEHIND" '{ahead_by: 4}'
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = info ]
  [ "$(message fork-behind)" = "4 commits behind upstream" ]
}

@test "other fork with Actions disabled is clean, workflows are not read" {
  respond_jq "$PERMS" '{enabled: false}'
  jq -nc '{workflows: [{name: "A", path: "a.yml", state: "active"}]}' | gh_respond "$WFS" -
  run_script
  [ "$(count fork-workflows-active)" -eq 0 ]
  [ "$(count check-failed)" -eq 0 ]
  [ "$(grep -c 'actions/workflows' "$GH_LOG")" -eq 0 ]
}

@test "unreadable Actions permissions of a fork fail the check" {
  gh_fail "$PERMS" 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 2 ]
  [ "$(message check-failed 0)" = "fork-workflows-active: gh: Server Error (HTTP 502)" ]
  [ "$(message check-failed 1)" = "settings-fork-approval: gh: Server Error (HTTP 502)" ]
  [ "$(count fork-workflows-active)" -eq 0 ]
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
  respond_jq "$FB" '[{name: "main"}]'
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
  respond_jq "$FB" '[{name: "main"}]'
  open_on main '[{head: {repo: {full_name: "other/x"}}}, {head: {repo: null}}, {head: {repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "open PRs of other forks and deleted head repos do not block" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}]'
  open_on main '[{head: {repo: {full_name: "other/x"}}}, {head: {repo: null}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 1 ]
}

@test "fork without parent and non-forks are out of scope" {
  jq -n '[
    {name: "spali/orphan", fork: true, default_branch: "main", parent: null},
    {name: "spali/plain", fork: false, default_branch: "main", parent: null}]' >"$INVENTORY"
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
  head -c 250000 /dev/zero | tr '\0' x >"$BATS_TEST_TMPDIR/big"
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '{ahead_by: 2, commits: [
    {commit: {message: $big, committer: {date: "2026-11-01T00:00:00Z"}}}]}' | gh_respond "$BEHIND" -
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[{head: {repo: {full_name: "o/x"}}, body: $big}]' |
    gh_respond '*repos/up/f/pulls?state=open&head=spali:main&per_page=100 --paginate' -
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}

@test "managed fork is skipped by fork checks" {
  jq -n '[{name: "spali/F", fork: true, default_branch: "main",
    parent: {name: "up/f", default_branch: "dev"}}]' >"$INVENTORY"
  echo '{"managed":[{"repo":"spali/f","upstream":"https://github.com/up/f"}]}' >"$CONFIG"
  run_script
  [ ! -s "$GH_LOG" ]
  [ ! -s "$FINDINGS" ]
}

@test "own commits on an unmanaged fork are info" {
  respond_jq "$FB" '[{name: "main"}, {name: "feat"}, {name: "dev"}]'
  respond_jq "$PB" '[{name: "dev"}, {name: "main"}]'
  respond_jq '*repos/up/f/compare/dev...spali:f:feat' '{ahead_by: 3}'
  respond_jq '*repos/up/f/compare/dev...spali:f:dev' '{ahead_by: 0}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(level branch-undeclared)" = info ]
  [ "$(message branch-undeclared)" = "feat: 3 own commits, not declared in repos.yml" ]
}

@test "the default branch of an unmanaged fork is checked too" {
  respond_jq "$OWN" '{ahead_by: 2}'
  run_script
  [ "$(message branch-undeclared)" = "main: 2 own commits, not declared in repos.yml" ]
}

@test "the default branch of an unmanaged fork is compared with the upstream default" {
  respond_jq "$PB" '[{name: "dev"}, {name: "main"}]'
  respond_jq '*repos/up/f/compare/main...spali:f:main' '{ahead_by: 5}'
  run_script
  [ "$(count branch-undeclared)" -eq 0 ]
  run ! grep -F 'compare/main...spali:f:main' "$GH_LOG"
}

@test "a branch that is an open PR head is not undeclared" {
  respond_jq "$FB" '[{name: "main"}, {name: "feat"}]'
  respond_jq '*repos/up/f/compare/dev...spali:f:feat' '{ahead_by: 3}'
  open_on feat '[{number: 1, created_at: "2026-11-10T00:00:00Z", html_url: "u", head: {ref: "feat", repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(count branch-undeclared)" -eq 0 ]
}

@test "the open pulls are looked up once per fork branch" {
  respond_jq "$OWN" '{ahead_by: 0}'
  run_script
  [ "$(grep -c 'pulls?state=open' "$GH_LOG")" -eq 2 ]
  grep -qF 'repos/up/f/pulls?state=open&head=spali:main&per_page=100 --paginate' "$GH_LOG"
  grep -qF 'repos/up/f/pulls?state=open&head=spali:feature&per_page=100 --paginate' "$GH_LOG"
}

@test "upstream pulls are never listed without a head filter" {
  respond_jq "$OWN" '{ahead_by: 0}'
  run_script
  grep -q 'state=closed' "$GH_LOG"
  run ! grep -v 'head=spali:' <(grep 'pulls?' "$GH_LOG")
}

@test "branch names are URL-encoded in the head filter" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}, {name: "fix/a#1"}]'
  open_on 'fix%2Fa%231' '[{number: 4, created_at: "2020-01-01T00:00:00Z", html_url: "u", head: {ref: "fix/a#1", repo: {full_name: "spali/f"}}}]'
  run_script
  grep -qF 'repos/up/f/pulls?state=open&head=spali:fix%2Fa%231&per_page=100 --paginate' "$GH_LOG"
  [ "$(message contribution-stale)" = "PR #4 open for 2509 days: u" ]
}

@test "a branch missing upstream is looked up in the closed pulls URL-encoded" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}, {name: "fix/a#1"}]'
  closed_on 'fix%2Fa%231' '[{head: {ref: "fix/a#1", repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(grep -c 'state=closed' "$GH_LOG")" -eq 1 ]
  grep -qF 'repos/up/f/pulls?state=closed&head=spali:fix%2Fa%231&per_page=100 --paginate' "$GH_LOG"
  [ "$(count fork-delete-candidate)" -eq 1 ]
}

@test "open pulls API error is check-failed" {
  gh_fail "$PRS" 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "fork-delete-candidate: gh: Server Error (HTTP 502)" ]
}

pr_aged() {
  open_on feature "[{number: 12, created_at: \"$1\", html_url: \"https://github.com/up/f/pull/12\", head: {ref: \"feature\", repo: {full_name: \"spali/f\"}}}]"
}

@test "PR open 91 days is contribution-stale" {
  pr_aged "$(date -u -d '2026-11-14T12:00:00Z - 91 days' +%FT%TZ)"
  run_script
  [ "$(count contribution-stale)" -eq 1 ]
  [ "$(level contribution-stale)" = info ]
  [ "$(message contribution-stale)" = "PR #12 open for 91 days: https://github.com/up/f/pull/12" ]
}

@test "PR open 89 days is not" {
  pr_aged "$(date -u -d '2026-11-14T12:00:00Z - 89 days' +%FT%TZ)"
  run_script
  [ "$(count contribution-stale)" -eq 0 ]
}

@test "PR of another fork is not contribution-stale" {
  open_on main '[{number: 3, created_at: "2020-01-01T00:00:00Z", html_url: "u", head: {ref: "main", repo: {full_name: "o/f"}}}]'
  run_script
  [ "$(count contribution-stale)" -eq 0 ]
}

@test "merged PR branch does not block delete candidate" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}, {name: "feature"}]'
  closed_on feature '[{head: {ref: "feature", repo: {full_name: "spali/f"}}}, {head: {ref: "feature", repo: null}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 1 ]
}

@test "closed PR of another branch does not unblock delete candidate" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}, {name: "feature"}]'
  closed_on feature '[{head: {ref: "feature", repo: {full_name: "o/f"}}}, {head: {ref: "x", repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "open PR still blocks delete candidate" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}, {name: "feature"}]'
  open_on feature '[{number: 1, created_at: "2026-11-10T00:00:00Z", html_url: "u", head: {ref: "feature", repo: {full_name: "spali/f"}}}]'
  closed_on feature '[{head: {ref: "feature", repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "closed pulls are only fetched when a branch is missing upstream" {
  respond_jq "$OWN" '{ahead_by: 0}'
  respond_jq "$FB" '[{name: "main"}]'
  run_script
  ! grep -q 'state=closed' "$GH_LOG"
}

@test "compare URLs are encoded" {
  jq -n '[{name: "spali/f", fork: true, default_branch: "x/a#1",
    parent: {name: "up/f", default_branch: "rel/b#2"}}]' >"$INVENTORY"
  respond_jq '*repos/up/f/pulls?state=open&head=spali:*&per_page=100 --paginate' '[]'
  run_script
  grep -qF 'repos/spali/f/compare/x%2Fa%231...up:rel%2Fb%232' "$GH_LOG"
  grep -qF 'repos/up/f/compare/rel%2Fb%232...spali:f:x%2Fa%231' "$GH_LOG"
  grep -qF 'repos/up/f/compare/rel%2Fb%232...spali:f:feature' "$GH_LOG"
  run ! grep -E 'compare/[^ ]*#' "$GH_LOG"
}

@test "fork approval red is reported for a fork" {
  respond_jq "$APPROVAL" '{approval_policy: "first_time_contributors"}'
  run_script
  [ "$(count settings-fork-approval)" -eq 1 ]
  [ "$(level settings-fork-approval)" = red ]
  [ "$(message settings-fork-approval)" = 'approval_policy: got "first_time_contributors", want "all_external_contributors"' ]
}

@test "fork with Actions disabled has no fork approval finding" {
  respond_jq "$PERMS" '{enabled: false}'
  run_script
  [ "$(count settings-fork-approval)" -eq 0 ]
  run ! grep -q fork-pr-contributor-approval "$GH_LOG"
}

@test "private fork skips fork approval" {
  jq -n '[{name: "spali/f", fork: true, private: true, default_branch: "main",
    parent: {name: "up/f", default_branch: "dev"}}]' >"$INVENTORY"
  run_script
  [ "$(count settings-fork-approval)" -eq 1 ]
  [ "$(level settings-fork-approval)" = skip ]
  [ "$(message settings-fork-approval)" = "private repository" ]
  run ! grep -q fork-pr-contributor-approval "$GH_LOG"
}

@test "stale-branch: a fork branch of a merged upstream pull request is red" {
  respond_jq "$FB" '[{name: "main", commit: {sha: "m1"}}, {name: "feature", commit: {sha: "s1"}}]'
  respond_jq '*repos/up/f/pulls?state=all&head=spali:feature&per_page=100 --paginate' '[
    {number: 9, state: "closed", merged_at: "2026-11-01T00:00:00Z", created_at: "2026-10-01T00:00:00Z",
     html_url: "https://github.com/up/f/pull/9", head: {ref: "feature", sha: "s1", repo: {full_name: "spali/f"}}}]'
  run_script
  [ "$(count stale-branch)" -eq 1 ]
  [ "$(level stale-branch)" = red ]
  [ "$(message stale-branch)" = "feature: pull request up/f#9 is merged, delete the branch: https://github.com/up/f/pull/9" ]
  run ! grep -q 'head=spali:main&' <(grep 'state=all' "$GH_LOG")
}
