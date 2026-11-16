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
  unset MONITOR_CHECKED
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
# open pulls are looked up per target branch: PRS answers every branch,
# open_on BRANCH JSON one branch (the URL-encoded name)
PRS='*repos/up/f/pulls?state=open&head=spali:*&per_page=100 --paginate'
MAIN="*repos/up/f/compare/$(sha 1)...dev"
FEAT="*repos/up/f/compare/$(sha 2)...main"
WIP="*repos/up/f/compare/$(sha 3)...dev"

respond_jq() { jq -nc "$2" | gh_respond "$1" -; }
open_on() { respond_jq "*repos/up/f/pulls?state=open&head=spali:$1&per_page=100 --paginate" "$2"; }

# behind N DATE: a compare answer with N commits missing, the oldest from DATE.
behind() { printf '{ahead_by: %s, commits: [{commit: {committer: {date: "%s"}}}]}' "$1" "$2"; }

# Compliant defaults for everything the script reads; tests register their own
# answers first (first match wins).
run_script() {
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
  respond_jq "$FEAT" "$(behind 1 2026-11-12T12:00:00Z)"
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "behind more than 48 h is red, to the second" {
  respond_jq "$MAIN" "$(behind 1 2026-11-12T11:59:59Z)"
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

@test "declared branch missing in the target is managed-behind" {
  jq -nc --arg a "$(sha 1)" --arg c "$(sha 3)" '[{name: "main", commit: {sha: $a}}, {name: "wip", commit: {sha: $c}}]' |
    gh_respond "$TB" -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(level managed-behind)" = red ]
  [ "$(message managed-behind)" = "feat: missing in the target" ]
  run ! grep -F "compare/$(sha 2)" "$GH_LOG"
}

@test "declared branches missing in the target are managed-behind" {
  jq -nc --arg a "$(sha 1)" '[{name: "main", commit: {sha: $a}}]' | gh_respond "$TB" -
  run_script
  [ "$(count managed-behind)" -eq 2 ]
  [ "$(message managed-behind 0)" = "feat: missing in the target" ]
  [ "$(message managed-behind 1)" = "wip: missing in the target" ]
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
  jq -nc --arg a "$(sha 1)" --arg d "$(sha 4)" \
    '[{name: "main", commit: {sha: $a}}, {name: "rel", commit: {sha: $d}}]' | gh_respond "$TB" -
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "rel"}]'
  respond_jq '*repos/up/f/compare/rel...spali:f:rel' '{ahead_by: 4}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(message branch-undeclared)" = "rel: 4 own commits, not declared in repos.yml" ]
  run ! grep -F 'compare/dev...spali:f:rel' "$GH_LOG"
}

@test "default branch with own commits is branch-undeclared" {
  respond_jq '*repos/up/f/compare/dev...spali:f:main' '{ahead_by: 4}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(level branch-undeclared)" = red ]
  [ "$(message branch-undeclared)" = "main: 4 own commits, not declared in repos.yml" ]
}

@test "default branch is compared with the upstream default, not the same name" {
  # upstream still has an old main; the target main follows upstream dev
  respond_jq '*repos/up/f/compare/main...spali:f:main' '{ahead_by: 9}'
  respond_jq '*repos/up/f/compare/dev...spali:f:main' '{ahead_by: 0}'
  run_script
  [ "$(count branch-undeclared)" -eq 0 ]
  run ! grep -F 'compare/main...spali:f:main' "$GH_LOG"
}

@test "with follow .* the default branch is still compared with the upstream default" {
  jq '.managed[0].follow = [".*"]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq '*repos/up/f/compare/main...spali:f:main' '{ahead_by: 0}'
  respond_jq '*repos/up/f/compare/dev...spali:f:main' '{ahead_by: 9}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(message branch-undeclared)" = "main: 9 own commits, not declared in repos.yml" ]
}

