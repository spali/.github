#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPORT="$BATS_TEST_DIRNAME/../scripts/monitor-report.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
  export FINDINGS="$FIX/findings.jsonl"
  export CONFIG="$FIX/config.json"
  export MONITOR_DOCS_URL=https://docs.example/checks.md
  unset MONITOR_CONFIG_URL INVENTORY
}

# section NAME prints the part of $output from the section heading NAME up
# to the next section heading.
section() {
  # headings may start with an anchor: ## <a name="x"></a>Title
  awk -v h="$1" '/^## / { t = $0; sub(/^## (<a name="[^"]*"><\/a>)?/, "", t); on = index(t, h) == 1 } on' <<<"$output"
}

# findings sets $FINDINGS to the lines on stdin.
findings() {
  cat >"$BATS_TEST_TMPDIR/findings.jsonl"
  export FINDINGS="$BATS_TEST_TMPDIR/findings.jsonl"
}

# config sets $CONFIG to the JSON on stdin.
config() {
  cat >"$BATS_TEST_TMPDIR/config.json"
  export CONFIG="$BATS_TEST_TMPDIR/config.json"
}

@test "exits 1 with an open red finding" {
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == "## Maintenance monitor"* ]]
  [[ $output == *"**[2 red](#user-content-red)** · [1 info](#user-content-info) · [1 not checked](#user-content-not-checked)"* ]]
  [[ $output == *"| [spali/pub](https://github.com/spali/pub) | merge commits allowed | [Settings](https://github.com/spali/pub/settings) |"* ]]
}

@test "exits 0 with only info and skip" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"spali/other","message":"m"}
{"level":"skip","check":"code-scanning-alert","repo":"spali/pub","message":"n/a"}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"**[0 red](#user-content-red)** · [1 info](#user-content-info) · [1 not checked](#user-content-not-checked)"* ]]
  [[ $output == *"> [!TIP]"* ]]
  [[ $output != *"[!CAUTION]"* ]]
  [[ "$(section "🔴 Red")" == *"Nothing to fix."* ]]
}

@test "names every repo and message, private or not" {
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"| [spali/secret-repo](https://github.com/spali/secret-repo) | CI failed: [run](https://api.github.com/repos/spali/secret-repo/actions/runs) |"* ]]
  [[ $output != *"[private]"* ]]
}

@test "writes only to stdout" {
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == "## Maintenance monitor"* ]]
  [ -z "$stderr" ]
  [ ! -e "$GITHUB_STEP_SUMMARY" ]
}

@test "ignore-unused of a repo not in any finding is listed with its repo" {
  findings </dev/null
  config <<'J'
{"ignores":[{"repo":"spali/gone","check":"adoption","reason":"hush"}]}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"**[0 red](#user-content-red)** · [1 info](#user-content-info) · [0 not checked](#user-content-not-checked)"* ]]
  [[ $output == *"### \`ignore-unused\` [ℹ️](https://docs.example/checks.md#ignore-unused)"* ]]
  [[ $output == *"| [spali/gone](https://github.com/spali/gone) | unused ignore: hush |"* ]]
}

@test "a non-string message is rendered, not fatal" {
  findings <<'J'
{"level":"red","check":"check-failed","repo":null,"message":{"url":"x"}}
J
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *'| - | {"url":"x"} |'* ]]
  [ -z "$stderr" ]
}

@test "findings above 200 KB are rendered completely" {
  jq -cn 'range(0; 30) | {level: "red", check: "main-red", repo: "spali/r\(.)", message: ("x" * 10000)}' >"$BATS_TEST_TMPDIR/big.jsonl"
  [ "$(stat -c %s "$BATS_TEST_TMPDIR/big.jsonl")" -gt 200000 ]
  export FINDINGS="$BATS_TEST_TMPDIR/big.jsonl"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"**[30 red](#user-content-red)** · [0 info](#user-content-info) · [0 not checked](#user-content-not-checked)"* ]]
  [[ $output == *"| [spali/r29](https://github.com/spali/r29) |"* ]]
  [ -z "$stderr" ]
}

