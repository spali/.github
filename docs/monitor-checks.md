# Maintenance monitor checks

What each check of the [maintenance monitor](../README.md#maintenance-monitor)
looks at, why a finding matters and how to fix it. The overview issue links
each check title here.

**Levels:** 🔴 red is something to fix (the run fails while one is open),
🔵 info is a hint, ⚪ skipped means "not applicable" and is only counted.
To accept a finding, add `{repo, check, reason}` to `ignores` in the control
file `repos.yml`. Settings and rulesets change only with the owner's approval.

Groups: [Release flow](#release-flow) · [Settings](#settings) ·
[Health](#health) · [Forks](#forks) · [Mirrors](#mirrors) · [Lists](#lists) ·
[Managed repositories](#managed-repositories) · [Monitor](#monitor)

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

## settings-merge

🔴 The merge options differ: merge commits must be off, squash and rebase
on, branches deleted on merge, and the squash commit title must be the pull
request title.

**Fix:** Settings → General → Pull Requests.

## settings-alerts

🔴 Dependabot alerts are off.

**Fix:** Settings → Advanced Security → Dependabot alerts.

## settings-pvr

🔴 Private vulnerability reporting is off (public repositories only;
⚪ skipped for private ones).

**Fix:** Settings → Advanced Security → Private vulnerability reporting.

## settings-actions

🔴 The default workflow token may write, or Actions may approve pull
requests.

**Fix:** Settings → Actions → General → Workflow permissions: read only,
"Allow GitHub Actions to create and approve pull requests" off.

## ruleset-main

🔴 The ruleset `main` is missing or differs: it must be active without bypass,
target the default branch, block deletion and force pushes, require a pull
request with rebase or squash, and require the check `pr / check`.
⚪ Skipped on private repositories of a Free account (no rulesets there).

**Fix:** Settings → Rules → Rulesets, restore it as in the README.

## ruleset-tags

🔴 The ruleset `release tags` is missing or differs: it must be active
without bypass, cover `refs/tags/v*` except `-next` and `-pr.*` tags, and only
block moving a tag. ⚪ Skipped like `ruleset-main`.

**Fix:** Settings → Rules → Rulesets, restore it as in the README.

# Health

Own repositories that are neither forks nor mirrors nor managed.

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
repository. Scheduled jobs (such as a fork sync) then stop silently.

**Fix:** `gh workflow enable <workflow> -R <repo>`; push a commit if it
should keep running.

## dependabot-alert

🔴 for critical or high, 🔵 for medium or low: open Dependabot alerts.
⚪ Skipped when alerts are off for the repository.

**Fix:** update the dependency, or dismiss the alert with a reason.

## code-scanning-alert

🔴 for critical or high, 🔵 for medium or low: open code scanning alerts.
⚪ Skipped when code scanning is not set up.

**Fix:** fix the code, or dismiss the alert with a reason.

# Forks

Forks with an upstream that are not managed.

## fork-behind

🔵 A fork is behind its upstream repository.

**Fix:** sync it (button "Sync fork") when you need the changes.

## fork-sync-stale

🔴 A fork with its own sync workflow (listed under `forks` in `repos.yml`)
misses upstream commits older than its `sync_interval_hours` plus 24 hours:
the sync does not work.

**Fix:** look at the sync workflow of the fork (disabled? failing? conflict?).

## fork-workflows-active

🔵 A fork runs its own workflows (usually copied from upstream), which can
fail or use minutes for nothing.

**Fix:** disable the workflows you do not need.

## fork-delete-candidate

🔵 The fork has no own commits on its default branch, no open pull request
upstream, and every branch of it also exists upstream or was the head of a
closed or merged pull request from the fork (contribution done): nothing
would be lost.

**Fix:** delete the fork if you no longer need it.

# Mirrors

Mirror targets listed under `mirrors` in `repos.yml`.

## mirror-behind

🔴 The mirror lacks branches or tags of its source, and its last push is
older than `interval_hours` plus 24 hours: the mirror job does not work.

**Fix:** look at the mirror job.

# Lists

The GitHub Lists of the owner (stars), named in `lists` of `repos.yml`.

## list-none

🔵 A repository is in no list, or a fork is in none of the fork lists.

**Fix:** add it to a list.

## list-contradiction

🔵 A repository is in both lists of an exclusive pair.

**Fix:** remove it from one of them.

## list-mirror-missing

🔵 A mirror target is not in the mirrors list.

**Fix:** add it to the list.

## list-archived

🔵 An archived repository is still in a list other than the archive list.

**Fix:** move it to the archive list.

## adoption

🔵 Own repositories (not forks, not mirrors) that do not use the shared
release flow.

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
(`has_wiki is true, expected false`).

**Fix:** correct the repository settings, or the `settings:` of its entry.

## managed-behind

🔴 A managed repository lacks upstream changes for more than 48 hours (the
24-hour sync interval plus 24 hours):

- a fork: its default branch misses commits of the upstream default branch,
  or a branch declared with `rebase: auto` misses commits of its `onto`, and
  the oldest missing commit is older than 48 hours
  (`main: 3 upstream commits missing, oldest from …`). A declared default
  branch follows its declaration. A declared branch that does not exist in
  the fork is red at once (`feat: missing in the target`);
- a mirror, or a fork with `refs: all`: branches or tags of the upstream are
  missing or differ (declared branches excepted), and the last push is older
  than 48 hours (`2 refs differ, last push …`).

The head branch of an open upstream pull request from the fork is left out:
the sync never writes it.

**Fix:** look at the sync run (see `sync-failed`).

## branch-undeclared

🔴 A branch of a managed fork has own commits but is not declared in
`branches:` and is not the head of an open pull request from the fork to
upstream. Own commits of the default branch are counted against the upstream
default branch (never against an upstream branch of the same name; with
`refs: all`, which mirrors branches by name, like any other branch), those
of any other branch against the upstream branch of the same name, else the
upstream default branch. The default branch counts too unless it is
declared. The sync does not touch such a branch and its run fails. (🔵 for
an unmanaged fork, where no sync manages anything.)

**Fix:** declare the branch with its `onto` and `rebase`, or delete it (or
reset the default branch to upstream) by hand.

## rebase-pending

🔵 A branch declared with `rebase: manual` is behind its `onto` upstream
(`wip: 2 upstream commits to rebase onto main`).

**Fix:** in the control repository run
`gh workflow run sync.yml -f repo=<repo> -f branch=<branch>`; on a conflict
rebase it by hand and push.

## sync-failed

🔴 The newest completed run of the workflow `sync.yml` in the control
repository did not succeed; the detail links the run. Checked once per
monitor run (in the Lists job), only when `managed:` has entries. No run yet
is no finding. ⚪ Skipped in a local run, where there is no control
repository.

**Fix:** read the log of the run, fix the cause, run the sync again.

## contribution-stale

🔵 An open upstream pull request from a fork is older than 90 days
(`PR #12 open for 91 days: <url>`). Checked for unmanaged forks.

**Fix:** follow up or close it.

## unmanaged

🔵 A repository is in the mirrors list (`lists.mirrors`) but is neither
listed under `managed:` nor a mirror target under `mirrors:`
(`in the mirrors list but not managed`).

**Fix:** add it to `managed:`, or ignore the finding with a reason.

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
