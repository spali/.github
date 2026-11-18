#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
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

@test "duplicate ignore fails" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: main-red, reason: a}\n  - {repo: spali/x, check: main-red, reason: b}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"duplicate ignore spali/x main-red"* ]]
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

@test "validate without a file fails" {
  run --separate-stderr "$CONFIG" validate
  [ "$status" -eq 1 ]
  [[ $stderr == "error: usage"* ]]
}

@test "lists are allowed" {
  f=$(printf 'version: 1\nlists: {archived: [a]}\n' | mk ok.yml)
  run "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}

@test "a control file above 200 KB is validated completely" {
  {
    echo 'version: 1'
    echo 'ignores:'
    for i in $(seq 1 3000); do
      printf '  - {repo: spali/r%s, check: main-red, reason: "%s"}\n' "$i" "$(head -c 80 /dev/zero | tr '\0' x)"
    done
  } >"$BATS_TEST_TMPDIR/big.yml"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/big.yml")" -gt 200000 ]
  run --separate-stderr "$CONFIG" validate "$BATS_TEST_TMPDIR/big.yml"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  printf '  - {repo: spali/r1, check: main-red, reason: dup}\n' >>"$BATS_TEST_TMPDIR/big.yml"
  run --separate-stderr "$CONFIG" validate "$BATS_TEST_TMPDIR/big.yml"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: $BATS_TEST_TMPDIR/big.yml: duplicate ignore spali/r1 main-red" ]
}

@test "unknown command fails" {
  run --separate-stderr "$CONFIG" bogus
  [ "$status" -eq 1 ]
  [[ $stderr == "error: "* ]]
}

@test "unknown lists key and wrong list types fail" {
  f=$(
    mk bad.yml <<'YAML'
version: 1
lists:
  mirror: x
  exclusiv: []
  archived: x
  external: x
  exclusive: [[a, b], [c], [d, 1], x]
YAML
  )
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: lists: unknown key mirror"* ]]
  [[ $stderr == *"lists: unknown key exclusiv"* ]]
  [[ $stderr == *"lists.archived must be a list of strings"* ]]
  [[ $stderr == *"lists.external must be a list of strings"* ]]
  [[ $stderr == *"lists.exclusive[1] must be a pair of strings"* ]]
  [[ $stderr == *"lists.exclusive[2] must be a pair of strings"* ]]
  [[ $stderr == *"lists.exclusive[3] must be a pair of strings"* ]]
  [[ $stderr != *"exclusive[0]"* ]]
}

@test "lists.mirrors must be a mapping" {
  f=$(printf 'version: 1\nlists: {mirrors: [a]}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists.mirrors must be a mapping"* ]]
}

@test "lists.exclusive must be a list" {
  f=$(printf 'version: 1\nlists: {exclusive: x}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists.exclusive must be a list"* ]]
}

@test "ignoring check-failed fails" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: check-failed, reason: r}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: $f: ignores[0].check: check-failed cannot be ignored" ]
}

