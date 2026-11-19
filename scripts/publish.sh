#!/usr/bin/env bash
# Publishes the files in $ASSETS_DIR (including checksums.txt), or no files
# with ASSETS=false (a repository without build, e.g. a library).
#
#   publish.sh release  attach to the draft $DRAFT_ID and publish it at $TAG
#   publish.sh next     replace all "-next" pre-releases, notes from the draft
#   publish.sh pr       replace the dev pre-releases of pull request $PR and
#                       add or update a comment with the link
# env: TAG, VERSION, SHA, PR, DRAFT_ID, ASSETS (true|false, default true),
#      ASSETS_DIR (with ASSETS=true), GH_REPO, GITHUB_SERVER_URL
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

comment_marker='<!-- release-flow:pr-dev -->'
comment_author='github-actions[bot]'

# load_assets sets the global array "files" to the files in $ASSETS_DIR,
# empty with ASSETS=false.
load_assets() {
  files=()
  case ${ASSETS:-true} in
  true) need_env ASSETS_DIR ;;
  false) return ;;
  *) die "ASSETS must be true or false, not '$ASSETS'" ;;
  esac
  files=("$ASSETS_DIR"/*)
  [[ -e ${files[0]} ]] || die "no release assets found in $ASSETS_DIR"
  need_files "$ASSETS_DIR"
}

# delete_releases deletes all releases (and tags) whose tag matches the glob.
delete_releases() {
  local glob=$1 tag
  gh release list --limit 1000 --json tagName --jq '.[].tagName' |
    while read -r tag; do
      # shellcheck disable=SC2053 # glob match on purpose
      if [[ $tag == $glob ]]; then
        gh release delete "$tag" --cleanup-tag --yes
      fi
    done
}

# delete_leftover_tag deletes the tag $TAG if it exists without a release
# (call it after deleting the releases): "gh release create --target" would
# otherwise reuse the old tag and ignore the target commit.
delete_leftover_tag() {
  # matching-refs matches by prefix (v1.0.0-pr.7 also finds v1.0.0-pr.77)
  if gh api "repos/$GH_REPO/git/matching-refs/tags/$TAG" |
    jq -e --arg ref "refs/tags/$TAG" 'any(.[]; .ref == $ref)' >/dev/null; then
    gh api -X DELETE "repos/$GH_REPO/git/refs/tags/$TAG"
  fi
}

publish_release() {
  need_env TAG VERSION SHA DRAFT_ID GH_REPO
  local prerelease=false latest=true state main_sha
  load_assets
  # the build took a while: the draft must still be this release's draft and
  # main must not have moved on (the draft's notes follow main)
  state=$(gh api "repos/$GH_REPO/releases/$DRAFT_ID" | jq -r '"\(.draft) \(.tag_name)"')
  if [[ $state != "true $TAG" ]]; then
    die "release $DRAFT_ID is no longer the draft for $TAG (draft=${state% *}, tag ${state#* })"
  fi
  main_sha=$(gh api "repos/$GH_REPO/commits/main" --jq .sha)
  if [[ $main_sha != "$SHA" ]]; then
    die "main moved to $main_sha while building $SHA, the draft now describes main; delete the tag and release again"
  fi
  if [[ $VERSION == *-* ]]; then
    prerelease=true
    latest=false
  fi
  if ((${#files[@]})); then
    gh release upload "$TAG" "${files[@]}" --clobber
  fi
  gh api -X PATCH "repos/$GH_REPO/releases/$DRAFT_ID" \
    -F draft=false -f tag_name="$TAG" -F prerelease="$prerelease" -f make_latest="$latest"
  # the -next pre-release was the build of this version
  delete_releases '*-next'
}

publish_next() {
  need_env TAG SHA DRAFT_ID GH_REPO
  local notes
  load_assets
  notes=$(mktemp)
  {
    gh api "repos/$GH_REPO/releases/$DRAFT_ID" --jq .body
    printf '\nPre-release of the next version, built from %s.\n' "$SHA"
  } >"$notes"
  delete_releases '*-next'
  delete_leftover_tag
  gh release create "$TAG" "${files[@]}" --target "$SHA" --prerelease --latest=false \
    --title "$TAG" --notes-file "$notes"
}

publish_pr() {
  need_env TAG SHA PR GH_REPO GITHUB_SERVER_URL
  local body comment_id state
  load_assets
  delete_releases "*-pr.$PR"
  delete_leftover_tag
  gh release create "$TAG" "${files[@]}" --target "$SHA" --prerelease --latest=false \
    --title "$TAG" --notes "Dev build of #$PR at $SHA, not for production use."

  # the cleanup of a pull request closed during the build ran before the
  # release existed
  state=$(gh pr view "$PR" --json state | jq -r .state)
  if [[ $state == CLOSED || $state == MERGED ]]; then
    gh release delete "$TAG" --cleanup-tag --yes
    printf '::warning::pull request #%s is %s, deleted the dev build %s\n' "$PR" "${state,,}" "$TAG"
    return
  fi

  body=$(mktemp)
  printf '%s\nDev build of this pull request at %s: %s/%s/releases/tag/%s\n\nNot for production use. It is deleted when the pull request is closed.\n' \
    "$comment_marker" "$SHA" "$GITHUB_SERVER_URL" "$GH_REPO" "$TAG" >"$body"
  # only our own comment: anyone can post a comment containing the marker
  comment_id=$(gh api "repos/$GH_REPO/issues/$PR/comments" --paginate |
    jq -rs --arg marker "$comment_marker" --arg bot "$comment_author" \
      'add // [] | map(select(.user.login == $bot and (.body | contains($marker)))) | first | .id // empty')
  if [[ -n $comment_id ]]; then
    gh api -X PATCH "repos/$GH_REPO/issues/comments/$comment_id" -F body=@"$body" >/dev/null
  else
    gh pr comment "$PR" --body-file "$body"
  fi
}

case ${1:-} in
release) publish_release ;;
next) publish_next ;;
pr) publish_pr ;;
*) die "usage: publish.sh release|next|pr" ;;
esac
