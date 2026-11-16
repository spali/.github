#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPORT="$BATS_TEST_DIRNAME/../scripts/monitor-report.sh"
  FIX="$BATS_TEST_DIRNAME/fixtures/monitor"
  export FINDINGS="$FIX/findings.jsonl"
  export CONFIG="$FIX/config.json"
  export MONITOR_DOCS_URL=https://docs.example/checks.md
  unset MONITOR_CONFIG_URL INVENTORY GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID
  export MONITOR_NOW
  MONITOR_NOW=$(date -u -d 2026-11-16T19:45:30Z +%s)
}

# section NAME prints the part of $output from the section heading NAME up
# to the anchor (or the details marker) of the next section (or the next
# heading).
section() {
  awk -v h="$1" '/^(<a name="[a-z-]+"><\/a>|<!-- maintenance-monitor:details -->)$/ { on = 0 } /^## / { on = index(substr($0, 4), h) == 1 } on' <<<"$output"
}

# anchored NAME TITLE: the section anchor NAME stands right above the heading
# TITLE: a line <a name="NAME"></a>, a line <br>, an empty line, "## TITLE".
anchored() {
  [[ $output == *$'\n<a name="'"$1"$'"></a>\n<br>\n\n## '"$2"$'\n'* ]]
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
  [[ $output == *$'\n## 🔴 Red\n'*$'\n## 🔵 Info\n'*$'\n## ⚪ Not checked\n'* ]]
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
  [[ $output != *"✅ Clean"* && $output != *"clean]("* && $output != *"user-content-clean"* ]]
}

@test "an empty inventory counts as none" {
  echo '[]' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  run "$REPORT"
  [[ $output != *"✅ Clean"* && $output != *"clean]("* && $output != *"user-content-clean"* ]]
}

@test "a broken inventory counts as none" {
  printf 'not json' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *"✅ Clean"* && $output != *"user-content-clean"* ]]
  [ -z "$stderr" ]
}

@test "without not checked findings the section says every check ran" {
  findings </dev/null
  run "$REPORT"
  [[ "$(section "⚪ Not checked")" == $'## ⚪ Not checked\n\nEvery check ran.' ]]
}

@test "with an inventory the summary links the sections, all in order" {
  export INVENTORY="$FIX/inventory.json"
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output == *$'> [!CAUTION]\n> **[2 red](#user-content-red)** · [1 info](#user-content-info) · [0 clean](#user-content-clean) · [1 not checked](#user-content-not-checked) · [3 to do](#user-content-todo) · updated 2026-11-16 19:45 UTC\n'* ]]
  [[ $output == *$'\n## 📝 TODO\n'*$'\n## 📋 Overview\n'*$'\n## 🔴 Red\n'*$'\n## 🔵 Info\n'*$'\n## ✅ Clean\n'*$'\n## ⚪ Not checked\n'* ]]
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
{"level":"info","check":"adoption","repo":"o/f","message":"no central release flow"}
J
  config <<'J'
{"ignores":[{"repo":"o/d","check":"settings-merge","reason":"ok"},{"repo":"o/e","check":"adoption","reason":"stale"}]}
J
  run "$REPORT"
  [ "$status" -eq 1 ]
  # o/e only has an unused ignore, o/f has an info finding, so it is not clean
  [[ $output == *"**[1 red](#user-content-red)** · [3 info](#user-content-info) · [3 clean](#user-content-clean) · [1 not checked](#user-content-not-checked)"* ]]
  clean=$(section "✅ Clean")
  [[ $clean == *"<details>"*"3 repositories"*$'\n[o/c](https://github.com/o/c), [o/d](https://github.com/o/d), [o/e](https://github.com/o/e)\n'*"</details>"* ]]
}

@test "the section anchors stay the same whatever the counts" {
  export INVENTORY="$FIX/inventory.json"
  run "$REPORT"
  anchored todo "📝 TODO"
  anchored overview "📋 Overview"
  anchored red "🔴 Red"
  anchored info "🔵 Info"
  anchored clean "✅ Clean"
  anchored not-checked "⚪ Not checked"
  # every section anchor stands on a line of its own, never in a heading
  [ "$(grep -c '^<a name="[a-z-]*"></a>$' <<<"$output")" -eq 6 ]
  run ! grep -q '^## .*<a name' <<<"$output"
}

