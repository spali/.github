#!/usr/bin/env bash
# Decides what to release and writes the step outputs
# kind, version, tag, sha, pr, draft-id.
#
#   prepare.sh next     after release-drafter updated the draft on main
#                       env: DRAFT_VERSION, DRAFT_ID, GITHUB_SHA
#   prepare.sh release  on a pushed tag: the tag must be the draft's tag and
#                       point to the current head of main
#                       env: GITHUB_REF_NAME, GITHUB_SHA, GH_REPO, GITHUB_WORKFLOW_REF
#   prepare.sh pr       dev build of the pull request of the current branch
#                       env: GITHUB_REF_NAME, GITHUB_SHA, DRAFT_VERSION, GH_REPO
#   prepare.sh version  checks the exception version input (empty is fine)
#                       env: VERSION
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
  need_env GITHUB_REF_NAME GITHUB_SHA GH_REPO GITHUB_WORKFLOW_REF
  local tag=$GITHUB_REF_NAME releases found_id current main_sha
  # drafts are not found by tag name, only in the release list
  # (--paginate prints one array per page, jq -s add joins them)
  releases=$(gh api "repos/$GH_REPO/releases" --paginate | jq -s 'add // []')
  found_id=$(jq -r --arg tag "$tag" '[.[] | select(.draft and .tag_name == $tag) | .id] | join(", ")' <<<"$releases")
  if [[ $found_id == *,* ]]; then
    die "several draft releases for $tag (ids $found_id); delete all but one, then re-run this run"
  fi
  if [[ -z $found_id ]]; then
    current=$(jq -r '[.[] | select(.draft) | .tag_name] | join(", ")' <<<"$releases")
    if [[ -n $current ]]; then
      die "no draft release for $tag (current draft: $current)"
    fi
    die "no draft release for $tag (no draft exists, merge a pull request first)"
  fi
  main_sha=$(gh api "repos/$GH_REPO/commits/main" --jq .sha)
  if [[ $GITHUB_SHA != "$main_sha" ]]; then
    die "tag $tag points to $GITHUB_SHA but main is at $main_sha; delete the tag and tag main again"
  fi
  # the draft is only up to date once this workflow ran successfully for
  # main's head (the run on main updates the draft)
  local workflow=${GITHUB_WORKFLOW_REF#*/*/}
  workflow=${workflow%@*}
  if ! gh api "repos/$GH_REPO/actions/runs?branch=main&head_sha=$main_sha&per_page=100" |
    jq -e --arg path "$workflow" 'any(.workflow_runs[];
      .path == $path and (.event == "push" or .event == "workflow_dispatch") and .conclusion == "success")' >/dev/null; then
    die "the draft is not up to date for main at $main_sha: no successful run of $workflow for it yet; wait for it, then re-run this run"
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

# check_version accepts SemVer 2.0.0 without build metadata ("+..." would not
# match the tag filters of release.yml) and without the pre-release suffixes
# that release.yml excludes from its tag filters.
check_version() {
  local version=${VERSION:-} id='(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
  [[ -n $version ]] || return 0
  local re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-'"$id"'(\.'"$id"')*)?$'
  if [[ ! $version =~ $re ]]; then
    die "version must be SemVer without \"v\" and without build metadata (e.g. 2.0.0-rc.1), got: $version"
  fi
  if [[ $version == *-next || $version == *-pr.* ]]; then
    die "version must not end in -next or contain -pr. (reserved for pre-releases), got: $version"
  fi
}

case ${1:-} in
next) prepare_next ;;
release) prepare_release ;;
pr) prepare_pr ;;
version) check_version ;;
*) die "usage: prepare.sh next|release|pr|version" ;;
esac
