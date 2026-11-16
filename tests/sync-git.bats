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

# synced prints the plan lines that are no records.
synced() {
  grep -v $'\trecord$' "$WORK/plan.tsv" || true
}

# no_record BRANCH succeeds when the plan writes no record of BRANCH.
no_record() {
  [ -z "$(plan_line "$REC/$1")" ]
}

# fresh_work empties $WORK for a second run in the same test.
fresh_work() {
  rm -rf "$WORK"
  mkdir "$WORK"
}

AUTO='[{"name": "main", "onto": "main", "rebase": "auto"}]'
REC=refs/sync/upstream

@test "pure fork fast-forwards default branch" {
  set_ref "$TG" refs/heads/main "$A"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/main\t%s\t%s\tff' "$A" "$B")" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "fork with undeclared own commits is skipped" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$O"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  no_record main
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/main\tundeclared')" ]
}

@test "declared branch is rebased onto upstream" {
  O1=$(GIT_AUTHOR_NAME=me commit "$A" o1 one "own one")
  O2=$(GIT_AUTHOR_NAME=me commit "$O1" o2 two "own two")
  set_ref "$TG" refs/heads/main "$O2"
  entry fork "$AUTO"
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
  entry fork "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  N=$(git -C "$WORK/repo" rev-parse refs/heads/main)
  [ "$(git -C "$WORK/repo" rev-parse "$N~1")" = "$C" ]
  [ "$(git -C "$WORK/repo" log --format=%s "$C..$N")" = "own two" ]
}

@test "conflict aborts without plan" {
  O=$(commit "$A" f own)
  set_ref "$TG" refs/heads/main "$O"
  entry fork "$AUTO"
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
  entry fork '[{"name": "feat", "onto": "dev", "rebase": "auto"}]'
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
  entry fork '[{"name": "feat", "onto": "main", "rebase": "manual"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  for sb in other; do
    fresh_work
    SYNC_BRANCH=$sb run "$SCRIPT" plan
    [ "$status" -eq 0 ]
    [ -z "$(synced)" ]
  done
  for sb in feat '*'; do
    fresh_work
    SYNC_BRANCH=$sb run "$SCRIPT" plan
    [ "$status" -eq 0 ]
    [ "$(plan_line refs/heads/feat | cut -f1,3)" = "$(printf '%s\trebase' "$O")" ]
  done
}

@test "missing manual branch is created from onto" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork '[{"name": "feat", "onto": "main", "rebase": "manual"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/feat\t%s\t%s\trebase' "$ZERO" "$B")" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "missing manual branch with a missing onto fails without push" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork '[{"name": "feat", "onto": "dev", "rebase": "manual"}]'
  run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [[ $stderr == *"onto dev missing upstream"* ]]
  [ ! -e "$WORK/plan.tsv" ]
}

@test "follow .* syncs all branches" {
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/tags/v1 "$A"
  T2=$(atag v2 "$B")
  set_ref "$UP" refs/tags/v2 "$T2"
  set_ref "$TG" refs/heads/main "$A"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/heads/main)" = "$(printf '%s\t%s\tff' "$A" "$B")" ]
  [ "$(plan_line refs/heads/dev)" = "$(printf '%s\t%s\tmirror' "$ZERO" "$C")" ]
  [ "$(plan_line refs/tags/v1)" = "$(printf '%s\t%s\tmirror' "$ZERO" "$A")" ]
  [ "$(plan_line refs/tags/v2)" = "$(printf '%s\t%s\tmirror' "$ZERO" "$T2")" ]
  [ "$(git -C "$WORK/repo" cat-file -t "$T2")" = tag ]
  [ "$(synced | wc -l)" -eq 4 ]
}

@test "moved upstream tag stops" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v1 "$B"
  T1=$(atag v2 "$A")
  T2=$(atag v2 "$B")
  set_ref "$TG" refs/tags/v2 "$T1"
  set_ref "$UP" refs/tags/v2 "$T2"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/tags/v1\tupstream moved tag (target %s, upstream %s)\nrefs/tags/v2\tupstream moved tag (target %s, upstream %s)' \
    "${A:0:7}" "${B:0:7}" "${T1:0:7}" "${T2:0:7}")" ]
}

@test "deleted upstream branch is deleted when contained" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$UP" refs/heads/dev "$A"
  set_ref "$TG" refs/heads/dev "$A"
  set_ref "$TG" refs/heads/old "$A"
  set_ref "$TG" refs/tags/gone "$A"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/heads/old)" = "$(printf '%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ "$(plan_line refs/tags/gone)" = "$(printf '%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ "$(synced | wc -l)" -eq 2 ]
}

@test "deleted upstream branch with unique commits is kept" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/old "$O"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  no_record old
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/old\tunique commits')" ]
}

@test "undeclared diverged branch is kept" {
  C=$(commit "$A" d dev)
  O=$(commit "$A" o own)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/dev "$O"
  entry fork '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/main\t%s\t%s\tff' "$A" "$B")" ]
  no_record dev
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/dev\tundeclared')" ]
}

@test "contribution branch is never planned" {
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/feat "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$A"
  set_ref "$TG" refs/heads/fix "$A"
  printf '%s\n' fix feat >"$WORK/contrib.txt"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  no_record feat
  no_record fix
  [ "$(sort "$WORK/skipped.txt")" = "$(printf 'refs/heads/feat\tcontribution\nrefs/heads/fix\tcontribution')" ]
}

