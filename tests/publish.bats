#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  PUBLISH="$BATS_TEST_DIRNAME/../scripts/publish.sh"
  export GH_REPO=spali/sandbox GITHUB_SERVER_URL=https://github.com SHA=abc
  export ASSETS_DIR="$BATS_TEST_TMPDIR/dist"
  mkdir -p "$ASSETS_DIR"
  echo a >"$ASSETS_DIR/app_1.zip"
  echo b >"$ASSETS_DIR/app_1.tar.gz"
  echo c >"$ASSETS_DIR/checksums.txt"
  FILES="$ASSETS_DIR/app_1.tar.gz $ASSETS_DIR/app_1.zip $ASSETS_DIR/checksums.txt"
  printf '%s\n' v1.0.0-next v0.9.0-next v1.0.0-pr.77 v0.9.0-pr.77 v1.0.0-pr.7 v0.9.0 |
    gh_respond 'release list *' -
}

# calls_matching prints the logged gh calls that start with $1.
calls_matching() {
  grep "^$1" "$GH_LOG" || true
}

# draft_state registers the current state of draft 42 and main's head.
draft_state() { # draft tag_name main_sha
  printf '{"draft":%s,"tag_name":"%s"}\n' "$1" "$2" | gh_respond 'api repos/spali/sandbox/releases/4[23]' -
  echo "$3" | gh_respond 'api repos/spali/sandbox/commits/main --jq .sha' -
}

@test "release: uploads to the draft and publishes it as latest" {
  draft_state true v1.0.0 abc
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run "$PUBLISH" release
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'release upload')" = "release upload v1.0.0 $FILES --clobber" ]
  [ "$(calls_matching 'api -X PATCH')" = "api -X PATCH repos/spali/sandbox/releases/42 -F draft=false -f tag_name=v1.0.0 -F prerelease=false -f make_latest=true" ]
  [ "$(calls_matching 'release upload' | wc -l)" -eq 1 ]
}

@test "release: a version with a suffix becomes a pre-release, not latest" {
  draft_state true v2.0.0-rc.1 abc
  TAG=v2.0.0-rc.1 VERSION=2.0.0-rc.1 DRAFT_ID=43 run "$PUBLISH" release
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'api -X PATCH')" = "api -X PATCH repos/spali/sandbox/releases/43 -F draft=false -f tag_name=v2.0.0-rc.1 -F prerelease=true -f make_latest=false" ]
}

@test "release: requires the draft" {
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID= run --separate-stderr "$PUBLISH" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: DRAFT_ID is required" ]
  [ -z "$(cat "$GH_LOG")" ]
}

@test "next: replaces every -next pre-release, notes from the draft" {
  printf '## Features\n\n* feat: x (#1) @a\n' | gh_respond 'api repos/spali/sandbox/releases/42 --jq .body' -
  TAG=v1.1.0-next VERSION=1.1.0-next DRAFT_ID=42 run "$PUBLISH" next
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'release delete')" = $'release delete v1.0.0-next --cleanup-tag --yes\nrelease delete v0.9.0-next --cleanup-tag --yes' ]
  create=$(calls_matching 'release create')
  [[ $create == "release create v1.1.0-next $FILES --target abc --prerelease --latest=false --title v1.1.0-next --notes-file "* ]]
  notes=${create##* --notes-file }
  [ "$(cat "$notes")" = $'## Features\n\n* feat: x (#1) @a\n\nPre-release of the next version, built from abc.' ]
  [ "$(grep -n 'release create' "$GH_LOG" | cut -d: -f1)" -gt "$(grep -n 'release delete v0.9.0-next' "$GH_LOG" | cut -d: -f1)" ]
}

@test "pr: replaces the dev pre-release and adds a comment" {
  TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'release delete')" = $'release delete v1.0.0-pr.77 --cleanup-tag --yes\nrelease delete v0.9.0-pr.77 --cleanup-tag --yes' ]
  [ "$(calls_matching 'release create')" = "release create v1.0.0-pr.77 $FILES --target abc --prerelease --latest=false --title v1.0.0-pr.77 --notes Dev build of #77 at abc, not for production use." ]
  comment=$(calls_matching 'pr comment')
  [[ $comment == "pr comment 77 --body-file "* ]]
  body=$(cat "${comment##* --body-file }")
  [[ $body == *"<!-- release-flow:pr-dev -->"* ]]
  [[ $body == *"https://github.com/spali/sandbox/releases/tag/v1.0.0-pr.77"* ]]
}

