# Managed repositories (key `managed:` of the control file), sourced by scripts.
# shellcheck shell=bash
# shellcheck source=scripts/monitor-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/monitor-lib.sh"

MANAGED_DEFAULT_SETTINGS='{"has_issues":false,"has_pull_requests":false,"has_wiki":false,"has_discussions":false,"has_projects":false,"actions":false}'

# JQ program: one normalized object per managed entry of the config on stdin.
# Argument: $defaults (default settings). Entries are assumed validated.
# shellcheck disable=SC2016 # jq program, no shell expansion wanted
MANAGED_JQ='
def gh: capture("^https://github\\.com/(?<o>[^/]+)/(?<n>[^/]+?)(\\.git)?/?$");
(.managed // [])[] |
  (.upstream | test("^https://github\\.com(/|$)")) as $fork
  | {
      repo,
      upstream,
      kind: (if $fork then "fork" else "mirror" end),
      upstream_repo: (if $fork then (.upstream | gh | "\(.o)/\(.n)") else null end),
      refs: (if $fork then (.refs // "default") else "all" end),
      branches: ((.branches // {}) | to_entries | sort_by(.key)
        | map({name: .key, onto: .value.onto, rebase: (.value.rebase // "manual")})),
      settings: ($defaults + (.settings // {})),
      private: (.private // false)
    }'

# managed_entries CONFIG_JSON_FILE prints one normalized JSON object per line.
managed_entries() {
  [[ -r ${1:-} ]] || die "managed_entries: cannot read ${1:-}"
  jq -c --argjson defaults "$MANAGED_DEFAULT_SETTINGS" "$MANAGED_JQ" "$1"
}

# managed_entry CONFIG_JSON_FILE REPO prints the object of one repo, or fails.
managed_entry() {
  local entries
  entries=$(managed_entries "$1") || return 1
  jq -ce --arg repo "$2" 'select(.repo == $repo)' <<<"$entries" | head -n1 | grep . || return 1
}
