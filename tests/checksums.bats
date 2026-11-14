#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  CHECKSUMS="$BATS_TEST_DIRNAME/../scripts/checksums.sh"
  DIST="$BATS_TEST_TMPDIR/dist"
  mkdir -p "$DIST"
}

@test "writes sha256 sums of all files sorted by name" {
  echo b >"$DIST/b.tar.gz"
  echo a >"$DIST/a.zip"
  run "$CHECKSUMS" "$DIST"
  [ "$status" -eq 0 ]
  [ "$(cat "$DIST/checksums.txt")" = "$(cd "$DIST" && sha256sum a.zip b.tar.gz)" ]
}

@test "replaces an existing checksums.txt instead of hashing it" {
  echo a >"$DIST/a.zip"
  echo stale >"$DIST/checksums.txt"
  run "$CHECKSUMS" "$DIST"
  [ "$status" -eq 0 ]
  [ "$(cat "$DIST/checksums.txt")" = "$(cd "$DIST" && sha256sum a.zip)" ]
}

@test "fails without assets" {
  run --separate-stderr "$CHECKSUMS" "$DIST"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no release assets found in $DIST" ]
}

@test "fails on a missing directory" {
  run --separate-stderr "$CHECKSUMS" "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: no release assets found in $BATS_TEST_TMPDIR/missing" ]
}

@test "fails on a directory in the assets" {
  echo a >"$DIST/a.zip"
  mkdir "$DIST/sub"
  run --separate-stderr "$CHECKSUMS" "$DIST"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: release assets must be files, $DIST/sub is a directory" ]
  [ ! -e "$DIST/checksums.txt" ]
}