@test "empty source aborts" {
  del_ref "$UP" refs/heads/main
  set_ref "$TG" refs/heads/main "$A"
  for kind in fork mirror; do
    fresh_work
    entry "$kind" '[]' '[".*"]'
    run --separate-stderr "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: upstream has 0 refs (branches and tags), target 1: refusing (empty or broken source)" ]
    [ ! -e "$WORK/plan.tsv" ]
  done
}

@test "half of the refs missing aborts" {
  set_ref "$UP" refs/heads/a "$A"
  for r in heads/main heads/a heads/b heads/c heads/d tags/v1; do
    set_ref "$TG" "refs/$r" "$A"
  done
  entry mirror '[]' '[".*"]'
  run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: upstream has 2 refs (branches and tags), target 6: refusing (empty or broken source)" ]
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
  entry mirror '[]' '[".*"]'
  cd "$BATS_TEST_TMPDIR"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/--upload-pack=touch_pwned\tinvalid ref name\nrefs/tags/-t\tinvalid ref name')" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'touch_pwned*' -o -name pwned)" ]
  # a declared branch from the config is checked too
  fresh_work
  entry fork '[{"name": "--exec=x", "onto": "main", "rebase": "auto"}, {"name": "main", "onto": "-x", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/%s\tinvalid ref name\n' --exec=x --upload-pack=touch_pwned main; printf 'refs/tags/-t\tinvalid ref name')" ]
  [ -z "$(find "$BATS_TEST_TMPDIR" -name 'touch_pwned*' -o -name pwned)" ]
}

@test "merge-requests refs are never fetched" {
  C=$(commit "$A" mr change)
  D=$(commit "$A" pr change)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$UP" refs/merge-requests/1/head "$C"
  set_ref "$UP" refs/pull/2/head "$D"
  set_ref "$UP" refs/remotes/origin/x "$D"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
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
  entry fork '[{"name": "main", "onto": "main", "rebase": "auto"},
    {"name": "feat", "onto": "main", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/backup/main)" = "$(printf '%s\t%s\tbackup' "$X" "$OM")" ]
  [ "$(plan_line refs/backup/feat)" = "$(printf '%s\t%s\tbackup' "$ZERO" "$OF")" ]
  [ "$(synced | cut -f4 | sort | uniq -c | awk '{print $2 $1}' | tr '\n' ' ')" = "backup2 rebase2 " ]
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
  for follow in '[]' '[".*"]'; do
    fresh_work
    entry fork '[{"name": "feat", "onto": "dev", "rebase": "auto"}]' "$follow"
    run --separate-stderr "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: branch feat: onto dev missing upstream" ]
    [ ! -e "$WORK/plan.tsv" ]
  done
}

@test "target default branch is never deleted" {
  # master is gone upstream and has own commits: kept as undeclared
  git -C "$TG" symbolic-ref HEAD refs/heads/master
  set_ref "$TG" refs/heads/master "$(commit "$A" o own)"
  set_ref "$TG" refs/heads/main "$B"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  no_record master
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/master\tundeclared')" ]
}

@test "target default follows the upstream default" {
  git -C "$TG" symbolic-ref HEAD refs/heads/master
  set_ref "$TG" refs/heads/master "$A"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/master\t%s\t%s\tff' "$A" "$B")" ]
  # diverged: skipped, upstream main is not created
  fresh_work
  set_ref "$TG" refs/heads/master "$(commit "$A" o own)"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  no_record master
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/master\tundeclared')" ]
}

@test "contribution branches are never planned without follow" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/feat "$O"
  printf '%s\n' main feat >"$WORK/contrib.txt"
  entry fork '[{"name": "feat", "onto": "main", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  no_record feat
  no_record main
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/feat\tcontribution\nrefs/heads/main\tcontribution')" ]
}

@test "rebase needs a committer identity" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork
  for v in GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL; do
    fresh_work
    run --separate-stderr env -u "$v" "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: $v is required" ]
  done
}

@test "backup prefix must not be a branch or tag namespace" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork
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
  entry fork '[{"name": "feat", "onto": "", "rebase": "auto"}, {"name": "", "onto": "main", "rebase": "auto"}]'
  SYNC_BRANCH=feat run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/\tinvalid ref name\nrefs/heads/feat\tinvalid ref name')" ]
}

@test "fast-forward writes the upstream record" {
  set_ref "$TG" refs/heads/main "$A"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$ZERO" "$B")" ]
  # an existing record is updated
  fresh_work
  set_ref "$TG" "$REC/main" "$A"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$A" "$B")" ]
  # an up to date record writes no line
  fresh_work
  set_ref "$TG" "$REC/main" "$B"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(plan_line "$REC/main")" ]
}

@test "first run creates records without stopping" {
  R=$(commit "$A" r rel)
  set_ref "$UP" refs/heads/rel "$R"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/rel "$R"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf '%s/main\t%s\t%s\trecord\n%s/rel\t%s\t%s\trecord' \
    "$REC" "$ZERO" "$B" "$REC" "$ZERO" "$R")" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "rebased declared branch records its onto" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$O"
  entry fork "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$ZERO" "$B")" ]
  # a rebase without a change still records its onto
  fresh_work
  N=$(commit "$B" o own)
  set_ref "$TG" refs/heads/main "$N"
  set_ref "$TG" "$REC/main" "$A"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(plan_line refs/heads/main)" ]
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$A" "$B")" ]
  # a created branch records its onto
  fresh_work
  set_ref "$TG" "$REC/main" "$B"
  entry fork '[{"name": "feat", "onto": "main", "rebase": "manual"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line "$REC/feat")" = "$(printf '%s\t%s\trecord' "$ZERO" "$B")" ]
}

