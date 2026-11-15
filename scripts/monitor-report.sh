#!/usr/bin/env bash
# Renders the findings of a monitor run as Markdown on stdout and applies the
# ignores of the control file.
#
# Env: FINDINGS (JSON lines), CONFIG (the control file as JSON).
# Exit status: 1 if a red finding is left, else 0.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# JQ program, run with -s over $FINDINGS. Argument: $cfg (slurped config).
# Prints {markdown, red}.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
REPORT_JQ='
$cfg[0] as $cfg | . as $f
| def cell: tostring | gsub("\\|"; "\\|") | gsub("[\\r\\n]+"; " ");
  def matches($i): .repo == $i.repo and .check == $i.check;

  ($cfg.ignores // []) as $ign
| ($f | map(select(. as $x | any($ign[]; . as $i | $x | matches($i)) | not))) as $kept
| ($ign | map(select(. as $i | any($f[]; matches($i)) | not))
    | map({level: "info", check: "ignore-unused", repo, message: "unused ignore: \(.reason)"})) as $unused
| ($kept + $unused) as $rows
| def level_rows($l): $rows | map(select(.level == $l));
  def section($l; $title):
    level_rows($l) as $r
  | if ($r | length) == 0 then empty else
      "### \($title)\n",
      ($r | map(.check) | unique[] as $c
       | ($r | map(select(.check == $c)) | sort_by(.repo // "")) as $cr
       | "#### `\($c)`\n\n| repo | message |\n| --- | --- |\n"
         + ($cr | map("| \(.repo // "-") | \(.message // "" | cell) |") | join("\n")) + "\n")
    end;
  (level_rows("red") | length) as $nred
| (level_rows("info") | length) as $ninfo
| (level_rows("skip") | length) as $nskip
| {
    red: $nred,
    markdown: ([
      "## Maintenance monitor\n",
      "\($nred) red · \($ninfo) info · \($nskip) skipped\n",
      section("red"; "Red"),
      section("info"; "Info")
    ] | join("\n"))
  }'

main() {
  need_env FINDINGS CONFIG
  local result
  result=$(jq -s --slurpfile cfg "$CONFIG" "$REPORT_JQ" "$FINDINGS")
  jq -r '.markdown' <<<"$result"
  [[ $(jq '.red' <<<"$result") -eq 0 ]]
}

main "$@"
