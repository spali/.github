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
      branches: ((.branches // {}) | to_entries | sort_by(.key)
        | map({name: .key, onto: .value.onto, rebase: (.value.rebase // "manual")})),
      follow: (.follow // []),
      tags: (.tags != false),
      settings: ($defaults + (.settings // {})),
      private: (.private // false)
    }'

# managed_entries CONFIG_JSON_FILE prints one normalized JSON object per line.
managed_entries() {
  [[ -r ${1:-} ]] || die "managed_entries: cannot read ${1:-}"
  jq -c --argjson defaults "$MANAGED_DEFAULT_SETTINGS" "$MANAGED_JQ" "$1"
}

# SYNC_REPO_JOB_RE: a job of sync.yml that syncs one repository, named
# "Sync · <owner/name>" with any (or no) "<caller job> / " prefix.
SYNC_REPO_JOB_RE='^(?:.* / )?Sync · (?<r>.+)$'

# check_sync_failed CONFIG_JSON_FILE: with at least one managed entry, reads
# the newest completed runs of the workflow sync.yml on main of the control
# repository ($GITHUB_REPOSITORY; unset: skip finding), newest first. Per
# managed repository the newest job "Sync · <repo>" that succeeded or failed
# counts (cancelled or skipped jobs are passed over); a failed one is a red
# finding of that repository. A job of the newest run that is not a repository
# job (the plan job) and did not succeed is a red finding without repository.
# Stops reading runs once every managed repository has a result; a repository
# without a job (or no run at all) is no finding. Runs once per monitor run.
check_sync_failed() {
  local open body runs id run_url step failed first=1 repo url
  json_out sync-failed - open -c '[(.managed // [])[].repo]' "$1" || return 0
  [[ $open != '[]' ]] || return 0
  if [[ -z ${GITHUB_REPOSITORY:-} ]]; then
    finding skip sync-failed - "sync-failed: no control repository (local run)"
    return 0
  fi
  body=$(fetch sync-failed - \
    "repos/$GITHUB_REPOSITORY/actions/workflows/sync.yml/runs?per_page=20&status=completed&branch=main") || return 0
  json_out sync-failed - runs -r '.workflow_runs // [] | .[] | "\(.id)\t\(.html_url)"' <<<"$body" || return 0
  while IFS=$'\t' read -r id run_url; do
    [[ -n $id ]] || continue
    body=$(fetch sync-failed - "repos/$GITHUB_REPOSITORY/actions/runs/$id/jobs?per_page=100") || return 0
    if [[ -n $first ]]; then
      first=
      # shellcheck disable=SC2016 # jq program
      json_out sync-failed - failed -r --arg re "$SYNC_REPO_JOB_RE" '
        any(.jobs // [] | .[]; (.name | test($re) | not) and .conclusion != "success")' <<<"$body" || return 0
      [[ $failed != true ]] ||
        finding red sync-failed - "sync run failed before the repositories: $run_url"
    fi
    # {done: repos with a result in this run, failed: [[repo, job url]]}
    # shellcheck disable=SC2016 # jq program
    json_out sync-failed - step -c --arg re "$SYNC_REPO_JOB_RE" --argjson open "$open" '
      [.jobs // [] | .[] | (.name | capture($re).r) as $r
        | select(IN($r; $open[]) and (.conclusion == "success" or .conclusion == "failure"))
        | {r: $r, conclusion, html_url}]
      | unique_by(.r)
      | {done: map(.r), failed: map(select(.conclusion == "failure") | [.r, .html_url])}' <<<"$body" || return 0
    json_out sync-failed - failed -r '.failed[] | @tsv' <<<"$step" || return 0
    while IFS=$'\t' read -r repo url; do
      [[ -z $repo ]] || finding red sync-failed "$repo" "last sync of this repository failed: $url"
    done <<<"$failed"
    # shellcheck disable=SC2016 # jq program
    json_out sync-failed - open -c --argjson open "$open" '$open - .done' <<<"$step" || return 0
    [[ $open != '[]' ]] || return 0
  done <<<"$runs"
}

# managed_entry CONFIG_JSON_FILE REPO prints the object of one repo, or fails.
managed_entry() {
  local entries entry
  entries=$(managed_entries "$1") || return 1
  entry=$(jq -c --arg repo "$2" 'select(.repo == $repo)' <<<"$entries")
  [[ -n $entry ]] || return 1
  printf '%s\n' "$entry"
}
