#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  FINDINGS="$BATS_TEST_TMPDIR/f.jsonl"
  INVENTORY="$BATS_TEST_TMPDIR/inventory.json"
  CONFIG="$BATS_TEST_TMPDIR/config.json"
  export FINDINGS INVENTORY CONFIG
  : >"$FINDINGS"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-lists.sh"
  unset GITHUB_REPOSITORY ARCHIVED LISTS
  STACK="🚀 My stack"
  ARCH="🗃️ My stack Archive"
  MIRR="👀  Mirrors"
  F1="▶️ Contribution forks"
  F2="♻️ Customization forks"
  PIN="📌 Pinned snapshots"
  EXT="🔍 Interesting and related"
  jq -n '{lists: {exclusive: [["▶️ Contribution forks", "♻️ Customization forks"]],
      forks: ["👀  Mirrors", "▶️ Contribution forks", "♻️ Customization forks"],
      external: ["🔍 Interesting and related"]}}' >"$CONFIG"
  inv spali/a false false true
}

# inv NAME... : inventory of compliant (central) repos, "name private fork".
inv() {
  jq -n --arg n "$1" --argjson p "$2" --argjson f "$3" --argjson c "$4" \
    '[{name: $n, private: $p, fork: $f, central: $c}]' >"$INVENTORY"
}

# lists JQ_ARRAY: register the GraphQL answer from [{name, items: [[repo, archived]]}].
lists() {
  jq -nc "$1 | {data: {user: {lists: {nodes: map({name, items: {nodes:
    (.items | map({nameWithOwner: .[0], isArchived: .[1]}))}})}}}}" | gh_respond '*graphql*' -
}

# all_lists JQ_ITEMS: all seven lists on GitHub (0 stack, 1 archive and 5
# pinned snapshots, both not configured, 2, 3 and 4 forks lists, 6
# external), JQ_ITEMS sets the items of some.
all_lists() {
  lists "[\"$STACK\", \"$ARCH\", \"$MIRR\", \"$F1\", \"$F2\", \"$PIN\", \"$EXT\"] | map({name: ., items: []}) | $1"
}

# config JQ: change the control file with JQ.
config() {
  jq "$1" "$CONFIG" >"$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
}

# archived JSON_ARRAY: the archived repositories of the inventory phase
# ({name, fork}).
archived() {
  printf '%s\n' "$1" >"$BATS_TEST_TMPDIR/archived.json"
  export ARCHIVED="$BATS_TEST_TMPDIR/archived.json"
}

run_script() {
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].level' "$FINDINGS"; }
repo() { jq -rs --arg c "$1" --argjson i "${2:-0}" 'map(select(.check == $c)) | .[$i].repo' "$FINDINGS"; }

@test "repo in a list and central has no findings" {
  all_lists '(.[0].items = [["spali/a", false]])'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "records the checked repositories" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  all_lists '.'
  run_script
  [ "$(cat "$MONITOR_CHECKED")" = "spali/a" ]
}

@test "list-none: repo in no list" {
  all_lists '.'
  run_script
  [ "$(count list-none)" -eq 1 ]
  [ "$(level list-none)" = info ]
  [ "$(repo list-none)" = spali/a ]
  [ "$(message list-none)" = "in no list" ]
}

@test "list-none: fork in none of the forks lists" {
  inv spali/f false true true
  all_lists '(.[0].items = [["spali/f", false]])'
  run_script
  [ "$(count list-none)" -eq 1 ]
  [ "$(level list-none)" = info ]
  [ "$(repo list-none)" = spali/f ]
  [ "$(message list-none)" = "in none of the forks lists" ]
}

@test "list-none: fork in no list at all is in none of the forks lists" {
  inv spali/f false true true
  all_lists '.'
  run_script
  [ "$(count list-none)" -eq 1 ]
  [ "$(message list-none)" = "in none of the forks lists" ]
}

@test "fork with an entry in a forks list is fine" {
  inv spali/f false true true
  config '.forks = [{repo: "spali/f", upstream: "https://github.com/up/f"}]'
  all_lists '(.[2].items = [["spali/f", false]])'
  run_script
  [ "$(jq -sc 'map(.check) - ["sync-failed"]' "$FINDINGS")" = '[]' ]
}

