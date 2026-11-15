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

@test "validate without a file fails" {
  run --separate-stderr "$CONFIG" validate
  [ "$status" -eq 1 ]
  [[ $stderr == "error: usage"* ]]
}

@test "lists are allowed" {
  f=$(printf 'version: 1\nlists: {archive: a}\n' | mk ok.yml)
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
  archive: [a]
  mirrors: 3
  forks: x
  exclusive: [[a, b], [c], [d, 1], x]
YAML
  )
  run --separate-stderr "$CONFIG" validate "$f"
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: $f: lists: unknown key mirror"* ]]
  [[ $stderr == *"lists: unknown key exclusiv"* ]]
  [[ $stderr == *"lists.archive must be a string"* ]]
  [[ $stderr == *"lists.mirrors must be a string"* ]]
  [[ $stderr == *"lists.forks must be a list of strings"* ]]
  [[ $stderr == *"lists.exclusive[1] must be a pair of strings"* ]]
  [[ $stderr == *"lists.exclusive[2] must be a pair of strings"* ]]
  [[ $stderr == *"lists.exclusive[3] must be a pair of strings"* ]]
  [[ $stderr != *"exclusive[0]"* ]]
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
