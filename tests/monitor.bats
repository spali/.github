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
  for s in release settings health forks lists billing; do
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
  export MONITOR_CONFIG="$BATS_TEST_TMPDIR/public.yml"
  unset MONITOR_ISSUE_REPO GITHUB_STEP_SUMMARY GITHUB_ACTIONS
  # a recording stand-in for the issue script
  cat >"$MONITOR_SCRIPTS_DIR/monitor-issue.sh" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$1" "\$2" "\${MONITOR_ISSUE_REPO:-}" >"$BATS_TEST_TMPDIR/issue.args"
cp "\$1" "$BATS_TEST_TMPDIR/issue.report"
[[ -z \${ISSUE_FAIL:-} ]] || { echo "error: updating issue #1 failed: boom (HTTP 422)" >&2; echo "second line" >&2; exit 1; }
EOS
  chmod +x "$MONITOR_SCRIPTS_DIR/monitor-issue.sh"
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
  printf '#!/usr/bin/env bash\necho leaked-stderr >&2\nexit 3\n' >"$MONITOR_SCRIPTS_DIR/monitor-health.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"check-failed"* ]]
  [[ $output == *"monitor-health.sh crashed"* ]]
  [[ $output != *leaked-stderr* ]]
  [ -z "$stderr" ]
}

@test "a crashing inventory script is red with an empty inventory" {
  printf '#!/usr/bin/env bash\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-repos.sh"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"monitor-repos.sh crashed"* ]]
}

@test "invalid config is red and the run continues with the empty config" {
  printf 'version: 2\n' >"$MONITOR_CONFIG"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"config-invalid"* ]]
  [[ $output == *"public.yml: "*"version must be 1"* ]]
  [ -z "$stderr" ]
}

@test "missing config file is red" {
  export MONITOR_CONFIG="$BATS_TEST_TMPDIR/nope.yml"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"nope.yml: "*"cannot read file"* ]]
}

@test "MONITOR_CONFIG defaults to repos.yml in the working directory" {
  unset MONITOR_CONFIG
  cd "$BATS_TEST_TMPDIR"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"repos.yml: "*"cannot read file"* ]]
  cp public.yml repos.yml
  run "$MONITOR"
  [ "$status" -eq 0 ]
}

@test "the config is converted to JSON for the checks" {
  cat >"$BATS_TEST_TMPDIR/public.yml" <<'EOS'
version: 1
ignores:
  - repo: spali/x
    check: adoption
    reason: on purpose
EOS
  printf '#!/usr/bin/env bash\ncp "$CONFIG" "%s/config.seen"\n' "$BATS_TEST_TMPDIR" >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run "$MONITOR"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.ignores[0].repo' "$BATS_TEST_TMPDIR/config.seen")" = '"spali/x"' ]
  [[ $output == *"unused ignore: on purpose"* ]]
}

@test "ignores of the config apply" {
  cat >"$MONITOR_CONFIG" <<'EOS'
version: 1
ignores:
  - repo: spali/some-repo
    check: adoption
    reason: on purpose
EOS
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\nfinding red adoption spali/some-repo x\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run "$MONITOR"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red"* ]]
}

@test "an item ignore hides only its item" {
  cat >"$MONITOR_CONFIG" <<'EOS'
version: 1
ignores:
  - repo: spali/some-repo
    check: unanswered
    item: 70
    reason: reviewed elsewhere
EOS
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\nfinding red unanswered spali/some-repo x 70\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run "$MONITOR"
  [ "$status" -eq 0 ]
  [[ $output == *"0 red"* ]]
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\nfinding red unanswered spali/some-repo x 71\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"1 red"* ]]
}

@test "the report goes to GITHUB_STEP_SUMMARY when set" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
  grep -q '^## Maintenance monitor' "$GITHUB_STEP_SUMMARY"
}

@test "without MONITOR_ISSUE_REPO the issue script is not run" {
  run "$MONITOR"
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/issue.args" ]
}

