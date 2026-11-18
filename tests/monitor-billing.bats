#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

USAGE='api users/spali/settings/billing/usage?year=2026&month=11'
PLAN='api users/spali'

setup() {
  load helpers/gh-stub
  stub_gh
  FINDINGS="$BATS_TEST_TMPDIR/f.jsonl"
  INVENTORY="$BATS_TEST_TMPDIR/inventory.json"
  CONFIG="$BATS_TEST_TMPDIR/config.json"
  export FINDINGS INVENTORY CONFIG
  : >"$FINDINGS"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/monitor-billing.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/billing"
  unset MONITOR_CHECKED
  export BILLING_TOKEN=account-token GH_TOKEN=app-token
  now 2026-11-18T12:00:00Z
  jq -n '[{name: "spali/private-a", private: true}, {name: "spali/public-b", private: false}]' >"$INVENTORY"
  echo '{"version": 1}' >"$CONFIG"
  PLAN_ANSWER="$FIXTURES/user-free.json"
}

# now ISO8601: the time of the run.
now() {
  MONITOR_NOW=$(date -u -d "$1" +%s)
  export MONITOR_NOW
}

# usage JQ_ARRAY: the usage answer from [[day, sku, quantity, repo, price,
# product], ...] (day of November 2026 or a full date; price optional or null,
# default GitHub's; product optional, default actions; a sku ending in
# "storage" is GigabyteHours, else Minutes).
usage() {
  jq -nc "$1"' | {usageItems: map(
    {"Actions Linux": 0.006, "Actions macOS 3-core": 0.062, "Actions Windows": 0.01,
      "Actions Linux ARM": 0.005, "Actions storage": 0.00033602}[.[1]] as $d | (.[4] // $d) as $p |
    {date: (if (.[0] | type) == "number" then "2026-11-\(.[0] | tostring | if length == 1 then "0" + . else . end)" else .[0] end + "T00:00:00Z"),
      product: (.[5] // "actions"), sku: .[1], quantity: .[2],
      unitType: (if .[1] | endswith("storage") then "GigabyteHours" else "Minutes" end),
      pricePerUnit: $p, grossAmount: (.[2] * $p), discountAmount: (.[2] * $p), netAmount: 0,
      repositoryName: .[3]})}' | gh_respond "$USAGE" -
}

# config JQ: change the control file with JQ.
config() {
  jq "$1" "$CONFIG" >"$CONFIG.n" && mv "$CONFIG.n" "$CONFIG"
}

# run_script runs the script; the plan answer is $PLAN_ANSWER unless the test
# registered one before.
run_script() {
  gh_respond "$PLAN" "$PLAN_ANSWER"
  run --separate-stderr "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

count() { jq -s --arg c "$1" 'map(select(.check == $c)) | length' "$FINDINGS"; }
message() { jq -rs --arg c "$1" 'map(select(.check == $c)) | .[0].message' "$FINDINGS"; }
level() { jq -rs --arg c "$1" 'map(select(.check == $c)) | .[0].level' "$FINDINGS"; }
info() { jq -rs 'map(select(.check == "billing" and .level == "info")) | .[0].message' "$FINDINGS"; }
total() { jq -s length "$FINDINGS"; }

@test "no account token: one skip finding, no call" {
  unset BILLING_TOKEN
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"skip","check":"billing","repo":null,"message":"no account token: billing not checked"}' ]
  [ ! -s "$GH_LOG" ]
}

@test "quiet month: one info line of private usage, with the account token" {
  gh_respond "$USAGE" "$FIXTURES/usage-quiet.json"
  run_script
  [ "$(total)" -eq 1 ]
  [ "$(level billing)" = info ]
  [ "$(jq -rs '.[0].repo' "$FINDINGS")" = null ]
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, projected 26 %) · storage 0 %'* ]]
  [[ "$(info)" == *'private-a 300 min'* ]]
  [[ "$(info)" != *public-b* ]]
  [ "$(sort -u "$GH_TOKENS")" = account-token ]
  [ "$(wc -l <"$GH_LOG")" -eq 2 ]
}

