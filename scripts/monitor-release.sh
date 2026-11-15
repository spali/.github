#!/usr/bin/env bash
# Release-flow checks for central repositories (devbuild-closed-pr, orphan-tag,
# several-drafts, next-stale) and pin-behind for every repository that pins a
# shared workflow, central or not. Writes findings only.
# Env: FINDINGS INVENTORY CONFIG (file paths); optional MONITOR_NOW.
set -euo pipefail
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

need_env FINDINGS INVENTORY CONFIG

CENTRAL=spali/.github
MIN_PIN_AGE_DAYS=7

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# check_releases REPO prints findings from $WORK/{releases,pulls,tags}.json
# (a missing pulls/tags file skips that check).
# shellcheck disable=SC2016 # jq programs, $vars are jq variables
check_releases() {
  local repo=$1 rel=$WORK/releases.json lines tag number latest

  if [[ -f $WORK/pulls.json ]] &&
    json_out devbuild-closed-pr "$repo" lines -r --slurpfile pulls "$WORK/pulls.json" \
      '.[] | select(.tag_name | test("^v.+-pr\\.[0-9]+$")) |
       (.tag_name | capture("-pr\\.(?<n>[0-9]+)$").n) as $n |
       select(($pulls[0] | map(.number | tostring) | index($n)) == null) |
       [.tag_name, $n] | @tsv' "$rel"; then
    while IFS=$'\t' read -r tag number; do
      [[ -z $tag ]] || finding red devbuild-closed-pr "$repo" "$tag: PR #$number is not open"
    done <<<"$lines"
  fi

  if [[ -f $WORK/tags.json ]] &&
    json_out orphan-tag "$repo" lines -r --slurpfile releases "$rel" \
      '.[] | .name | select(test("-next$|-pr\\.[0-9]+$")) |
       select(. as $t | $releases[0] | map(.tag_name) | index($t) | not)' "$WORK/tags.json"; then
    while IFS= read -r tag; do
      [[ -z $tag ]] || finding red orphan-tag "$repo" "$tag has no release"
    done <<<"$lines"
  fi

  if json_out several-drafts "$repo" lines -r \
    '[.[] | select(.draft) | .tag_name] | if length > 1 then join(", ") else empty end' "$rel" &&
    [[ -n $lines ]]; then
    finding red several-drafts "$repo" "drafts: $lines"
  fi

  if json_out next-stale "$repo" latest -r \
    '[.[] | select(.draft == false and .prerelease == false)] |
     max_by(.published_at) | if . then .tag_name else empty end' "$rel" &&
    [[ -n $latest ]] &&
    json_out next-stale "$repo" lines -r \
      '([.[] | select(.draft == false and .prerelease == false)] |
        max_by(.published_at) | .published_at) as $newest |
       .[] | select(.tag_name | test("-next$")) |
       select(.created_at < $newest) | .tag_name' "$rel"; then
    while IFS= read -r tag; do
      [[ -z $tag ]] || finding red next-stale "$repo" "$tag is older than $latest"
    done <<<"$lines"
  fi
}

# check_pins REPO PINS LATEST_TAG LATEST_SHA prints one pin-behind finding.
check_pins() {
  local repo=$1 pins=$2 tag=$3 sha=$4 list
  if ! list=$(jq -r --arg sha "$sha" \
    '[.[] | select(.sha != $sha) | "\(.workflow) pinned to \(.version // .sha[0:7])"] |
     unique | join(", ")' 2>/dev/null <<<"$pins"); then
    parse_failed pin-behind "$repo"
    return 0
  fi
  [[ -z $list ]] || finding red pin-behind "$repo" "$list, latest $tag"
}

main() {
  local repos repo central pins releases_ok latest_tag='' latest_sha='' latest_published latest_json commit_json
  local trim_rel='{tag_name, draft, prerelease, created_at, published_at}'

  if latest_json=$(fetch pin-behind "$CENTRAL" "repos/$CENTRAL/releases/latest"); then
    if latest_tag=$(jq -er '.tag_name' 2>/dev/null <<<"$latest_json") &&
      latest_published=$(jq -er '.published_at | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' 2>/dev/null <<<"$latest_json") &&
      days_since "$latest_published" >/dev/null 2>&1; then
      if commit_json=$(fetch pin-behind "$CENTRAL" "repos/$CENTRAL/commits/$latest_tag"); then
        if latest_sha=$(jq -er '.sha' 2>/dev/null <<<"$commit_json"); then
          if [[ $(days_since "$latest_published") -lt $MIN_PIN_AGE_DAYS ]]; then
            latest_sha=
          fi
        else
          latest_sha=
          parse_failed pin-behind "$CENTRAL"
        fi
      fi
    else
      parse_failed pin-behind "$CENTRAL"
    fi
  fi

  if ! repos=$(jq -r '.[] | select(.central or ((.pins // []) | length > 0)) |
      [.name, (.central // false)] | @tsv' "$INVENTORY" 2>/dev/null); then
    finding red check-failed - "release checks: cannot parse inventory"
    return 0
  fi
  while IFS=$'\t' read -r repo central; do
    [[ -n $repo ]] || continue
    pins=$(jq -c --arg r "$repo" '[.[] | select(.name == $r) | (.pins // [])[]]' "$INVENTORY" 2>/dev/null) || pins='[]'

    if [[ $central == true ]]; then
      rm -f "$WORK"/*.json
      releases_ok=
      paged devbuild-closed-pr "$repo" "repos/$repo/releases?per_page=100" "$trim_rel" "$WORK/releases.json" && releases_ok=1
      if [[ -n $releases_ok ]]; then
        paged devbuild-closed-pr "$repo" "repos/$repo/pulls?state=open&per_page=100" '{number}' "$WORK/pulls.json" || true
        paged orphan-tag "$repo" "repos/$repo/tags?per_page=100" '{name}' "$WORK/tags.json" || true
        check_releases "$repo"
      fi
    fi

    [[ -z $latest_sha ]] || check_pins "$repo" "$pins" "$latest_tag" "$latest_sha"
  done <<<"$repos"
}

main
