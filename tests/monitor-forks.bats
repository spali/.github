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
  unset MONITOR_CHECKED FORK_KINDS
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-forks.sh"
  # a fork: default branch main (upstream default dev), feat rebased
  # automatically onto main, wip rebased by hand onto dev
  jq -n '{version: 1, forks: [{repo: "spali/f", upstream: "https://github.com/up/f.git",
    branches: {feat: {onto: "main", rebase: "auto"}, wip: {onto: "dev", rebase: "manual"}}}]}' >"$CONFIG"
}

# sha N prints a 40 character hex string.
sha() { printf '%040d' "$1"; }

REPO='*api repos/spali/f'
ACT='*repos/spali/f/actions/permissions'
APPROVAL='*repos/spali/f/actions/permissions/fork-pr-contributor-approval'
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
  respond_jq "$APPROVAL" '{approval_policy: "all_external_contributors"}'
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

@test "compliant synced fork has no findings" {
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -q fork-pr-contributor-approval "$GH_LOG"
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/f" ]
}

@test "missing repository is fork-missing" {
  gh_fail "$REPO" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(count fork-missing)" -eq 1 ]
  [ "$(level fork-missing)" = red ]
  [ "$(message fork-missing)" = "repository does not exist (the sync creates a fork)" ]
}

@test "missing repo stops the other checks" {
  gh_fail "$REPO" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
  run ! grep -E 'repos/(spali|up)/f/' "$GH_LOG"
}

@test "archived synced repo is one fork-settings finding and no further checks" {
  respond_jq "$REPO" '{archived: true, default_branch: "main", private: false, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: true, has_pull_requests: false, has_wiki: true, has_discussions: false, has_projects: false}'
  run_script
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
  [ "$(count fork-settings)" -eq 1 ]
  [ "$(level fork-settings)" = red ]
  [ "$(message fork-settings)" = 'archived but synced: pin it or remove its entry from `forks:`' ]
  [ "$(repo_of fork-settings)" = spali/f ]
  run ! grep -E 'repos/(spali|up)/f/' "$GH_LOG"
}

@test "settings that differ are fork-settings" {
  respond_jq "$REPO" '{default_branch: "main", private: false, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: true, has_pull_requests: false, has_wiki: true, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: true}'
  run_script
  [ "$(count fork-settings)" -eq 1 ]
  [ "$(level fork-settings)" = red ]
  [ "$(message fork-settings)" = "has_issues is true, expected false; has_wiki is true, expected false; actions is true, expected false" ]
}

@test "declared settings exceptions are expected" {
  jq '.forks[0].settings = {has_issues: true, actions: true}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$REPO" '{default_branch: "main", private: false, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: true, has_pull_requests: false, has_wiki: false, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: true}'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "default branch behind upstream default is fork-behind" {
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = red ]
  [ "$(message fork-behind)" = "main: 3 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
}

@test "auto branch behind its onto is fork-behind" {
  respond_jq "$FEAT" "$(behind 2 2026-11-10T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(message fork-behind)" = "feat: 2 upstream commits missing, oldest from 2026-11-10T00:00:00Z" ]
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
  [ "$(count fork-behind)" -eq 1 ]
}

@test "declared default branch follows its declaration" {
  jq '.forks[0].branches.main = {onto: "dev", rebase: "manual"}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 0 ]
  [ "$(count rebase-pending)" -eq 1 ]
  [ "$(message rebase-pending)" = "main: 3 upstream commits to rebase onto dev" ]
}

@test "manual branch behind its onto is rebase-pending" {
  respond_jq "$WIP" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count rebase-pending)" -eq 1 ]
  [ "$(level rebase-pending)" = info ]
  [ "$(message rebase-pending)" = "wip: 2 upstream commits to rebase onto dev" ]
  [ "$(count fork-behind)" -eq 0 ]
}

@test "declared branch missing in the target is fork-behind" {
  jq -nc --arg a "$(sha 1)" --arg c "$(sha 3)" '[{name: "main", commit: {sha: $a}}, {name: "wip", commit: {sha: $c}}]' |
    gh_respond "$TB" -
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = red ]
  [ "$(message fork-behind)" = "feat: missing in the target" ]
  run ! grep -F "compare/$(sha 2)" "$GH_LOG"
}

