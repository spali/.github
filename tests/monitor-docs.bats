#!/usr/bin/env bats

setup() {
  # shellcheck source=../scripts/monitor-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
  AGENTS="$BATS_TEST_DIRNAME/../AGENTS.md"
}

@test "every check id is documented in AGENTS.md" {
  for id in "${MONITOR_CHECKS[@]}"; do
    run grep -F -- "| \`$id\` " "$AGENTS"
    [ "$status" -eq 0 ] || { echo "undocumented: $id"; return 1; }
  done
}

@test "every check id in the AGENTS.md catalog exists" {
  ids=$(sed -n '/^### Monitor findings/,/^## 6/p' "$AGENTS" | grep -Eo '^\| `[a-z-]+`' | tr -d '| `')
  [ -n "$ids" ]
  for id in $ids; do
    [[ " ${MONITOR_CHECKS[*]} " == *" $id "* ]] || { echo "unknown: $id"; return 1; }
  done
}

@test "every check id has a section in docs/monitor-checks.md" {
  DOC="$BATS_TEST_DIRNAME/../docs/monitor-checks.md"
  for id in "${MONITOR_CHECKS[@]}"; do
    run grep -qx -- "## $id" "$DOC"
    [ "$status" -eq 0 ] || { echo "no section: $id"; return 1; }
  done
}

@test "every section in docs/monitor-checks.md is a check id" {
  DOC="$BATS_TEST_DIRNAME/../docs/monitor-checks.md"
  ids=$(sed -n 's/^## //p' "$DOC")
  [ -n "$ids" ]
  for id in $ids; do
    [[ " ${MONITOR_CHECKS[*]} " == *" $id "* ]] || { echo "unknown: $id"; return 1; }
  done
}
