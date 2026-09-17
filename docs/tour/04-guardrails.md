# 04 — Guardrails

## What it does

| Layer | Where | Checks |
| --- | --- | --- |
| Git hooks | `common/lefthook.yml` | prettier and gitleaks at `pre-commit`, commitlint at `commit-msg`, `checklist` at `pre-push` |
| CI | `common/.github/workflows/security.yml` | Calls *you/.github*'s `app-security.yml`; hooks can be skipped with `--no-verify`, CI cannot |
| Renovate | `common/renovate.json` | Opens dependency-bump pull requests that the checks above must pass |
| Ruleset | `lib/publish.sh` | `scaffold publish` protects `main`: pull request required, no deletion, no force push |

## Read this

| File | Why |
| --- | --- |
| `common/lefthook.yml` | The three hook stages |
| `common/commitlint.config.js` | `@commitlint/config-conventional`, nothing custom (ADR-0006) |
| `common/renovate.json` | `config:recommended`, digest pinning, `minimumReleaseAge` of 3 days |
| `lib/publish.sh` | `protect_main`: no required status checks, because their names differ per project |
| `docs/decisions/0007-lefthook-over-husky.md` | lefthook over husky: hooks must work in a PHP-only project |

## Delete test

Delete `common/renovate.json` and a generated project gets no dependency-bump pull requests.
No check fails; dependencies just stop moving.

## Try it

```bash
yq '.pre-commit.commands | keys' common/lefthook.yml
```
