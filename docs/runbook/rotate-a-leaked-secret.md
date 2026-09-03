# Rotate a leaked secret

gitleaks runs at `pre-commit` locally (`common/lefthook.yml`) and again in
CI, so most leaks never reach a pushed commit. This runbook is for the one
that does anyway — a hook bypassed with `--no-verify`, or a secret that
predates the hook being installed.

Rotate first, rewrite history second. A rotated secret makes every leaked
copy worthless immediately, including ones already cloned or cached
somewhere history rewriting can't reach; rewriting history first, with the
old secret still valid, leaves a window where anyone who already has the
commit still has a working credential.

## 1. Rotate the credential

The database password is the one this toolbox generates for you
(`install.sh`'s `generate_service_passwords`): change `DB_PASSWORD` in the
affected host's `.env` to a new value and restart the stack —
`docker compose up -d` picks up the new value without touching the
`database` volume's existing data. For any other leaked credential (a
third-party API key, a registry token), rotate it at the provider first.

## 2. Confirm the new credential works

Restart the affected service and verify it comes up healthy against the
new value before touching git history — there's no reason to rewrite
history for a secret that turned out not to matter yet, or to discover the
new credential is wrong only after history is already rewritten.

## 3. Remove the secret from history

Only now: `git filter-repo` (or the BFG Repo-Cleaner) to strip the commit
that introduced it, then force-push the rewritten history and have every
collaborator re-clone rather than merge.

## 4. Add a gitleaks rule if this shape wasn't caught

If gitleaks didn't flag the leak (a secret shape it doesn't recognize by
default), that's the real gap — a rotated secret fixes this one incident,
but the same shape leaks again the next time someone bypasses the hook.

## Done when

The old credential no longer works anywhere, the new one is confirmed
live, and the leaked commit is gone from every remaining clone of the
repository.