@test "fork without an entry in a forks list is fine" {
  inv spali/f false true true
  all_lists '(.[3].items = [["spali/f", false]])'
  run_script
  # a fork is synced: only the skipped sync check (no control repository)
  [ "$(jq -sc 'map([.level, .check])' "$FINDINGS")" = '[["skip","sync-failed"]]' ]
}

@test "list-contradiction: repo in both lists of an exclusive pair" {
  all_lists '(.[3].items = [["spali/a", false]]) | (.[4].items = [["spali/a", false]])'
  run_script
  [ "$(count list-contradiction)" -eq 1 ]
  [ "$(level list-contradiction)" = info ]
  [ "$(repo list-contradiction)" = spali/a ]
  [ "$(message list-contradiction)" = 'in "▶️ Contribution forks" and "♻️ Customization forks"' ]
}

@test "mirror entry in no forks list is list-none" {
  config '.forks = [{repo: "spali/knx.js", upstream: "https://bitbucket.example/x.git"}]'
  inv spali/knx.js false false false
  all_lists '(.[0].items = [["spali/knx.js", false]])'
  run_script
  [ "$(count list-mirror-missing)" -eq 0 ]
  [ "$(count list-none)" -eq 1 ]
  [ "$(repo list-none)" = spali/knx.js ]
  [ "$(message list-none)" = "in none of the forks lists" ]
}

@test "mirror entry in no list at all is in none of the forks lists" {
  config '.forks = [{repo: "spali/m", upstream: "https://salsa.example/x.git"}]'
  inv spali/m false false false
  all_lists '.'
  run_script
  [ "$(count list-none)" -eq 1 ]
  [ "$(message list-none)" = "in none of the forks lists" ]
}

@test "mirror entry in a forks list is fine, also in other case, and no adoption" {
  config '.forks = [{repo: "spali/M", upstream: "https://salsa.example/x.git"}]'
  inv spali/m false false false
  all_lists '(.[2].items = [["spali/m", false]])'
  run_script
  # only the skipped sync check of the entry (no control repository)
  [ "$(jq -sc 'map(.check)' "$FINDINGS")" = '["sync-failed"]' ]
}

@test "non-fork entry with a GitHub upstream in a forks list is fine" {
  config '.forks = [{repo: "spali/m", upstream: "https://github.com/up/m"}]'
  inv spali/m false false false
  all_lists '(.[4].items = [["spali/m", false]])'
  run_script
  [ "$(count list-none)" -eq 0 ]
}

@test "one missing forks list is config-invalid and no forks list-none" {
  jq -n '[{name: "spali/f", private: false, fork: true, central: true},
    {name: "spali/m", private: false, fork: false, central: true}]' >"$INVENTORY"
  config '.forks = [{repo: "spali/m", upstream: "https://salsa.example/x.git"}]'
  lists "[\"$STACK\", \"$ARCH\", \"$MIRR\", \"$F1\", \"$PIN\", \"$EXT\"] | map({name: ., items: []})"
  run_script
  [ "$(count config-invalid)" -eq 1 ]
  [ "$(message config-invalid)" = 'list "♻️ Customization forks" not found on GitHub' ]
  [ "$(count list-none)" -eq 0 ]
}

@test "missing forks list is config-invalid and no forks list-none" {
  inv spali/f false true true
  lists "[\"$STACK\", \"$ARCH\", \"$F1\", \"$F2\", \"$PIN\", \"$EXT\"] | map({name: ., items: []})"
  run_script
  [ "$(count config-invalid)" -eq 1 ]
  [ "$(message config-invalid)" = 'list "👀  Mirrors" not found on GitHub' ]
  [ "$(count list-none)" -eq 0 ]
}

@test "fork in two forks lists counts once" {
  inv spali/f false true true
  all_lists '(.[2].items = [["spali/f", false], ["spali/x", false]]) | (.[3].items = [["spali/f", false]])'
  run_script
  [ "$(jq -sc 'map(.check) - ["sync-failed"]' "$FINDINGS")" = '[]' ]
}

