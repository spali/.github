#!/usr/bin/env bash
# Included Actions quota of the account (billing-minutes, billing-storage, and
# one info line billing per run). Only private repositories count: a
# repository of the usage that is not in the inventory (deleted, renamed,
# archived) counts as private. Minutes weigh by price (grossAmount over the
# Actions Linux price), so macOS and Windows count like GitHub bills them;
# storage is a monthly average in GB. Red when the usage so far reaches the
# threshold, or from day 7 of the month (UTC) when the projection to month end
# reaches 100 %. Included values and thresholds come from `billing:` in the
# control file, else from the plan (free, pro) and 75 %. Writes findings only
# (account level, no repository). Env: FINDINGS INVENTORY CONFIG (file paths),
# BILLING_TOKEN (account token with Plan read, used as GH_TOKEN; missing: skip
# finding), optional MONITOR_NOW (epoch seconds, default now).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

OWNER=spali

# Included minutes and storage (GB) of the plans without `billing:`.
PLANS='{"free": {"minutes": 2000, "gb": 0.5}, "pro": {"minutes": 3000, "gb": 2}}'

# Prints TSV lines "level check message" from the usage answer on stdin.
BILLING_JQ='
  def r: round;
  def mb: (. * 1000) as $m | if $m > 0 and $m < 0.5 then "<1" else ($m | round | tostring) end;
  def div($a; $b): if $b > 0 then $a / $b else 0 end;
  ($now | gmtime) as $t |
  ([$t[0], $t[1], 1, 0, 0, 0, 0, 0] | mktime) as $start |
  ((([$t[0], $t[1] + 1, 1, 0, 0, 0, 0, 0] | mktime) - $start) / 3600) as $month_h |
  (($now - $start) / 3600) as $e |
  $t[2] as $day |
  ($start | todate | .[0:7]) as $month |
  ($now - 86400 | todate | .[0:10]) as $yesterday |
  ([$inv[0][] | {key: (.name | ascii_downcase), value: (.private == true)}] | from_entries) as $private |
  def shown: (.repositoryName // "") as $n |
    if $private | has("\($o)/\($n)" | ascii_downcase) then $n
    else "\(if $n == "" then "(no name)" else $n end) (not in inventory)" end;
  [.usageItems[] | select((.date // "") | startswith($month))] as $items |
  (first($items[] | select(.sku == "Actions Linux") | .pricePerUnit | numbers | select(. > 0)) // 0.006) as $price |
  [$items[] | select($private["\($o)/\(.repositoryName // "")" | ascii_downcase] != false)] as $own |
  [$own[] | select(.unitType == "Minutes")] as $min_items |
  [$own[] | select(.unitType == "GigabyteHours")] as $gb_items |
  (([$min_items[].grossAmount] | add // 0) / $price) as $used |
  ([$gb_items[].quantity] | add // 0) as $gbh |
  (div($used * 100; $minutes)) as $min_pct |
  (div($min_pct * $month_h; $e)) as $min_proj |
  (div($gbh; $e)) as $avg |
  (if $day == 1 then $avg
   else [$gb_items[] | select(.date[0:10] == $yesterday) | .quantity] | add // 0 | . / 24 end) as $level |
  (div($gbh * 100; $gb * $e)) as $gb_pct |
  (div(($gbh + $level * ($month_h - $e)) * 100; $gb * $month_h)) as $gb_proj |
  def top(f; unit): group_by(shown) | map({n: .[0] | shown, v: (map(f) | add)}) |
    sort_by(-.v) | .[:3] | map("\(.n) \(.v | unit)") | join(", ");
  (if ($min_pct | r) >= $min_threshold or ($day >= 7 and ($min_proj | r) >= 100) then
     ["red", "billing-minutes",
      "Actions minutes at \($min_pct | r) % of the included \($minutes) (\($used | r)), projected \($min_proj | r) % by month end"]
   else empty end),
  (if ($gb_pct | r) >= $gb_threshold or ($day >= 7 and ($gb_proj | r) >= 100) then
     ["red", "billing-storage",
      "Actions storage at \($gb_pct | r) % of the included \($gb | mb) MB (\($avg | mb) MB on average), projected \($gb_proj | r) % by month end"]
   else empty end),
  ["info", "billing", ([
     "Actions minutes \($min_pct | r) % (\($used | r) of \($minutes), projected \($min_proj | r) %)",
     "storage \($gb_pct | r) % (\($avg | mb) MB of \($gb | mb) MB, projected \($gb_proj | r) %)",
     ($min_items | top((.grossAmount // 0) / $price; "\(r) min") | select(. != "") | "top: \(.)"),
     ($gb_items | top(div(.quantity // 0; $e); "\(mb) MB") | select(. != "") | "top storage: \(.)")
   ] | join(" · "))]
  | @tsv'

main() {
  local cfg plan body rows level check message now year month
  if [[ -z ${BILLING_TOKEN:-} ]]; then
    finding skip billing - "no account token: billing not checked"
    return 0
  fi
  export GH_TOKEN=$BILLING_TOKEN
  cfg=$(jq -c '.billing // {} | {minutes: .minutes.included, threshold: (.minutes.threshold // 75),
    gb: .storage["included-gb"], gb_threshold: (.storage.threshold // 75)}' "$CONFIG")
  if jq -e '.minutes == null or .gb == null' >/dev/null <<<"$cfg"; then
    body=$(fetch billing - "users/$OWNER") || return 0
    json_out billing - plan -er '.plan.name | strings' <<<"$body" || return 0
    if ! jq -e --arg p "$plan" 'has($p)' >/dev/null <<<"$PLANS"; then
      finding red check-failed - "billing: plan $plan has no defaults: set billing: in the control file"
      return 0
    fi
    cfg=$(jq -c --arg p "$plan" --argjson plans "$PLANS" \
      '.minutes //= $plans[$p].minutes | .gb //= $plans[$p].gb' <<<"$cfg")
  fi
  now=${MONITOR_NOW:-$(date -u +%s)}
  year=$(date -u -d "@$now" +%Y)
  month=$(date -u -d "@$now" +%-m)
  body=$(fetch billing - "users/$OWNER/settings/billing/usage?year=$year&month=$month") || return 0
  if ! jq -e '.usageItems | type == "array"' >/dev/null 2>&1 <<<"$body"; then
    parse_failed billing -
    return 0
  fi
  json_out billing - rows -r --argjson now "$now" --arg o "$OWNER" --slurpfile inv "$INVENTORY" \
    --argjson minutes "$(jq '.minutes' <<<"$cfg")" --argjson min_threshold "$(jq '.threshold' <<<"$cfg")" \
    --argjson gb "$(jq '.gb' <<<"$cfg")" --argjson gb_threshold "$(jq '.gb_threshold' <<<"$cfg")" \
    "$BILLING_JQ" <<<"$body" || return 0
  while IFS=$'\t' read -r level check message; do
    finding "$level" "$check" - "$message"
  done <<<"$rows"
}

main