@test "the details marker stands once, right above the red anchor" {
  export INVENTORY="$FIX/inventory.json"
  run "$REPORT"
  [ "$(grep -c '^<!-- maintenance-monitor:details -->$' <<<"$output")" -eq 1 ]
  [[ $output == *$'\n\n<!-- maintenance-monitor:details -->\n<a name="red"></a>\n<br>\n\n## 🔴 Red\n'* ]]
  # without an inventory too
  unset INVENTORY
  run "$REPORT"
  [[ $output == *$'\n<!-- maintenance-monitor:details -->\n<a name="red"></a>\n'* ]]
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

@test "adoption findings are rendered like any other: message not linkified" {
  findings <<'J'
{"level":"info","check":"adoption","repo":"o/a","message":"no central release flow in o/x"}
J
  run "$REPORT"
  [[ $output == *"| no central release flow in o/x |"* ]]
  [[ $output != *"[o/x]"* ]]
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
    red=$(section "🔴 Red")
    [ "$(grep -c '^| <a name="f-sync-failed-spali-knx-js"></a>\[spali/knx.js\](https://github.com/spali/knx.js) | last sync of this repository failed: \[job\](https://github.com/ctl/x/actions/runs/9/job/7) |  |' <<<"$red")" -eq 1 ]
    [ "$(grep -c '^| - | sync run failed before the repositories: \[run\](https://github.com/ctl/x/actions/runs/9) |  |' <<<"$red")" -eq 1 ]
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

# --- layout F: TODO, overview matrix, row anchors, summary line ----------

# layout sets a realistic inventory, control file and findings: red and info
# of several checks, a repo-less finding, a not checked finding, a managed
# repository outside the inventory (other case in the control file).
layout() {
  jq -n '[
    {name: "o/central", central: true, fork: false, pins: []},
    {name: "o/plain", central: false, fork: false, pins: []},
    {name: "o/fork", central: false, fork: true, parent: {name: "up/fork"}, pins: []},
    {name: "o/mirror", central: false, fork: false, pins: []},
    {name: "o/clean", central: false, fork: false, pins: []}]' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  config <<'J'
{"mirrors":[{"target":"o/mirror","source":"https://src.example/m.git","interval_hours":24}],
 "managed":[{"repo":"o/Man","upstream":"https://src.example/p.git"}],"ignores":[]}
J
  findings <<'J'
{"level":"red","check":"main-red","repo":"o/plain","message":"CI failed"}
{"level":"info","check":"adoption","repo":"o/plain","message":"no central release flow"}
{"level":"info","check":"fork-behind","repo":"o/fork","message":"3 commits behind upstream"}
{"level":"info","check":"branch-undeclared","repo":"o/fork","message":"b: 2 own commits"}
{"level":"info","check":"branch-undeclared","repo":"o/fork","message":"a: 1 own commits"}
{"level":"red","check":"check-failed","repo":"o/mirror","message":"mirror-behind: target not visible"}
{"level":"info","check":"list-none","repo":"o/central","message":"in no list"}
{"level":"skip","check":"ruleset-tags","repo":"o/central","message":"rulesets not available"}
{"level":"red","check":"config-invalid","repo":null,"message":"repos.yml: bad"}
{"level":"red","check":"managed-behind","repo":"o/man","message":"2 tags differ"}
J
}

# todo_titles prints the summary lines of the TODO entries, in order.
todo_titles() { section "📝 TODO" | grep '^<details'; }

@test "summary line counts the TODO entries, with time and run link, and there is no footer" {
  layout
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/ctl GITHUB_RUN_ID=42
  run "$REPORT"
  [ "$status" -eq 1 ]
  grep -qxF '> **[4 red](#user-content-red)** · [5 info](#user-content-info) · [1 clean](#user-content-clean) · [1 not checked](#user-content-not-checked) · [8 to do](#user-content-todo) · updated 2026-11-16 19:45 UTC · [run](https://github.com/o/ctl/actions/runs/42)' <<<"$output"
  [[ ${lines[-1]} != *"Updated"* && ${lines[-1]} != *"updated"* ]]
  [ "$(grep -c 'updated 2026' <<<"$output")" -eq 1 ]
}

@test "summary line has no run link when a run variable is missing" {
  export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/ctl
  run "$REPORT"
  [[ $output == *$'[1 not checked](#user-content-not-checked) · [3 to do](#user-content-todo) · updated 2026-11-16 19:45 UTC\n'* ]]
  [[ $output != *"· [run]("* ]]
}

@test "TODO: one entry per check and category, Fix now open first, then Decide, then Clean up" {
  layout
  run "$REPORT"
  run todo_titles
  [ "${#lines[@]}" -eq 8 ]
  [ "${lines[0]}" = '<details open><summary>🔴 <b>Fix now</b> · Fix checks that could not run · 1 repository · <code>check-failed</code></summary>' ]
  [[ ${lines[1]} == '<details open><summary>🔴 <b>Fix now</b> · '*' · 1 entry · <code>config-invalid</code></summary>' ]]
  [[ ${lines[2]} == '<details open><summary>🔴 <b>Fix now</b> · '*' · 1 repository · <code>main-red</code></summary>' ]]
  [[ ${lines[3]} == '<details open><summary>🔴 <b>Fix now</b> · '*' · <code>managed-behind</code></summary>' ]]
  [[ ${lines[4]} == '<details><summary>🤔 <b>Decide</b> · '*' · 1 repository · <code>adoption</code></summary>' ]]
  [[ ${lines[5]} == '<details><summary>🤔 <b>Decide</b> · '*' · 2 entries · <code>branch-undeclared</code></summary>' ]]
  [[ ${lines[6]} == '<details><summary>🧹 <b>Clean up</b> · '*' · <code>fork-behind</code></summary>' ]]
  [[ ${lines[7]} == '<details><summary>🧹 <b>Clean up</b> · '*' · <code>list-none</code></summary>' ]]
}

@test "TODO: an entry explains the check, links its docs and lists the rows like the details" {
  layout
  run "$REPORT"
  todo=$(section "📝 TODO")
  entry=$(awk '/<code>main-red<\/code>/ { on = 1 } on; on && /^<\/details>$/ { exit }' <<<"$todo")
  [[ $entry == *$'</summary>\n\n> '*$' [ℹ️](https://docs.example/checks.md#main-red)\n\n| Repository | Details | Fix at |\n| --- | --- | --- |\n| [o/plain](https://github.com/o/plain) | CI failed | [Actions](https://github.com/o/plain/actions) |\n\n</details>' ]]
  # repo-less rows show "-", TODO rows carry no anchors
  [[ $todo == *'| - | repos.yml: bad |'* ]]
  [[ $todo != *'<a name="f-'* ]]
}

@test "TODO: a check with red and info findings has a Fix now and a Decide entry" {
  findings <<'J'
{"level":"red","check":"branch-undeclared","repo":"o/a","message":"x: 3 own commits"}
{"level":"info","check":"branch-undeclared","repo":"o/b","message":"y: differs"}
J
  run "$REPORT"
  run todo_titles
  [ "${#lines[@]}" -eq 2 ]
  [[ ${lines[0]} == '<details open><summary>🔴 <b>Fix now</b> · '*'<code>branch-undeclared</code></summary>' ]]
  [[ ${lines[1]} == '<details><summary>🤔 <b>Decide</b> · '*'<code>branch-undeclared</code></summary>' ]]
}

@test "TODO: nothing to do without red or info findings" {
  findings <<'J'
{"level":"skip","check":"settings-pvr","repo":"o/a","message":"private repository"}
J
  run "$REPORT"
  [[ "$(section "📝 TODO")" == $'## 📝 TODO\n\nNothing to do.' ]]
  [[ $output == *"[0 to do](#user-content-todo)"* ]]
}

@test "TODO: pipes in the explanation-free rows stay escaped" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"o/a","message":"a | b"}
J
  run "$REPORT"
  [[ "$(section "📝 TODO")" == *'| [o/a](https://github.com/o/a) | a \| b |'* ]]
}

