# Finding and API helpers for the maintenance monitor, sourced by monitor-*.sh.
# shellcheck shell=bash
# shellcheck source=scripts/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MONITOR_CHECKS=(
  devbuild-closed-pr orphan-tag several-drafts next-stale pin-behind
  settings-merge settings-alerts settings-pvr settings-actions
  settings-fork-approval funding
  ruleset-main ruleset-tags main-red renovate-stale renovate-automerge workflow-disabled
  dependabot-alert code-scanning-alert unanswered stale-branch
  fork-missing fork-settings fork-behind fork-delete-candidate
  list-none list-contradiction list-external-own
  rebase-pending sync-failed contribution-stale
  adoption billing-minutes billing-storage billing
  check-failed config-invalid ignore-unused
)

# The TODO entry of each check in the overview issue (tests: one complete
# entry per MONITOR_CHECKS id): category of its info findings (decide or
# cleanup; red findings are always "Fix now"), task title, one sentence of
# explanation, and the overview areas (check groups) it can belong to, first
# match wins: the first group that applies to the repository, else the first
# one. check-failed takes the area of the check named before ":" in its
# message; config-invalid, ignore-unused and the billing checks concern no
# repository. "todo": false keeps the info findings of a check out of the
# TODO list (billing: one status line per run, nothing to do).
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
  "settings-merge": {"category": "cleanup", "areas": ["settings", "health"], "title": "Fix the merge settings",
    "text": "The merge options differ from the documented setup: fix the setting."},
  "settings-alerts": {"category": "cleanup", "areas": ["settings"], "title": "Turn on Dependabot alerts",
    "text": "Dependabot alerts are off, so vulnerable dependencies go unnoticed: enable them."},
  "settings-pvr": {"category": "cleanup", "areas": ["settings"], "title": "Turn on private vulnerability reporting",
    "text": "Reporters of a public repository cannot send a vulnerability privately: enable private vulnerability reporting."},
  "settings-actions": {"category": "cleanup", "areas": ["settings"], "title": "Fix the Actions permissions",
    "text": "Workflows get write permissions by default, or Actions may approve pull requests: set the workflow token to read-only and turn off approving pull requests."},
  "settings-fork-approval": {"category": "cleanup", "areas": ["settings", "health", "forks"], "title": "Require approval for fork pull request workflows",
    "text": "Workflows of pull requests from forks run without approval and can pick a self-hosted runner: require approval for all external contributors."},
  "funding": {"category": "cleanup", "areas": ["settings", "health", "forks"], "title": "Fix the sponsor button",
    "text": "The sponsor button does not match the repository: on in an own repository with a FUNDING.yml, off in a fork or mirror (its FUNDING.yml belongs to the upstream)."},
  "ruleset-main": {"category": "cleanup", "areas": ["settings"], "title": "Restore the main ruleset",
    "text": "The ruleset that protects `main` is missing or differs from the documented one: restore it."},
  "ruleset-tags": {"category": "cleanup", "areas": ["settings"], "title": "Restore the tag ruleset",
    "text": "The ruleset that protects release tags is missing or differs from the documented one: restore it."},
  "main-red": {"category": "cleanup", "areas": ["health"], "title": "Fix failing workflows on the default branch",
    "text": "The latest run of a workflow on the default branch failed: fix the cause and re-run it."},
  "renovate-stale": {"category": "cleanup", "areas": ["health"], "title": "Merge or close old Renovate pull requests",
    "text": "A Renovate pull request is open for more than 7 days: review and merge it, or close it."},
  "renovate-automerge": {"category": "cleanup", "areas": ["health"], "title": "Fix the Renovate auto-merge settings",
    "text": "Renovate does not merge automatic updates by rebase as soon as the required checks are green: fix `platformAutomerge` and `automergeStrategy` in the Renovate config."},
  "workflow-disabled": {"category": "cleanup", "areas": ["health"], "title": "Enable disabled workflows",
    "text": "GitHub disabled a workflow after 60 days without activity: enable it again, or delete it."},
  "dependabot-alert": {"category": "cleanup", "areas": ["health"], "title": "Handle Dependabot alerts",
    "text": "A dependency has a known vulnerability: update it, or dismiss the alert with a reason."},
  "code-scanning-alert": {"category": "cleanup", "areas": ["health"], "title": "Handle code scanning alerts",
    "text": "Code scanning found a problem in the code: fix it, or dismiss the alert with a reason."},
  "unanswered": {"category": "cleanup", "areas": ["health"], "title": "Answer waiting pull requests and issues",
    "text": "Someone waits for an answer in an open pull request or issue: answer it, close it, or ignore the item with a reason."},
  "stale-branch": {"category": "decide", "areas": ["health", "forks"], "title": "Delete branches of merged pull requests",
    "text": "The pull request of a branch is merged but the branch is left: delete it, or ignore the pull request number as item if the branch carries on."},
  "fork-missing": {"category": "cleanup", "areas": ["forks"], "title": "Create missing forks",
    "text": "A repository under `forks:` does not exist: let the sync create the fork, or fix the entry."},
  "fork-settings": {"category": "cleanup", "areas": ["forks"], "title": "Fix the settings of forks and mirrors",
    "text": "A synced fork or mirror differs from its `settings:` (default: all off), or is archived but synced: correct the setting or the entry."},
  "fork-behind": {"category": "cleanup", "areas": ["forks"], "title": "Bring forks and mirrors up to date",
    "text": "A synced fork or mirror misses upstream commits or tags for too long: read the sync run."},
  "fork-delete-candidate": {"category": "decide", "areas": ["forks"], "title": "Delete forks without own work?",
    "text": "No own commits and no open pull request upstream: delete it, archive or pin it to keep the state you reference, or put it in a List of lists.external to keep following the upstream."},
  "list-none": {"category": "cleanup", "areas": ["lists"], "title": "Add repositories to a List",
    "text": "The repository is in no List, or a fork or mirror is in none of the forks Lists: add it to the right List."},
  "list-contradiction": {"category": "decide", "areas": ["lists"], "title": "Choose one of two exclusive Lists",
    "text": "The repository is in both Lists of an exclusive pair: decide which one fits and remove it from the other."},
  "list-external-own": {"category": "cleanup", "areas": ["lists"], "title": "Move own repositories out of external Lists",
    "text": "Lists in lists.external are for repositories of others (forks and mirrors may be there): move own work to your stack List."},
  "rebase-pending": {"category": "decide", "areas": ["forks"], "title": "Rebase manual branches?",
    "text": "A `rebase: manual` branch is behind its upstream: run the sync for this branch when you are ready."},
  "sync-failed": {"category": "cleanup", "areas": ["forks"], "title": "Fix failed syncs",
    "text": "The last sync of a fork or mirror, or the sync run itself, did not succeed: read the sync log (a rebase conflict: resolve it by hand, or pin the fork)."},
  "contribution-stale": {"category": "decide", "areas": ["forks"], "title": "Follow up old pull requests upstream",
    "text": "An own pull request upstream is open for more than 90 days: ping, close or keep it."},
  "adoption": {"category": "decide", "areas": ["release"], "title": "Adopt the release flow?",
    "text": "An own repository does not use the central release flow: adopt it, or ignore the finding."},
  "billing-minutes": {"category": "cleanup", "areas": [], "title": "Keep Actions minutes within the included quota",
    "text": "Private repositories use up the included Actions minutes: move hosted jobs to a self-hosted runner or run them less often (the info line names the top repositories); raise `billing.minutes.threshold` if expected."},
  "billing-storage": {"category": "cleanup", "areas": [], "title": "Keep Actions storage within the included quota",
    "text": "Private repositories use up the included Actions storage: delete old artifacts and caches or shorten their retention (the info line names the top repositories); raise `billing.storage.threshold` if expected."},
  "billing": {"category": "cleanup", "areas": [], "todo": false, "title": "Actions usage of the account",
    "text": "The used and projected share of the included Actions minutes and storage, one line per run."},
  "check-failed": {"category": "cleanup", "areas": ["release", "settings", "health", "forks", "lists"], "title": "Fix checks that could not run",
    "text": "A check could not run (API error, missing access, bad response): read the detail and fix the cause; never ignore it."},
  "config-invalid": {"category": "cleanup", "areas": [], "title": "Fix the control file",
    "text": "The control file is missing or invalid, or names an unknown List or check: fix the file."},
  "ignore-unused": {"category": "cleanup", "areas": [], "title": "Remove unused ignores",
    "text": "An ignore in the control file matched no finding: remove it, or fix its repository or check."}
}'