@test "empty findings file exits 0" {
  findings </dev/null
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"**[0 red](#user-content-red)** · [0 info](#user-content-info) · [0 not checked](#user-content-not-checked)"* ]]
}

@test "ignore removes a red finding and exits 0" {
  findings <<'J'
{"level":"red","check":"settings-merge","repo":"spali/pub","message":"merge commits allowed"}
J
  config <<'J'
{"ignores":[{"repo":"spali/pub","check":"settings-merge","reason":"intended"}]}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"**[0 red](#user-content-red)** · [0 info](#user-content-info) · [0 not checked](#user-content-not-checked)"* ]]
  [[ $output != *"merge commits"* ]]
}

@test "unused ignore becomes info" {
  config <<'J'
{"ignores":[{"repo":"spali/pub","check":"adoption","reason":"typo?"}]}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *"**[2 red](#user-content-red)** · [2 info](#user-content-info) · [1 not checked](#user-content-not-checked)"* ]]
  [[ $output == *"| [spali/pub](https://github.com/spali/pub) | unused ignore: typo? |"* ]]
}

@test "sections are sorted and pipes escaped" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"spali/pub","message":"a | b"}
{"level":"red","check":"settings-pvr","repo":"spali/pub","message":"x"}
{"level":"red","check":"main-red","repo":"spali/pub","message":"y"}
{"level":"red","check":"main-red","repo":"spali/other","message":"z"}
J
  run "$REPORT"
  [[ $output == *'| a \| b |'* ]]
  [[ $output == *'## <a name="red"></a>🔴 Red'$'\n'*'## <a name="info"></a>🔵 Info'$'\n'*'## <a name="not-checked"></a>⚪ Not checked'$'\n'* ]]
  red=$(section "🔴 Red")
  # main-red (other, pub) before settings-pvr
  [[ $red == *"main-red"*"spali/other"*"spali/pub"*"settings-pvr"* ]]
}

@test "the summary is a caution alert while red findings are open" {
  run "$REPORT"
  [[ $output == *$'> [!CAUTION]\n> **[2 red](#user-content-red)** · [1 info](#user-content-info) · [1 not checked](#user-content-not-checked)'* ]]
}

@test "each check title links its explanation" {
  run "$REPORT"
  [[ $output == *"### \`main-red\` [ℹ️](https://docs.example/checks.md#main-red)"* ]]
}

@test "the docs link defaults to the main branch of spali/.github" {
  unset MONITOR_DOCS_URL
  run "$REPORT"
  [[ $output == *"[ℹ️](https://github.com/spali/.github/blob/main/docs/monitor-checks.md#main-red)"* ]]
}

@test "not checked findings are listed in a collapsed section, one line per reason" {
  run "$REPORT"
  nc=$(section "⚪ Not checked")
  [[ $nc == *"Checks that did not run in these repositories because they do not apply or the feature is not available there; the repositories were checked otherwise. Each line gives the reason."*"<details>"*"### \`code-scanning-alert\` [ℹ️](https://docs.example/checks.md#code-scanning-alert)"*"- no analysis found: [spali/pub](https://github.com/spali/pub)"*"</details>"* ]]
  [[ $nc != *"| Repository |"* ]]
  [[ $output != *"Skipped"* && $output != *"skipped"* ]]
}