@test "with MONITOR_ISSUE_REPO the issue is updated with the report and the counts" {
  export MONITOR_ISSUE_REPO=spali/ctl
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\nfinding red adoption a x\nfinding red main-red b y\nfinding info list-none c z\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/issue.args")" = "Maintenance monitor: 2 red · 1 info" ]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/issue.args")" = spali/ctl ]
  [ "$(<"$BATS_TEST_TMPDIR/issue.report")" = "$output" ]
}

@test "a clean run with the issue updated exits 0" {
  export MONITOR_ISSUE_REPO=spali/ctl
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/issue.args")" = "Maintenance monitor: 0 red · 0 info" ]
}

@test "a failing issue update prints one error line and fails an otherwise clean run" {
  export MONITOR_ISSUE_REPO=spali/ctl ISSUE_FAIL=1
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: updating issue #1 failed: boom (HTTP 422)" ]
  [[ $output == *"0 red"* ]]
}

@test "a red finding fails the run even when the issue update works" {
  export MONITOR_ISSUE_REPO=spali/ctl
  printf '#!/usr/bin/env bash\nexit 3\n' >"$MONITOR_SCRIPTS_DIR/monitor-health.sh"
  run "$MONITOR"
  [ "$status" -eq 1 ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/issue.args")" = "Maintenance monitor: 1 red · 0 info" ]
}

@test "a failing issue script without output still names itself" {
  export MONITOR_ISSUE_REPO=spali/ctl
  printf '#!/usr/bin/env bash\nexit 4\n' >"$MONITOR_SCRIPTS_DIR/monitor-issue.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: monitor-issue.sh failed" ]
}

@test "a crashing report script fails the run" {
  printf '#!/usr/bin/env bash\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-report.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: monitor-report.sh crashed" ]
}

@test "a crashing report script still updates the issue and then fails" {
  export MONITOR_ISSUE_REPO=spali/ctl
  printf '#!/usr/bin/env bash\necho partial\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-report.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: monitor-report.sh crashed" ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/issue.args")" = "Maintenance monitor: report crashed" ]
  [[ "$(<"$BATS_TEST_TMPDIR/issue.report")" == *"report script crashed"*"see the run log"* ]]
  [[ "$(<"$BATS_TEST_TMPDIR/issue.report")" != *partial* ]]
}

@test "a crashing report script and a failing issue update print both error lines" {
  export MONITOR_ISSUE_REPO=spali/ctl ISSUE_FAIL=1
  printf '#!/usr/bin/env bash\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-report.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [ "$stderr" = $'error: monitor-report.sh crashed\nerror: updating issue #1 failed: boom (HTTP 422)' ]
}

@test "a large inventory (over 200 KB) is handled" {
  jq -c '.[] | . + {pad: ("x" * 100000)}' "$FIX/inventory.json" |
    jq -s . >"$BATS_TEST_TMPDIR/inventory.json"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/inventory.json")" -gt 200000 ]
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\njq -e length "$INVENTORY" >/dev/null && finding red adoption a x\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 1 ]
  [[ $output == *"1 red"* ]]
  [ -z "$stderr" ]
}

# --- phases (one workflow step each) -------------------------------------

# phase PHASE runs one phase in the shared work dir.
phase() {
  run --separate-stderr env MONITOR_WORK="$BATS_TEST_TMPDIR/work" "$MONITOR" "$@"
}

# check_stub NAME BODY: a check script that sources the lib and runs BODY.
check_stub() {
  printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/monitor-lib.sh"\n%s\n' "$2" \
    >"$MONITOR_SCRIPTS_DIR/monitor-$1.sh"
}

@test "a phase needs MONITOR_WORK" {
  run --separate-stderr "$MONITOR" config
  [ "$status" -eq 2 ]
  [ "$stderr" = "error: MONITOR_WORK is required for a single phase" ]
}