@test "manual branch keeps its record until rebased" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$O"
  set_ref "$TG" "$REC/main" "$A"
  entry fork '[{"name": "main", "onto": "main", "rebase": "manual"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ -z "$(plan_line "$REC/main")" ]
  fresh_work
  SYNC_BRANCH=main run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$A" "$B")" ]
}

@test "deleted followed branch deletes its record" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" "$REC/main" "$B"
  set_ref "$TG" refs/heads/old "$A"
  set_ref "$TG" "$REC/old" "$A"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/heads/old)" = "$(printf '%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ "$(plan_line "$REC/old")" = "$(printf '%s\t%s\trecord' "$A" "$ZERO")" ]
  [ "$(wc -l <"$WORK/plan.tsv")" -eq 2 ]
  # without a record only the branch is deleted
  fresh_work
  del_ref "$TG" "$REC/old"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/old\t%s\t%s\tdelete' "$A" "$ZERO")" ]
}

@test "records are no target branches or tags" {
  # records under refs/tags/ are neither deleted as tags nor counted
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/sync/main "$B"
  set_ref "$TG" refs/tags/btag/v1 "$A"
  entry mirror '[]' '[".*"]'
  RECORD_PREFIX=refs/tags/sync/ TAG_BACKUP_PREFIX=refs/tags/btag/ run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "upstream refs under a sync prefix are invalid" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/sync/main "$B"
  set_ref "$UP" refs/tags/sync/x "$A"
  set_ref "$UP" refs/tags/btag/y "$A"
  set_ref "$UP" refs/tags/bk/z "$A"
  entry fork
  BACKUP_PREFIX=refs/tags/bk/ RECORD_PREFIX=refs/tags/sync/ TAG_BACKUP_PREFIX=refs/tags/btag/ run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/tags/bk/z\tinvalid ref name\nrefs/tags/btag/y\tinvalid ref name\nrefs/tags/sync/x\tinvalid ref name')" ]
}

@test "record prefix must not be a branch or tag namespace" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork
  for v in RECORD_PREFIX TAG_BACKUP_PREFIX; do
    for p in refs/heads/ refs/heads/x/ refs/tags/ refs/sync refs/; do
      fresh_work
      run --separate-stderr env "$v=$p" "$SCRIPT" plan
      [ "$status" -eq 1 ]
      [ "$stderr" = "error: invalid $v $p" ]
      run --separate-stderr env "$v=$p" "$SCRIPT" push
      [ "$status" -eq 1 ]
      [ "$stderr" = "error: invalid $v $p" ]
    done
  done
  # the three prefixes must not overlap
  for pair in "BACKUP_PREFIX=refs/backup/ RECORD_PREFIX=refs/backup/" \
    "BACKUP_PREFIX=refs/backup/ RECORD_PREFIX=refs/backup/rec/" \
    "RECORD_PREFIX=refs/sync/ TAG_BACKUP_PREFIX=refs/sync/tags/" \
    "BACKUP_PREFIX=refs/bk/tags/ TAG_BACKUP_PREFIX=refs/bk/"; do
    fresh_work
    # shellcheck disable=SC2086 # two NAME=value words
    run --separate-stderr env $pair "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [[ $stderr == "error: "*" overlaps "* ]]
  done
  fresh_work
  RECORD_PREFIX=refs/tags/sync/ TAG_BACKUP_PREFIX=refs/btag/ run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(plan_line refs/tags/sync/main)" = "$(printf '%s\t%s\trecord' "$ZERO" "$B")" ]
}

REWRITE='upstream rewritten (synced %s, upstream now %s, %s synced commits gone upstream; target has %s)'

# rewrite_skip REF REC UP GONE OWN prints the skipped.txt line of a rewrite.
rewrite_skip() {
  # shellcheck disable=SC2059 # the format is REWRITE
  printf "%s\t$REWRITE" "$1" "${2:0:7}" "${3:0:7}" "$4" "$5"
}

@test "force-pushed default branch stops" {
  C=$(commit "$A" c x)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" "$REC/main" "$B"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/main "$B" "$C" 1 'no own commits')" ]
}

@test "force-pushed default branch with own commits stops" {
  C=$(commit "$A" c x)
  O=$(commit "$B" o own)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$TG" refs/heads/main "$O"
  set_ref "$TG" "$REC/main" "$B"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/main "$B" "$C" 1 '1 own commits')" ]
}

@test "force-pushed followed branch stops, others sync" {
  R1=$(commit "$A" r one)
  R2=$(commit "$R1" r two)
  R3=$(commit "$A" r three)
  set_ref "$UP" refs/heads/rel "$R3"
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/rel "$R2"
  set_ref "$TG" "$REC/rel" "$R2"
  entry mirror '[]' '["rel"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/main\t%s\t%s\tff' "$A" "$B")" ]
  no_record rel
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/rel "$R2" "$R3" 2 'no own commits')" ]
}

@test "rewritten onto stops the declared branch" {
  C=$(commit "$A" c x)
  O=$(commit "$B" o own)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$TG" refs/heads/main "$O"
  set_ref "$TG" "$REC/main" "$B"
  entry fork "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/main "$B" "$C" 1 '1 own commits')" ]
  # a manual branch rebased on request stops the same way
  fresh_work
  entry fork '[{"name": "main", "onto": "main", "rebase": "manual"}]'
  SYNC_BRANCH=main run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/main "$B" "$C" 1 '1 own commits')" ]
}

