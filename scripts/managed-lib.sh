# Managed repositories (key `managed:` of the control file), sourced by scripts.
# shellcheck shell=bash
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

MANAGED_DEFAULT_SETTINGS='{"has_issues":false,"has_pull_requests":false,"has_wiki":false,"has_discussions":false,"has_projects":false,"actions":false}'

# JQ program: one normalized object per managed entry of the config on stdin.
# Argument: $defaults (default settings). Entries are assumed validated.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
MANAGED_JQ='
def gh: capture("^https://github\\.com/(?<o>[^/]+)/(?<n>[^/]+?)(\\.git)?/?$"; "i");
(.managed // [])[] |
  (.upstream | test("^https://github\\.com(/|$)"; "i")) as $fork
  | {
      repo,
      upstream,
      kind: (if $fork then "fork" else "mirror" end),
      upstream_repo: (if $fork then (.upstream | gh | "\(.o)/\(.n)") else null end),
      refs: (if $fork then (.refs // "default") else "all" end),
      branches: ((.branches // {}) | to_entries | sort_by(.key)
        | map({name: .key, onto: .value.onto, rebase: (.value.rebase // "manual")})),
      follow: (.follow // []),
      settings: ($defaults + (.settings // {})),
      private: (.private // false)
    }'

# managed_entries CONFIG_JSON_FILE prints one normalized JSON object per line.
managed_entries() {
  [[ -r ${1:-} ]] || die "managed_entries: cannot read ${1:-}"
  jq -c --argjson defaults "$MANAGED_DEFAULT_SETTINGS" "$MANAGED_JQ" "$1"
}

# check_sync_failed CONFIG_JSON_FILE: with at least one managed entry, the
# newest completed run of the workflow sync.yml in the control repository
# ($GITHUB_REPOSITORY; unset: skip finding) must have succeeded. No run yet
# is no finding. Findings have no repository.
check_sync_failed() {
  local n body url
  json_out sync-failed - n '(.managed // []) | length' "$1" || return 0
  ((n > 0)) || return 0
  if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
    finding skip sync-failed - "sync-failed: no control repository (local run)"
    return 0
  fi
  body=$(fetch sync-failed - \
    "repos/$GITHUB_REPOSITORY/actions/workflows/sync.yml/runs?per_page=1&status=completed") || return 0
  # shellcheck disable=SC2016 # jq program
  json_out sync-failed - url -r '
    .workflow_runs // [] | first // empty | select(.conclusion != "success") | .html_url' <<<"$body" || return 0
  [[ -z $url ]] || finding red sync-failed - "last sync run failed: $url"
}

# managed_entry CONFIG_JSON_FILE REPO prints the object of one repo, or fails.
managed_entry() {
  local entries entry
  entries=$(managed_entries "$1") || return 1
  entry=$(jq -c --arg repo "$2" 'select(.repo == $repo)' <<<"$entries")
  [[ -n $entry ]] || return 1
  printf '%s\n' "$entry"
}
