# AGENTS.md: release flow guide for AI agents

You are an AI agent working on a repository that uses the shared release flow
of `spali/.github`, or on `spali/.github` itself. This file tells you what the
flow guarantees, why it is built this way, and exactly what to do in each
situation. [README.md](README.md) is the same content for humans; when they
disagree, the code in `scripts/` and `.github/workflows/` is the truth, and
you should fix the document that is wrong.

## 1. Rules you must follow

**Never**
- push to `main` directly (a ruleset blocks it anyway), force-push, or move a
  release tag (blocked);
- delete the tag of a **published** release (allowed by the ruleset, but it
  orphans the release);
- add a bypass actor to a ruleset, disable a ruleset, or change repository
  settings without the owner's explicit approval for that change;
- push a release tag `vX.Y.Z` without the owner's explicit approval;
- interpolate untrusted values (PR title, branch name, release body, comment)
  into a `run:` script with `${{ }}`; pass them through `env:`;
- check out or execute pull request code in a `pull_request_target` workflow;
- build or publish dev builds from fork branches;
- pin a GitHub Action or reusable workflow by tag or branch; always
  `@<40-char commit sha> # vX.Y.Z`;
- put community health files (`FUNDING.yml`, `CONTRIBUTING.md`,
  `SECURITY.md`, issue templates, …) into `spali/.github` (they would become
  defaults for every repository of the owner);
- make the maintenance monitor write or change anything on GitHub (only `GET`
  requests and GraphQL queries);
- print or commit the name of a private repository: not in `repos.yml`, logs,
  summaries, PRs or commits (private entries live in the private control file);
- let a check script write to stdout/stderr; check scripts write only to
  `$FINDINGS`;
- pass API JSON through argv (`jq --arg`/`--argjson`): responses can exceed the
  argument limit; use files, pipes and `--slurpfile`.

**Always**
- use a Conventional Commits title for every pull request (section 4.1);
- merge with **rebase** (squash is allowed too; the squash commit takes the PR
  title, so the title must be final before merging);
- run the tests of `spali/.github` before you change it (section 7);
- write repository content (code, docs, commits, PRs, release notes) in English;
- verify a claim against a real run or the code before you report it.

## 2. How the flow works

```
pull request (title "feat: …")
  └─ pr.yml: label job (autolabeler, on opened/reopened/edited)
  └─ pr.yml: check job  ── required check "pr / check"
merge to main
  └─ release.yml (push main): prepare ─ build ─ publish
       prepare: release-drafter updates the DRAFT release vX.Y.Z
       publish: replaces the pre-release vX.Y.Z-next
owner pushes tag vX.Y.Z on the head of main
  └─ release.yml (push tag): prepare (tag check) ─ build ─ publish
       publish: uploads files to the draft, publishes it
owner starts release.yml manually on a PR branch
  └─ prepare ─ build ─ publish: pre-release vX.Y.Z-pr.N + PR comment
pull request closed
  └─ pr.yml: cleanup job deletes all vX.Y.Z-pr.N of that PR
```

### Components

| Path in `spali/.github` | Role |
|---|---|
| `.github/release-drafter.yml` | autolabeler rules, categories, version rule, notes template |
| `.github/workflows/pr.yml` | reusable; jobs `label`, `check`, `cleanup` |
| `.github/workflows/release-prepare.yml` | reusable; job `prepare`; outputs below |
| `.github/workflows/release-publish.yml` | reusable; job `publish` |
| `scripts/lib.sh` | `die`, `out`, `need_env` |
| `scripts/check-pr.sh` | title regex, release label present, warning on several |
| `scripts/prepare.sh` | `next` / `release` / `pr`: decide kind, version, tag, sha |
| `scripts/checksums.sh` | `checksums.txt` over the build files |
| `scripts/publish.sh` | `release` / `next` / `pr`: create, replace, publish |
| `scripts/cleanup-pr.sh` | delete `*-pr.<N>` releases and tags |
| `tests/*.bats`, `tests/helpers/gh-stub.bash` | bats tests with a fake `gh` |
| `examples/caller/*.yml` | files a repository copies |

### The interface (do not change it without a new major version)

A repository's `.github/workflows/release.yml` has exactly three jobs:

