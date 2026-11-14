#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  export GH_REPO=spali/sandbox
  CLEANUP="$BATS_TEST_DIRNAME/../scripts/cleanup-pr.sh"
  printf '%s\n' v1.0.0-pr.7 v1.1.0-pr.7 v1.0.0-pr.70 v1.0.0-next v1.0.0 v0.7.0 |
    gh_respond 'release list *' -
}

@test "deletes only the dev releases of this PR" {
  PR_NUMBER=7 run "$CLEANUP"
  [ "$status" -eq 0 ]
  run grep '^release delete' "$GH_LOG"
  [ "$output" = $'release delete v1.0.0-pr.7 --cleanup-tag --yes\nrelease delete v1.1.0-pr.7 --cleanup-tag --yes' ]
}

@test "does nothing without dev releases" {
  PR_NUMBER=8 run "$CLEANUP"
  [ "$status" -eq 0 ]
  ! grep -q '^release delete' "$GH_LOG"
}

@test "requires PR_NUMBER" {
  PR_NUMBER= run --separate-stderr "$CLEANUP"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: PR_NUMBER is required" ]
}
