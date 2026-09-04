# 09 — Wizard

## What it does

`scaffold` run with no arguments walks a user to a complete `new` command
instead of printing usage and exiting. It only does this in a terminal:
`main` checks `[ -t 0 ]` before calling `cmd_wizard`, and every other
invocation — a script, CI, `mise exec -- ./scaffold list` inside this
repository's own tests — keeps exactly today's behaviour. `scaffold`
appears in all three; a bare call that opened a menu there would hang them
as a timeout, not fail as an error, so the TTY check is the whole safety
argument.

The first question is shape — `web+api`, `app`, `api`, or `web` — not
frontend and backend separately. `laravel-inertia` sets
`ADAPTER_ROLE=app`: it is one application serving both tiers, so asking
"frontend?" then "backend?" has no honest answer for it on a two-question
flow. Asking shape first means that combination is never assembled to
begin with, rather than offered and then rejected at a summary screen. The
remaining questions follow from the answer — `web` never asks about a
database, because the web tier has no driver and `scaffold new` refuses
`--db` there (ADR-0020); the refusal becomes an absence instead of
something the user can walk into.

Every option the wizard offers comes from `scaffold list`, grouped by the
role and kind columns that command already prints. `wizard_options` in
`lib/wizard.sh` hardcodes no adapter name, no service name, no tier. This
repository has twice shipped a second copy of a list that then drifted from
`adapter.env` — `scripts/adapter-matrix.sh` exists because of the first
drift, and the service-adapter branch broke that script by adding rows to
`scaffold list` without checking who parsed it. A wizard with its own list
would have been the third copy. Instead, a fifth service costs one
directory, and it appears in the wizard because the wizard asks `scaffold
list`, the same promise ADR-0019 makes for everything else that reads that
listing.

Before generating anything, the wizard prints the `scaffold new` command
its answers mean — `wizard_command` renders it from `wizard_new_args`'
argv, the same argv `cmd_wizard` passes to `cmd_new` — and asks to confirm.
The second project from the same answers is scripted rather than clicked.

## Read this

- `lib/wizard.sh` — `wizard_options`, `wizard_questions`, `wizard_prompt_for`,
  `wizard_new_args`, `wizard_command`: pure, string-in/string-out functions
  that hold everything that could be wrong about the wizard's logic, tested
  without a terminal at all.
- `lib/tui.sh` — the terminal machinery: hiding and restoring the cursor,
  turning off terminal echo for the whole menu, draining the autorepeat
  backlog, and `tui_name_is_usable`, which calls `project_name_is_usable`
  (`lib/project.sh`) — the same rule `init_project` enforces for the flags
  and `scaffold add`.
- `scaffold`'s `cmd_wizard` — name, shape, then one to four more screens
  depending on the shape, from `wizard_questions`;
  `SCAFFOLD_WIZARD_DRY_RUN=1` stops it just before `cmd_new` would run.
- `tests/wizard.bats` — the pure functions get direct tests; one pty test
  drives the real screens with a scripted key sequence and asserts only on
  the command line it prints at the end, not on frames.
- `docs/superpowers/specs/2026-09-04-interactive-wizard-design.md` for the
  full design, including the known limits: no back navigation (Ctrl-C and
  re-run), and a `web+api` project still building one image because
  `set_image_context` records one context per project regardless of shape.

## Delete test

Delete the `[ -t 0 ] ||` guard from `scaffold`'s `main` and nothing in
`mise run test-unit` catches it in the way you'd expect: `tests/wizard.bats`
deliberately drives the wizard through a real pty, and `tests/cli.bats`'s
"scaffold with no arguments prints usage and fails" is what actually
depends on the guard — bats gives that test's `run scaffold` a closed
stdin. With the guard gone, that closed stdin reaches `tui_prompt_name`'s
first `read`, which now hits EOF and exits 130 instead of looping on an
empty name forever (confirmed by removing the guard in a scratch copy) —
so the test still fails, on the wrong status and no `usage:` text, just
without needing CI's five-minute timeout to say so.

## Try it

```bash
mise exec -- ./scaffold
```

Run this in an actual terminal — it opens the wizard. Piped or redirected,
the same command prints usage and exits 1 instead, which is what
`tests/cli.bats` checks under bats.