@test "list-external-own: own repository in an external list" {
  all_lists '(.[0].items = [["spali/a", false]]) | (.[6].items = [["spali/a", false], ["spali/a", false]])'
  run_script
  [ "$(count list-external-own)" -eq 1 ]
  [ "$(level list-external-own)" = info ]
  [ "$(repo list-external-own)" = spali/a ]
  [ "$(message list-external-own)" = 'own repository in "🔍 Interesting and related"' ]
}

@test "archived own repository in an external list is list-external-own" {
  archived '[{"name": "spali/old", "fork": false}]'
  all_lists '(.[0].items = [["spali/a", false], ["spali/old", true]]) | (.[6].items = [["spali/old", true]])'
  run_script
  [ "$(jq -sc 'map([.check, .repo, .message])' "$FINDINGS")" = '[["list-external-own","spali/old","own repository in \"🔍 Interesting and related\""]]' ]
}

@test "missing external list is config-invalid, no list-external-own" {
  config '.lists.external = ["🔍 Interesting and related", "🔍 Gone"]'
  all_lists '(.[0].items = [["spali/a", false]]) | (.[6].items = [["spali/a", false]])'
  run_script
  [ "$(count config-invalid)" -eq 1 ]
  [ "$(message config-invalid)" = 'list "🔍 Gone" not found on GitHub' ]
  [ "$(count list-external-own)" -eq 1 ]
}

@test "repo only in an external list is not in no list" {
  all_lists '(.[6].items = [["spali/a", false]])'
  run_script
  [ "$(count list-none)" -eq 0 ]
  [ "$(count list-external-own)" -eq 1 ]
}

@test "no list-mirror-missing check is registered" {
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  [[ " ${MONITOR_CHECKS[*]} " != *" list-mirror-missing "* ]]
  [[ " ${MONITOR_CHECKS[*]} " == *" list-external-own "* ]]
  [ "$(jq -c '."list-external-own" | [.category, .areas, .title, .text]' <<<"$MONITOR_TODO")" = '["cleanup",["lists"],"Move own repositories out of external Lists","Lists in lists.external are for repositories of others: move own work to your stack List and own forks to the forks List."]' ]
  [ "$(jq -c 'has("list-mirror-missing")' <<<"$MONITOR_TODO")" = false ]
}

@test "archived repo in a normal list is clean" {
  archived '[{"name": "spali/old", "fork": false}]'
  all_lists '(.[0].items = [["spali/a", false], ["spali/old", true]])'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "archived repo in no list is list-none" {
  archived '[{"name": "spali/old", "fork": false}]'
  all_lists '(.[0].items = [["spali/a", false]])'
  run_script
  [ "$(count list-none)" -eq 1 ]
  [ "$(level list-none)" = info ]
  [ "$(repo list-none)" = spali/old ]
  [ "$(message list-none)" = "in no list" ]
}

@test "archived fork outside the forks lists is list-none" {
  archived '[{"name": "spali/oldfork", "fork": true}, {"name": "spali/gone", "fork": true}]'
  all_lists '(.[0].items = [["spali/a", false], ["spali/oldfork", true]])'
  run_script
  [ "$(jq -rs 'map(select(.check == "list-none") | "\(.repo) \(.message)") | join(",")' "$FINDINGS")" = "spali/oldfork in none of the forks lists,spali/gone in none of the forks lists" ]
}

@test "archived fork in a forks list is clean" {
  archived '[{"name": "spali/f1", "fork": true}, {"name": "spali/f2", "fork": true}]'
  all_lists '(.[0].items = [["spali/a", false]]) | (.[2].items = [["spali/f1", true]]) | (.[3].items = [["spali/f2", true]])'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "archived repo in both lists of an exclusive pair is list-contradiction" {
  archived '[{"name": "spali/oldfork", "fork": true}]'
  all_lists '(.[0].items = [["spali/a", false]]) | (.[3].items = [["spali/oldfork", true]]) | (.[4].items = [["spali/oldfork", true]])'
  run_script
  [ "$(jq -sc 'map([.check, .repo])' "$FINDINGS")" = '[["list-contradiction","spali/oldfork"]]' ]
}

@test "lists not named in the control file are plain lists" {
  archived '[{"name": "spali/old", "fork": false}]'
  all_lists '(.[0].items = [["spali/a", false]]) | (.[1].items = [["spali/old", true]]) | (.[5].items = [["spali/a", false]])'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "no list-archived check is registered" {
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  [[ " ${MONITOR_CHECKS[*]} " != *" list-archived "* ]]
  [ "$(jq -c 'has("list-archived")' <<<"$MONITOR_TODO")" = false ]
}

@test "no ARCHIVED file means no archived findings" {
  local a
  for a in unset "$BATS_TEST_TMPDIR/missing.json" empty garbage names; do
    : >"$FINDINGS"
    case $a in
      unset) unset ARCHIVED ;;
      empty) archived '' ;;
      garbage) archived '{not json' ;;
      names) archived '["spali/old", {"fork": true}]' ;;
      *) export ARCHIVED=$a ;;
    esac
    all_lists '(.[0].items = [["spali/a", false]])'
    run_script
    [ ! -s "$FINDINGS" ]
  done
}

