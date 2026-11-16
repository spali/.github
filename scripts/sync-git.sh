#!/usr/bin/env bash
# Syncs the git refs of one managed fork or mirror.
#
#   sync-git.sh plan  fetches upstream and target into $WORK/repo, rebases the
#                     declared branches there and writes $WORK/plan.tsv
#                     (<ref> <old sha> <new sha> <reason>, tab separated;
#                     reasons ff, rebase, mirror, delete, backup) and
#                     $WORK/skipped.txt (<ref> <why>). Fails without a plan on
#                     a conflict, a missing onto or an empty source.
#   sync-git.sh push  (not implemented yet)
#
# env: ENTRY (the object of managed_entry), TARGET_URL, UPSTREAM_URL, WORK,
#      optional SYNC_BRANCH (a branch name or *: also rebase manual branches),
#      optional BACKUP_PREFIX (default refs/backup/), optional $WORK/contrib.txt
#      (contribution branches, one per line), GIT_COMMITTER_NAME/EMAIL.
set -euo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

ZERO=0000000000000000000000000000000000000000
BACKUP_PREFIX=${BACKUP_PREFIX:-refs/backup/}

# Keep system config and prompts out; pin the settings that change what a
# rebase does. GIT_CONFIG_COUNT/KEY/VALUE (credentials) stay untouched.
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1
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