@test "declared branch with a record outside the branch rebases" {
  X=$(commit "$A" x old)
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$O"
  set_ref "$TG" "$REC/main" "$X"
  entry fork "$AUTO"
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  N=$(git -C "$WORK/repo" rev-parse refs/heads/main)
  [ "$(plan_line refs/heads/main)" = "$(printf '%s\t%s\trebase' "$O" "$N")" ]
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$X" "$B")" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "without a record a diverged branch stays undeclared" {
  C=$(commit "$A" c x)
  R1=$(commit "$A" r one)
  R2=$(commit "$A" r two)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$UP" refs/heads/rel "$R2"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/rel "$R1"
  entry mirror '[]' '["rel"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/main\tundeclared\nrefs/heads/rel\tundeclared')" ]
}

@test "force-pushed default branch stops, followed branch and tag sync" {
  C=$(commit "$A" c x)
  R=$(commit "$A" r rel)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$UP" refs/heads/rel "$R"
  set_ref "$UP" refs/tags/v1 "$A"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" "$REC/main" "$B"
  entry mirror '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(plan_line refs/heads/main)" ]
  no_record main
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/rel\t%s\t%s\tmirror\n%s/rel\t%s\t%s\trecord\nrefs/tags/v1\t%s\t%s\tmirror' \
    "$ZERO" "$R" "$REC" "$ZERO" "$R" "$ZERO" "$A")" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/main "$B" "$C" 1 'no own commits')" ]
}

# rewrite_setup: upstream main rewritten from B to C (both on A), target
# main at B with record B.
rewrite_setup() {
  C=$(commit "$A" c x)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" "$REC/main" "$B"
}

@test "accepted default branch follows upstream with a backup" {
  rewrite_setup
  entry fork
  SYNC_ACCEPT=main run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/main\t%s\t%s\tff\nrefs/backup/main\t%s\t%s\tbackup\n%s/main\t%s\t%s\trecord' \
    "$B" "$C" "$ZERO" "$B" "$REC" "$B" "$C")" ]
  [ ! -s "$WORK/skipped.txt" ]
  run "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$(ref "$TG" refs/heads/main)" = "$C" ]
  [ "$(ref "$TG" refs/backup/main)" = "$B" ]
  [ "$(ref "$TG" "$REC/main")" = "$C" ]
  # a backup that already holds the old tip writes no line
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" "$REC/main" "$B"
  fresh_work
  SYNC_ACCEPT=main run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(plan_line refs/backup/main)" ]
  [ "$(plan_line refs/heads/main)" = "$(printf '%s\t%s\tff' "$B" "$C")" ]
}

@test "accepted branch behind its record follows upstream" {
  B2=$(commit "$B" f b2)
  C=$(commit "$A" c x)
  R1=$(commit "$A" r one)
  R2=$(commit "$R1" r two)
  R3=$(commit "$A" r three)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$UP" refs/heads/rel "$R3"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" "$REC/main" "$B2"
  set_ref "$TG" refs/heads/rel "$R1"
  set_ref "$TG" "$REC/rel" "$R2"
  entry mirror '[]' '["rel"]'
  SYNC_ACCEPT='*' run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/skipped.txt" ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/main\t%s\t%s\tff\nrefs/backup/main\t%s\t%s\tbackup\n%s/main\t%s\t%s\trecord\nrefs/heads/rel\t%s\t%s\tmirror\nrefs/backup/rel\t%s\t%s\tbackup\n%s/rel\t%s\t%s\trecord' \
    "$B" "$C" "$ZERO" "$B" "$REC" "$B2" "$C" "$R1" "$R3" "$ZERO" "$R1" "$REC" "$R2" "$R3")" ]
}

@test "accept refused with own commits on a followed branch" {
  R1=$(commit "$A" r one)
  R2=$(commit "$A" r two)
  O=$(commit "$R1" o own)
  set_ref "$UP" refs/heads/rel "$R2"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/rel "$O"
  set_ref "$TG" "$REC/rel" "$R1"
  entry mirror '[]' '["rel"]'
  SYNC_ACCEPT=rel run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(plan_line refs/heads/rel)" ]
  [ -z "$(plan_line refs/backup/rel)" ]
  no_record rel
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/rel "$R1" "$R2" 1 '1 own commits'); accept refused: own commits on top, declare the branch or reset it by hand" ]
}

@test "accepted declared branch moves exactly the own commits" {
  O1=$(commit "$B" o1 one "own one")
  O2=$(commit "$O1" o2 two "own two")
  C=$(commit "$A" c x)
  set_ref "$UP" refs/heads/main "$C"
  set_ref "$TG" refs/heads/main "$O2"
  set_ref "$TG" "$REC/main" "$B"
  entry fork "$AUTO"
  SYNC_ACCEPT=main run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/skipped.txt" ]
  N=$(git -C "$WORK/repo" rev-parse refs/heads/main)
  [ "$(git -C "$WORK/repo" rev-list --reverse --format=%s --no-commit-header "$C..$N" | tr '\n' ,)" = "own one,own two," ]
  [ "$(git -C "$WORK/repo" rev-parse "$N~2")" = "$C" ]
  [ "$(cat "$WORK/plan.tsv")" = "$(printf 'refs/heads/main\t%s\t%s\trebase\nrefs/backup/main\t%s\t%s\tbackup\n%s/main\t%s\t%s\trecord' \
    "$O2" "$N" "$ZERO" "$O2" "$REC" "$B" "$C")" ]
  # a conflict fails as before
  fresh_work
  K=$(commit "$A" o1 other)
  set_ref "$UP" refs/heads/main "$K"
  SYNC_ACCEPT=main run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [[ $stderr == *"branch main: rebase onto main failed (conflict)"* ]]
  [ ! -e "$WORK/plan.tsv" ]
}