@test "pr: updates the existing dev build comment of the bot" {
  echo '[{"id":990,"user":{"login":"someone"},"body":"hi"},{"id":991,"user":{"login":"github-actions[bot]"},"body":"<!-- release-flow:pr-dev -->\nold"}]' |
    gh_respond 'api repos/spali/sandbox/issues/77/comments --paginate' -
  TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ -z "$(calls_matching 'pr comment')" ]
  patch=$(calls_matching 'api -X PATCH')
  [[ $patch == "api -X PATCH repos/spali/sandbox/issues/comments/991 -F body=@"* ]]
}

@test "pr: ignores a marker comment written by someone else" {
  echo '[{"id":990,"user":{"login":"attacker"},"body":"<!-- release-flow:pr-dev -->\nevil link"}]' |
    gh_respond 'api repos/spali/sandbox/issues/77/comments --paginate' -
  TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ -z "$(calls_matching 'api -X PATCH')" ]
  [[ $(calls_matching 'pr comment') == "pr comment 77 --body-file "* ]]
}

@test "unknown subcommand" {
  run --separate-stderr "$PUBLISH" deploy
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: usage: publish.sh release|next|pr" ]
}

@test "fails without assets and publishes nothing" {
  rm -f "$ASSETS_DIR"/*
  TAG=v1.0.0-next VERSION=1.0.0-next DRAFT_ID=42 run --separate-stderr "$PUBLISH" next
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no release assets found in $ASSETS_DIR" ]
  [ -z "$(calls_matching 'release')" ]
}

@test "release: the draft was published or retagged meanwhile" {
  draft_state false v1.0.0 abc
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run --separate-stderr "$PUBLISH" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: release 42 is no longer the draft for v1.0.0 (draft=false, tag v1.0.0)" ]
  [ -z "$(calls_matching 'release upload')" ]
  [ -z "$(calls_matching 'api -X PATCH')" ]
}

@test "release: main moved on while building" {
  draft_state true v1.0.0 def
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run --separate-stderr "$PUBLISH" release
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: main moved to def while building abc, the draft now describes main; delete the tag and release again" ]
  [ -z "$(calls_matching 'release upload')" ]
}

@test "fails on a directory in the assets and publishes nothing" {
  mkdir "$ASSETS_DIR/sub"
  TAG=v1.0.0-next VERSION=1.0.0-next DRAFT_ID=42 run --separate-stderr "$PUBLISH" next
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: release assets must be files, $ASSETS_DIR/sub is a directory" ]
  [ -z "$(calls_matching 'release')" ]
}

@test "release: deletes the -next pre-releases after publishing" {
  draft_state true v1.0.0 abc
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run "$PUBLISH" release
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'release delete')" = $'release delete v1.0.0-next --cleanup-tag --yes\nrelease delete v0.9.0-next --cleanup-tag --yes' ]
  [ "$(grep -n 'release delete v1.0.0-next' "$GH_LOG" | cut -d: -f1)" -gt "$(grep -n 'api -X PATCH' "$GH_LOG" | cut -d: -f1)" ]
}

@test "release: a failed publish keeps the -next pre-releases" {
  draft_state true v1.0.0 abc
  gh_fail 'api -X PATCH *' 'HTTP 500'
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run "$PUBLISH" release
  [ "$status" -eq 1 ]
  [ -z "$(calls_matching 'release delete')" ]
}

@test "next: deletes a leftover tag without release before creating" {
  echo '[{"ref":"refs/tags/v1.1.0-next"}]' | gh_respond 'api repos/spali/sandbox/git/matching-refs/tags/v1.1.0-next' -
  TAG=v1.1.0-next VERSION=1.1.0-next DRAFT_ID=42 run "$PUBLISH" next
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'api -X DELETE')" = "api -X DELETE repos/spali/sandbox/git/refs/tags/v1.1.0-next" ]
  [ "$(grep -n 'release create' "$GH_LOG" | cut -d: -f1)" -gt "$(grep -n 'api -X DELETE' "$GH_LOG" | cut -d: -f1)" ]
}

@test "pr: deletes only the exact leftover tag" {
  echo '[{"ref":"refs/tags/v1.0.0-pr.7"},{"ref":"refs/tags/v1.0.0-pr.77"}]' |
    gh_respond 'api repos/spali/sandbox/git/matching-refs/tags/v1.0.0-pr.7' -
  TAG=v1.0.0-pr.7 VERSION=1.0.0-pr.7 PR=7 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'api -X DELETE')" = "api -X DELETE repos/spali/sandbox/git/refs/tags/v1.0.0-pr.7" ]
}

@test "pr: no leftover tag, nothing to delete" {
  echo '[{"ref":"refs/tags/v1.0.0-pr.77"}]' | gh_respond 'api repos/spali/sandbox/git/matching-refs/tags/v1.0.0-pr.7' -
  TAG=v1.0.0-pr.7 VERSION=1.0.0-pr.7 PR=7 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ -z "$(calls_matching 'api -X DELETE')" ]
}

@test "pr: deletes the dev build again when the pull request was closed meanwhile" {
  for state in CLOSED MERGED; do
    : >"$GH_LOG"
    : >"$GH_RESPONSES"
    printf '%s\n' v0.9.0 | gh_respond 'release list *' -
    echo "{\"state\":\"$state\"}" | gh_respond 'pr view 77 --json state' -
    TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
    [ "$status" -eq 0 ]
    [ "$(calls_matching 'release delete')" = "release delete v1.0.0-pr.77 --cleanup-tag --yes" ]
    [ "$(grep -n 'release delete' "$GH_LOG" | cut -d: -f1)" -gt "$(grep -n 'release create' "$GH_LOG" | cut -d: -f1)" ]
    [ -z "$(calls_matching 'pr comment')" ]
    [ -z "$(calls_matching 'api -X PATCH')" ]
    [[ $output == *"::warning::pull request #77 is ${state,,}, deleted the dev build v1.0.0-pr.77"* ]]
  done
}

@test "release without assets: publishes the draft, uploads nothing" {
  draft_state true v1.0.0 abc
  rm -rf "$ASSETS_DIR"
  ASSETS=false ASSETS_DIR= TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run "$PUBLISH" release
  [ "$status" -eq 0 ]
  [ -z "$(calls_matching 'release upload')" ]
  [ "$(calls_matching 'api -X PATCH')" = "api -X PATCH repos/spali/sandbox/releases/42 -F draft=false -f tag_name=v1.0.0 -F prerelease=false -f make_latest=true" ]
  [ "$(calls_matching 'release delete')" = $'release delete v1.0.0-next --cleanup-tag --yes\nrelease delete v0.9.0-next --cleanup-tag --yes' ]
}

@test "next without assets: creates the pre-release without files" {
  printf 'notes\n' | gh_respond 'api repos/spali/sandbox/releases/42 --jq .body' -
  rm -rf "$ASSETS_DIR"
  ASSETS=false ASSETS_DIR= TAG=v1.1.0-next VERSION=1.1.0-next DRAFT_ID=42 run "$PUBLISH" next
  [ "$status" -eq 0 ]
  [[ $(calls_matching 'release create') == "release create v1.1.0-next --target abc --prerelease --latest=false --title v1.1.0-next --notes-file "* ]]
}

@test "pr without assets: creates the dev pre-release without files" {
  rm -rf "$ASSETS_DIR"
  ASSETS=false ASSETS_DIR= TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'release create')" = "release create v1.0.0-pr.77 --target abc --prerelease --latest=false --title v1.0.0-pr.77 --notes Dev build of #77 at abc, not for production use." ]
}

@test "without assets: ignores files in the assets directory" {
  ASSETS=false TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [[ $(calls_matching 'release create') == "release create v1.0.0-pr.77 --target abc "* ]]
}

@test "with assets: requires the assets directory" {
  ASSETS_DIR= TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run --separate-stderr "$PUBLISH" pr
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: ASSETS_DIR is required" ]
  [ -z "$(cat "$GH_LOG")" ]
}

@test "fails on an invalid ASSETS value and publishes nothing" {
  ASSETS=no TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run --separate-stderr "$PUBLISH" pr
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: ASSETS must be true or false, not 'no'" ]
  [ -z "$(cat "$GH_LOG")" ]
}