1. `prepare`: `uses: spali/.github/.github/workflows/release-prepare.yml@<sha>`,
   permissions `contents: write`, `pull-requests: read`, `actions: read`,
   input `version` (exception version, only on `main`).
   Outputs: `kind` (`release`|`next`|`pr`), `version` (no `v`), `tag`
   (`v`+version), `sha` (commit to build), `pr` (number or empty),
   `draft-id` (release id or empty).
2. `build`: the repository's own job. `needs: prepare`. Checks out
   `needs.prepare.outputs.sha`, builds with `needs.prepare.outputs.version`,
   uploads every file to publish, flat, as artifact **`release-assets`**.
   Must not create `checksums.txt`, tags or releases.
3. `publish`: `uses: …/release-publish.yml@<sha>`, `needs: [prepare, build]`,
   permissions `contents: write`, `pull-requests: write`, `id-token: write`,
   `attestations: write`, `artifact-metadata: write`; passes all `prepare`
   outputs as inputs with the same names.

Triggers of `release.yml`: push to `main`; push of tags
`v[0-9]+.[0-9]+.[0-9]+`, `v[0-9]+.[0-9]+.[0-9]+-*`, excluding `!v*-next`,
`!v*-pr.*`; `workflow_dispatch` with input `version`. Concurrency group
`release-${{ github.ref }}`, cancel in progress except for tags.

`pr.yml` is called from `pull_request_target` with types `opened, reopened,
edited, synchronize, labeled, unlabeled, closed` on base `main`, permissions
`contents: write`, `pull-requests: write`.

The reusable workflows check out `spali/.github` at `job.workflow_sha` (the
commit the caller pinned) and load `release-drafter.yml` from the same commit.
So a caller always runs one consistent version of scripts and config.

## 3. Why it is built this way (decision log)

Use these when you are asked to change something: a change that breaks a
reason here needs the owner's decision.

