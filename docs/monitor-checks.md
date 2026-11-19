# Maintenance monitor checks

What each check of the [maintenance monitor](../README.md#maintenance-monitor)
looks at, why a finding matters and how to fix it. The overview issue links
each check title here.

**Levels:** 🔴 red is something to fix (the run fails while one is open),
🔵 info is a hint, ⚪ not checked means the check did not run in that
repository because it does not apply or the feature is not available there
(the repository was checked otherwise); it is only listed with its reason.
To accept a finding, add `{repo, check, reason}` to `ignores` in the control
file `repos.yml`. Settings and rulesets change only with the owner's approval.

**TODO in the overview issue:** red findings are 🔴 Fix now. Info findings
are 🤔 Decide (a choice only you can make: `adoption`, `branch-undeclared`,
`contribution-stale`, `fork-delete-candidate`, `list-contradiction`,
`rebase-pending`, `stale-branch`, `unmanaged`) or 🧹 Clean up (all other
checks). The title and sentence of each entry are in `MONITOR_TODO` in
`scripts/monitor-lib.sh`.

Groups: [Release flow](#release-flow) · [Settings](#settings) ·
[Health](#health) · [Forks](#forks) · [Lists](#lists) ·
[Managed repositories](#managed-repositories) · [Billing](#billing) ·
[Monitor](#monitor)

# Release flow

Repositories that use the shared release flow of `spali/.github`.

## devbuild-closed-pr

🔴 A dev build (`vX.Y.Z-pr.N` pre-release) exists for a pull request that is
no longer open. Dev builds are deleted when their pull request closes; one
that is left was missed by that cleanup.

**Fix:** `gh release delete <tag> --cleanup-tag --yes` in that repository.

## orphan-tag

🔴 A `-next` or `-pr.N` tag has no release. These tags only exist together
with their pre-release; a bare tag is left over from a failed or cancelled
build.

**Fix:** `git push --delete origin <tag>`.

## several-drafts

🔴 The repository has more than one draft release. The release flow expects
exactly one draft (the next version) and refuses to release while there are
several.

**Fix:** ask the owner which draft to keep, delete the others.

## next-stale

🔴 A `-next` pre-release is older than the latest release. It should have
been deleted when that release was published.

**Fix:** re-run the Release workflow on `main`, or delete the pre-release.

## pin-behind

🔴 A workflow pins a release of `spali/.github` while a newer one has been
out for more than 7 days. This also covers the control repository's own pin
of the monitor.

**Fix:** merge the Renovate pull request that updates the pin (or find out
why there is none).

# Settings

Repositories that use the shared release flow. Expected values: README
"Set up a new repository", steps 6 and 7.

## settings-alerts

🔴 Dependabot alerts are off.

**Fix:** Settings → Advanced Security → Dependabot alerts.

## settings-pvr

🔴 Private vulnerability reporting is off (public repositories only;
⚪ not checked for private ones).

**Fix:** Settings → Advanced Security → Private vulnerability reporting.

## settings-actions

🔴 The default workflow token may write, or Actions may approve pull
requests.

**Fix:** Settings → Actions → General → Workflow permissions: read only,
"Allow GitHub Actions to create and approve pull requests" off.

## settings-fork-approval

🔴 Workflows of pull requests from forks run without approval. A fork pull
request chooses its own `runs-on`, so it can pick a self-hosted runner.
⚪ Not checked for private repositories. No finding when Actions is disabled
(no workflow can run). Checked on all owned repositories (shown under Settings
for central ones, else under their group).

**Fix:** Settings → Actions → General → "Approval for running fork pull
request workflows from contributors": *Require approval for all external
contributors*, or
`gh api -X PUT repos/spali/<repo>/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`.

## ruleset-main

🔴 The ruleset `main` is missing or differs: it must be active without bypass,
target the default branch, block deletion and force pushes, require a pull
request with rebase or squash, and require the check `pr / check`.
⚪ Not checked on private repositories of a Free account (no rulesets there).

**Fix:** Settings → Rules → Rulesets, restore it as in the README.

## ruleset-tags

🔴 The ruleset `release tags` is missing or differs: it must be active
without bypass, cover `refs/tags/v*` except `-next` and `-pr.*` tags, and only
block moving a tag. ⚪ Not checked like `ruleset-main`.

**Fix:** Settings → Rules → Rulesets, restore it as in the README.

# Health

Own repositories that are neither forks nor managed.

## settings-merge

🔴 The merge options differ: merge commits must be off, squash and rebase
on, branches deleted on merge, and the squash commit title must be the pull
request title. Checked on all own repositories that are neither forks nor
managed (shown under Settings for central ones, else under Health).

**Fix:** Settings → General → Pull Requests.

## stale-branch

🔴 A branch was the head of a merged pull request and still points at the
merged commit: it is left over (usually because "Automatically delete head
branches" was off, see `settings-merge`). 🔵 The branch has commits after the
merge: maybe it carries on. A branch with an open pull request, the default
branch and branches of unmerged pull requests are not reported; the newest
merged pull request of a branch counts. Own repositories look at pull requests
inside the repository, forks (also managed ones) at their pull requests into
the upstream. The finding links the pull request (`#N` in the repository,
`owner/upstream#N` upstream) and carries its number as `item`.

**Fix:** delete the branch (`git push --delete origin <branch>`, or the
Branches page). To keep it, ignore the pull request by its number:

```yaml
ignores:
  - {repo: spali/example, check: stale-branch, item: 12, reason: release branch}
```

## main-red

🔴 The latest run of a workflow on the default branch failed. Runs of pull
requests and the monitor's own workflow are not counted.

**Fix:** open the run (link in the details), fix the cause, re-run.

## renovate-stale

🔴 A Renovate pull request has been open for more than 7 days.

**Fix:** review and merge it, or close it (Renovate then stops proposing that
update).

## workflow-disabled

🔴 GitHub disabled a workflow after 60 days without activity in the
repository. Scheduled jobs then stop silently.

**Fix:** `gh workflow enable <workflow> -R <repo>`; push a commit if it
should keep running.

## dependabot-alert

🔴 for critical or high, 🔵 for medium or low: open Dependabot alerts.
⚪ Not checked when alerts are off for the repository.

**Fix:** update the dependency, or dismiss the alert with a reason.

## code-scanning-alert

🔴 for critical or high, 🔵 for medium or low: open code scanning alerts.
⚪ Not checked when code scanning is not set up.

**Fix:** fix the code, or dismiss the alert with a reason.

## unanswered

🔴 Someone waits for an answer in an open pull request or issue: the newest
post by a human is not by the owner and older than `unanswered.days` days
(default 7). Posts are the opening, comments and, for pull requests, reviews
and review comments; a follow-up after the owner's answer counts again. Posts
of bots are ignored, items opened by a bot are not checked (Renovate pull
requests are `renovate-stale`). The finding names the days since that post
and links the item.

```yaml
unanswered:
  days: 14
```

**Fix:** answer it or close it. To accept one item, ignore it by its number
(`item` is only allowed for this check and `stale-branch`). The ignore stays
used while the item is open, whoever answered last; once the item is closed,
it is reported as `ignore-unused`: remove it.

```yaml
ignores:
  - {repo: spali/example, check: unanswered, item: 70, reason: reviewed separately}
```

# Forks

Forks with an upstream that are not managed.

## fork-behind

🔵 A fork is behind its upstream repository.

**Fix:** sync it by hand (button "Sync fork"), add it to `managed:` so the
central sync keeps it current, or archive it to freeze this state (see
[Freeze a fork or mirror](#freeze-a-fork-or-mirror)).

## fork-workflows-active

🔵 A fork has Actions enabled and active workflows (usually copied from
upstream), which can fail or use minutes for nothing. A fork with Actions
disabled in its settings is clean, whatever state its workflows report.

**Fix:** Settings → Actions → General → "Disable actions" (one switch, also
covers workflows that later come from upstream).

## fork-delete-candidate

🔵 The fork has no own commits on its default branch, no open pull request
upstream, and every branch of it also exists upstream or was the head of a
closed or merged pull request from the fork (contribution done): nothing
would be lost.

**Fix:** delete the fork, archive it to freeze the state you reference (see
[Freeze a fork or mirror](#freeze-a-fork-or-mirror)), or add it to `managed:`
to keep it synced.

# Lists

The GitHub Lists of the owner (stars), named in `lists` of `repos.yml`.
Archived repositories (snapshots) go in the same Lists as active ones and get
the same checks, except `unmanaged`: an archived repository is not synced.

## list-none

🔵 A repository is in no list (`in no list`), a fork or a repository under
`managed:` (such as a mirror of a repository outside GitHub) is in none of the
mirrors lists of `lists.mirrors` (`synced` and `other`, for example
"👀  Mirrors", "▶️ Contribution forks", "♻️ Customization forks"; message
`in none of the mirrors lists`). Archived repositories count too. The
mirrors variant is not reported while one of the configured mirrors Lists is
missing (that is `config-invalid`); "in no list" is still reported.
Without mirrors lists, forks and managed repositories get the plain
`in no list` rule.

**Fix:** add it to a list (a fork or managed repository to a mirrors list).

## list-contradiction

🔵 A repository is in both lists of an exclusive pair.

**Fix:** remove it from one of them.

### Freeze a fork or mirror

To keep a fork or mirror at its current state, without syncs or checks:
archive it on GitHub and leave it in its List (a fork in a mirrors list). The
monitor then checks it only for its lists. To move it to a newer state,
unarchive it, sync it, and archive it again.

A repository under `managed:` must first be removed from `managed:` (the sync
cannot push to an archived repository); until then the monitor reports it as
`managed-settings`.

## list-external-own

🔵 An own repository (archived ones too) is in a list of `lists.external`,
such as "🔍 Interesting and related", which is for repositories of others
(`own repository in "<list>"`).

**Fix:** move own work to your stack list and own forks to a mirrors list
(`lists.mirrors`).

## adoption

🔵 An own repository (not a fork, not under `managed:`) that does not use the shared
release flow ("no central release flow"). One finding per repository.

**Fix:** adopt the flow (README "Set up a new repository"), or ignore the
finding with a reason.

# Managed repositories

Forks and mirrors listed under `managed:` in `repos.yml`. The sync workflow
of the control repository keeps them up to date; the monitor only reports.
A fork has a `github.com` upstream, everything else is a mirror.

## managed-missing

🔴 A repository under `managed:` does not exist ("managed repository does
not exist (the sync creates it)"). No other check runs for it.

**Fix:** let the sync run (it creates a missing fork; a missing mirror fails
the sync job with the command to create it by hand once), or fix the `repo`
of the entry.

## managed-settings

🔴 A managed repository deviates from its settings: issues, pull requests,
wiki, discussions, projects and Actions are all off unless its `settings:`
says otherwise. The detail lists each difference
(`has_wiki is true, expected false`). An archived repository still under
`managed:` is reported with one finding (`archived but still under
managed:: remove the entry`) and gets no other managed check.

**Fix:** correct the repository settings, or the `settings:` of its entry; for
an archived one, remove the entry from `managed:` (see
[Freeze a fork or mirror](#freeze-a-fork-or-mirror)).

## managed-behind

🔴 A managed repository lacks upstream changes for more than 48 hours (the
24-hour sync interval plus 24 hours):

- branches (forks and mirrors alike): the default branch misses commits of
  the upstream default branch, or a branch declared with `rebase: auto`
  misses commits of its `onto`, and the oldest missing commit is older than
  48 hours (`main: 3 upstream commits missing, oldest from …`). A declared
  default branch follows its declaration. An upstream branch that matches a
  `follow` pattern is compared with the target branch of the same name the
  same way. A declared or followed branch that does not exist in the target
  is red at once (`feat: missing in the target`); a followed branch that is
  new upstream shows this until the next sync run creates it. A fork is
  compared in the upstream repository; a mirror (upstream not on github.com)
  in the mirror itself, which works only when the upstream commit is already
  there: otherwise the branch is red once the last push is older than 48
  hours (`main: differs from upstream, last push …`; a `rebase: manual`
  branch: `rebase-pending` without a count). A mirror branch declared onto
  a branch the upstream does not have is red at once
  (`feat: onto dev missing upstream`; the sync fails on it too);
- tags (unless `tags: false`): upstream tags are missing or differ in the
  target, and the last push is older than 48 hours
  (`2 tags differ, last push …`).

The head branch of an open upstream pull request from the fork is left out:
the sync never writes it.

When the default branch of a mirror's upstream cannot be read (`git
ls-remote --symref` fails or the upstream has no `HEAD`), its branches are
not compared: `check-failed` with
`managed-behind: cannot read the upstream default branch`.

A branch or tag the sync stopped because upstream rewrote it
(`upstream rewritten` or `upstream moved tag` in the sync run) stays behind
until the rewrite is accepted, so it may also show here (only once the last
push is older than 48 hours); `sync-failed` is the reliable signal.

**Fix:** look at the sync run (see `sync-failed`); for a missing `onto`,
fix the `onto` of the branch in `repos.yml`; for a stopped ref, accept the
rewrite as described under `sync-failed`.

## branch-undeclared

🔴 A branch of a managed fork or mirror has own commits but is not declared
in `branches:` and is not the head of an open pull request from the fork to
upstream. Own commits of the default branch are counted against the upstream
default branch (never against an upstream branch of the same name), those
of any other branch (a followed one too, the sync mirrors it by name)
against the upstream branch of the same name, else the upstream default
branch. The default branch counts too unless it is declared. The sync
ignores an undeclared branch that is neither the default branch nor
followed: its run stays green, only the monitor reports it. The default
branch or a followed branch with own commits is kept by the sync and fails
its run. A mirror is compared in the mirror itself: when the upstream commit
is not there, a branch the sync moves (the default or a followed one) is
left to `managed-behind`. (🔵 for an unmanaged fork, where no sync manages
anything.)

🔵 A mirror branch that is neither the default branch, declared nor
followed is never synced, so it may be an old copy of an upstream branch
that has moved on since; the mirror cannot tell such a stale copy from own
commits. It is no finding when its tip is the sha of any upstream branch or
tag; otherwise it is compared with the mirror's own default branch and,
when it is ahead, reported as info:
`<branch>: differs from upstream, not followed (own commits or a stale upstream copy)`.

**Fix:** declare the branch with its `onto` and `rebase`, or delete it (or
reset the default branch to upstream) by hand.

## rebase-pending

🔵 A branch declared with `rebase: manual` is behind its `onto` upstream
(`wip: 2 upstream commits to rebase onto main`).

**Fix:** in the control repository run
`gh workflow run sync.yml -f repo=<repo> -f branch=<branch>`; on a conflict
rebase it by hand and push.

## sync-failed

🔴 The last sync of a managed repository did not succeed: per repository
under `managed:` the newest job `Sync · <repo>` of the workflow `sync.yml` on
the branch `main` of the control repository that has a result counts; any
result but success (`failure`, `timed_out`, …) is red. A cancelled or skipped
job, or one without a conclusion (e.g. a run GitHub cancelled in the sync
concurrency group), has no result and is passed over: the older job counts.
The detail links the job (`last sync of this repository failed: <url>`). A
sync of one repository (`-f repo=…`) thus never hides a failure of another
one.
🔴 Without a repository: in the newest run whose non-repository job
(`Managed repositories`) has a result, that job did not succeed (`sync run
failed before the repositories: <url>`).

Only runs on `main` are read; runs on other branches (tests) never count.
Checked once per monitor run (in the Lists job), only when `managed:` has
entries; reads the 20 newest completed runs and stops once every managed
repository and the plan job have a result. A repository without a job in
these runs (new entry) and no run yet are no finding. 🔴 A run with more jobs
than one page (100) is `check-failed` (`sync-failed: more jobs than one page
…`). ⚪ Not checked in a local run, where there is no control repository. The
report links the sync runs of the control repository (Fix at) when it knows
the control file URL.

The job of a repository also fails when the sync stopped a ref because upstream rewrote it:
`error: <ref>: upstream rewritten (…)` or `upstream moved tag (…)`, with the
command to accept it. Such a ref stays as it was (the other refs are synced)
until the rewrite is accepted.

**Fix:** read the log of the job or run, fix the cause, run the sync again
(`gh workflow run sync.yml -f repo=<repo>`). For a
stopped ref: check upstream, then in the control repository run
`gh workflow run sync.yml -f repo=<repo> -f accept=<branch|tags/name|*>`
(the old tip is kept in `refs/backup/<branch>` or `refs/backup-tags/<tag>`).

## contribution-stale

🔵 An open upstream pull request from a fork is older than 90 days
(`PR #12 open for 91 days: <url>`). Checked for unmanaged forks.

**Fix:** follow up or close it.

## unmanaged

🔵 A repository (not archived) is in a synced mirrors list
(`lists.mirrors.synced`, for example "👀  Mirrors") but is not listed under
`managed:` (`in "<list>" but not managed`). The `other` mirrors lists may
hold unsynced forks.

**Fix:** add it to `managed:`, or ignore the finding with a reason.

# Billing

The included Actions quota of the account (Settings → Billing), checked once
per run, not per repository. Only the product Actions counts (Actions
minutes and Actions storage; Packages, Git LFS and Codespaces have included
quotas of their own and are left out), and only private repositories (public ones use Actions for free). A repository
of the usage that is not in the inventory (archived, created since) is looked
up once per run with the app token: a public one is left out, an archived
private one counts and is marked `(archived)`, one that no longer exists
(deleted, renamed) counts as private and is marked `(not in inventory)`. A
failing lookup is `check-failed`. Without an inventory (empty list) the run
lists ⚪ `billing` "no inventory: billing not checked". The checks need a fine-grained token of the owner with
the account permission Plan: read (the optional secret `account-token` of the
monitor workflow); without one the run lists ⚪ `billing` "no account token:
billing not checked".

Minutes weigh by price: the cost of all minutes (macOS and Windows cost more)
divided by the price of a Linux minute, so the numbers read like GitHub's.
Storage is a monthly average: GB-hours so far against the included GB over
the elapsed hours. Projections (UTC month): minutes at the pace so far;
storage at the level of yesterday (on day 1 the average so far) for the rest
of the month. Yesterday is the UTC day before the run; shortly after midnight
GitHub may still be filling in its usage, so the storage level can read low
in an early run. Included values come from the plan (Free: 2000 minutes and
0.5 GB, Pro: 3000 and 1 GB; other plans need the block), thresholds default
to 75 %. Set any of them in the control file:

```yaml
billing:
  minutes:
    included: 2000   # included minutes per month
    threshold: 75    # percent
  storage:
    included-gb: 0.5 # included Actions storage (monthly average)
    threshold: 75    # percent
```

## billing-minutes

🔴 The private repositories used `billing.minutes.threshold` percent of the
included minutes, or (from day 7 of the month) the projection to month end
reaches 100 % (`Actions minutes at 80 % of the included 2000 (1600),
projected 137 % by month end`).

**Fix:** the `billing` line names the top repositories: move their hosted
jobs to a self-hosted runner or run them less often. Raise
`billing.minutes.threshold` if the usage is expected.

## billing-storage

🔴 The average Actions storage (artifacts and caches) of the private
repositories reached `billing.storage.threshold` percent of the included
storage, or (from day 7) the projection to month end reaches 100 %.

**Fix:** the `billing` line names the top repositories: delete old artifacts
and caches or shorten their retention. Raise `billing.storage.threshold` if
the usage is expected.

## billing

🔵 One line per run with the numbers, also without a red finding, to see the
trend: `Actions minutes 15 % (300 of 2000, projected 26 %) · storage 0 %
(<1 MB of 500 MB, projected 0 %) · top: private-a 300 min · top storage:
private-a <1 MB`. Before day 7 of the month the projection is not shown yet
(`Actions minutes 15 % (300 of 2000, projection from day 7)`, the same for
storage). Not a TODO entry. ⚪ Not checked without an account token or without
an inventory.

**Fix:** nothing to do; act on `billing-minutes` or `billing-storage`.

# Monitor

## check-failed

🔴 A check could not run: an API error, a rate limit, an answer it could not
read, a script that crashed, or no repositories visible to the app. The
check is not a pass.

**Fix:** read the details and the run log, fix the access or the script.
Never ignore it.

## config-invalid

🔴 The control file is missing or invalid, or names an unknown list or
check. The run continues with an empty control file.

**Fix:** correct `repos.yml`; the Config workflow validates every change.

## ignore-unused

🔵 An ignore in `repos.yml` matched no finding: its cause is gone, or it has
a typo.

**Fix:** remove it, or correct the repository or check id.
