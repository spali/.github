#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  export GH_REPO=spali/sandbox PR_NUMBER=12
  CHECK="$BATS_TEST_DIRNAME/../scripts/check-pr.sh"
  labels '["fix"]'
}

# labels registers the labels the PR currently has.
labels() {
  jq -r '.[]' <<<"$1" | gh_respond 'pr view 12 --json labels --jq *' -
}

@test "accepts conventional titles" {
  for title in 'feat: add x' 'fix(parser): y' 'feat!: z' 'chore(deps): update a' \
    'refactor(api)!: b' 'ci(codeql): keep category' 'docs: README.md and v1.2/x'; do
    PR_TITLE=$title run "$CHECK"
    [ "$status" -eq 0 ] || { echo "rejected: $title"; return 1; }
  done
}

@test "rejects non conventional titles" {
  for title in 'Add x' 'feat:x' 'feature: x' 'dev: x' 'feat(): x' 'FEAT: x' 'feat: ' ''; do
    PR_TITLE=$title run --separate-stderr "$CHECK"
    [ "$status" -eq 1 ] || { echo "accepted: $title"; return 1; }
    [[ $stderr == "error: PR title must follow Conventional Commits"* ]]
  done
}

@test "never evaluates the title" {
  PR_TITLE='feat: $(touch '"$BATS_TEST_TMPDIR"'/pwned) "q" `touch '"$BATS_TEST_TMPDIR"'/pwned2`' run "$CHECK"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
  [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
}

@test "fails without a release label" {
  stub_gh
  labels '["bug","question"]'
  PR_TITLE='fix: y' run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: PR has none of the labels breaking-change, dependencies, feature, fix, other" ]
}

@test "passes with one release label among others" {
  stub_gh
  labels '["bug","fix"]'
  PR_TITLE='fix: y' run "$CHECK"
  [ "$status" -eq 0 ]
  grep -qx 'pr view 12 --json labels --jq .labels\[\].name' "$GH_LOG"
}

@test "requires PR_NUMBER and GH_REPO" {
  PR_TITLE='fix: y' PR_NUMBER= run --separate-stderr "$CHECK"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: PR_NUMBER is required" ]
}

@test "warns about several release labels" {
  stub_gh
  labels '["breaking-change","feature"]'
  PR_TITLE='feat: y' run "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "::warning::PR has several release labels (breaking-change, feature): the release notes use breaking-change. Remove the labels that do not apply." ]
}

@test "no warning with one release label" {
  PR_TITLE='fix: y' run "$CHECK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
