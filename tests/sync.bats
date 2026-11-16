#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REAL="$BATS_TEST_DIRNAME/../scripts"
  # A scripts dir with the real libs and config check and stubbed sync steps.
  export MONITOR_SCRIPTS_DIR="$BATS_TEST_TMPDIR/scripts"
  mkdir -p "$MONITOR_SCRIPTS_DIR"
  cp "$REAL"/lib.sh "$REAL"/monitor-lib.sh "$REAL"/managed-lib.sh \
    "$REAL"/monitor-config.sh "$MONITOR_SCRIPTS_DIR"/
  export CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  stub_step sync-create.sh 'echo exists'
  stub_step sync-settings.sh 'echo "settings ok"'
  stub_step sync-git.sh '
if [[ $1 == plan ]]; then
  : >"$WORK/plan.tsv"
  : >"$WORK/skipped.txt"
else
  echo "nothing to do"
fi'
  load helpers/gh-stub
  stub_gh
  echo '{"full_name": "spali/tool"}' | gh_respond 'api repos/spali/tool' -
  echo '{"full_name": "spali/web"}' | gh_respond 'api repos/spali/web' -
  echo '{"id": 4242}' | gh_respond 'api users/sync-app\[bot\]' -
  cat >"$BATS_TEST_TMPDIR/repos.yml" <<'EOS'
version: 1
monitor:
  runs-on: [self-hosted, linux]
managed:
  - repo: spali/tool
    upstream: https://github.com/Up/Tool
    branches:
      feature: {onto: main, rebase: auto}
  - repo: spali/Web
    upstream: https://gitlab.com/up/web.git
EOS
  export MONITOR_CONFIG="$BATS_TEST_TMPDIR/repos.yml"
  export GH_TOKEN=secret-token SYNC_APP_SLUG=sync-app
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  : >"$GITHUB_STEP_SUMMARY"
  unset SYNC_REPO SYNC_BRANCH GITHUB_OUTPUT GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL \
    GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  SYNC="$REAL/sync.sh"
}

# stub_step NAME BODY replaces a sync step script: it logs its name, its
# arguments and the environment it got to $CALLS, then runs BODY.
stub_step() {
  cat >"$MONITOR_SCRIPTS_DIR/$1" <<EOS
#!/usr/bin/env bash
set -euo pipefail
{
  printf '%s %s\n' "$1" "\$*"
  printf '  repo=%s\n' "\$(jq -r .repo <<<"\$ENTRY")"
  printf '  target=%s upstream=%s\n' "\${TARGET_URL:-}" "\${UPSTREAM_URL:-}"
  printf '  committer=%s <%s>\n' "\${GIT_COMMITTER_NAME:-}" "\${GIT_COMMITTER_EMAIL:-}"
  printf '  config=%s %s %s\n' "\${GIT_CONFIG_COUNT:-}" "\${GIT_CONFIG_KEY_0:-}" "\${GIT_CONFIG_VALUE_0:-}"
  printf '  branch=%s\n' "\${SYNC_BRANCH:-}"
  [[ ! -f \${WORK:-/nonexistent}/contrib.txt ]] || sed 's/^/  contrib=/' "\$WORK/contrib.txt"
} >>"\$CALLS"
$2
EOS
  chmod +x "$MONITOR_SCRIPTS_DIR/$1"
}

# gh_fail_first GLOB MESSAGE makes matching calls fail, ahead of the
# responses registered in setup
gh_fail_first() {
  printf 'fail\t%s\t%s\n' "$1" "$2" | cat - "$GH_RESPONSES" >"$GH_RESPONSES.new"
  mv "$GH_RESPONSES.new" "$GH_RESPONSES"
}

# steps prints the step calls (name and arguments) in order
steps() {
  grep -v '^  ' "$CALLS" || true
}

@test "matrix lists managed repos" {
  run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 0 ]
  [ "$(jq -c .repos <<<"$output")" = '["spali/tool","spali/Web"]' ]
  [ "$(jq -c '."runs-on"' <<<"$output")" = '["self-hosted","linux"]' ]
}

@test "matrix runs-on defaults to ubuntu-latest" {
  printf 'version: 1\nmanaged:\n  - {repo: spali/tool, upstream: "https://github.com/Up/Tool"}\n' >"$MONITOR_CONFIG"
  run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 0 ]
  [ "$(jq -c '."runs-on"' <<<"$output")" = '"ubuntu-latest"' ]
}

