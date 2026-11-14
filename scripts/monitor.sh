#!/usr/bin/env bash
# Daily maintenance monitor: validates the control files, builds the inventory,
# runs every check script and hands the findings to monitor-report.sh.
#
# Env: GH_TOKEN, MONITOR_PUBLIC_CONFIG (default repos.yml),
# MONITOR_PRIVATE_CONFIG (optional), LISTS_TOKEN (default GH_TOKEN),
# MONITOR_SCRIPTS_DIR (default: this script's directory).
# Prints nothing itself; the report is the only output.
set -euo pipefail

DIR=${MONITOR_SCRIPTS_DIR:-$(dirname "${BASH_SOURCE[0]}")}
# shellcheck source=scripts/monitor-lib.sh
source "$DIR/monitor-lib.sh"

WORK=$(mktemp -d)
export FINDINGS="$WORK/findings.jsonl"
export INVENTORY="$WORK/inventory.json"
export CONFIG="$WORK/config.json"
: >"$FINDINGS"

PUBLIC=${MONITOR_PUBLIC_CONFIG:-repos.yml}
PRIVATE=
EMPTY_CONFIG='{"version":1,"lists":{},"mirrors":[],"forks":[],"ignores":[]}'

# --- control files -----------------------------------------------------
if err=$("$DIR/monitor-config.sh" validate "$PUBLIC" 2>&1 >/dev/null); then
  merge_public=$PUBLIC
else
  line=$(head -n1 <<<"$err")
  line=${line#error: }
  line=${line#"$PUBLIC": }
  finding red config-invalid - "repos.yml: $line"
  merge_public=$WORK/empty.json
  printf '%s\n' "$EMPTY_CONFIG" >"$merge_public"
fi

if [[ -n ${MONITOR_PRIVATE_CONFIG:-} ]]; then
  if [[ ! -f $MONITOR_PRIVATE_CONFIG ]]; then
    finding red config-invalid - "private control file missing"
  elif "$DIR/monitor-config.sh" validate "$MONITOR_PRIVATE_CONFIG" --private >/dev/null 2>&1; then
    PRIVATE=$MONITOR_PRIVATE_CONFIG
  else
    finding red config-invalid - "private control file is invalid"
  fi
fi

if ! "$DIR/monitor-config.sh" merge "$merge_public" ${PRIVATE:+"$PRIVATE"} >"$CONFIG" 2>/dev/null; then
  finding red config-invalid - "control files cannot be merged"
  printf '%s\n' "$EMPTY_CONFIG" >"$CONFIG"
fi

# --- inventory ---------------------------------------------------------
if ! "$DIR/monitor-repos.sh" >"$INVENTORY"; then
  finding red check-failed - "monitor-repos.sh crashed"
  echo '[]' >"$INVENTORY"
fi

# --- public config must not name private repos -------------------------
if repos=$(jq -r --slurpfile inv "$INVENTORY" '
    ($inv[0] | map(select(.private) | .name)) as $privs
    | [(.mirrors[] | select(.private == false) | .target),
       (.forks[] | select(.private == false) | .repo),
       (.ignores[] | select(.private == false) | .repo)]
    | unique[] | select(. as $r | $privs | index($r))' "$CONFIG" 2>/dev/null); then
  while IFS= read -r repo; do
    [[ -z $repo ]] || finding red public-config-private-repo "$repo" "named in the public repos.yml"
  done <<<"$repos"
else
  finding red check-failed - "public-config-private-repo: cannot evaluate"
fi

# --- checks ------------------------------------------------------------
for check in release settings health forks mirrors lists; do
  script=monitor-$check.sh
  if ! LISTS_TOKEN=${LISTS_TOKEN:-${GH_TOKEN:-}} "$DIR/$script" >/dev/null 2>&1; then
    finding red check-failed - "$script crashed"
  fi
done

exec "$DIR/monitor-report.sh"