@test "declared branches missing in the target are fork-behind" {
  jq -nc --arg a "$(sha 1)" '[{name: "main", commit: {sha: $a}}]' | gh_respond "$TB" -
  run_script
  [ "$(count fork-behind)" -eq 2 ]
  [ "$(message fork-behind 0)" = "feat: missing in the target" ]
  [ "$(message fork-behind 1)" = "wip: missing in the target" ]
}

@test "contribution heads are not fork-behind" {
  # the sync never writes the head of an open upstream PR from the fork
  open_on main '[{head: {repo: {full_name: "Spali/F"}, ref: "main"}, created_at: "2026-11-01T00:00:00Z"}]'
  open_on feat '[{head: {repo: {full_name: "spali/f"}, ref: "feat"}, created_at: "2026-11-01T00:00:00Z"}]'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  respond_jq "$FEAT" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 0 ]
  [ ! -s "$FINDINGS" ]
}

@test "a PR head of another repository is still fork-behind" {
  open_on main '[{head: {repo: {full_name: "other/f"}, ref: "main"}}]'
  open_on feat '[{head: {repo: null, ref: "feat"}}]'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  respond_jq "$FEAT" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 2 ]
}

@test "contribution heads are excluded from followed branches" {
  jq '.forks[0].follow = [".*"]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "fix"}]'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" --arg f "$(sha 7)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}},
      {name: "dev", commit: {sha: $a}}, {name: "fix", commit: {sha: $f}}]' | gh_respond "$TB" -
  open_on fix '[{head: {repo: {full_name: "spali/f"}, ref: "fix"}, created_at: "2026-11-01T00:00:00Z"}]'
  respond_jq "*repos/up/f/compare/$(sha 7)...fix" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 0 ]
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
  open_on 'fix%2Fa%231' '[{head: {repo: {full_name: "spali/f"}, ref: "fix/a#1"}, created_at: "2026-11-01T00:00:00Z"}]'
  run_script
  grep -qF 'repos/up/f/pulls?state=open&head=spali:fix%2Fa%231&per_page=100 --paginate' "$GH_LOG"
}

@test "open pulls API error is check-failed and still checks behind" {
  gh_fail "$PRS" 'gh: Server Error (HTTP 502)'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count fork-behind)" -eq 1 ]
}

# follow: release branches rel/* are synced by name; rel/1 exists in the
# target (sha 6), rel/2 does not, other only upstream.
follow() {
  jq '.forks[0].follow = ["rel/.*"]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "rel/1"}, {name: "other"}]'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" --arg r "$(sha 6)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}},
      {name: "rel/1", commit: {sha: $r}}]' | gh_respond "$TB" -
}

@test "followed branch behind more than 48 h is fork-behind" {
  follow
  respond_jq "*repos/up/f/compare/$(sha 6)...rel%2F1" "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = red ]
  [ "$(message fork-behind)" = "rel/1: 2 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
}

@test "followed branch missing in the target is fork-behind" {
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "rel/1"}, {name: "rel/2"}]'
  follow
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = red ]
  [ "$(message fork-behind)" = "rel/2: missing in the target" ]
}

@test "unfollowed upstream branch is no finding" {
  follow
  respond_jq '*compare/*...other' "$(behind 2 2026-11-01T00:00:00Z)"
  run_script
  [ ! -s "$FINDINGS" ]
  run ! grep -F 'other' "$GH_LOG"
}

@test "compare URLs are encoded" {
  jq '.forks[0].follow = ["fix/.*"] | .forks[0].branches["x/a#1"] = {onto: "fix/a#1", rebase: "auto"}' \
    "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$UB" '[{name: "dev"}, {name: "main"}, {name: "fix/a#1"}]'
  jq -nc --arg a "$(sha 1)" --arg b "$(sha 2)" --arg c "$(sha 3)" --arg d "$(sha 4)" --arg e "$(sha 5)" \
    '[{name: "main", commit: {sha: $a}}, {name: "feat", commit: {sha: $b}}, {name: "wip", commit: {sha: $c}},
      {name: "fix/a#1", commit: {sha: $d}}, {name: "x/a#1", commit: {sha: $e}}, {name: "o/b#2", commit: {sha: $e}}]' |
    gh_respond "$TB" -
  run_script
  grep -qF "repos/up/f/compare/$(sha 4)...fix%2Fa%231" "$GH_LOG"
  grep -qF "repos/up/f/compare/$(sha 5)...fix%2Fa%231" "$GH_LOG"
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
  [ "$(count fork-behind)" -eq 0 ]
}

