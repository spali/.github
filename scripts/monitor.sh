#!/usr/bin/env bash
# Daily maintenance monitor: validates the control file, builds the inventory,
# runs every check script, renders the report and, if MONITOR_ISSUE_REPO is
# set, updates the overview issue in that repository.
#
# Usage: monitor.sh            all phases, prints only the report (local run)
#        monitor.sh PHASE      one phase, prints its log (one workflow step
#                              each); the phases share the dir $MONITOR_WORK
# Phases, in order: config inventory release settings health forks mirrors
# lists report issue. A check phase lists every repository it looked at
# (clean ones with ✓, the others as a log group with their findings) and
# annotates each red finding that is not ignored.
#
# Env: GH_TOKEN, MONITOR_CONFIG (default repos.yml), LISTS_TOKEN (default
# GH_TOKEN), MONITOR_ISSUE_REPO and ISSUE_TOKEN (see monitor-issue.sh),
# MONITOR_SCRIPTS_DIR (default: this script's directory), MONITOR_WORK.
# The report goes to $GITHUB_STEP_SUMMARY, or to stdout if that is not set.
# Exit status: all phases: 1 if a red finding is left or the issue update
# failed. One phase: 1 if it found a red finding that is not ignored or
# failed itself (the report phase only when the report crashed), 2 for a
# usage error.
set -euo pipefail

DIR=${MONITOR_SCRIPTS_DIR:-$(dirname "${BASH_SOURCE[0]}")}
# shellcheck source=scripts/monitor-lib.sh
source "$DIR/monitor-lib.sh"

PHASES=(config inventory release settings health forks mirrors lists report issue)
CHECKS=(release settings health forks mirrors lists)
CONFIG_FILE=${MONITOR_CONFIG:-repos.yml}
EMPTY_CONFIG='{"version":1,"lists":{},"mirrors":[],"forks":[],"ignores":[]}'

# annotate escapes the findings (JSON lines on stdin) as workflow commands.
# shellcheck disable=SC2016 # jq program
ANNOTATE_JQ='
  def data: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
  "::error title=\(.check)::\((if .repo then "\(.repo): " else "" end) + .message | data)"'

