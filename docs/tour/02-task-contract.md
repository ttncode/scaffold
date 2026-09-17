# 02 — Task contract

## What it does

- Every adapter implements nine `mise` tasks: `install`, `format`, `format-fix`, `lint`, `check`, `test`, `build`, `ci-unit`, `checklist`.
- CI runs the same task names in every config root, whatever the language.
- `format`, `lint` and `check` only report; `scaffold lint` rejects a writing flag (`--write`, `--fix`, …) in them.
- Names follow immich (ADR-0011).

## Read this

| File | Why |
| --- | --- |
| `lib/contract.sh` | `CONTRACT_TASKS`, `READ_ONLY_TASKS`, `WRITING_FLAGS`, `REQUIRED_ADAPTER_FILES` |
| `lib/lint.sh` | `lint_adapters`: required files, `adapter.env` variables, the nine tasks, read-only tasks |
| `adapters/nestjs/mise.toml` | One full implementation: `check` runs `tsc --noEmit`, `format-fix` writes |

## Delete test

Remove one name from `CONTRACT_TASKS` and `tests/contract.bats` fails:
"the contract has exactly nine task names".

## Try it

```bash
./scaffold lint
```