@test "repository API error other than 404 is check-failed" {
  gh_fail "$REPO" 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "fork-missing: gh: Server Error (HTTP 502)" ]
  [ "$(count fork-missing)" -eq 0 ]
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
  jq -n '{version: 1, forks: [{repo: "spali/m", upstream: "https://src.example/m.git"}]}' >"$CONFIG"
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
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(level fork-behind)" = red ]
  [ "$(message fork-behind)" = "2 tags differ, last push 2026-11-01T00:00:00Z" ]
}

@test "mirror with tags false ignores tags" {
  mirror
  jq '.forks[0].tags = false' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
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
  [ "$(count fork-behind)" -eq 1 ]
}

@test "mirror default branch behind is compared in the mirror" {
  mirror
  mirror_repo false 2026-11-13T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:9 | git_respond "$TGT" -
  respond_jq "$MCMP$(sha 9)...$(sha 1)" "$(behind 3 2026-11-01T00:00:00Z)"
  respond_jq "$MCMP$(sha 1)...$(sha 9)" '{ahead_by: 0}'
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(message fork-behind)" = "main: 3 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
}

# behind_mirror PUSHED_AT: main and the followed rel/1 lack the upstream
# commit, rel/2 is missing, wip (manual onto main) is behind.
behind_mirror() {
  mirror
  jq '.forks[0].follow = ["rel/.*"] | .forks[0].branches = {wip: {onto: "main", rebase: "manual"}}' \
    "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  mirror_repo false "$1"
  refs refs/heads/main:1 refs/heads/rel/1:2 refs/heads/rel/2:4 | git_respond "$SRC" -
  refs refs/heads/main:9 refs/heads/rel/1:8 refs/heads/wip:7 | git_respond "$TGT" -
  no_commit '*'
}

@test "mirror branch without the upstream commit differs after 48 h" {
  behind_mirror 2026-11-01T00:00:00Z
  run_script
  [ "$(count fork-behind)" -eq 3 ]
  [ "$(message fork-behind 0)" = "main: differs from upstream, last push 2026-11-01T00:00:00Z" ]
  [ "$(message fork-behind 1)" = "rel/1: differs from upstream, last push 2026-11-01T00:00:00Z" ]
  [ "$(message fork-behind 2)" = "rel/2: missing in the target" ]
  [ "$(count rebase-pending)" -eq 1 ]
  [ "$(message rebase-pending)" = "wip: upstream commits to rebase onto main" ]
}

@test "mirror branch without the upstream commit and a recent push is not red yet" {
  behind_mirror 2026-11-13T00:00:00Z
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(message fork-behind)" = "rel/2: missing in the target" ]
}

@test "mirror without upstream default branch is check-failed" {
  git_fail "$HEAD_SRC" 'fatal: unable to access'
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "fork-behind: cannot read the upstream default branch" ]
}

@test "private mirror is read through the API" {
  mirror
  mirror_repo true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 refs/tags/v1:2 | git_respond "$SRC" -
  jq -nc --arg s "$(sha 1)" '[{ref: "refs/heads/main", object: {sha: $s}}]' |
    gh_respond '*repos/spali/m/git/matching-refs/heads --paginate' -
  echo '[]' | gh_respond '*repos/spali/m/git/matching-refs/tags --paginate' -
  run_script
  [ "$(message fork-behind)" = "1 tags differ, last push 2026-11-01T00:00:00Z" ]
  run ! grep -q 'github.com/spali/m' "$GIT_LOG"
}

@test "private mirror API failure is check-failed of fork-behind" {
  mirror
  mirror_repo true 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  gh_fail '*matching-refs*' 'gh: Server Error (HTTP 502)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "fork-behind: gh: Server Error (HTTP 502)" ]
}

@test "unreachable upstream is check-failed" {
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  git_fail "$SRC" 'fatal: unable to access'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "fork-behind: cannot read upstream" ]
}

