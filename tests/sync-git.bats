#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/git-repos
  repos_init
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/sync-git.sh"
  ZERO=0000000000000000000000000000000000000000
  unset SYNC_BRANCH BACKUP_PREFIX
  A=$(commit - f a)
  B=$(commit "$A" f b)
  set_ref "$UP" refs/heads/main "$B"
}

# fresh_work empties $WORK for a second run in the same test.
fresh_work() {
  rm -rf "$WORK"
  mkdir "$WORK"
}

AUTO='[{"name": "main", "onto": "main", "rebase": "auto"}]'

@test "pure fork fast-forwards default branch" {
  set_ref "$TG" refs/heads/main "$A"
  entry fork default
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/main\t%s\t%s\tff' "$A" "$B")" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "fork with undeclared own commits is skipped" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$O"
  entry fork default
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/main\tundeclared')" ]
}

@test "declared branch is rebased onto upstream" {
  O1=$(GIT_AUTHOR_NAME=me commit "$A" o1 one "own one")
  O2=$(GIT_AUTHOR_NAME=me commit "$O1" o2 two "own two")
  set_ref "$TG" refs/heads/main "$O2"
  entry fork default "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  N=$(git -C "$WORK/repo" rev-parse refs/heads/main)
  [ "$(plan_line refs/heads/main)" = "$(printf '%s\t%s\trebase' "$O2" "$N")" ]
  [ "$(git -C "$WORK/repo" rev-parse "$N~2")" = "$B" ]
  [ "$(git -C "$WORK/repo" log --format=%s "$B..$N")" = $'own two\nown one' ]
  [ "$(git -C "$WORK/repo" log --format='%an %cn' "$B..$N" | sort -u)" = "me sync" ]
  pid() { git -C "$WORK/repo" show "$1" | git patch-id --stable | cut -d' ' -f1; }
  [ "$(pid "$N~1")" = "$(pid "$O1")" ]
  [ "$(pid "$N")" = "$(pid "$O2")" ]
}

@test "already contained own commit is dropped" {
  O1=$(commit "$A" o1 one "own one")
  O2=$(commit "$O1" o2 two "own two")
  C=$(commit "$B" o1 one "picked one")
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$TG" refs/heads/main "$O2"
  entry fork default "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  N=$(git -C "$WORK/repo" rev-parse refs/heads/main)
  [ "$(git -C "$WORK/repo" rev-parse "$N~1")" = "$C" ]
  [ "$(git -C "$WORK/repo" log --format=%s "$C..$N")" = "own two" ]
}

@test "conflict aborts without plan" {
  O=$(commit "$A" f own)
  set_ref "$TG" refs/heads/main "$O"
  entry fork default "$AUTO"
  run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: branch main: rebase onto main failed (conflict)" ]
  [ ! -e "$WORK/plan.tsv" ]
  [ "$(ref "$TG" refs/heads/main)" = "$O" ]
}

@test "missing onto fails without push" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$O"
  entry fork default '[{"name": "feat", "onto": "dev", "rebase": "auto"}]'
  run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: "*"feat"*"onto dev missing upstream"* ]]
  [ ! -e "$WORK/plan.tsv" ]
  [ "$(ref "$TG" refs/heads/feat)" = "$O" ]
}

@test "manual branch only with SYNC_BRANCH" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$O"
  entry fork default '[{"name": "feat", "onto": "main", "rebase": "manual"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  for sb in other; do
    fresh_work
    SYNC_BRANCH=$sb run "$SCRIPT" plan
    [ "$status" -eq 0 ]
    [ ! -s "$WORK/plan.tsv" ]
  done
  for sb in feat '*'; do
    fresh_work
    SYNC_BRANCH=$sb run "$SCRIPT" plan
    [ "$status" -eq 0 ]
    [ "$(plan_line refs/heads/feat | cut -f1,3)" = "$(printf '%s\trebase' "$O")" ]
  done
}

@test "mirror mode adds new branches and tags" {
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/tags/v1 "$A"
  T2=$(atag v2 "$B")
  set_ref "$UP" refs/tags/v2 "$T2"
  set_ref "$TG" refs/heads/main "$A"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/heads/main)" = "$(printf '%s\t%s\tmirror' "$A" "$B")" ]
  [ "$(plan_line refs/heads/dev)" = "$(printf '%s\t%s\tmirror' "$ZERO" "$C")" ]
  [ "$(plan_line refs/tags/v1)" = "$(printf '%s\t%s\tmirror' "$ZERO" "$A")" ]
  [ "$(plan_line refs/tags/v2)" = "$(printf '%s\t%s\tmirror' "$ZERO" "$T2")" ]
  [ "$(git -C "$WORK/repo" cat-file -t "$T2")" = tag ]
  [ "$(wc -l <"$WORK/plan.tsv")" -eq 4 ]
}