@test "foreign repos in lists are ignored" {
  all_lists '(.[0].items = [["spali/a", false], ["other/x", true]]) | (.[3].items = [["other/y", false]]) | (.[6].items = [["other/x", false]])'
  run_script
  [ ! -s "$FINDINGS" ]
}

@test "missing list name is config-invalid and dependent checks are skipped" {
  lists '[{name: "🚀 My stack", items: [["spali/a", false]]}, {name: "🗃️ My stack Archive", items: [["spali/a", false]]}]'
  run_script
  [ "$(count config-invalid)" -eq 4 ]
  [ "$(level config-invalid)" = red ]
  [ "$(repo config-invalid)" = null ]
  jq -rs 'map(select(.check == "config-invalid") | .message) | index("list \"👀  Mirrors\" not found on GitHub")' "$FINDINGS" | grep -qx '[0-9]*'
  [ "$(count list-contradiction)" -eq 0 ]
  [ "$(count list-none)" -eq 0 ]
}

@test "fork gets no list-none while a forks list is missing" {
  jq -n '[{name: "spali/a", private: false, fork: false, central: true},
    {name: "spali/f", private: false, fork: true, central: true}]' >"$INVENTORY"
  lists '[{name: "🚀 My stack", items: [["spali/a", false]]}, {name: "🗃️ My stack Archive", items: []}, {name: "👀  Mirrors", items: []}, {name: "▶️ Contribution forks", items: []}, {name: "📌 Pinned snapshots", items: []}, {name: "🔍 Interesting and related", items: []}]'
  run_script
  [ "$(count config-invalid)" -eq 1 ]
  [ "$(count list-none)" -eq 0 ]
}

@test "without configured forks lists a fork or entry in no list is plain list-none" {
  local c
  for c in '{"lists": {"exclusive": []}}' '{"lists": {"forks": []}}'; do
    : >"$FINDINGS"
    jq --argjson c "$c" -n '$c + {forks: [{repo: "spali/m", upstream: "https://salsa.example/x.git"}]}' >"$CONFIG"
    jq -n '[{name: "spali/f", private: false, fork: true, central: true},
      {name: "spali/m", private: false, fork: false, central: true}]' >"$INVENTORY"
    all_lists '.'
    run_script
    [ "$(jq -rs 'map(select(.check == "list-none") | "\(.repo) \(.message)") | join(",")' "$FINDINGS")" = "spali/f in no list,spali/m in no list" ]
  done
}

@test "adoption skips the entries of forks:" {
  jq -n '[{name: "spali/m", private: false, fork: false, central: false},
    {name: "spali/b", private: false, fork: false, central: false}]' >"$INVENTORY"
  jq '.forks = [{repo: "spali/M", upstream: "https://github.com/up/m"}]' "$CONFIG" >"$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
  all_lists '(.[0].items = [["spali/m", false], ["spali/b", false]])'
  run_script
  [ "$(jq -sr '[.[] | select(.check == "adoption") | .repo] | join(",")' "$FINDINGS")" = "spali/b" ]
}

@test "spali/.github is not counted for adoption" {
  jq -n '[{name: "spali/.github", private: false, fork: false, central: false}]' >"$INVENTORY"
  all_lists '(.[0].items = [["spali/.github", false]])'
  run_script
  [ "$(count adoption)" -eq 0 ]
}

