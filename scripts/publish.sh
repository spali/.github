#!/usr/bin/env bash
# Publishes the files in $ASSETS_DIR (including checksums.txt).
#
#   publish.sh release  attach to the draft $DRAFT_ID and publish it at $TAG
#   publish.sh next     replace all "-next" pre-releases, notes from the draft
#   publish.sh pr       replace the dev pre-releases of pull request $PR and
#                       add or update a comment with the link
# env: TAG, VERSION, SHA, PR, DRAFT_ID, ASSETS_DIR, GH_REPO, GITHUB_SERVER_URL
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

comment_marker='<!-- release-flow:pr-dev -->'

# load_assets sets the global array "files" to the files in $ASSETS_DIR.
load_assets() {
  files=("$ASSETS_DIR"/*)
  [[ -e ${files[0]} ]] || die "no release assets found in $ASSETS_DIR"
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

publish_release() {
  need_env TAG VERSION DRAFT_ID ASSETS_DIR GH_REPO
  local prerelease=false latest=true
  load_assets
  if [[ $VERSION == *-* ]]; then
    prerelease=true
    latest=false
  fi
  gh release upload "$TAG" "${files[@]}" --clobber
  gh api -X PATCH "repos/$GH_REPO/releases/$DRAFT_ID" \
    -F draft=false -f tag_name="$TAG" -F prerelease="$prerelease" -f make_latest="$latest"
}

publish_next() {
  need_env TAG SHA DRAFT_ID ASSETS_DIR GH_REPO
  local notes
  load_assets
  notes=$(mktemp)
  {
    gh api "repos/$GH_REPO/releases/$DRAFT_ID" --jq .body
    printf '\nPre-release of the next version, built from %s.\n' "$SHA"
  } >"$notes"
  delete_releases '*-next'
  gh release create "$TAG" "${files[@]}" --target "$SHA" --prerelease --latest=false \
    --title "$TAG" --notes-file "$notes"
}

publish_pr() {
  need_env TAG SHA PR ASSETS_DIR GH_REPO GITHUB_SERVER_URL
  local body comment_id
  load_assets
  delete_releases "*-pr.$PR"
  gh release create "$TAG" "${files[@]}" --target "$SHA" --prerelease --latest=false \
    --title "$TAG" --notes "Dev build of #$PR at $SHA, not for production use."

  body=$(mktemp)
  printf '%s\nDev build of this pull request at %s: %s/%s/releases/tag/%s\n\nNot for production use. It is deleted when the pull request is closed.\n' \
    "$comment_marker" "$SHA" "$GITHUB_SERVER_URL" "$GH_REPO" "$TAG" >"$body"
  comment_id=$(gh api "repos/$GH_REPO/issues/$PR/comments" --paginate \
    --jq ".[] | select(.body | contains(\"$comment_marker\")) | .id" | head -n 1)
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