@test "moved upstream tag is updated" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v1 "$B"
  T1=$(atag v2 "$A")
  T2=$(atag v2 "$B")
  set_ref "$TG" refs/tags/v2 "$T1"
  set_ref "$UP" refs/tags/v2 "$T2"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/tags/v1)" = "$(printf '%s\t%s\tmirror' "$A" "$B")" ]
  [ "$(plan_line refs/tags/v2)" = "$(printf '%s\t%s\tmirror' "$T1" "$T2")" ]
  [ "$(wc -l <"$WORK/plan.tsv")" -eq 2 ]
}

@test "deleted upstream branch is deleted when contained" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$UP" refs/heads/dev "$A"
  set_ref "$TG" refs/heads/dev "$A"
  set_ref "$TG" refs/heads/old "$A"
  set_ref "$TG" refs/tags/gone "$A"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/heads/old)" = "$(printf '%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ "$(plan_line refs/tags/gone)" = "$(printf '%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ "$(wc -l <"$WORK/plan.tsv")" -eq 2 ]
}

@test "deleted upstream branch with unique commits is kept" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/old "$O"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/old\tunique commits')" ]
}

@test "undeclared diverged branch is kept" {
  C=$(commit "$A" d dev)
  O=$(commit "$A" o own)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/dev "$O"
  entry fork all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/main\t%s\t%s\tmirror' "$A" "$B")" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/dev\tundeclared')" ]
}

@test "contribution branch is never planned" {
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/feat "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$A"
  set_ref "$TG" refs/heads/fix "$A"
  printf '%s\n' fix feat >"$WORK/contrib.txt"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(sort "$WORK/skipped.txt")" = "$(printf 'refs/heads/feat\tcontribution\nrefs/heads/fix\tcontribution')" ]
}

@test "empty source aborts" {
  del_ref "$UP" refs/heads/main
  set_ref "$TG" refs/heads/main "$A"
  for kind in "fork default" "mirror all"; do
    fresh_work
    # shellcheck disable=SC2086 # two words on purpose
    entry $kind
    run --separate-stderr "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: upstream has 0 refs, target 1: refusing (empty or broken source)" ]
    [ ! -e "$WORK/plan.tsv" ]
  done
}

@test "half of the refs missing aborts" {
  set_ref "$UP" refs/heads/a "$A"
  for r in heads/main heads/a heads/b heads/c heads/d tags/v1; do
    set_ref "$TG" "refs/$r" "$A"
  done
  entry mirror all
  run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: upstream has 2 refs, target 6: refusing (empty or broken source)" ]
  [ ! -e "$WORK/plan.tsv" ]
  # exactly half is still enough
  set_ref "$UP" refs/heads/b "$A"
  fresh_work
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
}

@test "option-like ref names are ignored" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$UP" 'refs/heads/--upload-pack=touch_pwned' "$A"
  set_ref "$UP" refs/tags/-t "$A"
  printf '%s\n' "$A" >"$UP/refs/heads/bad..name"
  entry mirror all
  cd "$BATS_TEST_TMPDIR"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/--upload-pack=touch_pwned\tinvalid ref name\nrefs/tags/-t\tinvalid ref name')" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'touch_pwned*' -o -name pwned)" ]
  # a declared branch from the config is checked too
  fresh_work
  entry fork default '[{"name": "--exec=x", "onto": "main", "rebase": "auto"}, {"name": "main", "onto": "-x", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/%s\tinvalid ref name\n' --exec=x --upload-pack=touch_pwned main; printf 'refs/tags/-t\tinvalid ref name')" ]
}

@test "merge-requests refs are never fetched" {
  C=$(commit "$A" mr change)
  D=$(commit "$A" pr change)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$UP" refs/merge-requests/1/head "$C"
  set_ref "$UP" refs/pull/2/head "$D"
  set_ref "$UP" refs/remotes/origin/x "$D"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  run git -C "$WORK/repo" cat-file -e "$C"
  [ "$status" -ne 0 ]
  run git -C "$WORK/repo" cat-file -e "$D"
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$WORK/repo" for-each-ref | grep -E 'merge-requests|pull|remotes')" ]
}