@test "accept refused when the record is not in the branch" {
  X=$(commit "$A" x old)
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$O"
  set_ref "$TG" "$REC/main" "$X"
  entry fork "$AUTO"
  SYNC_ACCEPT=main run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(rewrite_skip refs/heads/main "$X" "$B" 1 '1 own commits'); accept refused: record not in branch, rebase by hand" ]
}

@test "accepted moved tag with backup" {
  T1=$(atag v2 "$A")
  T2=$(atag v2 "$B")
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$TG" refs/tags/v2 "$T1"
  set_ref "$UP" refs/tags/v2 "$T2"
  entry fork
  SYNC_ACCEPT=tags/v1 run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/tags/v1\t%s\t%s\tmirror\nrefs/backup-tags/v1\t%s\t%s\tbackup' "$A" "$B" "$ZERO" "$A")" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/tags/v2\tupstream moved tag (target %s, upstream %s)' "${T1:0:7}" "${T2:0:7}")" ]
  run "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$(ref "$TG" refs/tags/v1)" = "$B" ]
  [ "$(ref "$TG" refs/backup-tags/v1)" = "$A" ]
  # an annotated tag keeps its tag object in the backup
  fresh_work
  SYNC_ACCEPT=tags/v2 run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/tags/v2\t%s\t%s\tmirror\nrefs/backup-tags/v2\t%s\t%s\tbackup' "$T1" "$T2" "$ZERO" "$T1")" ]
  # a backup that already holds the old tag writes no line
  fresh_work
  set_ref "$TG" refs/backup-tags/v2 "$T1"
  SYNC_ACCEPT=tags/v2 run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/tags/v2\t%s\t%s\tmirror' "$T1" "$T2")" ]
}

@test "accept * accepts all stops of the repo" {
  rewrite_setup
  R1=$(commit "$A" r one)
  R2=$(commit "$A" r two)
  set_ref "$UP" refs/heads/rel "$R2"
  set_ref "$TG" refs/heads/rel "$R1"
  set_ref "$TG" "$REC/rel" "$R1"
  set_ref "$TG" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v1 "$B"
  entry mirror '[]' '[".*"]'
  SYNC_ACCEPT='*' run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/skipped.txt" ]
  [ "$(LC_ALL=C sort "$WORK/plan.tsv")" = "$(printf '%s\t%s\t%s\tbackup\n%s\t%s\t%s\tbackup\n%s\t%s\t%s\tbackup\n%s\t%s\t%s\tff\n%s\t%s\t%s\tmirror\n%s\t%s\t%s\trecord\n%s\t%s\t%s\trecord\n%s\t%s\t%s\tmirror' \
    refs/backup-tags/v1 "$ZERO" "$A" refs/backup/main "$ZERO" "$B" refs/backup/rel "$ZERO" "$R1" \
    refs/heads/main "$B" "$C" refs/heads/rel "$R1" "$R2" \
    "$REC/main" "$B" "$C" "$REC/rel" "$R1" "$R2" refs/tags/v1 "$A" "$B")" ]
}

@test "accept of another branch changes nothing" {
  rewrite_setup
  set_ref "$TG" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v1 "$B"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  plan=$(cat "$WORK/plan.tsv") skipped=$(cat "$WORK/skipped.txt")
  [ -n "$skipped" ]
  for a in dev tags/v2 tags/main main/x; do
    fresh_work
    SYNC_ACCEPT=$a run "$SCRIPT" plan
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/plan.tsv")" = "$plan" ]
    [ "$(cat "$WORK/skipped.txt")" = "$skipped" ]
  done
  # without a stop an accept has no effect
  fresh_work
  set_ref "$UP" refs/heads/main "$B"
  set_ref "$TG" refs/tags/v1 "$B"
  SYNC_ACCEPT='*' run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/plan.tsv" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "invalid accept is refused" {
  set_ref "$TG" refs/heads/main "$B"
  entry fork
  for a in -x tags/ a..b '@{-1}' 'a b' '**'; do
    fresh_work
    SYNC_ACCEPT=$a run --separate-stderr "$SCRIPT" plan
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: invalid SYNC_ACCEPT" ]
    [ ! -e "$WORK/plan.tsv" ]
  done
}

@test "push of an accepted tag keeps branch backups apart" {
  R1=$(commit "$A" r one)
  R2=$(commit "$A" r two)
  set_ref "$UP" refs/heads/tags/v1 "$R2"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/tags/v1 "$R1"
  set_ref "$TG" "$REC/tags/v1" "$R1"
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$TG" refs/tags/v1 "$A"
  entry mirror '[]' '[".*"]'
  SYNC_ACCEPT=tags/v1 run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ ! -s "$WORK/skipped.txt" ]
  run "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$(ref "$TG" refs/heads/tags/v1)" = "$R2" ]
  [ "$(ref "$TG" refs/tags/v1)" = "$B" ]
  [ "$(ref "$TG" refs/backup/tags/v1)" = "$R1" ]
  [ "$(ref "$TG" refs/backup-tags/v1)" = "$A" ]
  [ "$(ref "$TG" "$REC/tags/v1")" = "$R2" ]
}

