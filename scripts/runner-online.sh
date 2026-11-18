#!/usr/bin/env bash
# runner-online.sh RUNS_ON fails unless a runner for RUNS_ON (JSON: a label or
# a list of labels, as monitor.runs-on) is online. GitHub-hosted labels (no
# "self-hosted") pass without a call. Self-hosted: at least one runner of the
# calling repository must be online and carry every label (case-insensitive),
# otherwise the jobs would wait in the queue until GitHub gives up after a day.
# Env: GITHUB_REPOSITORY, GH_TOKEN (Administration: read on that repository).
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

if (($# != 1)); then
  echo "usage: runner-online.sh RUNS_ON_JSON" >&2
  exit 2
fi

labels=$(jq -c 'if type == "string" then [.] else . end |
  if type == "array" and length > 0 and all(type == "string") then map(ascii_downcase)
  else error("bad") end' <<<"$1" 2>/dev/null) ||
  die "runs-on must be a label or a list of labels, got: $1"

if ! jq -e 'index("self-hosted")' <<<"$labels" >/dev/null; then
  echo "runs-on: GitHub-hosted runner"
  exit 0
fi

need_env GITHUB_REPOSITORY
repo=$GITHUB_REPOSITORY
wanted=$(jq -r 'join(", ")' <<<"$labels")
errf=$(mktemp)
trap 'rm -f "$errf"' EXIT
body=$(gh api "repos/$repo/actions/runners?per_page=100" 2>"$errf") ||
  die "cannot list the runners of $repo (the token needs Administration: read): $(head -n 1 "$errf")"

# shellcheck disable=SC2016 # jq program
jq -r --argjson want "$labels" '
  [.runners[] | {name, status, labels: [.labels[].name | ascii_downcase]}] as $all |
  [$all[] | select(.status == "online" and (.labels | contains($want)))] as $ok |
  "\($ok | length)\t\($all | length)\t\(if $all == [] then "none"
     else [$all[] | "\(.name) (\(.status))"] | join(", ") end)"' <<<"$body" |
  {
    IFS=$'\t' read -r ok all registered
    if ((ok == 0)); then
      die "no online self-hosted runner with the labels $wanted in $repo (registered: $registered): start a runner or change monitor.runs-on"
    fi
    echo "runs-on: $ok of $all runners online with labels $wanted"
  }