@test "backup line for every rebased branch" {
  OM=$(commit "$A" o own)
  OF=$(commit "$B" g feat)
  X=$(commit "$A" x old)
  set_ref "$TG" refs/heads/main "$OM"
  set_ref "$TG" refs/heads/feat "$OF"
  set_ref "$TG" refs/backup/main "$X"
  C=$(commit "$B" f c)
  set_ref "$UP" refs/heads/main "$C"
  entry fork default '[{"name": "main", "onto": "main", "rebase": "auto"},
    {"name": "feat", "onto": "main", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/backup/main)" = "$(printf '%s\t%s\tbackup' "$X" "$OM")" ]
  [ "$(plan_line refs/backup/feat)" = "$(printf '%s\t%s\tbackup' "$ZERO" "$OF")" ]
  [ "$(cut -f4 "$WORK/plan.tsv" | sort | uniq -c | awk '{print $2 $1}' | tr '\n' ' ')" = "backup2 rebase2 " ]
  # the prefix is configurable
  fresh_work
  BACKUP_PREFIX=refs/tags/backup/ run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/tags/backup/main)" = "$(printf '%s\t%s\tbackup' "$ZERO" "$OM")" ]
  [ "$(plan_line refs/tags/backup/feat)" = "$(printf '%s\t%s\tbackup' "$ZERO" "$OF")" ]
}

@test "missing onto fails without own commits" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$B"
  for refs in default all; do
    fresh_work
    entry fork "$refs" '[{"name": "feat", "onto": "dev", "rebase": "auto"}]'
    run --separate-stderr "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: branch feat: onto dev missing upstream" ]
    [ ! -e "$WORK/plan.tsv" ]
  done
}

@test "target default branch is never deleted" {
  git -C "$TG" symbolic-ref HEAD refs/heads/master
  set_ref "$TG" refs/heads/master "$A"
  set_ref "$TG" refs/heads/main "$B"
  entry mirror all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/master\tdefault branch')" ]
}

@test "target default follows the upstream default" {
  git -C "$TG" symbolic-ref HEAD refs/heads/master
  set_ref "$TG" refs/heads/master "$A"
  entry fork default
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/master\t%s\t%s\tff' "$A" "$B")" ]
  # diverged: skipped, upstream main is not created
  fresh_work
  set_ref "$TG" refs/heads/master "$(commit "$A" o own)"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/master\tundeclared')" ]
}

@test "contribution branches are never planned in default mode" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/feat "$O"
  printf '%s\n' main feat >"$WORK/contrib.txt"
  entry fork default '[{"name": "feat", "onto": "main", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/feat\tcontribution\nrefs/heads/main\tcontribution')" ]
}

@test "rebase needs a committer identity" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork default
  for v in GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
    fresh_work
    run --separate-stderr env -u "$v" "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: $v is required" ]
  done
}

@test "backup prefix must not be a branch or tag namespace" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork default
  for p in refs/heads/ refs/heads/backup/ refs/tags/ refs/backup refs/; do
    fresh_work
    BACKUP_PREFIX=$p run --separate-stderr "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: invalid BACKUP_PREFIX $p" ]
  done
  for p in refs/backup/ refs/tags/backup/; do
    fresh_work
    BACKUP_PREFIX=$p run "$SCRIPT" plan
    [ "$status" -eq 0 ]
  done
}

@test "declared branch with an empty field is skipped" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$O"
  entry fork default '[{"name": "feat", "onto": "", "rebase": "auto"}, {"name": "", "onto": "main", "rebase": "auto"}]'
  SYNC_BRANCH=feat run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/\tinvalid ref name\nrefs/heads/feat\tinvalid ref name')" ]
}

# --- push ---

# snap prints all refs of the target (name sha).
snap() {
  git -C "$TG" for-each-ref --format='%(refname) %(objectname)'
}

# hook NAME BODY installs a hook script in the target repository.
hook() {
  printf '#!/bin/sh\n%s\n' "$2" >"$TG/hooks/$1"
  chmod +x "$TG/hooks/$1"
}

# full_plan sets up a fork (refs all) whose plan has every reason:
# rebase + backup (feat), mirror create (dev), mirror update (main, tag v1),
# delete (old).
full_plan() {
  C=$(commit "$A" d dev)
  OF=$(commit "$A" g feat)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/feat "$OF"
  set_ref "$TG" refs/heads/old "$A"
  set_ref "$TG" refs/tags/v1 "$A"
  entry fork all '[{"name": "feat", "onto": "main", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cut -f4 "$WORK/plan.tsv" | sort | tr '\n' ' ')" = "backup delete mirror mirror mirror rebase " ]
}

