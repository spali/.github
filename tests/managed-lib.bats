#!/usr/bin/env bats

setup() {
  # shellcheck source=scripts/managed-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/managed-lib.sh"
  CONFIG="$BATS_TEST_TMPDIR/config.json"
  jq -n '{version: 1, managed: [
    {repo: "spali/homeassistant-keba",
     upstream: "https://github.com/dannerph/homeassistant-keba.git",
     branches: {"main": {onto: "main", rebase: "auto"}, "a/b": {onto: "main", rebase: "manual"}},
     settings: {}},
    {repo: "spali/knx.js", upstream: "https://bitbucket.org/ekarak/knx.js"},
    {repo: "spali/s", upstream: "https://github.com/o/s/", settings: {has_issues: true}, private: true}
  ]}' >"$CONFIG"
}

@test "kind is fork for github.com upstream" {
  run managed_entry "$CONFIG" spali/homeassistant-keba
  [ "$status" -eq 0 ]
  [ "$(jq -r .kind <<<"$output")" = fork ]
  [ "$(jq -r .upstream_repo <<<"$output")" = dannerph/homeassistant-keba ]
  [ "$(jq -r .refs <<<"$output")" = default ]
  [ "$(jq -r .private <<<"$output")" = false ]
}

@test "trailing slash is dropped from upstream_repo" {
  run managed_entry "$CONFIG" spali/s
  [ "$(jq -r .upstream_repo <<<"$output")" = o/s ]
  [ "$(jq -r .private <<<"$output")" = true ]
}

@test "kind is mirror for bitbucket upstream" {
  run managed_entry "$CONFIG" spali/knx.js
  [ "$(jq -r .kind <<<"$output")" = mirror ]
  [ "$(jq -r .refs <<<"$output")" = all ]
  [ "$(jq -r .upstream_repo <<<"$output")" = null ]
  [ "$(jq -c .branches <<<"$output")" = "[]" ]
}

@test "settings merge defaults with exceptions" {
  run managed_entry "$CONFIG" spali/s
  [ "$(jq -c .settings <<<"$output")" = '{"has_issues":true,"has_pull_requests":false,"has_wiki":false,"has_discussions":false,"has_projects":false,"actions":false}' ]
}

@test "branches become a sorted list" {
  run managed_entry "$CONFIG" spali/homeassistant-keba
  [ "$(jq -c .branches <<<"$output")" = '[{"name":"a/b","onto":"main","rebase":"manual"},{"name":"main","onto":"main","rebase":"auto"}]' ]
}

@test "managed_entries prints one object per line" {
  run managed_entries "$CONFIG"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(jq -r .repo <<<"${lines[1]}")" = spali/knx.js ]
}

@test "managed_entries is empty without managed" {
  echo '{"version":1}' >"$CONFIG"
  run managed_entries "$CONFIG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "managed_entry fails for an unknown repo" {
  run managed_entry "$CONFIG" spali/nope
  [ "$status" -eq 1 ]
}

@test "github.com host is case-insensitive, upstream_repo keeps case" {
  jq -n '{managed: [{repo: "spali/c", upstream: "https://GitHub.com/Own/Nm.git"}]}' >"$CONFIG"
  run managed_entry "$CONFIG" spali/c
  [ "$(jq -r .kind <<<"$output")" = fork ]
  [ "$(jq -r .upstream_repo <<<"$output")" = Own/Nm ]
}