# load NAMESPACE ARRAY fills ARRAY (heads/x or tags/x -> sha) from
# refs/NAMESPACE/{heads,tags}/; refs with an invalid name are deleted and
# skipped.
load() {
  local ns=$1 sha name orig
  local -n arr=$2
  while IFS=$'\t' read -r sha name; do
    orig=refs/${name#"refs/$ns/"}
    if ! valid_ref "$orig" || [[ $ns == up && $orig == "$BACKUP_PREFIX"* ]]; then
      skip "$orig" "invalid ref name"
      g update-ref -d "$name"
      continue
    fi
    # backups under refs/tags/ are no target tags
    [[ $ns == tg && $orig == "$BACKUP_PREFIX"* ]] && continue
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

# rebase_branch BRANCH ONTO rebases the target branch onto the upstream
# branch and plans it with a backup of the old tip.
rebase_branch() {
  local b=$1 onto=$2 old new bk
  [[ -n ${UPR[heads/$onto]:-} ]] || die "branch $b: onto $onto missing upstream"
  old=${TGR[heads/$b]:-$ZERO}
  if [[ $old == "$ZERO" ]]; then
    new=${UPR[heads/$onto]}
    g update-ref "refs/heads/$b" "$new"
  else
    g switch -q --no-guess -C "$b" "refs/tg/heads/$b"
    if ! g rebase -q --no-autosquash --empty=drop "refs/up/heads/$onto" >&2; then
      g rebase --abort >&2 || true
      die "branch $b: rebase onto $onto failed (conflict)"
    fi
    new=$(g rev-parse --verify "refs/heads/$b")
    g switch -q --detach
  fi
  [[ $new != "$old" ]] || return 0
  add "refs/heads/$b" "$old" "$new" rebase
  [[ $old != "$ZERO" ]] || return 0
  bk=${BKR[$b]:-$ZERO}
  [[ $bk == "$old" ]] || add "$BACKUP_PREFIX$b" "$bk" "$old" backup
}

# contained SHA succeeds when the commit of SHA is in a current upstream ref.
contained() {
  local c
  c=$(g rev-parse --verify --quiet "$1^{commit}") || return 1
  [[ -n $(g for-each-ref --contains "$c" --format='%(refname)' refs/up/) ]]
}

sorted_keys() {
  local -n a=$1
  ((${#a[@]})) || return 0
  printf '%s\n' "${!a[@]}" | LC_ALL=C sort
}

plan() {
  local mode kind name onto how key up tg tdef udef n u sha
  local -a keys
  need_env ENTRY TARGET_URL UPSTREAM_URL WORK GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  [[ -d $WORK ]] || die "WORK $WORK is not a directory"
  [[ $UPSTREAM_URL != -* && $TARGET_URL != -* ]] || die "invalid URL"
  # backups must not land in a namespace that is synced (refs/heads/, refs/tags/)
  if [[ $BACKUP_PREFIX != refs/?*/ || $BACKUP_PREFIX == refs/heads/* ||
    $BACKUP_PREFIX == refs/tags/ ]] || ! git check-ref-format "${BACKUP_PREFIX}x"; then
    die "invalid BACKUP_PREFIX $BACKUP_PREFIX"
  fi
  # shellcheck disable=SC2153 # ENTRY comes from the environment
  kind=$(jq -r .kind <<<"$ENTRY")
  mode=$(jq -r .refs <<<"$ENTRY")
  [[ $mode == default || $mode == all ]] || die "invalid refs mode $mode"
  [[ $kind == fork || $mode == all ]] || die "a mirror needs refs all"

  REPO=$WORK/repo
  PLAN_TMP=$WORK/plan.tsv.tmp
  rm -f "$WORK/plan.tsv" "$PLAN_TMP"
  trap 'rm -f "$PLAN_TMP"' EXIT
  : >"$PLAN_TMP"
  : >"$WORK/skipped.txt"
  git init -q "$REPO"

  g fetch -q --no-tags --no-write-fetch-head -- "$UPSTREAM_URL" \
    '+refs/heads/*:refs/up/heads/*' '+refs/tags/*:refs/up/tags/*' ||
    die "cannot fetch upstream"
  g fetch -q --no-tags --no-write-fetch-head -- "$TARGET_URL" \
    '+refs/heads/*:refs/tg/heads/*' '+refs/tags/*:refs/tg/tags/*' \
    "+${BACKUP_PREFIX}*:refs/tg/backup/*" ||
    die "cannot fetch target"

  declare -gA UPR=() TGR=() BKR=() DECL=() CONTRIB=()
  load up UPR
  load tg TGR
  while IFS=$'\t' read -r sha name; do
    BKR[${name#refs/tg/backup/}]=$sha
  done < <(g for-each-ref --format=$'%(objectname)\t%(refname)' refs/tg/backup/)
  if [[ -f $WORK/contrib.txt ]]; then
    while IFS= read -r name || [[ -n $name ]]; do
      [[ -z $name ]] || CONTRIB[$name]=1
    done <"$WORK/contrib.txt"
  fi

  u=${#UPR[@]}
  n=${#TGR[@]}
  if ((u == 0)) || { [[ $mode == all ]] && ((2 * u < n)); }; then
    die "upstream has $u refs, target $n: refusing (empty or broken source)"
  fi

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
    elif wants_rebase "$how" "$name"; then
      rebase_branch "$name" "$onto"
    fi
  done < <(jq -r '.branches[] | [.name, .onto, .rebase]
    | map((. // "") | tostring | explode | map(if . < 32 or . == 127 then 63 else . end) | implode) | join("\u001f")' <<<"$ENTRY")

  if [[ $mode == default ]]; then
    udef=$(default_branch "$UPSTREAM_URL" upstream)
    [[ -n $udef && -n ${UPR[heads/$udef]:-} ]] || die "upstream default branch missing"
    tdef=$(default_branch "$TARGET_URL" target)
    tdef=${tdef:-$udef}
    if [[ -n ${DECL[$tdef]:-} ]]; then
      :
    elif [[ -n ${CONTRIB[$tdef]:-} ]]; then
      skip "refs/heads/$tdef" contribution
    else
      up=${UPR[heads/$udef]}
      tg=${TGR[heads/$tdef]:-$ZERO}
      if [[ $tg == "$ZERO" ]] || { [[ $tg != "$up" ]] && is_ancestor "$tg" "$up"; }; then
        add "refs/heads/$tdef" "$tg" "$up" ff
      elif [[ $tg != "$up" ]]; then
        skip "refs/heads/$tdef" undeclared
      fi
    fi
  else
    mapfile -t keys < <(sorted_keys UPR)
    for key in "${keys[@]}"; do
      name=${key#*/}
      up=${UPR[$key]}
      tg=${TGR[$key]:-$ZERO}
      [[ $tg != "$up" ]] || continue
      if [[ $key == heads/* ]]; then
        [[ -z ${DECL[$name]:-} ]] || continue
        if [[ -n ${CONTRIB[$name]:-} ]]; then
          skip "refs/$key" contribution
          continue
        fi
        if [[ $tg != "$ZERO" ]] && ! is_ancestor "$tg" "$up"; then
          skip "refs/$key" undeclared
          continue
        fi
      fi
      add "refs/$key" "$tg" "$up" mirror
    done
    tdef=$(default_branch "$TARGET_URL" target)
    mapfile -t keys < <(sorted_keys TGR)
    for key in "${keys[@]}"; do
      [[ -z ${UPR[$key]:-} ]] || continue
      name=${key#*/}
      if [[ $key == heads/* ]]; then
        [[ -z ${DECL[$name]:-} ]] || continue
        if [[ $name == "$tdef" ]]; then
          skip "refs/$key" "default branch"
          continue
        fi
        if [[ -n ${CONTRIB[$name]:-} ]]; then
          skip "refs/$key" contribution
          continue
        fi
      fi
      if contained "${TGR[$key]}"; then
        add "refs/$key" "${TGR[$key]}" "$ZERO" delete
      else
        skip "refs/$key" "unique commits"
      fi
    done
  fi

  LC_ALL=C sort -u -o "$WORK/skipped.txt" "$WORK/skipped.txt"
  mv "$PLAN_TMP" "$WORK/plan.tsv"
}

case ${1:-} in
  plan) plan ;;
  push)
    printf 'error: not implemented\n' >&2
    exit 2
    ;;
  *)
    printf 'usage: %s plan|push\n' "$0" >&2
    exit 2
    ;;
esac
