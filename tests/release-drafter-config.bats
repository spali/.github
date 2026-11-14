#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  CONFIG="$BATS_TEST_DIRNAME/../.github/release-drafter.yml"
}

# label_for prints the label the autolabeler picks for a PR title: rules in
# order, the first rule whose title regex matches wins (stop-on-match),
# otherwise the fallback rule.
label_for() {
  yq -o=json '.autolabeler' "$CONFIG" | TITLE=$1 node -e '
    const rules = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const title = process.env.TITLE;
    const toRe = (s) => { const m = s.match(/^\/(.*)\/([a-z]*)$/); return new RegExp(m[1], m[2]); };
    for (const r of rules.filter((r) => !r.fallback)) {
      if ((r.title || []).some((t) => toRe(t).test(title))) { console.log(r.labels.join(",")); process.exit(0); }
    }
    console.log(rules.find((r) => r.fallback).labels.join(","));
  '
}

@test "config is valid YAML" {
  run yq '.' "$CONFIG"
  [ "$status" -eq 0 ]
}

@test "autolabeler picks exactly one label per title" {
  while IFS='|' read -r title want; do
    got=$(label_for "$title")
    [ "$got" = "$want" ] || { echo "$title: got $got, want $want"; return 1; }
  done <<'LIST'
feat!: x|breaking-change
fix!: x|breaking-change
refactor(api)!: x|breaking-change
chore(deps)!: x|breaking-change
fix(deps): update module x|dependencies
chore(deps): update actions/checkout action to v8|dependencies
feat(cli): x|feature
feat: x|feature
fix: x|fix
fix(parser): x|fix
docs: x|other
ci: x|other
featx: x|other
LIST
}

@test "autolabeler keeps manual labels" {
  [ "$(yq '.sync-labels' "$CONFIG")" = "false" ]
  [ "$(yq '[.autolabeler[] | select(.["stop-on-match"] == true)] | length' "$CONFIG")" = "4" ]
}

@test "categories are ordered, exclusive and bump the version" {
  run yq -o=tsv '.categories[] | select(.type == null or .type == "changelog") | [.title, (.when.label // "-"), .exclusive, .["semver-increment"]]' "$CONFIG"
  [ "$output" = "$(printf '%s\t%s\t%s\t%s\n' \
    'Breaking Changes' breaking-change true major \
    'Features' feature true minor \
    'Fixes' fix true patch \
    'Dependencies' dependencies true patch \
    'Others' - true patch)" ]
}

@test "release tag and name are v<version>" {
  [ "$(yq '.tag-template' "$CONFIG")" = 'v$RESOLVED_VERSION' ]
  [ "$(yq '.name-template' "$CONFIG")" = 'v$RESOLVED_VERSION' ]
}

# Top-level keys of drafter/schema.json and autolabeler/schema.json of
# release-drafter v7.10.0 (the version pinned in release-prepare.yml and
# pr.yml). Unknown keys are silently ignored by release-drafter.
known_keys='_extends autolabeler categories category-template change-author-template
change-authors-final-separator change-authors-separator change-body-escapes change-template
change-title-escapes commitish exclude-contributors exclude-labels exclude-paths
filter-by-commitish filter-by-range footer group-changes header history-limit include-labels
include-paths include-pre-releases latest name-template new-contributor-template
no-changes-template no-contributors-template no-new-contributor-template prerelease
prerelease-identifier pull-request-limit replacers sort-by sort-direction sync-labels
tag-prefix tag-template template version-resolver version-template'

@test "config uses only keys release-drafter knows" {
  unknown=()
  for key in $(yq 'keys | .[]' "$CONFIG"); do
    [[ " ${known_keys//$'\n'/ } " == *" $key "* ]] || unknown+=("$key")
  done
  [ "${#unknown[@]}" -eq 0 ] || { echo "unknown keys: ${unknown[*]}"; false; }
}