@test "matrix filters SYNC_REPO" {
  SYNC_REPO=spali/web run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 0 ]
  # matched case-insensitively, the config's spelling is used
  [ "$(jq -c .repos <<<"$output")" = '["spali/Web"]' ]
}

@test "unknown SYNC_REPO fails" {
  SYNC_REPO=spali/other run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: spali/other is not managed" ]
  [ -z "$output" ]
}

@test "SYNC_BRANCH needs SYNC_REPO" {
  SYNC_BRANCH=feature run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: the branch input needs the repo input" ]
}

@test "invalid SYNC_BRANCH fails" {
  SYNC_REPO=spali/tool SYNC_BRANCH=--upload-pack=x run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 1 ]
  [[ $stderr == "error: invalid branch"* ]]
  SYNC_REPO=spali/tool SYNC_BRANCH='*' run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 0 ]
}

@test "invalid config fails" {
  printf 'version: 2\n' >"$MONITOR_CONFIG"
  run --separate-stderr "$SYNC" matrix
  [ "$status" -eq 1 ]
  [[ $stderr == *"version must be 1"* ]]
  [ -z "$output" ]
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [ -z "$(steps)" ]
  [ ! -s "$GH_LOG" ]
}

@test "exists reports an existing and a missing repo" {
  run --separate-stderr "$SYNC" exists spali/tool
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' name=tool exists=true)" ]
  gh_fail_first 'api repos/spali/tool' 'gh: Not Found (HTTP 404)'
  run --separate-stderr "$SYNC" exists spali/tool
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' name=tool exists=false)" ]
}

@test "exists fails on an API error" {
  gh_fail_first 'api repos/spali/tool' 'gh: Server Error (HTTP 500)'
  run --separate-stderr "$SYNC" exists spali/tool
  [ "$status" -eq 1 ]
  [[ $stderr == *"HTTP 500"* ]]
  [[ $output != *exists=* ]]
}

@test "create runs only sync-create" {
  stub_step sync-create.sh 'echo "created fork"'
  run "$SYNC" create spali/tool
  [ "$status" -eq 0 ]
  [ "$(steps)" = "sync-create.sh " ]
  grep -qx '  repo=spali/tool' "$CALLS"
  grep -q 'created fork' "$GITHUB_STEP_SUMMARY"
}

@test "create failure fails with the message in the summary" {
  stub_step sync-create.sh 'echo "error: create spali/Web by hand: gh repo create spali/Web --public" >&2; exit 1'
  run "$SYNC" create spali/Web
  [ "$status" -eq 1 ]
  [[ $output == *"gh repo create spali/Web --public"* ]]
  grep -q 'gh repo create spali/Web --public' "$GITHUB_STEP_SUMMARY"
}

@test "repo runs create, settings, plan, push in order" {
  run "$SYNC" repo spali/tool
  [ "$status" -eq 0 ]
  [ "$(steps)" = "$(printf '%s\n' 'sync-create.sh ' 'sync-settings.sh ' 'sync-git.sh plan' 'sync-git.sh push')" ]
  [ "$(grep -c '^  repo=spali/tool$' "$CALLS")" -eq 4 ]
}

@test "repo refuses a missing repository" {
  gh_fail_first 'api repos/spali/tool' 'gh: Not Found (HTTP 404)'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [[ $output == *"spali/tool does not exist"* ]]
  [ -z "$(steps)" ]
}

@test "create failure skips git" {
  stub_step sync-create.sh 'echo "error: spali/tool exists but is not a fork of Up/Tool" >&2; exit 1'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [ "$(steps)" = "sync-create.sh " ]
  grep -q 'is not a fork of Up/Tool' "$GITHUB_STEP_SUMMARY"
}

@test "settings failure still syncs git but exits 1" {
  stub_step sync-settings.sh 'echo "has_wiki: true -> false"; echo "error: spali/tool: boom (HTTP 403)" >&2; exit 1'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [ "$(steps)" = "$(printf '%s\n' 'sync-create.sh ' 'sync-settings.sh ' 'sync-git.sh plan' 'sync-git.sh push')" ]
  grep -q 'has_wiki: true -> false' "$GITHUB_STEP_SUMMARY"
  grep -q 'boom (HTTP 403)' "$GITHUB_STEP_SUMMARY"
}

