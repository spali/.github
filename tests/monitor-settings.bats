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
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-settings.sh"
  inventory false
}

# inventory PRIVATE writes spali/a (central) plus a non-central repo that must
# be ignored.
inventory() {
  jq -n --argjson private "$1" '[
    {name: "spali/a", central: true, private: $private, pins: []},
    {name: "spali/skip", central: false, private: false, pins: []}]' >"$INVENTORY"
}

# Real answers recorded from a compliant repository (fixtures/monitor), with
# an optional jq filter to break one field: pvr_json 'FILTER'.
pvr_json() { jq -c "${1:-.}" "$FIX/settings-pvr.json" | gh_respond '*spali/a/private-vulnerability-reporting' -; }
actions_json() { jq -c "${1:-.}" "$FIX/settings-actions.json" | gh_respond '*spali/a/actions/permissions/workflow' -; }
list_json() { jq -c "${1:-.}" "$FIX/rulesets-list.json" | gh_respond '*repos/spali/a/rulesets' -; }
main_json() { jq -c "${1:-.}" "$FIX/ruleset-main.json" | gh_respond '*repos/spali/a/rulesets/27269150' -; }
tags_json() { jq -c "${1:-.}" "$FIX/ruleset-release-tags.json" | gh_respond '*repos/spali/a/rulesets/27269153' -; }

# Registered responses are first-match-wins: a test's own answers come first,
# the compliant defaults fill the rest.
run_script() {
  pvr_json
  actions_json
  list_json
  main_json
  tags_json
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" 'map(select(.check == $c)) | .[0].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" 'map(select(.check == $c)) | .[0].level' "$FINDINGS"; }

@test "compliant repo has no findings" {
  run_script
  [ ! -s "$FINDINGS" ]
  # only central repos are looked at
  run ! grep -q spali/skip "$GH_LOG"
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/a" ]
}

@test "settings-alerts is red when alerts are off" {
  gh_fail '*spali/a/vulnerability-alerts' 'gh: Vulnerability alerts are disabled. (HTTP 404)'
  run_script
  [ "$(count settings-alerts)" -eq 1 ]
  [ "$(level settings-alerts)" = red ]
  [ "$(message settings-alerts)" = "Dependabot alerts are off" ]
  [ "$(count check-failed)" -eq 0 ]
}

@test "vulnerability-alerts 404 is red, not check-failed" {
  gh_fail '*spali/a/vulnerability-alerts' 'Vulnerability alerts are disabled. (HTTP 404)'
  run_script
  [ "$(count settings-alerts)" -eq 1 ]
  [ "$(count check-failed)" -eq 0 ]
}

@test "other vulnerability-alerts errors are check-failed" {
  gh_fail '*spali/a/vulnerability-alerts' 'Server Error (HTTP 502)'
  run_script
  [ "$(count settings-alerts)" -eq 0 ]
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "settings-alerts: Server Error (HTTP 502)" ]
  [ "$(level check-failed)" = red ]
}

@test "settings-pvr is red when reporting is off" {
  pvr_json '.enabled = false'
  run_script
  [ "$(count settings-pvr)" -eq 1 ]
  [ "$(level settings-pvr)" = red ]
  [ "$(message settings-pvr)" = "enabled: got false, want true" ]
}

@test "private repo pvr is skipped" {
  inventory true
  run_script
  [ "$(level settings-pvr)" = skip ]
  [ "$(message settings-pvr)" = "private repository" ]
  run ! grep -q private-vulnerability-reporting "$GH_LOG"
}

@test "settings-actions is red for wrong workflow permissions" {
  actions_json '.default_workflow_permissions = "write" | .can_approve_pull_request_reviews = true'
  run_script
  [ "$(count settings-actions)" -eq 1 ]
  [ "$(message settings-actions)" = 'default_workflow_permissions: got "write", want "read"; can_approve_pull_request_reviews: got true, want false' ]
}

@test "ruleset-main is red when the ruleset is missing" {
  list_json 'map(select(.name != "main"))'
  run_script
  [ "$(message ruleset-main)" = "ruleset main missing" ]
  [ "$(level ruleset-main)" = red ]
  [ "$(count ruleset-tags)" -eq 0 ]
}