# new_findings FROM prints the findings after line FROM, each with the reason
# of a matching ignore (null if none).
# shellcheck disable=SC2016 # jq program
new_findings() {
  tail -n "+$(($1 + 1))" "$FINDINGS" |
    jq -c --slurpfile cfg "$CONFIG" '
      . as $f | ($cfg[0].ignores // []) as $ign |
      . + {ignored: ([$ign[] | select(.repo == $f.repo and .check == $f.check) | .reason] | first)}'
}

# --- phases ------------------------------------------------------------

phase_config() {
  local err line
  if err=$("$DIR/monitor-config.sh" validate "$CONFIG_FILE" 2>&1 >/dev/null) &&
    yq -o=json '.' "$CONFIG_FILE" >"$CONFIG" 2>/dev/null; then
    echo "✓ $(basename "$CONFIG_FILE") is valid"
    return 0
  fi
  line=$(head -n1 <<<"$err")
  line=${line#error: }
  line=${line#"$CONFIG_FILE": }
  finding red config-invalid - "$(basename "$CONFIG_FILE"): ${line:-invalid}"
  printf '%s\n' "$EMPTY_CONFIG" >"$CONFIG"
  tail -n1 "$FINDINGS" | jq -r "$ANNOTATE_JQ"
  return 1
}

phase_inventory() {
  if ! "$DIR/monitor-repos.sh" >"$INVENTORY"; then
    finding red check-failed - "monitor-repos.sh crashed"
    echo '[]' >"$INVENTORY"
    tail -n1 "$FINDINGS" | jq -r "$ANNOTATE_JQ"
    return 1
  fi
  jq -r '"✓ \(length) repositories, \(map(select(.central)) | length) central, \(map(select(.fork)) | length) forks"' "$INVENTORY"
}

# phase_check NAME runs monitor-NAME.sh and logs what it found.
phase_check() {
  local name=$1 script=monitor-$1.sh from checked_file rows
  checked_file="$WORK/checked-$name"
  : >"$checked_file"
  from=$(wc -l <"$FINDINGS")
  if ! MONITOR_CHECKED=$checked_file LISTS_TOKEN=${LISTS_TOKEN:-${GH_TOKEN:-}} \
    "$DIR/$script" >/dev/null 2>&1; then
    finding red check-failed - "$script crashed"
  fi
  rows=$(new_findings "$from")
  # shellcheck disable=SC2016 # jq program
  jq -nr --arg name "$name" --rawfile checked "$checked_file" '
    [inputs] as $f |
    ($checked | split("\n") | map(select(. != ""))) as $c |
    def icon: if .ignored then "◌" elif .level == "red" then "✗" elif .level == "info" then "ℹ" else "–" end;
    def n($l): map(select(.ignored == null and .level == $l)) | length;
    def counts: [
      (n("red") | select(. > 0) | "\(.) red"),
      (n("info") | select(. > 0) | "\(.) info"),
      (n("skip") | select(. > 0) | "\(.) skipped"),
      (map(select(.ignored)) | length | select(. > 0) | "\(.) ignored")] | join(", ");
    def group_icon: if n("red") > 0 then "✗" elif n("info") > 0 then "ℹ"
      elif n("skip") > 0 then "–" else "◌" end;
    (([$f[] | select(.repo == null)] | if length > 0 then [null] else [] end)
      + ($c + [$f[] | .repo | select(. != null)] | unique)) as $repos |
    ($repos[] as $r |
      [$f[] | select(.repo == $r)] as $rf |
      if ($rf | length) == 0 then "✓ \($r)"
      else
        "::group::\($rf | group_icon) \($r // "(no repository)"): \($rf | counts)",
        ($rf[] | "  \(icon) \(.check): \(.message)" + (if .ignored then " (ignored: \(.ignored))" else "" end)),
        "::endgroup::"
      end),
    ($f | map(select(.ignored == null and .level == "red")) | sort_by(.repo // "") | .[] | del(.ignored) | '"$ANNOTATE_JQ"'),
    "\($name): \([$repos[] | select(. != null)] | length) repositories · \($f | n("red")) red · \($f | n("info")) info · \($f | n("skip")) skipped · \($f | map(select(.ignored)) | length) ignored"
  ' <<<"$rows"
  [[ -z $(jq -c 'select(.ignored == null and .level == "red")' <<<"$rows") ]]
}

# phase_report renders $WORK/report.md and $WORK/title and appends the
# report to $GITHUB_STEP_SUMMARY (if set). Returns 1 if the report script
# crashed, else 0 (the check phases already failed for red findings).
phase_report() {
  local rc=0 counts title='Maintenance monitor'
  "$DIR/monitor-report.sh" >"$WORK/report.md" 2>/dev/null || rc=$?
  if ((rc > 1)); then
    echo "error: monitor-report.sh crashed" >&2
    printf '## Maintenance monitor\n\nThe report script crashed, see the run log.\n' >"$WORK/report.md"
    printf '%s\n' 'Maintenance monitor: report crashed' >"$WORK/title"
    summary
    return 1
  fi
  summary
  # the summary line of the report: "> **N red** · N info · N skipped"
  counts=$(grep -m1 -E '^> \*\*[0-9]+ red\*\* · [0-9]+ info' "$WORK/report.md" || true)
  counts=${counts#> }
  counts=${counts//\*/}
  if [[ $counts =~ ^([0-9]+)\ red\ ·\ ([0-9]+)\ info ]]; then
    title="Maintenance monitor: ${BASH_REMATCH[1]} red · ${BASH_REMATCH[2]} info"
  fi
  printf '%s\n' "$title" >"$WORK/title"
  printf '%s\n' "$rc" >"$WORK/report.rc"
  [[ -z ${counts:-} ]] || echo "✓ report: $counts"
}

# summary appends the report to $GITHUB_STEP_SUMMARY, if set.
summary() {
  [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || cat "$WORK/report.md" >>"$GITHUB_STEP_SUMMARY"
}

phase_issue() {
  local line
  if [[ -z ${MONITOR_ISSUE_REPO:-} ]]; then
    echo "– no MONITOR_ISSUE_REPO, overview issue not updated"
    return 0
  fi
  if ! "$DIR/monitor-issue.sh" "$WORK/report.md" "$(<"$WORK/title")" 2>"$WORK/issue.err" >/dev/null; then
    line=$(head -n1 "$WORK/issue.err")
    echo "${line:-error: monitor-issue.sh failed}" >&2
    return 1
  fi
  echo "✓ overview issue updated in $MONITOR_ISSUE_REPO"
}

# run_phase NAME
run_phase() {
  case $1 in
    config) phase_config ;;
    inventory) phase_inventory ;;
    report) phase_report ;;
    issue) phase_issue ;;
    *) phase_check "$1" ;;
  esac
}

# --- main --------------------------------------------------------------

main() {
  local p known='' status=0
  if (($# > 1)); then
    echo "usage: monitor.sh [PHASE]" >&2
    exit 2
  fi
  if (($# == 1)); then
    for p in "${PHASES[@]}"; do
      [[ $p != "$1" ]] || known=1
    done
    if [[ -z $known ]]; then
      echo "error: unknown phase $1 (${PHASES[*]})" >&2
      exit 2
    fi
    if [[ -z ${MONITOR_WORK:-} ]]; then
      echo "error: MONITOR_WORK is required for a single phase" >&2
      exit 2
    fi
    WORK=$MONITOR_WORK
    mkdir -p "$WORK"
  else
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
  fi
  export FINDINGS="$WORK/findings.jsonl" INVENTORY="$WORK/inventory.json" CONFIG="$WORK/config.json"
  [[ -e $FINDINGS ]] || : >"$FINDINGS"

  if (($# == 1)); then
    run_phase "$1"
    return
  fi

  # All phases: only the report on stdout, as before.
  phase_config >/dev/null || true
  phase_inventory >/dev/null || true
  for p in "${CHECKS[@]}"; do
    phase_check "$p" >/dev/null || true
  done
  phase_report >/dev/null || status=1
  [[ $(cat "$WORK/report.rc" 2>/dev/null || echo 0) -eq 0 ]] || status=1
  [[ -n ${GITHUB_STEP_SUMMARY:-} ]] || cat "$WORK/report.md"
  if [[ -n ${MONITOR_ISSUE_REPO:-} ]]; then
    phase_issue >/dev/null || status=1
  fi
  return "$status"
}

main "$@"