@test "push updates all planned refs" {
  full_plan
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  out=$output
  while IFS=$'\t' read -r r old new why; do
    if [[ $new == "$ZERO" ]]; then
      run git -C "$TG" rev-parse --verify --quiet "$r"
      [ "$status" -ne 0 ]
    else
      [ "$(ref "$TG" "$r")" = "$new" ]
    fi
    [[ $'\n'$out$'\n' == *$'\n'"$r ${old:0:7}..${new:0:7} ($why)"$'\n'* ]]
  done <"$WORK/plan.tsv"
  [[ $out == *"refs/heads/old ${A:0:7}..0000000 (delete)"* ]]
  [[ $out == *"refs/heads/dev 0000000..${C:0:7} (mirror)"* ]]
  [ "$(ref "$TG" refs/backup/feat)" = "$OF" ]
  # a second sync has nothing left to do
  fresh_work
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  run "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$output" = "nothing to do" ]
}

@test "push with stale lease keeps the user's commit" {
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$TG" refs/heads/main "$A"
  entry fork all
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$WORK/plan.tsv")" -eq 2 ]
  U=$(commit "$A" u user)
  set_ref "$TG" refs/heads/main "$U"
  before=$(snap)
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: push rejected, target unchanged" ]
  [ -z "$output" ]
  [ "$(ref "$TG" refs/heads/main)" = "$U" ]
  [ "$(snap)" = "$before" ]
  # a ref that must not exist yet but does
  fresh_work
  del_ref "$TG" refs/heads/main
  set_ref "$TG" refs/heads/main "$A"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  set_ref "$TG" refs/heads/dev "$U"
  before=$(snap)
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: push rejected, target unchanged" ]
  [ "$(snap)" = "$before" ]
}

@test "rejected push leaves all refs unchanged" {
  full_plan
  hook pre-receive 'if grep -q " refs/heads/dev$"; then echo "denied dev" >&2; exit 1; fi'
  before=$(snap)
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: push rejected, target unchanged" ]
  [[ $stderr == *"denied dev"* ]]
  [ -z "$output" ]
  [ "$(snap)" = "$before" ]
}

@test "verify mismatch restores old state" {
  full_plan
  before=$(snap)
  # the created dev is gone right after the push: verify fails, the other
  # five refs are restored
  hook post-receive 'git update-ref -d refs/heads/dev; rm -f "$0"'
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: verify failed, restored 5 refs" ]
  [ -z "$output" ]
  [ "$(snap)" = "$before" ]
}

@test "failed restore is reported loudly" {
  OM=$(commit "$A" o own)
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$TG" refs/heads/main "$OM"
  entry fork all "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cut -f1,4 "$WORK/plan.tsv" | sort | tr '\t\n' ' ,')" = "refs/backup/main backup,refs/heads/dev mirror,refs/heads/main rebase," ]
  # someone moves main right after the push: it is never overwritten, the
  # backup of the old tip stays, the other refs are restored
  hook post-receive "git update-ref refs/heads/main $A; rm -f \"\$0\""
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: RESTORE FAILED for refs/heads/main, backups at refs/backup/" ]
  [ -z "$output" ]
  [ "$(ref "$TG" refs/heads/main)" = "$A" ]
  [ "$(ref "$TG" refs/backup/main)" = "$OM" ]
  run git -C "$TG" rev-parse --verify --quiet refs/heads/dev
  [ "$status" -ne 0 ]
  # the restore push itself is rejected: nothing is restored
  rm -rf "$TG"
  git init -q --bare -b main "$TG"
  set_ref "$TG" refs/heads/main "$OM"
  hook post-receive 'git update-ref -d refs/heads/dev; printf "#!/bin/sh\nexit 1\n" >hooks/pre-receive; chmod +x hooks/pre-receive; rm -f "$0"'
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: RESTORE FAILED for refs/heads/main refs/backup/main, backups at refs/backup/" ]
  [ "$(ref "$TG" refs/heads/main)" = "$(plan_line refs/heads/main | cut -f2)" ]
  [ "$(ref "$TG" refs/backup/main)" = "$OM" ]
}