@test "more than one page of items is check-failed and skips list checks" {
  inv spali/b false false false
  jq -nc '{data: {user: {lists: {pageInfo: {hasNextPage: false}, nodes: [{name: "🚀 My stack",
    items: {pageInfo: {hasNextPage: true}, nodes: []}}]}}}}' | gh_respond '*graphql*' -
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "lists: more than 50 lists or 100 items in a list, not all read" ]
  [ "$(count list-none)" -eq 0 ]
  [ "$(count config-invalid)" -eq 0 ]
  [ "$(count adoption)" -eq 1 ]
}

@test "more than one page of lists is check-failed and skips list checks" {
  inv spali/b false false false
  jq -nc '{data: {user: {lists: {pageInfo: {hasNextPage: true}, nodes: []}}}}' | gh_respond '*graphql*' -
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(count list-none)" -eq 0 ]
  [ "$(count adoption)" -eq 1 ]
}

@test "adoption is one info finding per repository" {
  jq -n '[{name: "spali/z", private: false, fork: false, central: false},
    {name: "spali/b", private: false, fork: false, central: false},
    {name: "spali/c", private: false, fork: false, central: true},
    {name: "spali/f", private: false, fork: true, central: false}]' >"$INVENTORY"
  all_lists '(.[0].items = [["spali/z", false], ["spali/b", false], ["spali/c", false]]) | (.[3].items = [["spali/f", false]])'
  run_script
  [ "$(count adoption)" -eq 2 ]
  [ "$(level adoption)" = info ]
  [ "$(repo adoption)" = spali/b ]
  [ "$(message adoption)" = "no central release flow" ]
  [ "$(jq -sr '[.[] | select(.check == "adoption") | .repo] | join(",")' "$FINDINGS")" = "spali/b,spali/z" ]
}

@test "adoption names private repos too" {
  jq -n '[{name: "spali/b", private: false, fork: false, central: false},
    {name: "spali/p", private: true, fork: false, central: false},
    {name: "spali/q", private: true, fork: false, central: false}]' >"$INVENTORY"
  all_lists '(.[0].items = [["spali/b", false], ["spali/p", false], ["spali/q", false]])'
  run_script
  [ "$(count adoption)" -eq 3 ]
  [ "$(jq -sr '[.[] | select(.check == "adoption") | .repo] | join(",")' "$FINDINGS")" = "spali/b,spali/p,spali/q" ]
}

@test "repos that pin any shared workflow are not adoption candidates" {
  jq -n '[{name: "spali/ctl", private: true, fork: false, central: false,
      pins: [{workflow: "monitor.yml", sha: "a", version: "v1"}]},
    {name: "spali/b", private: false, fork: false, central: false, pins: []},
    {name: "spali/c", private: false, fork: false, central: false}]' >"$INVENTORY"
  all_lists '(.[0].items = [["spali/ctl", false], ["spali/b", false], ["spali/c", false]])'
  run_script
  [ "$(jq -sr '[.[] | select(.check == "adoption") | .repo] | join(",")' "$FINDINGS")" = "spali/b,spali/c" ]
}

@test "list query failure is check-failed, adoption still emitted" {
  inv spali/b false false false
  gh_fail '*graphql*' 'gh: Resource not accessible (HTTP 403)'
  run_script
  [ "$(count check-failed)" -eq 1 ]
  [ "$(level check-failed)" = red ]
  [ "$(message check-failed)" = "list-none: gh: Resource not accessible (HTTP 403)" ]
  [ "$(count list-none)" -eq 0 ]
  [ "$(count adoption)" -eq 1 ]
}

@test "LISTS gets the lists that were read, own repositories only" {
  export LISTS="$BATS_TEST_TMPDIR/lists.json"
  all_lists '(.[0].items = [["spali/a", false], ["other/x", false]]) | (.[5].items = [["spali/old", true]])'
  run_script
  [ "$(jq -c '.[0]' "$LISTS")" = '{"name":"🚀 My stack","items":[{"repo":"spali/a","archived":false}]}' ]
  [ "$(jq -c '.[5].items' "$LISTS")" = '[{"repo":"spali/old","archived":true}]' ]
  [ "$(jq length "$LISTS")" -eq 7 ]
}

