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

# The TODO entry of each check in the overview issue (tests: one complete
# entry per MONITOR_CHECKS id): category of its info findings (decide or
# cleanup; red findings are always "Fix now"), task title, one sentence of
# explanation, and the overview areas (check groups) it can belong to, first
# match wins: the first group that applies to the repository, else the first
# one. check-failed takes the area of the check named before ":" in its
# message; config-invalid and ignore-unused concern no repository.
# shellcheck disable=SC2016,SC2034 # Markdown backticks; used by monitor-report.sh
MONITOR_TODO='{
  "devbuild-closed-pr": {"category": "cleanup", "areas": ["release"], "title": "Delete dev builds of closed pull requests",
    "text": "A `-pr.N` pre-release is left for a pull request that is closed: delete the release and its tag."},
  "orphan-tag": {"category": "cleanup", "areas": ["release"], "title": "Delete tags without a release",
    "text": "A `-next` or `-pr.N` tag has no release: delete the tag."},
  "several-drafts": {"category": "cleanup", "areas": ["release"], "title": "Keep one release draft",
    "text": "More than one draft release exists: keep the draft of the next version and delete the others."},
  "next-stale": {"category": "cleanup", "areas": ["release"], "title": "Refresh the -next pre-release",
    "text": "The `-next` pre-release is older than the latest release: re-run the Release workflow on `main`, or delete the pre-release."},
  "pin-behind": {"category": "cleanup", "areas": ["release"], "title": "Update pinned shared workflows",
    "text": "A caller pins an older release of the shared workflows: merge or fix the Renovate pull request."},
  "settings-merge": {"category": "cleanup", "areas": ["settings"], "title": "Fix the merge settings",
    "text": "The merge options differ from the documented setup: fix the setting."},
  "settings-alerts": {"category": "cleanup", "areas": ["settings"], "title": "Turn on Dependabot alerts",
    "text": "Dependabot alerts are off, so vulnerable dependencies go unnoticed: enable them."},
  "settings-pvr": {"category": "cleanup", "areas": ["settings"], "title": "Turn on private vulnerability reporting",
    "text": "Reporters of a public repository cannot send a vulnerability privately: enable private vulnerability reporting."},
  "settings-actions": {"category": "cleanup", "areas": ["settings"], "title": "Fix the Actions permissions",
    "text": "Workflows get write permissions by default, or Actions may approve pull requests: set the workflow token to read-only and turn off approving pull requests."},
  "ruleset-main": {"category": "cleanup", "areas": ["settings"], "title": "Restore the main ruleset",
    "text": "The ruleset that protects `main` is missing or differs from the documented one: restore it."},
  "ruleset-tags": {"category": "cleanup", "areas": ["settings"], "title": "Restore the tag ruleset",
    "text": "The ruleset that protects release tags is missing or differs from the documented one: restore it."},
  "main-red": {"category": "cleanup", "areas": ["health"], "title": "Fix failing workflows on the default branch",
    "text": "The latest run of a workflow on the default branch failed: fix the cause and re-run it."},
  "renovate-stale": {"category": "cleanup", "areas": ["health"], "title": "Merge or close old Renovate pull requests",
    "text": "A Renovate pull request is open for more than 7 days: review and merge it, or close it."},
  "workflow-disabled": {"category": "cleanup", "areas": ["health", "forks"], "title": "Enable disabled workflows",
    "text": "GitHub disabled a workflow after 60 days without activity: enable it again, or delete it."},
  "dependabot-alert": {"category": "cleanup", "areas": ["health"], "title": "Handle Dependabot alerts",
    "text": "A dependency has a known vulnerability: update it, or dismiss the alert with a reason."},
  "code-scanning-alert": {"category": "cleanup", "areas": ["health"], "title": "Handle code scanning alerts",
    "text": "Code scanning found a problem in the code: fix it, or dismiss the alert with a reason."},
  "fork-behind": {"category": "cleanup", "areas": ["forks"], "title": "Bring forks up to date",
    "text": "A fork is behind its upstream: sync it with the Sync fork button, or add it to `managed:` so the central sync keeps it current."},
  "fork-sync-stale": {"category": "cleanup", "areas": ["forks"], "title": "Fix the sync workflow of forks",
    "text": "A fork with its own sync workflow misses upstream commits for too long: check its sync workflow."},
  "fork-workflows-active": {"category": "cleanup", "areas": ["forks"], "title": "Turn off Actions in forks",
    "text": "Upstream workflows run in the fork and cost minutes or fail: disable Actions in the settings of the fork if unwanted."},
  "fork-delete-candidate": {"category": "decide", "areas": ["forks"], "title": "Delete forks without own work?",
    "text": "No own commits and no open pull request upstream: keep the fork only if it is in a List on purpose or you plan to work on it, else delete it."},
  "mirror-behind": {"category": "cleanup", "areas": ["mirrors"], "title": "Fix mirrors that fall behind",
    "text": "A mirror target lacks refs of its source for too long: check the mirror job."},
  "list-none": {"category": "cleanup", "areas": ["lists"], "title": "Add repositories to a List",
    "text": "The repository is in no List, or a fork is in none of the fork Lists: add it to the right List."},
  "list-contradiction": {"category": "decide", "areas": ["lists"], "title": "Choose one of two exclusive Lists",
    "text": "The repository is in both Lists of an exclusive pair: decide which one fits and remove it from the other."},
  "list-mirror-missing": {"category": "cleanup", "areas": ["lists"], "title": "Add mirrors to the mirrors List",
    "text": "A mirror target is not in the mirrors List: add it."},
  "list-archived": {"category": "cleanup", "areas": ["lists"], "title": "Move archived repositories to the archive List",
    "text": "An archived repository is still in another List: move it to the archive List."},
  "managed-missing": {"category": "cleanup", "areas": ["managed"], "title": "Create missing managed repositories",
    "text": "A repository under `managed:` does not exist: let the sync create it, or fix the entry."},
  "managed-settings": {"category": "cleanup", "areas": ["managed"], "title": "Fix the settings of managed repositories",
    "text": "A managed repository differs from its `settings:`: correct the setting or the entry."},
  "managed-behind": {"category": "cleanup", "areas": ["managed"], "title": "Bring managed repositories up to date",
    "text": "A managed repository misses upstream commits or tags for too long: read the sync run."},
  "branch-undeclared": {"category": "decide", "areas": ["managed", "forks"], "title": "Declare or delete branches with own commits",
    "text": "A branch has own commits (or is a stale upstream copy) that no `branches:` entry covers: declare it in its `managed:` entry, or delete it."},
  "rebase-pending": {"category": "decide", "areas": ["managed"], "title": "Rebase manual branches?",
    "text": "A `rebase: manual` branch is behind its upstream: run the sync for this branch when you are ready."},
  "sync-failed": {"category": "cleanup", "areas": ["managed"], "title": "Fix failed syncs",
    "text": "The last sync of a managed repository, or the sync run itself, did not succeed: read the sync log."},
  "contribution-stale": {"category": "decide", "areas": ["forks"], "title": "Follow up old pull requests upstream",
    "text": "An own pull request upstream is open for more than 90 days: ping, close or keep it."},
  "unmanaged": {"category": "decide", "areas": ["lists"], "title": "Manage repositories in the mirrors List?",
    "text": "A repository in the mirrors List is neither managed nor a mirror target: add it to `managed:`, or ignore it."},
  "adoption": {"category": "decide", "areas": ["release"], "title": "Adopt the release flow?",
    "text": "An own repository does not use the central release flow: adopt it, or ignore the finding."},
  "check-failed": {"category": "cleanup", "areas": ["release", "settings", "health", "forks", "mirrors", "managed", "lists"], "title": "Fix checks that could not run",
    "text": "A check could not run (API error, missing access, bad response): read the detail and fix the cause; never ignore it."},
  "config-invalid": {"category": "cleanup", "areas": [], "title": "Fix the control file",
    "text": "The control file is missing or invalid, or names an unknown List or check: fix the file."},
  "ignore-unused": {"category": "cleanup", "areas": [], "title": "Remove unused ignores",
    "text": "An ignore in the control file matched no finding: remove it, or fix its repository or check."}
}'