@test "fork tags are compared with upstream" {
  refs refs/heads/dev:1 refs/heads/main:5 refs/tags/v1:8 refs/tags/v2:6 |
    git_respond '*ls-remote --heads --tags https://github.com/up/f.git' -
  refs refs/heads/dev:1 refs/heads/main:1 refs/tags/v2:6 |
    git_respond '*ls-remote --heads --tags https://github.com/spali/f.git' -
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(message fork-behind)" = "1 tags differ, last push 2026-11-01T00:00:00Z" ]
  # tags false: not read at all
  : >"$FINDINGS"
  : >"$GIT_LOG"
  jq '.forks[0].tags = false' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  run_script
  [ ! -s "$FINDINGS" ]
  [ ! -s "$GIT_LOG" ]
}

@test "several forks and mirrors are all checked" {
  jq '.forks += [{repo: "spali/m", upstream: "https://src.example/m.git"}]' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  gh_fail "$MREPO" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "$(printf 'spali/f\nspali/m')" ]
  [ "$(count fork-missing)" -eq 1 ]
  [ "$(repo_of fork-missing)" = spali/m ]
}

@test "large payloads are handled" {
  head -c 250000 /dev/zero | tr '\0' x >"$BATS_TEST_TMPDIR/big"
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '{ahead_by: 2, commits: [
    {commit: {message: $big, committer: {date: "2026-11-01T00:00:00Z"}}}]}' | gh_respond "$MAIN" -
  jq -nc --rawfile big "$BATS_TEST_TMPDIR/big" '[{head: {repo: {full_name: "o/x"}, ref: "main"}, body: $big}]' |
    gh_respond '*repos/up/f/pulls?state=open&head=spali:main&per_page=100 --paginate' -
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}

@test "fork approval red is reported for a synced fork" {
  jq '.forks[0].settings = {actions: true}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$ACT" '{enabled: true}'
  respond_jq "$APPROVAL" '{approval_policy: "first_time_contributors"}'
  run_script
  [ "$(count settings-fork-approval)" -eq 1 ]
  [ "$(level settings-fork-approval)" = red ]
  [ "$(message settings-fork-approval)" = 'approval_policy: got "first_time_contributors", want "all_external_contributors"' ]
  [ "$(repo_of settings-fork-approval)" = spali/f ]
}

@test "private fork skips fork approval" {
  jq '.forks[0].settings = {actions: true}' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$REPO" '{default_branch: "main", private: true, pushed_at: "2026-11-01T00:00:00Z",
    has_issues: false, has_pull_requests: false, has_wiki: false, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: true}'
  run_script
  [ "$(count settings-fork-approval)" -eq 1 ]
  [ "$(level settings-fork-approval)" = skip ]
  [ "$(message settings-fork-approval)" = "private repository" ]
  run ! grep -q fork-pr-contributor-approval "$GH_LOG"
}

@test "stale-branch: a declared fork branch whose upstream pull request was merged is info after new commits" {
  jq -nc '[{number: 12, state: "closed", merged_at: "2026-11-01T00:00:00Z", created_at: "2026-10-01T00:00:00Z",
    html_url: "https://github.com/up/f/pull/12", head: {ref: "feat", sha: "old", repo: {full_name: "spali/f"}}}]' |
    gh_respond '*repos/up/f/pulls?state=all&head=spali:feat&per_page=100 --paginate' -
  run_script
  [ "$(count stale-branch)" -eq 1 ]
  [ "$(level stale-branch)" = info ]
  [ "$(message stale-branch)" = "feat: pull request up/f#12 is merged, the branch has newer commits: https://github.com/up/f/pull/12" ]
  run ! grep -q 'state=all&head=spali:main&' "$GH_LOG"
}

# --- delete candidates and old pull requests (synced and pinned forks) ----

OWN='*repos/up/f/compare/dev...spali:f:main'
closed_on() { respond_jq "*repos/up/f/pulls?state=closed&head=spali:$1&per_page=100 --paginate" "$2"; }
only_main() {
  jq -nc --arg a "$(sha 1)" '[{name: "main", commit: {sha: $a}}]' | gh_respond "$TB" -
}