# up_refs prints the upstream refs fetched into the work repository.
up_refs() {
  git -C "$WORK/repo" for-each-ref --format='%(refname)' refs/up/
}

@test "mirror without follow syncs only the default branch and tags" {
  C=$(commit "$A" d dev)
  D=$(commit "$A" x other)
  T=$(atag v2 "$D")
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v2 "$T"
  set_ref "$TG" refs/heads/main "$A"
  entry mirror
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/main\t%s\t%s\tff\nrefs/tags/v1\t%s\t%s\tmirror\nrefs/tags/v2\t%s\t%s\tmirror' \
    "$A" "$B" "$ZERO" "$A" "$ZERO" "$T")" ]
  [ ! -s "$WORK/skipped.txt" ]
  [ "$(up_refs)" = "$(printf 'refs/up/heads/main\nrefs/up/tags/v1\nrefs/up/tags/v2')" ]
  run git -C "$WORK/repo" cat-file -e "$C"
  [ "$status" -ne 0 ]
}

@test "tags are synced by default" {
  T1=$(atag v1 "$A")
  set_ref "$UP" refs/tags/v1 "$T1"
  set_ref "$UP" refs/tags/v2 "$B"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/v2 "$B"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/tags/v1\t%s\t%s\tmirror' "$ZERO" "$T1")" ]
  [ "$(git -C "$WORK/repo" cat-file -t "$T1")" = tag ]
}

@test "deleted upstream tag with unique commits is kept" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/mine "$O"
  set_ref "$TG" refs/tags/old "$A"
  for t in v1 v2; do
    set_ref "$UP" "refs/tags/$t" "$B"
    set_ref "$TG" "refs/tags/$t" "$B"
  done
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/tags/old\t%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/tags/mine\tunique commits')" ]
}

@test "moved upstream tag on an own commit is kept" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$TG" refs/tags/v1 "$O"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/tags/v1\tupstream moved tag (target %s, upstream %s)' "${O:0:7}" "${B:0:7}")" ]
}

@test "tag commit on an unfetched upstream branch is no unique commit" {
  R=$(commit "$A" r rel)
  S=$(commit "$A" s rel2)
  set_ref "$UP" refs/heads/rel "$R"
  set_ref "$UP" refs/heads/rel2 "$S"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/tags/v0 "$R"
  set_ref "$TG" refs/tags/v1 "$S"
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$UP" refs/tags/keep "$B"
  set_ref "$TG" refs/tags/keep "$B"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/tags/v0\t%s\t%s\tdelete' "$R" "$ZERO")" ]
  # a moved tag stops even when its old commit is upstream
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/tags/v1\tupstream moved tag (target %s, upstream %s)' "${S:0:7}" "${B:0:7}")" ]
  # the extra heads are not synced
  [ "$(git -C "$WORK/repo" for-each-ref --format='%(refname)' refs/up/heads/)" = refs/up/heads/main ]
}

@test "onto branches are fetched for declared branches" {
  C=$(commit "$A" d dev)
  D=$(commit "$A" r rel)
  O=$(commit "$A" o own)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/heads/rel "$D"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feat "$O"
  entry fork '[{"name": "feat", "onto": "dev", "rebase": "auto"}]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(up_refs)" = "$(printf 'refs/up/heads/dev\nrefs/up/heads/main')" ]
  N=$(git -C "$WORK/repo" rev-parse refs/heads/feat)
  [ "$(plan_line refs/heads/feat)" = "$(printf '%s\t%s\trebase' "$O" "$N")" ]
  [ "$(git -C "$WORK/repo" rev-parse "$N~1")" = "$C" ]
}

@test "follow pattern mirrors matching release branches" {
  C=$(commit "$B" r rel)
  D=$(commit "$B" x feat)
  set_ref "$UP" refs/heads/release/v1 "$C"
  set_ref "$UP" refs/heads/feature/x "$D"
  set_ref "$TG" refs/heads/main "$B"
  entry fork '[]' '["^release/.*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/release/v1\t%s\t%s\tmirror' "$ZERO" "$C")" ]
  [ ! -s "$WORK/skipped.txt" ]
  [ "$(up_refs)" = "$(printf 'refs/up/heads/main\nrefs/up/heads/release/v1')" ]
}

@test "follow pattern is a full match" {
  C=$(commit "$B" r rel)
  set_ref "$UP" refs/heads/release/v1 "$C"
  set_ref "$UP" refs/heads/stable "$C"
  set_ref "$UP" refs/heads/stable-2 "$C"
  set_ref "$UP" refs/heads/pre-stable "$C"
  set_ref "$TG" refs/heads/main "$B"
  entry fork '[]' '["release", "stable"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/stable\t%s\t%s\tmirror' "$ZERO" "$C")" ]
  [ "$(up_refs)" = "$(printf 'refs/up/heads/main\nrefs/up/heads/stable')" ]
}

@test "followed branch with own commits is kept" {
  C=$(commit "$A" r rel)
  O=$(commit "$A" o own)
  set_ref "$UP" refs/heads/release/v1 "$C"
  set_ref "$UP" refs/heads/release/v2 "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/release/v1 "$O"
  set_ref "$TG" refs/heads/release/v2 "$A"
  entry fork '[]' '["release/.*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/release/v2\t%s\t%s\tmirror' "$A" "$C")" ]
  no_record release/v1
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/release/v1\tundeclared')" ]
}

