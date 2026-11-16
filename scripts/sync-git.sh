#!/usr/bin/env bash
# Syncs the git refs of one managed fork or mirror.
#
#   sync-git.sh plan  fetches upstream (only the default branch, the onto
#                     branches, the branches matching a follow pattern and,
#                     unless tags is false, all tags; all branches only
#                     to check a moved or gone tag) and target into
#                     $WORK/repo, rebases the declared branches there and
#                     writes $WORK/plan.tsv
#                     (<ref> <old sha> <new sha> <reason>, tab separated;
#                     reasons ff, rebase, mirror, delete, backup, record) and
#                     $WORK/skipped.txt (<ref> <why>). Fails without a plan on
#                     a conflict, a missing onto or an empty source.
#                     A record (${RECORD_PREFIX}<branch>) holds the upstream
#                     sha a synced branch sits on: the upstream sha of a
#                     fast-forwarded, mirrored or already equal default or
#                     followed branch, the onto sha of a rebased or created
#                     declared branch (also when the rebase changed nothing);
#                     it is deleted with its branch. A manual branch that is
#                     not rebased keeps its record.
#                     Nothing is lost or followed without a decision: a
#                     default or followed branch that is no ancestor of
#                     upstream is skipped as "upstream rewritten (...)" when
#                     its record is no ancestor of upstream (else as
#                     undeclared); a declared branch that contains its record
#                     is not rebased when the record is no ancestor of onto
#                     (same reason, the plan goes on); a target tag that
#                     differs from upstream is skipped as "upstream moved tag
#                     (...)". These skips write no record.
#                     SYNC_ACCEPT follows such a stop with a backup of the
#                     old tip: a default or followed branch is set to
#                     upstream when it equals its record (else it stays,
#                     "; accept refused: own commits on top, ..."); a declared
#                     branch moves only its own commits (rebase --onto onto
#                     <record>) when it contains its record (else it stays,
#                     "; accept refused: record not in branch, ..."); a
#                     moved tag is set to upstream. Without a stop it does
#                     nothing.
#   sync-git.sh push  pushes $WORK/plan.tsv to TARGET_URL in one atomic push
#                     with a lease on the old sha of every ref, then checks the
#                     target with ls-remote. On a mismatch it restores the old
#                     shas (leases on the new ones) and fails. Prints
#                     "<ref> <old>..<new> (<reason>)" per updated ref. The
#                     caller must build TARGET_URL from the managed entry.
#
# env: plan: ENTRY (the object of managed_entry), TARGET_URL, UPSTREAM_URL,
#      WORK, optional SYNC_BRANCH (a branch name or *: also rebase manual
#      branches; a missing manual branch is always created from its onto),
#      optional SYNC_ACCEPT (a branch name, tags/<name> or *: accept the
#      upstream rewrite of that branch or the moved tag, * all of them),
#      optional $WORK/contrib.txt (contribution branches, one per line),
#      GIT_COMMITTER_NAME/EMAIL.
#      push: TARGET_URL (without credentials), WORK.
#      both: optional BACKUP_PREFIX (branch backups <prefix><branch>,
#      default refs/backup/), TAG_BACKUP_PREFIX (tag backups <prefix><tag>,
#      default refs/backup-tags/),
#      RECORD_PREFIX (records, default refs/sync/upstream/); each under
#      refs/, not refs/heads/..., not refs/tags/ itself, and none inside
#      another. Upstream refs under them are skipped as invalid, target refs
#      under them are no branches or tags.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ZERO=0000000000000000000000000000000000000000
BACKUP_PREFIX=${BACKUP_PREFIX:-refs/backup/}
TAG_BACKUP_PREFIX=${TAG_BACKUP_PREFIX:-refs/backup-tags/}
RECORD_PREFIX=${RECORD_PREFIX:-refs/sync/upstream/}

# Keep system and global config and prompts out; pin the settings that
# change what a rebase does. GIT_CONFIG_COUNT/KEY/VALUE (credentials) stay
# untouched.
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
# no tracing that could print request headers (GIT_TRACE, GIT_TRACE2*, ...)
unset "${!GIT_TRACE@}" GIT_CURL_VERBOSE
GITC=(
  -c core.hooksPath=/dev/null
  -c core.autocrlf=false
  -c commit.gpgsign=false
  -c rebase.autoStash=false
  -c rebase.autoSquash=false
  -c rebase.updateRefs=false
  -c rebase.rebaseMerges=false
  -c rebase.missingCommitsCheck=ignore
  -c rerere.enabled=false
  -c advice.detachedHead=false
)