| Decision | Reason | Rejected alternative |
|---|---|---|
| Release notes and version from **release-drafter**, grouped by **PR labels** | Language independent, PR links and authors in notes, one shared config, draft visible before release | goreleaser changelog groups from commit subjects: Go only, no PR links with rebase merges; GitHub native notes: no shared config |
| Labels derived from the **PR title**, labels **override** | Automatic in the normal case, the owner can correct by hand | Matching titles directly in categories: no manual override |
| Autolabeler only **adds** labels (`sync-labels: false`), runs only on opened/reopened/edited | Sync would remove labels set by hand | Sync on every push |
| Own `check-pr.sh` instead of release-drafter's Check PR action | Labels set with `GITHUB_TOKEN` raise no new event; Check PR reads labels from the event and would always fail right after opening | Check PR action |
| The `check` job runs even when `label` failed (and fails then) | A skipped required check counts as passed on GitHub | `if: needs.label.result != 'failure'` |
| Breaking → major, feature → minor, else patch, **no 0.x exception** | Owner's decision: one rule, one config | Separate 0.x config |
| Tag check: draft with that tag **and** tag on main's head **and** a successful release run for that head | Notes, version and binaries always describe the same commit; tagging before the main run finished would release a stale draft | Name check only |
| Publish re-checks draft and main's head | A merge during the build would publish notes that list PRs not in the binaries | Trusting prepare's result |
| Exception version via `workflow_dispatch` input on `main`, no other bypass | The draft stays the single source of the version; the tag check needs no exception | Manual draft edits (overwritten by the next merge) |
| `-next` is replaced on every merge, at most one exists | Always exactly one "what comes next" build, no clutter | One pre-release per merge |
| Dev builds only manual, only branches of the repository, comment on the PR | Reporters get a link; fork code never gets write tokens or a release | Automatic dev builds, fork builds, comments on issues |
| Only the bot's own comment is updated | Anyone can post a comment containing the marker | Marker only |
| Central publish (checksums, attestation, release) and per-repository build | A new repository only writes its build, in any language | goreleaser publishing (Go only, cannot publish snapshots) |
| Attestation skipped in private repositories | GitHub does not store attestations for private user-owned repositories | Failing the release |
| Immutable releases **off** | They lock tag names forever; `-next`/`-pr.N` reuse names | Immutable releases |
| Rulesets **without bypass**, tag ruleset blocks **update** only | Owner's decision; deleting must stay possible to retry a failed tag check | Admin bypass; blocking deletion |
| Logic in Bash scripts with bats tests and a fake `gh` | Testable without GitHub; the workflows stay thin | Inline workflow scripts |
| `job.workflow_sha` with a fallback that fails checkout | Pinned scripts; never silently run the default branch | `github.workflow_sha` (that is the caller's) |

## 4. Procedures

### 4.1 Write a pull request title

Format `<type>[(<scope>)][!]: <description>`; type one of `build chore ci docs
feat fix perf refactor revert style test`; scope lowercase `[a-z0-9._/-]+`;
`!` for any breaking change; a space after the colon; non-empty description.
Use `(deps)` only for dependency updates.

Resulting label (first match): `!` → `breaking-change`; `(deps)` →
`dependencies`; `feat` → `feature`; `fix` → `fix`; else `other`.

If you change the type of an open PR's title, also remove the label the old
title produced (`gh pr edit <n> --remove-label <old>`): labels are never
removed automatically. The check warns when several release labels are present;
the first in the order breaking-change, feature, fix, dependencies, other wins.

### 4.2 Release

1. Confirm with the owner that a release is wanted.
2. `gh run list --workflow Release --branch main --limit 1`: the latest run
   must be `completed success`. If it is running, wait. If it failed, fix that
   first (the draft may be stale).
3. Read the draft: `gh api repos/<owner>/<repo>/releases --jq '.[] | select(.draft) | {tag_name, body}'`.
   Check version and sections against the merged PRs. Fix labels if needed
   (4.4) and wait for the new run.
4. Make sure the local `main` equals `origin/main`
   (`git fetch && git rev-parse main origin/main`).
5. With the owner's approval: `git tag <draft tag> origin/main && git push origin <draft tag>`.
   Use a lightweight tag.
6. `gh run watch <run id>`; on failure use section 5.
7. Verify: `gh release view <tag> --json isDraft,isPrerelease,assets` and
   `gh release list --json tagName,isLatest --jq '.[] | select(.isLatest) | .tagName'`
   (`gh release view` has no `isLatest` field).

### 4.3 Release a version the labels do not give

`gh workflow run Release --ref main -f version=<semver without v>` (for
example `2.0.0-rc.1`, `1.0.0`). No build metadata (`+…`), no `-next` suffix,
no `-pr.`: the tag would not start the release workflow. Wait for that run to succeed; the draft now
has tag `v<version>`. Continue with 4.2 from step 3. A merge before the tag
resets the draft; repeat.

### 4.4 Correct the release notes

- Wrong section/version for a PR: change its labels (`gh pr edit <n>
  --add-label … --remove-label …`), then `gh workflow run Release --ref main`
  to recompute the draft.
- Wording: edit the PR title, then rerun as above. Text added to the draft by
  hand is lost on the next run; add it only right before tagging.

### 4.5 Dev build for a pull request

1. The PR must come from a branch of the same repository and target `main`.
   For a fork PR: ask the owner; if approved, push the commits to a branch of
   the repository and open a PR from it.
2. `gh workflow run Release --ref <branch>` (no `version` input).
3. The PR gets (or updates) a comment with the link to `v<draft version>-pr.<N>`.
   Rerun after new commits. Closing the PR deletes the build.

### 4.6 Set up the flow in a new repository (any language)

1. Copy `examples/caller/pr.yml` and `examples/caller/release-generic.yml`
   (or `release-go.yml`) into `.github/workflows/` as `pr.yml` and `release.yml`.
2. Pin: `tag=$(gh release view --repo spali/.github --json tagName --jq .tagName)`;
   `gh api repos/spali/.github/commits/$tag --jq .sha`; replace every
   `SHA # vX.Y.Z` with `<sha> # <tag>`.
3. Write the `build` job (section 2 interface). Verify locally that the build
   puts only files (no directories) into the upload path.
   Go/goreleaser: `release --snapshot --clean`, env `VERSION`, and in the
   goreleaser config `snapshot.version_template: "{{ .Env.VERSION }}"`,
   `checksum.disable: true`; upload `dist/*.tar.gz` and `dist/*.zip`.
4. Renovate config with `helpers:pinGitHubActionDigests`.
5. Labels: the five `gh label create … --force` commands in README section
   "Set up a new repository".
6. With the owner's approval: repository settings (rebase and squash only,
   delete branch on merge, squash title = PR title, Dependabot alerts, private
   vulnerability reporting, unused features off), Actions settings (read-only
   token, no PR approval) and the two rulesets from the README; list the repository's own
   required checks plus `pr / check`. Create the rulesets after the check names
   exist (after the first PR ran).