@test "pure fork without PR is a delete candidate" {
  jq '.forks[0] |= del(.branches)' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  only_main
  run_script
  [ "$(count fork-delete-candidate)" -eq 1 ]
  [ "$(level fork-delete-candidate)" = info ]
  [ "$(message fork-delete-candidate)" = "no own commits, no open pull request upstream" ]
  ! grep -q 'state=closed' "$GH_LOG"
}

@test "fork with own commits on the default branch is not a candidate" {
  jq '.forks[0] |= del(.branches)' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  only_main
  respond_jq "$OWN" '{ahead_by: 2}'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "fork with a branch missing upstream is not a candidate, unless its PR was merged" {
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
  grep -qF 'repos/up/f/pulls?state=closed&head=spali:feat&per_page=100' "$GH_LOG"
  : >"$FINDINGS"
  closed_on feat '[{head: {ref: "feat", repo: {full_name: "spali/f"}}}]'
  closed_on wip '[{head: {ref: "wip", repo: {full_name: "spali/f"}}}, {head: {ref: "x", repo: {full_name: "o/f"}}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 1 ]
}

@test "fork with an open upstream PR is not a candidate" {
  jq '.forks[0] |= del(.branches)' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  only_main
  open_on main '[{head: {repo: {full_name: "other/x"}, ref: "main"}}, {head: {repo: null, ref: "main"}},
    {number: 1, created_at: "2026-11-10T00:00:00Z", html_url: "u", head: {repo: {full_name: "spali/f"}, ref: "main"}}]'
  run_script
  [ "$(count fork-delete-candidate)" -eq 0 ]
}

@test "PR open 91 days is contribution-stale, 89 days is not" {
  open_on feat "$(jq -nc --arg d "$(date -u -d '2026-11-14T12:00:00Z - 91 days' +%FT%TZ)" \
    '[{number: 12, created_at: $d, html_url: "https://github.com/up/f/pull/12", head: {ref: "feat", repo: {full_name: "spali/f"}}},
      {number: 3, created_at: "2020-01-01T00:00:00Z", html_url: "u", head: {ref: "feat", repo: {full_name: "o/f"}}}]')"
  run_script
  [ "$(count contribution-stale)" -eq 1 ]
  [ "$(level contribution-stale)" = info ]
  [ "$(message contribution-stale)" = "PR #12 open for 91 days: https://github.com/up/f/pull/12" ]
  : >"$FINDINGS"
  : >"$GH_RESPONSES"
  open_on feat "$(jq -nc --arg d "$(date -u -d '2026-11-14T12:00:00Z - 89 days' +%FT%TZ)" \
    '[{number: 12, created_at: $d, html_url: "u", head: {ref: "feat", repo: {full_name: "spali/f"}}}]')"
  run_script
  [ "$(count contribution-stale)" -eq 0 ]
}

# --- forks without an entry, entries without upstream, pinned ------------

@test "an inventory fork without an entry is checked with the defaults" {
  echo '{"version": 1, "forks": []}' >"$CONFIG"
  jq -n '[{name: "spali/f", fork: true, private: false, default_branch: "main",
    parent: {name: "up/f", default_branch: "dev"}}]' >"$INVENTORY"
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(count fork-behind)" -eq 1 ]
  [ "$(message fork-behind)" = "main: 3 upstream commits missing, oldest from 2026-11-01T00:00:00Z" ]
  # the declared branches of the old config are gone: feat and wip are left alone
  run ! grep -F "$(sha 2)" "$GH_LOG"
}

@test "an entry without upstream takes the parent of the repository" {
  echo '{"version": 1, "forks": [{"repo": "spali/f"}]}' >"$CONFIG"
  respond_jq "$REPO" '{fork: true, parent: {full_name: "up/f"}, default_branch: "main", private: false,
    pushed_at: "2026-11-01T00:00:00Z", has_issues: false, has_pull_requests: false, has_wiki: false,
    has_discussions: false, has_projects: false}'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  run_script
  [ "$(jq -sc 'map(.check)' "$FINDINGS")" = '["fork-behind"]' ]
}

@test "an entry without upstream that is no fork is check-failed" {
  echo '{"version": 1, "forks": [{"repo": "spali/f"}]}' >"$CONFIG"
  respond_jq "$REPO" '{fork: false, default_branch: "main", private: false}'
  run_script
  [ "$(jq -sc 'map([.level, .check, .message])' "$FINDINGS")" = '[["red","check-failed","fork-behind: no upstream: not a fork on GitHub, set upstream under `forks:`"]]' ]
}

