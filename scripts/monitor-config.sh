#!/usr/bin/env bash
# Control file of the maintenance monitor (repos.yml).
#
#   monitor-config.sh validate FILE [--private]
#   monitor-config.sh merge PUBLIC [PRIVATE]
#   monitor-config.sh public-check FILE
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# to_json FILE prints the YAML file as JSON.
to_json() {
  [[ -r $1 ]] || die "$1: cannot read file"
  yq -o=json '.' "$1" || die "$1: invalid YAML"
}

# JQ program: prints one problem per line for the JSON document on stdin.
# Arguments: $private (bool), $checks (array of known check ids).
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
VALIDATE_JQ='
def repo_ok: type == "string" and test("^spali/[A-Za-z0-9._-]+$");
def posint: type == "number" and . == floor and . > 0;
def list_of($k): if has($k) then (.[$k] | if type == "array" then . else [] end) else [] end;
def repo_err($path; $v):
  if ($v | repo_ok) then empty else "\($path): \($v | tostring) is not a spali repository" end;
def need($e; $k; $path; test_):
  if ($e | has($k)) | not then "\($path).\($k) is required"
  elif ($e[$k] | test_) then empty
  else "\($path).\($k) is invalid" end;

if type != "object" then "top level must be a mapping" else
  (if .version != 1 then "version must be 1" else empty end),
  (keys[] | select(IN("version", "lists", "mirrors", "forks", "ignores") | not)
    | "unknown key \(.)"),
  (if $private and has("lists") then "lists is not allowed in the private file" else empty end),
  (if has("lists") and (.lists | type) != "object" then "lists must be a mapping" else empty end),
  (if (.lists | type) == "object" then
     (.lists | keys[] | select(IN("exclusive", "archive", "mirrors", "forks") | not)
       | "lists: unknown key \(.)"),
     (.lists | to_entries[] | select(.key == "archive" or .key == "mirrors")
       | select(.value | type != "string") | "lists.\(.key) must be a string"),
     (.lists | if has("forks") and (.forks | type == "array" and all(type == "string") | not)
       then "lists.forks must be a list of strings" else empty end),
     (.lists | if has("exclusive") then
        (if (.exclusive | type) != "array" then "lists.exclusive must be a list"
         else (.exclusive | to_entries[]
           | select(.value | type == "array" and length == 2 and all(type == "string") | not)
           | "lists.exclusive[\(.key)] must be a pair of strings") end)
      else empty end)
   else empty end),
  (if has("mirrors") and (.mirrors | type) != "array" then "mirrors must be a list" else empty end),
  (if has("forks") and (.forks | type) != "array" then "forks must be a list" else empty end),
  (if has("ignores") and (.ignores | type) != "array" then "ignores must be a list" else empty end),
  (list_of("mirrors") | to_entries[] | "mirrors[\(.key)]" as $p | .value
    | if type != "object" then "\($p) must be a mapping" else
        (if has("target") | not then "\($p).target is required" else repo_err("\($p).target"; .target) end),
        (if has("source") | not then "\($p).source is required"
         elif (.source | type == "string" and startswith("https://")) | not
         then "\($p).source must start with https://" else empty end),
        (if has("interval_hours") | not then "\($p).interval_hours is required"
         elif (.interval_hours | posint) | not
         then "\($p).interval_hours must be a positive integer" else empty end),
        (if has("script") and (.script | type) != "string" then "\($p).script must be a string" else empty end)
      end),
  (list_of("forks") | to_entries[] | "forks[\(.key)]" as $p | .value
    | if type != "object" then "\($p) must be a mapping" else
        (if has("repo") | not then "\($p).repo is required" else repo_err("\($p).repo"; .repo) end),
        (if has("sync_interval_hours") | not then "\($p).sync_interval_hours is required"
         elif (.sync_interval_hours | posint) | not
         then "\($p).sync_interval_hours must be a positive integer" else empty end)
      end),
  (list_of("ignores") | to_entries[] | "ignores[\(.key)]" as $p | .value
    | if type != "object" then "\($p) must be a mapping" else
        (if has("repo") | not then "\($p).repo is required" else repo_err("\($p).repo"; .repo) end),
        (if has("check") | not then "\($p).check is required"
         elif .check == "check-failed" then "\($p).check: check-failed cannot be ignored"
         elif (.check as $c | $checks | any(. == $c)) | not then "\($p).check: unknown check \(.check | tostring)"
         else empty end),
        (if (.reason | type) == "string" and (.reason | test("\\S")) then empty
         else "\($p).reason must not be empty" end)
      end),
  ([list_of("ignores")[] | select(type == "object" and has("repo") and has("check"))
    | "\(.repo) \(.check)"] | group_by(.)[] | select(length > 1) | "duplicate ignore \(.[0])")
end'

cmd_validate() {
  local file=${1:-} private=false json problems
  [[ -n $file ]] || die "usage: validate FILE [--private]"
  [[ ${2:-} != --private ]] || private=true
  json=$(to_json "$file")
  problems=$(jq -r --argjson private "$private" \
    --argjson checks "$(printf '%s\n' "${MONITOR_CHECKS[@]}" | jq -R . | jq -sc .)" \
    "$VALIDATE_JQ" <<<"$json")
  [[ -z $problems ]] && return 0
  while IFS= read -r line; do
    printf 'error: %s: %s\n' "$file" "$line" >&2
  done <<<"$problems"
  return 1
}

cmd_merge() {
  local public=${1:-} private=${2:-} pub priv='{}'
  [[ -n $public ]] || die "usage: merge PUBLIC [PRIVATE]"
  pub=$(to_json "$public")
  [[ -z $private ]] || priv=$(to_json "$private")
  jq -n --argjson pub "$pub" --argjson priv "$priv" '
    def mark($v): [(. // [])[] | . + {private: $v}];
    {version: $pub.version, lists: $pub.lists}
    + (["mirrors", "forks", "ignores"] | map({(.): (($pub[.] | mark(false)) + ($priv[.] | mark(true)))}) | add)'
}

# public-check FILE: every spali repo named in the file (values and comments)
# must be public.
cmd_public_check() {
  local file=${1:-} json repo body failed=0
  [[ -n $file ]] || die "usage: public-check FILE"
  json=$(to_json "$file")
  while IFS= read -r repo; do
    if body=$(gh api "repos/$repo" 2>/dev/null) &&
      [[ $(jq -r '.private' <<<"$body" 2>/dev/null) == false ]]; then
      continue
    fi
    printf 'error: %s: %s is not a public repository\n' "$file" "$repo" >&2
    failed=1
  done < <(
    {
      jq -r '[(.mirrors // [])[].target, (.forks // [])[].repo, (.ignores // [])[].repo]
        | map(select(type == "string" and startswith("spali/")))[]' <<<"$json"
      grep -Eo 'spali/[A-Za-z0-9._-]+' "$file" | sed 's/\.*$//' || true
    } | sort -u
  )
  return "$failed"
}

main() {
  local cmd=${1:-}
  [[ $# -eq 0 ]] || shift
  case $cmd in
    validate) cmd_validate "$@" ;;
    merge) cmd_merge "$@" ;;
    public-check) cmd_public_check "$@" ;;
    *) die "usage: monitor-config.sh validate|merge|public-check ..." ;;
  esac
}

main "$@"