@test "info line: storage and the top repositories" {
  usage '[[17, "Actions Linux", 300, "private-a"], [17, "Actions Linux", 50, "private-d"],
    [16, "Actions storage", 30, "private-a"], [17, "Actions storage", 6, "private-a"]]'
  jq -n '[{name: "spali/private-a", private: true}, {name: "spali/private-d", private: true}]' >"$INVENTORY"
  run_script
  [ "$(info)" = 'Actions minutes 18 % (350 of 2000, projected 30 %) · storage 17 % (86 MB of 500 MB, projected 31 %) · top: private-a 300 min, private-d 50 min · top storage: private-a 86 MB' ]
}

@test "macOS minutes weigh by their price (fallback Linux price 0.006)" {
  usage '[[17, "Actions macOS 3-core", 100, "private-a"]]'
  run_script
  [[ "$(info)" == 'Actions minutes 52 % (1033 of 2000, '* ]]
  [[ "$(info)" == *'private-a 1033 min'* ]]
}

@test "the Linux price comes from the answer" {
  usage '[[17, "Actions Windows", 100, "private-a"], [17, "Actions Linux", 1, "public-b", 0.008]]'
  config '.billing.minutes.included = 1000'
  run_script
  # 100 Windows minutes cost 1.00, that is 125 minutes at 0.008
  [[ "$(info)" == 'Actions minutes 13 % (125 of 1000, '* ]]
}

@test "minutes at the threshold: red billing-minutes and the info line" {
  usage '[[17, "Actions Linux", 1600, "private-a"]]'
  run_script
  [ "$(count billing-minutes)" -eq 1 ]
  [ "$(level billing-minutes)" = red ]
  [ "$(message billing-minutes)" = 'Actions minutes at 80 % of the included 2000 (1600), projected 137 % by month end' ]
  [ "$(jq -rs 'map(select(.check == "billing-minutes")) | .[0].repo' "$FINDINGS")" = null ]
  [[ "$(info)" == 'Actions minutes 80 % (1600 of 2000, projected 137 %)'* ]]
  [ "$(count billing-storage)" -eq 0 ]
  [ "$(total)" -eq 2 ]
}

@test "projection only: red from day 7" {
  now 2026-11-10T12:00:00Z
  usage '[[9, "Actions Linux", 900, "private-a"]]'
  run_script
  [ "$(message billing-minutes)" = 'Actions minutes at 45 % of the included 2000 (900), projected 142 % by month end' ]
}

@test "projection only: no red before day 7" {
  now 2026-11-03T12:00:00Z
  usage '[[2, "Actions Linux", 900, "private-a"]]'
  run_script
  [ "$(count billing-minutes)" -eq 0 ]
  [ "$(total)" -eq 1 ]
  [[ "$(info)" == 'Actions minutes 45 % (900 of 2000, projection from day 7) · storage 0 % (0 MB of 500 MB, projection from day 7)'* ]]
}

@test "day 7: the info line shows the projection" {
  now 2026-11-07T00:00:00Z
  usage '[[6, "Actions Linux", 300, "private-a"]]'
  run_script
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, projected 75 %) · storage 0 % (0 MB of 500 MB, projected 0 %)'* ]]
}

@test "storage red by the level of yesterday only" {
  usage '[[17, "Actions storage", 36, "private-a"]]'
  run_script
  [ "$(count billing-storage)" -eq 1 ]
  [ "$(level billing-storage)" = red ]
  [ "$(message billing-storage)" = 'Actions storage at 17 % of the included 500 MB (86 MB on average), projected 135 % by month end' ]
  [ "$(count billing-minutes)" -eq 0 ]
}

@test "storage with a low level yesterday is not red" {
  usage '[[16, "Actions storage", 30, "private-a"], [17, "Actions storage", 6, "private-a"]]'
  run_script
  [ "$(count billing-storage)" -eq 0 ]
  [[ "$(info)" == *'storage 17 % (86 MB of 500 MB, projected 31 %)'* ]]
}

@test "storage at the threshold is red" {
  usage '[[16, "Actions storage", 100, "private-a"], [17, "Actions storage", 60, "private-a"]]'
  config '.billing.storage.threshold = 50'
  run_script
  [[ "$(message billing-storage)" == 'Actions storage at 76 % of the included 500 MB'* ]]
}

@test "config: a higher minutes threshold, no red" {
  now 2026-11-03T12:00:00Z
  usage '[[2, "Actions Linux", 1600, "private-a"]]'
  config '.billing.minutes.threshold = 90'
  run_script
  [ "$(count billing-minutes)" -eq 0 ]
  [[ "$(info)" == 'Actions minutes 80 % (1600 of 2000, '* ]]
}

