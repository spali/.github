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
are 🤔 Decide (a choice only you can make: `adoption`,
`contribution-stale`, `fork-delete-candidate`, `list-contradiction`,
`rebase-pending`, `stale-branch`) or 🧹 Clean up (all other checks). The title and sentence of each entry are in `MONITOR_TODO` in
`scripts/monitor-lib.sh`.

Groups: [Release flow](#release-flow) · [Settings](#settings) ·
[Health](#health) · [Forks and mirrors](#forks-and-mirrors) ·
[Lists](#lists) · [Billing](#billing) · [Monitor](#monitor)

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

## funding

🔵 The sponsor button does not match the repository. An own repository with a
`.github/FUNDING.yml` has the button off, so the file has no effect. A fork or
mirror has the button on: its `FUNDING.yml` is the upstream's, so the button
would collect for the upstream on your repository. Read with GraphQL
(`fundingLinks`, `hasSponsorshipsEnabled`).

**Fix:** Settings → General → Features → *Sponsorships*: on for an own
repository with a `FUNDING.yml`, off for a fork or mirror, or
`gh api graphql -f query='mutation { updateRepository(input: {repositoryId: "<id>", hasSponsorshipsEnabled: true}) { repository { hasSponsorshipsEnabled } } }'`
(`false` for a fork; the id from `gh api repos/spali/<repo> --jq .node_id`).

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

Own repositories that are neither forks nor under `forks:`.

## settings-merge

🔴 The merge options differ: merge commits must be off, squash and rebase
on, branches deleted on merge, and the squash commit title must be the pull
request title. Checked on all own repositories that are neither forks nor
under `forks:` (shown under Settings for central ones, else under Health).

**Fix:** Settings → General → Pull Requests.

## stale-branch

🔴 A branch was the head of a merged pull request and still points at the
merged commit: it is left over (usually because "Automatically delete head
branches" was off, see `settings-merge`). 🔵 The branch has commits after the
merge: maybe it carries on. A branch with an open pull request, the default
branch and branches of unmerged pull requests are not reported; the newest
merged pull request of a branch counts. Own repositories look at pull requests
inside the repository, forks (synced and pinned ones) at their pull requests
into the upstream. The finding links the pull request (`#N` in the repository,
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

# Forks and mirrors

Every own fork on GitHub that is not archived, and every entry of `forks:` in
`repos.yml` (a mirror of a repository outside GitHub needs one, with its
`upstream`). The sync workflow of the control repository keeps them up to
date unless they are pinned; the monitor only reports. A fork has a
`github.com` upstream (its parent, unless the entry names one), everything
else is a mirror.

What the sync does by default: the default branch follows the upstream
default branch, fast-forwarded, or rebased onto it when it has own commits (a
conflict fails the sync: `sync-failed`). Tags follow upstream (unless
`tags: false`). Other branches are synced only when declared under
`branches:` (rebased onto their `onto`) or matched by `follow:` (taken over
by name); all others are left alone. Issues, pull requests, wiki,
discussions, projects and Actions are off unless `settings:` says otherwise.
The head branch of an open upstream pull request from the fork is never
written.

### Pin a fork or mirror

`pinned: true` in its entry keeps a fork or mirror at its state while you
keep using it: the sync leaves it alone, and the monitor checks only
`settings-fork-approval`, `stale-branch`, `fork-delete-candidate` and
`contribution-stale` (forks), never its settings or how far it is behind.

```yaml
forks:
  - {repo: spali/example, pinned: true}
```

### Freeze a fork or mirror

To keep it at its current state for good: archive it on GitHub and leave it
in its List. The sync skips archived forks, and the monitor checks it only
for its lists. To move it to a newer state, unarchive it, sync it, and
archive it again. An archived repository with an entry that is not pinned is
`fork-settings` until the entry is removed or pinned.

## fork-missing

🔴 A repository under `forks:` does not exist ("repository does not exist
(the sync creates a fork)"). No other check runs for it.

**Fix:** let the sync run (it creates a missing fork from the `upstream` of
the entry; a missing mirror fails the sync job with the command to create it
by hand once), or fix the `repo` of the entry.

## fork-settings

🔴 A synced fork or mirror deviates from its settings: issues, pull
requests, wiki, discussions, projects and Actions are all off unless its
`settings:` says otherwise. The detail lists each difference
(`has_wiki is true, expected false`). An archived repository with an entry
that is not pinned is reported with one finding (`archived but synced: pin
it or remove its entry from forks:`) and gets no other check.

**Fix:** correct the repository settings, or the `settings:` of its entry; for
an archived one, remove or pin the entry (see
[Freeze a fork or mirror](#freeze-a-fork-or-mirror)).

## fork-behind

🔴 A synced fork or mirror lacks upstream changes for more than 48 hours
(the 24-hour sync interval plus 24 hours):

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
`fork-behind: cannot read the upstream default branch`. An entry without
`upstream` whose repository is no fork on GitHub is `check-failed` with
`fork-behind: no upstream: …`.

A branch or tag the sync stopped because upstream rewrote it
(`upstream rewritten` or `upstream moved tag` in the sync run) stays behind
until the rewrite is accepted, so it may also show here (only once the last
push is older than 48 hours); `sync-failed` is the reliable signal.

**Fix:** look at the sync run (see `sync-failed`); for a missing `onto`,
fix the `onto` of the branch in `repos.yml`; for a stopped ref, accept the
rewrite as described under `sync-failed`.

## rebase-pending

🔵 A branch declared with `rebase: manual` is behind its `onto` upstream
(`wip: 2 upstream commits to rebase onto main`).

**Fix:** in the control repository run
`gh workflow run sync.yml -f repo=<repo> -f branch=<branch>`; on a conflict
rebase it by hand and push.

## sync-failed

🔴 The last sync of a fork or mirror did not succeed: per synced repository
(the own forks that are not archived and the entries of `forks:`, without
the pinned ones) the newest job `Sync · <repo>` of the workflow `sync.yml` on
the branch `main` of the control repository that has a result counts; any
result but success (`failure`, `timed_out`, …) is red. A cancelled or skipped
job, or one without a conclusion (e.g. a run GitHub cancelled in the sync
concurrency group), has no result and is passed over: the older job counts.
The detail links the job (`last sync of this repository failed: <url>`). A
sync of one repository (`-f repo=…`) thus never hides a failure of another
one.
🔴 Without a repository: in the newest run whose non-repository job
(`Repositories`) has a result, that job did not succeed (`sync run
failed before the repositories: <url>`).

Only runs on `main` are read; runs on other branches (tests) never count.
Checked once per monitor run (in the Lists job), only when a repository is
synced; reads the 20 newest completed runs and stops once every synced
repository and the plan job have a result. A repository without a job in
these runs (new fork or entry) and no run yet are no finding. 🔴 A run with
more jobs than one page (100) is `check-failed` (`sync-failed: more jobs than
one page …`). ⚪ Not checked in a local run, where there is no control
repository. The report links the sync runs of the control repository (Fix
at) when it knows the control file URL.

The job of a repository fails when the rebase of a branch (the default branch
with own commits too) has a conflict, when a followed branch has own commits,
and when the sync stopped a ref because upstream rewrote it:
`error: <ref>: upstream rewritten (…)` or `upstream moved tag (…)`, with the
command to accept it. Such a ref stays as it was (the other refs are synced)
until the rewrite is accepted.

**Fix:** read the log of the job or run, fix the cause, run the sync again
(`gh workflow run sync.yml -f repo=<repo>`). For a conflict: rebase the
branch by hand and push, or pin the fork. For a
stopped ref: check upstream, then in the control repository run
`gh workflow run sync.yml -f repo=<repo> -f accept=<branch|tags/name|*>`
(the old tip is kept in `refs/backup/<branch>` or `refs/backup-tags/<tag>`).

## fork-delete-candidate

🔵 The fork has no own commits on its default branch, no open pull request
upstream, and every branch of it also exists upstream or was the head of a
closed or merged pull request from the fork (contribution done): nothing
would be lost.

**Fix:** delete the fork, or archive or pin it to keep the state you
reference (see [Pin a fork or mirror](#pin-a-fork-or-mirror)).

## contribution-stale

🔵 An open upstream pull request from a fork is older than 90 days
(`PR #12 open for 91 days: <url>`).

**Fix:** follow up or close it.

# Lists

The GitHub Lists of the owner (stars), named in `lists` of `repos.yml`.
Archived repositories (snapshots) go in the same Lists as active ones and get
the same checks.

## list-none

🔵 A repository is in no list (`in no list`), or a fork or a repository
under `forks:` (such as a mirror of a repository outside GitHub) is in none
of the forks lists of `lists.forks` (for example "🍴 Forks & mirrors";
message `in none of the forks lists`). Archived repositories count too. The
forks variant is not reported while one of the configured forks Lists is
missing (that is `config-invalid`); "in no list" is still reported.
Without forks lists, forks and entries get the plain `in no list` rule.

**Fix:** add it to a list (a fork or mirror to a forks list).

## list-contradiction

🔵 A repository is in both lists of an exclusive pair.

**Fix:** remove it from one of them.

## list-external-own

🔵 An own repository (archived ones too) is in a list of `lists.external`,
such as "🔍 Interesting and related", which is for repositories of others
(`own repository in "<list>"`).

**Fix:** move own work to your stack list and own forks to a forks list
(`lists.forks`).

## adoption

🔵 An own repository (not a fork, not under `forks:`) that does not use the shared
release flow ("no central release flow"). One finding per repository.

**Fix:** adopt the flow (README "Set up a new repository"), or ignore the
finding with a reason.

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
