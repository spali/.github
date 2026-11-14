#!/usr/bin/env bash
# Checks a pull request before merge:
#  1. the title follows Conventional Commits (it becomes the release note entry)
#  2. the PR carries one of the labels that sort it into the release notes
# env: PR_TITLE, PR_NUMBER, GH_REPO (and GH_TOKEN for gh)
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

need_env PR_NUMBER GH_REPO

types='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'
pattern="^(${types})(\([a-z0-9._/-]+\))?!?: [^[:space:]].*$"
release_labels=(breaking-change dependencies feature fix other)

if ! [[ ${PR_TITLE:-} =~ $pattern ]]; then
  die "PR title must follow Conventional Commits: <type>[(<scope>)][!]: <description>, type one of ${types//|/, }"
fi

labels=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name')
for label in "${release_labels[@]}"; do
  if grep -qxF "$label" <<<"$labels"; then
    exit 0
  fi
done
joined=$(printf '%s, ' "${release_labels[@]}")
die "PR has none of the labels ${joined%, }"