@test "every check in MONITOR_CHECKS has a TODO entry: category, title and sentence" {
  # shellcheck source=../scripts/monitor-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  for c in "${MONITOR_CHECKS[@]}"; do
    jq -e --arg c "$c" '.[$c] | (.category == "decide" or .category == "cleanup")
      and (.title | type == "string" and length > 0)
      and (.text | type == "string" and length > 0 and endswith("."))
      and (.areas | type == "array" and all(.[]; IN("release", "settings", "health", "forks", "mirrors", "managed", "lists")))' \
      <<<"$MONITOR_TODO" >/dev/null || { echo "no complete TODO entry: $c"; return 1; }
  done
  # and no entry for an unknown check
  extra=$(jq -r 'keys[]' <<<"$MONITOR_TODO" | while read -r c; do [[ " ${MONITOR_CHECKS[*]} " == *" $c "* ]] || echo "$c"; done)
  [ -z "$extra" ]
}

@test "TODO: the categories follow the agreed mapping" {
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  run jq -r 'to_entries | map(select(.value.category == "decide") | .key) | sort | join(" ")' <<<"$MONITOR_TODO"
  [ "$output" = "adoption branch-undeclared contribution-stale fork-delete-candidate list-contradiction rebase-pending unmanaged" ]
}

@test "TODO: a check without an entry is Clean up, titled by its id, without sentence" {
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  findings <<'J'
{"level":"info","check":"brand-new","repo":"o/a","message":"m"}
J
  run "$REPORT"
  [[ "$(section "📝 TODO")" == *$'<details><summary>🧹 <b>Clean up</b> · brand-new · 1 repository · <code>brand-new</code></summary>\n\n> [ℹ️](https://docs.example/checks.md#brand-new)\n'* ]]
}