@test "token is never in the process args or output" {
  full_plan
  real=$(command -v git)
  mkdir "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR/args.log" "$real" >"$BATS_TEST_TMPDIR/bin/git"
  chmod +x "$BATS_TEST_TMPDIR/bin/git"
  tok=ghs_dummyTOKEN0123456789
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
  export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $tok"
  # tracing from the caller's environment is switched off
  export GIT_TRACE=1 GIT_TRACE2=1 GIT_TRACE2_EVENT=1 GIT_TRACE_CURL=1
  # the failure path copies git's output to stderr
  hook pre-receive 'exit 1'
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "error: push rejected, target unchanged" ]
  [[ $output != *"$tok"* ]]
  rm "$TG/hooks/pre-receive"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 6 ]
  [[ $output != *"$tok"* ]]
  grep -q push "$BATS_TEST_TMPDIR/args.log"
  ! grep -q "$tok" "$BATS_TEST_TMPDIR/args.log"
  # a URL with credentials is refused before any git call
  for url in "https://x-access-token:$tok@github.com/spali/t.git" "https://$tok@github.com/spali/t.git" \
    "git@github.com:spali/t.git" "ssh://git@github.com/spali/t.git"; do
    rm -f "$BATS_TEST_TMPDIR/args.log"
    TARGET_URL=$url PATH="$BATS_TEST_TMPDIR/bin:$PATH" run "$SCRIPT" push
    [ "$status" -eq 1 ]
    [ "$output" = "error: TARGET_URL must not contain credentials" ]
    [ ! -e "$BATS_TEST_TMPDIR/args.log" ]
  done
}

@test "empty plan does nothing" {
  set_ref "$TG" refs/heads/main "$B"
  : >"$WORK/plan.tsv"
  before=$(snap)
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$output" = "nothing to do" ]
  [ "$(snap)" = "$before" ]
  # no plan at all is an error
  rm "$WORK/plan.tsv"
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no plan in $WORK" ]
}

@test "invalid plan line is refused" {
  full_plan
  before=$(snap)
  cp "$WORK/plan.tsv" "$BATS_TEST_TMPDIR/good.tsv"
  bad=(
    "$(printf 'refs/remotes/x\t%s\t%s\tmirror' "$ZERO" "$A")"
    "$(printf 'refs/heads/-x\t%s\t%s\tmirror' "$ZERO" "$A")"
    "$(printf 'refs/heads/a..b\t%s\t%s\tmirror' "$ZERO" "$A")"
    "$(printf 'refs/heads/x\t%s\t%s\tmirror' "$ZERO" "${A:0:39}")"
    "$(printf 'refs/heads/x\t%s\t%s\tmirror' "-$ZERO" "$A")"
    "$(printf 'refs/heads/x\t%s\t%s' "$ZERO" "$A")"
    "$(printf 'refs/heads/x\t%s\t%s\tmirror\textra' "$ZERO" "$A")"
    "$(printf 'refs/heads/x\t%s\t%s\tbogus' "$ZERO" "$A")"
    "$(printf 'refs/heads/x\t%s\t%s\tmirror' "$A" "$A")"
    "$(head -n1 "$BATS_TEST_TMPDIR/good.tsv")"
    "$(printf 'refs/backupx/x\t%s\t%s\tbackup' "$ZERO" "$A")"
  )
  for line in "${bad[@]}"; do
    { cat "$BATS_TEST_TMPDIR/good.tsv"; printf '%s\n' "$line"; } >"$WORK/plan.tsv"
    run --separate-stderr "$SCRIPT" push
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: invalid plan line 7" ]
    [ "$(snap)" = "$before" ]
  done
}

@test "same plan pushed twice is not reverted" {
  full_plan
  cp -r "$WORK" "$BATS_TEST_TMPDIR/w2"
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  first=$output
  after=$(snap)
  # a second sync with the same plan: its leases fail, the target already
  # shows every new sha, so it reports success and touches nothing
  WORK=$BATS_TEST_TMPDIR/w2 run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$output" = "$first" ]
  [ "$(snap)" = "$after" ]
}

@test "failed push in a mixed state touches nothing" {
  full_plan
  # another writer has put main at its new sha and moved feat (lease fails)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$(commit "$OF" u user)"
  before=$(snap)
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: push failed, target in mixed state: refs/heads/feat refs/backup/feat refs/heads/dev refs/tags/v1 refs/heads/old" ]
  [ "$(snap)" = "$before" ]
}

@test "global git config does not change the push" {
  full_plan
  git -C "$WORK/repo" -c user.name=x -c user.email=x@example.com tag -a -m x extra "$C"
  export HOME=$BATS_TEST_TMPDIR/home
  mkdir "$HOME"
  printf '[push]\n\tfollowTags = true\n' >"$HOME/.gitconfig"
  unset GIT_CONFIG_GLOBAL
  [ "$(git config --get push.followTags)" = true ]
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  run git -C "$TG" rev-parse --verify --quiet refs/tags/extra
  [ "$status" -ne 0 ]
}
