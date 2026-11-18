#!/usr/bin/env bash
# Control file of the maintenance monitor (repos.yml).
#
#   monitor-config.sh validate FILE
set -euo pipefail

# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

# to_json FILE prints the YAML file as JSON.
to_json() {
  [[ -r $1 ]] || die "$1: cannot read file"
  yq -o=json '.' "$1" || die "$1: invalid YAML"
}

# JQ program: prints one problem per line for the JSON document on stdin.
# Argument: $checks (array of known check ids).
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
VALIDATE_JQ='
def repo_ok: type == "string" and test("^spali/[A-Za-z0-9._-]+$");
def posint: type == "number" and . == floor and . > 0;
def list_of($k): if has($k) then (.[$k] | if type == "array" then . else [] end) else [] end;
def repo_err($path; $v):
  if ($v | repo_ok) then empty else "\($path): \($v | tostring) is not a spali repository" end;
def on_github: type == "string" and test("^https://github\\.com(/|$)"; "i");
def gh_repo_url: test("^https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\\.git)?/?$"; "i");
def branch_ok: type == "string" and test("^[A-Za-z0-9._/-]+$") and (contains("..") | not)
  and (startswith("-") | not) and (startswith("/") | not);
# a follow pattern must compile on its own and inside the full-match wrapper
def regex_ok: . as $re | (try ("" | test($re) | ("" | test("^(?:" + $re + ")$")) | true) catch false);
def need($e; $k; $path; test_):
  if ($e | has($k)) | not then "\($path).\($k) is required"
  elif ($e[$k] | test_) then empty
  else "\($path).\($k) is invalid" end;

