#!/usr/bin/env bash
# GitHub Lists drift (list-none, list-contradiction, list-mirror-missing,
# list-archived, config-invalid for unknown list names) and release-flow
# adoption. Writes findings only. Env: FINDINGS INVENTORY CONFIG (file paths),
# optional LISTS_TOKEN (used as GH_TOKEN for the GraphQL call only).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

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

# Prints TSV lines "level check repo message" for every list finding.
list_findings() {
  jq -r --slurpfile inv "$INVENTORY" --slurpfile cfg "$CONFIG" '
    ($cfg[0].lists // {}) as $cl |
    . as $lists |
    ([$lists[].name]) as $have |
    ([($cl.exclusive // [])[][], $cl.archive, $cl.mirrors, ($cl.forks // [])[]] |
      map(select(. != null)) | unique) as $used |
    ($used - $have) as $missing |
    def ok($n): ($missing | index($n)) == null;
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
    (($cl.exclusive // [])[] | select(ok(.[0]) and ok(.[1])) | . as [$a, $b] |
      $inv[0][] | .name as $r | inlists($r) as $in |
      select(($in | index($a)) != null and ($in | index($b)) != null) |
      row("info"; "list-contradiction"; $r; "in \"\($a)\" and \"\($b)\"")),
    (select($cl.mirrors != null and ok($cl.mirrors)) | $cl.mirrors as $m |
      ($cfg[0].mirrors // [])[] | .target as $t |
      select(inlists($t) | index($m) == null) |
      row("info"; "list-mirror-missing"; $t; "mirror target not in \"\($m)\"")),
    (select($cl.archive != null and ok($cl.archive)) |
      [$lists[] | select(.name != $cl.archive) | .name as $n |
        .items[] | select(.archived) | {repo, n: $n}] |
      group_by(.repo)[] |
      row("info"; "list-archived"; .[0].repo;
        "archived, still in " + (map("\"\(.n)\"") | join(", "))))
  ' "$1"
}

check_adoption() {
  local out
  if ! out=$(jq -r --slurpfile cfg "$CONFIG" '
      ([$cfg[0].mirrors // [] | .[].target]) as $m |
      [.[] | select(.name != "spali/.github" and .fork == false and .central == false and ([.name] | inside($m) | not))] |
      (map(select(.private | not) | .name) | sort | join(", ")) as $pub |
      (map(select(.private)) | length) as $priv |
      select(length > 0) |
      "\(length) own repositories without the shared release flow: \($pub)" +
        (if $priv > 0 then " (+\($priv) private)" else "" end)' "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "adoption: cannot parse inventory"
    return 0
  fi
  [[ -z $out ]] || finding info adoption - "$out"
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
}

main
