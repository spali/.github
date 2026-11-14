#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  export GH_REPO=spali/sandbox GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  : >"$GITHUB_OUTPUT"
  PREPARE="$BATS_TEST_DIRNAME/../scripts/prepare.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
}

outputs() {
  cat "$GITHUB_OUTPUT"
}

main_at() {
  echo "$1" | gh_respond 'api repos/spali/sandbox/commits/main --jq .sha' -
}

@test "next: pre-release from the draft version" {
  DRAFT_VERSION=1.0.0 DRAFT_ID=42 GITHUB_SHA=abc run "$PREPARE" next
  [ "$status" -eq 0 ]
  [ "$(outputs)" = $'kind=next\nversion=1.0.0-next\ntag=v1.0.0-next\nsha=abc\npr=\ndraft-id=42' ]
}

@test "next: requires the draft" {
  DRAFT_VERSION= DRAFT_ID=42 GITHUB_SHA=abc run --separate-stderr "$PREPARE" next
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: DRAFT_VERSION is required" ]
}

@test "release: tag matches the draft and main" {
  gh_respond 'release list *' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at abc
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run "$PREPARE" release
  [ "$status" -eq 0 ]
  [ "$(outputs)" = $'kind=release\nversion=1.0.0\ntag=v1.0.0\nsha=abc\npr=\ndraft-id=42' ]
}

@test "release: pre-release version from an exception draft" {
  gh_respond 'release list *' "$FIXTURES/releases-draft-v2.0.0-rc.1.json"
  main_at abc
  GITHUB_REF_NAME=v2.0.0-rc.1 GITHUB_SHA=abc run "$PREPARE" release
  [ "$status" -eq 0 ]
  [ "$(outputs)" = $'kind=release\nversion=2.0.0-rc.1\ntag=v2.0.0-rc.1\nsha=abc\npr=\ndraft-id=43' ]
}

@test "release: tag does not match the draft" {
  gh_respond 'release list *' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at abc
  GITHUB_REF_NAME=v1.1.0 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no draft release for v1.1.0 (current draft: v1.0.0)" ]
  [ -z "$(outputs)" ]
}

@test "release: no draft at all" {
  gh_respond 'release list *' "$FIXTURES/releases-no-draft.json"
  main_at abc
  GITHUB_REF_NAME=v1.0.1 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no draft release for v1.0.1 (no draft exists, merge a pull request first)" ]
}

@test "release: tag on an older commit" {
  gh_respond 'release list *' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at def
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: tag v1.0.0 points to abc but main is at def; delete the tag and tag main again" ]
  [ -z "$(outputs)" ]
}

@test "pr: dev build of the branch's pull request" {
  echo '[{"number":77,"isCrossRepository":false}]' | gh_respond 'pr list --head fix/x *' -
  GITHUB_REF_NAME=fix/x GITHUB_SHA=abc DRAFT_VERSION=1.0.0 run "$PREPARE" pr
  [ "$status" -eq 0 ]
  [ "$(outputs)" = $'kind=pr\nversion=1.0.0-pr.77\ntag=v1.0.0-pr.77\nsha=abc\npr=77\ndraft-id=' ]
  grep -qx 'pr list --head fix/x --base main --state open --json number,isCrossRepository' "$GH_LOG"
}

@test "pr: branch without pull request" {
  echo '[]' | gh_respond 'pr list --head fix/x *' -
  GITHUB_REF_NAME=fix/x GITHUB_SHA=abc DRAFT_VERSION=1.0.0 run --separate-stderr "$PREPARE" pr
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: branch fix/x has no open pull request to main" ]
}

@test "pr: ignores pull requests from forks with the same branch name" {
  echo '[{"number":78,"isCrossRepository":true}]' | gh_respond 'pr list --head fix/x *' -
  GITHUB_REF_NAME=fix/x GITHUB_SHA=abc DRAFT_VERSION=1.0.0 run --separate-stderr "$PREPARE" pr
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: branch fix/x has no open pull request to main" ]
}

@test "pr: not on main" {
  GITHUB_REF_NAME=main GITHUB_SHA=abc DRAFT_VERSION=1.0.0 run --separate-stderr "$PREPARE" pr
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: run the dev build on a pull request branch, not main" ]
}

@test "unknown subcommand" {
  run --separate-stderr "$PREPARE" deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: usage: prepare.sh next|release|pr" ]
}
