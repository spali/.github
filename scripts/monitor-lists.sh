#!/usr/bin/env bash
# GitHub Lists drift (list-none, list-contradiction, list-mirror-missing,
# list-archived, unmanaged, config-invalid for unknown list names) and
# release-flow adoption, and sync-failed (managed-lib.sh; here because it runs
# once). Archived repositories are judged only by the archive Lists
# (lists.archived). Writes findings only. Env: FINDINGS INVENTORY CONFIG (file
# paths), optional ARCHIVED (JSON array of the archived repository names;
# missing, empty or unreadable: none), LISTS_TOKEN (used as GH_TOKEN for the
# GraphQL call only), GITHUB_REPOSITORY (the control repository, for
# sync-failed).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/managed-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/managed-lib.sh"

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

# archived_names prints the names in $ARCHIVED as one JSON array, [] when the
# file is unset, missing, empty or not a JSON array.
archived_names() {
  local names
  if [[ -n ${ARCHIVED:-} && -r $ARCHIVED ]] &&
    names=$(jq -ce 'select(type == "array") | map(strings)' "$ARCHIVED" 2>/dev/null); then
    printf '%s\n' "$names"
  else
    echo '[]'
  fi
}

# Prints TSV lines "level check repo message" for every list finding.
list_findings() {
  local arch mirrors
  arch=$(archived_names)
  # mirrors: managed entries whose upstream is not on github.com
  mirrors=$(managed_entries "$CONFIG" | jq -sc '[.[] | select(.kind == "mirror") | .repo]') || return 1
  jq -r --slurpfile inv "$INVENTORY" --slurpfile cfg "$CONFIG" \
    --argjson arch "$arch" --argjson mirrors "$mirrors" '
    ($cfg[0].lists // {}) as $cl |
    ($cl.archived // []) as $al |
    . as $lists |
    ([$lists[].name]) as $have |
    ([($cl.exclusive // [])[][], $al[], $cl.mirrors, ($cl.forks // [])[]] |
      map(select(. != null)) | unique) as $used |
    ($used - $have) as $missing |
    def ok($n): ($missing | index($n)) == null;
    (($al | length) > 0 and ($al | all(.[]; ok(.)))) as $arch_ok |
    def inlists($r): [$lists[] | select(any(.items[]; .repo == $r)) | .name];
    def row($l; $c; $r; $m): [$l, $c, $r, $m] | @tsv;
    ($missing[] | row("red"; "config-invalid"; "-"; "list \"\(.)\" not found on GitHub")),
    ((($cl.forks // []) | all(.[]; ok(.))) as $forks_ok |
      (($cl.forks // []) | length > 0) as $forks_set |
      $inv[0][] | . as $i | inlists($i.name) as $in |
      if $i.fork and $forks_set then
        if $forks_ok and (($cl.forks // []) | all(.[]; . as $f | ($in | index($f)) == null))
        then row("info"; "list-none"; $i.name; "fork in none of the fork lists") else empty end
      elif ($in | length) == 0 then row("info"; "list-none"; $i.name; "in no list")
      else empty end),
    (select($arch_ok) | $arch[] | . as $r |
      select(inlists($r) | any(.[]; IN($al[])) | not) |
      row("info"; "list-none"; $r; "archived, in none of the archive lists")),
    (($cl.exclusive // [])[] | select(ok(.[0]) and ok(.[1])) | . as [$a, $b] |
      $inv[0][] | .name as $r | inlists($r) as $in |
      select(($in | index($a)) != null and ($in | index($b)) != null) |
      row("info"; "list-contradiction"; $r; "in \"\($a)\" and \"\($b)\"")),
    (select($cl.mirrors != null and ok($cl.mirrors)) | $cl.mirrors as $m |
      [$lists[] | select(.name == $m) | .items[].repo | ascii_downcase] as $inm |
      $mirrors[] | select(ascii_downcase | IN($inm[]) | not) |
      row("info"; "list-mirror-missing"; .; "managed mirror not in \"\($m)\"")),
    (select($cl.mirrors != null and ok($cl.mirrors)) | $cl.mirrors as $m |
      [($cfg[0].managed // [])[].repo | ascii_downcase] as $known |
      [$lists[] | select(.name == $m) | .items[] | select(.archived | not) | .repo] | unique[] |
      select(ascii_downcase | IN($known[]) | not) |
      row("info"; "unmanaged"; .; "in the mirrors list but not managed")),
    (select($arch_ok) |
      [$lists[] | select(.name | IN($al[]) | not) | .name as $n |
        .items[] | select(.archived) | {repo, n: $n}] |
      group_by(.repo)[] |
      row("info"; "list-archived"; .[0].repo;
        "archived, still in " + (map("\"\(.n)\"") | join(", "))))
  ' "$1"
}

check_adoption() {
  local out repo
  if ! out=$(jq -r --slurpfile cfg "$CONFIG" '
      [$cfg[0].managed // [] | .[].repo | ascii_downcase] as $m |
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
  check_sync_failed "$CONFIG"
  local names
  names=$(jq -r '.[].name' "$INVENTORY" 2>/dev/null) || names=
  while IFS= read -r repo; do
    [[ -z $repo ]] || checked "$repo"
  done <<<"$names"
}

main