@test "a pinned fork gets no settings, behind or tag checks" {
  jq '.forks[0].pinned = true' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$REPO" '{default_branch: "main", private: false, pushed_at: "2020-01-01T00:00:00Z",
    has_issues: true, has_pull_requests: true, has_wiki: true, has_discussions: false, has_projects: false}'
  respond_jq "$ACT" '{enabled: true}'
  respond_jq "$MAIN" "$(behind 3 2026-11-01T00:00:00Z)"
  only_main
  run_script
  [ "$(jq -sc 'map(.check)' "$FINDINGS")" = '["fork-delete-candidate"]' ]
  run ! grep -F 'compare/0' "$GH_LOG"
  run ! grep -q ls-remote "$GIT_LOG"
}

@test "a pinned mirror gets only the fork approval check" {
  echo '{"version": 1, "forks": [{"repo": "spali/f", "upstream": "https://example.org/f.git", "pinned": true}]}' >"$CONFIG"
  respond_jq "$ACT" '{enabled: true}'
  respond_jq "$APPROVAL" '{approval_policy: "first_time_contributors"}'
  run_script
  [ "$(jq -sc 'map(.check)' "$FINDINGS")" = '["settings-fork-approval"]' ]
  run ! grep -q ls-remote "$GIT_LOG"
}

@test "an archived pinned repository has no finding" {
  jq '.forks[0].pinned = true' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  respond_jq "$REPO" '{archived: true, default_branch: "main", private: false}'
  run_script
  [ ! -s "$FINDINGS" ]
}

# --- the kind of each fork or mirror (FORK_KINDS) ------------------------

kinds() { jq -sc 'map([.repo, .kind, .pinned, .own, .pulls, .upstream])' "$FORK_KINDS"; }

@test "a fork without own commits or pull requests is unchanged" {
  export FORK_KINDS="$BATS_TEST_TMPDIR/kinds.jsonl"
  run_script
  [ "$(kinds)" = '[["spali/f","unchanged",false,0,[],"up/f"]]' ]
  # one comparison of the default branch serves the kind and the delete candidate
  [ "$(grep -c 'compare/dev...spali:f:main' "$GH_LOG")" -eq 1 ]
}

@test "own commits make a fork customized, an open pull request a contribution" {
  export FORK_KINDS="$BATS_TEST_TMPDIR/kinds.jsonl"
  respond_jq "$OWN" '{ahead_by: 2}'
  run_script
  [ "$(kinds)" = '[["spali/f","customized",false,2,[],"up/f"]]' ]
  : >"$FORK_KINDS"
  : >"$GH_RESPONSES"
  respond_jq "$OWN" '{ahead_by: 2}'
  open_on feat '[{number: 5, created_at: "2026-11-10T00:00:00Z", html_url: "u", head: {repo: {full_name: "spali/f"}, ref: "feat"}},
    {number: 6, created_at: "2026-11-10T00:00:00Z", html_url: "u", head: {repo: {full_name: "o/f"}, ref: "feat"}}]'
  run_script
  [ "$(kinds)" = '[["spali/f","contribution",false,2,[5],"up/f"]]' ]
}

@test "a pinned fork and a mirror record their kind too" {
  export FORK_KINDS="$BATS_TEST_TMPDIR/kinds.jsonl"
  jq '.forks[0].pinned = true' "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
  only_main
  run_script
  [ "$(kinds)" = '[["spali/f","unchanged",true,0,[],"up/f"]]' ]
  : >"$FORK_KINDS"
  : >"$GH_RESPONSES"
  mirror
  mirror_repo false 2026-11-01T00:00:00Z
  refs refs/heads/main:1 | git_respond "$SRC" -
  refs refs/heads/main:1 | git_respond "$TGT" -
  run_script
  [ "$(jq -sc 'map([.repo, .kind, .pinned, .own])' "$FORK_KINDS")" = '[["spali/m","mirror",false,null]]' ]
}

@test "without FORK_KINDS nothing is recorded" {
  run_script
  [ ! -e "$BATS_TEST_TMPDIR/kinds.jsonl" ]
}
