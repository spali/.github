#!/usr/bin/env bash
# Mirror check: every branch and tag of the source must exist with the same
# sha in the mirror target (extra target refs are ignored). mirror-behind is
# red only when the target was last pushed more than interval_hours + 24 h ago.
# Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

# ls_remote URL OUTFILE writes "<ref> <sha>" lines (peeled ^{} refs dropped).
ls_remote() {
  local raw
  raw=$(mktemp)
  if ! GIT_TERMINAL_PROMPT=0 timeout 120 git ls-remote --heads --tags "$1" >"$raw" 2>/dev/null; then
    rm -f "$raw"
    return 1
  fi
  awk -F'\t' 'NF == 2 && $2 !~ /\^\{\}$/ {print $2, $1}' "$raw" >"$2"
  rm -f "$raw"
}

# api_refs REPO OUTFILE: the same list for a private repository via the API.
api_refs() {
  local kind part
  : >"$2"
  for kind in heads tags; do
    part=$(mktemp)
    if ! paged mirror-behind "$1" "repos/$1/git/matching-refs/$kind" \
      '{ref, sha: .object.sha}' "$part"; then
      rm -f "$part"
      return 1
    fi
    if ! jq -r '.[] | "\(.ref) \(.sha)"' "$part" >>"$2" 2>/dev/null; then
      parse_failed mirror-behind "$1"
      rm -f "$part"
      return 1
    fi
    rm -f "$part"
  done
}

check_mirror() {
  local target=$1 source=$2 hours=$3 info private pushed src tgt n age
  if ! info=$(jq -r --arg t "$target" '
      .[] | select(.name == $t) | [.private, .pushed_at] | @tsv' "$INVENTORY" 2>/dev/null); then
    parse_failed mirror-behind "$target"
    return 0
  fi
  if [[ -z $info ]]; then
    finding red check-failed "$target" "mirror-behind: target not visible"
    return 0
  fi
  IFS=$'\t' read -r private pushed <<<"$info"
  src=$(mktemp)
  tgt=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$src' '$tgt'; trap - RETURN" RETURN
  if ! ls_remote "$source" "$src"; then
    finding red check-failed "$target" "mirror-behind: cannot read source"
    return 0
  fi
  if [[ $private == true ]]; then
    api_refs "$target" "$tgt" || return 0
  elif ! ls_remote "https://github.com/$target.git" "$tgt"; then
    finding red check-failed "$target" "mirror-behind: cannot read target"
    return 0
  fi
  n=$(awk 'FILENAME == ARGV[1] {t[$1] = $2; next} t[$1] != $2 {n++} END {print n + 0}' "$tgt" "$src")
  ((n > 0)) || return 0
  age=$(((${MONITOR_NOW:-$(date -u +%s)} - $(date -u -d "$pushed" +%s)) / 3600))
  if ((age > hours + 24)); then
    finding red mirror-behind "$target" "$n refs differ, last push $pushed"
  fi
}

main() {
  local mirrors target source hours
  if ! mirrors=$(jq -r '.mirrors // [] | .[] |
      [.target, .source, .interval_hours] | @tsv' "$CONFIG" 2>/dev/null); then
    finding red check-failed - "mirror checks: cannot parse config"
    return 0
  fi
  while IFS=$'\t' read -r target source hours; do
    [[ -n $target ]] || continue
    checked "$target"
    check_mirror "$target" "$source" "$hours"
  done <<<"$mirrors"
}

main
