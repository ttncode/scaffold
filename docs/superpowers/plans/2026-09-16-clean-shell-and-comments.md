# Clean Shell and Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every tracked file meets `comment-code`; every shell file meets the Clean Bash rules; lint keeps it that way.

**Architecture:** five independent pull requests by area, each merged before the next branches. No behaviour change anywhere; the existing bats suites and real-project checklists are the regression net.

**Tech Stack:** bash 5, shellcheck 0.11.0, shfmt 3.14.1, bats 1.13.0, mise.

**Spec:** `docs/superpowers/specs/2026-09-16-clean-shell-and-comments-design.md`

## Global Constraints

- Rules: the `comment-code` skill (`~/.claude/skills/comment-code/SKILL.md`) and `~/.dotfiles/agentic/rules/bash.md`. Read both before editing.
- No behaviour change: error messages, stdout/stderr lines, exit codes and generated-file contents stay byte-identical. Never edit a test assertion to make a code change pass.
- No file-level `readonly`; `local -r` inside functions is fine.
- No `set -euo pipefail` added to sourced files (`lib/*.sh`, `services/**/*.sh`, `tests/helpers/*.bash`, fixture drivers). Executables (`scaffold`, `scripts/*.sh`, `common/install.sh`) must have it.
- Bats `@test` bodies keep `[ … ]`; helpers and non-test shell use `[[ ]]` / `(( ))`.
- `[ ]` → `[[ ]]`: quote the RHS of `=`, `==`, `!=` unless a glob is intended. Numeric tests → `(( ))`.
- `echo` → `printf '%s\n'` only where a variable/expansion is printed.
- Never `local x="$(cmd)"`: declare, then assign.
- Split a function over 20 lines only at a nameable seam. Linear sequences (big `case`, heredoc, render loop) stay; record each kept function and why in the task report.
- Function names that appear in `docs/` or `README.md` keep their name and contract: `add_app_service apply_adapter apply_service_dockerfile apply_service_drivers assemble_compose assert_known_tiers cmd_add cmd_new cmd_wizard config_roots generate_service_passwords init_project lint_adapters lint_services load_adapter load_toolchain_env project_name_is_usable register_config_root register_image_target role_path service_compose_key service_driver_dockerfile service_healthy sync_ci_roots tui_name_is_usable tui_prompt_name wizard_actions wizard_command wizard_new_args wizard_options wizard_prompt_for wizard_questions write_env_lines splice_flask_probe init_flask_alembic assert_nest_probe_spliced`.
- Keep: `#!` lines, `# shellcheck …` pragmas (each carrying a same-line reason), `# noqa`, `eslint-disable`, `@phpstan-`, `ponytail:` markers, and splice anchors `# @SERVICE_SETUP@`, `# @DB_ENGINE@`, `# @DB_PROBE@` (column and spelling are matched by awk/sed).
- Do not touch: `verbatim` rows of `docs/PROVENANCE.md` (`common/.editorconfig`), `common/docs/.vitepress/theme/vendor/**`, `docs/**`, `*.md`, `LICENSE`, `mise.lock`, `UPSTREAM`.
- Script headers: purpose + usage only. No `Description :`/`Author`/banner blocks.
- Commits: conventional (`chore:`, `refactor:`, `style:`), no co-author noise beyond repo convention. Each PR from a fresh branch off up-to-date `main`.
- Verification per PR: `mise run lint` clean; `mise run test-runner` exits 0.
- Real-project check (Tasks 2, 3, 5): in the scratchpad, `./scaffold new <dir>/p1 --api flask --web nextjs --db postgres --cache redis` and `./scaffold new <dir>/p2 --api nestjs --db mongodb`, then `mise run checklist` inside each. Delete both afterwards. Never run `scaffold publish`.

---

### Task 1: Tooling

**Files:**
- Modify: `mise.toml` (`[tools]`, `[tasks.lint]`)
- Modify: `services/**/*.sh`, `tests/helpers/setup.bash`, `tests/**/*.sh` (shellcheck findings only)
- Modify: every shell file (the `shfmt -w` commit)

- [ ] **Step 1:** add `shfmt = "3.14.1"` under `[tools]`, run `mise install` so `mise.lock` records it.
- [ ] **Step 2:** change `[tasks.lint]` to lint every tracked shell file with both tools:
  ```toml
  [tasks.lint]
  run = [
    "git ls-files -z -- scaffold '*.sh' '*.bash' '*.bats' | xargs -0 -r shellcheck",
    "git ls-files -z -- scaffold '*.sh' '*.bash' '*.bats' | xargs -0 -r shfmt -i 2 -ci -d",
  ]
  ```
  Shrink the task's existing comment to what still holds (the `git ls-files` discovery rationale), or delete it.
