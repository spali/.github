#!/usr/bin/env bash
# Creates the fork or mirror of ENTRY when it does not exist.
#
# Prints "exists", "created fork" or fails. A repository that exists with
# the wrong kind (or the wrong parent) is never modified.
#
# env: ENTRY (the object of fork_entry), GH_TOKEN, optional
#      SYNC_POLL_SLEEP (seconds between the visibility polls, default 3).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_env ENTRY GH_TOKEN
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC2153 # ENTRY comes from the environment
entry_get() { jq -r "$1" <<<"$ENTRY"; }
REPO=$(entry_get .repo)
KIND=$(entry_get .kind)
UPSTREAM_REPO=$(entry_get '.upstream_repo // ""')
[[ $REPO =~ ^spali/[A-Za-z0-9._-]+$ ]] || die "invalid repo: $REPO"
[[ $KIND == fork || $KIND == mirror ]] || die "invalid kind: $KIND"
# mirrors have no upstream_repo (null)
[[ $KIND == mirror || $UPSTREAM_REPO =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] ||
  die "invalid upstream_repo: $UPSTREAM_REPO"

# get_repo fetches repos/<repo> into $TMP/repo.json. Returns 0 when it
# exists, 1 on 404, and dies on any other error.
get_repo() {
  if gh api "repos/$REPO" >"$TMP/repo.json" 2>"$TMP/err"; then
    return 0
  fi
  if grep -q '(HTTP 404)' "$TMP/err"; then
    return 1
  fi
  die "$REPO: $(head -n 1 "$TMP/err")"
}

# check_kind fails unless $TMP/repo.json matches the kind of the entry.
check_kind() {
  local parent
  if [[ $KIND == fork ]]; then
    parent=$(jq -r 'if .fork == true then .parent.full_name // "" else "" end' "$TMP/repo.json")
    [[ -n $parent && ${parent,,} == "${UPSTREAM_REPO,,}" ]] ||
      die "$REPO exists but is not a fork of $UPSTREAM_REPO"
  else
    [[ $(jq -r '.fork == true' "$TMP/repo.json") == false ]] ||
      die "$REPO exists but is a fork, not a mirror"
  fi
}

if get_repo; then
  check_kind
  echo exists
  exit 0
fi

if [[ $KIND == mirror ]]; then
  # Installation tokens cannot create repositories of a user account.
  visibility=--public
  [[ $(entry_get .private) != true ]] || visibility=--private
  die "create $REPO by hand: gh repo create $REPO $visibility"
fi

# a follow pattern may need other branches; tags are fetched by the sync
only_default=true
[[ $(entry_get '.follow | length') == 0 ]] || only_default=false
jq -n --arg name "${REPO#*/}" --argjson only "$only_default" \
  '{name: $name, default_branch_only: $only}' >"$TMP/fork.json"
gh api -X POST "repos/$UPSTREAM_REPO/forks" --input "$TMP/fork.json" >/dev/null 2>"$TMP/err" ||
  die "$REPO: $(head -n 1 "$TMP/err")"

visible=false
for ((i = 0; i < 10; i++)); do
  if get_repo; then
    visible=true
    break
  fi
  sleep "${SYNC_POLL_SLEEP:-3}"
done
[[ $visible == true ]] || die "fork $REPO not visible after creation"
check_kind
echo "created fork"
