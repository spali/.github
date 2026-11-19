#!/usr/bin/env bash
# Renders the findings of a monitor run as Markdown on stdout and applies the
# ignores of the control file.
#
# Env: FINDINGS (JSON lines), CONFIG (the control file as JSON),
# MONITOR_DOCS_URL (the check explanations, default: docs/monitor-checks.md on
# main of spali/.github), MONITOR_CONFIG_URL (the control file on GitHub,
# optional), INVENTORY (the inventory JSON array, optional: without it there
# is no overview and no section of clean repositories), MONITOR_NOW (epoch,
# default now: the time in the summary line), GITHUB_SERVER_URL,
# GITHUB_REPOSITORY, GITHUB_RUN_ID (optional, all three: link to the run),
# report.timezone of CONFIG (default UTC: the time zone of the summary line),
# FORK_KINDS (optional: JSON lines of monitor-forks.sh record_kind, the kind
# of each fork or mirror; without it there is no section of forks), LISTS
# (optional: the GitHub Lists of monitor-lists.sh; with them the forks section
# shows the lists of each fork or mirror, without the lists.forks of CONFIG).
# Exit status: 1 if a red finding is left, else 0.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# An ISO 8601 UTC time in a message (jq regex, no capture group).
TIME_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?Z'

# JQ program, run with -s over $FINDINGS, after $MONITOR_GROUPS_JQ.
# Arguments: $cfg (slurped config), $inv (slurped inventory, [] without one),
# $kinds (the fork kinds, [] without them), $lists (the GitHub Lists, null
# without them),
# $docs (URL of the check explanations), $control (URL of the control file,
# may be empty), $todo (MONITOR_TODO), $now (time of the summary line),
# $times (UTC time in a message -> the same time in the report time zone), $run
# (URL of the run, may be empty). Prints {markdown, red}.
# Layout: summary line, TODO (one entry per check and category, without the
# checks marked "todo": false), Overview
# (repository × area; only with an inventory), Red, Info, Forks and mirrors
# (only with fork kinds), Clean, Not checked.
# Each section has an explicit anchor on its own line above the heading, then
# <br> and an empty line (keeps the heading clear of the sticky issue header):
# GitHub issues give headings no ids, but keep <a name="x"> as id/name
# "user-content-x", so the links point at #user-content-x directly. The line
# <!-- maintenance-monitor:details --> right above the Red anchor splits the
# report for monitor-issue.sh: issue text above, monitor comment from it on.
# Each Red/Info row with a repository starts with the anchor
# f-<check>-<slug>[-n] that the overview icons link to.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
REPORT_JQ='
# UTC times in messages (2024-10-28T06:59:24Z) in the time zone of the report
def local_times: gsub("(?<t>'"$TIME_RE"')"; $times[.t] // .t);
$cfg[0] as $cfg
| map(if (.message | type) == "string" then .message |= local_times else . end) as $f
| def gh: "https://github.com/\(.)";
  def repo_link: "[\(.)](\(gh))";
  def cell: tostring | gsub("\\|"; "\\|") | gsub("[\\r\\n]+"; " ");
  def slug: ascii_downcase | gsub("[^a-z0-9-]"; "-");
  def section($name; $title; $pre): "\($pre)<a name=\"\($name)\"></a>\n<br>\n", "## \($title)\n";
  def section($name; $title): section($name; $title; "");
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
      elif $c == "settings-merge" or $c == "funding" then ["Settings", "\($r | gh)/settings"]
      elif $c == "settings-alerts" or $c == "settings-pvr" then ["Security settings", "\($r | gh)/settings/security_analysis"]
      elif $c == "settings-actions" or $c == "settings-fork-approval" then ["Actions settings", "\($r | gh)/settings/actions"]
      elif $c == "ruleset-main" or $c == "ruleset-tags" then ["Rulesets", "\($r | gh)/settings/rules"]
      elif $c == "main-red" or $c == "workflow-disabled" or $c == "fork-workflows-active" then ["Actions", "\($r | gh)/actions"]
      elif $c == "unanswered" then ["Issues", "\($r | gh)/issues"]
      elif $c == "stale-branch" then ["Branches", "\($r | gh)/branches"]
      elif $c == "dependabot-alert" then ["Dependabot", "\($r | gh)/security/dependabot"]
      elif $c == "code-scanning-alert" then ["Code scanning", "\($r | gh)/security/code-scanning"]
      elif ($c | startswith("fork-")) then ["Fork", ($r | gh)]
      elif ($c | startswith("list-")) then ["Lists", "\($r | split("/")[0] | gh)?tab=stars"]
      else null end;
  # The message as Markdown: URLs, and issue numbers become links.
  def details:
    .repo as $r
    | (.message // "" | cell)
    | gsub("(?<u>https://[^\\s|)\\]]+)"; "[\(if (.u | test("/actions/runs/[0-9]+/job/")) then "job" elif (.u | test("/actions/runs")) then "run" else "link" end)](\(.u))")
    | if $r != null then gsub("(?<![\\w/&\\[])#(?<n>[0-9]+)"; "[#\(.n)](\($r | gh)/issues/\(.n))") else . end;
  # A table row; with .anchor its first cell starts with that row anchor.
  def row: "| \(if .anchor then "<a name=\"\(.anchor)\"></a>" else "" end)\(if .repo then (.repo | repo_link) else "-" end) | \(details) | \(fix | if . then "[\(.[0])](\(.[1]))" else "" end) |";
  def table: "| Repository | Details | Fix at |\n| --- | --- | --- |\n" + (map(row) | join("\n")) + "\n";
  def matches($i): .repo == $i.repo and .check == $i.check and (($i.item // null) == null or $i.item == .item);
  def count($n; $one; $more): "\($n) \(if $n == 1 then $one else $more end)";

  ($cfg.ignores // []) as $ign
| ($f | map(select(. as $x | any($ign[]; . as $i | $x | matches($i)) | not))) as $kept
| ($ign | map(select(. as $i | any($f[]; matches($i)) | not))
    | map({level: "info", check: "ignore-unused", repo, message: (if .item then "unused ignore of #\(.item): \(.reason)" else "unused ignore: \(.reason)" end)})) as $unused
| ($kept + $unused) as $rows
| def level_rows($l): $rows | map(select(.level == $l));
  # The red and info rows in the order of their tables (check, then
  # repository regardless of case), each with a repository with a unique
  # .anchor: f-<check>-<slug>, then -2, -3 … until unused (o/a twice and
  # o/a-2 give f-x-o-a, f-x-o-a-2 and f-x-o-a-2-2).
  ([level_rows("red"), level_rows("info") | sort_by(.check, (.repo // "" | ascii_downcase))[]]
    | reduce .[] as $x ({used: {}, out: []};
        if $x.repo == null then .out += [$x]
        else "f-\($x.check)-\($x.repo | slug)" as $k
          | . as $st
          | (first(range(1; infinite) | (if . == 1 then $k else "\($k)-\(.)" end) | select($st.used[.] | not))) as $a
          | .used[$a] = true | .out += [$x + {anchor: $a}] end)
    | .out | to_entries | map(.value + {pos: .key})) as $listed
  | def checks($l):
    $listed | map(select(.level == $l)) | map(.check) | unique[] as $c
    | "### `\($c)` [ℹ️](\($docs)#\($c))\n\n" + ($listed | map(select(.level == $l and .check == $c)) | table);
  # The not checked findings of one check: one line per reason (the message
  # without "<check>: " and "gh: ", Markdown escaped), its repositories
  # sorted; without a repository only the reason.
  def reasons($r):
    $r | map(.check) | unique[] as $c
    | "### `\($c)` [ℹ️](\($docs)#\($c))\n\n"
      + ($r | map(select(.check == $c))
         | map(.reason = (.message // "" | tostring | gsub("[\\r\\n]+"; " ")
             | ltrimstr("\($c): ") | ltrimstr("gh: ")
             | if test("^\\s*$") then "(no details)" else gsub("(?<m>[\\\\`*_\\[\\]<>])"; "\\\(.m)") end))
         | group_by(.reason)
         | map("- \(.[0].reason)"
             + (map(.repo // empty) | unique | if length > 0 then ": " + (map(repo_link) | join(", ")) else "" end))
         | join("\n")) + "\n";
  # TODO: one entry per check with red findings (Fix now) and per check with
  # info findings (category of MONITOR_TODO, Clean up if unknown), in the
  # order Fix now, Decide, Clean up, then by check. A check whose entry has
  # "todo": false (a status line, nothing to do) stays out of the TODO.
  ({fix: ["🔴", "Fix now", 0], decide: ["🤔", "Decide", 1], cleanup: ["🧹", "Clean up", 2]}) as $cats
| ($listed | map(select($todo[.check].todo != false)) | group_by(.level, .check)
    | map(.[0] as $x | ($todo[$x.check] // {}) as $t
        | {check: $x.check, rows: map(del(.anchor)), title: ($t.title // $x.check), text: ($t.text // ""),
           cat: (if $x.level == "red" then "fix" elif $t.category == "decide" then "decide" else "cleanup" end)})
    | sort_by($cats[.cat][2], .check)) as $tasks
| def task:
    $cats[.cat] as [$icon, $label]
    | (.rows | if all(.repo != null) and (map(.repo) | unique | length) == length
        then count(length; "repository"; "repositories") else count(length; "entry"; "entries") end) as $n
    | "<details\(if .cat == "fix" then " open" else "" end)><summary>\($icon) <b>\($label)</b> · \(.title) · \($n) · <code>\(.check)</code></summary>\n\n"
      + "> \(if .text != "" then .text + " " else "" end)[ℹ️](\($docs)#\(.check))\n\n"
      + (.rows | table) + "\n</details>\n";
  (level_rows("red") | length) as $nred
| (level_rows("info") | length) as $ninfo
| (level_rows("skip") | length) as $nskip
  # the kind of each fork or mirror, the last record per repository, by kind,
  # within a kind the ones with past pull requests or pinned first
| ($kinds | map(select(type == "object" and (.repo | type) == "string"))
    | group_by(.repo | ascii_downcase) | map(last)
    | sort_by((.kind | {"contribution": 0, "customized": 1, "unchanged": 2}[.] // 3),
        (if (.merged | type) == "number" and .merged > 0 or (.closed | type) == "number" and .closed > 0
            or .pinned == true then 0 else 1 end),
        (.repo | ascii_downcase))) as $forks
| def upstream_link:
    (.upstream // "") as $u
    | if $u | test("^https://") then "[\($u | cell)](\($u))"
      elif $u == "" then "–" else $u | repo_link end;
  # what the fork holds, then the past pull requests of its owner upstream;
  # ❔ unknown when the numbers are missing (a mirror)
  def kind_label:
    (.upstream // "") as $u
    | if (.own | type) != "number" then "❔ unknown"
      else (if .kind == "contribution" then "🤝 contribution: " + (.pulls | map("[#\(.)](https://github.com/\($u)/pull/\(.))") | join(", "))
        elif .kind == "customized" then "✏️ \(count(.own; "own commit"; "own commits"))"
        else "⚪ unchanged" end)
        + (if (.merged | type) != "number" or (.closed | type) != "number" then " · ❔ past pull requests unknown"
           else [(select(.merged > 0) | "✅ \(.merged) merged"), (select(.closed > 0) | "✖️ \(.closed) closed")]
             | map(" · " + .) | join("") end)
      end;
  # the other lists of the repository (without lists.forks), null without lists
  def other_lists:
    (.repo | ascii_downcase) as $r
    | if $lists == null then null
      else [$lists[] | select(.name | IN(($cfg.lists.forks // [])[]) | not)
          | select(any(.items[]?; (.repo? | strings | ascii_downcase) == $r)) | .name | cell]
        | if length == 0 then "–" else join(", ") end end;
  .
| ($inv[0] | if type == "array" and length > 0 then . else null end) as $inventory
  # ignore-unused and findings without a repository concern no repository;
  # an empty inventory counts as none
| ($inventory | if . then
      ($rows | map(select(.level != "skip" and .check != "ignore-unused") | .repo // empty)) as $dirty
      | map(.name) | unique | map(select(. as $n | $dirty | index($n) | not))
    else null end) as $clean
  # Overview: the groups of the check scripts (as the workflow matrix), by
  # lowercase name; the column lists takes the whole
  # inventory.
| ($inventory | if . then groups($cfg; .) | map_values(map(ascii_downcase))
    | .lists = ($inventory | map(.name | ascii_downcase)) else null end) as $applies
| ([["release", "Release"], ["settings", "Settings"], ["health", "Health"],
    ["forks", "Fork / Mirror"], ["lists", "Lists"]]) as $cols
| def column:
    (.repo | ascii_downcase) as $r
    | (if .check == "check-failed" then ((.message // "" | tostring | capture("^(?<k>[a-z-]+): ") | .k)? // "" | $todo[.].areas) else null end) as $named
    | ($named // $todo[.check].areas // ($cols | map(.[0]))) as $cands
    | (first($cands[] | select(. as $a | $applies[$a] | index($r))) // $cands[0]);
  def overview:
    ($listed | map(select(.repo != null and .check != "ignore-unused") | .col = column | select(.col != null))) as $marks
    | ($rows | map(select(.level == "skip" and .repo != null) | .col = column)) as $skips
    | ($marks | group_by(.repo | ascii_downcase)
        | map({key: (.[0].repo | ascii_downcase), name: .[0].repo, red: any(.level == "red"), marks: .})
        | sort_by((if .red then 0 else 1 end), .key)) as $repos
    | if ($repos | length) == 0 then "No repository with findings.\n"
      else "Each icon is one finding and jumps to its row below. 🔴 fix · 🔵 note · ✅ ok · ⚪ not checked · – does not apply\n",
        "| Repository | \($cols | map(.[1]) | join(" | ")) |\n| :-- |\($cols | map(" :-: |") | join(""))\n"
        + ($repos | map(. as $p
            | "| \($p.name | repo_link) | "
              + ($cols | map(.[0] as $col
                  | ($p.marks | map(select(.col == $col)) | sort_by((if .level == "red" then 0 else 1 end), .check, .pos)) as $m
                  | if ($m | length) > 0 then $m | map("[\(if .level == "red" then "🔴" else "🔵" end)](#user-content-\(.anchor))") | join("")
                    elif any($skips[]; (.repo | ascii_downcase) == $p.key and .col == $col) then "⚪"
                    elif $applies[$col] | index($p.key) then "✅"
                    else "–" end) | join(" | "))
              + " |") | join("\n")) + "\n"
      end;
  {
    red: $nred,
    markdown: ([
      "## Maintenance monitor\n",
      (if $nred > 0 then "> [!CAUTION]" else "> [!TIP]" end)
        + "\n> **[\($nred) red](#user-content-red)** · [\($ninfo) info](#user-content-info)"
        + (if $clean then " · [\($clean | length) clean](#user-content-clean)" else "" end)
        + " · [\($nskip) not checked](#user-content-not-checked)"
        + " · [\($tasks | length) to do](#user-content-todo) · updated \($now)"
        + (if $run != "" then " · [run](\($run))" else "" end) + "\n",
      section("todo"; "📝 TODO"),
      (if ($tasks | length) == 0 then "Nothing to do.\n" else ($tasks[] | task) end),
      (if $applies then section("overview"; "📋 Overview"), overview else empty end),
      section("red"; "🔴 Red"; "<!-- maintenance-monitor:details -->\n"),
      (if $nred == 0 then "✅ Nothing to fix.\n" else checks("red") end),
      section("info"; "🔵 Info"),
      (if $ninfo == 0 then "Nothing to note.\n" else checks("info") end),
      (if $applies then "[↑ overview](#user-content-overview)\n" else empty end),
      (if ($forks | length) > 0 then
        section("forks"; "🍴 Forks and mirrors"),
        "What each fork or mirror holds: 🤝 open pull requests upstream, ✏️ own commits on the default branch (the sync rebases them), ⚪ nothing of its own; past pull requests of its owner upstream: ✅ merged, ✖️ closed without merge; ❔ unknown: not counted (a mirror of a repository outside GitHub); 📌 pinned: not synced.\n",
        "| Repository | Upstream | Kind |\(if $lists then " Lists |" else "" end)\n| --- | --- | --- |\(if $lists then " --- |" else "" end)\n"
          + ($forks | map("| \(.repo | repo_link) | \(upstream_link) | \(kind_label)\(if .pinned then " · 📌 pinned" else "" end) |\(other_lists | if . then " \(.) |" else "" end)") | join("\n")) + "\n"
       else empty end),
      (if $clean then
        section("clean"; "✅ Clean"),
        (if ($clean | length) == 0 then "No repository without findings.\n"
         else ($clean | map(repo_link) | join(", ")) + "\n" end)
       else empty end),
      section("not-checked"; "⚪ Not checked"),
      (if $nskip == 0 then "Every check ran.\n"
       else "Checks that did not run in these repositories because they do not apply or the feature is not available there; the repositories were checked otherwise. Each line gives the reason.\n",
         reasons(level_rows("skip")) end)
    ] | join("\n"))
  }'

main() {
  need_env FINDINGS CONFIG
  local result now tz run='' inv=(--argjson inv '[]') kinds='[]' lists='null'
  # a missing or broken inventory means none: no section of clean repositories
  if [[ -n ${INVENTORY:-} ]] && jq -e 'type == "array"' "$INVENTORY" >/dev/null 2>&1; then
    inv=(--slurpfile inv "$INVENTORY")
  fi
  # broken or missing fork kinds mean none
  if [[ -n ${FORK_KINDS:-} && -r $FORK_KINDS ]]; then
    kinds=$(jq -cs '[.[] | objects]' "$FORK_KINDS" 2>/dev/null) || kinds='[]'
  fi
  # broken or missing lists mean none: no lists column
  if [[ -n ${LISTS:-} && -r $LISTS ]]; then
    lists=$(jq -c 'if type == "array" then map(objects | select(.name | type == "string")) else null end' "$LISTS" 2>/dev/null) || lists='null'
    [[ -n $lists ]] || lists='null'
  fi
  # the time zone of the summary line (validated by monitor-config.sh), else UTC
  tz=$(jq -r '.report.timezone? // "UTC" | strings' "$CONFIG" 2>/dev/null) || tz=''
  now=$(TZ=${tz:-UTC} date -d "@${MONITOR_NOW:-$(date -u +%s)}" '+%Y-%m-%d %H:%M %Z')
  # the times in the messages, converted by date (jq's %Z ignores daylight saving)
  local t times='{}'
  while IFS= read -r t; do
    [[ -n $t ]] || continue
    times=$(jq -c --arg t "$t" --arg l "$(TZ=${tz:-UTC} date -d "$t" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)" \
      'if $l == "" then . else .[$t] = $l end' <<<"$times")
  done < <(jq -rs '[.[] | objects | .message | strings | scan("'"$TIME_RE"'")] | unique[]' "$FINDINGS" 2>/dev/null || true)
  if [[ -n ${GITHUB_SERVER_URL:-} && -n ${GITHUB_REPOSITORY:-} && -n ${GITHUB_RUN_ID:-} ]]; then
    run=$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID
  fi
  result=$(jq -s --slurpfile cfg "$CONFIG" "${inv[@]}" --argjson kinds "$kinds" --argjson lists "$lists" \
    --arg docs "${MONITOR_DOCS_URL:-https://github.com/spali/.github/blob/main/docs/monitor-checks.md}" \
    --arg control "${MONITOR_CONFIG_URL:-}" --argjson todo "$MONITOR_TODO" \
    --arg now "$now" --argjson times "$times" --arg run "$run" "$MONITOR_GROUPS_JQ$REPORT_JQ" "$FINDINGS")
  jq -r '.markdown' <<<"$result"
  [[ $(jq '.red' <<<"$result") -eq 0 ]]
}

main "$@"
