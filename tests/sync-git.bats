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