@test "overview: repos with findings, red first then by name, one icon per finding" {
  layout
  run "$REPORT"
  ov=$(section "📋 Overview")
  run grep '^| ' <<<"$ov"
  [ "${lines[0]}" = '| Repository | Release | Settings | Health | Fork / Mirror | Sync | Lists |' ]
  [ "${lines[1]}" = '| :-- | :-: | :-: | :-: | :-: | :-: | :-: |' ]
  [ "${lines[2]}" = '| [o/man](https://github.com/o/man) | – | – | – | – | [🔴](#user-content-f-managed-behind-o-man) | – |' ]
  [ "${lines[3]}" = '| [o/mirror](https://github.com/o/mirror) | – | – | – | [🔴](#user-content-f-check-failed-o-mirror) | – | ✅ |' ]
  # adoption sits in Release although release does not apply to o/plain
  [ "${lines[4]}" = '| [o/plain](https://github.com/o/plain) | [🔵](#user-content-f-adoption-o-plain) | – | [🔴](#user-content-f-main-red-o-plain) | – | – | ✅ |' ]
  [ "${lines[5]}" = '| [o/central](https://github.com/o/central) | ✅ | ⚪ | ✅ | – | – | [🔵](#user-content-f-list-none-o-central) |' ]
  [ "${lines[6]}" = '| [o/fork](https://github.com/o/fork) | – | – | – | [🔵](#user-content-f-branch-undeclared-o-fork)[🔵](#user-content-f-branch-undeclared-o-fork-2)[🔵](#user-content-f-fork-behind-o-fork) | – | ✅ |' ]
  [ "${#lines[@]}" -eq 7 ]
  # the clean repository and the repo-less finding are not in the matrix
  [[ $ov != *"o/clean"* && $ov != *"config-invalid"* ]]
  [[ $ov == *"🔴 fix · 🔵 note · ✅ ok · ⚪ not checked · – does not apply"* ]]
}