@test "ruleset-tags is red when the ruleset is missing" {
  list_json 'map(select(.name != "release tags"))'
  run_script
  [ "$(message ruleset-tags)" = "ruleset release tags missing" ]
  [ "$(count ruleset-main)" -eq 0 ]
}

@test "ruleset with a bypass actor is red" {
  main_json '.bypass_actors = [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]'
  run_script
  [ "$(count ruleset-main)" -eq 1 ]
  [ "$(level ruleset-main)" = red ]
  [ "$(message ruleset-main)" = "bypass_actors: got 1, want 0" ]
}

@test "ruleset-main lists every problem" {
  main_json '.enforcement = "evaluate"
    | .rules |= map(select(.type != "deletion"))
    | (.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods) = ["merge"]
    | (.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = [{"context": "Lint"}]'
  run_script
  [ "$(message ruleset-main)" = 'enforcement: got "evaluate", want "active"; rule deletion: missing; rule pull_request.allowed_merge_methods: got ["merge"], want ["rebase","squash"]; rule required_status_checks: context pr / check missing' ]
}

@test "ruleset-main accepts merge methods in any order" {
  main_json '(.rules[] | select(.type == "pull_request") | .parameters.allowed_merge_methods) = ["squash", "rebase"]'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "ruleset-main is red for a wrong target and ref" {
  main_json '.target = "tag" | .conditions.ref_name.include = ["refs/heads/main"] | .rules |= map(select(.type != "non_fast_forward" and .type != "pull_request" and .type != "required_status_checks"))'
  run_script
  [ "$(message ruleset-main)" = 'target: got "tag", want "branch"; include: got ["refs/heads/main"], want ["~DEFAULT_BRANCH"]; rule non_fast_forward: missing; rule pull_request: missing; rule required_status_checks: missing' ]
}

@test "ruleset-tags is red for wrong refs and extra rules" {
  tags_json '.conditions.ref_name.exclude = [] | .rules += [{"type": "deletion"}]'
  run_script
  [ "$(count ruleset-tags)" -eq 1 ]
  [ "$(message ruleset-tags)" = 'exclude: got [], want ["refs/tags/v*-next","refs/tags/v*-pr.*"]; rules: got ["update","deletion"], want ["update"]' ]
}

@test "ruleset-tags is red when not active" {
  tags_json '.enforcement = "disabled"'
  run_script
  [ "$(message ruleset-tags)" = 'enforcement: got "disabled", want "active"' ]
}

@test "rulesets on a private free repo are skipped" {
  inventory true
  gh_fail '*repos/spali/a/rulesets' 'Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
  run_script
  [ "$(level ruleset-main)" = skip ]
  [ "$(level ruleset-tags)" = skip ]
  [ "$(message ruleset-tags)" = "rulesets not available" ]
  [ "$(count check-failed)" -eq 0 ]
}

@test "a failing call is check-failed, never green" {
  gh_fail '*repos/spali/a/rulesets' 'rate limit (HTTP 403)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count ruleset-main)" -eq 0 ]
}

@test "unparsable answers are check-failed" {
  echo 'not json' | gh_respond '*spali/a/actions/permissions/workflow' -
  run_script
  [ "$(message check-failed)" = "settings-actions: cannot parse API response" ]
}

@test "a ruleset answer over 200 KB still produces the right findings" {
  main_json '.bypass_actors = [{"actor_id": 5}] | .description = ("x" * 250000)'
  run_script
  [ "$(message ruleset-main)" = "bypass_actors: got 1, want 0" ]
  [ "$(jq -s length "$FINDINGS")" -eq 1 ]
}

@test "an unparsable inventory is check-failed" {
  echo 'nope' >"$INVENTORY"
  run_script
  [ "$(message check-failed)" = "settings checks: cannot parse inventory" ]
}

@test "settings checks do not read the fork approval" {
  run_script
  run ! grep -q fork-pr-contributor-approval "$GH_LOG"
}

@test "settings checks do not read the merge settings (monitor-health.sh does)" {
  run_script
  run ! grep -q graphql "$GH_LOG"
}