@test "followed contribution and declared branches keep their rules" {
  C=$(commit "$A" r rel)
  O=$(commit "$A" o own)
  set_ref "$UP" refs/heads/release/v1 "$C"
  set_ref "$UP" refs/heads/release/v2 "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/release/v1 "$A"
  set_ref "$TG" refs/heads/release/v2 "$O"
  printf '%s\n' release/v1 >"$WORK/contrib.txt"
  entry fork '[{"name": "release/v2", "onto": "main", "rebase": "manual"}]' '["release/.*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  no_record release/v1
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/release/v1\tcontribution')" ]
}

@test "followed branch gone upstream is deleted when contained" {
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/release/old "$A"
  entry fork '[]' '["release/.*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(synced)" = "$(printf 'refs/heads/release/old\t%s\t%s\tdelete' "$A" "$ZERO")" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "followed branch gone upstream is kept with unique commits" {
  O=$(commit "$A" o own)
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/release/old "$O"
  entry fork '[]' '["release/.*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  no_record release/old
  [ "$(cat "$WORK/skipped.txt")" = "$(printf 'refs/heads/release/old\tunique commits')" ]
}

@test "followed target default branch is never deleted" {
  git -C "$TG" symbolic-ref HEAD refs/heads/master
  set_ref "$TG" refs/heads/master "$B"
  entry fork '[]' '["master"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "invalid follow pattern fails without plan" {
  set_ref "$TG" refs/heads/main "$A"
  entry fork '[]' '["release/(v"]'
  run --separate-stderr "$SCRIPT" plan
  [ "$status" -eq 1 ]
  [[ $stderr == *"error: invalid follow pattern"* ]]
  [ ! -e "$WORK/plan.tsv" ]
}

@test "unfollowed target branch is untouched" {
  C=$(commit "$A" x feat)
  O=$(commit "$A" o own)
  set_ref "$UP" refs/heads/feature/x "$C"
  set_ref "$TG" refs/heads/main "$B"
  set_ref "$TG" refs/heads/feature/x "$A"
  set_ref "$TG" refs/heads/feature/y "$O"
  set_ref "$TG" refs/heads/gone "$A"
  entry fork '[]' '["release/.*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ -z "$(synced)" ]
  [ ! -s "$WORK/skipped.txt" ]
}

@test "tags false leaves tags alone" {
  T=$(atag v2 "$A")
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$UP" refs/tags/new "$B"
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/tags/v1 "$A"
  set_ref "$TG" refs/tags/v2 "$T"
  set_ref "$TG" refs/backup/main "$A"
  for kind in fork mirror; do
    fresh_work
    entry "$kind" '[]' '[".*"]' false
    run "$SCRIPT" plan
    [ "$status" -eq 0 ]
    [ "$(synced)" = "$(printf 'refs/heads/main\t%s\t%s\tff' "$A" "$B")" ]
    [ ! -s "$WORK/skipped.txt" ]
    [ "$(up_refs)" = refs/up/heads/main ]
    [ "$(git -C "$WORK/repo" for-each-ref --format='%(refname)' refs/tg/)" = "$(printf 'refs/tg/backup/main\nrefs/tg/heads/main')" ]
    run git -C "$WORK/repo" cat-file -e "$T"
    [ "$status" -ne 0 ]
  done
}

@test "follow .* fetches every branch and tag" {
  C=$(commit "$A" d dev)
  T=$(atag v2 "$C")
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/tags/v1 "$A"
  set_ref "$UP" refs/tags/v2 "$T"
  set_ref "$TG" refs/heads/main "$B"
  entry fork '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(up_refs)" = "$(printf 'refs/up/heads/dev\nrefs/up/heads/main\nrefs/up/tags/v1\nrefs/up/tags/v2')" ]
  [ "$(git -C "$WORK/repo" cat-file -t "$T")" = tag ]
  [ "$(synced | cut -f1 | tr '\n' ' ')" = "refs/heads/dev refs/tags/v1 refs/tags/v2 " ]
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

# full_plan sets up a fork (follow .*) whose plan has every reason:
# rebase + backup (feat), ff (main), mirror create (dev, tag v1), delete
# (old).
full_plan() {
  C=$(commit "$A" d dev)
  OF=$(commit "$A" g feat)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$UP" refs/tags/v1 "$B"
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/feat "$OF"
  set_ref "$TG" refs/heads/old "$A"
  entry fork '[{"name": "feat", "onto": "main", "rebase": "auto"}]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cut -f4 "$WORK/plan.tsv" | sort | tr '\n' ' ')" = "backup delete ff mirror mirror rebase record record record " ]
}

@test "push updates all planned refs" {
  full_plan
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 9 ]
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
  entry fork '[]' '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$WORK/plan.tsv")" -eq 4 ]
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
  set_ref "$TG" "$REC/main" "$A"
  full_plan
  [ "$(plan_line "$REC/main")" = "$(printf '%s\t%s\trecord' "$A" "$B")" ]
  before=$(snap)
  # the created dev is gone right after the push: verify fails, the other
  # eight refs (five synced refs, three records) are restored
  hook post-receive 'git update-ref -d refs/heads/dev; rm -f "$0"'
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: verify failed, restored 8 refs" ]
  [ -z "$output" ]
  [ "$(snap)" = "$before" ]
  [ "$(ref "$TG" "$REC/main")" = "$A" ]
  run git -C "$TG" rev-parse --verify --quiet "$REC/feat"
  [ "$status" -ne 0 ]
}

