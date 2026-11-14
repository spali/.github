#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  CONFIG="$BATS_TEST_DIRNAME/../scripts/monitor-config.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
}

# mk NAME writes stdin to $BATS_TEST_TMPDIR/NAME and prints the path.
mk() {
  cat >"$BATS_TEST_TMPDIR/$1"
  printf '%s\n' "$BATS_TEST_TMPDIR/$1"
}

@test "valid file passes" {
  run --separate-stderr "$CONFIG" validate "$FIX/repos-valid.yml"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "valid private file passes with --private" {
  run "$CONFIG" validate "$FIX/repos-private.yml" --private
  [ "$status" -eq 0 ]
}

@test "unknown top-level key fails" {
  f=$(printf 'version: 1\nfoo: 1\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: $f: unknown key foo" ]
}

@test "wrong version fails" {
  f=$(printf 'version: 2\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: version must be 1"* ]]
}

@test "unknown check in ignore fails" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: main-rde, reason: r}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"unknown check main-rde"* ]]
}

@test "empty reason fails" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: main-red, reason: ""}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"reason must not be empty"* ]]
}

@test "private file with lists fails" {
  f=$(printf 'version: 1\nlists: {archive: a}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f" --private
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists is not allowed in the private file"* ]]
}

@test "duplicate ignore fails" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: main-red, reason: a}\n  - {repo: spali/x, check: main-red, reason: b}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"duplicate ignore spali/x main-red"* ]]
}

@test "bad repo names and intervals fail" {
  f=$(
    mk bad.yml <<'YAML'
version: 1
mirrors:
  - {target: other/x, source: "http://a", interval_hours: 0}
forks:
  - {repo: spali/ok, sync_interval_hours: 1.5}
YAML
  )
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mirrors[0].target: other/x is not a spali repository"* ]]
  [[ $stderr == *"mirrors[0].source must start with https://"* ]]
  [[ $stderr == *"mirrors[0].interval_hours must be a positive integer"* ]]
  [[ $stderr == *"forks[0].sync_interval_hours must be a positive integer"* ]]
}

@test "missing mirror fields and non-string script fail" {
  f=$(printf 'version: 1\nmirrors:\n  - {script: 3}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mirrors[0].target is required"* ]]
  [[ $stderr == *"mirrors[0].source is required"* ]]
  [[ $stderr == *"mirrors[0].interval_hours is required"* ]]
  [[ $stderr == *"mirrors[0].script must be a string"* ]]
}

@test "all problems are reported, not only the first" {
  f=$(printf 'version: 3\nfoo: 1\nbar: 2\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [ "$(wc -l <<<"$stderr")" -eq 3 ]
}

@test "missing file fails" {
  run --separate-stderr "$CONFIG" validate "$BATS_TEST_TMPDIR/nope.yml"
  [ "$status" -eq 1 ]
  [[ $stderr == "error: "* ]]
}

@test "merge marks private entries" {
  run "$CONFIG" merge "$FIX/repos-valid.yml" "$FIX/repos-private.yml"
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.ignores[] | select(.private) | .repo]' <<<"$output")" = '["spali/secret"]' ]
  [ "$(jq -c '[.ignores[] | select(.private | not) | .repo]' <<<"$output")" = '["spali/old-thing"]' ]
  [ "$(jq '.mirrors | length' <<<"$output")" -eq 2 ]
  [ "$(jq -c '[.mirrors[] | .private]' <<<"$output")" = '[false,true]' ]
  [ "$(jq '.forks[0].private' <<<"$output")" = false ]
}

@test "merge works without a private file" {
  run "$CONFIG" merge "$FIX/repos-valid.yml"
  [ "$status" -eq 0 ]
  [ "$(jq '[.mirrors[] | select(.private)] | length' <<<"$output")" -eq 0 ]
}

@test "merge keeps emoji list names exactly" {
  run "$CONFIG" merge "$FIX/repos-valid.yml" "$FIX/repos-private.yml"
  [ "$(jq -r '.lists.mirrors' <<<"$output")" = "👀  Mirrors" ]
  [ "$(jq -r '.lists.exclusive[1][0]' <<<"$output")" = "▶️ Constribution forks" ]
}

@test "public-check passes for public repos" {
  echo '{"private": false}' | gh_respond 'api repos/*' -
  run --separate-stderr "$CONFIG" public-check "$FIX/repos-valid.yml"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  run gh_calls
  [ "$output" = $'api repos/spali/fork-a\napi repos/spali/mirror-a\napi repos/spali/old-thing' ]
}

@test "public-check checks each repo once" {
  f=$(
    mk dup.yml <<'YAML'
version: 1
mirrors:
  - {target: spali/a, source: "https://x", interval_hours: 1}
forks:
  - {repo: spali/a, sync_interval_hours: 1}
ignores:
  - {repo: spali/a, check: main-red, reason: r}
YAML
  )
  echo '{"private": false}' | gh_respond 'api repos/*' -
  run "$CONFIG" public-check "$f"
  [ "$status" -eq 0 ]
  [ "$(gh_calls | wc -l)" -eq 1 ]
}

@test "public-check fails for a private repo" {
  echo '{"private": true}' | gh_respond 'api repos/spali/fork-a' -
  echo '{"private": false}' | gh_respond 'api repos/*' -
  run --separate-stderr "$CONFIG" public-check "$FIX/repos-valid.yml"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: $FIX/repos-valid.yml: spali/fork-a is not a public repository" ]
}

@test "public-check fails for a repo that is not public" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: main-red, reason: r}\n  - {repo: spali/y, check: main-red, reason: r}\n' | mk gone.yml)
  gh_fail 'api repos/spali/x' 'gh: Not Found (HTTP 404)'
  echo '{"private": true}' | gh_respond 'api repos/spali/y' -
  run --separate-stderr "$CONFIG" public-check "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: spali/x is not a public repository"* ]]
  [[ $stderr == *"error: $f: spali/y is not a public repository"* ]]
}

@test "unknown command fails" {
  run --separate-stderr "$CONFIG" bogus
  [ "$status" -eq 1 ]
  [[ $stderr == "error: "* ]]
}
