# Sync with upstream immich

When: moving the pinned immich commit forward, or after `.github/workflows/provenance.yml` opens an issue titled "upstream drift detected".

`scripts/check-provenance.sh` diffs every `verbatim` row of `docs/PROVENANCE.md` against the commit pinned in `UPSTREAM`, read from a local clone. It never fetches. `DRIFTED` means the file here differs from that commit.

## Steps

1. Update the local clone. The default path is `~/workspace/playground/immich`; set `SCAFFOLD_UPSTREAM_CLONE` for another.

   ```bash
   git -C ~/workspace/playground/immich fetch origin
   ```

2. To move the pin, write the new commit into `UPSTREAM` as `immich-app/immich@<commit>`. Skip this step when answering a drift issue.

3. Run the check.

   ```bash
   ./scripts/check-provenance.sh
   ```

4. Resolve every `DRIFTED` row with one of three answers.

   | Answer | When | Do |
   | --- | --- | --- |
   | Take upstream | Upstream's version is one this project wants | `git -C <clone> show <commit>:<upstream path> > <file>`; the row stays `verbatim` |
   | Accept the divergence | This project differs on purpose | Change the row to `adapted` and write the reason in its Notes |
   | Not derived | The resemblance was coincidence, checked with `diff` | Change the row to `original` and remove its upstream path; record the check as the "Out of scope, checked and rejected as rows" section does |

5. Run the check again until it exits 0, then commit `UPSTREAM`, `docs/PROVENANCE.md` and any copied file together.

## Verify

```bash
./scripts/check-provenance.sh; echo "exit $?"      # "0 drifted, 0 missing, 0 errors", exit 0
bats tests/provenance.bats
```

## If it fails

| Symptom | Fix |
| --- | --- |
| `no local clone at <path>` | Clone immich there, or set `SCAFFOLD_UPSTREAM_CLONE` |
| `<commit> is not a commit in <clone>` | Step 1: fetch the clone |
| `UPSTREAM (…) is not of the form owner/repo@commit` | Fix the `UPSTREAM` line |
| `MISSING <file>` | A `verbatim` row names a file that no longer exists here. Remove or correct the row |
| `ERROR <file>: could not read <path>` | The upstream path moved at the new commit. Correct the row's upstream path |
| `no verbatim rows found` | The table format broke; `check_verbatim_rows` reads rows starting with a backticked path |
