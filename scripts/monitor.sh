#!/usr/bin/env bash
# Daily maintenance monitor: validates the control file, builds the inventory,
# runs every check script, renders the report and, if MONITOR_ISSUE_REPO is
# set, updates the overview issue in that repository.
#
# Env: GH_TOKEN, MONITOR_CONFIG (default repos.yml), LISTS_TOKEN (default
# GH_TOKEN), MONITOR_ISSUE_REPO and ISSUE_TOKEN (see monitor-issue.sh),
# MONITOR_SCRIPTS_DIR (default: this script's directory).
# The report goes to $GITHUB_STEP_SUMMARY, or to stdout if that is not set.
# Exit status: 1 if a red finding is left or the issue update failed.
set -euo pipefail

DIR=${MONITOR_SCRIPTS_DIR:-$(dirname "${BASH_SOURCE[0]}")}
# shellcheck source=scripts/monitor-lib.sh
source "$DIR/monitor-lib.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export FINDINGS="$WORK/findings.jsonl"
export INVENTORY="$WORK/inventory.json"
export CONFIG="$WORK/config.json"
: >"$FINDINGS"

CONFIG_FILE=${MONITOR_CONFIG:-repos.yml}
EMPTY_CONFIG='{"version":1,"lists":{},"mirrors":[],"forks":[],"ignores":[]}'

# --- control file ------------------------------------------------------
if err=$("$DIR/monitor-config.sh" validate "$CONFIG_FILE" 2>&1 >/dev/null) &&
  yq -o=json '.' "$CONFIG_FILE" >"$CONFIG" 2>/dev/null; then
  :
else
  line=$(head -n1 <<<"$err")
  line=${line#error: }
  line=${line#"$CONFIG_FILE": }
  finding red config-invalid - "$(basename "$CONFIG_FILE"): ${line:-invalid}"
  printf '%s\n' "$EMPTY_CONFIG" >"$CONFIG"
fi

# --- inventory ---------------------------------------------------------
if ! "$DIR/monitor-repos.sh" >"$INVENTORY"; then
  finding red check-failed - "monitor-repos.sh crashed"
  echo '[]' >"$INVENTORY"
fi

# --- checks ------------------------------------------------------------
for check in release settings health forks mirrors lists; do
  script=monitor-$check.sh
  if ! LISTS_TOKEN=${LISTS_TOKEN:-${GH_TOKEN:-}} "$DIR/$script" >/dev/null 2>&1; then
    finding red check-failed - "$script crashed"
  fi
done

# --- report ------------------------------------------------------------
status=0
report_rc=0
title=
"$DIR/monitor-report.sh" >"$WORK/report.md" 2>/dev/null || report_rc=$?
if ((report_rc > 1)); then
  echo "error: monitor-report.sh crashed" >&2
  printf '## Maintenance monitor\n\nThe report script crashed, see the run log.\n' >"$WORK/report.md"
  title='Maintenance monitor: report crashed'
  status=1
elif ((report_rc == 1)); then
  status=1
fi
cat "$WORK/report.md" >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# --- overview issue ----------------------------------------------------
if [[ -n ${MONITOR_ISSUE_REPO:-} ]]; then
  if [[ -z $title ]]; then
    title='Maintenance monitor'
    counts=$(grep -m1 -E '^[0-9]+ red · [0-9]+ info' "$WORK/report.md" || true)
    if [[ $counts =~ ^([0-9]+)\ red\ ·\ ([0-9]+)\ info ]]; then
      title="Maintenance monitor: ${BASH_REMATCH[1]} red · ${BASH_REMATCH[2]} info"
    fi
  fi
  if ! "$DIR/monitor-issue.sh" "$WORK/report.md" "$title" 2>"$WORK/issue.err" >/dev/null; then
    line=$(head -n1 "$WORK/issue.err")
    echo "${line:-error: monitor-issue.sh failed}" >&2
    status=1
  fi
fi

exit "$status"
