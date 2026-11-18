#!/usr/bin/env bats

setup() {
  # shellcheck source=scripts/managed-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/managed-lib.sh"
  load helpers/gh-stub
  stub_gh
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync-settings.sh"
  export GH_TOKEN=secret-token
  settings '{}'
  # the fork approval endpoint answers from this file; approval rewrites it
  APPROVAL_FILE="$BATS_TEST_TMPDIR/approval.json"
  approval all_external_contributors
  gh_respond 'api repos/spali/tool/actions/permissions/fork-pr-contributor-approval' "$APPROVAL_FILE"
}

# approval <policy> sets the answer of the fork pull request approval endpoint
approval() {
  jq -nc --arg p "$1" '{approval_policy: $p}' >"$APPROVAL_FILE"
}

# settings <json> sets ENTRY through managed_entry with the given exceptions
settings() {
  local cfg="$BATS_TEST_TMPDIR/config.json"
  jq -n --argjson s "$1" \
    '{version: 1, managed: [{repo: "spali/tool", upstream: "https://github.com/up/tool", settings: $s}]}' >"$cfg"
  ENTRY=$(managed_entry "$cfg" spali/tool)
  export ENTRY
}

ALL_OFF='{"has_issues": false, "has_pull_requests": false, "has_wiki": false, "has_discussions": false, "has_projects": false}'

only_repo_paths() {
  local line
  while IFS= read -r line; do
    [[ $line == "api repos/spali/tool" || $line == "api repos/spali/tool/actions/permissions" ||
      $line == "api -X PATCH repos/spali/tool --input "* ||
      $line == "api -X PUT repos/spali/tool/actions/permissions --input "* ||
      $line == "api repos/spali/tool/actions/permissions/fork-pr-contributor-approval" ||
      $line == "api -X PUT repos/spali/tool/actions/permissions/fork-pr-contributor-approval --input "* ]] || {
      echo "unexpected call: $line" >&2
      return 1
    }
  done < <(gh_calls)
}

@test "settings unchanged sends no PATCH" {
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "settings ok" ]
  only_repo_paths
  ! gh_calls | grep -q -e PATCH -e PUT
}

@test "differing settings are patched with only the changed keys" {
  jq -c '.has_issues = true | .has_wiki = null' <<<"$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "has_issues: true -> false" ]
  [ "${lines[1]}" = "has_wiki: null -> false" ]
  [ "${#lines[@]}" -eq 2 ]
  only_repo_paths
  n=$(gh_calls | grep -n PATCH | cut -d: -f1)
  [ "$(jq -cS . "$GH_INPUTS/$n")" = '{"has_issues":false,"has_wiki":false}' ]
}

@test "exception keeps has_issues true" {
  settings '{"has_issues": true}'
  jq -c '.has_issues = true' <<<"$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "settings ok" ]
  ! gh_calls | grep -q PATCH
}

@test "actions are disabled" {
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": true}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "actions: true -> false" ]
  only_repo_paths
  n=$(gh_calls | grep -n PUT | cut -d: -f1)
  [ "$(jq -c . "$GH_INPUTS/$n")" = '{"enabled":false}' ]
}

@test "actions are enabled by exception" {
  settings '{"actions": true}'
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  [ "$output" = "actions: false -> true" ]
  n=$(gh_calls | grep -n PUT | cut -d: -f1)
  [ "$(jq -c . "$GH_INPUTS/$n")" = '{"enabled":true}' ]
}


@test "fork approval is required for all external contributors with Actions on" {
  settings '{"actions": true}'
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": true}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  approval first_time_contributors
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "fork_pr_approval: first_time_contributors -> all_external_contributors" ]
  only_repo_paths
  n=$(gh_calls | grep -n 'PUT repos/spali/tool/actions/permissions/fork-pr-contributor-approval' | cut -d: -f1)
  [ "$(jq -c . "$GH_INPUTS/$n")" = '{"approval_policy":"all_external_contributors"}' ]
}

@test "fork approval already set sends no PUT" {
  settings '{"actions": true}'
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": true}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  approval all_external_contributors
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "settings ok" ]
  ! gh_calls | grep -q PUT
}

@test "fork approval is set right after Actions are enabled" {
  settings '{"actions": true}'
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  approval first_time_contributors_new_to_github
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "actions: false -> true" ]
  [ "${lines[1]}" = "fork_pr_approval: first_time_contributors_new_to_github -> all_external_contributors" ]
}

@test "fork approval is required with Actions off too" {
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  approval first_time_contributors
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "fork_pr_approval: first_time_contributors -> all_external_contributors" ]
  only_repo_paths
}

@test "fork approval is skipped for a private repository" {
  settings '{"actions": true}'
  jq -c '.private = true' <<<"$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": true}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "settings ok" ]
  ! gh_calls | grep -q fork-pr-contributor-approval
}

@test "fork approval API error fails" {
  settings '{"actions": true}'
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": true}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  gh_fail 'api -X PUT repos/spali/tool/actions/permissions/fork-pr-contributor-approval *' 'gh: Forbidden (HTTP 403)'
  approval first_time_contributors
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: spali/tool: gh: Forbidden (HTTP 403)" ]
}

@test "API error fails" {
  gh_fail 'api repos/spali/tool' $'gh: Forbidden (HTTP 403)\nmore'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: spali/tool: gh: Forbidden (HTTP 403)" ]
  only_repo_paths
}

@test "PATCH failure still sets Actions and fails at the end" {
  jq -c '.has_issues = true' <<<"$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": true}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  gh_fail 'api -X PATCH *' 'gh: Forbidden (HTTP 403)'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"error: spali/tool: gh: Forbidden (HTTP 403)"* ]]
  [[ $output == *"actions: true -> false"* ]]
  gh_calls | grep -q '^api -X PUT repos/spali/tool/actions/permissions'
  only_repo_paths
}

@test "invalid repo is rejected before any call" {
  ENTRY=$(jq -c '.repo = "other/tool"' <<<"$ENTRY") run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ ! -s "$GH_LOG" ]
}

@test "token stays out of arguments" {
  echo "$ALL_OFF" | gh_respond 'api repos/spali/tool' -
  echo '{"enabled": false}' | gh_respond 'api repos/spali/tool/actions/permissions' -
  run "$SCRIPT"
  ! gh_calls | grep -q secret-token
}
