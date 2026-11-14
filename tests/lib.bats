#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  SCRIPTS="$BATS_TEST_DIRNAME/../scripts"
}

@test "die prints the message to stderr and exits 1" {
  run --separate-stderr bash -c "source '$SCRIPTS/lib.sh'; die boom"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: boom" ]
  [ -z "$output" ]
}

@test "out appends key=value to GITHUB_OUTPUT" {
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  run bash -c "source '$SCRIPTS/lib.sh'; out version 1.2.3; out tag v1.2.3"
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = $'version=1.2.3\ntag=v1.2.3' ]
}

@test "out writes to stdout without GITHUB_OUTPUT" {
  unset GITHUB_OUTPUT
  run bash -c "source '$SCRIPTS/lib.sh'; out kind next"
  [ "$output" = "kind=next" ]
}

@test "need_env fails on an empty variable" {
  run --separate-stderr bash -c "source '$SCRIPTS/lib.sh'; FOO= need_env FOO"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: FOO is required" ]
}

@test "need_env passes when all variables are set" {
  run bash -c "source '$SCRIPTS/lib.sh'; FOO=1 BAR=2 need_env FOO BAR"
  [ "$status" -eq 0 ]
}

@test "gh stub returns the registered fixture and logs the call" {
  stub_gh
  echo '{"a":1}' >"$BATS_TEST_TMPDIR/fixture.json"
  gh_respond 'api repos/*' "$BATS_TEST_TMPDIR/fixture.json"
  run gh api repos/x
  [ "$output" = '{"a":1}' ]
  [ "$(gh_calls)" = "api repos/x" ]
}

@test "gh stub can fail a call" {
  stub_gh
  gh_fail 'release view *' 'release not found'
  run --separate-stderr gh release view v1
  [ "$status" -eq 1 ]
  [ "$stderr" = "release not found" ]
}