@test "overview: a finding shows in the column of its check even where that area does not apply" {
  layout
  findings <<'J'
{"level":"info","check":"adoption","repo":"o/plain","message":"no central release flow"}
{"level":"info","check":"fork-behind","repo":"o/plain","message":"1 commit behind upstream"}
J
  run "$REPORT"
  [[ "$(section "📋 Overview")" == *'| [o/plain](https://github.com/o/plain) | [🔵](#user-content-f-adoption-o-plain) | – | ✅ | [🔵](#user-content-f-fork-behind-o-plain) | – | ✅ |'* ]]
}

@test "overview: 🔴 before 🔵 in one cell" {
  layout
  findings <<'J'
{"level":"info","check":"dependabot-alert","repo":"o/plain","message":"1 low"}
{"level":"red","check":"main-red","repo":"o/plain","message":"x"}
J
  run "$REPORT"
  [[ "$(section "📋 Overview")" == *'| [o/plain](https://github.com/o/plain) | – | – | [🔴](#user-content-f-main-red-o-plain)[🔵](#user-content-f-dependabot-alert-o-plain) | – | – | ✅ |'* ]]
}

@test "every matrix link resolves to exactly one row anchor, and row anchors are unique" {
  layout
  f=$(cat "$FINDINGS"; echo '{"level":"red","check":"branch-undeclared","repo":"o/fork","message":"c: 9 own commits"}')
  findings <<<"$f"
  run "$REPORT"
  links=$(section "📋 Overview" | grep -o '(#user-content-f-[^)]*)' | sed 's/^(#user-content-//; s/)$//')
  [ "$(wc -l <<<"$links")" -eq 9 ]
  for l in $links; do
    [ "$(grep -cF "<a name=\"$l\"></a>" <<<"$output")" -eq 1 ] || { echo "not one anchor: $l"; return 1; }
  done
  [ -z "$(grep -o '<a name="f-[^"]*"' <<<"$output" | sort | uniq -d)" ]
  # the red branch-undeclared row comes first, the info rows continue its numbering
  [[ "$(section "🔴 Red")" == *'| <a name="f-branch-undeclared-o-fork"></a>[o/fork](https://github.com/o/fork) | c: 9 own commits |'* ]]
  [[ "$(section "🔵 Info")" == *'| <a name="f-branch-undeclared-o-fork-2"></a>[o/fork](https://github.com/o/fork) | b: 2 own commits |'* ]]
}

@test "row anchor slug: repository lowercased, other characters become -" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"O/My.Repo_x","message":"m"}
{"level":"red","check":"config-invalid","repo":null,"message":"bad"}
J
  run "$REPORT"
  [[ $output == *'| <a name="f-list-none-o-my-repo-x"></a>[O/My.Repo_x](https://github.com/O/My.Repo_x) | m |'* ]]
  # a repo-less row has no anchor
  [[ $output == *$'\n| - | bad |'* ]]
}

@test "info ends with a link back to the overview" {
  layout
  run "$REPORT"
  [[ "$(section "🔵 Info")" == *$'\n[↑ overview](#user-content-overview)' ]]
}

@test "ignored findings appear neither in TODO nor in the overview" {
  layout
  c=$(jq -c '.ignores = [{repo: "o/central", check: "list-none", reason: "ok"}, {repo: "o/plain", check: "main-red", reason: "known"}]' "$CONFIG")
  config <<<"$c"
  run "$REPORT"
  [[ "$(section "📝 TODO")" != *"list-none"* && "$(section "📝 TODO")" != *"main-red"* ]]
  ov=$(section "📋 Overview")
  [[ $ov != *"o/central"* && $ov != *"main-red"* ]]
  [[ $ov == *'| [o/plain](https://github.com/o/plain) | [🔵](#user-content-f-adoption-o-plain) | – | ✅ | – | – | ✅ |'* ]]
}

