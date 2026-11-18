#!/usr/bin/env bash
# Lists the image tags that belong to an existing dev or next release, so that
# the image cleanup keeps them: the tag of a release
# v1.2.0-pr.7 or v1.3.0-next is 1.2.0-pr.7 or 1.3.0-next.
# Writes tags=<comma separated list> to $GITHUB_OUTPUT.
# env: GH_REPO (and GH_TOKEN for gh), GITHUB_OUTPUT
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_env GH_REPO

releases=$(gh release list --limit 1000 --json tagName)
tags=$(jq -r '[.[].tagName | select(test("^v.+-(pr\\..*|next)$")) | ltrimstr("v")] | sort | join(",")' <<<"$releases")
out tags "$tags"