@test "not checked: equal reasons are merged, prefixes dropped, repos sorted" {
  findings <<'J'
{"level":"skip","check":"code-scanning-alert","repo":"o/b","message":"code-scanning-alert: gh: Code scanning is not enabled for this repository. (HTTP 403)"}
{"level":"skip","check":"code-scanning-alert","repo":"o/a","message":"code-scanning-alert: gh: Code scanning is not enabled for this repository. (HTTP 403)"}
{"level":"skip","check":"code-scanning-alert","repo":"o/c","message":"code-scanning-alert: gh: no analysis found (HTTP 404)"}
{"level":"skip","check":"settings-pvr","repo":"o/a","message":"private repository"}
J
  run "$REPORT"
  [ "$status" -eq 0 ]
  [[ $output == *"[4 not checked](#user-content-not-checked)"* ]]
  nc=$(section "⚪ Not checked")
  [[ $nc == *"### \`code-scanning-alert\`"*"### \`settings-pvr\`"* ]]
  [ "$(grep -c '^- ' <<<"$nc")" -eq 3 ]
  [[ $nc == *$'\n- Code scanning is not enabled for this repository. (HTTP 403): [o/a](https://github.com/o/a), [o/b](https://github.com/o/b)\n'* ]]
  [[ $nc == *$'\n- no analysis found (HTTP 404): [o/c](https://github.com/o/c)\n'* ]]
  [[ $nc == *$'\n- private repository: [o/a](https://github.com/o/a)\n'* ]]
  [[ $nc != *"Fix at"* && $nc != *"[Code scanning]("* ]]
  [[ $nc == *"<summary>4 entries, click to show</summary>"* ]]
}

@test "not checked: one entry is singular" {
  run "$REPORT"
  [[ "$(section "⚪ Not checked")" == *"<summary>1 entry, click to show</summary>"* ]]
}

@test "not checked: empty reason and missing repo" {
  findings <<'J'
{"level":"skip","check":"sync-failed","repo":null,"message":"no control repository"}
{"level":"skip","check":"settings-pvr","repo":"o/a","message":""}
{"level":"skip","check":"ruleset-tags","repo":"o/b","message":"ruleset-tags: gh: "}
J
  run "$REPORT"
  nc=$(section "⚪ Not checked")
  [[ $nc == *$'\n- no control repository\n'* ]]
  [[ $nc == *$'\n- (no details): [o/a](https://github.com/o/a)\n'* ]]
  [[ $nc == *$'\n- (no details): [o/b](https://github.com/o/b)\n'* ]]
}

@test "not checked: markdown and html in reasons are escaped" {
  findings <<'J'
{"level":"skip","check":"settings-pvr","repo":"o/a","message":"a\\b `c` *d* _e_ [f](g) <h>"}
J
  run "$REPORT"
  [[ "$(section "⚪ Not checked")" == *'- a\\b \`c\` \*d\* \_e\_ \[f\](g) \<h\>: [o/a](https://github.com/o/a)'* ]]
}

@test "without an inventory there is no clean section" {
  run "$REPORT"
  [[ $output != *"Clean"* && $output != *"clean"* ]]
}

@test "an empty inventory counts as none" {
  echo '[]' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  run "$REPORT"
  [[ $output != *"Clean"* && $output != *"clean"* ]]
}

@test "a broken inventory counts as none" {
  printf 'not json' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *"Clean"* ]]
  [ -z "$stderr" ]
}

@test "without not checked findings the section says every check ran" {
  findings </dev/null
  run "$REPORT"
  [[ "$(section "⚪ Not checked")" == $'## <a name="not-checked"></a>⚪ Not checked\n\nEvery check ran.' ]]
}

@test "with an inventory the summary links all four sections in order" {
  export INVENTORY="$FIX/inventory.json"
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *$'> [!CAUTION]\n> **[2 red](#user-content-red)** · [1 info](#user-content-info) · [0 clean](#user-content-clean) · [1 not checked](#user-content-not-checked)\n'* ]]
  [[ $output == *$'\n## <a name="red"></a>🔴 Red\n'*$'\n## <a name="info"></a>🔵 Info\n'*$'\n## <a name="clean"></a>✅ Clean\n'*$'\n## <a name="not-checked"></a>⚪ Not checked\n'* ]]
  [[ "$(section "✅ Clean")" == *"No repository without findings."* ]]
}

