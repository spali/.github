#!/usr/bin/env bats
# monitor.sh matrix and MONITOR_REPO: the jobs of each check group (one per
# repository with monitor.jobs per-repo, else one for all) and the runner.

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
  # central, pinned caller, plain repo, fork, fork without parent, fork with
  # an entry and a plain repo with an entry (o/gone has an entry but does not
  # exist)
  jq -n '[
    {name: "o/central", central: true, fork: false, private: false, default_branch: "main", pins: []},
    {name: "o/caller", central: false, fork: false, private: true, default_branch: "main",
     pins: [{workflow: "monitor.yml", sha: "abc"}]},
    {name: "o/plain", central: false, fork: false, private: false, default_branch: "main", pins: []},
    {name: "o/fork", central: false, fork: true, private: false, default_branch: "main",
     parent: {name: "up/fork", default_branch: "dev"}, pins: []},
    {name: "o/orphan", central: false, fork: true, private: false, default_branch: "main", parent: null, pins: []},
    {name: "o/MFork", central: false, fork: true, private: false, default_branch: "main",
     parent: {name: "up/mfork", default_branch: "main"}, pins: []},
    {name: "o/mplain", central: false, fork: false, private: false, default_branch: "main", pins: []}]' >"$MONITOR_WORK/inventory.json"
  jq -n '{version: 1, lists: {}, ignores: [], monitor: {jobs: "per-repo"},
    forks: [{repo: "o/mplain", upstream: "https://src.example/p.git"},
      {repo: "o/mfork", upstream: "https://github.com/up/mfork"},
      {repo: "o/gone", upstream: "https://github.com/up/gone"}]}' \
    >"$MONITOR_WORK/config.json"
}

@test "matrix prints the repositories of each check group" {
  run --separate-stderr "$MONITOR" matrix
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(jq -c . <<<"$output")" = '{"release":["o/caller","o/central"],"settings":["o/central"],"health":["o/caller","o/central","o/plain"],"forks":["o/MFork","o/fork","o/gone","o/mplain","o/orphan"],"runs-on":"ubuntu-latest"}' ]
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
  for g in release settings health forks; do
    want=$(checked_by "$g")
    got=$(jq -c --arg g "$g" '.[$g]' <<<"$matrix")
    [ "$got" = "$want" ] || { echo "$g: matrix $got, script $want"; return 1; }
  done
}

@test "MONITOR_REPO limits a check phase to one repository" {
  printf '#!/usr/bin/env bash\njq -c "[.[].name]" "$INVENTORY" >"%s/seen"\njq -c "[.forks[].repo]" "$CONFIG" >"%s/entries"\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/monitor-forks.sh"
  scripts=$BATS_TEST_TMPDIR/scripts
  mkdir -p "$scripts"
  cp "$BATS_TEST_DIRNAME"/../scripts/*.sh "$scripts"/
  cp "$BATS_TEST_TMPDIR/monitor-forks.sh" "$scripts"/
  chmod +x "$scripts"/*.sh
  MONITOR_SCRIPTS_DIR=$scripts MONITOR_REPO=o/MFork run --separate-stderr "$scripts/monitor.sh" forks
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = '["o/MFork"]' ]
  [ "$(cat "$BATS_TEST_TMPDIR/entries")" = '["o/mfork"]' ]
  # the shared files are not changed
  [ "$(jq length "$MONITOR_WORK/inventory.json")" -eq 7 ]
}

@test "MONITOR_REPO limits forks to one repository" {
  export GITHUB_REPOSITORY=ctl/x
  MONITOR_REPO=o/MFork run --separate-stderr "$MONITOR" forks
  grep -q 'api repos/o/MFork$' "$GH_LOG"
  run ! grep -E 'o/(gone|mplain|fork|orphan)|sync.yml' "$GH_LOG"
}

@test "MONITOR_REPO with lists is a usage error" {
  MONITOR_REPO=o/plain run --separate-stderr "$MONITOR" lists
  [ "$status" -eq 2 ]
  [ "$stderr" = "error: MONITOR_REPO does not apply to lists" ]
}

@test "matrix with an unreadable inventory keeps only the entries of the control file" {
  echo nope >"$MONITOR_WORK/inventory.json"
  run --separate-stderr "$MONITOR" matrix
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"release":[],"settings":[],"health":[],"forks":["o/gone","o/mfork","o/mplain"],"runs-on":"ubuntu-latest"}' ]
}

@test "matrix with an unreadable control file prints empty groups" {
  echo nope >"$MONITOR_WORK/inventory.json"
  echo nope >"$MONITOR_WORK/config.json"
  run --separate-stderr "$MONITOR" matrix
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"release":[],"settings":[],"health":[],"forks":[],"runs-on":"ubuntu-latest"}' ]
}

@test "per-group (the default) runs one job for all repositories of a group" {
  jq 'del(.monitor)' "$MONITOR_WORK/config.json" >"$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$MONITOR_WORK/config.json"
  run --separate-stderr "$MONITOR" matrix
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '{"release":[""],"settings":[""],"health":[""],"forks":[""],"runs-on":"ubuntu-latest"}' ]
}

@test "runs-on comes from the control file" {
  jq '.monitor = {"runs-on": ["self-hosted", "linux"]}' "$MONITOR_WORK/config.json" >"$BATS_TEST_TMPDIR/c" && mv "$BATS_TEST_TMPDIR/c" "$MONITOR_WORK/config.json"
  run --separate-stderr "$MONITOR" matrix
  [ "$(jq -c '."runs-on"' <<<"$output")" = '["self-hosted","linux"]' ]
}

@test "an empty MONITOR_REPO checks every repository of the group" {
  MONITOR_REPO='' run --separate-stderr "$MONITOR" settings
  [ -n "$output" ]
  [[ ${lines[-1]} == "settings: 1 repositories"* ]]
}
