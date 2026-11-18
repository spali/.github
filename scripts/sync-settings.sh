#!/usr/bin/env bash
# Enforces the settings of ENTRY on the managed repository: the five has_*
# features, GitHub Actions and, for public repositories, the approval of fork
# pull request workflows for all external contributors. Prints "<key>: <old> -> <new>" per change or
# "settings ok". Only keys that differ are written.
#
# env: ENTRY (the object of managed_entry), GH_TOKEN.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_env ENTRY GH_TOKEN
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2153 # ENTRY comes from the environment
REPO=$(jq -r .repo <<<"$ENTRY")
[[ $REPO =~ ^spali/[A-Za-z0-9._-]+$ ]] || die "invalid repo: $REPO"

FAILED=0
# fail reports the first line of $TMP/err and remembers the failure.
fail() {
  printf 'error: %s: %s\n' "$REPO" "$(head -n 1 "$TMP/err")" >&2
  FAILED=1
}

gh api "repos/$REPO" >"$TMP/repo.json" 2>"$TMP/err" || {
  fail
  exit 1
}

# keys whose current value differs from the wanted one (null counts)
jq -r --argjson want "$(jq -c .settings <<<"$ENTRY")" \
  '. as $cur | ["has_issues","has_pull_requests","has_wiki","has_discussions","has_projects"][]
   | select($cur[.] != $want[.]) | "\(.)\t\($cur[.])\t\($want[.])"' \
  "$TMP/repo.json" >"$TMP/diff.tsv"

changed=0
if [[ -s $TMP/diff.tsv ]]; then
  changed=1
  jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[2] == "true")}] | from_entries' \
    <"$TMP/diff.tsv" >"$TMP/patch.json"
  if gh api -X PATCH "repos/$REPO" --input "$TMP/patch.json" >/dev/null 2>"$TMP/err"; then
    while IFS=$'\t' read -r key old new; do
      printf '%s: %s -> %s\n' "$key" "$old" "$new"
    done <"$TMP/diff.tsv"
  else
    fail
  fi
fi

if gh api "repos/$REPO/actions/permissions" >"$TMP/actions.json" 2>"$TMP/err"; then
  old=$(jq -r '.enabled' "$TMP/actions.json")
  new=$(jq -r '.settings.actions' <<<"$ENTRY")
  if [[ $old != "$new" ]]; then
    changed=1
    jq -n --argjson enabled "$new" '{enabled: $enabled}' >"$TMP/put.json"
    if gh api -X PUT "repos/$REPO/actions/permissions" --input "$TMP/put.json" >/dev/null 2>"$TMP/err"; then
      printf 'actions: %s -> %s\n' "$old" "$new"
    else
      fail
    fi
  fi
else
  fail
fi

# A pull request from a fork chooses its own runs-on (e.g. a self-hosted
# runner): require approval for all external contributors. Also with Actions
# off, so the guard is in place when Actions is turned on later. Public
# repositories only: the endpoint answers 422 for private ones.
APPROVAL=all_external_contributors
if [[ $(jq -r '.private' "$TMP/repo.json") != true ]]; then
  if gh api "repos/$REPO/actions/permissions/fork-pr-contributor-approval" >"$TMP/approval.json" 2>"$TMP/err"; then
    old=$(jq -r '.approval_policy' "$TMP/approval.json")
    if [[ $old != "$APPROVAL" ]]; then
      changed=1
      jq -n --arg p "$APPROVAL" '{approval_policy: $p}' >"$TMP/approval-put.json"
      if gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" \
        --input "$TMP/approval-put.json" >/dev/null 2>"$TMP/err"; then
        printf 'fork_pr_approval: %s -> %s\n' "$old" "$APPROVAL"
      else
        fail
      fi
    fi
  else
    fail
  fi
fi

[[ $FAILED -eq 0 ]] || exit 1
[[ $changed -eq 1 ]] || echo "settings ok"
