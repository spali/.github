# Forks and mirrors (key `forks:` of the control file plus the own forks on
# GitHub), sourced by scripts.
# shellcheck shell=bash
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

FORK_DEFAULT_SETTINGS='{"has_issues":false,"has_pull_requests":false,"has_wiki":false,"has_discussions":false,"has_projects":false,"actions":false}'

# JQ program: one normalized object per fork or mirror, for the config on
# stdin: every entry of `forks:`, then every fork of $inv (an inventory array
# [{name, fork, private, parent: {name}}], may be []) without an entry, with
# the defaults. The name is spelled as in $inv when it is there. Without `upstream:` the upstream is the parent of the
# inventory fork (null when unknown: the caller looks it up). Arguments:
# $defaults (default settings), $inv. Entries are assumed validated.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
FORKS_JQ='
def gh: capture("^https://github\\.com/(?<o>[^/]+)/(?<n>[^/]+?)(\\.git)?/?$"; "i");
(if ($inv | type) == "array" then $inv else [] end) as $inv |
[(.forks // [])[].repo | ascii_downcase] as $cfg |
((.forks // [])[],
 ($inv[] | select(.fork == true and (.name | ascii_downcase | IN($cfg[]) | not)) | {repo: .name})) |
  . as $e |
  ([$inv[] | select((.name | ascii_downcase) == ($e.repo | ascii_downcase))] | first) as $i |
  (.upstream // (if $i.parent.name then "https://github.com/\($i.parent.name)" else null end)) as $up |
  ($up != null and ($up | test("^https://github\\.com(/|$)"; "i"))) as $ongh
  | {
      repo: ($i.name // .repo),
      upstream: $up,
      kind: (if $up == null or $ongh then "fork" else "mirror" end),
      upstream_repo: (if $ongh then ($up | gh | "\(.o)/\(.n)") else null end),
      branches: ((.branches // {}) | to_entries | sort_by(.key)
        | map({name: .key, onto: .value.onto, rebase: (.value.rebase // "manual")})),
      follow: (.follow // []),
      tags: (.tags != false),
      settings: ($defaults + (.settings // {})),
      private: (if has("private") then .private else ($i.private // false) end),
      pinned: (.pinned == true)
    }'

# fork_entries CONFIG_JSON_FILE [INVENTORY_FILE] prints one normalized JSON
# object per line (pinned ones too).
fork_entries() {
  local inv='[]'
  [[ -r ${1:-} ]] || die "fork_entries: cannot read ${1:-}"
  if [[ -n ${2:-} ]]; then
    inv=$(jq -c . "$2") || die "fork_entries: cannot read $2"
  fi
  jq -c --argjson defaults "$FORK_DEFAULT_SETTINGS" --argjson inv "$inv" "$FORKS_JQ" "$1"
}

# fork_entry CONFIG_JSON_FILE REPO [INVENTORY_FILE] prints the object of one
# repository (matched case-insensitively), or fails.
fork_entry() {
  local entries entry
  entries=$(fork_entries "$1" "${3:-}") || return 1
  entry=$(jq -c --arg repo "$2" 'select((.repo | ascii_downcase) == ($repo | ascii_downcase))' <<<"$entries" | head -n 1)
  [[ -n $entry ]] || return 1
  printf '%s\n' "$entry"
}

# synced_repos CONFIG_JSON_FILE [INVENTORY_FILE] prints the names of the
# repositories the sync keeps current (not pinned) as one sorted JSON array.
synced_repos() {
  fork_entries "$@" | jq -sc '[.[] | select(.pinned | not) | .repo] | sort'
}

# SYNC_REPO_JOB_RE: a job of sync.yml that syncs one repository, named
# "Sync · <owner/name>" with any (or no) "<caller job> / " prefix.
SYNC_REPO_JOB_RE='^(?:.* / )?Sync · (?<r>.+)$'

# check_sync_failed CONFIG_JSON_FILE INVENTORY_FILE: with at least one synced
# repository (synced_repos), reads
# the newest completed runs of the workflow sync.yml on main of the control
# repository ($GITHUB_REPOSITORY; unset: skip finding), newest first. A job
# has a result unless its conclusion is cancelled, skipped or null (e.g. a run
# GitHub cancelled in the concurrency group); such jobs are passed over and an
# older job counts. Per synced repository the newest job "Sync · <repo>" with
# a result counts; anything but success (failure, timed_out, ...) is a red
# finding of that repository. The non-repository jobs (the plan job) of the
# newest run where one of them has a result must have succeeded, else a red
# finding without repository. Stops reading runs once every synced
# repository and the plan job have a result; a repository without a job (or
# no run at all) is no finding. A run with more jobs than one page is
# check-failed. Runs once per monitor run.
check_sync_failed() {
  local open body runs id run_url step page plan_state repo_failures plan=1 repo url
  if ! open=$(synced_repos "$1" "$2" 2>/dev/null); then
    finding red check-failed - "sync-failed: cannot read the forks"
    return 0
  fi
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
    # empty when the page holds every job, else "<total>, read <n>"
    # shellcheck disable=SC2016 # jq program
    json_out sync-failed - page -r '
      (.jobs // [] | length) as $n | select((.total_count // 0) > $n) | "\(.total_count), read \($n)"' <<<"$body" || return 0
    if [[ -n $page ]]; then
      finding red check-failed - "sync-failed: more jobs than one page ($page): $run_url"
      return 0
    fi
    # shellcheck disable=SC2016 # jq program
    json_out sync-failed - step -c --arg re "$SYNC_REPO_JOB_RE" --argjson open "$open" '
      def result: .conclusion | IN("cancelled", "skipped", null) | not;
      (.jobs // []) as $jobs
      | ([$jobs[] | select((.name | test($re) | not) and result)]
          | if length == 0 then "none" elif all(.conclusion == "success") then "ok" else "failed" end) as $plan
      | [$jobs[] | (.name | capture($re).r) as $r | select(IN($r; $open[]) and result)
          | {r: $r, conclusion, html_url}]
      | unique_by(.r)
      | {plan: $plan, done: map(.r), failed: map(select(.conclusion != "success") | [.r, .html_url])}' <<<"$body" || return 0
    if [[ -n $plan ]]; then
      # none (no plan job with a result), ok or failed
      json_out sync-failed - plan_state -r '.plan' <<<"$step" || return 0
      [[ $plan_state == none ]] || plan=
      [[ $plan_state != failed ]] ||
        finding red sync-failed - "sync run failed before the repositories: $run_url"
    fi
    json_out sync-failed - repo_failures -r '.failed[] | @tsv' <<<"$step" || return 0
    while IFS=$'\t' read -r repo url; do
      [[ -z $repo ]] || finding red sync-failed "$repo" "last sync of this repository failed: $url"
    done <<<"$repo_failures"
    # shellcheck disable=SC2016 # jq program
    json_out sync-failed - open -c --argjson open "$open" '$open - .done' <<<"$step" || return 0
    [[ $open != '[]' || -n $plan ]] || return 0
  done <<<"$runs"
}

LISTS_QUERY='query { user(login: "spali") { lists(first: 50) { pageInfo { hasNextPage } nodes { name items(first: 100) { pageInfo { hasNextPage } nodes { ... on Repository { nameWithOwner isArchived } } } } } } }'

# fetch_lists CHECK FILE [REPO] reads the GitHub Lists of spali into FILE as
# [{name, items: [{repo, archived}]}], own repositories only (token
# LISTS_TOKEN, else GH_TOKEN). Returns 1 when the lists are unavailable,
# after a check-failed finding of CHECK for REPO (default: none).
fetch_lists() {
  local check=$1 repo=${3:--} body trimmed
  body=$(GH_TOKEN="${LISTS_TOKEN:-${GH_TOKEN:-}}" fetch "$check" "$repo" graphql -f query="$LISTS_QUERY") || return 1
  if jq -e '[.data.user.lists | .pageInfo.hasNextPage, (.nodes[].items.pageInfo.hasNextPage)] | any(. == true)' \
    >/dev/null 2>&1 <<<"$body"; then
    finding red check-failed "$repo" "lists: more than 50 lists or 100 items in a list, not all read"
    return 1
  fi
  if ! trimmed=$(jq --arg o "spali/" '
      [.data.user.lists.nodes[] | {name, items: [.items.nodes[] |
        select((.nameWithOwner // "") | ascii_downcase | startswith($o)) |
        {repo: .nameWithOwner, archived: (.isArchived // false)}]}]' 2>/dev/null <<<"$body"); then
    parse_failed "$check" "$repo"
    return 1
  fi
  printf '%s\n' "$trimmed" >"$2"
}