@test "declared default branch is not undeclared" {
  jq '.managed[0].branches.main = {onto: "dev", rebase: "auto"}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq '*repos/up/f/compare/*...spali:f:main' '{ahead_by: 4}'
  run_script
  [ "$(count branch-undeclared)" -eq 0 ]
  run ! grep -F 'spali:f:main' "$GH_LOG"
}

@test "contribution branch is not undeclared" {
  jq -nc --arg a "$(sha 1)" --arg d "$(sha 4)" \
    '[{name: "main", commit: {sha: $a}}, {name: "fix-x", commit: {sha: $d}}]' | gh_respond "$TB" -
  open_on fix-x '[{head: {repo: {full_name: "other/f"}, ref: "fix-x"}},
    {head: {repo: null, ref: "fix-x"}}, {head: {repo: {full_name: "Spali/F"}, ref: "fix-x"}}]'
  respond_jq '*repos/up/f/compare/dev...spali:f:fix-x' '{ahead_by: 3}'
  run_script
  [ "$(count branch-undeclared)" -eq 0 ]
  run ! grep -F 'spali:f:fix-x' "$GH_LOG"
}

@test "contribution heads are not managed-behind" {
  # the sync never writes the head of an open upstream PR from the fork
  open_on main '[{head: {repo: {full_name: "Spali/F"}, ref: "main"}}]'
  open_on feat '[{head: {repo: {full_name: "spali/f"}, ref: "feat"}}]'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  respond_jq "$FEAT" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 0 ]
  [ ! -s "$FINDINGS" ]
}

@test "a PR head of another repository is still managed-behind" {
  open_on main '[{head: {repo: {full_name: "other/f"}, ref: "main"}}]'
  open_on feat '[{head: {repo: null, ref: "feat"}}]'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  respond_jq "$FEAT" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 2 ]
}

@test "contribution heads are excluded from followed branches" {
  jq '.managed[0].follow = [".*"]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "fix"}]'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" --arg f "$(sha 7)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}},
      {name: "dev", commit: {sha: $a}}, {name: "fix", commit: {sha: $f}}]' | gh_respond "$TB" -
  open_on fix '[{head: {repo: {full_name: "spali/f"}, ref: "fix"}}]'
  respond_jq "*repos/up/f/compare/$(sha 7)...fix" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 0 ]
  run ! grep -F "compare/$(sha 7)" "$GH_LOG"
}

@test "open pulls are looked up once per target branch" {
  run_script
  [ "$(grep -c 'pulls?state=open' "$GH_LOG")" -eq 3 ]
  grep -qF 'repos/up/f/pulls?state=open&head=spali:wip&per_page=100 --paginate' "$GH_LOG"
}

@test "upstream pulls are never listed without a head filter" {
  run_script
  grep -q 'pulls?' "$GH_LOG"
  run ! grep -v 'head=spali:' <(grep 'pulls?' "$GH_LOG")
}

@test "branch names are URL-encoded in the head filter" {
  jq -nc --arg a "$(sha 1)" --arg d "$(sha 4)" \
    '[{name: "main", commit: {sha: $a}}, {name: "fix/a#1", commit: {sha: $d}}]' | gh_respond "$TB" -
  open_on 'fix%2Fa%231' '[{head: {repo: {full_name: "spali/f"}, ref: "fix/a#1"}}]'
  run_script
  grep -qF 'repos/up/f/pulls?state=open&head=spali:fix%2Fa%231&per_page=100 --paginate' "$GH_LOG"
  [ "$(count branch-undeclared)" -eq 0 ]
}

@test "open pulls API error is check-failed and still checks behind" {
  gh_fail "$PRS" 'gh: Server Error (HTTP 502)'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(count branch-undeclared)" -eq 0 ]
}

# follow: release branches rel/* are synced by name; rel/1 exists in the
# target (sha 6), rel/2 does not, other only upstream.
follow() {
  jq '.managed[0].follow = ["rel/.*"]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "rel/1"}, {name: "other"}]'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" --arg r "$(sha 6)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}},
      {name: "rel/1", commit: {sha: $r}}]' | gh_respond "$TB" -
}

@test "followed branch behind more than 48 h is managed-behind" {
  follow
  respond_jq "*repos/up/f/compare/$(sha 6)...rel%2F1" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(level managed-behind)" = red ]
  [ "$(message managed-behind)" = "rel/1: 2 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
}

@test "followed branch missing in the target is managed-behind" {
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "rel/1"}, {name: "rel/2"}]'
  follow
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(level managed-behind)" = red ]
  [ "$(message managed-behind)" = "rel/2: missing in the target" ]
}

@test "followed branch with own commits is compared with the same name upstream" {
  follow
  respond_jq '*repos/up/f/compare/rel%2F1...spali:f:rel%2F1' '{ahead_by: 3}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(message branch-undeclared)" = "rel/1: 3 own commits, not declared in repos.yml" ]
  run ! grep -F 'compare/dev...spali:f:rel' "$GH_LOG"
}

@test "unfollowed upstream branch is no finding" {
  follow
  respond_jq '*compare/*...other' "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -F 'other' "$GH_LOG"
}

@test "compare URLs are encoded" {
  jq '.managed[0].follow = ["fix/.*"] | .managed[0].branches["x/a#1"] = {onto: "fix/a#1", rebase: "auto"}' \
    "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "fix/a#1"}]'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" --arg d "$(sha 4)" --arg e "$(sha 5)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}},
      {name: "fix/a#1", commit: {sha: $d}}, {name: "x/a#1", commit: {sha: $e}}, {name: "o/b#2", commit: {sha: $e}}]' |
    gh_respond "$TB" -
  run_script
  grep -qF "repos/up/f/compare/$(sha 4)...fix%2Fa%231" "$GH_LOG"
  grep -qF "repos/up/f/compare/$(sha 5)...fix%2Fa%231" "$GH_LOG"
  grep -qF 'repos/up/f/compare/fix%2Fa%231...spali:f:fix%2Fa%231' "$GH_LOG"
  grep -qF 'repos/up/f/compare/dev...spali:f:o%2Fb%232' "$GH_LOG"
  run ! grep -E 'compare/[^ ]*#' "$GH_LOG"
}

@test "without follow the upstream branches are read once" {
  run_script
  [ "$(grep -c 'repos/up/f/branches' "$GH_LOG")" -eq 1 ]
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

# --- tags and mirrors ----------------------------------------------------

SRC='*ls-remote --heads --tags https://src.example/m.git'
TGT='*ls-remote --heads --tags https://github.com/spali/m.git'
HEAD_SRC='*ls-remote --symref -- https://src.example/m.git HEAD'
MREPO='*api repos/spali/m'
MCMP='*repos/spali/m/compare/'

# refs "NAME:N ..." prints ls-remote lines.
refs() {
  local e
  for e in "$@"; do printf '%s\t%s\n' "$(sha "${e#*:}")" "${e%%:*}"; done
}

# a mirror of src.example with default branch main up and down
mirror() {
  jq -n '{version: 1, managed: [{repo: "spali/m", upstream: "https://src.example/m.git"}]}' >"$CONFIG"
  respond_jq '*api repos/spali/m/actions/permissions' '{enabled: false}'
  printf 'ref: refs/heads/main\tHEAD\n%s\tHEAD\n' "$(sha 1)" | git_respond "$HEAD_SRC" -
}

# mirror_repo PRIVATE PUSHED_AT
mirror_repo() {
  respond_jq "$MREPO" "{default_branch: \"main\", private: $1, pushed_at: \"$2\",
    has_issues: false, has_pull_requests: false, has_wiki: false, has_discussions: false, has_projects: false}"
}

# no_commit: GitHub knows no such comparison (a commit is not in the mirror)
no_commit() { gh_fail "$MCMP$1" 'gh: Not Found (HTTP 404)'; }

@test "synced mirror has no findings" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 refs/heads/dev:3 | git_respond "$SRC" -
  refs refs/heads/main:1 refs/tags/v1:2 refs/heads/extra:7 | git_respond "$TGT" -
  respond_jq "${MCMP}main...extra" '{ahead_by: 0}'
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -vE '^api repos/spali/m(/actions/permissions|/compare/([0-9]{40}\.\.\.[0-9]{40}|main\.\.\.extra))?$' "$GH_LOG"
}

@test "mirror tags behind is red" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/heads/dev:3 refs/tags/v1:2 refs/tags/v2:4 refs/tags/v3:5 | git_respond "$SRC" -
  refs refs/heads/main:1 refs/tags/v1:2 refs/tags/v2:9 refs/tags/old:8 | git_respond "$TGT" -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(level managed-behind)" = red ]
  [ "$(message managed-behind)" = "2 tags differ, last push 2026-11-01T00:00:00Z" ]
}

@test "mirror with tags false ignores tags" {
  mirror
  jq '.managed[0].tags = false' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "mirror pushed exactly 48 h ago is no finding" {
  mirror
  mirror_repo false 2026-11-12T12:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "mirror pushed 48 h and a second ago is red" {
  mirror
  mirror_repo false 2026-11-12T11:59:59Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
}

@test "mirror default branch behind is compared in the mirror" {
  mirror
  mirror_repo false 2026-11-13T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:9 | git_respond "$TGT" -
  respond_jq "$MCMP$(sha 9)...$(sha 1)" "$(behind 3 2026-11-01T00:00:00Z)"
  respond_jq "$MCMP$(sha 1)...$(sha 9)" '{ahead_by: 0}'
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(message managed-behind)" = "main: 3 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
  [ "$(count branch-undeclared)" -eq 0 ]
}

# behind_mirror PUSHED_AT: main and the followed rel/1 lack the upstream
# commit, rel/2 is missing, wip (manual onto main) is behind.
behind_mirror() {
  mirror
  jq '.managed[0].follow = ["rel/.*"] | .managed[0].branches = {wip: {onto: "main", rebase: "manual"}}' \
    "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  mirror_repo false "$1"
  refs refs/heads/main:1 refs/heads/rel/1:2 refs/heads/rel/2:4 | git_respond "$SRC" -
  refs refs/heads/main:9 refs/heads/rel/1:8 refs/heads/wip:7 | git_respond "$TGT" -
  no_commit '*'
}

@test "mirror branch without the upstream commit differs after 48 h" {
  behind_mirror 2026-11-01T00:00:00Z
  run_script
  [ "$(count managed-behind)" -eq 3 ]
  [ "$(message managed-behind 0)" = "main: differs from upstream, last push 2026-11-01T00:00:00Z" ]
  [ "$(message managed-behind 1)" = "rel/1: differs from upstream, last push 2026-11-01T00:00:00Z" ]
  [ "$(message managed-behind 2)" = "rel/2: missing in the target" ]
  [ "$(count rebase-pending)" -eq 1 ]
  [ "$(message rebase-pending)" = "wip: upstream commits to rebase onto main" ]
  # default and followed branches are behind: the sync handles them, so no
  # branch-undeclared without a comparison
  [ "$(count branch-undeclared)" -eq 0 ]
}

@test "mirror branch without the upstream commit and a recent push is not red yet" {
  behind_mirror 2026-11-13T00:00:00Z
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(message managed-behind)" = "rel/2: missing in the target" ]
}

@test "mirror unfollowed branch is compared with the mirror default branch" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/heads/odd:5 refs/tags/v1:6 | git_respond "$SRC" -
  refs refs/heads/main:1 refs/heads/extra:7 refs/heads/odd:8 refs/heads/same:1 \
    refs/heads/copy:5 refs/heads/tagged:6 refs/heads/a/b:4 refs/tags/v1:6 | git_respond "$TGT" -
  respond_jq "${MCMP}main...extra" '{ahead_by: 2}'
  respond_jq "${MCMP}main...odd" '{ahead_by: 0}'
  respond_jq "${MCMP}main...a%2Fb" '{ahead_by: 1}'
  no_commit '*'
  run_script
  [ "$(count branch-undeclared)" -eq 2 ]
  [ "$(level branch-undeclared 0)" = info ]
  [ "$(level branch-undeclared 1)" = info ]
  [ "$(message branch-undeclared 0)" = "extra: differs from upstream, not followed (own commits or a stale upstream copy)" ]
  [ "$(message branch-undeclared 1)" = "a/b: differs from upstream, not followed (own commits or a stale upstream copy)" ]
  [ "$(jq -s 'map(select(.level == "red")) | length' "$FINDINGS")" -eq 0 ]
  # equal to an upstream branch or tag: no comparison at all
  run ! grep -E 'compare/main\.\.\.(same|copy|tagged)$' "$GH_LOG"
  run ! grep -E 'compare/[0-9]{40}\.\.\.' "$GH_LOG"
}

@test "mirror default branch with own commits stays red" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:9 | git_respond "$TGT" -
  respond_jq "$MCMP$(sha 1)...$(sha 9)" '{ahead_by: 2}'
  respond_jq "$MCMP$(sha 9)...$(sha 1)" '{ahead_by: 0}'
  run_script
  [ "$(count branch-undeclared)" -eq 1 ]
  [ "$(level branch-undeclared)" = red ]
  [ "$(message branch-undeclared)" = "main: 2 own commits, not declared in repos.yml" ]
}

@test "mirror without upstream default branch is check-failed" {
  git_fail "$HEAD_SRC" 'fatal: unable to access'
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "managed-behind: cannot read the upstream default branch" ]
}

@test "private mirror is read through the API" {
  mirror
  mirror_repo true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  jq -nc --arg s "$(sha 1)" '[{ref: "refs/heads/main", object: {sha: $s}}]' |
    gh_respond '*repos/spali/m/git/matching-refs/heads --paginate' -
  echo '[]' | gh_respond '*repos/spali/m/git/matching-refs/tags --paginate' -
  run_script
  [ "$(message managed-behind)" = "1 tags differ, last push 2026-11-01T00:00:00Z" ]
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

@test "fork tags are compared with upstream" {
  refs refs/heads/dev:1 refs/heads/main:5 refs/tags/v1:8 refs/tags/v2:6 |
    git_respond '*ls-remote --heads --tags https://github.com/up/f.git' -
  refs refs/heads/dev:1 refs/heads/main:1 refs/tags/v2:6 |
    git_respond '*ls-remote --heads --tags https://github.com/spali/f.git' -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(message managed-behind)" = "1 tags differ, last push 2026-11-01T00:00:00Z" ]
  # tags false: not read at all
  : >"$FINDINGS"
  : >"$GIT_LOG"
  jq '.managed[0].tags = false' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  run_script
  [ ! -s "$FINDINGS" ]
  [ ! -s "$GIT_LOG" ]
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
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[{head: {repo: {full_name: "o/x"}, ref: "main"}, body: $big}]' |
    gh_respond '*repos/up/f/pulls?state=open&head=spali:main&per_page=100 --paginate' -
  run_script
  [ "$(count managed-behind)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}