@test "an unknown phase is an error" {
  phase nope
  [ "$status" -eq 2 ]
  [ "$stderr" = "error: unknown phase nope (config inventory matrix release settings health forks lists billing report issue)" ]
}

@test "config phase reports a valid control file" {
  phase config
  [ "$status" -eq 0 ]
  [ "$output" = "✓ public.yml is valid" ]
  [ -s "$BATS_TEST_TMPDIR/work/config.json" ]
}

@test "config phase fails with an annotation for an invalid control file" {
  printf 'version: 2\n' >"$MONITOR_CONFIG"
  phase config
  [ "$status" -eq 1 ]
  [[ ${lines[0]} == "::error title=config-invalid::public.yml: "*"version must be 1"* ]]
  [ "$(jq -c . "$BATS_TEST_TMPDIR/work/config.json")" = '{"version":1,"lists":{},"ignores":[]}' ]
}

@test "inventory phase prints the counts" {
  phase config
  phase inventory
  [ "$status" -eq 0 ]
  [ "$output" = "✓ $(jq length "$FIX/inventory.json") repositories, $(jq 'map(select(.central)) | length' "$FIX/inventory.json") central, $(jq 'map(select(.fork)) | length' "$FIX/inventory.json") forks, 0 archived" ]
}

@test "inventory phase keeps the archived repositories apart" {
  cat >"$MONITOR_SCRIPTS_DIR/monitor-repos.sh" <<EOS
#!/usr/bin/env bash
echo '[{"name":"spali/old","fork":false},{"name":"spali/older","fork":true}]' >"\$MONITOR_ARCHIVED"
cat "$BATS_TEST_TMPDIR/inventory.json"
EOS
  phase config
  phase inventory
  [ "$status" -eq 0 ]
  [[ $output == *", $(jq 'map(select(.fork)) | length' "$FIX/inventory.json") forks, 2 archived" ]]
  [ "$(jq -c . "$BATS_TEST_TMPDIR/work/archived.json")" = '[{"name":"spali/old","fork":false},{"name":"spali/older","fork":true}]' ]
}

@test "lists phase gets the archived repositories" {
  cat >"$MONITOR_SCRIPTS_DIR/monitor-repos.sh" <<EOS
#!/usr/bin/env bash
echo '[{"name":"spali/old","fork":false}]' >"\$MONITOR_ARCHIVED"
cat "$BATS_TEST_TMPDIR/inventory.json"
EOS
  printf '#!/usr/bin/env bash\ncp "$ARCHIVED" "%s/archived.seen"\n' "$BATS_TEST_TMPDIR" >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  phase config
  phase inventory
  phase lists
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$BATS_TEST_TMPDIR/archived.seen")" = '[{"name":"spali/old","fork":false}]' ]
}

@test "the forks phase writes the fork kinds, the report reads them" {
  printf '#!/usr/bin/env bash\necho "{\\"repo\\":\\"o/f\\",\\"kind\\":\\"customized\\",\\"pinned\\":false,\\"own\\":1,\\"merged\\":0,\\"closed\\":0,\\"pulls\\":[],\\"upstream\\":\\"up/f\\"}" >>"$FORK_KINDS"\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-forks.sh"
  phase config
  phase inventory
  echo stale >"$BATS_TEST_TMPDIR/work/fork-kinds.jsonl"
  phase forks
  [ "$status" -eq 0 ]
  # the phase starts a new file
  [ "$(jq -c '[.repo, .kind]' "$BATS_TEST_TMPDIR/work/fork-kinds.jsonl")" = '["o/f","customized"]' ]
  phase settings
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/work/fork-kinds.jsonl")" -eq 1 ]
  phase report
  [ "$status" -eq 0 ]
  grep -qF '| [o/f](https://github.com/o/f) | [up/f](https://github.com/up/f) | ✏️ 1 own commit |' "$BATS_TEST_TMPDIR/work/report.md"
}

