#!/usr/bin/env bash
# Renders the findings of a monitor run as Markdown, applies the ignores of the
# control file and masks private repositories.
#
# Env: FINDINGS (JSON lines), INVENTORY (JSON array), CONFIG (monitor-config.sh
# merge output); optional GITHUB_STEP_SUMMARY (else stdout) and MONITOR_UNMASK
# (honored only outside GitHub Actions).
# Exit status: 1 if a red finding is left, else 0.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# JQ program, run with -s over $FINDINGS. Arguments: $inv, $cfg (slurped
# files), $unmask (bool). Prints {markdown, red}.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
REPORT_JQ='
$inv[0] as $inv | $cfg[0] as $cfg | . as $f
| ($inv | map({key: .name, value: .private}) | from_entries) as $pm
| ([(($cfg.mirrors // [])[] | select(.private) | .target),
     (($cfg.forks // [])[] | select(.private) | .repo),
     (($cfg.ignores // [])[] | select(.private) | .repo)]) as $cfgprivs
| (($inv | map(select(.private) | .name)) + $cfgprivs | unique) as $privs
| ($privs | map(split("/")[1:] | join("/"))) as $shorts
| def lb: "[A-Za-z0-9._-]";
  def rb: "[A-Za-z0-9_-]";
  def esc: gsub("\\."; "\\.");
  def maskstr($n): gsub("(?<!\(lb))\($n | esc)(?!\(rb))"; "[private]"; "i");
  def mask: if $unmask then . else reduce (($privs + $shorts)[]) as $n (.; maskstr($n)) end;
  def is_priv: . as $r | $r != null and ($unmask | not) and ((($pm | has($r)) | not) or $pm[$r] or ($cfgprivs | index($r) != null));
  def cell: mask | gsub("\\|"; "\\|") | gsub("[\\r\\n]+"; " ");
  def matches($i): .repo == $i.repo and .check == $i.check;

  ($cfg.ignores // []) as $ign
| ($f | map(select(. as $x | any($ign[]; . as $i | $x | matches($i)) | not))) as $kept
| ($ign | map(select(. as $i | any($f[]; matches($i)) | not))) as $unused
| ($unused | map(select(.private and ($unmask | not)))) as $privign
| ($unused | map(select((.private and ($unmask | not)) | not)
    | {level: "info", check: "ignore-unused", repo, message: "unused ignore: \(.reason)"})) as $pubign
| ($kept + $pubign | map(. + {priv: (.repo | is_priv)})) as $rows
| def level_rows($l): $rows | map(select(.level == $l));
  def masked($l):
    (level_rows($l) | map(select(.priv)) | group_by(.check)
      | map({check: .[0].check, text: "\(.[0].check): \(map(.repo) | unique | length) private repo(s)"}))
    + (if $l == "info" and ($privign | length) > 0
       then [{check: "ignore-unused", text: "ignore-unused: \($privign | length) private ignore(s)"}] else [] end);
  def section($l; $title):
    (level_rows($l) | map(select(.priv | not))) as $pub
  | masked($l) as $m
  | (($pub | map(.check)) + ($m | map(.check)) | unique) as $checks
  | if ($checks | length) == 0 then empty else
      "### \($title)\n",
      ($checks[] as $c
       | ($pub | map(select(.check == $c)) | sort_by(.repo // "")) as $r
       | (if ($r | length) > 0 then
            "#### `\($c)`\n\n| repo | message |\n| --- | --- |\n"
            + ($r | map("| \(.repo // "-") | \(.message // "" | tostring | cell) |") | join("\n")) + "\n"
          else empty end),
         ($m[] | select(.check == $c) | .text + "\n"))
    end;
  (level_rows("red") | length) as $nred
| ((level_rows("info") | length) + ($privign | length)) as $ninfo
| ($rows | map(select(.level == "skip")) | length) as $nskip
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
  need_env FINDINGS INVENTORY CONFIG
  local unmask=false result
  if [[ ${MONITOR_UNMASK:-} == 1 && ${GITHUB_ACTIONS:-} != true ]]; then
    unmask=true
  fi
  result=$(jq -s --slurpfile inv "$INVENTORY" --slurpfile cfg "$CONFIG" \
    --argjson unmask "$unmask" "$REPORT_JQ" "$FINDINGS")
  jq -r '.markdown' <<<"$result" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
  [[ $(jq '.red' <<<"$result") -eq 0 ]]
}

main "$@"
