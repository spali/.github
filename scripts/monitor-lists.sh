#!/usr/bin/env bash
# GitHub Lists drift (list-none, list-contradiction, list-external-own,
# config-invalid for unknown list names) and release-flow adoption, and
# sync-failed (forks-lib.sh; here because it runs once). Archived
# repositories (snapshots) go in the same Lists as active ones and get the
# same checks. Forks and repositories under `forks:` belong in a forks List
# (lists.forks); own repositories do not belong in lists.external. Writes
# findings only. Env:
# FINDINGS INVENTORY CONFIG (file paths), optional ARCHIVED (JSON array of
# the archived repositories as {name, fork}; missing, empty or unreadable:
# none), LISTS_TOKEN (used as GH_TOKEN for the GraphQL call only),
# GITHUB_REPOSITORY (the control repository, for sync-failed).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/forks-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/forks-lib.sh"

need_env FINDINGS INVENTORY CONFIG

OWNER=spali
QUERY='query { user(login: "spali") { lists(first: 50) { pageInfo { hasNextPage } nodes { name items(first: 100) { pageInfo { hasNextPage } nodes { ... on Repository { nameWithOwner isArchived } } } } } } }'

# Reads the lists once into FILE as [{name, items: [{repo, archived}]}], own
# repositories only. Returns 1 when the lists are unavailable.
fetch_lists() {
  local body trimmed
  body=$(GH_TOKEN="${LISTS_TOKEN:-${GH_TOKEN:-}}" fetch list-none - graphql -f query="$QUERY") || return 1
  if jq -e '[.data.user.lists | .pageInfo.hasNextPage, (.nodes[].items.pageInfo.hasNextPage)] | any(. == true)' \
    >/dev/null 2>&1 <<<"$body"; then
    finding red check-failed - "lists: more than 50 lists or 100 items in a list, not all read"
    return 1
  fi
  if ! trimmed=$(jq --arg o "$OWNER/" '
      [.data.user.lists.nodes[] | {name, items: [.items.nodes[] |
        select((.nameWithOwner // "") | startswith($o)) |
        {repo: .nameWithOwner, archived: (.isArchived // false)}]}]' 2>/dev/null <<<"$body"); then
    parse_failed list-none -
    return 1
  fi
  printf '%s\n' "$trimmed" >"$1"
}

# archived_repos prints the repositories in $ARCHIVED as one JSON array of
# {name, fork}, [] when the file is unset, missing, empty or not a JSON array.
archived_repos() {
  local repos
  if [[ -n ${ARCHIVED:-} && -r $ARCHIVED ]] &&
    repos=$(jq -ce 'select(type == "array") | map(objects | select(.name | type == "string") | {name, fork: (.fork == true)})' "$ARCHIVED" 2>/dev/null); then
    printf '%s\n' "$repos"
  else
    echo '[]'
  fi
}

# Prints TSV lines "level check repo message" for every list finding.
list_findings() {
  local arch
  arch=$(archived_repos)
  jq -r --slurpfile inv "$INVENTORY" --slurpfile cfg "$CONFIG" --argjson arch "$arch" '
    ($cfg[0].lists // {}) as $cl |
    (($cl.forks // []) | unique) as $ml |
    ($cl.external // []) as $el |
    [($cfg[0].forks // [])[].repo | ascii_downcase] as $known |
    ([$inv[0][] | {name, fork}] + $arch) as $repos |
    . as $lists |
    ([$lists[].name]) as $have |
    ([($cl.exclusive // [])[][], $ml[], $el[]] | unique) as $used |
    ($used - $have) as $missing |
    def ok($n): ($missing | index($n)) == null;
    def inlists($r): [$lists[] | select(any(.items[]; .repo == $r)) | .name];
    def items($n): [$lists[] | select(.name == $n) | .items[] | .repo] | unique[];
    def row($l; $c; $r; $m): [$l, $c, $r, $m] | @tsv;
    ($missing[] | row("red"; "config-invalid"; "-"; "list \"\(.)\" not found on GitHub")),
    (($ml | length > 0) as $ml_set | ($ml | all(.[]; ok(.))) as $ml_ok |
      $repos[] | . as $i | inlists($i.name) as $in |
      if $ml_set and ($i.fork or ($i.name | ascii_downcase | IN($known[]))) then
        if $ml_ok and ($in | any(.[]; IN($ml[])) | not)
        then row("info"; "list-none"; $i.name; "in none of the forks lists") else empty end
      elif ($in | length) == 0 then row("info"; "list-none"; $i.name; "in no list")
      else empty end),
    (($cl.exclusive // [])[] | select(ok(.[0]) and ok(.[1])) | . as [$a, $b] |
      $repos[] | .name as $r | inlists($r) as $in |
      select(($in | index($a)) != null and ($in | index($b)) != null) |
      row("info"; "list-contradiction"; $r; "in \"\($a)\" and \"\($b)\"")),
    ($el | unique[] | select(ok(.)) | . as $e | items($e) |
      row("info"; "list-external-own"; .; "own repository in \"\($e)\""))
  ' "$1"
}

check_adoption() {
  local out repo
  if ! out=$(jq -r --slurpfile cfg "$CONFIG" '
      [$cfg[0].forks // [] | .[].repo | ascii_downcase] as $m |
      [.[] | select(.name != "spali/.github" and .fork == false and .central == false and ((.pins // []) | length == 0) and (.name | ascii_downcase | IN($m[]) | not)) | .name] |
      sort[]' "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "adoption: cannot parse inventory"
    return 0
  fi
  while IFS= read -r repo; do
    [[ -z $repo ]] || finding info adoption "$repo" "no central release flow"
  done <<<"$out"
}

main() {
  local tmp rows level check repo message
  tmp=$(mktemp)
  if fetch_lists "$tmp"; then
    if rows=$(list_findings "$tmp" 2>/dev/null); then
      while IFS=$'\t' read -r level check repo message; do
        [[ -n $level ]] || continue
        finding "$level" "$check" "$repo" "$message"
      done <<<"$rows"
    else
      parse_failed list-none -
    fi
  fi
  rm -f "$tmp"
  check_adoption
  check_sync_failed "$CONFIG" "$INVENTORY"
  local names
  names=$(jq -r '.[].name' "$INVENTORY" 2>/dev/null) || names=
  while IFS= read -r repo; do
    [[ -z $repo ]] || checked "$repo"
  done <<<"$names"
}

main