@test "push writes records atomically" {
  set_ref "$TG" refs/heads/main "$A"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cut -f1,4 "$WORK/plan.tsv" | tr '\t\n' ' ,')" = "refs/heads/main ff,$REC/main record," ]
  # a rejected record leaves the branch alone
  hook pre-receive "if grep -q \" $REC/main\$\"; then exit 1; fi"
  before=$(snap)
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: push rejected, target unchanged" ]
  [ "$(snap)" = "$before" ]
  rm "$TG/hooks/pre-receive"
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  [ "$(ref "$TG" refs/heads/main)" = "$B" ]
  [ "$(ref "$TG" "$REC/main")" = "$B" ]
  [[ $output == *"$REC/main 0000000..${B:0:7} (record)"* ]]
}

@test "failed restore is reported loudly" {
  OM=$(commit "$A" o own)
  C=$(commit "$A" d dev)
  set_ref "$UP" refs/heads/dev "$C"
  set_ref "$TG" refs/heads/main "$OM"
  entry fork "$AUTO" '[".*"]'
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  [ "$(cut -f1,4 "$WORK/plan.tsv" | sort | tr '\t\n' ' ,')" = "refs/backup/main backup,refs/heads/dev mirror,refs/heads/main rebase,refs/sync/upstream/dev record,refs/sync/upstream/main record," ]
  # someone moves main right after the push: it is never overwritten, the
  # backup of the old tip stays, the other refs are restored
  hook post-receive "git update-ref refs/heads/main $A; rm -f \"\$0\""
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: RESTORE FAILED for refs/heads/main, backups at refs/backup/ and refs/backup-tags/" ]
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
  [ "${stderr_lines[-1]}" = "error: RESTORE FAILED for refs/heads/main refs/backup/main refs/sync/upstream/main refs/sync/upstream/dev, backups at refs/backup/ and refs/backup-tags/" ]
  [ "$(ref "$TG" refs/heads/main)" = "$(plan_line refs/heads/main | cut -f2)" ]
  [ "$(ref "$TG" refs/backup/main)" = "$OM" ]
}

@test "failed restore keeps tag backups and restores records" {
  U=$(commit "$A" u user)
  set_ref "$TG" refs/heads/main "$A"
  set_ref "$TG" refs/heads/user "$U"
  entry fork
  run "$SCRIPT" plan
  [ "$status" -eq 0 ]
  printf 'refs/backup-tags/v1\t%s\t%s\tbackup\n' "$ZERO" "$A" >>"$WORK/plan.tsv"
  # someone moves main right after the push: the tag backup stays, the
  # record goes back with the other refs
  hook post-receive "git update-ref refs/heads/main $U; rm -f \"\$0\""
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 1 ]
  [ "${stderr_lines[-1]}" = "error: RESTORE FAILED for refs/heads/main, backups at refs/backup/ and refs/backup-tags/" ]
  [ "$(ref "$TG" refs/heads/main)" = "$U" ]
  [ "$(ref "$TG" refs/backup-tags/v1)" = "$A" ]
  run git -C "$TG" rev-parse --verify --quiet "$REC/main"
  [ "$status" -ne 0 ]
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
  [ "${#lines[@]}" -eq 9 ]
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
    "$(printf 'refs/heads/x\t%s\t%s\trecord' "$ZERO" "$A")"
    "$(printf 'refs/backup/x\t%s\t%s\trecord' "$ZERO" "$A")"
    "$(printf '%s/x\t%s\t%s\tff' "$REC" "$ZERO" "$A")"
    "$(printf '%s/x\t%s\t%s\tbackup' "$REC" "$ZERO" "$A")"
    "$(printf '%s/x\t%s\t%s\tdelete' "$REC" "$A" "$ZERO")"
    "$(printf 'refs/heads/x\t%s\t%s\tdelete' "$ZERO" "$A")"
  )
  n=$(($(wc -l <"$BATS_TEST_TMPDIR/good.tsv") + 1))
  for line in "${bad[@]}"; do
    { cat "$BATS_TEST_TMPDIR/good.tsv"; printf '%s\n' "$line"; } >"$WORK/plan.tsv"
    run --separate-stderr "$SCRIPT" push
    [ "$status" -eq 1 ]
    [ "$stderr" = "error: invalid plan line $n" ]
    [ "$(snap)" = "$before" ]
  done
  # valid: a record delete, a tag backup
  printf '%s/x\t%s\t%s\trecord\nrefs/backup-tags/v1\t%s\t%s\tbackup\n' "$REC" "$A" "$ZERO" "$ZERO" "$A" >"$WORK/plan.tsv"
  set_ref "$TG" "$REC/x" "$A"
  run --separate-stderr "$SCRIPT" push
  [ "$status" -eq 0 ]
  run git -C "$TG" rev-parse --verify --quiet "$REC/x"
  [ "$status" -ne 0 ]
  [ "$(ref "$TG" refs/backup-tags/v1)" = "$A" ]
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
  [ "${stderr_lines[-1]}" = "error: push failed, target in mixed state: refs/heads/feat refs/backup/feat refs/sync/upstream/feat refs/sync/upstream/main refs/heads/dev refs/sync/upstream/dev refs/heads/old refs/tags/v1" ]
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
