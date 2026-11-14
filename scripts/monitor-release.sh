#!/usr/bin/env bash
# Release-flow checks for central repositories: devbuild-closed-pr, orphan-tag,
# several-drafts, next-stale and pin-behind. Writes findings only.
# Env: FINDINGS INVENTORY CONFIG (file paths); optional MONITOR_NOW.
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

CENTRAL=spali/.github
MIN_PIN_AGE_DAYS=7

# paged CHECK REPO PATH prints all pages of PATH as one JSON array.
paged() {
  local body
  body=$(fetch "$1" "$2" "$3" --paginate) || return 1
  jq -s 'add // []' <<<"$body"
}

# check_releases REPO RELEASES PULLS TAGS prints findings (PULLS/TAGS empty = skip that check).
check_releases() {
  local repo=$1 releases=$2 pulls=$3 tags=$4 tag
  local latest drafts

  if [[ -n $pulls ]]; then
    while IFS=$'\t' read -r tag number; do
      finding red devbuild-closed-pr "$repo" "$tag: PR #$number is not open"
    done < <(jq -r --argjson pulls "$pulls" \
      '.[] | select(.tag_name | test("^v.+-pr\\.[0-9]+$")) |
       (.tag_name | capture("-pr\\.(?<n>[0-9]+)$").n) as $n |
       select(($pulls | map(.number | tostring) | index($n)) == null) |
       [.tag_name, $n] | @tsv' <<<"$releases")
  fi

  if [[ -n $tags ]]; then
    while IFS= read -r tag; do
      finding red orphan-tag "$repo" "$tag has no release"
    done < <(jq -r --argjson releases "$releases" \
      '.[] | .name | select(test("-next$|-pr\\.[0-9]+$")) |
       select(. as $t | $releases | map(.tag_name) | index($t) | not)' <<<"$tags")
  fi

  drafts=$(jq -r '[.[] | select(.draft) | .tag_name] | if length > 1 then join(", ") else empty end' <<<"$releases")
  [[ -z $drafts ]] || finding red several-drafts "$repo" "drafts: $drafts"

  latest=$(jq -r '[.[] | select(.draft == false and .prerelease == false)] |
    max_by(.published_at) | if . then .tag_name else empty end' <<<"$releases")
  if [[ -n $latest ]]; then
    while IFS= read -r tag; do
      finding red next-stale "$repo" "$tag is older than $latest"
    done < <(jq -r '([.[] | select(.draft == false and .prerelease == false)] |
        max_by(.published_at) | .published_at) as $newest |
      .[] | select(.tag_name | test("-next$")) |
      select(.created_at < $newest) | .tag_name' <<<"$releases")
  fi
}

# check_pins REPO PINS LATEST_TAG LATEST_SHA prints one pin-behind finding.
check_pins() {
  local repo=$1 pins=$2 tag=$3 sha=$4 list
  list=$(jq -r --arg sha "$sha" \
    '[.[] | select(.sha != $sha) | "\(.workflow) pinned to \(.version // .sha[0:7])"] |
     unique | join(", ")' <<<"$pins")
  [[ -z $list ]] || finding red pin-behind "$repo" "$list, latest $tag"
}

main() {
  local repos repo pins releases pulls tags
  local latest_tag='' latest_sha='' latest_published latest_json commit_json

  if latest_json=$(fetch pin-behind "$CENTRAL" "repos/$CENTRAL/releases/latest"); then
    latest_tag=$(jq -r '.tag_name' <<<"$latest_json")
    latest_published=$(jq -r '.published_at' <<<"$latest_json")
    if commit_json=$(fetch pin-behind "$CENTRAL" "repos/$CENTRAL/commits/$latest_tag"); then
      latest_sha=$(jq -r '.sha' <<<"$commit_json")
      if [[ $(days_since "$latest_published") -lt $MIN_PIN_AGE_DAYS ]]; then
        latest_sha=
      fi
    fi
  fi

  repos=$(jq -r '.[] | select(.central) | .name' "$INVENTORY")
  while IFS= read -r repo; do
    [[ -n $repo ]] || continue
    pins=$(jq -c --arg r "$repo" '.[] | select(.name == $r) | .pins' "$INVENTORY")

    if releases=$(paged devbuild-closed-pr "$repo" "repos/$repo/releases?per_page=100"); then
      pulls=$(paged devbuild-closed-pr "$repo" "repos/$repo/pulls?state=open&per_page=100") || pulls=
      tags=$(paged orphan-tag "$repo" "repos/$repo/tags?per_page=100") || tags=
      check_releases "$repo" "$releases" "$pulls" "$tags"
    fi

    [[ -z $latest_sha ]] || check_pins "$repo" "$pins" "$latest_tag" "$latest_sha"
  done <<<"$repos"
}

main