@test "config: the default threshold 75 is red at the same usage" {
  now 2026-11-03T12:00:00Z
  usage '[[2, "Actions Linux", 1600, "private-a"]]'
  run_script
  [ "$(count billing-minutes)" -eq 1 ]
}

@test "config: only a threshold set, the included values come from the plan" {
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  config '.billing = {minutes: {threshold: 90}}'
  run_script
  grep -qx "$PLAN" "$GH_LOG"
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, '*'of 500 MB'* ]]
}

@test "config: plan pro gives 3000 minutes and 2 GB" {
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  echo '{"plan": {"name": "pro"}}' | gh_respond "$PLAN" -
  run_script
  [[ "$(info)" == 'Actions minutes 10 % (300 of 3000, '*'of 2000 MB'* ]]
}

@test "config: a full billing block needs no plan call" {
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  config '.billing = {minutes: {included: 1000, threshold: 75}, storage: {"included-gb": 1, threshold: 75}}'
  gh_fail "$PLAN" 'must not be called (HTTP 500)'
  run_script
  ! grep -qx "$PLAN" "$GH_LOG"
  [ "$(info)" = 'Actions minutes 30 % (300 of 1000, projected 51 %) · storage 0 % (0 MB of 1000 MB, projected 0 %) · top: private-a 300 min' ]
}

@test "config: an unknown plan without included values is check-failed" {
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  echo '{"plan": {"name": "team"}}' | gh_respond "$PLAN" -
  config '.billing = {minutes: {included: 3000}}'
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: plan team has no defaults: set billing: in the control file"}' ]
}

@test "repositories not in the inventory count as private and are named" {
  usage '[[17, "Actions Linux", 300, "gone-c"], [17, "Actions Linux", 60, ""], [17, "Actions Linux", 100, "public-b"]]'
  gh_fail 'api repos/spali/gone-c' 'gh: Not Found (HTTP 404)'
  run_script
  [[ "$(info)" == 'Actions minutes 18 % (360 of 2000, '* ]]
  [[ "$(info)" == *'top: gone-c (not in inventory) 300 min, (no name) (not in inventory) 60 min'* ]]
  # one lookup for the unknown name, none for the empty one or the inventory
  [ "$(grep -c '^api repos/' "$GH_LOG")" -eq 1 ]
}

@test "an archived public repository is looked up with the app token and ignored" {
  usage '[[17, "Actions Linux", 300, "archived-e"], [16, "Actions Linux", 100, "archived-e"], [17, "Actions Linux", 300, "private-a"]]'
  echo '{"name": "archived-e", "private": false, "archived": true}' | gh_respond 'api repos/spali/archived-e' -
  run_script
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, '* ]]
  [[ "$(info)" != *archived-e* ]]
  [ "$(grep -cx 'api repos/spali/archived-e' "$GH_LOG")" -eq 1 ]
  # the lookup uses the app token, the billing calls the account token
  [ "$(paste -d ' ' "$GH_LOG" "$GH_TOKENS" | grep '^api repos/' | awk '{print $NF}')" = app-token ]
  [ "$(paste -d ' ' "$GH_LOG" "$GH_TOKENS" | grep '^api users/' | awk '{print $NF}' | sort -u)" = account-token ]
}

@test "an archived private repository counts and is marked archived" {
  usage '[[17, "Actions Linux", 300, "archived-f"], [17, "Actions storage", 24, "archived-f"]]'
  echo '{"name": "archived-f", "private": true, "archived": true}' | gh_respond 'api repos/spali/archived-f' -
  run_script
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, '* ]]
  [[ "$(info)" == *'top: archived-f (archived) 300 min'* ]]
  [[ "$(info)" == *'top storage: archived-f (archived) '* ]]
}

@test "a lookup error is check-failed, nothing else" {
  usage '[[17, "Actions Linux", 300, "gone-c"]]'
  gh_fail 'api repos/spali/gone-c' 'gh: Bad credentials (HTTP 401)'
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: gh: Bad credentials (HTTP 401)"}' ]
}

@test "a lookup answer that is not JSON is check-failed" {
  usage '[[17, "Actions Linux", 300, "gone-c"]]'
  echo '<html>oops</html>' | gh_respond 'api repos/spali/gone-c' -
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: cannot parse API response"}' ]
}