@test "LISTS stays unwritten when the lists are unavailable" {
  export LISTS="$BATS_TEST_TMPDIR/lists.json"
  gh_fail '*graphql*' 'gh: Resource not accessible (HTTP 403)'
  run_script
  [ ! -e "$LISTS" ]
}

@test "LISTS_TOKEN is used for the GraphQL call" {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<GHEND
#!/usr/bin/env bash
echo "\$GH_TOKEN" >>"$BATS_TEST_TMPDIR/tokens"
echo '{"data":{"user":{"lists":{"nodes":[]}}}}'
GHEND
  GH_TOKEN=base LISTS_TOKEN=lists run_script
  [ "$(cat "$BATS_TEST_TMPDIR/tokens")" = lists ]
}

@test "GH_TOKEN is used when LISTS_TOKEN is unset" {
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<GHEND
#!/usr/bin/env bash
echo "\$GH_TOKEN" >>"$BATS_TEST_TMPDIR/tokens"
echo '{"data":{"user":{"lists":{"nodes":[]}}}}'
GHEND
  GH_TOKEN=base run_script
  [ "$(cat "$BATS_TEST_TMPDIR/tokens")" = base ]
}

@test "large list response is parsed" {
  jq -nc --arg pad "$(head -c 300000 /dev/zero | tr '\0' x)" \
    '{data: {user: {lists: {nodes: [{name: "🚀 My stack", pad: $pad,
      items: {nodes: [{nameWithOwner: "spali/a", isArchived: false}]}}]}}}}' |
    gh_respond '*graphql*' -
  echo '{"lists": {"external": ["🚀 My stack"]}}' >"$CONFIG"
  run_script
  [ ! -s "$FINDINGS" ]
}

# --- sync-failed (runs once, here) --------------------------------------

RUNS='repos/ctl/x/actions/workflows/sync.yml/runs?per_page=20&status=completed&branch=main'

# entries [REPO...]: forks: entries for REPO... (default spali/f).
entries() {
  local repos
  repos=$(jq -nc '$ARGS.positional' --args "${@:-spali/f}")
  jq --argjson r "$repos" '.forks = ($r | map({repo: ., upstream: "https://github.com/up/x"}))' \
    "$CONFIG" >"$CONFIG.new" && mv "$CONFIG.new" "$CONFIG"
}

# sync_runs ID...: completed sync runs on main, newest first.
sync_runs() {
  jq -nc --args '{total_count: ($ARGS.positional | length), workflow_runs: ($ARGS.positional
    | map({id: tonumber, conclusion: "success", html_url: "https://github.com/ctl/x/actions/runs/\(.)"}))}' "$@" |
    gh_respond "*$RUNS" -
}

# sync_jobs RUN_ID 'NAME=CONCLUSION'...: the jobs of one run (an empty
# CONCLUSION is null); job n (from 1) has the URL .../runs/RUN_ID/job/RUN_IDn.
sync_jobs() {
  local id=$1
  shift
  jq -nc --arg id "$id" --args '{total_count: ($ARGS.positional | length), jobs: ($ARGS.positional
    | to_entries | map((.value | capture("^(?<name>.*)=(?<c>[a-z_]*)$")) as $j
    | {name: $j.name, status: "completed", conclusion: (if $j.c == "" then null else $j.c end), run_id: ($id | tonumber),
       html_url: "https://github.com/ctl/x/actions/runs/\($id)/job/\($id)\(.key + 1)"}))}' "$@" |
    gh_respond "*repos/ctl/x/actions/runs/$id/jobs?per_page=100" -
}

PLAN='sync / Repositories'

# sync_findings prints the sync-failed findings as "level repo message" lines.
sync_findings() {
  jq -rs 'map(select(.check == "sync-failed"))[] | "\(.level) \(.repo // "-") \(.message)"' "$FINDINGS"
}

@test "no synced repository: no sync check" {
  export GITHUB_REPOSITORY=ctl/x
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  run ! grep -F 'sync.yml' "$GH_LOG"
}

@test "synced repositories without a control repository skip sync-failed" {
  entries
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 1 ]
  [ "$(level sync-failed)" = skip ]
  [ "$(message sync-failed)" = "sync-failed: no control repository (local run)" ]
  run ! grep -F 'sync.yml' "$GH_LOG"
}