@test "monitor settings are allowed" {
  f=$(printf 'version: 1\nmonitor:\n  jobs: per-repo\n  runs-on: [self-hosted, linux]\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  f=$(printf 'version: 1\nmonitor:\n  jobs: per-group\n  runs-on: ubuntu-24.04\n' | mk ok2.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}

@test "wrong monitor settings fail" {
  f=$(printf 'version: 1\nmonitor:\n  jobs: all\n  runs-on: [1]\n  runner: x\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"monitor: unknown key runner"* ]]
  [[ $stderr == *"monitor.jobs must be per-group or per-repo"* ]]
  [[ $stderr == *"monitor.runs-on must be a label or a list of labels"* ]]
}

@test "monitor must be a mapping" {
  f=$(printf 'version: 1\nmonitor: per-repo\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: $f: monitor must be a mapping" ]
}

# managed_bad ENTRY_YAML_LINES EXPECTED: validation of a one-entry managed list.
managed_bad() {
  f=$(printf 'version: 1\nmanaged:\n%s\n' "$1" | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: $2"* ]]
}

@test "managed: exact keba example passes" {
  f=$(
    mk ok.yml <<'YAML'
version: 1
managed:
  - repo: spali/homeassistant-keba
    upstream: https://github.com/dannerph/homeassistant-keba
    branches:
      main: { onto: main, rebase: auto }
    settings: {}
  - repo: spali/knx.js
    upstream: https://bitbucket.org/ekarak/knx.js
YAML
  )
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "managed: valid full entry passes" {
  f=$(
    mk ok.yml <<'YAML'
version: 1
managed:
  - repo: spali/a
    upstream: https://github.com/o/a.git/
    follow: ['.*']
    tags: false
    private: true
    branches:
      release/1.x: { onto: main, rebase: manual }
    settings: { has_issues: true, has_wiki: false, actions: true }
YAML
  )
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "managed: repo is required" {
  managed_bad '  - {upstream: "https://github.com/o/a"}' "managed[0].repo is required"
}

@test "managed: upstream must start with https" {
  managed_bad '  - {repo: spali/a, upstream: "http://github.com/o/a"}' "managed[0].upstream must start with https://"
}

@test "managed: github.com upstream must be owner/name" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a/tree/x"}' "managed[0].upstream is not a github.com repository URL"
}

@test "managed: refs is an unknown key" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", refs: all}' "managed[0]: unknown key refs"
  managed_bad '  - {repo: spali/a, upstream: "https://example.org/a", refs: default}' "managed[0]: unknown key refs"
}

@test "managed: tags must be a boolean" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", tags: "no"}' "managed[0].tags must be a boolean"
  managed_bad '  - {repo: spali/a, upstream: "https://example.org/a", tags: 0}' "managed[0].tags must be a boolean"
}

@test "managed: branch onto is required" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {main: {rebase: auto}}}' "managed[0].branches.main.onto is required"
}

@test "managed: branch rebase must be auto or manual" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {main: {onto: main, rebase: x}}}' "managed[0].branches.main.rebase must be auto or manual"
}

@test "managed: invalid branch name fails" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {"a b": {onto: main, rebase: auto}}}' 'managed[0].branches: "a b" is not a valid branch name'
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {"a..b": {onto: main, rebase: auto}}}' 'managed[0].branches: "a..b" is not a valid branch name'
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {"-a": {onto: main, rebase: auto}}}' 'managed[0].branches: "-a" is not a valid branch name'
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {"/a": {onto: main, rebase: auto}}}' 'managed[0].branches: "/a" is not a valid branch name'
}

@test "managed: unknown settings key fails" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", settings: {foo: true}}' "managed[0].settings: unknown key foo"
}

@test "managed: settings values must be booleans" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", settings: {has_issues: 1}}' "managed[0].settings.has_issues must be a boolean"
}

@test "managed: private must be a boolean" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", private: "yes"}' "managed[0].private must be a boolean"
}

@test "managed: duplicate repo fails" {
  managed_bad '  - {repo: spali/x, upstream: "https://github.com/o/a"}
  - {repo: spali/x, upstream: "https://github.com/o/b"}' "duplicate managed spali/x"
}

@test "managed: onto must be a valid branch name" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {main: {onto: "--x", rebase: auto}}}' 'managed[0].branches.main.onto: "--x" is not a valid branch name'
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {main: {onto: "a b", rebase: auto}}}' 'managed[0].branches.main.onto: "a b" is not a valid branch name'
}

@test "managed: non-string onto is invalid" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: {main: {onto: 1, rebase: auto}}}' "managed[0].branches.main.onto is invalid"
}

@test "managed: github.com host is case-insensitive" {
  managed_bad '  - {repo: spali/a, upstream: "https://GitHub.com/o/a/tree/x"}' "managed[0].upstream is not a github.com repository URL"
  f=$(printf 'version: 1\nmanaged:\n  - {repo: spali/a, upstream: "https://GitHub.com/o/a", tags: true}\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}

@test "managed: duplicate and overlap checks ignore case" {
  managed_bad '  - {repo: spali/X, upstream: "https://github.com/o/a"}
  - {repo: spali/x, upstream: "https://github.com/o/b"}' "duplicate managed spali/x"
}

@test "managed: unknown entry key fails" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", foo: 1}' "managed[0]: unknown key foo"
}

@test "managed: branches and settings must be mappings" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", branches: [main]}' "managed[0].branches must be a mapping"
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", settings: [a]}' "managed[0].settings must be a mapping"
}

