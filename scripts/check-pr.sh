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
# order of the release notes sections: the first label found decides
found=()
for label in breaking-change feature fix dependencies other; do
  if grep -qxF "$label" <<<"$labels"; then
    found+=("$label")
  fi
done
if ((${#found[@]} == 0)); then
  joined=$(printf '%s, ' "${release_labels[@]}")
  die "PR has none of the labels ${joined%, }"
fi
if ((${#found[@]} > 1)); then
  joined=$(printf '%s, ' "${found[@]}")
  echo "::warning::PR has several release labels (${joined%, }): the release notes use ${found[0]}. Remove the labels that do not apply."
fi