@test "plan failure skips push and exits 1" {
  stub_step sync-git.sh '[[ $1 == plan ]] && { echo "error: branch feature: rebase onto main failed (conflict)" >&2; exit 1; }; echo pushed'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [ "$(steps | tail -n 1)" = "sync-git.sh plan" ]
  grep -q 'rebase onto main failed (conflict)' "$GITHUB_STEP_SUMMARY"
}

@test "push failure exits 1" {
  stub_step sync-git.sh '[[ $1 == plan ]] && exit 0; echo "error: push rejected, target unchanged" >&2; exit 1'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  grep -q 'push rejected, target unchanged' "$GITHUB_STEP_SUMMARY"
}

@test "unmanaged repo is refused" {
  for mode in exists create repo; do
    run "$SYNC" "$mode" spali/other
    [ "$status" -eq 1 ]
    [[ $output == *"spali/other is not managed"* ]]
  done
  # the lookup of an argument is exact
  run "$SYNC" repo spali/web
  [ "$status" -eq 1 ]
  [ -z "$(steps)" ]
  [ ! -s "$GH_LOG" ]
}

@test "summary lists updated and skipped refs" {
  stub_step sync-git.sh '
if [[ $1 == plan ]]; then
  printf "refs/heads/x\tundeclared\nrefs/heads/y\tcontribution\n" >"$WORK/skipped.txt"
else
  echo "refs/heads/main 1111111..2222222 (ff)"
fi'
  run "$SYNC" repo spali/tool
  # a kept undeclared ref fails the run
  [ "$status" -eq 1 ]
  grep -q '^### spali/tool' "$GITHUB_STEP_SUMMARY"
  grep -q 'exists' "$GITHUB_STEP_SUMMARY"
  grep -qx -- '- settings: ok' "$GITHUB_STEP_SUMMARY"
  grep -qF '`refs/heads/main 1111111..2222222 (ff)`' "$GITHUB_STEP_SUMMARY"
  grep -qF '`refs/heads/x`: undeclared' "$GITHUB_STEP_SUMMARY"
  grep -qF '`refs/heads/y`: contribution' "$GITHUB_STEP_SUMMARY"
}

@test "refs kept with own commits fail the run after the push" {
  stub_step sync-git.sh '
if [[ $1 == plan ]]; then
  printf "refs/heads/x\tundeclared\nrefs/heads/y\tcontribution\nrefs/tags/t\tunique commits\n" >"$WORK/skipped.txt"
else
  echo "refs/heads/main 1111111..2222222 (ff)"
fi'
  run --separate-stderr "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [ "$(steps | tail -n 1)" = "sync-git.sh push" ]
  [[ $stderr == *"error: 2 refs kept with own commits: refs/heads/x refs/tags/t"* ]]
  grep -qF 'error: 2 refs kept with own commits: refs/heads/x refs/tags/t' "$GITHUB_STEP_SUMMARY"
  grep -qF '`refs/heads/main 1111111..2222222 (ff)`' "$GITHUB_STEP_SUMMARY"
}

@test "refs skipped for other reasons keep the run green" {
  stub_step sync-git.sh '
if [[ $1 == plan ]]; then
  printf "refs/heads/-x\tinvalid ref name\nrefs/heads/main\tdefault branch\nrefs/heads/y\tcontribution\n" >"$WORK/skipped.txt"
else
  echo "nothing to do"
fi'
  run --separate-stderr "$SYNC" repo spali/tool
  [ "$status" -eq 0 ]
  [[ $stderr != *"kept with own commits"* ]]
  ! grep -q 'kept with own commits' "$GITHUB_STEP_SUMMARY"
}

@test "kept refs are reported also when the push failed" {
  stub_step sync-git.sh '
if [[ $1 == plan ]]; then
  printf "refs/heads/x\tundeclared\n" >"$WORK/skipped.txt"
else
  echo "error: push rejected, target unchanged" >&2; exit 1
fi'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  grep -q 'push rejected, target unchanged' "$GITHUB_STEP_SUMMARY"
  grep -qF 'error: 1 refs kept with own commits: refs/heads/x' "$GITHUB_STEP_SUMMARY"
}

