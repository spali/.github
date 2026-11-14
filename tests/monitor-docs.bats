#!/usr/bin/env bats

setup() {
  # shellcheck source=../scripts/monitor-lib.sh
  source "$BATS_TEST_DIRNAME/../scripts/monitor-lib.sh"
}

@test "every check id is documented in AGENTS.md" {
  for id in "${MONITOR_CHECKS[@]}"; do
    run grep -F -- "\`$id\`" "$BATS_TEST_DIRNAME/../AGENTS.md"
    [ "$status" -eq 0 ] || { echo "undocumented: $id"; return 1; }
  done
}
