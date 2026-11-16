#!/usr/bin/env bash
# Sync of the managed forks and mirrors (key `managed:` of the control file),
# one step of the reusable workflow sync.yml per mode.
#
#   sync.sh matrix       prints {"repos": [...], "runs-on": ...} for the
#                        workflow matrix: all managed repositories, or only
#                        SYNC_REPO (matched case-insensitively, printed as
#                        spelled in the control file; unknown: fails).
#   sync.sh exists REPO  prints name=<repo without owner> and exists=true or
#                        exists=false (to $GITHUB_OUTPUT if set); fails on
#                        any other API error.
#   sync.sh create REPO  creates the missing fork (sync-create.sh). A missing
#                        mirror fails with the command to create it by hand.
#                        Forking needs an installation token that is not
#                        scoped to repositories.
#   sync.sh repo REPO    refuses a repository that does not exist, then checks
#                        its kind (sync-create.sh), enforces its settings
#                        (sync-settings.sh), lists the contribution branches
#                        of a fork (heads of open upstream pull requests from
#                        REPO) and syncs its refs (sync-git.sh plan, push).
#                        The git steps still run after a settings failure;
#                        they are skipped when the kind check, the
#                        contribution lookup or the committer lookup failed.
#                        A failed plan skips the push.
#
# REPO is looked up exactly as spelled in the control file and must be listed
# under `managed:`. Every write goes to that repository only: its URL is built
# here from the entry (https://github.com/<repo>.git), never taken from input.
# git gets the token only through GIT_CONFIG_COUNT/KEY/VALUE (an extraheader
# for https://github.com/), and only in the git steps.
# create and repo append a Markdown section to $GITHUB_STEP_SUMMARY (if set).
#
# env: GH_TOKEN, MONITOR_CONFIG (default repos.yml), MONITOR_SCRIPTS_DIR
#      (default: this script's directory), optional SYNC_REPO (matrix) and
#      SYNC_BRANCH (a branch name or *, rebases manual branches; needs
#      SYNC_REPO), repo: SYNC_APP_SLUG (committer <slug>[bot]) unless
#      GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL are set.
# Exit status: 0 ok, 1 a step failed or input refused, 2 usage error.
set -euo pipefail

DIR=${MONITOR_SCRIPTS_DIR:-$(dirname "${BASH_SOURCE[0]}")}
# shellcheck source=scripts/managed-lib.sh
source "$DIR/managed-lib.sh"

CONFIG_FILE=${MONITOR_CONFIG:-repos.yml}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
CONFIG=$TMP/config.json
SUMMARY=()

usage() {
  echo "usage: sync.sh matrix | sync.sh exists|create|repo REPO" >&2
  exit 2
}

# load_config validates the control file and converts it to $CONFIG.
load_config() {
  "$DIR/monitor-config.sh" validate "$CONFIG_FILE" >/dev/null || exit 1
  yq -o=json '.' "$CONFIG_FILE" >"$CONFIG" || die "$CONFIG_FILE: invalid YAML"
}

