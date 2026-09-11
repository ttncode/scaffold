# 0024 — Publishing a project is part of generating it

Status: Accepted
Date: 2026-09-11

## Context

`scaffold new` produces a project that already assumes a GitHub repository
exists: `compose.yaml`'s image, `install.sh`'s `RepoUrl` and both build
workflows all name `<owner>/<project>`, written from the account resolved at
generation time. Creating that repository, and configuring it, was left to a
person following `docs/runbook/first-project-walkthrough.md`.

Two of those steps fail in ways that point somewhere other than themselves,
and both were hit in one afternoon while testing this toolbox:

- **`gh repo create --push` pushes the branch you are standing on and makes it
  the repository's default.** From a feature branch, `main` never reaches the
  remote; `gh pr create` then refuses with "head branch is the same as the base
  branch", and CI's `changes` job fails fetching a `main` that is not there.
  The runbook already warns about this in three paragraphs, which is what a
  warning looks like when the thing warned about cannot be prevented.
- **Without `can_approve_pull_request_reviews`, Release Please cannot open its
  release pull request.** Measured on `ttncode/duo-trial`: the release job
  failed with "GitHub Actions is not permitted to create or approve pull
  requests" — a message about Actions, several steps from the repository
  setting that caused it. The runbook calls this call "required, not
  optional", in bold, which is the same admission.

ADR-0004 names a third: branch protection is the only one of the four
guardrails that is a repository setting rather than a file, and the one most
likely to be skipped because nothing in the project records whether it was
applied.

A runbook step that is required, has no in-repo trace, and fails somewhere
else is a step that should not be a runbook step.

## Decision

`scaffold publish [dir]` creates the repository and applies the settings.

**The repository is the one the project already names.** `<owner>/<name>` comes
from the registry path recorded in `mise.toml`, not from an argument: the
project's compose file, installer and workflows all carry that pair, so a
repository created under any other name leaves every one of them resolving to
nothing. There is no flag to override it, because overriding it is the defect.

**It refuses to create a repository from anywhere but a clean `main`**, for
the reason above. Once the repository exists it touches no branch at all, so
this is a guard on creation, not a general rule.

**Idempotent.** Each step asks whether it has already been done. Running it
against an existing repository applies only the settings — which is the case
that matters, because the settings are the half people forget and nothing in
the project's files records whether they were applied.

**Branch protection as a ruleset on the default branch**: a pull request
required, no force-push, no deletion, review threads resolved. No required
status checks: a ruleset names them literally, and this project's are
`ci (apps/api)` — one per config root, differing per project and changing
whenever an application is added. Requiring a pull request is the part that
generalises; naming checks belongs to whoever knows the project.

**A plan that refuses rulesets is a warning, not a failure.** Measured: a
private repository on a free account answers 403 "Upgrade to GitHub Pro or
make this repository public to enable this feature". Everything before that
step succeeded, and failing the command would withhold those steps from
exactly the accounts that most need them. Any other error is still fatal.

**The release app secrets are set when both are in the environment**, and
their absence is reported rather than silently accepted: without them Release
Please opens its pull request as `GITHUB_TOKEN`, whose checks sit at "Action
required" and then expire red — three runs in the history that say nothing
true about the project.

**Not GitHub Pages.** `app-docs.yml` builds the documentation site and does
not deploy it, so there is no Pages setting for this command to set. If a
deploy job is added there, this decision needs revisiting.

## Consequences

- Steps 8's `gh` incantations disappear from the walkthrough, and the trap
  they were warning about cannot be walked into.
- The command is tested against a stubbed `gh` (`tests/publish.bats`), the
  same technique `tests/install.bats` uses for `curl` and `docker`. What that
  does not cover is whether GitHub accepts the ruleset payload; the shape is
  asserted to be valid JSON carrying the three rules, and the live path was
  exercised only far enough to observe the plan limit above.
- A project whose GitHub repository is renamed after generation still breaks
  every reference to it. This command does not fix that; it removes one way
  of arriving there.
- `scaffold` now needs `gh` for one of its commands. It is not added to
  `require_tools`: `new`, `add`, `update`, `list` and `lint` all work without
  it, and only `publish` checks for it, by name, before doing anything.

## Alternatives considered

- **Leaving it in the runbook.** Rejected by evidence: the two steps that most
  needed following were the two that went wrong while testing this toolbox on
  the day the command was written.
- **Taking the repository name as an argument.** Rejected: the project already
  names exactly one repository in four files, and a second source for that
  name is a way for them to disagree.
- **Requiring status checks in the ruleset.** Rejected: their names are
  per-project and change as applications are added, so anything general enough
  to write here would be wrong for most projects.
- **Prompting for confirmation before creating.** Rejected: typing
  `scaffold publish` is the confirmation, and `--dry-run` prints what it would
  do for anyone who wants to see it first.
