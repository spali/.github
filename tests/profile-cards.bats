#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/git-repos
  repos_init
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/profile-cards.sh"
  unset GH_TOKEN PROFILE_BRANCH PROFILE_APP_SLUG
  export PROFILE_CARDS='[{"card":"stats","options":"a=b","path":"profile/stats.svg"},{"card":"top-langs","options":"","path":"profile/top-langs.svg"}]'
  SRC="$BATS_TEST_TMPDIR/src"
  mkdir -p "$SRC/profile"
  echo '<svg>stats</svg>' >"$SRC/profile/stats.svg"
  echo '<svg>langs</svg>' >"$SRC/profile/top-langs.svg"
  README=$(commit - README.md hello)
  set_ref "$TG" refs/heads/main "$README"
}

# refused CARDS runs check with CARDS and expects exit 1 and an error.
refused() {
  PROFILE_CARDS=$1 run --separate-stderr "$SCRIPT" check
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ $stderr == error:* ]]
}

# card PATH prints a one-card list with PATH.
card() {
  jq -nc --arg p "$1" '[{card: "stats", options: "", path: $p}]'
}

@test "check prints the valid list compact" {
  run --separate-stderr "$SCRIPT" check
  [ "$status" -eq 0 ]
  [ "$output" = "$PROFILE_CARDS" ]
}

@test "check accepts pin, wakatime and gist cards" {
  PROFILE_CARDS='[{"card":"pin","path":"a.svg"},{"card":"wakatime","path":"b.svg"},{"card":"gist","path":"c.svg"}]' \
    run --separate-stderr "$SCRIPT" check
  [ "$status" -eq 0 ]
}

@test "check refuses an empty list" { refused '[]'; }
@test "check refuses a non-array" { refused '{"card":"stats"}'; }
@test "check refuses invalid JSON" { refused 'nope'; }
@test "check refuses an unknown card" { refused '[{"card":"foo","path":"a.svg"}]'; }
@test "check refuses a missing path" { refused '[{"card":"stats"}]'; }
@test "check refuses a path without .svg" { refused "$(card profile/stats.png)"; }
@test "check refuses an absolute path" { refused "$(card /x.svg)"; }
@test "check refuses a .. segment" { refused "$(card profile/../../x.svg)"; }
@test "check refuses a leading .. segment" { refused "$(card ../x.svg)"; }
@test "check refuses a path in .git" { refused "$(card .git/x.svg)"; }
@test "check refuses an empty segment" { refused "$(card profile//x.svg)"; }

@test "check refuses a duplicate path" {
  refused '[{"card":"stats","path":"a.svg"},{"card":"top-langs","path":"a.svg"}]'
}

@test "check without PROFILE_CARDS is a usage error" {
  unset PROFILE_CARDS
  run --separate-stderr "$SCRIPT" check
  [ "$status" -eq 2 ]
}

@test "commit writes all cards in one commit and pushes" {
  run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 0 ]
  head=$(ref "$TG" refs/heads/main)
  [ "$output" = "pushed $head" ]
  [ "$(git -C "$TG" rev-parse "$head^")" = "$README" ]
  [ "$(git -C "$TG" log -1 --format=%s main)" = "chore: update profile cards" ]
  [ "$(git -C "$TG" log -1 --format=%cn main)" = sync ]
  [ "$(git -C "$TG" show main:profile/stats.svg)" = '<svg>stats</svg>' ]
  [ "$(git -C "$TG" show main:profile/top-langs.svg)" = '<svg>langs</svg>' ]
  [ "$(git -C "$TG" show main:README.md)" = hello ]
}

@test "commit without changes pushes nothing" {
  "$SCRIPT" commit "$SRC" >/dev/null
  head=$(ref "$TG" refs/heads/main)
  rm -rf "$WORK" && mkdir "$WORK"
  run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  [ "$(ref "$TG" refs/heads/main)" = "$head" ]
}

@test "commit uses PROFILE_BRANCH" {
  set_ref "$TG" refs/heads/test "$README"
  PROFILE_BRANCH=test run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 0 ]
  [ "$(ref "$TG" refs/heads/main)" = "$README" ]
  [ "$(git -C "$TG" show test:profile/stats.svg)" = '<svg>stats</svg>' ]
}

@test "commit uses the app bot as committer" {
  unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  PROFILE_APP_SLUG=my-app run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 0 ]
  [ "$(git -C "$TG" log -1 --format='%cn <%ce>' main)" = 'my-app[bot] <my-app[bot]@users.noreply.github.com>' ]
}

@test "commit fails on a missing card file and pushes nothing" {
  rm "$SRC/profile/top-langs.svg"
  run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 1 ]
  [[ $stderr == *profile/top-langs.svg* ]]
  [ "$(ref "$TG" refs/heads/main)" = "$README" ]
}

@test "commit refuses an invalid list before cloning" {
  PROFILE_CARDS='[]' run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$WORK")" ]
}

@test "commit fails when the target moved ahead" {
  other=$(commit "$README" other.txt x)
  # a race: the pre-push hook moves the target before the push lands
  mkdir -p "$BATS_TEST_TMPDIR/hooks"
  printf '#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT\ngit -C %q push -q -f %q %s:refs/heads/main\n' "$SCRATCH" "$TG" "$other" >"$BATS_TEST_TMPDIR/hooks/pre-push"
  chmod +x "$BATS_TEST_TMPDIR/hooks/pre-push"
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$BATS_TEST_TMPDIR/hooks" \
    run --separate-stderr "$SCRIPT" commit "$SRC"
  [ "$status" -eq 1 ]
  [ "$(ref "$TG" refs/heads/main)" = "$other" ]
}

@test "commit without SRC_DIR is a usage error" {
  run --separate-stderr "$SCRIPT" commit
  [ "$status" -eq 2 ]
}