# check_branch fails unless SYNC_BRANCH is empty, * or a valid branch name.
check_branch() {
  local b=${SYNC_BRANCH:-}
  [[ -z $b || $b == '*' ]] && return 0
  if [[ $b == -* || $b == *@\{* ]] || ! git check-ref-format --branch "$b" >/dev/null 2>&1; then
    die "invalid branch: ${b//[^[:print:]]/?}"
  fi
}

# load_entry REPO sets ENTRY, REPO, KIND, UPSTREAM, UPSTREAM_REPO or fails.
load_entry() {
  ENTRY=$(managed_entry "$CONFIG" "$1") || die "$1 is not managed"
  export ENTRY
  REPO=$(jq -r .repo <<<"$ENTRY")
  KIND=$(jq -r .kind <<<"$ENTRY")
  UPSTREAM=$(jq -r .upstream <<<"$ENTRY")
  UPSTREAM_REPO=$(jq -r '.upstream_repo // ""' <<<"$ENTRY")
  [[ $REPO =~ ^spali/[A-Za-z0-9._-]+$ ]] || die "invalid repo: $REPO"
  [[ $UPSTREAM =~ ^https://[^[:space:][:cntrl:]]+$ ]] || die "$REPO: invalid upstream"
  [[ $KIND == mirror || $UPSTREAM_REPO =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] ||
    die "$REPO: invalid upstream repository"
}

# --- summary -------------------------------------------------------------

# md TEXT prints TEXT as inline code (backticks and control characters removed).
md() {
  local t=${1//\`/\'}
  # shellcheck disable=SC2016 # literal backticks
  printf '`%s`' "${t//[[:cntrl:]]/?}"
}

note() {
  SUMMARY+=("$1")
}

# fail_note WHAT notes the error of the last step ($TMP/err).
fail_note() {
  local msg
  msg=$(sed -n 's/^error: //p' "$TMP/err" | paste -sd ';' - | sed 's/;/; /g')
  [[ -n $msg ]] || msg=$(grep -v '^[[:space:]]*$' "$TMP/err" | tail -n 1 || true)
  note "- ✗ $1 failed: $(md "${msg:-no message}")"
}

# finish STATUS writes the summary section and exits.
finish() {
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
      printf '### %s\n\n' "$REPO"
      printf '%s\n' "${SUMMARY[@]}"
      echo
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  exit "$1"
}

# step SCRIPT ARGS... runs a sync script with ENTRY. Its stdout goes to
# $TMP/out, its stderr to $TMP/err; both are copied to the log.
step() {
  local rc=0
  "$DIR/$1" "${@:2}" >"$TMP/out" 2>"$TMP/err" || rc=$?
  cat "$TMP/out"
  cat "$TMP/err" >&2
  return "$rc"
}

# --- modes ---------------------------------------------------------------

cmd_matrix() {
  local out n
  check_branch
  [[ -z ${SYNC_BRANCH:-} || -n ${SYNC_REPO:-} ]] || die "the branch input needs the repo input"
  # shellcheck disable=SC2016 # jq program
  out=$(jq -c --arg want "${SYNC_REPO:-}" '
    [(.managed // [])[].repo] as $all |
    {
      repos: (if $want == "" then $all
              else [$all[] | select(ascii_downcase == ($want | ascii_downcase))] end),
      "runs-on": (.monitor["runs-on"] // "ubuntu-latest")
    }' "$CONFIG")
  n=$(jq '.repos | length' <<<"$out")
  [[ -z ${SYNC_REPO:-} || $n -gt 0 ]] || die "${SYNC_REPO//[^[:print:]]/?} is not managed"
  printf '%s\n' "$out"
}

# get_repo succeeds when REPO exists, returns 1 on 404 and dies otherwise.
get_repo() {
  if gh api "repos/$REPO" >"$TMP/repo.json" 2>"$TMP/err"; then
    return 0
  fi
  grep -q '(HTTP 404)' "$TMP/err" && return 1
  die "$REPO: $(grep -m1 '(HTTP [0-9]*)' "$TMP/err" || head -n 1 "$TMP/err")"
}

cmd_exists() {
  load_entry "$1"
  out name "${REPO#*/}"
  if get_repo; then
    out exists true
  else
    out exists false
  fi
}

cmd_create() {
  load_entry "$1"
  if step sync-create.sh; then
    note "- repository: $(head -n 1 "$TMP/out")"
    finish 0
  fi
  fail_note create
  finish 1
}

# committer sets COMMITTER_NAME and COMMITTER_EMAIL: GIT_COMMITTER_* if set,
# else the bot user of the app SYNC_APP_SLUG.
committer() {
  local slug=${SYNC_APP_SLUG:-} id
  if [[ -n ${GIT_COMMITTER_NAME:-} && -n ${GIT_COMMITTER_EMAIL:-} ]]; then
    COMMITTER_NAME=$GIT_COMMITTER_NAME COMMITTER_EMAIL=$GIT_COMMITTER_EMAIL
    return 0
  fi
  if [[ ! $slug =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "error: SYNC_APP_SLUG is missing or invalid" >"$TMP/err"
    cat "$TMP/err" >&2
    return 1
  fi
  gh api "users/${slug}[bot]" >"$TMP/user.json" 2>"$TMP/err" || {
    cat "$TMP/err" >&2
    return 1
  }
  id=$(jq -r '.id // ""' "$TMP/user.json")
  if [[ ! $id =~ ^[0-9]+$ ]]; then
    echo "error: no user id for ${slug}[bot]" >"$TMP/err"
    cat "$TMP/err" >&2
    return 1
  fi
  COMMITTER_NAME="${slug}[bot]"
  COMMITTER_EMAIL="$id+${slug}[bot]@users.noreply.github.com"
}

# contributions writes $WORK/contrib.txt: the head branches of the open
# upstream pull requests whose head repository is REPO.
contributions() {
  gh api --paginate "repos/$UPSTREAM_REPO/pulls?state=open&per_page=100" \
    >"$TMP/pulls.json" 2>"$TMP/err" || {
    cat "$TMP/err" >&2
    return 1
  }
  jq -rs --arg repo "$REPO" '
    add // [] | .[] | select((.head.repo.full_name // "" | ascii_downcase) == ($repo | ascii_downcase))
    | .head.ref' "$TMP/pulls.json" >"$WORK/contrib.txt" 2>"$TMP/err" || {
    echo "error: cannot read the pull requests of $UPSTREAM_REPO" >"$TMP/err"
    cat "$TMP/err" >&2
    return 1
  }
}

# git_step plan|push runs sync-git.sh with the URLs of the entry, the
# committer and the token as an extraheader for https://github.com/.
git_step() {
  local auth
  auth=$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)
  TARGET_URL="https://github.com/$REPO.git" UPSTREAM_URL=$UPSTREAM WORK=$WORK \
    GIT_COMMITTER_NAME=$COMMITTER_NAME GIT_COMMITTER_EMAIL=$COMMITTER_EMAIL \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
    GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth" \
    step sync-git.sh "$1"
}

# list_out TITLE [EMPTY] notes the lines of $TMP/out as a list ("none" when
# there are none or the output is EMPTY).
list_out() {
  local line
  if [[ ! -s $TMP/out ]] || [[ $(<"$TMP/out") == "${2:-}" ]]; then
    note "- $1: none"
    return
  fi
  note "- $1:"
  while IFS= read -r line; do
    [[ -z $line ]] || note "  - $(md "$line")"
  done <"$TMP/out"
}

cmd_repo() {
  local status=0 git=1 ref why
  check_branch
  load_entry "$1"
  need_env GH_TOKEN
  if ! get_repo; then
    echo "error: $REPO does not exist (the create step makes it)" | tee "$TMP/err" >&2
    fail_note repository
    finish 1
  fi
  # the kind check: sync-create.sh only checks an existing repository
  if ! step sync-create.sh; then
    fail_note repository
    finish 1
  fi
  note "- repository: $(head -n 1 "$TMP/out")"

  if step sync-settings.sh; then
    if [[ $(<"$TMP/out") == "settings ok" ]]; then
      note "- settings: ok"
    else
      list_out "settings changed"
    fi
  else
    status=1
    [[ ! -s $TMP/out ]] || list_out "settings changed"
    fail_note settings
  fi

  WORK=$TMP/git
  mkdir -p "$WORK"
  if ! committer; then
    fail_note committer
    git=0
  fi
  if ((git)) && [[ $KIND == fork ]] && ! contributions; then
    fail_note "contribution lookup"
    git=0
  fi
  if ((git == 0)); then
    note "- refs: not synced"
    finish 1
  fi

  if ! git_step plan; then
    fail_note plan
    note "- refs: not synced"
    finish 1
  fi
  if [[ -s $WORK/skipped.txt ]]; then
    note "- skipped refs:"
    while IFS=$'\t' read -r ref why; do
      note "  - $(md "$ref"): $why"
    done <"$WORK/skipped.txt"
  fi
  if git_step push; then
    list_out "updated refs" "nothing to do"
  else
    fail_note push
    status=1
  fi
  finish "$status"
}

# --- main ----------------------------------------------------------------

(($# >= 1)) || usage
case $1 in
  matrix)
    (($# == 1)) || usage
    load_config
    cmd_matrix
    ;;
  exists | create | repo)
    (($# == 2)) || usage
    load_config
    REPO=$2
    "cmd_$1" "$2"
    ;;
  *) usage ;;
esac