@test "clean lists inventory repos without red or info, sorted; skip and ignored count as clean" {
  jq -n '[{name:"o/e"},{name:"o/d"},{name:"o/c"},{name:"o/b"},{name:"o/a"},{name:"o/f"}]' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  findings <<'J'
{"level":"red","check":"main-red","repo":"o/a","message":"x"}
{"level":"info","check":"list-none","repo":"o/b","message":"x"}
{"level":"skip","check":"settings-pvr","repo":"o/c","message":"private repository"}
{"level":"red","check":"settings-merge","repo":"o/d","message":"x"}
{"level":"info","check":"adoption","repo":null,"message":"1 own repositories without the shared release flow: o/f"}
J
  config <<'J'
{"ignores":[{"repo":"o/d","check":"settings-merge","reason":"ok"},{"repo":"o/e","check":"adoption","reason":"stale"}]}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  # o/e only has an unused ignore, o/f is only named in a finding without repo
  [[ $output == *"**[1 red](#user-content-red)** · [3 info](#user-content-info) · [4 clean](#user-content-clean) · [1 not checked](#user-content-not-checked)"* ]]
  clean=$(section "✅ Clean")
  [[ $clean == *"<details>"*"4 repositories"*$'\n[o/c](https://github.com/o/c), [o/d](https://github.com/o/d), [o/e](https://github.com/o/e), [o/f](https://github.com/o/f)\n'*"</details>"* ]]
}

@test "the section anchors stay the same whatever the counts" {
  export INVENTORY="$FIX/inventory.json"
  run "$REPORT"
  for h in 'red">🔴 Red' 'info">🔵 Info' 'clean">✅ Clean' 'not-checked">⚪ Not checked'; do
    grep -qxF "## <a name=\"${h%%\">*}\"></a>${h#*\">}" <<<"$output"
  done
}

@test "each check links where to fix it" {
  findings <<'J'
{"level":"red","check":"devbuild-closed-pr","repo":"o/r","message":"m"}
{"level":"red","check":"orphan-tag","repo":"o/r","message":"m"}
{"level":"red","check":"pin-behind","repo":"o/r","message":"m"}
{"level":"red","check":"settings-alerts","repo":"o/r","message":"m"}
{"level":"red","check":"settings-actions","repo":"o/r","message":"m"}
{"level":"red","check":"ruleset-main","repo":"o/r","message":"m"}
{"level":"red","check":"workflow-disabled","repo":"o/r","message":"m"}
{"level":"red","check":"dependabot-alert","repo":"o/r","message":"m"}
{"level":"red","check":"code-scanning-alert","repo":"o/r","message":"m"}
{"level":"red","check":"renovate-stale","repo":"o/r","message":"m"}
{"level":"info","check":"list-none","repo":"o/r","message":"m"}
{"level":"info","check":"fork-behind","repo":"o/r","message":"m"}
J
  run "$REPORT"
  [[ $output == *"[Releases](https://github.com/o/r/releases)"* ]]
  [[ $output == *"[Tags](https://github.com/o/r/tags)"* ]]
  [[ $output == *"[Renovate PRs](https://github.com/o/r/pulls?q=is%3Apr+is%3Aopen+author%3Aapp%2Frenovate)"* ]]
  [[ $output == *"[Security settings](https://github.com/o/r/settings/security_analysis)"* ]]
  [[ $output == *"[Actions settings](https://github.com/o/r/settings/actions)"* ]]
  [[ $output == *"[Rulesets](https://github.com/o/r/settings/rules)"* ]]
  [[ $output == *"[Actions](https://github.com/o/r/actions)"* ]]
  [[ $output == *"[Dependabot](https://github.com/o/r/security/dependabot)"* ]]
  [[ $output == *"[Code scanning](https://github.com/o/r/security/code-scanning)"* ]]
  [[ $output == *"[Lists](https://github.com/o?tab=stars)"* ]]
  [[ $output == *"| [o/r](https://github.com/o/r) | m | [Fork](https://github.com/o/r) |"* ]]
}

@test "issue numbers link into the repository of the finding" {
  findings <<'J'
{"level":"red","check":"renovate-stale","repo":"o/r","message":"#12 chore: bump x (9 days)"}
{"level":"red","check":"devbuild-closed-pr","repo":"o/r","message":"v1.0.0-pr.7: PR #7 is not open"}
J
  run "$REPORT"
  [[ $output == *"| [#12](https://github.com/o/r/issues/12) chore: bump x (9 days) |"* ]]
  [[ $output == *"PR [#7](https://github.com/o/r/issues/7) is not open"* ]]
}