@test "managed: must be a list" {
  f=$(printf 'version: 1\nmanaged: x\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: $f: managed must be a list" ]
}

@test "managed: follow must be a list of strings" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", follow: "release/.*"}' "managed[0].follow must be a list of strings"
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", follow: [1]}' "managed[0].follow must be a list of strings"
}

@test "managed: follow pattern must be a valid regular expression" {
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", follow: ["ok", "release/(v"]}' "managed[0].follow[1]: invalid regular expression"
  # a pattern that only compiles inside the full-match wrapper is refused too
  managed_bad '  - {repo: spali/a, upstream: "https://github.com/o/a", follow: ["a)|(?:.*"]}' "managed[0].follow[0]: invalid regular expression"
}

@test "managed: follow allowed for a mirror" {
  f=$(printf 'version: 1\nmanaged:\n  - {repo: spali/a, upstream: "https://example.org/a", follow: [".*"], tags: false}\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "managed: valid follow passes" {
  f=$(
    mk ok.yml <<'YAML'
version: 1
managed:
  - repo: spali/a
    upstream: https://github.com/o/a
    follow: ['^release/v[0-9]+\.[0-9]+$', 'stable']
  - repo: spali/b
    upstream: https://github.com/o/b
    follow: []
YAML
  )
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "forks key was removed" {
  f=$(printf 'version: 1\nforks: []\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *'`forks:` was removed: move the entry to `managed:`'* ]]
}

@test "mirrors key was removed" {
  f=$(printf 'version: 1\nmirrors: []\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *'`mirrors:` was removed: move the entry to `managed:`'* ]]
}

@test "lists.archive was removed" {
  f=$(printf 'version: 1\nlists: {archive: a}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *'`lists.archive` was removed: use `lists.archived`'* ]]
}

@test "lists.archived must be a list of strings" {
  f=$(printf 'version: 1\nlists: {archived: "x"}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists.archived must be a list of strings"* ]]
  f=$(printf 'version: 1\nlists: {archived: ["a", "b"]}\n' | mk ok.yml)
  run "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}

@test "lists.mirrors as a string is rejected" {
  f=$(printf 'version: 1\nlists: {mirrors: x}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *'`lists.mirrors` is now a mapping: put the List under `lists.mirrors.synced`'* ]]
}

@test "lists.forks was removed" {
  f=$(printf 'version: 1\nlists: {forks: [a]}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *'`lists.forks` was removed: put the Lists under `lists.mirrors.other`'* ]]
}

@test "lists.mirrors mapping with synced and other is valid" {
  f=$(printf 'version: 1\nlists:\n  mirrors: {synced: [a], other: [b]}\n  external: [c]\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}

@test "lists.mirrors mapping is checked" {
  f=$(printf 'version: 1\nlists: {mirrors: {foo: []}}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists.mirrors: unknown key foo"* ]]
  f=$(printf 'version: 1\nlists: {mirrors: {synced: x, other: [1]}}\n' | mk bad2.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists.mirrors.synced must be a list of strings"* ]]
  [[ $stderr == *"lists.mirrors.other must be a list of strings"* ]]
}

@test "lists.external must be a list of strings" {
  f=$(printf 'version: 1\nlists: {external: "x"}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"lists.external must be a list of strings"* ]]
}

@test "unanswered days is accepted" {
  f=$(printf 'version: 1\nunanswered:\n  days: 14\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "unanswered: unknown key fails" {
  f=$(printf 'version: 1\nunanswered:\n  day: 3\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: unanswered: unknown key day"* ]]
}

@test "unanswered.days must be a positive integer" {
  for v in 0 -1 1.5 abc; do
    f=$(printf 'version: 1\nunanswered:\n  days: %s\n' "$v" | mk bad.yml)
    run --separate-stderr "$CONFIG" validate "$f"
    [ "$status" -eq 1 ]
    [[ $stderr == *"error: $f: unanswered.days must be a positive integer"* ]]
  done
}

@test "billing: full and partial blocks are accepted" {
  f=$(printf 'version: 1\nbilling:\n  minutes: {included: 2000, threshold: 75.5}\n  storage: {included-gb: 0.5, threshold: 100}\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  f=$(printf 'version: 1\nbilling: {minutes: {threshold: 80}}\n' | mk ok2.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
}

@test "billing must be a mapping" {
  f=$(printf 'version: 1\nbilling: 5\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: billing must be a mapping"* ]]
}

@test "billing: unknown keys fail" {
  f=$(printf 'version: 1\nbilling:\n  foo: 1\n  minutes: {bar: 1}\n  storage: {baz: 1}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: billing: unknown key foo"* ]]
  [[ $stderr == *"error: $f: billing.minutes: unknown key bar"* ]]
  [[ $stderr == *"error: $f: billing.storage: unknown key baz"* ]]
}

@test "billing.minutes and billing.storage must be mappings" {
  f=$(printf 'version: 1\nbilling:\n  minutes: 1\n  storage: x\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: billing.minutes must be a mapping"* ]]
  [[ $stderr == *"error: $f: billing.storage must be a mapping"* ]]
}

@test "billing.minutes.included must be a positive integer" {
  for v in 0 -1 1.5 abc; do
    f=$(printf 'version: 1\nbilling:\n  minutes: {included: %s}\n' "$v" | mk bad.yml)
    run --separate-stderr "$CONFIG" validate "$f"
    [ "$status" -eq 1 ]
    [[ $stderr == *"error: $f: billing.minutes.included must be a positive integer"* ]]
  done
}

@test "billing thresholds must be a number from 1 to 100" {
  for v in 0 0.5 101 abc; do
    for k in minutes storage; do
      f=$(printf 'version: 1\nbilling:\n  %s: {threshold: %s}\n' "$k" "$v" | mk bad.yml)
      run --separate-stderr "$CONFIG" validate "$f"
      [ "$status" -eq 1 ]
      [[ $stderr == *"error: $f: billing.$k.threshold must be a number from 1 to 100"* ]]
    done
  done
}

@test "billing.storage.included-gb must be a positive number" {
  for v in 0 -1 abc; do
    f=$(printf 'version: 1\nbilling:\n  storage: {included-gb: %s}\n' "$v" | mk bad.yml)
    run --separate-stderr "$CONFIG" validate "$f"
    [ "$status" -eq 1 ]
    [[ $stderr == *"error: $f: billing.storage.included-gb must be a positive number"* ]]
  done
}

@test "ignores item must be a positive integer" {
  for v in 0 -2 1.5 abc; do
    f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: unanswered, item: %s, reason: r}\n' "$v" | mk bad.yml)
    run --separate-stderr "$CONFIG" validate "$f"
    [ "$status" -eq 1 ]
    [[ $stderr == *"error: $f: ignores[0].item must be a positive integer"* ]]
  done
}

@test "ignores with different items are not duplicates" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: unanswered, item: 1, reason: a}\n  - {repo: spali/x, check: unanswered, item: 2, reason: b}\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}

@test "the same item ignore twice is a duplicate" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: unanswered, item: 1, reason: a}\n  - {repo: spali/x, check: unanswered, item: 1, reason: b}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"duplicate ignore spali/x unanswered 1"* ]]
}

@test "ignores item is only allowed for the checks unanswered and stale-branch" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: adoption, item: 3, reason: r}\n' | mk bad.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: ignores[0].item is only allowed for the checks unanswered and stale-branch"* ]]
}

@test "ignores item is allowed for stale-branch" {
  f=$(printf 'version: 1\nignores:\n  - {repo: spali/x, check: stale-branch, item: 3, reason: r}\n' | mk ok.yml)
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 0 ]
}
