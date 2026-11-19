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
- make the maintenance monitor write anything on GitHub except its overview
  issue, its one monitor comment on that issue and the label
  `maintenance-monitor` in the calling repository, with
  that repository's `GITHUB_TOKEN`; everything else it does is `GET` requests
  and GraphQL queries with the read-only app token;
- make the sync (`sync.yml`) write to a repository that is neither an own
  fork (not archived, not pinned) nor listed under `forks:` of the control
  file, take a target URL from anything but the entry, or pass a token in an argument, URL, log or artifact (git gets it
  only through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`);
- make the profile cards (`profile-cards.yml`) write anything but the card
  paths of its `cards` input to its one target repository, force-push, or use
  the write app token beyond contents write on that repository (the sync's
  write app is reused there, scoped per run);
- put the name of a private repository into `spali/.github`: not in code, docs,
  tests, fixtures, PRs or commits (say "the private control repository"; the
  monitor's control file lives there);
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
| `.github/workflows/image-cleanup.yml` | reusable; job `cleanup`; deletes `*-pr.*`/`*-next` image tags whose release no longer exists, plus untagged and orphaned images, of a ghcr.io package; run by repositories with an image |
| `.github/workflows/release-prepare.yml` | reusable; job `prepare`; outputs below |
| `.github/workflows/release-publish.yml` | reusable; job `publish` |
| `.github/workflows/monitor.yml` | reusable; job `monitor`; run by the private control repository |
| `.github/workflows/monitor-config.yml` | reusable; job `config`; validates the control file |
| `.github/workflows/sync.yml` | reusable; jobs `plan` (Repositories) and `sync` (one per synced repository); run by the private control repository |
| `.github/workflows/profile-cards.yml` | reusable; jobs `card` (one per card) and `commit`; run by the private control repository |
| `scripts/profile-cards.sh` | `check` (validates the card list), `commit` (writes the cards to the profile repository) |
| `scripts/lib.sh` | `die`, `out`, `need_env` |
| `scripts/runner-online.sh` | fails unless a self-hosted runner for `monitor.runs-on` is online (monitor Inventory, sync plan) |
| `scripts/check-pr.sh` | title regex, release label present, warning on several |
| `scripts/prepare.sh` | `next` / `release` / `pr`: decide kind, version, tag, sha |
| `scripts/checksums.sh` | `checksums.txt` over the build files |
| `scripts/publish.sh` | `release` / `next` / `pr`: create, replace, publish |
| `scripts/cleanup-pr.sh` | delete `*-pr.<N>` releases and tags |
| `scripts/image-cleanup.sh` | `tags=` output: tags of the existing `v*-pr.*` and `v*-next` releases without `v`, kept from deletion by the image cleanup |
| `scripts/monitor*.sh` | maintenance monitor: `monitor.sh` runs `monitor-repos.sh` (inventory), the check scripts, `monitor-report.sh` and `monitor-issue.sh` (issue body plus one monitor comment, split at the report line `<!-- maintenance-monitor:details -->`); `monitor.sh PHASE` runs one of them (shared dir `MONITOR_WORK`); `monitor.sh matrix` prints the jobs per check group for the workflow matrix (`monitor.jobs`, `monitor.runs-on` of the control file), `MONITOR_REPO` limits a check phase to one repository (empty: all) |
| `scripts/sync.sh` | fork and mirror sync: `matrix` (repositories, runner), `exists`, `create` (`sync-create.sh`), `repo` (kind check, `sync-settings.sh`, contribution branches, `sync-git.sh plan` and `push`); `scripts/forks-lib.sh` normalizes the `forks:` entries and the own forks without one |
| `docs/monitor-checks.md` | explanation of each monitor check, linked from the overview issue (one `## <check id>` section each, tested) |
| `tests/*.bats`, `tests/helpers/gh-stub.bash` | bats tests with a fake `gh` |
| `examples/caller/*.yml` | files a repository copies |

### The interface (do not change it without a new major version)

A repository's `.github/workflows/release.yml` has exactly three jobs (repositories
with a container image add a fourth job `image-cleanup`, see the image-cleanup
paragraph below):

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

A repository without files to release (e.g. a library) has no `build` job:
`publish` has `needs: prepare` and input `assets: false` (default `true`).
Its releases carry only the notes and the tag; no `checksums.txt`, no
attestation (`examples/caller/release-library.yml`).

