#!/usr/bin/env bash
# Decides what to release and writes the step outputs
# kind, version, tag, sha, pr, draft-id.
#
#   prepare.sh next     after release-drafter updated the draft on main
#                       env: DRAFT_VERSION, DRAFT_ID, GITHUB_SHA
#   prepare.sh release  on a pushed tag: the tag must be the draft's tag and
#                       point to the current head of main
#                       env: GITHUB_REF_NAME, GITHUB_SHA, GH_REPO
#   prepare.sh pr       dev build of the pull request of the current branch
#                       env: GITHUB_REF_NAME, GITHUB_SHA, DRAFT_VERSION, GH_REPO
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

emit() { # kind version sha pr draft-id
  out kind "$1"
  out version "$2"
  out tag "v$2"
  out sha "$3"
  out pr "$4"
  out draft-id "$5"
}

prepare_next() {
  need_env DRAFT_VERSION DRAFT_ID GITHUB_SHA
  emit next "$DRAFT_VERSION-next" "$GITHUB_SHA" "" "$DRAFT_ID"
}

prepare_release() {
  need_env GITHUB_REF_NAME GITHUB_SHA GH_REPO
  local tag=$GITHUB_REF_NAME releases found_id current main_sha
  # drafts are not found by tag name, only in the release list
  releases=$(gh release list --limit 1000 --json tagName,isDraft,databaseId)
  found_id=$(jq -r --arg tag "$tag" '.[] | select(.isDraft and .tagName == $tag) | .databaseId' <<<"$releases")
  if [[ -z $found_id ]]; then
    current=$(jq -r '[.[] | select(.isDraft) | .tagName] | join(", ")' <<<"$releases")
    if [[ -n $current ]]; then
      die "no draft release for $tag (current draft: $current)"
    fi
    die "no draft release for $tag (no draft exists, merge a pull request first)"
  fi
  main_sha=$(gh api "repos/$GH_REPO/commits/main" --jq .sha)
  if [[ $GITHUB_SHA != "$main_sha" ]]; then
    die "tag $tag points to $GITHUB_SHA but main is at $main_sha; delete the tag and tag main again"
  fi
  emit release "${tag#v}" "$GITHUB_SHA" "" "$found_id"
}

prepare_pr() {
  need_env GITHUB_REF_NAME GITHUB_SHA DRAFT_VERSION GH_REPO
  local branch=$GITHUB_REF_NAME number
  if [[ $branch == main ]]; then
    die "run the dev build on a pull request branch, not main"
  fi
  number=$(gh pr list --head "$branch" --base main --state open --json number,isCrossRepository |
    jq -r '[.[] | select(.isCrossRepository | not)][0].number // empty')
  if [[ -z $number ]]; then
    die "branch $branch has no open pull request to main"
  fi
  emit pr "$DRAFT_VERSION-pr.$number" "$GITHUB_SHA" "$number" ""
}

case ${1:-} in
next) prepare_next ;;
release) prepare_release ;;
pr) prepare_pr ;;
*) die "usage: prepare.sh next|release|pr" ;;
esac