7. First release: a repository without a published release has no baseline;
   the first draft lists no PRs. Release that draft (or an exception version)
   to create the baseline.
8. Verify with a test PR: label set, `pr / check` green, after merge a draft
   and `-next` exist.

### 4.7 Change `spali/.github`

1. Branch, change, and add or change a bats test first (it must fail before
   the fix). Use `tests/helpers/gh-stub.bash`: `stub_gh`, `gh_respond '<glob>'
   <file|->`, `gh_fail`, `$GH_LOG`.
2. The stub ignores `--jq`; when a script needs data, fetch JSON and filter
   with local `jq` so the test exercises the filter.
3. Check every new `gh` flag and JSON field against the real `gh` (read-only
   commands); the stub accepts anything.
4. Run `bats tests/`, `shellcheck -x scripts/*.sh tests/helpers/*.bash`,
   `actionlint`.
5. PR with a Conventional Commits title, CI green, rebase merge.
6. For workflow changes, test end to end in a repository that pins the new
   commit (scenarios: PR label/check, merge → draft + `-next`, dev build and
   cleanup, wrong tag, tag before the main run finished, exception version,
   real release).
7. Release `spali/.github` itself (owner approval): `git tag vX.Y.Z
   origin/main && git push origin vX.Y.Z && gh release create vX.Y.Z
   --generate-notes`. Interface changes → new major version. Renovate then
   updates the pins in the repositories.

Updating release-drafter (a Renovate PR): compare the top-level keys of its
`drafter/schema.json` and `autolabeler/schema.json` at the new version with
`known_keys` in `tests/release-drafter-config.bats` and update the list.
release-drafter ignores unknown keys without a warning.

### 4.8 Emergency change of `main` without a PR

Only on the owner's explicit instruction: the owner disables the ruleset
(Settings → Rules → Rulesets), the change is made, the owner enables it again.
Do not do this yourself.

### 4.9 Handle a monitor finding

The workflow `monitor.yml` (daily, 05:17 UTC) fails while a red finding is
open. Code: `scripts/monitor*.sh`; control file: `repos.yml`.

1. Open the failed run and read the job summary. Each finding has a check id
   (section 5), a repository and a detail. Private repositories only appear as
   counts.
2. For private details run locally:
   `GH_TOKEN=$(gh auth token) MONITOR_UNMASK=1 scripts/monitor.sh`
   (add `MONITOR_PRIVATE_CONFIG=<file>` for the private control file). Never
   paste its output into a PR, commit or issue.
3. Fix the cause (table in section 5). Settings changes need the owner's
   approval (section 1).
4. If the finding is accepted, open a PR that adds `{repo, check, reason}` to
   `ignores` in `repos.yml` (public repositories only; private ones go to the
   private control file). The reason is required. Remove an ignore that is
   reported as `ignore-unused`.
5. Re-run: `gh workflow run monitor.yml`.

Never weaken or delete a check, widen a threshold, or add a "not applicable"
answer just to get green. A check that cannot run is `check-failed`, not a
pass.

## 5. Error catalog