Triggers of `release.yml`: push to `main`; push of tags
`v[0-9]+.[0-9]+.[0-9]+`, `v[0-9]+.[0-9]+.[0-9]+-*`, excluding `!v*-next`,
`!v*-pr.*`; `workflow_dispatch` with input `version`. Concurrency group
`release-${{ github.ref }}`, cancel in progress except for tags.

`pr.yml` is called from `pull_request_target` with types `opened, reopened,
edited, synchronize, labeled, unlabeled, closed` on base `main`, permissions
`contents: write`, `pull-requests: write`.

`image-cleanup.yml` (job `cleanup`) is called as a job after `publish` in
`release.yml` (`needs: publish`) and after `pr` in `pr.yml` (`needs: pr`,
`if: github.event.action == 'closed'`): input `package` (default: the
repository name), caller permissions `contents: read`, `packages: write`. It
deletes image tags `*-pr.*` and `*-next` that have no release any more,
untagged and orphaned images; release tags are never touched. The cleanup is
eventual: an image is deleted by the next cleanup run (next merge, release or
PR close) once it is older than 2 hours, and after a release the `next` tag
keeps pointing at the last next image until the next merge. Repositories
without an image do not call it.

The reusable monitor workflows are part of the interface too.
`monitor.yml` (job `monitor`): inputs `app-client-id` (required) and `config`
(default `repos.yml`), secret `app-key` (required), caller permissions
`contents: read`, `issues: write`; it has no concurrency group and no
schedule, the caller owns both. `monitor-config.yml` (job `config`): input
`config`, permission `contents: read`. `sync.yml` (jobs `plan`, `sync`):
inputs `app-client-id` (required), `config` (default `repos.yml`), `repo`
and `branch` (default empty), secret `app-key` (required), caller permission
`contents: read`; the caller owns the schedule and the concurrency group
`sync`. `profile-cards.yml` (jobs `card`, `commit`): inputs `app-client-id`
and `cards` (required), `repository` and `branch` (default empty), secrets
`token` and `app-key` (required), caller permission `contents: read`; the
caller owns the schedule and the concurrency group `profile-cards`.
Renaming or removing an input or secret needs a new major version.

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
| The monitor runs in a **private control repository** that calls reusable workflows; `spali/.github` only provides code | Private repository names can appear in logs, summary and issue without masking; the control file stays private | Cron in this public repository with masking and a private file merged in |
| The overview issue is written with the caller's `GITHUB_TOKEN`, everything else read with the read-only app token | The app can never write; the only write is scoped to one repository | An app with `issues: write` on all repositories |
| The overview issue holds summary, TODO and overview; Red, Info, Forks and mirrors, Clean and Not checked go into one fixed monitor comment (the oldest comment starting with `<!-- maintenance-monitor:details -->`, edited in place) | The full report outgrew the 64 KB issue body; one edited comment adds no notifications or timeline entries, the anchor links still work on the same page | Everything in the body (cut); a new comment per run; a dynamic number of comments |
| The monitor runs as **matrix jobs**, the control file chooses `monitor.jobs` (`per-group` default, `per-repo`) and `monitor.runs-on` | One workflow and one set of scripts for both: a job per repository only changes the matrix (`MONITOR_REPO`), so the variants cannot drift; `per-repo` costs about 55 billed minutes per run on hosted runners, so it is opt-in (own runner) | Two workflows (steps in one job vs. matrix); one job with steps only |

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
   (or `release-go.yml`, or `release-library.yml` when nothing is built) into
   `.github/workflows/` as `pr.yml` and `release.yml`.
2. Pin: `tag=$(gh release view --repo spali/.github --json tagName --jq .tagName)`;
   `gh api repos/spali/.github/commits/$tag --jq .sha`; replace every
   `SHA # vX.Y.Z` with `<sha> # <tag>`.
3. Write the `build` job (section 2 interface; none with `release-library.yml`). Verify locally that the build
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
4. Run the checks of section 7 (bats, shellcheck, actionlint).
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

The workflow `monitor.yml` runs daily (05:17 UTC) from the private control
repository, which also holds the control file `repos.yml`. The run fails while
a red finding is open. Code: `scripts/monitor*.sh` in `spali/.github`.

