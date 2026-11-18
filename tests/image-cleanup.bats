#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  load helpers/gh-stub
  stub_gh
  export GH_REPO=spali/sandbox
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : >"$GITHUB_OUTPUT"
  SCRIPT="$BATS_TEST_DIRNAME/../scripts/image-cleanup.sh"
}

# releases JSON prints a release list with the given tags (isDraft false).
releases() {
  printf '%s\n' "$@" | jq -R '{tagName: .}' | jq -sc .
}

@test "keeps the image tags of existing dev and next releases" {
  releases v1.2.0-pr.7 v1.3.0-next v1.2.0 v2.0.0-rc.1 | gh_respond 'release list *' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = "tags=1.2.0-pr.7,1.3.0-next" ]
}

@test "no releases keep nothing" {
  echo '[]' | gh_respond 'release list *' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = "tags=" ]
}

@test "the script lists draft releases too (gh release list includes them)" {
  echo '[{"tagName":"v1.3.0-next","isDraft":true},{"tagName":"v1.3.0","isDraft":false}]' |
    gh_respond 'release list *' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = "tags=1.3.0-next" ]
}

@test "the tags are sorted" {
  releases v1.3.0-next v1.0.0-pr.2 | gh_respond 'release list *' -
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(cat "$GITHUB_OUTPUT")" = "tags=1.0.0-pr.2,1.3.0-next" ]
}

@test "release list failure fails the script" {
  gh_fail 'release list *' "HTTP 500"
  run "$SCRIPT"
  [ "$status" -ne 0 ]
  ! grep -q '^tags=' "$GITHUB_OUTPUT"
}

@test "requires GH_REPO" {
  GH_REPO= run --separate-stderr "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$stderr" = "error: GH_REPO is required" ]
}

# wf QUERY runs yq QUERY on the reusable workflow.
wf() {
  yq -r -o=json -I=0 "$1" "$BATS_TEST_DIRNAME/../.github/workflows/image-cleanup.yml"
}

@test "workflow permissions are minimal" {
  [ "$(wf '.permissions')" = '{"contents":"read"}' ]
  [ "$(wf '.jobs.cleanup.permissions')" = '{"contents":"read","packages":"write"}' ]
}

@test "workflow runs the script before the action" {
  [ "$(wf '.jobs.cleanup.steps[0].uses')" = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1' ]
  [ "$(wf '.jobs.cleanup.steps[0].with.repository')" = 'spali/.github' ]
  [ "$(wf '.jobs.cleanup.steps[0].with.ref')" = "\${{ job.workflow_sha || 'job-workflow-sha-unavailable' }}" ]
  [ "$(wf '.jobs.cleanup.steps[0].with.path')" = '.release-flow' ]
  [ "$(wf '.jobs.cleanup.steps[0].with."persist-credentials"')" = 'false' ]
  [ "$(wf '.jobs.cleanup.steps[1].id')" = keep ]
  [ "$(wf '.jobs.cleanup.steps[1].run')" = '.release-flow/scripts/image-cleanup.sh' ]
  [ "$(wf '.jobs.cleanup.steps[1].env.GH_REPO')" = '${{ github.repository }}' ]
  [ "$(wf '.jobs.cleanup.steps[1].env.GH_TOKEN')" = '${{ github.token }}' ]
  [ "$(wf '.jobs.cleanup.steps[2].id')" = cleanup ]
}

@test "workflow configures the cleanup action" {
  grep -q 'uses: dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f # v1.2.2$' \
    "$BATS_TEST_DIRNAME/../.github/workflows/image-cleanup.yml"
  [ "$(wf '.jobs.cleanup.steps[2].uses')" = 'dataaxiom/ghcr-cleanup-action@d52806a0dc70b430571a37da1fde39733ffd640f' ]
  run wf '.jobs.cleanup.steps[2].with'
  [ "$output" = '{"token":"${{ github.token }}","owner":"${{ github.repository_owner }}","package":"${{ inputs.package || github.event.repository.name }}","delete-tags":"*-pr.*,*-next","exclude-tags":"${{ steps.keep.outputs.tags }}","delete-untagged":true,"delete-orphaned-images":true}' ]
}

@test "workflow serializes runs per package" {
  [ "$(wf '.concurrency.group')" = 'image-cleanup-${{ github.repository }}-${{ inputs.package || github.event.repository.name }}' ]
  [ "$(wf '.concurrency."cancel-in-progress"')" = 'false' ]
}

@test "workflow package input is optional" {
  [ "$(wf '.on.workflow_call.inputs.package.required')" = 'false' ]
  [ "$(wf '.on.workflow_call.inputs.package.type')" = 'string' ]
  [ -z "$(wf '.on.workflow_call.inputs.package.default')" ]
  [ "$(wf '.on.workflow_call.inputs.package | has("default")')" = true ]
}
