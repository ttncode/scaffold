# CI is red

CI calls exactly one of the nine contract tasks per failing step (ADR-0011).
Find the task name in the failed step's log, then look here.

| Task | What failing usually means | Where to look |
| --- | --- | --- |
| `install` | Lockfile out of sync with the manifest, or a supply-chain guard tripped (a fresh `minimumReleaseAge` violation, an unapproved native build). | The dependency you (or a dependency's dependency) just bumped; ADR-0017. |
| `format` | Someone committed unformatted code, or ran `format-fix` locally without committing the result. | `git diff` after running the adapter's own `format-fix` task. |
| `format-fix` | Should never run in CI — it writes. If you see it here, the pipeline is miswired. | `common/.github/workflows/ci.yml` / the reusable `app-ci.yml` call. |
| `lint` | A real lint violation, or the lint config itself changed underneath the code. | The step's own output names the file and rule. |
| `check` | A type error, or (Laravel) `phpstan` found something real. | The step's own output; `check` never modifies files, so re-running it locally reproduces exactly what CI saw. |
| `test` | A real test failure, or a test that depends on state a fresh checkout doesn't have. | Re-run the same task locally against a clean clone before assuming CI is wrong. |
| `build` | The app doesn't compile, or a build-time dependency (an env var, a generated file) is missing in CI that exists locally. | Diff what CI's environment provides against your own. |
| `ci-unit` | An aggregate of `install`/`format`/`lint`/`check`/`test` — read which sub-step actually failed; the aggregate name alone doesn't say. | The step's full log, not just its final line. |
| `checklist` | Same as `ci-unit`, plus `build` — this is what `pre-push` runs locally, so a red `checklist` in CI after a clean local run usually means an environment difference, not a code difference. | Compare the CI runner's toolchain (`mise ls` in the job log, if captured) against local `mise ls`. |

Outside the nine tasks: a red `zizmor` job means a workflow file itself has
a static-analysis finding (untrusted input interpolated into a `run:`
block is the common one — see `.github/workflows/adapters.yml`'s own
`env:`-first pattern for the fix). A red `provenance` job's `self-test`
means `scripts/check-provenance.sh` itself regressed, not that upstream
drifted; its `check` job means upstream actually moved — see
`docs/runbook/sync-with-upstream-immich.md`.

## Done when

The failing step's log names a real cause you can point at, not just a
red X — and the fix lands as a task-scoped change (the adapter's `mise.toml`,
the file `lint`/`check` complained about), never as a workflow edit that
papers over what the task actually caught.
