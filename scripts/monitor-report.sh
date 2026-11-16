#!/usr/bin/env bash
# Renders the findings of a monitor run as Markdown on stdout and applies the
# ignores of the control file.
#
# Env: FINDINGS (JSON lines), CONFIG (the control file as JSON),
# MONITOR_DOCS_URL (the check explanations, default: docs/monitor-checks.md on
# main of spali/.github), MONITOR_CONFIG_URL (the control file on GitHub,
# optional), INVENTORY (the inventory JSON array, optional: without it there
# is no section of clean repositories).
# Exit status: 1 if a red finding is left, else 0.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# JQ program, run with -s over $FINDINGS. Arguments: $cfg (slurped config),
# $inv (slurped inventory, [] without one), $docs (URL of the check
# explanations), $control (URL of the control file, may be empty). Prints
# {markdown, red}.
# The summary links each section by the id GitHub generates for its heading
# (lowercase, emoji and punctuation removed, spaces to hyphens): "## 🔴 Red"
# is #-red. The headings carry no count so the ids never change.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
REPORT_JQ='
$cfg[0] as $cfg | . as $f
| def gh: "https://github.com/\(.)";
  def repo_link: "[\(.)](\(gh))";
  def cell: tostring | gsub("\\|"; "\\|") | gsub("[\\r\\n]+"; " ");
  # Where to fix a finding: [label, url] or null.
  def fix:
    .repo as $r | .check as $c
    # the sync workflow of the control repository, if its file URL is known
    | ([$control | capture("^(?<repo>https://[^/]+/[^/]+/[^/]+)/blob/")? | .repo
        | "\(.)/actions/workflows/sync.yml"] | first) as $sync
    | if $c == "sync-failed" then (if $sync then ["Sync runs", $sync] else null end)
      elif $r == null then
        (if ($c == "config-invalid" or $c == "ignore-unused") and $control != "" then ["Control file", $control] else null end)
      elif $c == "ignore-unused" then (if $control != "" then ["Control file", $control] else null end)
      elif $c == "devbuild-closed-pr" or $c == "several-drafts" or $c == "next-stale" then ["Releases", "\($r | gh)/releases"]
      elif $c == "orphan-tag" then ["Tags", "\($r | gh)/tags"]
      elif $c == "pin-behind" or $c == "renovate-stale" then ["Renovate PRs", "\($r | gh)/pulls?q=is%3Apr+is%3Aopen+author%3Aapp%2Frenovate"]
      elif $c == "settings-merge" then ["Settings", "\($r | gh)/settings"]
      elif $c == "settings-alerts" or $c == "settings-pvr" then ["Security settings", "\($r | gh)/settings/security_analysis"]
      elif $c == "settings-actions" then ["Actions settings", "\($r | gh)/settings/actions"]
      elif $c == "ruleset-main" or $c == "ruleset-tags" then ["Rulesets", "\($r | gh)/settings/rules"]
      elif $c == "main-red" or $c == "workflow-disabled" or $c == "fork-workflows-active" then ["Actions", "\($r | gh)/actions"]
      elif $c == "dependabot-alert" then ["Dependabot", "\($r | gh)/security/dependabot"]
      elif $c == "code-scanning-alert" then ["Code scanning", "\($r | gh)/security/code-scanning"]
      elif ($c | startswith("fork-")) then ["Fork", ($r | gh)]
      elif $c == "mirror-behind" then ["Mirror", ($r | gh)]
      elif ($c | startswith("list-")) then ["Lists", "\($r | split("/")[0] | gh)?tab=stars"]
      else null end;
  # The message as Markdown: URLs, issue numbers and (in adoption) repository
  # names become links.
  def details:
    .repo as $r | .check as $c
    | (.message // "" | cell)
    | gsub("(?<u>https://[^\\s|)\\]]+)"; "[\(if (.u | test("/actions/runs/[0-9]+/job/")) then "job" elif (.u | test("/actions/runs")) then "run" else "link" end)](\(.u))")
    | if $r != null then gsub("(?<![\\w/&\\[])#(?<n>[0-9]+)"; "[#\(.n)](\($r | gh)/issues/\(.n))") else . end
    | if $c == "adoption" then gsub("(?<![\\w/.\\[-])(?<o>[A-Za-z0-9-]+)/(?<n>[A-Za-z0-9._-]*[A-Za-z0-9_-])"; "[\(.o)/\(.n)](https://github.com/\(.o)/\(.n))") else . end;
  def row: "| \(if .repo then (.repo | repo_link) else "-" end) | \(details) | \(fix | if . then "[\(.[0])](\(.[1]))" else "" end) |";
  def matches($i): .repo == $i.repo and .check == $i.check;

  ($cfg.ignores // []) as $ign
| ($f | map(select(. as $x | any($ign[]; . as $i | $x | matches($i)) | not))) as $kept
| ($ign | map(select(. as $i | any($f[]; matches($i)) | not))
    | map({level: "info", check: "ignore-unused", repo, message: "unused ignore: \(.reason)"})) as $unused
| ($kept + $unused) as $rows
| def level_rows($l): $rows | map(select(.level == $l));
  def checks($r):
    $r | map(.check) | unique[] as $c
    | ($r | map(select(.check == $c)) | sort_by(.repo // "")) as $cr
    | "### `\($c)` [ℹ️](\($docs)#\($c))\n\n| Repository | Details | Fix at |\n| --- | --- | --- |\n"
      + ($cr | map(row) | join("\n")) + "\n";
  # The not checked findings of one check: one line per reason (the message
  # without "<check>: " and "gh: "), its repositories sorted.
  def reasons($r):
    $r | map(.check) | unique[] as $c
    | "### `\($c)` [ℹ️](\($docs)#\($c))\n\n"
      + ($r | map(select(.check == $c))
         | map(.reason = (.message // "" | tostring | gsub("[\\r\\n]+"; " ")
             | ltrimstr("\($c): ") | ltrimstr("gh: ")))
         | group_by(.reason)
         | map("- \(.[0].reason): \(map(.repo // empty) | unique | map(repo_link) | join(", "))")
         | join("\n")) + "\n";
  def count($n; $one; $more): "\($n) \(if $n == 1 then $one else $more end)";
  (level_rows("red") | length) as $nred
| (level_rows("info") | length) as $ninfo
| (level_rows("skip") | length) as $nskip
  # ignore-unused and findings without a repository concern no repository
| ($inv[0] | if type == "array" then
      ($rows | map(select(.level != "skip" and .check != "ignore-unused") | .repo // empty)) as $dirty
      | map(.name) | unique | map(select(. as $n | $dirty | index($n) | not))
    else null end) as $clean
| {
    red: $nred,
    markdown: ([
      "## Maintenance monitor\n",
      (if $nred > 0 then "> [!CAUTION]" else "> [!TIP]" end)
        + "\n> **[\($nred) red](#-red)** · [\($ninfo) info](#-info)"
        + (if $clean then " · [\($clean | length) clean](#-clean)" else "" end)
        + " · [\($nskip) not checked](#-not-checked)\n",
      "## 🔴 Red\n",
      (if $nred == 0 then "✅ Nothing to fix.\n" else checks(level_rows("red")) end),
      "## 🔵 Info\n",
      (if $ninfo == 0 then "Nothing to note.\n" else checks(level_rows("info")) end),
      (if $clean then
        "## ✅ Clean\n",
        (if ($clean | length) == 0 then "No repository without findings.\n"
         else "<details><summary>\(count($clean | length; "repository"; "repositories")), click to show</summary>\n",
           ($clean | map(repo_link) | join(", ")) + "\n", "</details>\n" end)
       else empty end),
      "## ⚪ Not checked\n",
      (if $nskip == 0 then "Every check ran.\n"
       else "Checks that could not run in these repositories because the feature is off there; the repositories were checked otherwise.\n",
         "<details><summary>\(count($nskip; "check"; "checks")), click to show</summary>\n", reasons(level_rows("skip")), "</details>\n" end)
    ] | join("\n"))
  }'

main() {
  need_env FINDINGS CONFIG
  local result inv=(--argjson inv '[]')
  # a missing or broken inventory means none: no section of clean repositories
  if [[ -n ${INVENTORY:-} ]] && jq -e 'type == "array"' "$INVENTORY" >/dev/null 2>&1; then
    inv=(--slurpfile inv "$INVENTORY")
  fi
  result=$(jq -s --slurpfile cfg "$CONFIG" "${inv[@]}" \
    --arg docs "${MONITOR_DOCS_URL:-https://github.com/spali/.github/blob/main/docs/monitor-checks.md}" \
    --arg control "${MONITOR_CONFIG_URL:-}" "$REPORT_JQ" "$FINDINGS")
  jq -r '.markdown' <<<"$result"
  [[ $(jq '.red' <<<"$result") -eq 0 ]]
}

main "$@"