if type != "object" then "top level must be a mapping" else
  (if .version != 1 then "version must be 1" else empty end),
  (keys[] | select(IN("version", "monitor", "lists", "managed", "ignores", "mirrors", "forks", "unanswered") | not)
    | "unknown key \(.)"),
  (if has("forks") then "`forks:` was removed: move the entry to `managed:`" else empty end),
  (if has("mirrors") then "`mirrors:` was removed: move the entry to `managed:`" else empty end),
  (if has("monitor") and (.monitor | type) != "object" then "monitor must be a mapping" else empty end),
  (if (.monitor | type) == "object" then
     (.monitor | keys[] | select(IN("jobs", "runs-on") | not) | "monitor: unknown key \(.)"),
     (.monitor | if has("jobs") and (.jobs | IN("per-group", "per-repo") | not)
       then "monitor.jobs must be per-group or per-repo" else empty end),
     (.monitor | if has("runs-on") and (.["runs-on"] |
         (type == "string" and length > 0) or
         (type == "array" and length > 0 and all(type == "string" and length > 0)) | not)
       then "monitor.runs-on must be a label or a list of labels" else empty end)
   else empty end),
  (if has("unanswered") and (.unanswered | type) != "object" then "unanswered must be a mapping" else empty end),
  (if (.unanswered | type) == "object" then
     (.unanswered | keys[] | select(. != "days") | "unanswered: unknown key \(.)"),
     (.unanswered | if has("days") and (.days | posint | not)
       then "unanswered.days must be a positive integer" else empty end)
   else empty end),
  (if has("lists") and (.lists | type) != "object" then "lists must be a mapping" else empty end),
  (if (.lists | type) == "object" then
     (.lists | keys[] | select(IN("exclusive", "archive", "archived", "mirrors", "forks", "external") | not)
       | "lists: unknown key \(.)"),
     (.lists | if has("archive") then "`lists.archive` was removed: use `lists.archived`" else empty end),
     (.lists | if has("forks") then "`lists.forks` was removed: put the Lists under `lists.mirrors.other`" else empty end),
     (.lists | if has("mirrors") then
        (.mirrors | if type == "string" then "`lists.mirrors` is now a mapping: put the List under `lists.mirrors.synced`"
         elif type != "object" then "lists.mirrors must be a mapping"
         else (keys[] | select(IN("synced", "other") | not) | "lists.mirrors: unknown key \(.)"),
              (to_entries[] | select(.key | IN("synced", "other"))
               | select(.value | type == "array" and all(type == "string") | not)
               | "lists.mirrors.\(.key) must be a list of strings") end)
      else empty end),
     (.lists | to_entries[] | select(.key == "external" or .key == "archived")
       | select(.value | type == "array" and all(type == "string") | not)
       | "lists.\(.key) must be a list of strings"),
     (.lists | if has("exclusive") then
        (if (.exclusive | type) != "array" then "lists.exclusive must be a list"
         else (.exclusive | to_entries[]
           | select(.value | type == "array" and length == 2 and all(type == "string") | not)
           | "lists.exclusive[\(.key)] must be a pair of strings") end)
      else empty end)
   else empty end),
  (if has("ignores") and (.ignores | type) != "array" then "ignores must be a list" else empty end),
  (if has("managed") and (.managed | type) != "array" then "managed must be a list" else empty end),
  (list_of("managed") | to_entries[] | "managed[\(.key)]" as $p | .value
    | if type != "object" then "\($p) must be a mapping" else
        (keys[] | select(IN("repo", "upstream", "branches", "follow", "tags", "settings", "private") | not)
          | "\($p): unknown key \(.)"),
        (if has("repo") | not then "\($p).repo is required" else repo_err("\($p).repo"; .repo) end),
        (if has("upstream") | not then "\($p).upstream is required"
         elif (.upstream | type == "string" and startswith("https://")) | not
         then "\($p).upstream must start with https://"
         elif (.upstream | on_github) and ((.upstream | gh_repo_url) | not)
         then "\($p).upstream is not a github.com repository URL" else empty end),
        (if has("private") and (.private | type) != "boolean" then "\($p).private must be a boolean" else empty end),
        (if has("tags") and (.tags | type) != "boolean" then "\($p).tags must be a boolean" else empty end),
        (if has("follow") then
           (if (.follow | type == "array" and all(type == "string")) | not
            then "\($p).follow must be a list of strings"
            else (.follow | to_entries[] | select(.value | regex_ok | not)
              | "\($p).follow[\(.key)]: invalid regular expression") end)
         else empty end),
        (if has("branches") then
           (if (.branches | type) != "object" then "\($p).branches must be a mapping"
            else (.branches | to_entries[] | .key as $b | .value as $v
              | (if ($b | branch_ok) | not then "\($p).branches: \"\($b)\" is not a valid branch name"
                 else empty end),
                (if ($v | type) != "object" then "\($p).branches.\($b) must be a mapping" else
                   (if ($v | has("onto")) | not then "\($p).branches.\($b).onto is required"
                    elif ($v.onto | type) != "string" then "\($p).branches.\($b).onto is invalid"
                    elif ($v.onto | branch_ok) | not
                    then "\($p).branches.\($b).onto: \"\($v.onto)\" is not a valid branch name"
                    else empty end),
                   (if ($v | has("rebase") and (.rebase | IN("auto", "manual"))) | not
                    then "\($p).branches.\($b).rebase must be auto or manual" else empty end)
                 end)) end)
         else empty end),
        (if has("settings") then
           (if (.settings | type) != "object" then "\($p).settings must be a mapping"
            else (.settings | to_entries[]
              | if (.key | IN("has_issues", "has_pull_requests", "has_wiki", "has_discussions",
                              "has_projects", "actions")) | not
                then "\($p).settings: unknown key \(.key)"
                elif (.value | type) != "boolean" then "\($p).settings.\(.key) must be a boolean"
                else empty end) end)
         else empty end)
      end),
  ([list_of("managed")[] | select(type == "object" and (.repo | type) == "string") | .repo | ascii_downcase]
    | group_by(.)[] | select(length > 1) | "duplicate managed \(.[0])"),
  (list_of("ignores") | to_entries[] | "ignores[\(.key)]" as $p | .value
    | if type != "object" then "\($p) must be a mapping" else
        (if has("repo") | not then "\($p).repo is required" else repo_err("\($p).repo"; .repo) end),
        (if has("check") | not then "\($p).check is required"
         elif .check == "check-failed" then "\($p).check: check-failed cannot be ignored"
         elif (.check as $c | $checks | any(. == $c)) | not then "\($p).check: unknown check \(.check | tostring)"
         else empty end),
        (if has("item") and (.item | posint | not) then "\($p).item must be a positive integer"
         elif has("item") and (.check | IN("unanswered", "stale-branch") | not) then "\($p).item is only allowed for the checks unanswered and stale-branch" else empty end),
        (if (.reason | type) == "string" and (.reason | test("\\S")) then empty
         else "\($p).reason must not be empty" end)
      end),
  ([list_of("ignores")[] | select(type == "object" and has("repo") and has("check"))
    | "\(.repo) \(.check)\(if has("item") then " \(.item)" else "" end)"] | group_by(.)[] | select(length > 1) | "duplicate ignore \(.[0])")
end'

cmd_validate() {
  local file=${1:-} json problems
  [[ -n $file ]] || die "usage: validate FILE"
  json=$(to_json "$file")
  problems=$(jq -r \
    --argjson checks "$(printf '%s\n' "${MONITOR_CHECKS[@]}" | jq -R . | jq -sc .)" \
    "$VALIDATE_JQ" <<<"$json")
  [[ -z $problems ]] && return 0
  while IFS= read -r line; do
    printf 'error: %s: %s\n' "$file" "$line" >&2
  done <<<"$problems"
  return 1
}

main() {
  local cmd=${1:-}
  [[ $# -eq 0 ]] || shift
  case $cmd in
    validate) cmd_validate "$@" ;;
    *) die "usage: monitor-config.sh validate FILE" ;;
  esac
}

main "$@"
