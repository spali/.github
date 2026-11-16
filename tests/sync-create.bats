#!/usr/bin/env bats

setup() {
  # shellcheck source=scripts/managed-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/managed-lib.sh"
  load helpers/gh-stub
  stub_gh
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync-create.sh"
  export GH_TOKEN=secret-token SYNC_POLL_SLEEP=0
  entry fork
}

# entry <kind> [follow_json [private]] sets ENTRY through managed_entry, so
# it has the real shape (upstream_repo is null for mirrors)
entry() {
  local kind=$1 follow=${2:-[]} private=${3:-false} upstream=https://github.com/Up/Tool
  [[ $kind == fork ]] || upstream=https://gitlab.com/up/tool
  local cfg="$BATS_TEST_TMPDIR/config.json"
  jq -n --arg up "$upstream" --argjson follow "$follow" --argjson private "$private" \
    '{version: 1, managed: [{repo: "spali/tool", upstream: $up, private: $private}
      + (if $follow == [] then {} else {follow: $follow} end)]}' >"$cfg"
  ENTRY=$(managed_entry "$cfg" spali/tool)
  export ENTRY
}

# only_entry_paths fails if a call targets anything but the repo or its forks
only_entry_paths() {
  local line
  while IFS= read -r line; do
    [[ $line == "api repos/spali/tool" || $line == "api -X POST repos/Up/Tool/forks --input "* ]] || {
      echo "unexpected call: $line" >&2
      return 1
    }
  done < <(gh_calls)
}

# first GET of the repo answers 404, later ones answer with the file
repo_appears_later() {
  mv "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/gh.real"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<WRAPEOF
#!/usr/bin/env bash
if [[ "\$*" == "api repos/spali/tool" && ! -e "$BATS_TEST_TMPDIR/seen" ]]; then
  : >"$BATS_TEST_TMPDIR/seen"
  printf '%s\n' "\$*" >>"\$GH_LOG"
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
exec "$BATS_TEST_TMPDIR/bin/gh.real" "\$@"
WRAPEOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

FORK_OK='{"fork": true, "parent": {"full_name": "up/tool"}}'

@test "existing repo is left alone" {
  echo "$FORK_OK" | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = exists ]
  only_entry_paths
  [ "$(gh_calls | wc -l)" -eq 1 ]
}

@test "missing fork is created with default_branch_only" {
  repo_appears_later
  echo "$FORK_OK" | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "created fork" ]
  only_entry_paths
  gh_calls | grep -q '^api -X POST repos/Up/Tool/forks --input '
  [ "$(jq -c . "$GH_INPUTS/2")" = '{"name":"tool","default_branch_only":true}' ]
}

@test "default_branch_only false when follow is set" {
  entry fork '["release/.*"]'
  repo_appears_later
  echo "$FORK_OK" | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  only_entry_paths
  [ "$(jq -c . "$GH_INPUTS/2")" = '{"name":"tool","default_branch_only":false}' ]
}

@test "fork not visible after polling fails" {
  gh_fail 'api repos/spali/tool' 'gh: Not Found (HTTP 404)'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: fork spali/tool not visible after creation" ]
  only_entry_paths
  [ "$(gh_calls | grep -c '^api repos/spali/tool$')" -eq 11 ]
}

@test "existing non-fork with fork entry fails" {
  echo '{"fork": false}' | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: spali/tool exists but is not a fork of Up/Tool" ]
  only_entry_paths
  [ "$(gh_calls | wc -l)" -eq 1 ]
}

@test "fork of another parent fails" {
  echo '{"fork": true, "parent": {"full_name": "other/tool"}}' | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: spali/tool exists but is not a fork of Up/Tool" ]
  only_entry_paths
}

@test "existing fork with mirror entry fails" {
  entry mirror
  echo "$FORK_OK" | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: spali/tool exists but is a fork, not a mirror" ]
  only_entry_paths
}

@test "existing mirror is left alone" {
  entry mirror
  echo '{"fork": false}' | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = exists ]
}

@test "mirror creation fallback message" {
  entry mirror
  gh_fail 'api repos/spali/tool' 'gh: Not Found (HTTP 404)'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: create spali/tool by hand: gh repo create spali/tool --public" ]
  only_entry_paths
  [ "$(gh_calls | wc -l)" -eq 1 ]
}

@test "private mirror fallback message" {
  entry mirror '[]' true
  gh_fail 'api repos/spali/tool' 'gh: Not Found (HTTP 404)'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: create spali/tool by hand: gh repo create spali/tool --private" ]
}

@test "API error fails with the first line" {
  gh_fail 'api repos/spali/tool' $'gh: Server Error (HTTP 500)\nsecond line'
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$output" = "error: spali/tool: gh: Server Error (HTTP 500)" ]
  only_entry_paths
}

@test "invalid repo is rejected before any call" {
  ENTRY=$(jq -c '.repo = "other/tool"' <<<"$ENTRY") run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == "error: invalid repo"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "invalid upstream repo is rejected before any call" {
  ENTRY=$(jq -c '.upstream_repo = "a/b/../c"' <<<"$ENTRY") run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == "error: invalid upstream_repo"* ]]
  [ ! -s "$GH_LOG" ]
}

@test "token stays out of arguments" {
  echo "$FORK_OK" | gh_respond 'api repos/spali/tool' -
  run "$SCRIPT"
  ! gh_calls | grep -q secret-token
  grep -q secret-token "$GH_TOKENS"
}

@test "mirror entry has no upstream_repo" {
  entry mirror
  [ "$(jq -r .upstream_repo <<<"$ENTRY")" = null ]
}
