#!/usr/bin/env bash
# Renders the findings of a monitor run as Markdown on stdout and applies the
# ignores of the control file.
#
# Env: FINDINGS (JSON lines), CONFIG (the control file as JSON),
# MONITOR_DOCS_URL (the check explanations, default: docs/monitor-checks.md on
# main of spali/.github), MONITOR_CONFIG_URL (the control file on GitHub,
# optional).
# Exit status: 1 if a red finding is left, else 0.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# JQ program, run with -s over $FINDINGS. Arguments: $cfg (slurped config),
# $docs (URL of the check explanations), $control (URL of the control file,
# may be empty). Prints {markdown, red}.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
REPORT_JQ='
$cfg[0] as $cfg | . as $f
| def gh: "https://github.com/\(.)";
  def repo_link: "[\(.)](\(gh))";
  def cell: tostring | gsub("\\|"; "\\|") | gsub("[\\r\\n]+"; " ");
  # Where to fix a finding: [label, url] or null.
  def fix:
    .repo as $r | .check as $c
    | if $r == null then
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
    | gsub("(?<u>https://[^\\s|)\\]]+)"; "[\(if (.u | test("/actions/runs")) then "run" else "link" end)](\(.u))")
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
  (level_rows("red") | length) as $nred
| (level_rows("info") | length) as $ninfo
| (level_rows("skip") | length) as $nskip
| {
    red: $nred,
    markdown: ([
      "## Maintenance monitor\n",
      (if $nred > 0 then "> [!CAUTION]" else "> [!TIP]" end)
        + "\n> **\($nred) red** · \($ninfo) info · \($nskip) skipped\n",
      "## 🔴 Red (\($nred))\n",
      (if $nred == 0 then "✅ Nothing to fix.\n" else checks(level_rows("red")) end),
      "## 🔵 Info (\($ninfo))\n",
      (if $ninfo == 0 then "Nothing to note.\n" else checks(level_rows("info")) end),
      "## ⚪ Skipped (\($nskip))\n",
      (if $nskip == 0 then "Nothing skipped.\n"
       else "<details><summary>Not applicable, click to show</summary>\n", checks(level_rows("skip")), "</details>\n" end)
    ] | join("\n"))
  }'

main() {
  need_env FINDINGS CONFIG
  local result
  result=$(jq -s --slurpfile cfg "$CONFIG" \
    --arg docs "${MONITOR_DOCS_URL:-https://github.com/spali/.github/blob/main/docs/monitor-checks.md}" \
    --arg control "${MONITOR_CONFIG_URL:-}" "$REPORT_JQ" "$FINDINGS")
  jq -r '.markdown' <<<"$result"
  [[ $(jq '.red' <<<"$result") -eq 0 ]]
}

main "$@"