g() { git -C "$REPO" "${GITC[@]}" "$@"; }

# valid_ref REF succeeds when REF is a full ref name whose short name is also
# a valid branch name (no leading dash, no option look-alike).
valid_ref() {
  git check-ref-format "$1" && git check-ref-format --branch "${1#refs/*/}" >/dev/null 2>&1
}

# valid_branch NAME succeeds for a valid branch name (no @{-N} expansion).
valid_branch() {
  [[ $1 != *@\{* ]] && valid_ref "refs/heads/$1"
}

skip() {
  printf '%s\t%s\n' "${1//[^[:print:]]/?}" "$2" >>"$WORK/skipped.txt"
}

add() {
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$PLAN_TMP"
}

# is_ancestor A B succeeds when commit A is an ancestor of B.
is_ancestor() {
  local rc=0
  g merge-base --is-ancestor "$1" "$2" || rc=$?
  case $rc in
    0) return 0 ;;
    1) return 1 ;;
    *) die "cannot compare $1 and $2" ;;
  esac
}

# own_ref REF succeeds when REF is under a prefix the sync writes itself
# (backups, tag backups, records).
own_ref() {
  [[ $1 == "$BACKUP_PREFIX"* || $1 == "$TAG_BACKUP_PREFIX"* || $1 == "$RECORD_PREFIX"* ]]
}