@test "the lists phase writes the lists, the report shows them for the forks" {
  printf '#!/usr/bin/env bash\necho "{\\"repo\\":\\"o/f\\",\\"kind\\":\\"unchanged\\",\\"pinned\\":false,\\"own\\":0,\\"merged\\":0,\\"closed\\":0,\\"pulls\\":[],\\"upstream\\":\\"up/f\\"}" >>"$FORK_KINDS"\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-forks.sh"
  printf '#!/usr/bin/env bash\necho "[{\\"name\\":\\"Home\\",\\"items\\":[{\\"repo\\":\\"o/f\\",\\"archived\\":false}]}]" >"$LISTS"\n' \
    >"$MONITOR_SCRIPTS_DIR/monitor-lists.sh"
  phase config
  phase inventory
  echo stale >"$BATS_TEST_TMPDIR/work/lists.json"
  phase forks
  [ "$status" -eq 0 ]
  # only the lists phase writes the lists
  [ "$(cat "$BATS_TEST_TMPDIR/work/lists.json")" = stale ]
  phase lists
  [ "$status" -eq 0 ]
  phase report
  [ "$status" -eq 0 ]
  grep -qF '| [o/f](https://github.com/o/f) | [up/f](https://github.com/up/f) | ⚪ unchanged | Home |' "$BATS_TEST_TMPDIR/work/report.md"
}

@test "billing phase runs the billing script with the whole inventory and the account token" {
  check_stub billing 'jq -c "[.[].name]" "$INVENTORY" >"'"$BATS_TEST_TMPDIR"'/seen"
printf "%s\n" "${BILLING_TOKEN:-}" >"'"$BATS_TEST_TMPDIR"'/token"
finding info billing - "Actions minutes 15 %"'
  phase config
  phase inventory
  BILLING_TOKEN=acct phase billing
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "billing: 0 repositories · 0 red · 1 info · 0 not checked · 0 ignored" ]
  [[ $output == *"ℹ billing: Actions minutes 15 %"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/seen")" = "$(jq -c '[.[].name]' "$FIX/inventory.json")" ]
  [ "$(cat "$BATS_TEST_TMPDIR/token")" = acct ]
}

@test "MONITOR_REPO with billing is a usage error" {
  MONITOR_REPO=spali/a phase billing
  [ "$status" -eq 2 ]
  [ "$stderr" = "error: MONITOR_REPO does not apply to billing" ]
}

@test "all phases run the billing check" {
  check_stub billing 'finding info billing - "Actions minutes 15 %"'
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 0 ]
  [[ $output == *"Actions minutes 15 %"* ]]
}

@test "inventory phase fails when the script crashes" {
  printf '#!/usr/bin/env bash\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-repos.sh"
  phase config
  phase inventory
  [ "$status" -eq 1 ]
  [[ $output == *"::error title=check-failed::monitor-repos.sh crashed"* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/work/inventory.json")" = "[]" ]
  [ "$(cat "$BATS_TEST_TMPDIR/work/archived.json")" = "[]" ]
}

@test "a check phase lists clean repos and groups repos with findings" {
  cat >"$MONITOR_CONFIG" <<'EOS'
version: 1
ignores:
  - {repo: spali/c, check: main-red, reason: known}
EOS
  check_stub health 'checked spali/a; checked spali/b; checked spali/c
finding red main-red spali/b "main is red"
finding info renovate-stale spali/b "PR #1 open"
finding skip code-scanning-alert spali/b "not enabled"
finding red main-red spali/c "also red"
finding red check-failed - "health: boom"'
  phase config
  phase inventory
  phase health
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  expected=$(cat <<'EOS'
::group::✗ (no repository): 1 red
  ✗ check-failed: health: boom
::endgroup::
✓ spali/a
::group::✗ spali/b: 1 red, 1 info, 1 not checked
  ✗ main-red: main is red
  ℹ renovate-stale: PR #1 open
  – code-scanning-alert: not enabled
::endgroup::
::group::◌ spali/c: 1 ignored
  ◌ main-red: also red (ignored: known)
::endgroup::
::error title=check-failed::health: boom
::error title=main-red::spali/b: main is red
health: 3 repositories · 2 red · 1 info · 1 not checked · 1 ignored
EOS
)
  [ "$output" = "$expected" ]
}

@test "a clean check phase exits 0" {
  check_stub release 'checked spali/a
finding info pin-behind spali/a "pinned to v1"'
  phase config
  phase inventory
  phase release
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "release: 1 repositories · 0 red · 1 info · 0 not checked · 0 ignored" ]
}

