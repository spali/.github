#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/runner-online.sh"
  load helpers/gh-stub
  stub_gh
  export GITHUB_REPOSITORY=o/control
}

runners() {
  gh_respond 'api repos/o/control/actions/runners?per_page=100' -
}

@test "GitHub-hosted labels need no check" {
  run "$SCRIPT" '"ubuntu-latest"'
  [ "$status" -eq 0 ]
  [ "$output" = "runs-on: GitHub-hosted runner" ]
  [ ! -s "$GH_LOG" ]
  run "$SCRIPT" '["ubuntu-24.04"]'
  [ "$status" -eq 0 ]
  [ ! -s "$GH_LOG" ]
}

@test "an online runner with all labels passes, case-insensitive" {
  runners <<'EOF'
{"total_count": 2, "runners": [
  {"name": "r1", "status": "offline", "busy": false, "labels": [{"name": "self-hosted"}, {"name": "Linux"}]},
  {"name": "r2", "status": "online", "busy": true, "labels": [{"name": "self-hosted"}, {"name": "Linux"}, {"name": "X64"}]}
]}
EOF
  run "$SCRIPT" '["self-hosted", "linux"]'
  [ "$status" -eq 0 ]
  [ "$output" = "runs-on: 1 of 2 runners online with labels self-hosted, linux" ]
}

@test "a single self-hosted label string is checked too" {
  runners <<'EOF'
{"total_count": 1, "runners": [{"name": "r1", "status": "online", "labels": [{"name": "self-hosted"}]}]}
EOF
  run "$SCRIPT" '"self-hosted"'
  [ "$status" -eq 0 ]
  [[ $output == *"1 of 1 runners online"* ]]
}

@test "no online runner with the labels fails with what is registered" {
  runners <<'EOF'
{"total_count": 2, "runners": [
  {"name": "r1", "status": "offline", "labels": [{"name": "self-hosted"}, {"name": "Linux"}]},
  {"name": "r2", "status": "online", "labels": [{"name": "self-hosted"}, {"name": "Windows"}]}
]}
EOF
  run "$SCRIPT" '["self-hosted", "linux"]'
  [ "$status" -eq 1 ]
  [[ $output == *"error: no online self-hosted runner with the labels self-hosted, linux in o/control"* ]]
  [[ $output == *"registered: r1 (offline), r2 (online)"* ]]
  [[ $output == *"start a runner or change monitor.runs-on"* ]]
}

@test "no registered runner at all fails" {
  runners <<<'{"total_count": 0, "runners": []}'
  run "$SCRIPT" '["self-hosted"]'
  [ "$status" -eq 1 ]
  [[ $output == *"registered: none"* ]]
}

@test "an API error fails and names the permission" {
  gh_fail 'api repos/o/control/actions/runners*' 'HTTP 403: Resource not accessible by integration'
  run "$SCRIPT" '["self-hosted"]'
  [ "$status" -eq 1 ]
  [[ $output == *"cannot list the runners of o/control"*"Administration: read"* ]]
  [[ $output == *"HTTP 403"* ]]
}

@test "the runners are read with the given token from the calling repository" {
  runners <<<'{"total_count": 1, "runners": [{"name": "r", "status": "online", "labels": [{"name": "self-hosted"}]}]}'
  GH_TOKEN=tok run "$SCRIPT" '["self-hosted"]'
  [ "$status" -eq 0 ]
  [ "$(cat "$GH_LOG")" = "api repos/o/control/actions/runners?per_page=100" ]
  [ "$(cat "$GH_TOKENS")" = "tok" ]
}

@test "invalid input fails" {
  run "$SCRIPT" 'not json'
  [ "$status" -eq 1 ]
  [[ $output == *"error: runs-on must be a label or a list of labels"* ]]
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  unset GITHUB_REPOSITORY
  run "$SCRIPT" '["self-hosted"]'
  [ "$status" -eq 1 ]
  [[ $output == *"GITHUB_REPOSITORY is required"* ]]
}

@test "monitor: the checks start only after the runner check" {
  local wf="$BATS_TEST_DIRNAME/../.github/workflows/monitor.yml"
  run yq -r '.jobs.prepare.outputs.ready' "$wf"
  [ "$output" = '${{ steps.runner.outputs.ready }}' ]
  run yq -r '.jobs.prepare.steps[] | select(.id == "runner") | .env.GH_TOKEN' "$wf"
  [ "$output" = '${{ steps.app-token.outputs.token }}' ]
  run yq -r '.jobs.prepare.steps[] | select(.id == "runner") | .run' "$wf"
  [[ $output == *'runner-online.sh "$RUNNER"'$'\n''echo "ready=true"'* ]]
  run yq -r '.jobs.prepare.steps[] | select(.id == "matrix") | .run' "$wf"
  [[ $output != *ready* ]]
  run yq -r '.jobs.prepare.steps[] | select(.id == "app-token") | .with."permission-administration"' "$wf"
  [ "$output" = read ]
}

@test "sync: the plan checks a self-hosted runner with an Administration read token" {
  local wf="$BATS_TEST_DIRNAME/../.github/workflows/sync.yml"
  run yq -r '.jobs.plan.steps[] | select(.id == "runner-token") | .with."permission-administration"' "$wf"
  [ "$output" = read ]
  run yq -r '.jobs.plan.steps[] | select(.id == "runner-token") | .with.repositories' "$wf"
  [ "$output" = '${{ github.event.repository.name }}' ]
  run yq -r '.jobs.plan.steps[] | select(.id == "runner-token") | .if' "$wf"
  [[ $output == *"contains(steps.matrix.outputs.runner, 'self-hosted')"* ]]
  run yq -r '.jobs.plan.steps[] | select(.name == "Runner online") | .run' "$wf"
  [ "$output" = '.sync/scripts/runner-online.sh "$RUNNER"' ]
  run yq -r '.jobs.plan.steps[] | select(.name == "Runner online") | .env.GH_TOKEN' "$wf"
  [ "$output" = '${{ steps.runner-token.outputs.token }}' ]
}
