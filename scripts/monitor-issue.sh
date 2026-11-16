#!/usr/bin/env bash
# Keeps the overview issue of the maintenance monitor up to date.
#
#   monitor-issue.sh REPORT_FILE TITLE
#
# Writes the report into the open issue labelled maintenance-monitor of
# $MONITOR_ISSUE_REPO (the lowest number if there are several), or creates it.
# Creates the label if it is missing. This is the only thing the monitor ever
# writes. The body is the report as it is (its summary line carries the time
# and the run link). Env: MONITOR_ISSUE_REPO (owner/name), ISSUE_TOKEN (used
# as GH_TOKEN for the gh calls of this script only).
# Failure: one "error: ..." line on stderr, exit 1.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

LABEL=maintenance-monitor
LIMIT=65536 # GitHub's limit for an issue body; counted in bytes to be safe
NOTE='… truncated, see the run summary.'

REPORT=${1:-}
TITLE=${2:-}
[[ -n $REPORT && -n $TITLE ]] || die "usage: monitor-issue.sh REPORT_FILE TITLE"
[[ -r $REPORT ]] || die "$REPORT: cannot read file"
need_env MONITOR_ISSUE_REPO ISSUE_TOKEN

export GH_TOKEN=$ISSUE_TOKEN
REPO=$MONITOR_ISSUE_REPO

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# gh_write DESCRIPTION ARGS... runs gh api ARGS, discarding its output; on
# failure dies with the line of stderr that names the error.
gh_write() {
  local what=$1
  shift
  gh api "$@" >/dev/null 2>"$WORK/err" || die "$what failed: $(err_line "$WORK/err")"
}

# ensure_label creates the label when GET answers 404.
ensure_label() {
  if gh api "repos/$REPO/labels/$LABEL" >/dev/null 2>"$WORK/err"; then
    return 0
  fi
  grep -qF '(HTTP 404)' "$WORK/err" || die "reading label $LABEL failed: $(err_line "$WORK/err")"
  gh_write "creating label $LABEL" -X POST "repos/$REPO/labels" \
    -f name="$LABEL" -f color=0e8a16 -f description="Overview of the maintenance monitor"
}

# build_body writes the issue body to $WORK/body.md: the report; a report
# that does not fit is cut at a line boundary, every <details> block left open
# by the cut is closed (after an empty line, which also ends a table), and
# NOTE follows.
build_body() {
  local size budget open closing
  size=$(LC_ALL=C wc -c <"$REPORT")
  if ((size <= LIMIT)); then
    cat "$REPORT" >"$WORK/body.md"
    return 0
  fi
  printf '\n%s\n' "$NOTE" >"$WORK/tail.md"
  budget=$((LIMIT - $(LC_ALL=C wc -c <"$WORK/tail.md")))
  while :; do
    head -c "$budget" "$REPORT" >"$WORK/cut.md"
    # the last line of the cut is partial unless the cut ends with a newline
    if [[ -n $(tail -c1 "$WORK/cut.md") ]]; then
      head -n -1 "$WORK/cut.md" >"$WORK/cut2.md"
      mv "$WORK/cut2.md" "$WORK/cut.md"
    fi
    open=$(($(grep -c '^<details' "$WORK/cut.md" || true) - $(grep -c '^</details>$' "$WORK/cut.md" || true)))
    closing=
    while ((open-- > 0)); do closing+=$'\n</details>\n'; done
    printf '%s' "$closing" >"$WORK/close.md"
    size=$(($(LC_ALL=C wc -c <"$WORK/cut.md") + $(LC_ALL=C wc -c <"$WORK/close.md") + $(LC_ALL=C wc -c <"$WORK/tail.md")))
    ((size > LIMIT)) || break
    budget=$((budget - (size - LIMIT)))
  done
  cat "$WORK/cut.md" "$WORK/close.md" "$WORK/tail.md" >"$WORK/body.md"
}

# find_issue prints the lowest number of the open issues with the label
# (pull requests excluded), or nothing.
find_issue() {
  gh api "repos/$REPO/issues?state=open&labels=$LABEL&per_page=100" --paginate \
    >"$WORK/issues.json" 2>"$WORK/err" ||
    die "listing issues failed: $(err_line "$WORK/err")"
  jq -rs 'add // [] | map(select(.pull_request == null)) | sort_by(.number)
    | .[0].number // empty' "$WORK/issues.json" 2>/dev/null ||
    die "listing issues failed: cannot parse API response"
}

main() {
  local number
  ensure_label
  number=$(find_issue)
  build_body
  if [[ -n $number ]]; then
    jq -n --rawfile body "$WORK/body.md" --arg title "$TITLE" \
      '{title: $title, body: $body}' >"$WORK/request.json"
    gh_write "updating issue #$number" -X PATCH "repos/$REPO/issues/$number" --input "$WORK/request.json"
  else
    jq -n --rawfile body "$WORK/body.md" --arg title "$TITLE" --arg label "$LABEL" \
      '{title: $title, body: $body, labels: [$label]}' >"$WORK/request.json"
    gh_write "creating the issue" -X POST "repos/$REPO/issues" --input "$WORK/request.json"
  fi
}

main
