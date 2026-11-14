#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  export GH_REPO=spali/sandbox GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out"
  export GITHUB_WORKFLOW_REF=spali/sandbox/.github/workflows/release.yml@refs/tags/v1.0.0
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

# main_run registers the runs of the release workflow for main's head.
main_run() { # sha json
  echo "$2" | gh_respond "api repos/spali/sandbox/actions/runs?branch=main&head_sha=$1&per_page=100" -
}

ok_run='{"workflow_runs":[{"path":".github/workflows/release.yml","event":"push","conclusion":"success"}]}'


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
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at abc
  main_run abc "$ok_run"
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run "$PREPARE" release
  [ "$status" -eq 0 ]
  [ "$(outputs)" = $'kind=release\nversion=1.0.0\ntag=v1.0.0\nsha=abc\npr=\ndraft-id=42' ]
  grep -qx 'api repos/spali/sandbox/releases --paginate' "$GH_LOG"
}

@test "release: pre-release version from an exception draft" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-draft-v2.0.0-rc.1.json"
  main_at abc
  main_run abc "$ok_run"
  GITHUB_REF_NAME=v2.0.0-rc.1 GITHUB_SHA=abc run "$PREPARE" release
  [ "$status" -eq 0 ]
  [ "$(outputs)" = $'kind=release\nversion=2.0.0-rc.1\ntag=v2.0.0-rc.1\nsha=abc\npr=\ndraft-id=43' ]
}

@test "release: tag does not match the draft" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at abc
  GITHUB_REF_NAME=v1.1.0 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no draft release for v1.1.0 (current draft: v1.0.0)" ]
  [ -z "$(outputs)" ]
}

@test "release: no draft at all" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-no-draft.json"
  main_at abc
  GITHUB_REF_NAME=v1.0.1 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no draft release for v1.0.1 (no draft exists, merge a pull request first)" ]
}

@test "release: tag on an older commit" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-draft-v1.0.0.json"
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
  [ "$stderr" = "error: usage: prepare.sh next|release|pr|version" ]
}

@test "release: finds the draft on a later page" {
  { echo '[{"id":40,"tag_name":"v0.9.0","draft":false}]'; echo '[{"id":42,"tag_name":"v1.0.0","draft":true}]'; } |
    gh_respond 'api repos/spali/sandbox/releases --paginate' -
  main_at abc
  main_run abc "$ok_run"
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run "$PREPARE" release
  [ "$status" -eq 0 ]
  grep -qx 'draft-id=42' "$GITHUB_OUTPUT"
}

@test "release: the draft is not updated for main's head yet" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at abc
  main_run abc '{"workflow_runs":[{"path":".github/workflows/release.yml","event":"push","conclusion":null},{"path":".github/workflows/other.yml","event":"push","conclusion":"success"}]}'
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: the draft is not up to date for main at abc: no successful run of .github/workflows/release.yml for it yet; wait for it, then re-run this run" ]
  [ -z "$(outputs)" ]
}

@test "release: a successful dispatch run on main counts" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-draft-v1.0.0.json"
  main_at abc
  main_run abc '{"workflow_runs":[{"path":".github/workflows/release.yml","event":"workflow_dispatch","conclusion":"success"}]}'
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run "$PREPARE" release
  [ "$status" -eq 0 ]
}

@test "release: several drafts with the tag" {
  gh_respond 'api repos/spali/sandbox/releases --paginate' "$FIXTURES/releases-two-drafts-v1.0.0.json"
  main_at abc
  main_run abc "$ok_run"
  GITHUB_REF_NAME=v1.0.0 GITHUB_SHA=abc run --separate-stderr "$PREPARE" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: several draft releases for v1.0.0 (ids 44, 42); delete all but one, then re-run this run" ]
  [ -z "$(outputs)" ]
}

@test "version: empty is fine" {
  VERSION= run "$PREPARE" version
  [ "$status" -eq 0 ]
  [ -z "$(outputs)" ]
}

@test "version: accepts SemVer" {
  for v in 1.0.0 0.1.2 10.20.30 2.0.0-rc.1 1.0.0-alpha.beta-1 1.0.0-0a.1; do
    VERSION=$v run "$PREPARE" version
    [ "$status" -eq 0 ] || { echo "rejected $v"; false; }
  done
}

@test "version: rejects anything else" {
  for v in v1.0.0 1.0 1.0.0.0 01.0.0 1.0.0- 1.0.0-rc..1 1.0.0-01 1.0.0+build.5 ' 1.0.0' $'1.0.0\nx'; do
    VERSION=$v run --separate-stderr "$PREPARE" version
    [ "$status" -eq 1 ] || { echo "accepted $v"; false; }
    [ "$stderr" = "error: version must be SemVer without \"v\" and without build metadata (e.g. 2.0.0-rc.1), got: $v" ]
  done
}

@test "version: rejects the suffixes of the pre-releases" {
  for v in 1.0.0-next 1.0.0-pr.5 1.0.0-rc.1-next 1.0.0-x-pr.1; do
    VERSION=$v run --separate-stderr "$PREPARE" version
    [ "$status" -eq 1 ] || { echo "accepted $v"; false; }
    [ "$stderr" = "error: version must not end in -next or contain -pr. (reserved for pre-releases), got: $v" ]
  done
}
