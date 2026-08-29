# Sync with upstream immich

`.github/workflows/provenance.yml` runs `scripts/check-provenance.sh`
monthly against the commit pinned in `UPSTREAM`, and opens an issue titled
"upstream drift detected" when a `verbatim` row in `docs/PROVENANCE.md` no
longer matches. A `DRIFTED` row is not itself a failure — leaving it
`DRIFTED` is.

## 1. Read the diff

The issue body is `check-provenance.sh`'s own output: which file, and the
diff against the pinned commit. Decide which of three responses applies —
there is no fourth.

## 2. Pull the change in

If upstream's edit is one this project should have too (a real bug fix, a
security update), apply it here and leave the row `verbatim`. Re-run the
check to confirm it now reports `ok`.

```bash
SCAFFOLD_UPSTREAM_CLONE=/path/to/immich ./scripts/check-provenance.sh
```

## 3. Accept the divergence

If this project deliberately differs (the usual case — most `verbatim`
files stay that way specifically because they *shouldn't* diverge, but a
change here can still be a considered "no"), reclassify the row `adapted`
in `docs/PROVENANCE.md` and record the reason next to it, same as every
other `adapted` row already does.

## 4. Reclassify as never having been a real comparison

Rare: if the resemblance to upstream was coincidental rather than derived,
reclassify `original` and remove the "Upstream path" claim. Verify with
`diff` first — `docs/PROVENANCE.md`'s own "Out of scope, checked and
rejected as rows" section is the model for how to record that check.

## 5. Bump `UPSTREAM`

Once every drifted row is resolved, update `UPSTREAM` to the commit you
diffed against, so the next monthly run starts from here, not from the
older pin.

## Done when

`scripts/check-provenance.sh` exits 0, and every row that changed
classification this round says why in `docs/PROVENANCE.md`, not just what.