# jq definitions of the repositories each check group looks at, shared by
# the workflow matrix (monitor.sh) and the overview of the report:
# groups($c; $inv) with $c the control file and $inv the inventory (anything
# but an array counts as empty) is {release, settings, health, forks, mirrors,
# managed: [names, sorted]}. Managed repositories (names compared
# case-insensitively) are left out of health and forks; the group managed
# takes the names of the control file.
# shellcheck disable=SC2016,SC2034 # jq program; used by monitor.sh and monitor-report.sh
MONITOR_GROUPS_JQ='
  def groups($c; $inv):
    ([$c.mirrors // [] | .[].target]) as $m |
    ([$c.managed // [] | .[].repo]) as $mg |
    ([$mg[] | ascii_downcase]) as $mgl |
    def unmanaged: (.name | ascii_downcase | IN($mgl[])) | not;
    (if ($inv | type) == "array" then $inv else [] end) as $inv |
    def names(f): [$inv[] | select(f) | .name] | sort;
    {
      release: names(.central or ((.pins // []) | length > 0)),
      settings: names(.central == true),
      health: names(.fork == false and ([.name] | inside($m) | not) and unmanaged),
      forks: names(.fork == true and .parent != null and ([.name] | inside($m) | not) and unmanaged),
      mirrors: ($m | sort),
      managed: ($mg | sort)
    };'

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

# head_pulls CHECK REPO UPSTREAM_REPO STATE BRANCHES_JSON FILE writes the
# pulls of UPSTREAM_REPO in STATE (open or closed) whose head is one of the
# branches BRANCHES_JSON (JSON array of names) of the owner of REPO to FILE:
# [{head_repo, head_ref, number, created_at, html_url}]. One query per branch
# with the head filter (branch URL-encoded), never all pulls of the upstream
# (thousands for large projects). Callers still filter on head_repo == REPO.
# API errors are check-failed findings of CHECK; it then returns 1.
head_pulls() {
  local check=$1 repo=$2 up=$3 state=$4 branches=$5 out=$6 heads head part all
  # shellcheck disable=SC2016 # jq program
  json_out "$check" "$repo" heads -r --arg o "${repo%%/*}" '.[] | "\($o):\(@uri)"' <<<"$branches" || return 1
  part=$(mktemp)
  all=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$part' '$all'; trap - RETURN" RETURN
  while IFS= read -r head; do
    [[ -n $head ]] || continue
    paged "$check" "$repo" "repos/$up/pulls?state=$state&head=$head&per_page=100" \
      '{head_repo: (.head.repo.full_name // ""), head_ref: .head.ref, number, created_at, html_url}' "$part" || return 1
    cat "$part" >>"$all"
  done <<<"$heads"
  json_out "$check" "$repo" heads -s 'add // []' "$all" || return 1
  printf '%s\n' "$heads" >"$out"
}

# uri NAME prints NAME URL-encoded (for a branch name in an API path).
uri() {
  # shellcheck disable=SC2016 # jq program
  jq -rn --arg s "$1" '$s | @uri'
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

# remote_head URL prints the default branch of a remote (empty if it has
# none); fails when the remote cannot be read.
remote_head() {
  local out
  out=$(GIT_TERMINAL_PROMPT=0 timeout 120 git ls-remote --symref -- "$1" HEAD 2>/dev/null) || return 1
  awk '$1 == "ref:" && $3 == "HEAD" { sub(/^refs\/heads\//, "", $2); print $2; exit }' <<<"$out"
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
# TARGET_DEFAULT (the default branch of REPO, may be empty) are counted against
# UPSTREAM_DEFAULT, never against an upstream branch of the same name (the
# sync moves it onto the upstream default); those of any other branch against
# the upstream branch of the same name, else UPSTREAM_DEFAULT (branch names
# URL-encoded in the compare URL). API errors are
# check-failed findings of CHECK; the function then returns 1 after printing
# the branches found so far.
undeclared_branches() {
  local check=$1 repo=$2 up=$3 updef=$4 declared=$5 prs=$6 tdef=$7 tb ub list branch base uri body n
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
    [., (if . != $tdef and IN($un[]) then . else $def end | @uri), @uri] | @tsv' "$tb" || return 1
  while IFS=$'\t' read -r branch base uri; do
    [[ -n $branch ]] || continue
    body=$(fetch "$check" "$repo" "repos/$up/compare/$base...${repo%%/*}:${repo#*/}:$uri") || return 1
    json_out "$check" "$repo" n -r '.ahead_by // 0' <<<"$body" || return 1
    if ((n > 0)); then
      printf '%s\t%s\n' "$branch" "$n"
    fi
  done <<<"$list"
}
