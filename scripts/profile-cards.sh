#!/usr/bin/env bash
# Checks the card list of the profile cards workflow and commits the
# rendered cards to the profile repository.
#
#   profile-cards.sh check          validates PROFILE_CARDS and prints it
#                                   compact (the matrix of the card jobs)
#   profile-cards.sh commit SRC_DIR checks PROFILE_CARDS, clones TARGET_URL
#                                   into $WORK/repo, copies SRC_DIR/<path> of
#                                   every card there and, when a card
#                                   changed, commits and pushes; prints
#                                   "unchanged" or "pushed <sha>"
#
# PROFILE_CARDS is a JSON array of {card, options, path}: card is one of
# stats, top-langs, pin, wakatime, gist; path is a relative path ending in
# .svg, without empty, . or .. segments, outside .git and unique in the list.
# The push is a plain push: it fails when the branch moved meanwhile. git gets
# the token only through GIT_CONFIG_COUNT/KEY/VALUE (an extraheader for
# https://github.com/), never in an argument or URL.
#
# env: PROFILE_CARDS; commit: TARGET_URL, WORK, optional PROFILE_BRANCH
#      (default: the default branch of the target), GH_TOKEN (none: no
#      extraheader), GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL (also the
#      author).
# Exit status: 0 ok, 1 refused or failed, 2 usage error.
set -euo pipefail

MESSAGE='chore: update profile cards'

usage() {
  echo "usage: profile-cards.sh check | commit SRC_DIR" >&2
  exit 2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

# check prints PROFILE_CARDS compact or fails with the first problem.
check() {
  local problem
  [[ -n ${PROFILE_CARDS+x} ]] || usage
  problem=$(jq -r '
    def bad_path: test("^/") or (split("/") | any(. == "" or . == "." or . == ".."))
      or test("^\\.git(/|$)") or (test("\\.svg$") | not);
    if type != "array" then "the card list is not a JSON array"
    elif length == 0 then "the card list is empty"
    elif any(.[]; type != "object") then "unknown card: \(first(.[] | select(type != "object")) | tojson)"
    else [(map(select(.card | IN("stats", "top-langs", "pin", "wakatime", "gist") | not))
           | if length > 0 then "unknown card: \(.[0].card | tojson)" else empty end),
          (map(select((.path | type) != "string" or (.path | bad_path)))
           | if length > 0 then "invalid path: \(.[0].path | tojson)" else empty end),
          (map(.path) | group_by(.) | map(select(length > 1)[0])
           | if length > 0 then "duplicate path: \(.[0])" else empty end)] | first // empty
    end' <<<"$PROFILE_CARDS" 2>/dev/null) || fail "the card list is not valid JSON"
  [[ -z $problem ]] || fail "$problem"
  jq -c . <<<"$PROFILE_CARDS"
}

# git_auth sets GIT_AUTH, the base64 credential of the extraheader. In GitHub
# Actions it is masked first: the runner masks GH_TOKEN, not its encoding.
git_auth() {
  GIT_AUTH=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
  [[ ${GITHUB_ACTIONS:-} != true ]] || printf '::add-mask::%s\n' "$GIT_AUTH"
}

# g runs git, with the token as extraheader when GH_TOKEN is set.
g() {
  if [[ -n ${GH_TOKEN:-} ]]; then
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
      GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $GIT_AUTH" git "$@"
  else
    git "$@"
  fi
}

commit() {
  local src=$1 repo path head
  local -a paths
  check >/dev/null
  mapfile -t paths < <(jq -r '.[].path' <<<"$PROFILE_CARDS")
  for path in "${paths[@]}"; do
    [[ -f $src/$path ]] || fail "card file missing: $path"
  done
  [[ -n ${GIT_COMMITTER_NAME:-} && -n ${GIT_COMMITTER_EMAIL:-} ]] ||
    fail "no committer: set GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL"
  export GIT_AUTHOR_NAME=$GIT_COMMITTER_NAME GIT_AUTHOR_EMAIL=$GIT_COMMITTER_EMAIL
  export GIT_TERMINAL_PROMPT=0
  [[ -z ${GH_TOKEN:-} ]] || git_auth
  repo=$WORK/repo
  g clone -q --depth 1 ${PROFILE_BRANCH:+--branch "$PROFILE_BRANCH"} "$TARGET_URL" "$repo"
  for path in "${paths[@]}"; do
    mkdir -p "$(dirname "$repo/$path")"
    cp "$src/$path" "$repo/$path"
    git -C "$repo" add -- "$path"
  done
  if git -C "$repo" diff --cached --quiet; then
    echo unchanged
    return
  fi
  git -C "$repo" commit -q -m "$MESSAGE"
  g -C "$repo" push -q origin HEAD || fail "push rejected (the branch moved?); re-run"
  head=$(git -C "$repo" rev-parse HEAD)
  echo "pushed $head"
}

case ${1:-} in
check) [[ $# -eq 1 ]] || usage; check ;;
commit) [[ $# -eq 2 ]] || usage; commit "$2" ;;
*) usage ;;
esac
