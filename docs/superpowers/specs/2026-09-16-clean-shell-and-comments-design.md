# Clean Shell and Comments Design

**Goal:** bring every tracked file to the `comment-code` standard and every
shell file to the Clean Bash rules (`~/.dotfiles/agentic/rules/bash.md`), and
lock the shell half in with lint so it does not drift back.

**Scope:** 64 shell files (`scaffold`, `lib/`, `scripts/`, `services/`,
`tests/`, `common/install.sh`) and every non-shell file that carries comments
(`adapters/`, `common/`, `.github/`, root `mise.toml`, `lefthook.yml`). No
behaviour changes. `docs/` prose is out of scope: it is documentation, not
comments.

## What was measured

Run against `main` at `39c78be`:

| Area | Files | Lines | Comment lines |
| --- | --- | --- | --- |
| `scaffold`, `lib/`, `scripts/`, `common/install.sh` | 17 | 4368 | 977 |
| `services/` | 15 | 715 | 261 |
| `tests/` (`.bats`, `.bash`, fixture `.sh`) | 32 | 4542 | 835 |
| non-shell files with comments | 80 | — | 592 |

| Rule | Occurrences |
| --- | --- |
| `[ ]` tests | 553 (`[[ ]]` already: 207) |
| `echo` | 173 |
| functions over 20 lines | 53 (largest: `cmd_add` 68, `tui_select` 55, `record_release_age_exceptions` 55) |
| `local x="$(…)"` | 4 |
| `let` / `expr` | 1 |
| shellcheck on `services/` + `tests/*.bash` (never linted today) | 30 findings: SC2016 ×17, SC2015 ×6, SC1003 ×4, SC2154 ×3 |
| `shfmt -i 2 -ci -d` (shfmt 3.14.1, not yet pinned) | 39 files, ~1800 changed lines |

## Decisions

**Where the repository overrides the rule.** Three rule items are wrong for
this codebase and are not applied:

- *File-level `readonly`.* `lib/*.sh` is sourced again into child processes;
  a second `readonly` of the same name is a fatal error. `local -r` stays.
- *`set -euo pipefail` in sourced files.* `lib/*.sh`, `services/**/*.sh` and
  `tests/helpers/setup.bash` inherit their options from the entrypoint that
  sources them; setting options there silently changes the caller.
  Executables (`scaffold`, `scripts/*.sh`, `common/install.sh`) must have it.
- *`[[ ]]` inside bats test bodies.* `[ "$status" -eq 0 ]` is bats' own idiom
  and reports the failing expression; the rule applies to helpers and to any
  shell outside a `@test` body.

**Byte-identical files are untouched.** Every `verbatim` row in
`docs/PROVENANCE.md` (today `common/.editorconfig`) and everything under
`common/docs/.vitepress/theme/vendor/` is excluded — `scripts/check-provenance.sh`
fails on any drift.

**Functional comments stay.** Anchors (`# @SERVICE_SETUP@`, `# @DB_ENGINE@`,
`# @DB_PROBE@`), toolchain pragmas (`# shellcheck …`, `# noqa`,
`// eslint-disable…`, `@phpstan-…`), `ponytail:` markers, and the `#!` line.
Splice anchors are matched byte-for-byte by awk/sed, so their column and
spelling are fixed.

**Functions are split only at a clear seam.** A function over 20 lines is split
when a contiguous block can be named for what it does. One that is long because
it is a single linear sequence — a large `case`, a heredoc, a TUI render loop —
stays whole, and the ledger records why. Every function name that appears in
`docs/` or `README.md` keeps its name and its contract.

**`[ ]` → `[[ ]]` quotes the right-hand side.** Inside `[[ ]]` an unquoted RHS
of `=`/`==`/`!=` is a glob pattern, so `[ "$a" = $b ]` and `[[ $a = $b ]]`
differ when `$b` contains `*`. Every converted comparison quotes its RHS unless
a pattern is intended. Numeric comparisons move to `(( ))`.

**`printf` replaces `echo` only where a variable is printed.** A literal string
through `echo` has none of the hazards the rule names.

**Lint enforces the shell half.** `mise.toml` pins `shfmt = "3.14.1"`; the
`lint` task runs shellcheck over every tracked shell file (including
`services/` and `tests/`) and `shfmt -i 2 -ci -d` over the same set. The first
`shfmt -w` lands as its own commit containing nothing else, and its hash goes
into `.git-blame-ignore-revs` if the repository has one (it ships one to
generated projects via `common/`; the toolbox itself gains one, in PR 2, once the rebase-merged hash is final).

**Nothing observable changes.** Error messages, output lines, exit codes and
generated-file contents stay identical, because tests assert them. A test that
has to change because the code changed is evidence of a behaviour change: stop
and fix the code, not the test.

## Work items

Five pull requests, in order, each merged green before the next branches from
`main`:

1. **Tooling** — pin shfmt, widen shellcheck, fix the 30 new shellcheck
   findings, one pure `shfmt -w` commit.
2. **Core** — `.git-blame-ignore-revs`, then `scaffold`, `lib/*.sh`,
   `scripts/*.sh`, `common/install.sh`.
3. **Services** — `services/**/*.sh`.
4. **Tests** — `tests/**` shell (`.bats`, `.bash`, fixture `.sh`).
5. **Non-shell comments** — `adapters/`, `common/`, `.github/`, root
   `mise.toml`, `lefthook.yml`, every other tracked non-doc file.

## Verification

Per PR: `mise run lint`; `mise run test-runner` (both lanes); CI green.
PRs 2, 3 and 5 additionally generate two real projects —
`--api flask --web nextjs --db postgres --cache redis` and
`--api nestjs --db mongodb` — and run each project's `mise run checklist`.
All generated projects and scratch files are deleted afterwards; nothing is
published.

## Not doing

| Item | Why |
| --- | --- |
| Rewrite ADRs or `docs/` prose | dated records and documentation, not code comments |
| Move deleted rationale into new ADRs | a comment that fails the gate is deleted; one that passes stays short |
| Change any `verbatim` or `vendor/` file | provenance check requires byte identity |
| Split functions with no nameable seam | single-use helpers that only move lines add indirection |
