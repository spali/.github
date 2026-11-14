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

@test "release: uploads to the draft and publishes it as latest" {
  TAG=v1.0.0 VERSION=1.0.0 DRAFT_ID=42 run "$PUBLISH" release
  [ "$status" -eq 0 ]
  [ "$(calls_matching 'release upload')" = "release upload v1.0.0 $FILES --clobber" ]
  [ "$(calls_matching 'api -X PATCH')" = "api -X PATCH repos/spali/sandbox/releases/42 -F draft=false -f tag_name=v1.0.0 -F prerelease=false -f make_latest=true" ]
  [ "$(sed -n 1p "$GH_LOG")" = "release upload v1.0.0 $FILES --clobber" ]
}

@test "release: a version with a suffix becomes a pre-release, not latest" {
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

@test "pr: updates an existing dev build comment" {
  echo 991 | gh_respond 'api repos/spali/sandbox/issues/77/comments --paginate --jq *' -
  TAG=v1.0.0-pr.77 VERSION=1.0.0-pr.77 PR=77 run "$PUBLISH" pr
  [ "$status" -eq 0 ]
  [ -z "$(calls_matching 'pr comment')" ]
  patch=$(calls_matching 'api -X PATCH')
  [[ $patch == "api -X PATCH repos/spali/sandbox/issues/comments/991 -F body=@"* ]]
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