@test "failed sync run is sync-failed" {
  entries
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/f=failure'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/9/job/92" ]
}

@test "inventory forks count as synced, pinned entries do not" {
  jq -n '[{name: "spali/a", private: false, fork: false, central: true},
    {name: "spali/inv", private: false, fork: true, central: false, parent: {name: "up/inv"}},
    {name: "spali/pin", private: false, fork: true, central: false, parent: {name: "up/pin"}}]' >"$INVENTORY"
  config '.forks = [{repo: "spali/pin", pinned: true}]'
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/inv=failure' 'sync / Sync · spali/pin=failure'
  all_lists '(.[0].items = [["spali/a", false]]) | (.[2].items = [["spali/inv", false], ["spali/pin", false]])'
  run_script
  [ "$(sync_findings)" = "red spali/inv last sync of this repository failed: https://github.com/ctl/x/actions/runs/9/job/92" ]
}

@test "successful sync run is no finding" {
  entries
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/f=success'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  grep -qF 'runs/9/jobs' "$GH_LOG"
}

@test "no sync run yet is no finding" {
  entries
  export GITHUB_REPOSITORY=ctl/x
  jq -nc '{total_count: 0, workflow_runs: []}' | gh_respond "*$RUNS" -
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  grep -qF 'sync.yml/runs' "$GH_LOG"
  run ! grep -F '/jobs' "$GH_LOG"
}

@test "red nightly run and green dispatch for another repo: only the failed repo is red" {
  entries spali/f spali/g spali/h
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/g=success'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=failure' 'sync / Sync · spali/g=failure' \
    'sync / Sync · spali/h=success'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/10/job/102" ]
}

@test "a later green job of the same repo clears it" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/f=success'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=failure'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
}

@test "cancelled newest job keeps the older failure" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 12 11 10
  sync_jobs 12 "$PLAN=success" 'sync / Sync · spali/f=cancelled'
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/f=skipped'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=failure'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/10/job/102" ]
}

@test "failed plan job of the newest run is the general finding" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=failure" 'sync / Sync · spali/f=skipped'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=success'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red - sync run failed before the repositories: https://github.com/ctl/x/actions/runs/11" ]
}

@test "failed plan job of an older run is no finding" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10 9
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/g=success'
  sync_jobs 10 "$PLAN=failure"
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/f=success'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
}

@test "job names with any caller prefix and dotted repo names match exactly" {
  entries spali/knx.js spali/a-b_c spali/n spali/ok
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 'Managed repositories=success' 'Sync · spali/knx.jsx=failure' \
    'maint / Sync · spali/knx.js=failure' 'Sync · spali/a-b_c=failure' \
    'outer / inner / Sync · spali/n=failure' 'x / Sync · spali/ok=success' \
    'Sync · spali/knxXjs=failure' 'Sync · spali/a-b_c2=failure'
  all_lists '.'
  run_script
  [ "$(sync_findings | sort)" = "$(printf '%s\n' \
    "red spali/a-b_c last sync of this repository failed: https://github.com/ctl/x/actions/runs/9/job/94" \
    "red spali/knx.js last sync of this repository failed: https://github.com/ctl/x/actions/runs/9/job/93" \
    "red spali/n last sync of this repository failed: https://github.com/ctl/x/actions/runs/9/job/95")" ]
}

@test "a job name merely containing the repo does not match" {
  entries spali/knx.js
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/knx.js extra=failure' 'sync / Sync · xspali/knx.js=failure' \
    'sync / Sync · spali/knx.js/x=failure'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
}

@test "jobs of repositories that are not synced are ignored" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/f=success' 'sync / Sync · spali/gone=failure'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
}

@test "runs are read only from main" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  sync_jobs 9 "$PLAN=success" 'sync / Sync · spali/f=success'
  all_lists '.'
  run_script
  [ "$(grep -c 'sync.yml/runs' "$GH_LOG")" -eq 1 ]
  grep -F 'sync.yml/runs' "$GH_LOG" | grep -qF 'branch=main'
}

