# Finding and API helpers for the maintenance monitor, sourced by monitor-*.sh.
# shellcheck shell=bash
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR_CHECKS=(
  devbuild-closed-pr orphan-tag several-drafts next-stale pin-behind
  settings-merge settings-alerts settings-pvr settings-actions
  ruleset-main ruleset-tags main-red renovate-stale workflow-disabled
  dependabot-alert code-scanning-alert
  fork-behind fork-sync-stale fork-workflows-active fork-delete-candidate
  mirror-behind list-none list-contradiction list-mirror-missing list-archived
  managed-missing managed-settings managed-behind branch-undeclared
  rebase-pending sync-failed contribution-stale unmanaged
  adoption check-failed config-invalid ignore-unused
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

# checked REPO appends REPO to $MONITOR_CHECKED (if set): the run log lists
# every repository a check script looked at, also those without findings.
checked() {
  [[ -z ${MONITOR_CHECKED:-} ]] || printf '%s\n' "$1" >>"$MONITOR_CHECKED"
}

# err_line FILE prints the line of a gh stderr file that names the failure:
# the one containing "(HTTP ", else the first non-empty line.
err_line() {
  local line
  line=$(grep -F -m1 -- '(HTTP ' "$1" || true)
  [[ -n $line ]] || line=$(grep -m1 -v '^[[:space:]]*$' "$1" || true)
  printf '%s\n' "$line"
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
  line=$(err_line "$errf")
  rm -f "$errf"
  for pattern in "${NA_PATTERNS[@]}"; do
    if [[ $err == *"$pattern"* ]]; then
      line=$(grep -F -m1 -- "$pattern" <<<"$err" || true)
      finding skip "$check" "$repo" "$check: $line"
      return 2
    fi
  done
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

# parse_failed CHECK REPO records an unreadable API response as check-failed.
parse_failed() {
  finding red check-failed "$2" "$1: cannot parse API response"
}

# paged CHECK REPO PATH FIELDS FILE reads all pages of PATH, keeps only FIELDS
# (a jq object construction) and writes the JSON array to FILE.
paged() {
  local body trimmed
  body=$(fetch "$1" "$2" "$3" --paginate) || return 1
  if ! trimmed=$(jq -s "add // [] | map($4)" 2>/dev/null <<<"$body"); then
    parse_failed "$1" "$2"
    return 1
  fi
  printf '%s\n' "$trimmed" >"$5"
}

# json_out CHECK REPO OUTVAR JQ_ARGS... runs jq, stores its output in OUTVAR.
# On failure records check-failed and returns 1.
json_out() {
  local check=$1 repo=$2 var=$3 json_result
  shift 3
  if ! json_result=$(jq "$@" 2>/dev/null); then
    parse_failed "$check" "$repo"
    return 1
  fi
  printf -v "$var" '%s' "$json_result"
}

# disabled_workflows CHECK REPO OUTVAR reads a workflows API body on stdin and
# stores one line per workflow GitHub disabled for inactivity in OUTVAR.
disabled_workflows() {
  json_out "$1" "$2" "$3" -r '
    .workflows // [] | .[] | select(.state == "disabled_inactivity") |
    "\(.name) (\(.path)) disabled by GitHub after 60 days of inactivity"'
}

# ls_remote URL OUTFILE writes "<ref> <sha>" lines (peeled ^{} refs dropped).
ls_remote() {
  local raw
  raw=$(mktemp)
  if ! GIT_TERMINAL_PROMPT=0 timeout 120 git ls-remote --heads --tags "$1" >"$raw" 2>/dev/null; then
    rm -f "$raw"
    return 1
  fi
  awk -F'\t' 'NF == 2 && $2 !~ /\^\{\}$/ {print $2, $1}' "$raw" >"$2"
  rm -f "$raw"
}

# api_refs REPO OUTFILE [CHECK]: the same list for a private repository via
# the API. Errors are check-failed findings of CHECK (default mirror-behind).
api_refs() {
  local check=${3:-mirror-behind} kind part
  : >"$2"
  for kind in heads tags; do
    part=$(mktemp)
    if ! paged "$check" "$1" "repos/$1/git/matching-refs/$kind" \
      '{ref, sha: .object.sha}' "$part"; then
      rm -f "$part"
      return 1
    fi
    if ! jq -r '.[] | "\(.ref) \(.sha)"' "$part" >>"$2" 2>/dev/null; then
      parse_failed "$check" "$1"
      rm -f "$part"
      return 1
    fi
    rm -f "$part"
  done
}

# undeclared_branches CHECK REPO UPSTREAM_REPO UPSTREAM_DEFAULT DECLARED_JSON
# OPEN_PRS_FILE TARGET_DEFAULT prints "branch<TAB>n" for every branch of REPO
# with n > 0 own commits that is not declared (DECLARED_JSON: JSON array of
# branch names) and not the head of an open upstream pull request from REPO
# (OPEN_PRS_FILE: JSON array of {head_repo, head_ref}). Own commits of
# TARGET_DEFAULT (the default branch of REPO) are counted against
# UPSTREAM_DEFAULT, never against an upstream branch of the same name (the
# sync moves it onto the upstream default); those of any other branch against
# the upstream branch of the same name, else UPSTREAM_DEFAULT. API errors are
# check-failed findings of CHECK; the function then returns 1 after printing
# the branches found so far.
undeclared_branches() {
  local check=$1 repo=$2 up=$3 updef=$4 declared=$5 prs=$6 tdef=$7 tb ub list branch base body n
  tb=$(mktemp)
  ub=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$tb' '$ub'; trap - RETURN" RETURN
  paged "$check" "$repo" "repos/$repo/branches?per_page=100" '{name}' "$tb" || return 1
  paged "$check" "$repo" "repos/$up/branches?per_page=100" '{name}' "$ub" || return 1
  # shellcheck disable=SC2016 # jq program
  json_out "$check" "$repo" list -r --argjson d "$declared" --arg r "$repo" --arg def "$updef" \
    --arg tdef "$tdef" --slurpfile u "$ub" --slurpfile p "$prs" '
    [$u[0][].name] as $un |
    [$p[0][] | select((.head_repo // "" | ascii_downcase) == ($r | ascii_downcase)) | .head_ref] as $contrib |
    .[] | .name | select(IN($d[]) or IN($contrib[]) | not) |
    [., (if . != $tdef and IN($un[]) then . else $def end)] | @tsv' "$tb" || return 1
  while IFS=$'\t' read -r branch base; do
    [[ -n $branch ]] || continue
    body=$(fetch "$check" "$repo" "repos/$up/compare/$base...${repo%%/*}:${repo#*/}:$branch") || return 1
    json_out "$check" "$repo" n -r '.ahead_by // 0' <<<"$body" || return 1
    if ((n > 0)); then
      printf '%s\t%s\n' "$branch" "$n"
    fi
  done <<<"$list"
}
