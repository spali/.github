# Finding and API helpers for the maintenance monitor, sourced by monitor-*.sh.
# shellcheck shell=bash
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR_CHECKS=(
  devbuild-closed-pr orphan-tag several-drafts next-stale pin-behind
  settings-merge settings-alerts settings-pvr settings-actions
  ruleset-main ruleset-tags main-red renovate-stale workflow-disabled
  dependabot-alert code-scanning-alert self-stale
  fork-behind fork-sync-stale fork-workflows-active fork-delete-candidate
  mirror-behind list-none list-contradiction list-mirror-missing list-archived
  adoption check-failed config-invalid ignore-unused public-config-private-repo
)

# API answers that mean "not applicable" (matched as fixed substrings of the
# whole gh stderr). "Vulnerability alerts are disabled." and a plain
# "Not Found" are deliberately not listed.
NA_PATTERNS=(
  'no analysis found'
  'Upgrade to GitHub Pro or make this repository public to enable this feature.'
  'Code scanning is not enabled for this repository.'
  'Dependabot alerts are disabled for this repository.'
)

# finding LEVEL CHECK REPO MESSAGE appends one JSON line to $FINDINGS.
# REPO is - for none.
finding() {
  local level=$1 check=$2 repo=$3 message=$4 c known=
  need_env FINDINGS
  case $level in
    red | info | skip) ;;
    *) die "unknown level $level" ;;
  esac
  for c in "${MONITOR_CHECKS[@]}"; do
    [[ $c != "$check" ]] || known=1
  done
  [[ -n $known ]] || die "unknown check $check"
  [[ $repo != - ]] || repo=
  jq -cn --arg level "$level" --arg check "$check" --arg repo "$repo" \
    --arg message "$message" \
    '{level: $level, check: $check, repo: (if $repo == "" then null else $repo end), message: $message}' \
    >>"$FINDINGS"
}

# fetch CHECK REPO ARGS... runs gh api ARGS. Success: prints the body.
# Known n/a answer: skip finding, returns 2. Anything else: red check-failed
# finding, returns 1. Writes nothing to stderr and nothing to stdout on failure.
fetch() {
  local check=$1 repo=$2 body errf err line pattern
  shift 2
  errf=$(mktemp)
  if body=$(gh api "$@" 2>"$errf"); then
    rm -f "$errf"
    printf '%s\n' "$body"
    return 0
  fi
  err=$(<"$errf")
  rm -f "$errf"
  for pattern in "${NA_PATTERNS[@]}"; do
    if [[ $err == *"$pattern"* ]]; then
      line=$(grep -F -m1 -- "$pattern" <<<"$err" || true)
      finding skip "$check" "$repo" "$check: $line"
      return 2
    fi
  done
  line=$(grep -F -m1 -- '(HTTP ' <<<"$err" || true)
  [[ -n $line ]] || line=$(grep -m1 -v '^[[:space:]]*$' <<<"$err" || true)
  finding red check-failed "$repo" "$check: $line"
  return 1
}

# days_since ISO8601 prints whole days elapsed (now is $MONITOR_NOW).
days_since() {
  local then_ now
  then_=$(date -u -d "$1" +%s)
  now=${MONITOR_NOW:-$(date -u +%s)}
  printf '%d\n' $(((now - then_) / 86400))
}