| Message (in run log) | Cause | Action |
|---|---|---|
| `PR title must follow Conventional Commits` | title format | fix the title (4.1) |
| `PR has none of the labels …` | label missing | add the right label |
| `##[warning]PR has several release labels` | old label left | remove labels that do not apply |
| `labeling the pull request failed, re-run the jobs` | autolabeler error | `gh run rerun <id> --failed` |
| `no draft release for vA (current draft: vB)` | wrong tag | delete tag vA (it has no release), push vB after 4.2 |
| `no draft release for vA (no draft exists, …)` | nothing merged since last release | delete tag vA |
| `tag vA points to X but main is at Y` | tagged old commit or merge after tagging | delete tag, redo 4.2 |
| `the draft is not up to date for main at X` | tagged before the main run finished | wait for it, `gh run rerun <id>` (tag stays) |
| `main moved to X while building Y` | merge during the release build | delete tag, redo 4.2 |
| `release N is no longer the draft for vA` | draft published/changed meanwhile | inspect releases, report to owner |
| `several draft releases for vA (ids …)` | duplicate drafts (e.g. created by hand) | ask the owner which to delete, then `gh run rerun <id>` |
| `version must be SemVer without "v" …` | bad exception version | dispatch again with a valid version (4.3) |
| `version must not end in -next or contain -pr. …` | exception version uses a reserved suffix | choose another suffix (e.g. `-rc.1`) |
| `the version input only applies on main` | dispatch with version on a branch | run on `main` |
| `run the dev build on a pull request branch, not main` | dev build dispatched on main | use the PR branch |
| `branch X has no open pull request to main` | no PR or fork PR | open a PR from that branch |
| `run on main, on a pull request branch …` | unsupported trigger (e.g. dispatch on a tag) | use a supported trigger |
| `no release assets found in …` | build uploaded nothing | fix the build/upload path |
| `release assets must be files, … is a directory` | build uploaded a directory | upload the files flat |
| `output … must be a single line` | a value for a step output contains a newline | fix the value's source |
| `##[warning]pull request #N is closed/merged, deleted the dev build …` | PR closed during a dev build | expected, nothing to do |
| checkout of `job-workflow-sha-unavailable` fails | GitHub gave no `job.workflow_sha` | report to owner; do not unpin |
| `Unknown JSON field` from `gh` | a script uses a field `gh` does not have | fix the script, test against real `gh` |
| Draft says "could not find a previous published release" | new repository without release | 4.6 step 7 |
| Attestation step skipped with a notice | private repository | expected |

Delete a tag: `git push --delete origin vA && git tag -d vA`.

### Monitor findings (check ids)

Red unless marked info. The detail is in the job summary.

| Check id | Meaning | Action |
|---|---|---|
| `devbuild-closed-pr` | a `-pr.N` pre-release exists for a closed pull request | `gh release delete <tag> --cleanup-tag --yes` |
| `orphan-tag` | a `-next`/`-pr.N` tag without release | delete the tag (`git push --delete origin <tag>`) |
| `several-drafts` | more than one draft release | ask the owner which to delete |
| `next-stale` | `-next` pre-release older than the latest release | re-run the build on `main`, or delete it |
| `pin-behind` | a caller pins a `spali/.github` release older than a newer one (older than 7 days) | merge or fix the Renovate PR |
| `settings-merge` | merge options differ from README "Set up", step 6 | fix the setting (owner approval) |
| `settings-alerts` | Dependabot alerts are off | enable them (owner approval) |
| `settings-pvr` | private vulnerability reporting is off (public repo) | enable it (owner approval) |
| `settings-actions` | default workflow permissions are not read-only, or Actions may approve PRs | fix the setting (owner approval) |
| `ruleset-main` | the `main` ruleset is missing or differs (README step 7); skipped on private repositories under the Free plan | restore it (owner approval) |
| `ruleset-tags` | the tag ruleset is missing or differs; skipped on private repositories under the Free plan | restore it (owner approval) |
| `main-red` | the latest run of a workflow on the default branch failed | fix the cause, re-run |
| `renovate-stale` | a Renovate PR is open for more than 7 days | review and merge, or close it |
| `workflow-disabled` | a workflow is disabled (inactivity) | enable it (`gh workflow enable`), push a commit if needed |
| `dependabot-alert` | open alert; red for critical/high, info for low/medium | update or dismiss with a reason |
| `code-scanning-alert` | open alert; red for critical/high, info for low/medium | fix or dismiss with a reason |
| `self-stale` | no commit on `spali/.github` `main` for 50 days or more | commit something useful before GitHub disables the schedule at 60 days |
| `fork-behind` (info) | a fork is behind its upstream | sync when you care |
| `fork-sync-stale` | a fork with its own sync workflow misses upstream commits beyond `sync_interval_hours` + 24 h | check the sync workflow |
| `fork-workflows-active` (info) | a fork runs its own workflows | disable them if unwanted |
| `fork-delete-candidate` (info) | no own commits and no open upstream PR | consider deleting the fork |
| `mirror-behind` | the mirror target lacks refs of its source beyond `interval_hours` + 24 h | check the mirror job in the mirror repository |
| `list-none` (info) | a repository is in no list | add it to a list |
| `list-contradiction` (info) | lists contradict each other or the archive state | fix the lists |
| `list-mirror-missing` (info) | a mirror target is not in the mirrors list | add it to the list |
| `list-archived` (info) | an archived repository is not in the archive list | move it |
| `adoption` (info) | a repository does not use the release flow | adopt it (4.6) or ignore |
| `check-failed` | a check could not run (API error, rate limit, bad response, empty inventory) | read the detail, fix access or the script; never ignore |
| `config-invalid` | `repos.yml` or the private control file is invalid, or names an unknown list/check | fix the file |
| `ignore-unused` (info) | an ignore matched no finding | remove it, or fix the typo |
| `public-config-private-repo` | `repos.yml` names a private repository | remove it, move it to the private control file; the name is already public in the history, tell the owner |

