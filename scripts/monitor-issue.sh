#!/usr/bin/env bash
# Keeps the overview issue of the maintenance monitor up to date.
#
#   monitor-issue.sh REPORT_FILE TITLE
#
# Writes the report into the open issue labelled maintenance-monitor of
# $MONITOR_ISSUE_REPO (the lowest number if there are several), or creates it.
# Creates the label if it is missing. The report is split at its line MARK:
# the part above is the issue body (plus POINTER, kept also when the body is
# cut), the part from MARK on is the monitor comment: the oldest comment of
# the issue by MONITOR_COMMENT_AUTHOR whose first line is MARK (updated in
# place, created if there is none; other comments are left alone). Without
# MARK the whole report is the body and no comment is touched. Issue, label
# and that comment are the only things the monitor ever writes. The report
# needs no footer (its summary line carries the time and the run link).
# Env: MONITOR_ISSUE_REPO (owner/name), ISSUE_TOKEN (used as GH_TOKEN for the
# gh calls of this script only), MONITOR_COMMENT_AUTHOR (login of the monitor
# comment's author, default github-actions[bot], the author with the
# workflow's GITHUB_TOKEN; empty: any author, for a local run with a
# personal token).
# Failure: one "error: ..." line on stderr, exit 1.
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

LABEL=maintenance-monitor
LIMIT=65536 # GitHub's limit for an issue or comment body; counted in bytes to be safe
NOTE='… truncated, see the run summary.'
MARK='<!-- maintenance-monitor:details -->'
POINTER='Details (red, info, clean, not checked) are in the monitor comment below.'
AUTHOR=${MONITOR_COMMENT_AUTHOR-github-actions[bot]}

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

# split_report writes the issue text to $WORK/text.md and, if the report has
# the line MARK, the details from that line on to $WORK/details.md.
split_report() {
  local n
  n=$(grep -nxF -m1 -- "$MARK" "$REPORT" | cut -d: -f1 || true)
  if [[ -z $n ]]; then
    cp "$REPORT" "$WORK/text.md"
    return 0
  fi
  head -n "$((n - 1))" "$REPORT" >"$WORK/text.md"
  tail -n "+$n" "$REPORT" >"$WORK/details.md"
}

# build_body SRC DST [MAX] writes SRC to DST; a SRC above MAX bytes (default
# LIMIT) is cut at a line boundary, every <details> block left open by the cut
# is closed (after an empty line, which also ends a table), and NOTE follows.
build_body() {
  local src=$1 dst=$2 max=${3:-$LIMIT} size budget open closing
  size=$(LC_ALL=C wc -c <"$src")
  if ((size <= max)); then
    cat "$src" >"$dst"
    return 0
  fi
  printf '\n%s\n' "$NOTE" >"$WORK/tail.md"
  budget=$((max - $(LC_ALL=C wc -c <"$WORK/tail.md")))
  while :; do
    head -c "$budget" "$src" >"$WORK/cut.md"
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
    ((size > max)) || break
    budget=$((budget - (size - max)))
  done
  cat "$WORK/cut.md" "$WORK/close.md" "$WORK/tail.md" >"$dst"
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

# find_comment NUMBER prints the id of the oldest comment of the issue by
# AUTHOR (any author if empty) whose first line is MARK, or nothing.
find_comment() {
  gh api "repos/$REPO/issues/$1/comments?per_page=100" --paginate \
    >"$WORK/comments.json" 2>"$WORK/err" ||
    die "listing comments of issue #$1 failed: $(err_line "$WORK/err")"
  jq -rs --arg mark "$MARK" --arg author "$AUTHOR" 'add // []
    | map(select(($author == "" or .user.login == $author)
        and ((.body // "") | split("\n")[0] | rtrimstr("\r")) == $mark))
    | sort_by(.id) | .[0].id // empty' "$WORK/comments.json" 2>/dev/null ||
    die "listing comments of issue #$1 failed: cannot parse API response"
}

# write_comment NUMBER NEW: the monitor comment of the issue gets
# $WORK/details.md (NEW=1: the issue was just created, it has no comments).
write_comment() {
  local number=$1 id=
  build_body "$WORK/details.md" "$WORK/comment.md"
  jq -n --rawfile body "$WORK/comment.md" '{body: $body}' >"$WORK/request.json"
  [[ $2 == 1 ]] || id=$(find_comment "$number")
  if [[ -n $id ]]; then
    gh_write "updating the monitor comment of issue #$number" -X PATCH \
      "repos/$REPO/issues/comments/$id" --input "$WORK/request.json"
  else
    gh_write "creating the monitor comment of issue #$number" -X POST \
      "repos/$REPO/issues/$number/comments" --input "$WORK/request.json"
  fi
}

main() {
  local number new=0
  ensure_label
  number=$(find_issue)
  split_report
  if [[ -e $WORK/details.md ]]; then
    # POINTER goes after the cut, in a paragraph of its own; its bytes are
    # reserved
    printf '\n%s\n' "$POINTER" >"$WORK/pointer.md"
    build_body "$WORK/text.md" "$WORK/body.md" "$((LIMIT - $(LC_ALL=C wc -c <"$WORK/pointer.md")))"
    if [[ -z $(tail -c2 "$WORK/body.md" | tr -d '\n') ]]; then
      printf '%s\n' "$POINTER" >>"$WORK/body.md"
    else
      cat "$WORK/pointer.md" >>"$WORK/body.md"
    fi
  else
    build_body "$WORK/text.md" "$WORK/body.md"
  fi
  if [[ -n $number ]]; then
    jq -n --rawfile body "$WORK/body.md" --arg title "$TITLE" \
      '{title: $title, body: $body}' >"$WORK/request.json"
    gh_write "updating issue #$number" -X PATCH "repos/$REPO/issues/$number" --input "$WORK/request.json"
  else
    jq -n --rawfile body "$WORK/body.md" --arg title "$TITLE" --arg label "$LABEL" \
      '{title: $title, body: $body, labels: [$label]}' >"$WORK/request.json"
    gh api -X POST "repos/$REPO/issues" --input "$WORK/request.json" >"$WORK/created.json" 2>"$WORK/err" ||
      die "creating the issue failed: $(err_line "$WORK/err")"
    new=1
  fi
  [[ -e $WORK/details.md ]] || return 0
  if ((new)); then
    number=$(jq -er '.number | numbers' "$WORK/created.json" 2>/dev/null) ||
      die "creating the issue failed: cannot parse API response"
  fi
  write_comment "$number" "$new"
}

main
