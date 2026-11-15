#!/usr/bin/env bats
# monitor.sh matrix and MONITOR_REPO: the repositories of each check group,
# one matrix job per repository.

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  load helpers/git-stub
  stub_gh
  stub_git
  MONITOR="$BATS_TEST_DIRNAME/../scripts/monitor.sh"
  export MONITOR_WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$MONITOR_WORK"
  : >"$MONITOR_WORK/findings.jsonl"
  unset MONITOR_REPO GITHUB_WORKFLOW_REF
  export GH_TOKEN=t
  # central, pinned caller, plain repo, fork, fork without parent, mirror
  jq -n '[
    {name: "o/central", central: true, fork: false, private: false, default_branch: "main", pins: []},
    {name: "o/caller", central: false, fork: false, private: true, default_branch: "main",
     pins: [{workflow: "monitor.yml", sha: "abc"}]},
    {name: "o/plain", central: false, fork: false, private: false, default_branch: "main", pins: []},
    {name: "o/fork", central: false, fork: true, private: false, default_branch: "main",
     parent: {name: "up/fork", default_branch: "dev"}, pins: []},
    {name: "o/orphan", central: false, fork: true, private: false, default_branch: "main", parent: null, pins: []},
    {name: "o/mirror", central: false, fork: false, private: false, default_branch: "main",
     pushed_at: "2026-11-01T00:00:00Z", pins: []}]' >"$MONITOR_WORK/inventory.json"
  jq -n '{version: 1, lists: {}, forks: [], ignores: [],
    mirrors: [{target: "o/mirror", source: "https://src.example/m.git", interval_hours: 24}]}' \
    >"$MONITOR_WORK/config.json"
}

@test "matrix prints the repositories of each check group" {
  run --separate-stderr "$MONITOR" matrix
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -c . <<<"$output")" = '{"release":["o/caller","o/central"],"settings":["o/central"],"health":["o/caller","o/central","o/plain"],"forks":["o/fork"],"mirrors":["o/mirror"]}' ]
}

# checked_by GROUP runs the real check script of GROUP over the inventory and
# prints the repositories it looked at, sorted, as a JSON array.
checked_by() {
  MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked-$1" \
    FINDINGS="$BATS_TEST_TMPDIR/f-$1.jsonl" INVENTORY="$MONITOR_WORK/inventory.json" \
    CONFIG="$MONITOR_WORK/config.json" \
    "$BATS_TEST_DIRNAME/../scripts/monitor-$1.sh" >/dev/null 2>&1 || true
  sort -u "$BATS_TEST_TMPDIR/checked-$1" 2>/dev/null | jq -Rsc 'split("\n") | map(select(. != ""))'
}

@test "matrix selects the same repositories as the check scripts" {
  run --separate-stderr "$MONITOR" matrix
  matrix=$output
  for g in release settings health forks mirrors; do
    want=$(checked_by "$g")
    got=$(jq -c --arg g "$g" '.[$g]' <<<"$matrix")
    [ "$got" = "$want" ] || { echo "$g: matrix $got, script $want"; return 1; }
  done
}

@test "MONITOR_REPO limits a check phase to one repository" {
  printf '#!/usr/bin/env bash\njq -c "[.[].name]" "$INVENTORY" >"%s/seen"\njq -c "[.mirrors[].target]" "$CONFIG" >"%s/mirrors"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/monitor-mirrors.sh"
  scripts=$BATS_TEST_TMPDIR/scripts
  mkdir -p "$scripts"
  cp "$BATS_TEST_DIRNAME"/../scripts/*.sh "$scripts"/
  cp "$BATS_TEST_TMPDIR/monitor-mirrors.sh" "$scripts"/
  chmod +x "$scripts"/*.sh
  MONITOR_SCRIPTS_DIR=$scripts MONITOR_REPO=o/mirror run --separate-stderr "$scripts/monitor.sh" mirrors
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = '["o/mirror"]' ]
  [ "$(cat "$BATS_TEST_TMPDIR/mirrors")" = '["o/mirror"]' ]
  # the shared files are not changed
  [ "$(jq length "$MONITOR_WORK/inventory.json")" -eq 6 ]
}

@test "MONITOR_REPO with lists is a usage error" {
  MONITOR_REPO=o/plain run --separate-stderr "$MONITOR" lists
  [ "$status" -eq 2 ]
  [ "$stderr" = "error: MONITOR_REPO does not apply to lists" ]
}

@test "matrix with an unreadable inventory prints empty groups" {
  echo nope >"$MONITOR_WORK/inventory.json"
  run --separate-stderr "$MONITOR" matrix
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"release":[],"settings":[],"health":[],"forks":[],"mirrors":[]}' ]
}