## 6. Facts that are easy to get wrong

- A tag push runs the workflow files **of the tagged commit**; a fix in
  `spali/.github` only applies to releases of commits that pin it.
- In a reusable workflow, `github.workflow_ref`/`GITHUB_WORKFLOW_REF` and
  `github.workflow_sha` describe the **caller**; `job.workflow_sha` /
  `job.workflow_ref` describe the called workflow. actionlint does not know the
  `job.workflow_*` properties yet (ignored in `.github/actionlint.yaml`).
- Events caused by `GITHUB_TOKEN` (labels, tags created by API) start no new
  workflow runs.
- Draft releases are not returned by the "release by tag" API; list releases.
- `gh release list --json` has no id field; use `gh api repos/<r>/releases --paginate`
  and join pages with `jq -s 'add'`.
- release-drafter ignores pre-releases as the base version (`-next`, `-pr.N`,
  `-rc.1`), so after an rc the next draft is computed from the last full release.
- `GITHUB_*` environment variables cannot be overridden in `env:`.
- A required status check whose job was skipped counts as passed.
- Monitor, Free plan: rulesets on private repositories answer 403 `Upgrade to
  GitHub Pro or make this repository public …` (not applicable). `vulnerability-alerts`
  answers 404 `Vulnerability alerts are disabled.` when the setting is off (a
  finding, not n/a). `private-vulnerability-reporting` answers a generic 404 on
  private repositories: decide by `private` from the inventory, do not call it.
  Not applicable are only the tested answers in `scripts/monitor-lib.sh`
  (code scanning `no analysis found` or `not enabled`, `Dependabot alerts are
  disabled for this repository`, the ruleset message above).
- `gh` stderr can contain extra lines around the error (e.g. a missing scope
  hint): the message is the line ending in `(HTTP nnn)`; n/a patterns match the
  whole stderr.
- Lists (GraphQL `user.lists`) contain private repositories for the owner's
  token: treat them like the inventory and mask them.
- A fork's own sync workflow is disabled after 60 days without repository
  activity like any scheduled workflow of a public repository
  (`disabled_inactivity`); the monitor reports it as `workflow-disabled`.
- `git ls-remote` on mirror targets only compares the refs of the source; extra
  refs in the target are fine.

## 7. Verify `spali/.github` locally

```sh
bats tests/                                        # all tests pass
shellcheck -x scripts/*.sh tests/helpers/*.bash    # no output
actionlint                                         # no output
actionlint examples/caller/*.yml                   # no output
```

CI runs the same checks as the required checks `shellcheck`, `bats`,
`actionlint`.

## 8. Known limitations (accepted for now)

- A dev build can still be left behind if its pull request is closed in the
  moment between the state check and the end of the publish job (delete it by
  hand: `gh release delete <tag> --cleanup-tag --yes`).
- A tag left over without a release is only cleaned up for `-next` and
  `-pr.N`; a leftover release tag `vX.Y.Z` fails the tag check as usual.
