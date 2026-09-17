# Rotate a leaked secret

When: a secret reached a pushed commit, past gitleaks at `pre-commit` (`common/lefthook.yml`) and in CI.

Rotate first, rewrite history second: a rotated secret makes every copy worthless, including clones history rewriting cannot reach.

## Steps

1. Rotate the credential.
   - A third-party key or token: revoke and reissue it at the provider.
   - A service password from `install.sh` (`DB_PASSWORD`, `REDIS_PASSWORD`): change it inside the running service first. The database images read `DB_PASSWORD` only when their volume is empty, so editing `.env` alone locks the apps out.

     ```bash
     cd app
     docker compose exec database psql -U app -d app -c "ALTER USER app PASSWORD '<new>'"   # postgres
     docker compose exec database mysql -uroot -p -e "ALTER USER 'app'@'%' IDENTIFIED BY '<new>'; ALTER USER 'root'@'%' IDENTIFIED BY '<new>'; ALTER USER 'root'@'localhost' IDENTIFIED BY '<new>'"   # mysql
     docker compose exec database mongosh -u app -p --authenticationDatabase admin --eval "db.getSiblingDB('admin').changeUserPassword('app', '<new>')"   # mongodb
     ```

     `redis` reads `REDIS_PASSWORD` on every start and needs no command.

2. Put the new value in `.env` and restart.

   ```bash
   docker compose up -d
   docker compose ps          # every service healthy before step 3 rewrites history
   ```

3. Remove the secret from history with `git filter-repo` or BFG Repo-Cleaner, force-push, and have every collaborator re-clone.

4. If gitleaks did not flag the leak, add a rule for that secret's shape, or the next bypassed hook leaks it again.

## Verify

```bash
docker compose ps                     # every service healthy
mise run secrets                      # in the project: gitleaks over the whole history
```

- The old credential is refused wherever it was used.

## If it fails

| Symptom | Fix |
| --- | --- |
| Apps fail to connect after the restart | The password inside the database was not changed. Run the step 1 command with the old password, or restore the old `.env` value and repeat step 1 |
| `mise run secrets` still reports the secret | History still holds it. Repeat step 3 |