@test "repositories named in an adoption message are links" {
  findings <<'J'
{"level":"info","check":"adoption","repo":null,"message":"2 own repositories without the shared release flow: o/a, o/b.c"}
J
  run "$REPORT"
  [[ $output == *"| - | 2 own repositories without the shared release flow: [o/a](https://github.com/o/a), [o/b.c](https://github.com/o/b.c) |"* ]]
}

@test "control file findings link the control file when its URL is known" {
  findings <<'J'
{"level":"red","check":"config-invalid","repo":null,"message":"repos.yml: bad"}
J
  config <<'J'
{"ignores":[{"repo":"o/r","check":"adoption","reason":"x"}]}
J
  export MONITOR_CONFIG_URL=https://github.com/o/ctl/blob/abc/repos.yml
  run "$REPORT"
  [[ $output == *"| - | repos.yml: bad | [Control file](https://github.com/o/ctl/blob/abc/repos.yml) |"* ]]
  [[ $output == *"| unused ignore: x | [Control file](https://github.com/o/ctl/blob/abc/repos.yml) |"* ]]
}

@test "sync-failed with a repo from the lists job renders under that repo, once, in both job modes" {
  local lists=$BATS_TEST_TMPDIR/lists.jsonl one=$BATS_TEST_TMPDIR/one.jsonl
  printf '%s\n' \
    '{"level":"red","check":"sync-failed","repo":"spali/knx.js","message":"last sync of this repository failed: https://github.com/ctl/x/actions/runs/9/job/7"}' \
    '{"level":"red","check":"sync-failed","repo":null,"message":"sync run failed before the repositories: https://github.com/ctl/x/actions/runs/9"}' >"$lists"
  printf '%s\n' '{"level":"red","check":"managed-behind","repo":"spali/knx.js","message":"m"}' >"$one"
  # per-group: one managed job for all repos; per-repo: one job per repo (and
  # an empty file for another); the Lists job runs once in both.
  for files in "$lists $one" "$lists $one $BATS_TEST_TMPDIR/empty.jsonl"; do
    : >"$BATS_TEST_TMPDIR/empty.jsonl"
    # shellcheck disable=SC2086 # word splitting on purpose
    findings < <(cat $files)
    run "$REPORT"
    [ "$status" -eq 1 ]
    [[ $output == *"**[3 red](#user-content-red)**"* ]]
    [ "$(grep -c '^| \[spali/knx.js\](https://github.com/spali/knx.js) | last sync of this repository failed: \[job\](https://github.com/ctl/x/actions/runs/9/job/7) |  |' <<<"$output")" -eq 1 ]
    [ "$(grep -c '^| - | sync run failed before the repositories: \[run\](https://github.com/ctl/x/actions/runs/9) |  |' <<<"$output")" -eq 1 ]
  done
}

@test "sync-failed links the sync runs of the control repository when its URL is known" {
  findings <<'J'
{"level":"red","check":"sync-failed","repo":"o/r","message":"last sync of this repository failed: https://github.com/o/ctl/actions/runs/9/job/7"}
{"level":"red","check":"sync-failed","repo":null,"message":"sync run failed before the repositories: https://github.com/o/ctl/actions/runs/9"}
J
  export MONITOR_CONFIG_URL=https://github.com/o/ctl/blob/abc/repos.yml
  run "$REPORT"
  [[ $output == *"| [o/r](https://github.com/o/r) | last sync of this repository failed: [job](https://github.com/o/ctl/actions/runs/9/job/7) | [Sync runs](https://github.com/o/ctl/actions/workflows/sync.yml) |"* ]]
  [[ $output == *"| - | sync run failed before the repositories: [run](https://github.com/o/ctl/actions/runs/9) | [Sync runs](https://github.com/o/ctl/actions/workflows/sync.yml) |"* ]]
}
