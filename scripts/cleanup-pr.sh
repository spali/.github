#!/usr/bin/env bash
# Deletes the dev pre-releases (and their tags) of a pull request.
# env: PR_NUMBER, GH_REPO (and GH_TOKEN for gh)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_env PR_NUMBER GH_REPO

gh release list --limit 1000 --json tagName --jq '.[].tagName' |
  while read -r tag; do
    if [[ $tag == *-pr."$PR_NUMBER" ]]; then
      gh release delete "$tag" --cleanup-tag --yes
    fi
  done
