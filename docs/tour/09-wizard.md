# 09 — Wizard

## What it does

1. `scaffold` with no arguments opens the wizard only when stdin is a terminal (`[[ -t 0 ]]` in `main`); otherwise it prints usage and exits 1, so scripts and CI never hang.
2. Action: `new`; `update` and `publish` are offered only inside a scaffold project. A single option skips the screen.
3. For `new`: name, then shape (`web+api`, `app`, `api`, `web`), then one question per role and service. `web` asks only for its adapter: no database or cache (ADR-0020).
4. Options come from `scaffold list`, so a new adapter or service appears without editing the wizard.
5. It prints the equivalent `scaffold new` command and asks `[y/N]` before running it. No back navigation: Esc or Ctrl-C exits.

## Read this

| File | Why |
| --- | --- |
| `lib/wizard.sh` | Pure functions: `wizard_actions`, `wizard_shapes`, `wizard_questions`, `wizard_options`, `wizard_new_args`, `wizard_command` |
| `lib/tui.sh` | Terminal screens; `tui_name_is_usable` calls `project_name_is_usable` from `lib/project.sh` |
| `scaffold` | `cmd_wizard`, `ask_shape_questions`; `SCAFFOLD_WIZARD_DRY_RUN=1` stops before anything changes |
| `tests/wizard.bats` | Direct tests of the pure functions, plus pty tests that drive the real screens |

## Delete test

Delete the `[[ -t 0 ]] ||` guard in `scaffold`'s `main` and `tests/cli.bats` fails:
"scaffold with no arguments prints usage and fails".

## Try it

```bash
SCAFFOLD_WIZARD_DRY_RUN=1 ./scaffold   # in a terminal; answer y at the end, nothing is generated
```
