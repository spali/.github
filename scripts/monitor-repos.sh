#!/usr/bin/env bash
# Builds the monitor's repository inventory: prints a JSON array to stdout.
# Env: FINDINGS. In Actions (GITHUB_ACTIONS=true) the app's installation is
# listed; locally the user token lists all owned repositories. A repository is
# central when it pins a shared workflow other than the maintenance ones
# (monitor, its config check and the fork/mirror sync).
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS

# Whatever the tools print is discarded.
exec 2>/dev/null

OWNER=spali
PIN_RE='^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]+spali/\.github/\.github/workflows/([^@]+)@([0-9a-f]{40})( # (v[^ ]+))?'

# list_repos prints the owned, non-archived repositories as one JSON array.
list_repos() {
  local raw
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    raw=$(fetch check-failed - installation/repositories --paginate) || return 1
    jq -s 'map(.repositories) | add // []' <<<"$raw" || { parse_failed inventory -; return 1; }
  else
    raw=$(fetch check-failed - 'user/repos?affiliation=owner' --paginate) || return 1
    jq -s 'add // []' <<<"$raw" || { parse_failed inventory -; return 1; }
  fi
}

# Shared workflows of the maintenance tooling: pinning only these does not make
# a repository a release-flow (central) one.
MAINTENANCE_WORKFLOWS='["monitor.yml","monitor-config.yml","sync.yml"]'

# workflow_pins REPO BRANCH prints the central workflow pins as JSON lines
# and returns 1 when the workflow directory could not be read.
workflow_pins() {
  local repo=$1 branch=$2 errf listing err line names name raw match
  errf=$(mktemp)
  if ! listing=$(gh api "repos/$repo/contents/.github/workflows?ref=$branch" 2>"$errf"); then
    err=$(<"$errf")
    line=$(err_line "$errf")
    rm -f "$errf"
    if [[ $err == *'(HTTP 404)'* || $err == *'This repository is empty.'* ]]; then
      return 0
    fi
    finding red check-failed "$repo" "inventory: $line"
    return 1
  fi
  rm -f "$errf"
  names=$(jq -r '.[] | select(.type == "file" and (.name | test("\\.ya?ml$"))) | .name' <<<"$listing")
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    raw=$(fetch check-failed "$repo" -H 'Accept: application/vnd.github.raw' \
      "repos/$repo/contents/.github/workflows/$name?ref=$branch") || continue
    while IFS= read -r match; do
      [[ $match =~ $PIN_RE ]] || continue
      jq -cn --arg workflow "${BASH_REMATCH[2]}" --arg sha "${BASH_REMATCH[3]}" \
        --arg version "${BASH_REMATCH[5]}" \
        '{workflow: $workflow, sha: $sha, version: (if $version == "" then null else $version end)}'
    done < <(grep -E -- "$PIN_RE" <<<"$raw" || true)
  done <<<"$names"
}

main() {
  local repos name default_branch fork pins parent body entries=()
  if ! repos=$(list_repos); then
    echo '[]'
    return 0
  fi
  repos=$(jq -c --arg owner "$OWNER" \
    '[.[] | select(.owner.login == $owner and .archived == false)]' <<<"$repos")

  if [[ $(jq length <<<"$repos") -eq 0 ]]; then
    finding red check-failed - "inventory: no repositories visible"
    echo '[]'
    return 0
  fi

  while IFS=$'\t' read -r name default_branch fork; do
    pins=
    parent=null
    if [[ $fork == true ]]; then
      if body=$(fetch check-failed "$name" "repos/$name"); then
        parent=$(jq -c '.parent | if . then {name: .full_name, default_branch: .default_branch} else null end' <<<"$body")
      fi
    else
      pins=$(workflow_pins "$name" "$default_branch" || true)
    fi
    entries+=("$(jq -c --arg name "$name" --argjson parent "$parent" \
      --argjson pins "$(jq -s . <<<"$pins")" \
      --argjson maintenance "$MAINTENANCE_WORKFLOWS" \
      '.[] | select(.full_name == $name) |
       {name: .full_name, private, fork, default_branch, pushed_at,
        central: ($pins | any(.workflow | IN($maintenance[]) | not)), pins: $pins, parent: $parent}' <<<"$repos")")
  done < <(jq -r '.[] | [.full_name, .default_branch, .fork] | @tsv' <<<"$repos")

  printf '%s\n' "${entries[@]}" | jq -s 'sort_by(.name)'
}

main