@test "a crashing check phase is red and hides the script output" {
  printf '#!/usr/bin/env bash\necho secret\necho leaked-stderr >&2\nexit 3\n' >"$MONITOR_SCRIPTS_DIR/monitor-forks.sh"
  phase config
  phase inventory
  phase forks
  [ "$status" -eq 1 ]
  [[ $output == *"::error title=check-failed::monitor-forks.sh crashed"* ]]
  [[ $output != *leaked-stderr* ]]
  [[ $stderr != *secret* ]]
}

@test "annotation data escapes percent and newlines" {
  check_stub lists 'finding red adoption spali/a "50% done
next line"'
  phase config
  phase inventory
  phase lists
  [[ $output == *"::error title=adoption::spali/a: 50%25 done%0Anext line"* ]]
}

@test "findings of earlier phases are not repeated" {
  check_stub release 'finding red orphan-tag spali/a x'
  check_stub settings 'checked spali/a'
  phase config
  phase inventory
  phase release
  phase settings
  [ "$status" -eq 0 ]
  [ "$output" = $'✓ spali/a\nsettings: 1 repositories · 0 red · 0 info · 0 not checked · 0 ignored' ]
}

@test "report phase writes the summary and does not fail for red findings" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  check_stub lists 'finding red adoption spali/a x'
  phase config
  phase inventory
  phase lists
  phase report
  [ "$status" -eq 0 ]
  grep -qF '**[1 red](#user-content-red)**' "$GITHUB_STEP_SUMMARY"
  [ "$output" = "✓ report: 1 red · 0 info · 3 clean · 0 not checked · 1 to do" ]
}

@test "report phase fails when the report script crashes" {
  printf '#!/usr/bin/env bash\nexit 2\n' >"$MONITOR_SCRIPTS_DIR/monitor-report.sh"
  phase config
  phase inventory
  phase report
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: monitor-report.sh crashed" ]
}

@test "issue phase updates the issue with the title of the report" {
  export MONITOR_ISSUE_REPO=spali/ctl GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=spali/ctl GITHUB_RUN_ID=42
  check_stub lists 'finding red adoption spali/a x'
  phase config
  phase inventory
  phase lists
  phase report
  phase issue
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$BATS_TEST_TMPDIR/issue.args")" = "Maintenance monitor: 1 red · 0 info" ]
  [ "$output" = "✓ overview issue updated in spali/ctl" ]
}

@test "issue phase without MONITOR_ISSUE_REPO does nothing" {
  phase config
  phase inventory
  phase report
  phase issue
  [ "$status" -eq 0 ]
  [ "$output" = "– no MONITOR_ISSUE_REPO, overview issue not updated" ]
  [ ! -e "$BATS_TEST_TMPDIR/issue.args" ]
}

@test "issue phase fails when the update fails" {
  export MONITOR_ISSUE_REPO=spali/ctl ISSUE_FAIL=1
  phase config
  phase inventory
  phase report
  phase issue
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: updating issue #1 failed: boom (HTTP 422)" ]
}

@test "the full run does not leave the work dir or the log lines behind" {
  check_stub health 'checked spali/a'
  run --separate-stderr "$MONITOR"
  [ "$status" -eq 0 ]
  [[ $output != *"✓ spali/a"* ]]
  [[ $output != *"::"* ]]
}
