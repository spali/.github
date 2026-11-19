#!/usr/bin/env bats

setup() {
  # shellcheck source=scripts/forks-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/forks-lib.sh"
  CONFIG="$BATS_TEST_TMPDIR/config.json"
  INV="$BATS_TEST_TMPDIR/inventory.json"
  jq -n '{version: 1, forks: [
    {repo: "spali/homeassistant-keba",
     upstream: "https://github.com/dannerph/homeassistant-keba.git",
     branches: {"main": {onto: "main", rebase: "auto"}, "a/b": {onto: "main", rebase: "manual"}},
     settings: {}},
    {repo: "spali/knx.js", upstream: "https://bitbucket.org/ekarak/knx.js"},
    {repo: "spali/s", upstream: "https://github.com/o/s/", settings: {has_issues: true}, private: true}
  ]}' >"$CONFIG"
  jq -n '[
    {name: "spali/go-xq", fork: false, private: false},
    {name: "spali/HomeAssistant-Keba", fork: true, private: true, parent: {name: "dannerph/homeassistant-keba"}},
    {name: "spali/esphome", fork: true, private: false, parent: {name: "esphome/esphome"}},
    {name: "spali/plain", fork: true, private: true, parent: {name: "o/plain"}}
  ]' >"$INV"
}

@test "kind is fork for github.com upstream" {
  run fork_entry "$CONFIG" spali/homeassistant-keba
  [ "$status" -eq 0 ]
  [ "$(jq -r .kind <<<"$output")" = fork ]
  [ "$(jq -r .upstream_repo <<<"$output")" = dannerph/homeassistant-keba ]
  [ "$(jq -r 'has("refs")' <<<"$output")" = false ]
  [ "$(jq -r .private <<<"$output")" = false ]
  [ "$(jq -r .pinned <<<"$output")" = false ]
}

@test "trailing slash is dropped from upstream_repo" {
  run fork_entry "$CONFIG" spali/s
  [ "$(jq -r .upstream_repo <<<"$output")" = o/s ]
  [ "$(jq -r .private <<<"$output")" = true ]
}

@test "kind is mirror for bitbucket upstream" {
  run fork_entry "$CONFIG" spali/knx.js
  [ "$(jq -r .kind <<<"$output")" = mirror ]
  [ "$(jq -r 'has("refs")' <<<"$output")" = false ]
  [ "$(jq -r .upstream_repo <<<"$output")" = null ]
  [ "$(jq -c .branches <<<"$output")" = "[]" ]
}

@test "settings merge defaults with exceptions" {
  run fork_entry "$CONFIG" spali/s
  [ "$(jq -c .settings <<<"$output")" = '{"has_issues":true,"has_pull_requests":false,"has_wiki":false,"has_discussions":false,"has_projects":false,"actions":false}' ]
}

@test "branches become a sorted list" {
  run fork_entry "$CONFIG" spali/homeassistant-keba
  [ "$(jq -c .branches <<<"$output")" = '[{"name":"a/b","onto":"main","rebase":"manual"},{"name":"main","onto":"main","rebase":"auto"}]' ]
}

@test "fork_entries prints one object per line" {
  run fork_entries "$CONFIG"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(jq -r .repo <<<"${lines[1]}")" = spali/knx.js ]
}

@test "fork_entries is empty without forks and inventory" {
  echo '{"version":1}' >"$CONFIG"
  run fork_entries "$CONFIG"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fork_entries adds the inventory forks without an entry, with defaults" {
  run fork_entries "$CONFIG" "$INV"
  [ "$status" -eq 0 ]
  [ "$(jq -sc 'map(.repo)' <<<"$output")" = '["spali/HomeAssistant-Keba","spali/knx.js","spali/s","spali/esphome","spali/plain"]' ]
  run fork_entry "$CONFIG" spali/plain "$INV"
  [ "$output" = '{"repo":"spali/plain","upstream":"https://github.com/o/plain","kind":"fork","upstream_repo":"o/plain","branches":[],"follow":[],"tags":true,"settings":{"has_issues":false,"has_pull_requests":false,"has_wiki":false,"has_discussions":false,"has_projects":false,"actions":false},"private":true,"pinned":false}' ]
}

@test "an entry without upstream takes the parent of the inventory fork" {
  jq -n '{forks: [{repo: "spali/ESPHome", branches: {dev: {onto: "dev", rebase: "auto"}}, private: false}]}' >"$CONFIG"
  run fork_entry "$CONFIG" spali/esphome "$INV"
  [ "$(jq -c '[.repo, .upstream, .kind, .upstream_repo, .private, (.branches | length)]' <<<"$output")" = '["spali/esphome","https://github.com/esphome/esphome","fork","esphome/esphome",false,1]' ]
  # no inventory: the upstream is unknown, the caller looks it up
  run fork_entry "$CONFIG" spali/esphome
  [ "$(jq -c '[.upstream, .kind, .upstream_repo]' <<<"$output")" = '[null,"fork",null]' ]
}

@test "pinned entries are listed, but not synced" {
  jq -n '{forks: [{repo: "spali/esphome", pinned: true}, {repo: "spali/m", upstream: "https://example.org/m"}]}' >"$CONFIG"
  run fork_entry "$CONFIG" spali/esphome "$INV"
  [ "$(jq -r .pinned <<<"$output")" = true ]
  run synced_repos "$CONFIG" "$INV"
  [ "$status" -eq 0 ]
  [ "$output" = '["spali/HomeAssistant-Keba","spali/m","spali/plain"]' ]
}

@test "fork_entry fails for an unknown repo" {
  run fork_entry "$CONFIG" spali/nope
  [ "$status" -eq 1 ]
  run fork_entry "$CONFIG" spali/go-xq "$INV"
  [ "$status" -eq 1 ]
}

@test "github.com host is case-insensitive, upstream_repo keeps case" {
  jq -n '{forks: [{repo: "spali/c", upstream: "https://GitHub.com/Own/Nm.git"}]}' >"$CONFIG"
  run fork_entry "$CONFIG" spali/c
  [ "$(jq -r .kind <<<"$output")" = fork ]
  [ "$(jq -r .upstream_repo <<<"$output")" = Own/Nm ]
}

@test "follow defaults to []" {
  jq -n '{forks: [{repo: "spali/c", upstream: "https://github.com/o/c"},
    {repo: "spali/d", upstream: "https://github.com/o/d", follow: ["release/.*"]}]}' >"$CONFIG"
  run fork_entry "$CONFIG" spali/c
  [ "$(jq -c .follow <<<"$output")" = "[]" ]
  run fork_entry "$CONFIG" spali/d
  [ "$(jq -c .follow <<<"$output")" = '["release/.*"]' ]
}

@test "tags defaults to true" {
  jq -n '{forks: [{repo: "spali/c", upstream: "https://github.com/o/c"},
    {repo: "spali/d", upstream: "https://example.org/d", tags: false},
    {repo: "spali/e", upstream: "https://example.org/e", tags: true}]}' >"$CONFIG"
  run fork_entry "$CONFIG" spali/c
  [ "$(jq -c .tags <<<"$output")" = true ]
  run fork_entry "$CONFIG" spali/d
  [ "$(jq -c .tags <<<"$output")" = false ]
  run fork_entry "$CONFIG" spali/e
  [ "$(jq -c .tags <<<"$output")" = true ]
}