@test "an old adoption ignore without repository becomes a visible ignore-unused" {
  layout
  c=$(jq -c '.ignores = [{repo: null, check: "adoption", reason: "later"}]' "$CONFIG")
  config <<<"$c"
  run --separate-stderr "$REPORT"
  [ "$status" -eq 1 ]
  [ -z "$stderr" ]
  [[ "$(section "📝 TODO")" == *'<details><summary>🧹 <b>Clean up</b> · '*' · 1 entry · <code>ignore-unused</code></summary>'* ]]
  [[ "$(section "🔵 Info")" == *'| - | unused ignore: later |'* ]]
  [[ "$(section "📋 Overview")" != *"ignore-unused"* ]]
  # the adoption finding itself stays
  [[ "$(section "📋 Overview")" == *'[🔵](#user-content-f-adoption-o-plain)'* ]]
}

@test "without an inventory the overview is left out, TODO stays" {
  layout
  unset INVENTORY
  run "$REPORT"
  [ "$status" -eq 1 ]
  [[ $output != *"📋 Overview"* && $output != *"user-content-overview"* ]]
  [ "$(todo_titles | wc -l)" -eq 8 ]
}

@test "per-repo job mode renders the same overview" {
  layout
  run "$REPORT"
  want=$(section "📋 Overview")
  c=$(jq -c '.monitor = {jobs: "per-repo"}' "$CONFIG")
  config <<<"$c"
  run "$REPORT"
  [ "$(section "📋 Overview")" = "$want" ]
}

@test "the overview says so when no repository has findings" {
  layout
  findings </dev/null
  run "$REPORT"
  [[ "$(section "📋 Overview")" == *"No repository with findings."* ]]
  [[ "$(section "📋 Overview")" != *"| Repository |"* ]]
}

@test "details blocks keep valid Markdown: blank line after summary and before the end" {
  layout
  run "$REPORT"
  [ "$(grep -c '^<details' <<<"$output")" -eq "$(grep -c '^</details>$' <<<"$output")" ]
  awk '/^<details/ { getline n; if (n != "") { print "no blank line after: " $0; bad = 1 } }
       /^<\/details>$/ { if (prev != "") { print "no blank line before </details>"; bad = 1 } }
       { prev = $0 } END { exit bad }' <<<"$output"
}

@test "row anchors stay unique when a numbered slug equals another repository's slug" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"o/a","message":"one"}
{"level":"info","check":"list-none","repo":"o/a","message":"two"}
{"level":"info","check":"list-none","repo":"o/a-2","message":"three"}
J
  echo '[{"name":"o/a"},{"name":"o/a-2"}]' >"$BATS_TEST_TMPDIR/inv.json"
  export INVENTORY="$BATS_TEST_TMPDIR/inv.json"
  run "$REPORT"
  [ -z "$(grep -o '<a name="f-[^"]*"' <<<"$output" | sort | uniq -d)" ]
  [ "$(grep -o '<a name="f-[^"]*"' <<<"$output" | wc -l)" -eq 3 ]
  for l in $(section "📋 Overview" | grep -o '(#user-content-f-[^)]*)' | sed 's/^(#user-content-//; s/)$//'); do
    [ "$(grep -cF "<a name=\"$l\"></a>" <<<"$output")" -eq 1 ] || { echo "not one anchor: $l"; return 1; }
  done
  # the overview links o/a-2 to its own row
  a2=$(section "📋 Overview" | grep '^| \[o/a-2\]' | grep -o '#user-content-f-[^)]*' | sed 's/^#user-content-//')
  [[ "$(section "🔵 Info")" == *"<a name=\"$a2\"></a>[o/a-2](https://github.com/o/a-2) | three |"* ]]
}

@test "Red, Info and TODO rows are sorted by repository regardless of case" {
  findings <<'J'
{"level":"info","check":"list-none","repo":"o/b","message":"m"}
{"level":"info","check":"list-none","repo":"o/C","message":"m"}
{"level":"info","check":"list-none","repo":"O/a","message":"m"}
J
  run "$REPORT"
  [[ "$(section "🔵 Info")" == *"[O/a]"*"[o/b]"*"[o/C]"* ]]
  [[ "$(section "📝 TODO")" == *"[O/a]"*"[o/b]"*"[o/C]"* ]]
}