@test "only Actions and Packages count, not Codespaces" {
  usage '[[17, "Actions Linux", 300, "private-a"], [17, "Codespaces compute 2-core", 5000, "private-a", 0.18, "codespaces"],
    [17, "Codespaces storage", 500, "private-a", 0.07, "codespaces"], [16, "Packages storage", 42, "private-a", 0.0008, "Packages"]]'
  run_script
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, projected 26 %) · storage 20 % (100 MB of 500 MB, '* ]]
  [ "$(total)" -eq 1 ]
}

@test "no lookup for an unknown repository of a product that does not count" {
  usage '[[17, "Actions Linux", 300, "private-a"], [17, "Codespaces compute 2-core", 50, "gone-c", 0.18, "codespaces"]]'
  run_script
  [ "$(grep -c '^api repos/' "$GH_LOG")" -eq 0 ]
}

@test "empty inventory: skip, no computing" {
  echo '[]' >"$INVENTORY"
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"skip","check":"billing","repo":null,"message":"no inventory: billing not checked"}' ]
  [ ! -s "$GH_LOG" ]
}

@test "a repository is matched to the inventory case-insensitively" {
  usage '[[17, "Actions Linux", 300, "Public-B"]]'
  run_script
  [[ "$(info)" == 'Actions minutes 0 % (0 of 2000, '* ]]
}

@test "day 1: storage level is the average so far, no projection red" {
  now 2026-11-01T06:00:00Z
  usage '[[1, "Actions storage", 0.3, "private-a"], [1, "Actions Linux", 600, "private-a"]]'
  run_script
  [ "$(total)" -eq 1 ]
  [ "$(info)" = 'Actions minutes 30 % (600 of 2000, projection from day 7) · storage 10 % (50 MB of 500 MB, projection from day 7) · top: private-a 600 min · top storage: private-a 50 MB' ]
}

@test "start of the month without usage: 0 %, no division by zero" {
  now 2026-11-01T00:00:00Z
  echo '{"usageItems": []}' | gh_respond "$USAGE" -
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"info","check":"billing","repo":null,"message":"Actions minutes 0 % (0 of 2000, projection from day 7) · storage 0 % (0 MB of 500 MB, projection from day 7)"}' ]
}

@test "usage items of other months are left out" {
  usage '[["2026-10-31", "Actions Linux", 5000, "private-a"], ["2026-12-01", "Actions storage", 999, "private-a"],
    [17, "Actions Linux", 300, "private-a"]]'
  run_script
  [ "$(total)" -eq 1 ]
  [[ "$(info)" == 'Actions minutes 15 % (300 of 2000, projected 26 %) · storage 0 % (0 MB'* ]]
}

@test "the Linux price of another month is not used" {
  usage '[["2026-10-31", "Actions Linux", 1, "public-b", 0.1], [17, "Actions Windows", 120, "private-a"]]'
  run_script
  # 120 Windows minutes cost 1.20 = 200 Linux minutes at the fallback 0.006
  [[ "$(info)" == 'Actions minutes 10 % (200 of 2000, '* ]]
}

@test "usage API error: one check-failed, nothing else" {
  gh_fail "$USAGE" 'gh: Resource not accessible by personal access token (HTTP 403)'
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: gh: Resource not accessible by personal access token (HTTP 403)"}' ]
}

@test "plan API error: one check-failed, nothing else" {
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  gh_fail "$PLAN" 'gh: Not Found (HTTP 404)'
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: gh: Not Found (HTTP 404)"}' ]
}

@test "usage answer that is not JSON: one check-failed" {
  echo '<html>oops</html>' | gh_respond "$USAGE" -
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: cannot parse API response"}' ]
}

@test "usage answer without usageItems: one check-failed" {
  echo '{"message": "moved"}' | gh_respond "$USAGE" -
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: cannot parse API response"}' ]
}

@test "plan answer without a plan name: one check-failed" {
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  echo '{"login": "spali"}' | gh_respond "$PLAN" -
  run_script
  [ "$(jq -c . "$FINDINGS")" = '{"level":"red","check":"check-failed","repo":null,"message":"billing: cannot parse API response"}' ]
}

@test "no repositories are recorded as checked" {
  export MONITOR_CHECKED="$BATS_TEST_TMPDIR/checked"
  : >"$MONITOR_CHECKED"
  usage '[[17, "Actions Linux", 300, "private-a"]]'
  run_script
  [ ! -s "$MONITOR_CHECKED" ]
}