# load NAMESPACE ARRAY fills ARRAY (heads/x or tags/x -> sha) from
# refs/NAMESPACE/{heads,tags}/; refs with an invalid name are deleted and
# skipped.
load() {
  local ns=$1 sha name orig
  local -n arr=$2
  while IFS=$'\t' read -r sha name; do
    orig=refs/${name#"refs/$ns/"}
    if ! valid_ref "$orig" || { [[ $ns == up ]] && own_ref "$orig"; }; then
      skip "$orig" "invalid ref name"
      g update-ref -d "$name"
      continue
    fi
    # backups and records under refs/tags/ are no target tags
    [[ $ns == tg ]] && own_ref "$orig" && continue
    # shellcheck disable=SC2034 # nameref to the caller's array
    arr[${orig#refs/}]=$sha
  done < <(g for-each-ref --format=$'%(objectname)\t%(refname)' "refs/$ns/heads/" "refs/$ns/tags/")
}

# default_branch URL prints the default branch of a remote (empty if none).
default_branch() {
  local out name
  out=$(g ls-remote --symref -- "$1" HEAD) || die "cannot read the default branch of $2"
  name=$(awk '$1 == "ref:" && $3 == "HEAD" { print $2; exit }' <<<"$out")
  name=${name#refs/heads/}
  [[ -z $name ]] || valid_branch "$name" || die "invalid default branch of $2"
  printf '%s\n' "$name"
}

wants_rebase() {
  [[ $1 == auto || ${SYNC_BRANCH:-} == "$2" || ${SYNC_BRANCH:-} == '*' ]]
}

# accepts KEY (heads/x or tags/x) succeeds when SYNC_ACCEPT accepts a
# rewrite of the branch or a move of the tag: *, the branch name or tags/x.
accepts() {
  local a=${SYNC_ACCEPT:-}
  [[ -n $a ]] || return 1
  [[ $a == '*' ]] && return 0
  if [[ $1 == heads/* ]]; then
    [[ $a == "${1#heads/}" ]]
  else
    [[ $a == "$1" ]]
  fi
}

# backup_line REF OLD NEW plans the backup REF (now OLD) at NEW unless it is
# there already.
backup_line() {
  [[ $2 == "$3" ]] || add "$1" "$2" "$3" backup
}

# record_line BRANCH NEW plans the record of BRANCH at NEW (zero: delete)
# unless it is there already.
record_line() {
  local old=${RECR[$1]:-$ZERO}
  [[ $old == "$2" ]] || add "$RECORD_PREFIX$1" "$old" "$2" record
}

# rewritten BRANCH UP succeeds when BRANCH has a record that is not an
# ancestor of the upstream sha UP: upstream dropped commits that were synced.
rewritten() {
  [[ -n ${RECR[$1]:-} ]] && ! is_ancestor "${RECR[$1]}" "$2"
}

# rewrite_reason BRANCH UP TG prints the skip reason of a rewritten BRANCH
# (record of BRANCH, upstream sha UP, target sha TG).
rewrite_reason() {
  local rec=${RECR[$1]} gone own
  gone=$(g rev-list --count "$2..$rec") || die "cannot compare $rec and $2"
  own=$(g rev-list --count "$rec..$3") || die "cannot compare $rec and $3"
  if ((own == 0)); then
    own="no own commits"
  else
    own="$own own commits"
  fi
  printf 'upstream rewritten (synced %s, upstream now %s, %s synced commits gone upstream; target has %s)\n' \
    "${rec:0:7}" "${2:0:7}" "$gone" "$own"
}

# skip_rewrite BRANCH UP TG [SUFFIX] skips BRANCH with its rewrite_reason
# (and SUFFIX).
skip_rewrite() {
  local why
  why=$(rewrite_reason "$1" "$2" "$3")
  skip "refs/heads/$1" "$why${4:-}"
}

# rewrite_branch BRANCH UP TG REASON handles a rewritten default or followed
# branch: skipped unless accepted; accepted, it is set to UP (REASON ff or
# mirror) with a backup of TG when TG is its record, else refused.
rewrite_branch() {
  local b=$1 up=$2 tg=$3
  if ! accepts "heads/$b"; then
    skip_rewrite "$b" "$up" "$tg"
  elif [[ $tg != "${RECR[$b]}" ]]; then
    skip_rewrite "$b" "$up" "$tg" "; accept refused: own commits on top, declare the branch or reset it by hand"
  else
    add "refs/heads/$b" "$tg" "$up" "$4"
    backup_line "$BACKUP_PREFIX$b" "${BKR[$b]:-$ZERO}" "$tg"
    record_line "$b" "$up"
  fi
}

# rebase_branch BRANCH ONTO rebases the target branch onto the upstream
# branch and plans it with a backup of the old tip and its record. When the
# record is no longer in onto (upstream rewritten), a branch that contains
# its record is skipped, or with SYNC_ACCEPT rebased with only the commits
# after its record; a branch without its record is rebased as usual, but
# refused with SYNC_ACCEPT.
rebase_branch() {
  local b=$1 onto=$2 old new
  local -a base=("refs/up/heads/$onto")
  [[ -n ${UPR[heads/$onto]:-} ]] || die "branch $b: onto $onto missing upstream"
  old=${TGR[heads/$b]:-$ZERO}
  if [[ $old != "$ZERO" ]] && rewritten "$b" "${UPR[heads/$onto]}"; then
    if is_ancestor "${RECR[$b]}" "$old"; then
      if ! accepts "heads/$b"; then
        skip_rewrite "$b" "${UPR[heads/$onto]}" "$old"
        return 0
      fi
      base=(--onto "refs/up/heads/$onto" "${RECR[$b]}")
    elif accepts "heads/$b"; then
      skip_rewrite "$b" "${UPR[heads/$onto]}" "$old" "; accept refused: record not in branch, rebase by hand"
      return 0
    fi
  fi
  if [[ $old == "$ZERO" ]]; then
    new=${UPR[heads/$onto]}
    g update-ref "refs/heads/$b" "$new"
  else
    g switch -q --no-guess -C "$b" "refs/tg/heads/$b"
    if ! g rebase -q --no-autosquash --empty=drop "${base[@]}" >&2; then
      g rebase --abort >&2 || true
      die "branch $b: rebase onto $onto failed (conflict)"
    fi
    new=$(g rev-parse --verify "refs/heads/$b")
    g switch -q --detach
  fi
  if [[ $new != "$old" ]]; then
    add "refs/heads/$b" "$old" "$new" rebase
    [[ $old == "$ZERO" ]] || backup_line "$BACKUP_PREFIX$b" "${BKR[$b]:-$ZERO}" "$old"
  fi
  # also when the rebase changed nothing: the branch sits on onto now
  record_line "$b" "${UPR[heads/$onto]}"
}

# contained SHA succeeds when the commit of SHA is in a current upstream ref.
contained() {
  local c
  c=$(g rev-parse --verify --quiet "$1^{commit}") || return 1
  [[ -n $(g for-each-ref --contains "$c" --format='%(refname)' refs/up/) ]]
}

# contained_tag SHA is contained, but first fetches all upstream heads once
# into refs/up/extra/ (not read by load, never synced) when SHA is not in a
# fetched upstream ref: a tag commit may be only on an unfetched branch.
contained_tag() {
  contained "$1" && return 0
  if [[ -z ${EXTRA:-} ]]; then
    EXTRA=1
    g fetch -q --no-tags --no-write-fetch-head -- "$UPSTREAM_URL" \
      '+refs/heads/*:refs/up/extra/*' || die "cannot fetch upstream"
  fi
  contained "$1"
}

# backups and records must not land in a namespace that is synced
# (refs/heads/, refs/tags/) nor inside each other
check_prefixes() {
  local v w p
  for v in BACKUP_PREFIX TAG_BACKUP_PREFIX RECORD_PREFIX; do
    p=${!v}
    if [[ $p != refs/?*/ || $p == refs/heads/* || $p == refs/tags/ ]] ||
      ! git check-ref-format "${p}x"; then
      die "invalid $v $p"
    fi
  done
  for v in BACKUP_PREFIX TAG_BACKUP_PREFIX RECORD_PREFIX; do
    for w in BACKUP_PREFIX TAG_BACKUP_PREFIX RECORD_PREFIX; do
      [[ $v == "$w" || ${!w} != "${!v}"* ]] || die "$w ${!w} overlaps $v ${!v}"
    done
  done
}

# follow_match prints the names (one per line on stdin) that match a follow
# pattern of the entry as a whole. The patterns are only used inside jq.
follow_match() {
  if [[ $FOLLOW == '[]' ]]; then
    cat >/dev/null
    return 0
  fi
  # shellcheck disable=SC2016 # jq program
  jq -rR --argjson f "$FOLLOW" \
    'select(. as $n | any($f[]; . as $re | $n | test("^(?:" + $re + ")$")))' ||
    die "invalid follow pattern"
}

# fetch_needed UPSTREAM_DEFAULT fetches only the upstream default branch, the
# onto of every declared branch, the branches that match a follow pattern
# (FOL) and, with TAGS, all tags (invalid tag names are dropped by load).
# The branch names come from ls-remote; invalid ones are skipped. Other
# namespaces are never fetched.
fetch_needed() {
  local udef=$1 out sha name onto fol
  local -a specs=()
  local -A have=() want=()
  out=$(g ls-remote --heads -- "$UPSTREAM_URL") || die "cannot read upstream branches"
  while IFS=$'\t' read -r sha name; do
    [[ -n $name ]] || continue
    if [[ $name != refs/heads/* ]] || ! valid_ref "$name"; then
      skip "$name" "invalid ref name"
      continue
    fi
    have[${name#refs/heads/}]=1
  done <<<"$out"
  [[ -z $udef ]] || want[$udef]=1
  # shellcheck disable=SC2153 # ENTRY comes from the environment
  while IFS= read -r onto; do
    [[ -z $onto ]] || want[$onto]=1
  done < <(jq -r '.branches[].onto // empty | tostring' <<<"$ENTRY")
  fol=$(sorted_keys have | follow_match)
  while IFS= read -r name; do
    [[ -z $name ]] || FOL[$name]=1
  done <<<"$fol"
  for name in "${!FOL[@]}"; do want[$name]=1; done
  for name in "${!want[@]}"; do
    [[ -n ${have[$name]:-} ]] || continue
    specs+=("+refs/heads/$name:refs/up/heads/$name")
  done
  [[ $TAGS != true ]] || specs+=('+refs/tags/*:refs/up/tags/*')
  ((${#specs[@]})) || return 0
  g fetch -q --no-tags --no-write-fetch-head -- "$UPSTREAM_URL" "${specs[@]}" ||
    die "cannot fetch upstream"
}

sorted_keys() {
  local -n a=$1
  ((${#a[@]})) || return 0
  printf '%s\n' "${!a[@]}" | LC_ALL=C sort
}

# in_scope KEY succeeds for a ref (heads/x or tags/x) the sync mirrors by
# name: a followed branch, or a tag when TAGS is true.
in_scope() {
  [[ $1 == tags/* ]] && [[ $TAGS == true ]] && return 0
  [[ $1 == heads/* && -n ${SCOPE[${1#heads/}]:-} ]]
}

plan() {
  local name onto how key up tg tdef udef n u sha fol
  local -a keys
  need_env ENTRY TARGET_URL UPSTREAM_URL WORK GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  [[ -d $WORK ]] || die "WORK $WORK is not a directory"
  [[ $UPSTREAM_URL != -* && $TARGET_URL != -* ]] || die "invalid URL"
  check_prefixes
  [[ -z ${SYNC_ACCEPT:-} || $SYNC_ACCEPT == '*' ]] || valid_branch "$SYNC_ACCEPT" ||
    die "invalid SYNC_ACCEPT"
  # shellcheck disable=SC2153 # ENTRY comes from the environment
  TAGS=$(jq -r '.tags != false' <<<"$ENTRY")

  REPO=$WORK/repo
  PLAN_TMP=$WORK/plan.tsv.tmp
  rm -f "$WORK/plan.tsv" "$PLAN_TMP"
  trap 'rm -f "$PLAN_TMP"' EXIT
  : >"$PLAN_TMP"
  : >"$WORK/skipped.txt"
  git init -q "$REPO"

  declare -gA UPR=() TGR=() BKR=() TBKR=() RECR=() DECL=() CONTRIB=() FOL=() SCOPE=()
  EXTRA=
  FOLLOW=$(jq -c '.follow // []' <<<"$ENTRY")
  udef=$(default_branch "$UPSTREAM_URL" upstream)
  fetch_needed "$udef"
  # tags false: target tags are neither read nor written
  local -a tgspecs=('+refs/heads/*:refs/tg/heads/*')
  [[ $TAGS != true ]] || tgspecs+=('+refs/tags/*:refs/tg/tags/*')
  g fetch -q --no-tags --no-write-fetch-head -- "$TARGET_URL" \
    "${tgspecs[@]}" "+${BACKUP_PREFIX}*:refs/tg/backup/*" \
    "+${TAG_BACKUP_PREFIX}*:refs/tg/backup-tags/*" "+${RECORD_PREFIX}*:refs/tg/record/*" ||
    die "cannot fetch target"

  load up UPR
  load tg TGR
  while IFS=$'\t' read -r sha name; do
    BKR[${name#refs/tg/backup/}]=$sha
  done < <(g for-each-ref --format=$'%(objectname)\t%(refname)' refs/tg/backup/)
  while IFS=$'\t' read -r sha name; do
    TBKR[${name#refs/tg/backup-tags/}]=$sha
  done < <(g for-each-ref --format=$'%(objectname)\t%(refname)' refs/tg/backup-tags/)
  while IFS=$'\t' read -r sha name; do
    RECR[${name#refs/tg/record/}]=$sha
  done < <(g for-each-ref --format=$'%(objectname)\t%(refname)' refs/tg/record/)
  if [[ -f $WORK/contrib.txt ]]; then
    while IFS= read -r name || [[ -n $name ]]; do
      [[ -z $name ]] || CONTRIB[$name]=1
    done <"$WORK/contrib.txt"
  fi

  u=${#UPR[@]}
  n=${#TGR[@]}
  ((u > 0)) || die "upstream has $u refs (branches and tags), target $n: refusing (empty or broken source)"
  # the default branch and the refs mirrored by name (followed branches,
  # tags): upstream must have at least half as many as the target
  for name in "${!FOL[@]}"; do SCOPE[$name]=1; done
  fol=$(sorted_keys TGR | sed -n 's|^heads/||p' | follow_match)
  while IFS= read -r name; do
    [[ -z $name ]] || SCOPE[$name]=1
  done <<<"$fol"
  tdef=$(default_branch "$TARGET_URL" target)
  tdef=${tdef:-$udef}
  u=0 n=0
  for key in "${!UPR[@]}"; do
    in_scope "$key" || [[ $key == "heads/$udef" ]] || continue
    u=$((u + 1))
  done
  for key in "${!TGR[@]}"; do
    in_scope "$key" || [[ $key == "heads/$tdef" ]] || continue
    n=$((n + 1))
  done
  ((2 * u >= n)) || die "upstream has $u refs (branches and tags), target $n: refusing (empty or broken source)"

  # declared branches; \x1f is no IFS whitespace, so empty fields stay empty,
  # control characters become ? (an invalid ref name)
  while IFS=$'\x1f' read -r name onto how; do
    if ! valid_branch "$name"; then
      skip "refs/heads/$name" "invalid ref name"
      continue
    fi
    DECL[$name]=1
    if ! valid_branch "$onto"; then
      skip "refs/heads/$name" "invalid ref name"
    elif [[ -n ${CONTRIB[$name]:-} ]]; then
      skip "refs/heads/$name" contribution
    elif wants_rebase "$how" "$name" || [[ -z ${TGR[heads/$name]:-} ]]; then
      # a missing branch is created from onto, also a manual one (it loses
      # nothing)
      rebase_branch "$name" "$onto"
    fi
  done < <(jq -r '.branches[] | [.name, .onto, .rebase]
    | map((. // "") | tostring | explode | map(if . < 32 or . == 127 then 63 else . end) | implode) | join("\u001f")' <<<"$ENTRY")

  [[ -n $udef && -n ${UPR[heads/$udef]:-} ]] || die "upstream default branch missing"
  if [[ -n ${DECL[$tdef]:-} ]]; then
    :
  elif [[ -n ${CONTRIB[$tdef]:-} ]]; then
    skip "refs/heads/$tdef" contribution
  else
    up=${UPR[heads/$udef]}
    tg=${TGR[heads/$tdef]:-$ZERO}
    if [[ $tg == "$ZERO" ]] || { [[ $tg != "$up" ]] && is_ancestor "$tg" "$up"; }; then
      add "refs/heads/$tdef" "$tg" "$up" ff
      record_line "$tdef" "$up"
    elif [[ $tg != "$up" ]] && rewritten "$tdef" "$up"; then
      rewrite_branch "$tdef" "$up" "$tg" ff
    elif [[ $tg != "$up" ]]; then
      skip "refs/heads/$tdef" undeclared
    else
      record_line "$tdef" "$up"
    fi
  fi
  # followed branches: fast-forward or create by name
  mapfile -t keys < <(sorted_keys FOL)
  for name in "${keys[@]}"; do
    [[ $name != "$tdef" && -z ${DECL[$name]:-} ]] || continue
    up=${UPR[heads/$name]:-}
    tg=${TGR[heads/$name]:-$ZERO}
    [[ -n $up ]] || continue
    if [[ -n ${CONTRIB[$name]:-} ]]; then
      [[ $tg == "$up" ]] || skip "refs/heads/$name" contribution
    elif [[ $tg == "$up" ]]; then
      record_line "$name" "$up"
    elif [[ $tg != "$ZERO" ]] && ! is_ancestor "$tg" "$up"; then
      if rewritten "$name" "$up"; then
        rewrite_branch "$name" "$up" "$tg" mirror
      else
        skip "refs/heads/$name" undeclared
      fi
    else
      add "refs/heads/$name" "$tg" "$up" mirror
      record_line "$name" "$up"
    fi
  done
  # followed target branches gone upstream (the default branch never)
  mapfile -t keys < <(sorted_keys SCOPE)
  for name in "${keys[@]}"; do
    [[ $name != "$tdef" && -z ${DECL[$name]:-} && -z ${UPR[heads/$name]:-} && -n ${TGR[heads/$name]:-} ]] || continue
    if [[ -n ${CONTRIB[$name]:-} ]]; then
      skip "refs/heads/$name" contribution
    elif contained "${TGR[heads/$name]}"; then
      add "refs/heads/$name" "${TGR[heads/$name]}" "$ZERO" delete
      record_line "$name" "$ZERO"
    else
      skip "refs/heads/$name" "unique commits"
    fi
  done
  # tags (only loaded when TAGS is true): new ones by name (an annotated tag
  # keeps its tag object); a moved one only with SYNC_ACCEPT (with a backup
  # of the old one); a gone upstream one
  # is deleted only when nothing is lost (its commit is in an upstream ref)
  mapfile -t keys < <(sorted_keys UPR | grep '^tags/' || true)
  for key in "${keys[@]}"; do
    [[ -n $key && ${TGR[$key]:-$ZERO} != "${UPR[$key]}" ]] || continue
    tg=${TGR[$key]:-$ZERO}
    if [[ $tg == "$ZERO" ]]; then
      add "refs/$key" "$tg" "${UPR[$key]}" mirror
    elif accepts "$key"; then
      add "refs/$key" "$tg" "${UPR[$key]}" mirror
      backup_line "$TAG_BACKUP_PREFIX${key#tags/}" "${TBKR[${key#tags/}]:-$ZERO}" "$tg"
    else
      skip "refs/$key" "upstream moved tag (target ${tg:0:7}, upstream ${UPR[$key]:0:7})"
    fi
  done
  mapfile -t keys < <(sorted_keys TGR | grep '^tags/' || true)
  for key in "${keys[@]}"; do
    [[ -n $key && -z ${UPR[$key]:-} ]] || continue
    if contained_tag "${TGR[$key]}"; then
      add "refs/$key" "${TGR[$key]}" "$ZERO" delete
    else
      skip "refs/$key" "unique commits"
    fi
  done

  LC_ALL=C sort -u -o "$WORK/skipped.txt" "$WORK/skipped.txt"
  mv "$PLAN_TMP" "$WORK/plan.tsv"
}

# has_credentials URL succeeds when URL carries a user part (user@ or
# user:pass@ before the host, also in the scp form user@host:path).
has_credentials() {
  local auth
  if [[ $1 == *://* ]]; then
    auth=${1#*://}
    auth=${auth%%/*}
  else
    auth=${1%%:*}
  fi
  [[ $auth == *@* ]]
}

# plan_ref_ok REF REASON succeeds when plan writes REASON only for refs like
# REF: records under RECORD_PREFIX, backups under BACKUP_PREFIX or
# TAG_BACKUP_PREFIX, the rest under refs/heads/ or refs/tags/ outside them.
plan_ref_ok() {
  case $2 in
    record) [[ $1 == "$RECORD_PREFIX"* ]] ;;
    backup) [[ $1 == "$BACKUP_PREFIX"* || $1 == "$TAG_BACKUP_PREFIX"* ]] ;;
    *) ! own_ref "$1" && [[ $1 =~ ^refs/(heads|tags)/ ]] ;;
  esac
}

# read_plan fills P_REF, P_OLD, P_NEW, P_WHY from $WORK/plan.tsv and fails
# on the first line that plan would never write.
read_plan() {
  local line n=0 r o nw why t=$'\t'
  local -A seen=()
  local re="^([^$t]+)$t([0-9a-f]{40})$t([0-9a-f]{40})$t(ff|rebase|mirror|delete|backup|record)\$"
  P_REF=() P_OLD=() P_NEW=() P_WHY=()
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    [[ $line =~ $re ]] || die "invalid plan line $n"
    r=${BASH_REMATCH[1]} o=${BASH_REMATCH[2]} nw=${BASH_REMATCH[3]} why=${BASH_REMATCH[4]}
    if [[ $o == "$nw" || -n ${seen[$r]:-} ]] || ! valid_ref "$r" || ! plan_ref_ok "$r" "$why" ||
      [[ $why == delete && $nw != "$ZERO" ]] ||
      [[ $why != delete && $why != record && $nw == "$ZERO" ]]; then
      die "invalid plan line $n"
    fi
    seen[$r]=1
    P_REF+=("$r") P_OLD+=("$o") P_NEW+=("$nw") P_WHY+=("$why")
  done <"$WORK/plan.tsv"
}

# push_refs EXPECT_ARRAY TO_ARRAY INDEX... pushes the planned refs at INDEX
# atomically to TO, each with a lease on EXPECT (zero: the ref must not
# exist; zero TO: delete). git's output goes to $WORK/push.out.
push_refs() {
  local -n exp=$1 to=$2
  local i r
  local -a args=() specs=()
  shift 2
  for i in "$@"; do
    r=${P_REF[i]}
    if [[ ${exp[i]} == "$ZERO" ]]; then
      args+=("--force-with-lease=$r:")
    else
      args+=("--force-with-lease=$r:${exp[i]}")
    fi
    if [[ ${to[i]} == "$ZERO" ]]; then
      specs+=(":$r")
    else
      specs+=("${to[i]}:$r")
    fi
  done
  g push --atomic --porcelain --no-verify "${args[@]}" -- "$TARGET_URL" "${specs[@]}" \
    >"$WORK/push.out" 2>&1
}

# observe fills OBS (ref -> sha) from ls-remote of the target.
observe() {
  local sha name out
  OBS=()
  out=$(g ls-remote --refs -- "$TARGET_URL") || return 1
  while IFS=$'\t' read -r sha name; do
    [[ -z $name ]] || OBS[$name]=$sha
  done <<<"$out"
}

# state I prints the observed sha of planned ref I (zero if absent).
state() {
  printf '%s\n' "${OBS[${P_REF[$1]}]:-$ZERO}"
}

# rollback WHAT restores the refs that the target shows at their new sha to
# the old sha (leases on the new sha) in one atomic push and fails. A ref
# that somebody else moved is never touched; then the backups (branch and
# tag) stay too. Records go back with the other refs.
rollback() {
  local what=$1 i s
  local -a restore=() failed=()
  local -A bad=() foreign=()
  for i in "${!P_REF[@]}"; do
    s=$(state "$i")
    [[ $s == "${P_NEW[i]}" || $s == "${P_OLD[i]}" ]] || foreign[$i]=1
  done
  for i in "${!P_REF[@]}"; do
    [[ $(state "$i") == "${P_NEW[i]}" ]] || continue
    ((${#foreign[@]} == 0)) || [[ ${P_REF[i]} != "$BACKUP_PREFIX"* && ${P_REF[i]} != "$TAG_BACKUP_PREFIX"* ]] || continue
    restore+=("$i")
  done
  if ((${#restore[@]})) && ! push_refs P_NEW P_OLD "${restore[@]}"; then
    cat "$WORK/push.out" >&2
    for i in "${restore[@]}"; do bad[$i]=1; done
  fi
  for i in "${!P_REF[@]}"; do
    [[ -z ${bad[$i]:-}${foreign[$i]:-} ]] || failed+=("${P_REF[i]}")
  done
  ((${#failed[@]} == 0)) || die "RESTORE FAILED for ${failed[*]}, backups at $BACKUP_PREFIX and $TAG_BACKUP_PREFIX"
  die "$what, restored ${#restore[@]} refs"
}

# report prints one line per planned ref.
report() {
  local i
  for i in "${!P_REF[@]}"; do
    printf '%s %s..%s (%s)\n' "${P_REF[i]}" "${P_OLD[i]:0:7}" "${P_NEW[i]:0:7}" "${P_WHY[i]}"
  done
}

push() {
  local i landed=0
  local -a all missing=()
  need_env TARGET_URL WORK
  [[ $TARGET_URL != -* ]] || die "invalid URL"
  ! has_credentials "$TARGET_URL" || die "TARGET_URL must not contain credentials"
  check_prefixes
  [[ -f $WORK/plan.tsv ]] || die "no plan in $WORK"
  read_plan
  if ((${#P_REF[@]} == 0)); then
    printf 'nothing to do\n'
    return 0
  fi
  REPO=$WORK/repo
  [[ -d $REPO ]] || die "no repository in $WORK"
  declare -gA OBS=()
  all=("${!P_REF[@]}")

  # A failed push is never rolled back: the refs at their new sha may come
  # from another sync with the same plan.
  if ! push_refs P_OLD P_NEW "${all[@]}"; then
    cat "$WORK/push.out" >&2
    observe || die "push failed, target state unknown (atomic: either all old or all new)"
    for i in "${all[@]}"; do
      if [[ $(state "$i") != "${P_NEW[i]}" ]]; then
        missing+=("${P_REF[i]}")
      elif [[ ${P_NEW[i]} != "$ZERO" ]]; then
        # an absent ref may be somebody else's delete; only an update or
        # create shows that the push landed
        landed=1
      fi
    done
    if ((${#missing[@]})); then
      ((landed)) || die "push rejected, target unchanged"
      die "push failed, target in mixed state: ${missing[*]}"
    fi
    # every ref is at its new sha: the push landed, only its status was lost
    report
    return 0
  fi

  if ! observe; then
    # unknown state: assume the push landed, the leases keep the restore safe
    for i in "${all[@]}"; do
      [[ ${P_NEW[i]} == "$ZERO" ]] || OBS[${P_REF[i]}]=${P_NEW[i]}
    done
    rollback "verify failed (cannot read the target)"
  fi
  for i in "${all[@]}"; do
    [[ $(state "$i") == "${P_NEW[i]}" ]] || rollback "verify failed"
  done
  report
}

case ${1:-} in
  plan) plan ;;
  push) push ;;
  *)
    printf 'usage: %s plan|push\n' "$0" >&2
    exit 2
    ;;
esac