# jq definitions of the repositories each check group looks at, shared by
# the workflow matrix (monitor.sh) and the overview of the report:
# groups($c; $inv) with $c the control file and $inv the inventory (anything
# but an array counts as empty) is {release, settings, health, forks: [names,
# sorted]}. forks: the inventory forks and the entries of
# `forks:` (names compared case-insensitively, the inventory spelling wins);
# health: the other repositories that are no fork.
# shellcheck disable=SC2016,SC2034 # jq program; used by monitor.sh and monitor-report.sh
MONITOR_GROUPS_JQ='
  def groups($c; $inv):
    ([$c.forks // [] | .[].repo]) as $fe |
    ([$fe[] | ascii_downcase]) as $fel |
    def entry: .name | ascii_downcase | IN($fel[]);
    (if ($inv | type) == "array" then $inv else [] end) as $inv |
    ([$inv[].name | ascii_downcase]) as $invl |
    def names(f): [$inv[] | select(f) | .name] | sort;
    {
      release: names(.central or ((.pins // []) | length > 0)),
      settings: names(.central == true),
      health: names(.fork == false and (entry | not)),
      forks: (names(.fork == true or entry)
        + [$fe[] | select(ascii_downcase | IN($invl[]) | not)] | sort)
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
  local level=$1 check=$2 repo=$3 message=$4 item=${5:-} c known=
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
  [[ -z $item || $item =~ ^[0-9]+$ ]] || die "item $item is not a number"
  jq -cn --arg level "$level" --arg check "$check" --arg repo "$repo" \
    --arg message "$message" --arg item "$item" \
    '{level: $level, check: $check, repo: (if $repo == "" then null else $repo end), message: $message}
      + (if $item == "" then {} else {item: ($item | tonumber)} end)' \
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
# pulls of UPSTREAM_REPO in STATE (open, closed or all) whose head is one of the
# branches BRANCHES_JSON (JSON array of names) of the owner of REPO to FILE:
# [{head_repo, head_ref, head_sha, number, state, merged_at, created_at,
# html_url}]. One query per branch
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
      '{head_repo: (.head.repo.full_name // ""), head_ref: .head.ref, head_sha: .head.sha, number, state, merged_at, created_at, html_url}' "$part" || return 1
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

# check_fork_approval REPO PRIVATE: settings-fork-approval. A pull request from
# a fork chooses its own runs-on (e.g. a self-hosted runner); requiring approval
# for all external contributors is the only guard. The endpoint answers 422 for
# private repositories, so they are skipped without a call (PRIVATE is "true";
# anything else counts as public). With Actions disabled no workflow can run:
# no finding. Writes findings only and always
# returns 0.
check_fork_approval() {
  local repo=$1 private=$2 body out
  if [[ $private == true ]]; then
    finding skip settings-fork-approval "$repo" "private repository"
    return 0
  fi
  body=$(fetch settings-fork-approval "$repo" "repos/$repo/actions/permissions") || return 0
  json_out settings-fork-approval "$repo" out -r '.enabled' <<<"$body" || return 0
  [[ $out != false ]] || return 0
  body=$(fetch settings-fork-approval "$repo" "repos/$repo/actions/permissions/fork-pr-contributor-approval") || return 0
  json_out settings-fork-approval "$repo" out -r '
    if .approval_policy == "all_external_contributors" then ""
    else "approval_policy: got \(.approval_policy | tojson), want \("all_external_contributors" | tojson)" end' <<<"$body" || return 0
  if [[ -n $out ]]; then
    finding red settings-fork-approval "$repo" "$out"
  fi
}

# check_funding REPO KIND: funding (info only). KIND "own": a FUNDING.yml
# without the sponsor button wastes it. KIND "fork" (forks and mirrors): the
# FUNDING.yml is the upstream's, so the button must be off. Read with GraphQL,
# REST has neither value. Writes findings only and always returns 0.
# shellcheck disable=SC2016 # GraphQL variables, no shell expansion wanted
FUNDING_QUERY='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { hasSponsorshipsEnabled fundingLinks { platform } } }'
check_funding() {
  local repo=$1 kind=$2 body out
  body=$(fetch funding "$repo" graphql -f query="$FUNDING_QUERY" \
    -f owner="${repo%%/*}" -f name="${repo#*/}") || return 0
  # shellcheck disable=SC2016 # jq program
  json_out funding "$repo" out -r --arg kind "$kind" \
    '.data.repository | if . == null then error("no repository") else . end |
     if .hasSponsorshipsEnabled == null then error("no sponsor setting") else . end |
     if $kind == "fork" then
       (if .hasSponsorshipsEnabled then "the sponsor button is on in a fork or mirror" else "" end)
     else
       (if (.fundingLinks | length) > 0 and (.hasSponsorshipsEnabled | not)
        then "FUNDING.yml exists, but the sponsor button is off" else "" end)
     end' <<<"$body" || return 0
  [[ -z $out ]] || finding info funding "$repo" "$out"
}

# Renovate config files in Renovate's order (the first one found wins). The
# merge query reads each as alias r<index>.
RENOVATE_FILES=(
  renovate.json renovate.json5 .github/renovate.json .github/renovate.json5
  .gitlab/renovate.json .gitlab/renovate.json5
  .renovaterc .renovaterc.json .renovaterc.json5
)

# check_merge REPO PRIVATE: settings-merge (expected values: README "Set up a
# new repository", step 6) and renovate-automerge (step 3), for every owned
# repository that is neither a fork nor under `forks:`. One GraphQL query reads
# the merge settings (the REST repository answers null for them to an app
# token without write access) and the Renovate config files of the default
# branch. Without a Renovate config neither allow_auto_merge nor
# renovate-automerge is checked. PRIVATE "true": under the Free plan a private
# repository has no rulesets, so no required checks, and GitHub auto-merge
# would not wait for them: platformAutomerge must be false there, and
# allow_auto_merge is not wanted. Only top-level keys of the config count
# (presets in `extends` are not resolved). Writes findings only and always
# returns 0.
merge_query() {
  local i blobs=''
  for i in "${!RENOVATE_FILES[@]}"; do
    blobs+=" r$i: object(expression: \"HEAD:${RENOVATE_FILES[i]}\") { ... on Blob { text } }"
  done
  # shellcheck disable=SC2016 # GraphQL variables, no shell expansion wanted
  printf '%s' 'query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    mergeCommitAllowed squashMergeAllowed rebaseMergeAllowed
    deleteBranchOnMerge squashMergeCommitTitle autoMergeAllowed'"$blobs"'
  }
}'
}
MERGE_QUERY=$(merge_query)

# Problems of a Renovate config (one JSON object on stdin, read with -s; $private
# is "true" or not). Prints them joined by "; ".
# shellcheck disable=SC2016 # jq program
RENOVATE_PROBLEMS='
  if length != 1 or (.[0] | type) != "object" then error("not one object") else .[0] end |
  def want(k; v): if .[k] == v then empty else "\(k): got \(.[k] | tojson), want \(v | tojson)" end;
  [ (if $private == "true" then want("platformAutomerge"; false)
     elif .platformAutomerge == false then "platformAutomerge: got false, want true"
     else empty end),
    want("automergeStrategy"; "rebase") ] | join("; ")'

check_merge() {
  local repo=$1 private=${2:-false} body out problems path text
  body=$(fetch settings-merge "$repo" graphql -f query="$MERGE_QUERY" \
    -f owner="${repo%%/*}" -f name="${repo#*/}") || return 0
  # shellcheck disable=SC2016 # jq program
  json_out settings-merge "$repo" out -c --arg private "$private" \
    --argjson files "$(printf '%s\n' "${RENOVATE_FILES[@]}" | jq -R . | jq -sc .)" \
    '.data.repository | if . == null then error("no repository") else . end | . as $g |
     ([range($files | length) as $i | select($g["r\($i)"].text != null) |
       {path: $files[$i], text: $g["r\($i)"].text}] | first) as $cfg |
     {allow_merge_commit: .mergeCommitAllowed,
      allow_squash_merge: .squashMergeAllowed,
      allow_rebase_merge: .rebaseMergeAllowed,
      delete_branch_on_merge: .deleteBranchOnMerge,
      squash_merge_commit_title: .squashMergeCommitTitle,
      allow_auto_merge: .autoMergeAllowed} as $r |
     {allow_merge_commit: false, allow_squash_merge: true,
       allow_rebase_merge: true, delete_branch_on_merge: true,
       squash_merge_commit_title: "PR_TITLE"}
     + (if $cfg != null and $private != "true" then {allow_auto_merge: true} else {} end) |
     to_entries |
     map(select($r[.key] != .value) |
       "\(.key): got \($r[.key] | tojson), want \(.value | tojson)") | join("; ") |
     {problems: ., path: $cfg.path, text: $cfg.text}' \
    <<<"$body" || return 0
  problems=$(jq -r .problems <<<"$out")
  [[ -z $problems ]] || finding red settings-merge "$repo" "$problems"
  path=$(jq -r '.path // empty' <<<"$out")
  [[ -n $path ]] || return 0
  text=$(jq -r .text <<<"$out")
  if ! problems=$(jq -rs --arg private "$private" "$RENOVATE_PROBLEMS" <<<"$text" 2>/dev/null); then
    finding red check-failed "$repo" "renovate-automerge: cannot parse $path"
    return 0
  fi
  [[ -z $problems ]] || finding red renovate-automerge "$repo" "$path: $problems"
}

# check_stale_branches REPO DEFAULT TARGET BRANCHES_FILE: stale-branch. Every
# branch of REPO (BRANCHES_FILE: [{name, sha}]) except DEFAULT that was the
# head of a merged pull request from REPO into TARGET (REPO itself, or the
# upstream of a fork) and has no open one; the newest merge counts: red when the branch
# still points at the merged head, info when it has commits after it. The
# finding carries the pull request number as item. One pulls query per branch
# (head filter, state all). Writes findings only and always returns 0.
check_stale_branches() {
  local repo=$1 default=$2 target=$3 branches=$4 names prs rows branch same n url pr
  # shellcheck disable=SC2016 # jq program
  json_out stale-branch "$repo" names -c --arg d "$default" '[.[].name | select(. != $d)]' "$branches" || return 0
  [[ $names != '[]' ]] || return 0
  prs=$(mktemp)
  # shellcheck disable=SC2064 # expand now
  trap "rm -f '$prs'; trap - RETURN" RETURN
  head_pulls stale-branch "$repo" "$target" all "$names" "$prs" || return 0
  # shellcheck disable=SC2016 # jq program
  json_out stale-branch "$repo" rows -r --arg r "$repo" --slurpfile b "$branches" '
    [.[] | select((.head_repo // "" | ascii_downcase) == ($r | ascii_downcase))] |
    group_by(.head_ref)[] | select(all(.state != "open")) |
    [.[] | select(.merged_at != null)] | max_by(.merged_at) // empty | . as $p |
    first($b[0][] | select(.name == $p.head_ref) | .sha) as $sha |
    [$p.head_ref, ($sha == $p.head_sha), $p.number, $p.html_url] | @tsv' "$prs" || return 0
  while IFS=$'\t' read -r branch same n url; do
    [[ -n $branch ]] || continue
    # the report links "#N" to REPO; a pull request upstream gets its URL
    if [[ ${target,,} == "${repo,,}" ]]; then
      pr="pull request #$n" url=
    else
      pr="pull request $target#$n" url=": $url"
    fi
    if [[ $same == true ]]; then
      finding red stale-branch "$repo" "$branch: $pr is merged, delete the branch$url" "$n"
    else
      finding info stale-branch "$repo" "$branch: $pr is merged, the branch has newer commits$url" "$n"
    fi
  done <<<"$rows"
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

# api_refs REPO OUTFILE CHECK: the same list for a private repository via
# the API. Errors are check-failed findings of CHECK.
api_refs() {
  local check=$3 kind part
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