@test "reading stops once every repo has a result" {
  entries spali/f spali/g
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 12 11 10
  sync_jobs 12 "$PLAN=success" 'sync / Sync · spali/f=failure'
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/g=success' 'sync / Sync · spali/f=success'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/g=failure'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/12/job/122" ]
  grep -qF 'runs/11/jobs' "$GH_LOG"
  run ! grep -F 'runs/10/jobs' "$GH_LOG"
}

@test "a repo without a job in any run is no finding" {
  entries spali/f spali/new
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 10 9
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=failure'
  sync_jobs 9 "$PLAN=success"
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/10/job/102" ]
  grep -qF 'runs/9/jobs' "$GH_LOG"
}

@test "runs API error is check-failed" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  gh_fail "*$RUNS" 'HTTP 500: boom (https://api.github.com/x) (HTTP 500)'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  [ "$(count check-failed)" -eq 1 ]
  [[ $(message check-failed) == "sync-failed: "* ]]
}

@test "jobs API error is check-failed" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  gh_fail '*repos/ctl/x/actions/runs/9/jobs*' 'HTTP 502: bad (HTTP 502)'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "sync-failed: HTTP 502: bad (HTTP 502)" ]
}

@test "cancelled newest run is no general finding" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=cancelled" 'sync / Sync · spali/f=skipped'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=success'
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  grep -qF 'runs/10/jobs' "$GH_LOG"
}

@test "the general finding comes from the newest run whose plan job has a result" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 12 11 10 9
  sync_jobs 12 "$PLAN=success" 'sync / Sync · spali/f=success'
  sync_jobs 11 "$PLAN=cancelled"
  sync_jobs 10 "$PLAN=failure" 'sync / Sync · spali/f=skipped'
  sync_jobs 9 "$PLAN=success"
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  run ! grep -F 'runs/11/jobs' "$GH_LOG"
}

@test "a cancelled newest run does not hide an older failed plan job" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 12 11 10
  sync_jobs 12 "$PLAN=cancelled" 'sync / Sync · spali/f=skipped'
  sync_jobs 11 "$PLAN=failure" 'sync / Sync · spali/f=skipped'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=success'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red - sync run failed before the repositories: https://github.com/ctl/x/actions/runs/11" ]
}

@test "the plan job keeps runs read until it has a result" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=skipped" 'sync / Sync · spali/f=failure'
  sync_jobs 10 "$PLAN=timed_out"
  all_lists '.'
  run_script
  [ "$(sync_findings | sort)" = "$(printf '%s\n' \
    "red - sync run failed before the repositories: https://github.com/ctl/x/actions/runs/10" \
    "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/11/job/112")" ]
}

@test "a timed out repo job over an older success is red" {
  entries spali/f spali/g
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/f=timed_out' 'sync / Sync · spali/g=action_required'
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=success' 'sync / Sync · spali/g=success'
  all_lists '.'
  run_script
  [ "$(sync_findings | sort)" = "$(printf '%s\n' \
    "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/11/job/112" \
    "red spali/g last sync of this repository failed: https://github.com/ctl/x/actions/runs/11/job/113")" ]
  run ! grep -F 'runs/10/jobs' "$GH_LOG"
}

@test "a repo job without a conclusion is passed over" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 11 10
  sync_jobs 11 "$PLAN=success" 'sync / Sync · spali/f='
  sync_jobs 10 "$PLAN=success" 'sync / Sync · spali/f=failure'
  all_lists '.'
  run_script
  [ "$(sync_findings)" = "red spali/f last sync of this repository failed: https://github.com/ctl/x/actions/runs/10/job/102" ]
}

@test "more jobs than one page is check-failed" {
  entries spali/f
  export GITHUB_REPOSITORY=ctl/x
  sync_runs 9
  jq -nc '{total_count: 101, jobs: [{name: "sync / Managed repositories", conclusion: "success", html_url: "u1"},
    {name: "sync / Sync · spali/f", conclusion: "success", html_url: "u2"}]}' |
    gh_respond '*repos/ctl/x/actions/runs/9/jobs?per_page=100' -
  all_lists '.'
  run_script
  [ "$(count sync-failed)" -eq 0 ]
  [ "$(count check-failed)" -eq 1 ]
  [ "$(message check-failed)" = "sync-failed: more jobs than one page (101, read 2): https://github.com/ctl/x/actions/runs/9" ]
}
