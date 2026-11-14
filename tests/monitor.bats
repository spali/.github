#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REAL="$BATS_TEST_DIRNAME/../scripts"
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
  # A scripts dir with the real config/report/lib and stubbed checks.
  export MONITOR_SCRIPTS_DIR="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$MONITOR_SCRIPTS_DIR"
  cp "$REAL"/lib.sh "$REAL"/monitor-lib.sh "$REAL"/monitor-config.sh \
    "$REAL"/monitor-report.sh "$MONITOR_SCRIPTS_DIR"/
  local s
  for s in release settings health forks mirrors lists; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$MONITOR_SCRIPTS_DIR/monitor-$s.sh"
  done
  cp "$FIX/inventory.json" "$BATS_TEST_TMPDIR/inventory.json"
  cat >"$MONITOR_SCRIPTS_DIR/monitor-repos.sh" <<EOS
#!/usr/bin/env bash
cat "$BATS_TEST_TMPDIR/inventory.json"
EOS
  chmod +x "$MONITOR_SCRIPTS_DIR"/*.sh
  cat >"$BATS_TEST_TMPDIR/public.yml" <<'EOS'
version: 1
EOS
  export MONITOR_PUBLIC_CONFIG="$BATS_TEST_TMPDIR/public.yml"
  unset MONITOR_PRIVATE_CONFIG GITHUB_STEP_SUMMARY GITHUB_ACTIONS MONITOR_UNMASK
  export GH_TOKEN=t
  MONITOR="$REAL/monitor.sh"
}

@test "clean run exits 0 and prints only the report" {
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 0 ]
  [[ $output == "## Maintenance monitor"* ]]
  [[ $output == *"0 red"* ]]
  [ -z "$stderr" ]
}

@test "a crashing check script is red" {
  printf '#!/usr/bin/env bash\necho secret >&2\nexit 3\n' >"$MONITOR_SCRIPTS_DIR/monitor-health.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"check-failed"* ]]
  [[ $output == *"monitor-health.sh crashed"* ]]
  [[ $output != *secret* ]]
  [ -z "$stderr" ]
}

@test "a crashing inventory script is red with an empty inventory" {
  printf '#!/usr/bin/env bash\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-repos.sh"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"monitor-repos.sh crashed"* ]]
}

@test "invalid private config is red without details" {
  printf 'version: 1\nmirrors:\n  - target: spali/hidden-name\n' >"$BATS_TEST_TMPDIR/private.yml"
  export MONITOR_PRIVATE_CONFIG="$BATS_TEST_TMPDIR/private.yml"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"config-invalid"* ]]
  [[ $output == *"private control file is invalid"* ]]
  [[ $output != *hidden-name* ]]
  [[ $output != *interval_hours* ]]
  [ -z "$stderr" ]
}

@test "missing private config is red" {
  export MONITOR_PRIVATE_CONFIG="$BATS_TEST_TMPDIR/nope.yml"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"private control file missing"* ]]
}

@test "valid private config is merged and ignores apply" {
  cat >"$BATS_TEST_TMPDIR/private.yml" <<'EOS'
version: 1
ignores:
  - repo: spali/secret-repo
    check: adoption
    reason: private on purpose
EOS
  export MONITOR_PRIVATE_CONFIG="$BATS_TEST_TMPDIR/private.yml"
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\nfinding red adoption spali/secret-repo x\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run "$MONITOR"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red"* ]]
}

@test "invalid public config is red and the run continues" {
  printf 'version: 2\n' >"$MONITOR_PUBLIC_CONFIG"
  cat >"$BATS_TEST_TMPDIR/private.yml" <<'EOS'
version: 1
ignores:
  - repo: spali/secret-repo
    check: adoption
    reason: private on purpose
EOS
  export MONITOR_PRIVATE_CONFIG="$BATS_TEST_TMPDIR/private.yml"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output != *"cannot be merged"* ]]
  [[ $output == *"config-invalid"* ]]
  [[ $output == *"repos.yml: "*"version must be 1"* ]]
}

@test "public config naming a private repo is red" {
  cat >"$MONITOR_PUBLIC_CONFIG" <<'EOS'
version: 1
ignores:
  - repo: spali/secret-repo
    check: adoption
    reason: oops
EOS
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"public-config-private-repo"* ]]
  [[ $output != *"secret-repo"* ]]
}

@test "large inventory still reports a public config naming a private repo" {
  jq -c '.[] | . + {pad: ("x" * 100000)}' "$FIX/inventory.json" |
    jq -s . >"$BATS_TEST_TMPDIR/inventory.json"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/inventory.json")" -gt 200000 ]
  cat >"$MONITOR_PUBLIC_CONFIG" <<'EOS'
version: 1
ignores:
  - repo: spali/secret-repo
    check: adoption
    reason: oops
EOS
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"public-config-private-repo: 1 private repo(s)"* ]]
  [[ $output != *"secret-repo"* ]]
  [ -z "$stderr" ]
}