@test "contrib.txt holds open PR heads of this repo only" {
  jq -n '[
    {head: {ref: "fix-a", repo: {full_name: "spali/tool"}}},
    {head: {ref: "other", repo: {full_name: "someone/tool"}}},
    {head: {ref: "gone", repo: null}}]' >"$BATS_TEST_TMPDIR/p1.json"
  jq -n '[{head: {ref: "fix-b", repo: {full_name: "Spali/Tool"}}}]' >"$BATS_TEST_TMPDIR/p2.json"
  cat "$BATS_TEST_TMPDIR/p1.json" "$BATS_TEST_TMPDIR/p2.json" |
    gh_respond 'api --paginate repos/Up/Tool/pulls?state=open&per_page=100' -
  run "$SYNC" repo spali/tool
  [ "$status" -eq 0 ]
  [ "$(grep '^  contrib=' "$CALLS" | sort -u)" = "$(printf '%s\n' '  contrib=fix-a' '  contrib=fix-b')" ]
}

@test "contribution lookup failure skips git" {
  gh_fail_first 'api --paginate repos/Up/Tool/pulls*' 'gh: Server Error (HTTP 502)'
  run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  [ "$(steps)" = "$(printf '%s\n' 'sync-create.sh ' 'sync-settings.sh ')" ]
  grep -q 'HTTP 502' "$GITHUB_STEP_SUMMARY"
}

@test "mirror has no contribution lookup" {
  run "$SYNC" repo spali/Web
  [ "$status" -eq 0 ]
  ! grep -q pulls "$GH_LOG"
  ! grep -q '^  contrib=' "$CALLS"
  grep -qx '  target=https://github.com/spali/Web.git upstream=https://gitlab.com/up/web.git' "$CALLS"
}

@test "git gets the URLs from the entry and the token only through GIT_CONFIG" {
  local header
  header="AUTHORIZATION: basic $(printf '%s' 'x-access-token:secret-token' | base64 -w0)"
  SYNC_BRANCH=feature TARGET_URL=https://evil.example/x UPSTREAM_URL=https://evil.example/y \
    run "$SYNC" repo spali/tool
  [ "$status" -eq 0 ]
  [ "$(grep -c '^  target=https://github.com/spali/tool.git upstream=https://github.com/Up/Tool$' "$CALLS")" -eq 2 ]
  [ "$(grep -cxF "  config=1 http.https://github.com/.extraheader $header" "$CALLS")" -eq 2 ]
  # create and settings get no git credentials
  [ "$(grep -c '^  config=  $' "$CALLS")" -eq 2 ]
  [ "$(grep -c '^  branch=feature$' "$CALLS")" -eq 4 ]
  [[ $output != *secret-token* && $output != *"${header#* basic }"* ]]
  ! grep -q -e secret-token -e "${header#* basic }" "$GITHUB_STEP_SUMMARY"
  ! grep -q secret-token "$GH_LOG"
}

@test "committer is the app bot" {
  run "$SYNC" repo spali/tool
  [ "$status" -eq 0 ]
  [ "$(grep -c '^  committer=sync-app\[bot\] <4242+sync-app\[bot\]@users.noreply.github.com>$' "$CALLS")" -eq 2 ]
}

@test "invalid app slug skips git" {
  SYNC_APP_SLUG='x y' run "$SYNC" repo spali/tool
  [ "$status" -eq 1 ]
  ! grep -q '^sync-git.sh' "$CALLS"
}

@test "usage errors exit 2" {
  run "$SYNC"
  [ "$status" -eq 2 ]
  run "$SYNC" repo
  [ "$status" -eq 2 ]
  run "$SYNC" bogus spali/tool
  [ "$status" -eq 2 ]
}

@test "workflow skips the repo step when create failed" {
  local wf="$BATS_TEST_DIRNAME/../.github/workflows/sync.yml"
  # the step after a failed create runs with the default if (success())
  run yq -r '.jobs.sync.steps[] | select(.id == "repo") | .if // ""' "$wf"
  [ "$status" -eq 0 ]
  [[ $output != *always* && $output != *failure* && $output != *cancelled* ]]
  run yq -r '.jobs.sync.steps[].id // ""' "$wf"
  [[ $output == *$'create\n'*repo* ]]
  # all inputs reach run: steps through env only
  ! grep -E 'run:.*\$\{\{' "$wf"
}