- [ ] **Step 3:** run `mise run lint`; expect shellcheck findings in `services/`, `tests/` and `.bats` files. Fix each: real bugs get fixed; intentional ones (e.g. SC2016 single-quoted `$` written into generated code) get `# shellcheck disable=SCxxxx # <reason>` on the narrowest scope. SC1091/SC1090 for sourced paths: prefer a `# shellcheck source=` directive over disable. Commit: `chore(lint): shellcheck every tracked shell file`.
- [ ] **Step 4:** `git ls-files -z -- scaffold '*.sh' '*.bash' '*.bats' | xargs -0 shfmt -i 2 -ci -w`. Verify `git diff -w --stat` is empty or whitespace-only in meaning (e.g. `die() { a; b; }` expanded to multiple lines is fine). Run `mise run test-runner`. Commit ONLY this: `style: shfmt -i 2 -ci every shell file`.
- [ ] **Step 5:** `mise run lint` exits 0; `mise run test-runner` exits 0. Push, open PR, wait for CI, merge with `gh pr merge --rebase --delete-branch` (not squash: squash would fold the pure shfmt commit into the lint fixes).

### Task 2: Core — `scaffold`, `lib/*.sh`, `scripts/*.sh`, `common/install.sh`

**Files:** those 17 files. `common/install.sh` ships to every generated project.

- [ ] **Step 0:** find the shfmt commit on `main` (`git log --format='%H %s' | grep 'style: shfmt'`) and create `.git-blame-ignore-revs` with that hash under a one-line `#` comment naming its subject. A rebase merge rewrites hashes, which is why this waits until Task 1 is on `main`.
- [ ] **Step 1:** file by file, apply the Global Constraints: delete comments that fail the gate; shorten the ones that pass; convert tests/`echo`/`local`/`let`/`expr`; name positional args into locals; fix headers (`scripts/check-provenance.sh` has a banner-style `# Description :` header).
- [ ] **Step 2:** split functions over 20 lines at nameable seams. Candidates by size: `cmd_add` (68), `tui_select` (55), `record_release_age_exceptions` (55), `cmd_wizard` (51), `add_app_service` (49), `apply_adapter` (49), `cmd_update` (47), `cmd_publish` (42), `lint_adapter_env` (40), `_tui_render` (39). List all with `awk 'FNR==1{fn=""} /^[a-z_]+\(\) \{/{fn=$1;s=FNR} fn&&/^\}/{if(FNR-s-1>20)print FNR-s-1, FILENAME, fn;fn=""}' scaffold lib/*.sh scripts/*.sh common/install.sh`.
- [ ] **Step 3:** after each file or two, `mise run test-unit`; commit per file group (`refactor(lib): …`).
- [ ] **Step 4:** `mise run lint`, `mise run test-runner`, real-project check. Push, PR, CI green, `gh pr merge --squash --delete-branch`.

### Task 3: Services — `services/**/*.sh`

- [ ] **Step 1:** same treatment as Task 2 for the 15 driver and shared files. The splice guards (`assert_nest_probe_spliced`, the flask guard in `splice_flask_probe`) keep their logic exactly; their comments may shrink but the reason a guard checks the *absence* of the fallback must survive in one line.
- [ ] **Step 2:** `mise run lint`, `mise run test-runner`, real-project check. PR, CI, squash-merge.

### Task 4: Tests — `tests/**` shell

- [ ] **Step 1:** comments and helpers in `.bats`, `tests/helpers/setup.bash`, fixture `.sh`. Test names (`@test "…"`) are unchanged. Fixture drivers under `tests/fixtures/lint-services/` exist to be *wrong* in one specific way each — keep the defect each fixture is named for.
- [ ] **Step 2:** `mise run lint`, `mise run test-runner`. PR, CI, squash-merge.

### Task 5: Non-shell comments

**Files:** every tracked file outside Tasks 1–4 that carries comments, excluding the do-not-touch list. List with:
`git ls-files | grep -vE '\.(sh|bash|bats|md|lock)$|^docs/|^tests/|vendor/|^scaffold$|^LICENSE$|^UPSTREAM$|^common/\.editorconfig$' | xargs grep -lE '^\s*(#|//|/\*|\*|<!--)'`

- [ ] **Step 1:** apply `comment-code` only (no code changes beyond what makes a deleted comment unnecessary). Comments inside files copied into generated projects (`adapters/`, `common/`) are read by client developers: keep the ones that explain a non-obvious choice they would otherwise undo.
- [ ] **Step 2:** `mise run lint`, `mise run test-runner`, real-project check. PR, CI, squash-merge.