1. Open the failed run in the control repository, or the issue labelled
   `maintenance-monitor` there (updated on every run). Each finding has a
   check id (section 5), a repository and a detail. The red job of the run
   job names the check group (and the repository with `monitor.jobs:
   per-repo`); its log groups the findings per repository.
2. To reproduce locally (read-only, no issue is written):
   `GH_TOKEN=$(gh auth token) MONITOR_CONFIG=<path to repos.yml> scripts/monitor.sh`.
   Setting `MONITOR_ISSUE_REPO` would write the issue; do not set it locally.
   One phase with its step log: set `MONITOR_WORK` to an empty dir, run
   `scripts/monitor.sh config`, then `inventory`, then the phase (e.g. `forks`).
3. Fix the cause (table in section 5). Settings changes need the owner's
   approval (section 1).
4. If the finding is accepted, open a PR in the control repository that adds
   `{repo, check, reason}` to `ignores` in `repos.yml` (`item` for one
   pull request or issue of `unanswered` or `stale-branch`). The reason is
   required. Remove an ignore that is reported as `ignore-unused`.
5. Re-run: `gh workflow run monitor.yml` in the control repository.

Billing findings (`billing-minutes`, `billing-storage`, `billing`) have no
repository: they concern the whole account and come from the phase `billing`
in the Lists job. It reads with the optional secret `account-token` of
`monitor.yml` (fine-grained token of the owner, account permission Plan:
read), passed to the script as `BILLING_TOKEN`; without it `billing` is not
checked. Locally: `BILLING_TOKEN=<that token>` with the phases `config`,
`inventory`, `billing` (the API answers only for the owner's own token). A
`check-failed` "billing: …" with HTTP 401/403 means the token expired or lacks
Plan: read: renew it in the control repository.

Never weaken or delete a check, widen a threshold, or add a "not applicable"
answer just to get green. A check that cannot run is `check-failed`, not a
pass.

### 4.10 Change the monitor jobs or runner

- Switching `monitor.jobs` or `monitor.runs-on` is a change of `repos.yml` in
  the control repository (PR there). Nothing changes in `spali/.github`.
- `per-repo` on GitHub-hosted runners costs about one billed minute per job
  (about 55 per run): only with the owner's approval.
- A new check group needs, in the same PR: the script, its name in `CHECKS`
  and the selection in `groups` (`MONITOR_GROUPS_JQ` in
  `scripts/monitor-lib.sh`, shared by the workflow matrix and the overview
  of the issue; a new overview column in `REPORT_JQ`), a matrix job in
  `.github/workflows/monitor.yml` (copy one, with its own `if` and
  `matrix.repo`), the job in Report's `needs`, and the group in the test
  "matrix selects the same repositories as the check scripts"
  (`tests/monitor-matrix.bats`). That test fails if the matrix and a script
  select different repositories; never change it to pass, fix the selection.
- A new check id needs its entry in `MONITOR_TODO` (`scripts/monitor-lib.sh`:
  category of its info findings, TODO title, one sentence, areas); tested.
  `"todo": false` keeps a pure status line (like `billing`) out of the TODO;
  it is still listed under Info.
- Account-level checks (`lists`, `billing`) are phases in the Lists job, one
  step each (`monitor.sh <phase>`), not matrix jobs: they see the whole
  inventory, and `MONITOR_REPO` with them is a usage error (exit 2). A new one
  needs its name in `PHASES` and `CHECKS` of `scripts/monitor.sh`, the same
  usage error, and a step in the Lists job. A token it needs beyond the app
  token is an optional secret of `monitor.yml` (as `account-token`), passed to
  that step only; never put it into the job env.
- Never add a second workflow for another job layout.

### 4.11 Add, change or pin a fork or mirror

The workflow `sync.yml` runs daily (04:47 UTC) and on every change of
`repos.yml` from the private control repository. Code: `scripts/sync*.sh`.

1. Every own fork that is not archived is synced without an entry (default
   branch, rebased onto upstream when it has own commits, and tags; default
   settings). Add or change an entry under `forks:` of `repos.yml` with a PR
   in the control repository only for exceptions (schema: README "Fork and
   mirror sync"): a mirror outside GitHub (`upstream`), more branches
   (`branches:`, `follow:`), `settings:`, `tags: false`, or `pinned: true`
   to stop syncing it. The `Config` check validates it. Turning a setting on
   (`settings:`) needs the owner's approval.
2. After the merge the sync runs. A new fork with an entry and `upstream` is
   created by it; a new mirror fails with `create <repo> by hand: gh repo
   create <repo> --public|--private`: the owner runs that command once, then
   re-run the sync.
3. A rebase conflict (`rebase onto <x> failed (conflict)`, also of the
   default branch with own commits) pushes nothing for that repository.
   Rebase the branch by hand (fetch upstream, `git rebase`, resolve), push
   it, then run `gh workflow run sync.yml -f repo=<repo>` in the control
   repository; or ask the owner to pin the fork.
4. Rebase a `rebase: manual` branch: `gh workflow run sync.yml -f repo=<repo>
   -f branch=<branch>` (`-f branch='*'` for all manual branches of the repo).
5. `RESTORE FAILED for …`: the push landed but its verification failed and the
   restore did not succeed. Never push over it: the old tips are in
   `refs/backup/<branch>` of the repository; compare and restore by hand with
   the owner.
6. A lease failure (`push rejected, target unchanged`) means somebody pushed to
   the repository during the run: nothing was overwritten, re-run.
7. `error: <n> refs kept with own commits: <refs>`: the sync pushed everything
   else but never overwrites a followed branch or a tag with own commits
   (skipped as `undeclared` or `unique commits`), and the run stays
   red until it is resolved. Ask the owner: declare the branch under
   `branches:` (step 1), or delete it or reset it to upstream by hand.
8. `error: <ref>: upstream rewritten (…)` or `upstream moved tag (…)`:
   upstream rewrote the branch or moved the tag since the last sync (record
   `refs/sync/upstream/<branch>`); the sync pushed everything else and the
   run stays red. Check upstream with the owner, then
   `gh workflow run sync.yml -f repo=<repo> -f accept=<branch|tags/name|*>`;
   the old tip is kept in `refs/backup/<branch>` or `refs/backup-tags/<tag>`
   (one backup per ref, replaced by each later accept or rebase). A declared
   branch (and a default branch with own commits) keeps only its own commits
   after the record; a followed branch with own commits on top is refused (`accept refused`, the error
   line has no accept hint then): declare it (step 1) or reset it by hand.
   A `rebase: manual` branch needs only `accept`. Changing the `onto` of a
   declared branch, or declaring a previously followed branch, also shows
   as `upstream rewritten`; accept then moves only the own commits. Records
   of branches no longer synced stay; delete `refs/sync/upstream/<branch>`
   by hand if a later branch name conflicts (e.g. `foo` and `foo/bar`).
9. Right after the sync created a fork, the first fetch may fail once (GitHub
   is still copying the repository); the next run recovers, or re-run.
10. Forks and mirrors are synced the same way; they differ only in how the
   repository is created. The sync fetches only the upstream default branch,
   the `onto` branches, the branches matching `follow:` (whole-name regular
   expressions, jq syntax) and all tags. To sync more upstream branches
   (e.g. release branches), add a pattern to `follow:`; all branches:
   `follow: ['.*']`. `tags: false` leaves the tags alone (neither fetched
   nor touched). The key `refs` no longer exists (`unknown key refs`).
11. A renamed upstream default branch (e.g. `master` to `main`) is synced
   into the branch of upstream's name and, after the push, made the
   default branch (log and summary: `default branch: master -> main`); the
   old branch is not deleted. It stays the default (and gets upstream's
   default as before) when it is declared or has commits beyond the
   upstream default; delete or declare it with the owner first. A failed
   change (`default branch failed`) fails the run; re-run after the cause
   (e.g. missing Administration write) is fixed.

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

Red unless marked info. The detail is in the job summary, the monitor comment of the overview
issue and the log of the failed step. Explanations for humans:
`docs/monitor-checks.md` (keep it in sync with this table).

| Check id | Meaning | Action |
|---|---|---|
| `devbuild-closed-pr` | a `-pr.N` pre-release exists for a closed pull request | `gh release delete <tag> --cleanup-tag --yes` |
| `orphan-tag` | a `-next`/`-pr.N` tag without release | delete the tag (`git push --delete origin <tag>`) |
| `several-drafts` | more than one draft release | ask the owner which to delete |
| `next-stale` | `-next` pre-release published before the latest release | re-run the build on `main`, or delete it |
| `pin-behind` | a caller (including the control repository's monitor pin) pins a `spali/.github` release older than a newer one (older than 7 days) | merge or fix the Renovate PR |
| `settings-merge` | merge options differ from README "Set up", step 6 (all own repositories that are neither forks nor under `forks:`) | fix the setting (owner approval) |
| `settings-alerts` | Dependabot alerts are off | enable them (owner approval) |
| `settings-pvr` | private vulnerability reporting is off (public repo) | enable it (owner approval) |
| `settings-actions` | default workflow permissions are not read-only, or Actions may approve PRs | fix the setting (owner approval) |
| `settings-fork-approval` | fork pull request workflows of outside contributors run without approval (public repository with Actions on; all owned repositories) | require approval for all external contributors (owner approval) |
| `funding` (info) | the sponsor button does not match: off in an own repository with a `FUNDING.yml`, or on in a fork or mirror (its `FUNDING.yml` is the upstream's) | turn *Sponsorships* on or off (owner approval) |
| `ruleset-main` | the `main` ruleset is missing or differs (README step 7); not checked on private repositories under the Free plan | restore it (owner approval) |
| `ruleset-tags` | the tag ruleset is missing or differs; not checked on private repositories under the Free plan | restore it (owner approval) |
| `main-red` | the latest run of a workflow on the default branch failed (the monitor's own workflow in the control repository is not checked) | fix the cause, re-run |
| `renovate-stale` | a Renovate PR is open for more than 7 days | review and merge, or close it |
| `workflow-disabled` | a workflow is disabled (inactivity) | enable it (`gh workflow enable`), push a commit if needed |
| `dependabot-alert` | open alert; red for critical/high, info for low/medium | update or dismiss with a reason |
| `code-scanning-alert` | open alert; red for critical/high, info for low/medium | fix or dismiss with a reason |
| `unanswered` | in an open pull request or issue the newest human post (opening, comment, review, review comment; bots ignored, items opened by a bot skipped) is not by the owner and older than `unanswered.days` days (default 7); the finding carries the number as `item` | answer it or close it, or ignore the item (`item: <number>`) with a reason; the ignore stays used while the item is open and becomes `ignore-unused` once it is closed: then remove it |
| `stale-branch` | a branch (not the default branch) was the head of a merged pull request from the repository (own repositories: into the repository; forks, pinned ones too: into the upstream) and has no open one; red when it still points at the merged head, info when it has commits after it; the newest merge counts; the finding carries the pull request number as `item` | delete the branch, or ignore the item (`item: <number>`) with a reason |
| `fork-delete-candidate` (info) | a fork (pinned ones too) has no own commits on the default branch, no open upstream PR from the fork, and every fork branch also exists upstream or was the head of a closed or merged upstream PR from the fork; not when it is in a list of `lists.external` (kept to follow the upstream) | delete the fork, archive or pin it to keep the state you reference, or put it in a list of `lists.external` to keep following the upstream |
| `list-none` (info) | a repository (archived ones too) is in no list, or a fork or `forks:` entry in none of the forks lists (`lists.forks`) | add it to a list |
| `list-contradiction` (info) | a repository is in both lists of an exclusive pair | fix the lists |
| `list-external-own` (info) | an own repository that is no fork and no `forks:` entry (archived ones too) is in a list of `lists.external` (lists for repositories of others); a fork or mirror there is fine, it follows the upstream | move own work to the stack list |
| `fork-missing` | a repository under `forks:` does not exist (no other check runs for it) | let the sync create it (a mirror: run the `gh repo create` command from the failed sync job once, 4.11), or fix the entry |
| `fork-settings` | a synced fork's or mirror's issues/pull requests/wiki/discussions/projects/Actions differ from its `settings:` (default all off), or the repository is archived but has an entry that is not pinned (then the only finding) | correct the setting (owner approval) or the `settings:` entry; for an archived one remove or pin the entry |
| `fork-behind` | a synced fork's or mirror's default branch, `rebase: auto` branch or followed branch (`follow:`) misses upstream commits older than 48 h (a mirror branch lacking the upstream commit: `differs from upstream` and no push for 48 h), or a declared or followed branch is missing in the target; tags (unless `tags: false`) differ from upstream and no push for 48 h; heads of open upstream PRs from the fork excepted; a ref the sync stopped on an upstream rewrite may also show (once the last push is older than 48 h; `sync-failed` is the reliable signal) | read the sync run (a stopped ref: accept it, 4.11) |
| `rebase-pending` (info) | a `rebase: manual` branch is behind its `onto` upstream | `gh workflow run sync.yml -f repo=<repo> -f branch=<branch>` in the control repository (4.11) |
| `sync-failed` | per synced repository (own forks not archived and `forks:` entries, without the pinned ones), its newest job `Sync · <repo>` with a result (cancelled, skipped or no conclusion passed over) of `sync.yml` on `main` of the control repository did not succeed (`failure`, `timed_out`, …); without repository: a non-repository job did not succeed in the newest run where it has a result (same rule); more jobs than one page is check-failed (checked in Lists when a repository is synced; not checked in a local run), also on a rebase conflict and when it stopped a ref on an upstream rewrite (`upstream rewritten`, `upstream moved tag`) | read the sync log; a stopped ref: check upstream, then accept it (4.11) |
| `contribution-stale` (info) | an open upstream pull request from a fork (pinned ones too) is older than 90 days | follow up or close it |
| `adoption` (info) | a repository (not a fork, not under `forks:`) does not use the release flow (one finding per repository) | adopt it (4.6) or ignore |
| `billing-minutes` | private repositories (and repositories not in the inventory) used `billing.minutes.threshold` % (default 75) of the included Actions minutes (price-weighted, in Linux minutes; included from `billing:` or the plan), or from day 7 (UTC) the month-end projection reaches 100 % (account level) | move hosted jobs of the top repositories (`billing` line) to the self-hosted runner or run them less often; raise the threshold if expected |
| `billing-storage` | the same for the average Actions storage (GB-hours; projection at yesterday's level) against `billing.storage` | delete old artifacts and caches or shorten their retention; raise the threshold if expected |
| `billing` (info) | one status line per run: used and projected share of minutes and storage, top repositories; not a TODO entry; not checked without an account token | none |
| `check-failed` | a check could not run (API error, rate limit, bad response, empty inventory) | read the detail, fix access or the script; never ignore |
| `config-invalid` | the control file is missing or invalid, or names an unknown list/check | fix the file |
| `ignore-unused` (info) | an ignore matched no finding | remove it, or fix the typo |

## 6. Facts that are easy to get wrong

- A tag push runs the workflow files **of the tagged commit**; a fix in
  `spali/.github` only applies to releases of commits that pin it.
- In a reusable workflow, `github.workflow_ref`/`GITHUB_WORKFLOW_REF` and
  `github.workflow_sha` describe the **caller**; `job.workflow_sha` /
  `job.workflow_ref` describe the called workflow. actionlint does not know the
  `job.workflow_*` properties yet (ignored in `.github/actionlint.yaml`).
- Deleting ghcr.io package versions with `GITHUB_TOKEN` requires the repository
  to have the Admin role under the package's Manage Actions access (the action
  needs it); otherwise the `image-cleanup` job fails with 403.
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
  `repos/R/actions/permissions/fork-pr-contributor-approval` answers 422 `Fork PR
  approval is not allowed for private repositories`: decide by `private`, do not
  call it.
  Not applicable are only the tested answers in `scripts/monitor-lib.sh`
  (code scanning `no analysis found` or `not enabled`, `Dependabot alerts are
  disabled for this repository`, the ruleset message above).
- `gh` stderr can contain extra lines around the error (e.g. a missing scope
  hint): the message is the line ending in `(HTTP nnn)`; n/a patterns match the
  whole stderr.
- Lists (GraphQL `user.lists`) contain private repositories for the owner's
  token (`LISTS_TOKEN`, default `GH_TOKEN`, is used for that call only).
- `main-red` skips the monitor's own workflow in the calling repository, found
  by `GITHUB_WORKFLOW_REF` (in a reusable workflow that is the caller's
  `owner/repo/.github/workflows/file.yml@ref`): its previous run fails after
  every red finding and would otherwise keep the control repository red.
  Without the variable (local runs) nothing is skipped.
- A repository that only calls `monitor.yml` / `monitor-config.yml` /
  `sync.yml` / `profile-cards.yml` (`MAINTENANCE_WORKFLOWS` in `monitor-repos.sh`) is not
  `central` (not a release-flow repository): no release checks and, because it
  has pins, no `adoption` finding, but `pin-behind` applies.
- A scheduled workflow of a public repository is disabled after 60 days without
  repository activity (`disabled_inactivity`); the monitor reports it as
  `workflow-disabled` for own repositories.
- The REST repository (`GET repos/{owner}/{repo}`) answers `null` for the merge
  settings (`allow_merge_commit`, …) to an app token without write access;
  `settings-merge` reads them with GraphQL (`mergeCommitAllowed`, …), which
  works with read access.
- Monitor jobs: `per-group` is a matrix with the single entry `""`
  (`MONITOR_REPO` empty = all repositories of the group), so job names use
  `matrix.repo || 'all repositories'`. An empty group gives `[]` and the job is
  skipped by its `if` (an empty matrix would be an error). Findings travel as
  artifacts `findings-<job>-<index>` (findings, and in the forks jobs the
  fork kinds `fork-kinds.jsonl`, in the lists job the lists `lists.json`, both
  for the report section 🍴 Forks and mirrors)
  plus `monitor-base` (config, inventory, archived);
  Report concatenates them. Inventory cannot use `monitor.runs-on`: the value
  comes from its own output.
- Self-hosted `monitor.runs-on`: Inventory (monitor) and Repositories
  (sync) run `scripts/runner-online.sh` on GitHub-hosted runners and fail when
  no runner of the control repository with all labels is online. GitHub does
  not notify about queued jobs, and Report itself would wait for the runner,
  so the failure of that first job is the only alert. `ready` of Inventory is
  set only after the check. It looks again for up to 2 minutes
  (`RUNNER_ONLINE_WAIT`, `RUNNER_ONLINE_INTERVAL`): ephemeral runners
  deregister after each job, and right after a sync run all of them were
  offline or not listed at once (E2E 2026-11-18). No fallback to hosted runners (owner's decision,
  2026-11-18).
- `git ls-remote` on mirror targets only compares the refs of the source; extra
  refs in the target are fine (`fork-behind`).
- Sync tokens (tested 2026-11-16): an installation token scoped
  (`repositories:`) to a repository that does not exist cannot be created
  (422). Forking needs an installation token that is not scoped to
  repositories (one scoped to another repository gets 403) and that has all
  app permissions: a down-scoped token (any subset of permissions) gets 403
  "You can't fork this repository at this time.". So `sync.yml` checks
  existence with an unscoped metadata-only token, creates a missing fork with
  an unscoped token without `permission-*` inputs (all app permissions), and
  syncs with a token scoped to the repository. `POST /user/repos` is refused for app tokens:
  mirrors (no fork parent) must be created by hand.
- `has_pull_requests` is settable with `PATCH repos/{owner}/{repo}`, like the
  other `has_*` settings.
- GitHub accepts pushes to `refs/backup/*` (outside heads and tags); the sync
  keeps the old tip of a rebased branch there (of an accepted moved tag in
  `refs/backup-tags/*`, its records in `refs/sync/upstream/*`).
- The sync matches the dispatch input `repo` case-insensitively against its
  list of synced repositories (spelled as on GitHub when the fork is listed
  there, else as in `forks:`).

## 7. Verify `spali/.github` locally

```sh
bats --jobs "$(nproc)" --no-parallelize-within-files tests/  # all tests pass
shellcheck -x scripts/*.sh tests/helpers/*.bash    # no output
actionlint                                         # no output
actionlint examples/caller/*.yml                   # no output
```

CI runs the same checks as the required checks `shellcheck`, `bats`,
`actionlint`. `--jobs` needs GNU `parallel`; it runs the test files in
parallel, the tests of one file in order (in parallel within a file, bats is
slower with few jobs). Every file must therefore stand alone: no state shared
with other files, temporary files only in `$BATS_TEST_TMPDIR`.

## 8. Known limitations (accepted for now)

- A dev build can still be left behind if its pull request is closed in the
  moment between the state check and the end of the publish job (delete it by
  hand: `gh release delete <tag> --cleanup-tag --yes`).
- A tag left over without a release is only cleaned up for `-next` and
  `-pr.N`; a leftover release tag `vX.Y.Z` fails the tag check as usual.
- `pin-behind` does not run during the first 7 days after a new
  `spali/.github` release.
