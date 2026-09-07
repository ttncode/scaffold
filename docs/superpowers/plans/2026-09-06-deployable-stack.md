# Deployable Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a freshly generated project serve HTTP on the port its
`compose.yaml` publishes, reach its database through the environment the
released stack hands it, and prove both in CI.

**Architecture:** Every adapter serves on container port 8080 and declares two
paths — a liveness path its `HEALTHCHECK` probes, and a readiness path that
runs one query. The Laravel runtime stages move to FrankenPHP so something
answers HTTP at all. The application's connection variables are composed in
`compose.yaml` from the service variables already in `.env`, written by the
service driver, which is the only thing that knows both the service and the
adapter family. A tier-gated CI job starts the stack and curls both paths.

**Tech Stack:** bash, `yq`, `jq`, `mise`, `bats`, Docker Compose, FrankenPHP
(Caddy + embedded PHP), Prisma (Nest), Eloquent (Laravel).

**Spec:** `docs/superpowers/specs/2026-09-06-deployable-stack-design.md`

## Global Constraints

- Chat is Vietnamese; **every file, comment, commit message and document is
  English**.
- Comment style follows immich and the surrounding repository: explain *why*,
  never *what*. No comment asserts that a mechanism "always" does something
  unless a check enforces it.
- Tests must stay isolated. A test that modifies the toolbox uses
  `copy_toolbox` (`tests/helpers/setup.bash`) — never the real tree. Slow is
  acceptable; interdependent is not.
- **Run only the suites your change touches.** `bats tests/<suite>.bats`, or
  `--filter <name>` for one test. Capture output to a file once and grep the
  file rather than re-running to count. The full lane runs in CI.
- `docker run` is denied by this environment's permission policy.
  `docker build` and `docker compose up -d` are available — every container
  verification in this plan uses compose.
- Container port is **8080** for every adapter. `common/compose.yaml` stays as
  it is.
- The FrankenPHP base image is
  `dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:049b8d8356efceb93c91ed42866de890534310bcef4ad4dde902029e4a0d20c3`,
  verified against the registry on 2026-09-06. **Alpine, not bookworm**:
  `services/mongodb/drivers/laravel.sh` emits `apk add`.
- Every image reference is pinned by digest (`tests/compose.bats` enforces it).
- Run `mise run lint` (shellcheck) before every commit.
- Work on branch `feat/deployable-stack`, cut from `spec/deployable-stack`.

## File Structure

**Created:**

| Path | Responsibility |
| --- | --- |
| `adapters/nestjs/src/health/health.controller.ts` | liveness and readiness routes for Nest |
| `adapters/nestjs/src/health/health.module.ts` | wires the controller into `AppModule` |
| `adapters/nextjs/src/app/api/health/live/route.ts` | liveness route for Next |
| `adapters/laravel-api/routes/health.php` | readiness route for the API skeleton |
| `adapters/laravel-inertia/routes/health.php` | readiness route for the starter kit |
| docs/decisions/0021-the-released-stack-must-run.md | records this design |

**Modified:**

| Path | Change |
| --- | --- |
| `adapters/*/adapter.env` | `ADAPTER_LIVENESS_PATH`, `ADAPTER_READINESS_PATH` |
| `adapters/nextjs/Dockerfile`, `.workspace` | `ENV PORT=8080`, `EXPOSE 8080`, healthcheck |
| `adapters/nestjs/Dockerfile`, `.workspace` | the same, and a path that exists |
| `adapters/laravel-api/Dockerfile` | FrankenPHP runtime stage |
| `adapters/laravel-inertia/Dockerfile` | the same, plus `public/build` ordering |
| `adapters/laravel-inertia/.dockerignore` | `public/build` |
| `adapters/nestjs/mise.toml` | a `migrate` task branching on the Prisma provider |
| `lib/contract.sh` | the two new adapter vars, the new driver hook |
| `lib/lint.sh` | enforce them |
| `lib/service.sh` | `service_driver_compose_env`, `apply_service_compose_env` |
| `services/*/drivers/*.sh` | emit the family's environment block and DB probe |
| `services/mongodb/drivers/laravel.sh` | pin `mongodb/mongodb` to the extension |
| `common/install.sh` | generate `APP_KEY`; run the migration task once |
| `common/example.env` | nothing — `APP_KEY` is appended by the driver |
| `.github/workflows/adapters.yml` | the `deploy` gate |
| `tests/compose.bats` | port, healthcheck and declared-path assertions |
| `tests/contract.bats` | the new required vars and driver hook |
| `tests/service.bats` | the emitted compose block |
| `docs/decisions/0003-*`, `0014-*` | the boundaries this moves |
| `docs/tour/07-containers.md` | its worked example becomes false |
| `docs/runbook/first-project-walkthrough.md` | step 10 becomes "run it" |

---

### Task 0: Branch

- [ ] **Step 1: Cut the branch**

```bash
cd /home/ttndev/workspace/personal/scaffold
git checkout spec/deployable-stack
git checkout -b feat/deployable-stack
```

- [ ] **Step 2: Confirm the starting point is clean**

Run: `git status --porcelain`
Expected: no output.

---

### Task 1: Adapters declare their liveness and readiness paths

The gate and the `HEALTHCHECK` must read the path from one place. `nestjs`
probes `/health` today and nothing serves it; that defect exists because the
Dockerfile's idea of the route and the application's idea of it were never
required to agree.

**Files:**
- Modify: `lib/contract.sh`, `lib/lint.sh`, `adapters/*/adapter.env`
- Test: `tests/contract.bats`

**Interfaces:**
- Produces: `ADAPTER_LIVENESS_PATH` (every adapter) and
  `ADAPTER_READINESS_PATH` (only adapters whose role is in `DRIVEN_ROLES`),
  both read by `lib/lint.sh`, `tests/compose.bats` and the CI gate.

- [ ] **Step 1: Write the failing test**

Append to `tests/contract.bats`:

```bash
@test "every adapter declares a liveness path" {
  local missing=""
  for dir in "${SCAFFOLD_ROOT}"/adapters/*/; do
    grep -q '^ADAPTER_LIVENESS_PATH=' "${dir}adapter.env" \
      || missing="${missing}$(basename "$dir")"$'\n'
  done
  [ -z "$missing" ] || { echo "missing ADAPTER_LIVENESS_PATH:"; echo "$missing"; false; }
}

@test "an adapter whose role takes a driver declares a readiness path" {
  # a web adapter opens no connection (DRIVEN_ROLES), so it has nothing to
  # probe; anything else must, or the deploy gate has no way to prove the
  # application actually reaches its database.
  local missing=""
  for dir in "${SCAFFOLD_ROOT}"/adapters/*/; do
    role="$(grep '^ADAPTER_ROLE=' "${dir}adapter.env" | cut -d'"' -f2)"
    case " ${DRIVEN_ROLES[*]} " in *" ${role} "*) ;; *) continue ;; esac
    grep -q '^ADAPTER_READINESS_PATH=' "${dir}adapter.env" \
      || missing="${missing}$(basename "$dir")"$'\n'
  done
  [ -z "$missing" ] || { echo "missing ADAPTER_READINESS_PATH:"; echo "$missing"; false; }
}
```

`tests/contract.bats` already sources `lib/contract.sh` in its `setup`; if it
does not, add `. "${SCAFFOLD_ROOT}/lib/contract.sh"` there so `DRIVEN_ROLES`
resolves.

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- bats --filter 'liveness path|readiness path' tests/contract.bats`
Expected: both FAIL, listing all four adapters.

- [ ] **Step 3: Declare the paths**

`adapters/nextjs/adapter.env` — append:

```sh
# create-next-app generates no health route, and the web tier opens no
# database connection, so `/` is both the only thing it serves and the whole
# of what there is to check.
ADAPTER_LIVENESS_PATH="/"
```

`adapters/nestjs/adapter.env` — append:

```sh
# The generator produces `/` returning Hello World and nothing else. Both of
# these are routes this adapter ships itself (src/health/), because the
# Dockerfile's HEALTHCHECK has been probing a /health that never existed.
ADAPTER_LIVENESS_PATH="/health/live"
ADAPTER_READINESS_PATH="/health/ready"
```

`adapters/laravel-api/adapter.env` and `adapters/laravel-inertia/adapter.env`
— append to each:

```sh
# /up ships with laravel since 11.x and deliberately touches nothing, which
# is why it cannot stand alone: a project with a wrong DATABASE_URL passes it.
ADAPTER_LIVENESS_PATH="/up"
ADAPTER_READINESS_PATH="/health/ready"
```

- [ ] **Step 4: Enforce them in lint**

In `lib/contract.sh`, add to `REQUIRED_ADAPTER_VARS`:

```sh
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_FAMILY ADAPTER_GENERATOR ADAPTER_LIVENESS_PATH)
```

`ADAPTER_READINESS_PATH` is conditional on the role, so it cannot go in that
list. In `lib/lint.sh`, inside the per-adapter loop that already reports
missing vars, add:

```sh
  # Conditional on the role rather than required outright: a web adapter has
  # no connection to probe, and demanding a readiness path from it would only
  # produce one that returns 200 without doing anything.
  case " ${DRIVEN_ROLES[*]} " in
    *" ${ADAPTER_ROLE} "*)
      [ -n "${ADAPTER_READINESS_PATH:-}" ] \
        || fail "${name}: ADAPTER_READINESS_PATH is required for role ${ADAPTER_ROLE}" ;;
  esac
```

Add `ADAPTER_READINESS_PATH` and `ADAPTER_LIVENESS_PATH` to the `unset -v`
list in `load_adapter` (`lib/adapter.sh`), beside `ADAPTER_FAMILY`, so a
second `load_adapter` in one process cannot inherit the previous adapter's
value.

- [ ] **Step 5: Run the tests**

Run: `mise exec -- bats tests/contract.bats && mise exec -- ./scaffold lint`
Expected: all PASS, `lint` silent, exit 0.

- [ ] **Step 6: Commit**

```bash
git add lib/contract.sh lib/lint.sh lib/adapter.sh adapters/*/adapter.env tests/contract.bats
git commit -m "feat: let an adapter declare the paths its health checks probe"
```

---

### Task 2: The TypeScript adapters serve on 8080

**Files:**
- Create: `adapters/nestjs/src/health/health.controller.ts`,
  `adapters/nestjs/src/health/health.module.ts`,
  `adapters/nextjs/src/app/api/health/live/route.ts`
- Modify: `adapters/nestjs/Dockerfile`, `adapters/nestjs/Dockerfile.workspace`,
  `adapters/nextjs/Dockerfile`, `adapters/nextjs/Dockerfile.workspace`,
  `adapters/nestjs/adapter.env`
- Test: `tests/compose.bats`

**Interfaces:**
- Consumes: `ADAPTER_LIVENESS_PATH` from Task 1.
- Produces: `GET /health/live` on Nest returning `{"status":"ok"}`; both
  TypeScript images listening on 8080.

- [ ] **Step 1: Write the failing test**

Append to `tests/compose.bats`:

```bash
@test "every adapter Dockerfile serves the port compose publishes" {
  # common/compose.yaml publishes ${APP_PORT:-8080}:8080 and nothing rewrites
  # it, so an adapter exposing anything else publishes a dead port.
  run bash -c "grep -L '^EXPOSE 8080\$' '${SCAFFOLD_ROOT}'/adapters/*/Dockerfile*"
  [ -z "$output" ] || { echo "not exposing 8080:"; echo "$output"; false; }
}

@test "every adapter Dockerfile probes the liveness path its adapter declares" {
  # nestjs probed /health for months while the generator produced only `/`.
  # The Dockerfile's idea of the route and the adapter's must be one value.
  local wrong=""
  for dir in "${SCAFFOLD_ROOT}"/adapters/*/; do
    path="$(grep '^ADAPTER_LIVENESS_PATH=' "${dir}adapter.env" | cut -d'"' -f2)"
    for file in "${dir}"Dockerfile "${dir}"Dockerfile.workspace; do
      [ -f "$file" ] || continue
      grep -q "HEALTHCHECK" "$file" \
        || { wrong="${wrong}${file}: no HEALTHCHECK"$'\n'; continue; }
      grep -q "localhost:8080${path}" "$file" \
        || wrong="${wrong}${file}: does not probe ${path} on 8080"$'\n'
    done
  done
  [ -z "$wrong" ] || { echo "$wrong"; false; }
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- bats --filter 'port compose publishes|liveness path its adapter' tests/compose.bats`
Expected: both FAIL — six Dockerfiles on the first, all six on the second
(the Laravel pair have no `HEALTHCHECK` at all).

- [ ] **Step 3: Ship the Nest health routes**

Create `adapters/nestjs/src/health/health.controller.ts`:

```ts
import { Controller, Get, HttpException, HttpStatus } from '@nestjs/common';

@Controller('health')
export class HealthController {
  @Get('live')
  live(): { status: string } {
    return { status: 'ok' };
  }

  // The probe is written by the selected service's driver: prisma has no
  // provider-agnostic read, so a SQL provider gets $queryRawUnsafe and
  // mongodb gets $runCommandRaw. A project generated with --db none keeps
  // the anchor's fallback and reports 503, because there is nothing here
  // that could honestly report ready.
  @Get('ready')
  async ready(): Promise<{ status: string }> {
    try {
      // @DB_PROBE@
      throw new Error('no database is configured for this project');
    } catch (error) {
      throw new HttpException(
        { status: 'unavailable', reason: (error as Error).message },
        HttpStatus.SERVICE_UNAVAILABLE,
      );
    }
  }
}
```

Create `adapters/nestjs/src/health/health.module.ts`:

```ts
import { Module } from '@nestjs/common';

import { HealthController } from './health.controller';

@Module({ controllers: [HealthController] })
export class HealthModule {}
```

Wire it in. `apply_adapter` copies only top-level adapter files, so the
`src/health/` directory needs `ADAPTER_POST_GENERATE` to place it and to
register the module. Extend `adapters/nestjs/adapter.env`'s existing
`ADAPTER_POST_GENERATE` (do not add a second one — the variable is read once):

```sh
ADAPTER_POST_GENERATE='sed -i "s/^bootstrap();$/void bootstrap();/" src/main.ts && sed -i "1i import { HealthModule } from '"'"'./health/health.module'"'"';" src/app.module.ts && sed -i "s/imports: \[\]/imports: [HealthModule]/" src/app.module.ts && pnpm exec prettier --write .'
```

The `src/health/` files themselves are copied by a new directory case in
`apply_adapter` — see Step 4.

- [ ] **Step 4: Let an adapter ship a directory**

`apply_adapter` (`lib/adapter.sh`) special-cases `docker/` and skips every
other directory. Replace that single case with a loop over every directory
the adapter ships, so a route file does not need a second mechanism:

```sh
  # Every directory the adapter ships, merged into the generated tree rather
  # than replacing what is there: `src/` already exists after the generator
  # ran, and `cp -R src dest/src` would nest it as dest/src/src.
  local dir
  for dir in "${ADAPTER_DIR}"/*/; do
    [ -d "$dir" ] || continue
    mkdir -p "${dest}/$(basename "$dir")"
    cp -R "${dir}." "${dest}/$(basename "$dir")/"
  done
```

Delete the `[ -d "${ADAPTER_DIR}/docker" ] && cp -R …` line it replaces.

- [ ] **Step 5: Ship the Next liveness route**

Create `adapters/nextjs/src/app/api/health/live/route.ts`:

```ts
export const dynamic = 'force-dynamic';

export function GET(): Response {
  return Response.json({ status: 'ok' });
}
```

Change `adapters/nextjs/adapter.env`'s `ADAPTER_LIVENESS_PATH` to
`/api/health/live` and say why in the comment: a route handler answers
without rendering the home page, so the probe does not depend on whatever the
client later puts on `/`.

- [ ] **Step 6: Move both images to 8080**

In all four TypeScript Dockerfiles, replace the `EXPOSE`, `HEALTHCHECK` and
add `ENV PORT`:

`adapters/nestjs/Dockerfile` and `adapters/nestjs/Dockerfile.workspace`, in
the runtime stage:

```dockerfile
# 8080 because that is the container port common/compose.yaml publishes, and
# nothing rewrites it — an adapter listening anywhere else publishes a dead
# port. Nest reads PORT in main.ts's `app.listen(process.env.PORT ?? 3000)`.
ENV PORT=8080
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/health/live || exit 1
```

`adapters/nextjs/Dockerfile` and `adapters/nextjs/Dockerfile.workspace`, in
the runtime stage — the same `ENV PORT=8080` and `EXPOSE 8080`, with:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/api/health/live || exit 1
```

- [ ] **Step 7: Run the static tests**

Run: `mise exec -- bats tests/compose.bats > /tmp/compose.log 2>&1; tail -20 /tmp/compose.log`
Expected: every test PASS.

- [ ] **Step 8: Prove it serves, with a real container**

```bash
mkdir -p /tmp/dsverify && cd /tmp/dsverify
scaffold() ( eval "$(mise env -C /home/ttndev/workspace/personal/scaffold -s bash)"
             /home/ttndev/workspace/personal/scaffold/scaffold "$@" )
scaffold new t2 --api nestjs --db postgres
cd t2
ctx="$(grep -E '^      context:' .github/workflows/build.yml | head -1 | sed 's/.*context: *//')"
df="$(grep -E '^      dockerfile:' .github/workflows/build.yml | head -1 | sed 's/.*dockerfile: *//')"
docker build -f "$df" -t dsverify/t2:local "$ctx"
sed -i 's|ghcr.io/CHANGEME/CHANGEME:${IMAGE_TAG:-latest}|dsverify/t2:local|' compose.yaml
cp example.env .env
docker compose up -d
sleep 20
docker compose ps
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/health/live
docker compose down -v
```

Expected: `docker compose ps` shows the app container `Up`, and the `curl`
prints `200`. `/health/ready` is expected to return 503 at this point —
Task 5 is what makes it 200.

- [ ] **Step 9: Commit**

```bash
git add adapters/nestjs adapters/nextjs lib/adapter.sh tests/compose.bats
git commit -m "feat: serve the port compose publishes, on a route that exists"
```

---

### Task 3: The Laravel images serve HTTP

**Files:**
- Modify: `adapters/laravel-api/Dockerfile`,
  `adapters/laravel-inertia/Dockerfile`,
  `adapters/laravel-inertia/.dockerignore`
- Test: `tests/compose.bats` (already written in Task 2)

**Interfaces:**
- Consumes: `ADAPTER_LIVENESS_PATH="/up"` from Task 1.
- Produces: both Laravel images listening on 8080 with a working
  `HEALTHCHECK`.

- [ ] **Step 1: Confirm the tests still fail for these two**

Run: `mise exec -- bats --filter 'liveness path its adapter' tests/compose.bats`
Expected: FAIL, naming only the two Laravel Dockerfiles.

- [ ] **Step 2: Replace the laravel-api runtime stage**

In `adapters/laravel-api/Dockerfile`, replace the whole runtime stage —
`FROM php:…` through `CMD ["php-fpm"]` — with:

```dockerfile
# FrankenPHP, because php-fpm speaks FastCGI and this stack has no web server
# in front of it: nothing served HTTP at all, and compose published a dead
# port. Documented as a first-class server in laravel.com/docs/13.x/deployment,
# part of the PHP Foundation since May 2025, and what Laravel Cloud runs.
# Alpine specifically: services/mongodb/drivers/laravel.sh emits `apk add`.
FROM dunglas/frankenphp:1.12.7-php8.3-alpine@sha256:049b8d8356efceb93c91ed42866de890534310bcef4ad4dde902029e4a0d20c3 AS runtime
RUN docker-php-ext-install opcache
# @SERVICE_SETUP@
WORKDIR /var/www
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY docker/opcache.ini /usr/local/etc/php/conf.d/opcache.ini
# :8080 is how frankenphp listens on an unprivileged port and declines to
# provision TLS, which belongs to whatever proxy this lands behind.
ENV SERVER_NAME=:8080
# Caddy writes here and will not start if it may not. The app tree needs the
# same: COPY runs as root, the server runs as www-data, and the first request
# that compiles a blade view or writes a log fails without this.
ENV XDG_CONFIG_HOME=/config XDG_DATA_HOME=/data
RUN mkdir -p /config /data \
 && chown -R www-data:www-data /config /data \
      /var/www/storage /var/www/bootstrap/cache
USER www-data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget -qO- http://localhost:8080/up || exit 1
CMD ["frankenphp", "run"]
```

Delete the long "no healthcheck is possible" comment. Its reasoning — that a
check which cannot fail is worse than none — was right and is preserved in
decision record 0021; what it concluded stopped being true the moment something served
HTTP.

- [ ] **Step 3: Do the same for laravel-inertia, and fix the asset ordering**

Apply the identical runtime stage to `adapters/laravel-inertia/Dockerfile`,
with one difference: `COPY . .` must run **before** the assets copy, so a
developer's locally built `public/build` cannot layer over the image's:

```dockerfile
COPY --from=vendor /app/vendor ./vendor
COPY . .
COPY --from=assets /app/public/build ./public/build
```

Add to `adapters/laravel-inertia/.dockerignore`:

```
# vite writes this and .gitignore excludes it, but a build context is not a
# git tree: without this line a developer who has run `npm run build` ships
# their host copy over the one the assets stage just built. Same shape as the
# bootstrap/cache manifests two lines up.
public/build
```

- [ ] **Step 4: Run the static tests**

Run: `mise exec -- bats tests/compose.bats > /tmp/compose.log 2>&1; tail -20 /tmp/compose.log`
Expected: every test PASS, including the digest test — the FrankenPHP
reference is pinned.

- [ ] **Step 5: Prove laravel-api serves**

```bash
cd /tmp/dsverify
scaffold new t3 --api laravel-api --db postgres
cd t3
docker build -f apps/api/Dockerfile -t dsverify/t3:local apps/api
sed -i 's|ghcr.io/CHANGEME/CHANGEME:${IMAGE_TAG:-latest}|dsverify/t3:local|' compose.yaml
cp example.env .env
docker compose up -d
sleep 25
docker compose ps
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/up
docker compose logs app | tail -20
docker compose down -v
```

Expected: `curl` prints `200`. If it prints a connection error, read
`docker compose logs app` before changing anything — Caddy names the reason
it would not start.

- [ ] **Step 6: Prove laravel-inertia serves, and serves its assets**

Repeat Step 5 with `scaffold new t3b --app laravel-inertia --db postgres`,
`apps/app`, and additionally:

```bash
asset="$(docker compose exec -T app sh -c 'ls public/build/assets/*.js | head -1')"
curl -fsS -o /dev/null -w '%{http_code}\n' "http://localhost:8080/${asset#public/}"
```

Expected: both `curl`s print `200`. The second is what separates a working
answer from one that serves PHP and 404s every asset.

- [ ] **Step 7: Commit**

```bash
git add adapters/laravel-api adapters/laravel-inertia
git commit -m "feat: put an http server in the laravel images"
```

---

### Task 4: The driver writes the app's connection environment

**Files:**
- Modify: `lib/service.sh`, `lib/contract.sh`, `lib/lint.sh`
- Test: `tests/service.bats`, `tests/contract.bats`

**Interfaces:**
- Produces: `service_driver_compose_env` — a driver hook printing YAML lines
  for `services.app.environment`, and `apply_service_compose_env <project>
  <block>` which merges them into `compose.yaml`. Task 5 implements the hook
  in each driver; Task 6 relies on the merged result.

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "a driver's compose environment interpolates rather than embedding a password" {
  # The password must exist in exactly one place — .env — so compose composes
  # the URL at `up` time. A literal baked here is the changeme-versus-app
  # mismatch that made the dev stack unable to authenticate.
  local bad=""
  for driver in "${SCAFFOLD_ROOT}"/services/*/drivers/*.sh; do
    block="$( . "${SCAFFOLD_ROOT}/lib/service.sh"
              SERVICE_DIR="$(dirname "$(dirname "$driver")")"
              . "$driver"; service_driver_compose_env )"
    [ -z "$block" ] && continue
    grep -q '\${DB_PASSWORD' <<<"$block" || grep -q '\${REDIS_PASSWORD' <<<"$block" \
      || bad="${bad}${driver}"$'\n'
  done
  [ -z "$bad" ] || { echo "embeds a literal password:"; echo "$bad"; false; }
}

@test "apply_service_compose_env merges into the app service" {
  local project="${BATS_TEST_TMPDIR}/p"
  mkdir -p "$project"
  printf 'services:\n  app:\n    image: x\n' > "${project}/compose.yaml"
  . "${SCAFFOLD_ROOT}/lib/service.sh"
  apply_service_compose_env "$project" 'DATABASE_URL: ${DATABASE_URL:-postgresql://app@database:5432/app}'
  run mise exec -- yq -r '.services.app.environment.DATABASE_URL' "${project}/compose.yaml"
  [[ "$output" == 'postgresql://app@database:5432/app' ]] \
    || [[ "$output" == '${DATABASE_URL:-postgresql://app@database:5432/app}' ]]
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- bats --filter 'compose environment|apply_service_compose_env' tests/service.bats`
Expected: FAIL — `service_driver_compose_env: command not found` and
`apply_service_compose_env: command not found`.

- [ ] **Step 3: Add the merge function**

In `lib/service.sh`, beside `apply_service_setup`:

```sh
# apply_service_compose_env <project> <block>
# Adds the block to compose.yaml's app service. yq rather than an anchor: the
# app service is generated by assemble_compose from common/compose.yaml, so
# there is a real document to merge into by the time this runs, and a text
# anchor would only be a second way to write YAML.
apply_service_compose_env() {
  local project="$1" block="$2"
  local file="${project}/compose.yaml" fragment

  [ -n "$block" ] || return 0
  [ -f "$file" ] || die "no compose.yaml in ${project}"

  fragment="$(mktemp)"
  {
    printf 'services:\n  app:\n    environment:\n'
    printf '%s\n' "$block" | sed 's/^/      /'
  } > "$fragment"

  if ! yq eval-all --inplace -P 'select(fileIndex==0) * select(fileIndex==1)' \
    "$file" "$fragment"; then
    rm -f "$fragment"
    die "could not merge the service environment into ${file}"
  fi
  rm -f "$fragment"
}
```

`-P` for the same reason `merge_lefthook_fragment` needs it: yq propagates the
style of what it merges, and a collapsed `compose.yaml` is a file a client has
to read.

- [ ] **Step 4: Call it from apply_service_drivers**

In `apply_service_drivers`, beside the existing `service_driver_dockerfile`
accumulation, add a second accumulator and one call:

```sh
    # shellcheck source=/dev/null # family varies, so the path isn't constant
    rendered="$( . "$driver"; service_driver_compose_env )"
    [ -n "$rendered" ] && env_block+="${rendered}"$'\n'
```

Declare `env_block=""` beside `block=""`, and after the loop, beside the
existing `apply_service_setup` call:

```sh
  apply_service_compose_env "$project" "${env_block%$'\n'}"
```

- [ ] **Step 5: Require the hook of every driver**

In `lib/contract.sh`, add a list beside `REQUIRED_SERVICE_FILES`:

```sh
# apply_service_drivers calls all three, so a driver shipping fewer fails at
# generation rather than at lint.
REQUIRED_DRIVER_FUNCTIONS=(service_driver_apply service_driver_dockerfile service_driver_compose_env)
```

In `lib/lint.sh`'s `lint_services`, source each driver in a subshell and
check each name with `declare -F`.

- [ ] **Step 6: Run the tests**

Run: `mise exec -- bats tests/service.bats tests/contract.bats > /tmp/svc.log 2>&1; grep -c '^ok ' /tmp/svc.log; grep -A4 '^not ok' /tmp/svc.log`
Expected: the second test passes; the first still fails (no driver implements
the hook yet), and `scaffold lint` now reports every driver as missing it.
That is the correct intermediate state — Task 5 closes it.

- [ ] **Step 7: Commit**

```bash
git add lib/service.sh lib/contract.sh lib/lint.sh tests/service.bats tests/contract.bats
git commit -m "feat: give a driver a seam for the app's connection environment"
```

---

### Task 5: Every driver emits its family's environment and probe

**Files:**
- Modify: `services/{mysql,postgres,mongodb,redis}/drivers/{laravel,nest}.sh`,
  `services/shared/{laravel,nest}.sh`
- Test: `tests/service.bats`

**Interfaces:**
- Consumes: `apply_service_compose_env` and `REQUIRED_DRIVER_FUNCTIONS` from
  Task 4; the `@DB_PROBE@` anchor from Task 2's Nest controller.
- Produces: a `compose.yaml` whose `app` service carries the family's
  variables, and a readiness route that runs a real query.

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "the laravel drivers name the connection selector laravel actually reads" {
  # config/database.php is `env('DB_CONNECTION', 'sqlite')`. Without that
  # variable laravel does not fail — it silently reads DB_DATABASE as a
  # sqlite filename and never contacts the service at all.
  for service in mysql postgres mongodb; do
    block="$( . "${SCAFFOLD_ROOT}/lib/service.sh"
              . "${SCAFFOLD_ROOT}/services/${service}/drivers/laravel.sh"
              service_driver_compose_env )"
    grep -q '^DB_CONNECTION:' <<<"$block" \
      || { echo "${service}/laravel.sh emits no DB_CONNECTION"; false; }
  done
}

@test "the nest drivers name DATABASE_URL and let an operator override it" {
  for service in mysql postgres mongodb; do
    block="$( . "${SCAFFOLD_ROOT}/lib/service.sh"
              . "${SCAFFOLD_ROOT}/services/${service}/drivers/nest.sh"
              service_driver_compose_env )"
    grep -q '^DATABASE_URL: \${DATABASE_URL:-' <<<"$block" \
      || { echo "${service}/nest.sh does not allow an override"; false; }
  done
}
```

- [ ] **Step 2: Run them and watch them fail**

Run: `mise exec -- bats --filter 'connection selector|DATABASE_URL' tests/service.bats`
Expected: both FAIL.

- [ ] **Step 3: Implement the hook in the shared Nest driver**

In `services/shared/nest.sh`, add — using `PRISMA_PROVIDER` and the service's
own port, both already in scope from the per-service driver:

```sh
# The value an operator sets in .env wins; otherwise compose composes it from
# the same DB_* variables the database container reads, so the password lives
# in exactly one place and the two cannot drift. Measured against a real
# `docker compose config`: both paths resolve, and the default is not
# evaluated when DATABASE_URL is set.
service_driver_compose_env() {
  printf 'DATABASE_URL: ${DATABASE_URL:-%s}\n' "$PRISMA_COMPOSE_URL"
}
```

Each `services/<db>/drivers/nest.sh` sets `PRISMA_COMPOSE_URL` beside the
`PRISMA_URL` it already sets — the same string with `localhost` replaced by
`database` and the literals replaced by interpolations. For postgres:

```sh
PRISMA_COMPOSE_URL='postgresql://${DB_USERNAME:-app}:${DB_PASSWORD}@database:5432/${DB_DATABASE:-app}'
```

mysql uses `mysql://…@database:3306/…`; mongodb uses
`mongodb://…@database:27017/…?authSource=admin&directConnection=true`. Single
quotes throughout: these are compose's interpolations, not the shell's.

- [ ] **Step 4: Implement the probe for Nest**

In `services/shared/nest.sh`'s `service_driver_apply`, after the prisma setup
it already does, replace the controller's anchor:

```sh
  # prisma has no provider-agnostic read: $queryRaw is SQL-only and mongodb
  # needs a command. Written here rather than branched in the controller so
  # the shipped route carries exactly one probe, for the provider this
  # project actually has.
  local probe
  case "$PRISMA_PROVIDER" in
    mongodb) probe='await new PrismaClient().$runCommandRaw({ ping: 1 });' ;;
    *)       probe="await new PrismaClient().\$queryRawUnsafe('SELECT 1');" ;;
  esac
  sed -i.bak "s|// @DB_PROBE@|import('@prisma/client').then(async ({ PrismaClient }) => { ${probe} });\n      return { status: 'ok' };|" \
    src/health/health.controller.ts
  rm -f src/health/health.controller.ts.bak
```

The `throw` below the anchor stays in the shipped file and is what a `--db
none` project keeps: unreachable once a probe is spliced in, and the honest
503 when none is.

- [ ] **Step 5: Implement both for the shared Laravel driver**

In `services/shared/laravel.sh`:

```sh
service_driver_compose_env() {
  # DB_CONNECTION first and always: config/database.php defaults to sqlite,
  # so its absence is not an error, it is a silent wrong answer.
  printf 'DB_CONNECTION: %s\n' "$LARAVEL_CONNECTION"
  printf '%s\n' "$LARAVEL_COMPOSE_ENV"
  # APP_KEY has no service to come from and laravel will not boot without it;
  # install.sh generates the value, this only reserves the name.
  printf 'APP_KEY: ${APP_KEY}\n'
}
```

Each `services/<db>/drivers/laravel.sh` sets `LARAVEL_CONNECTION` (`mysql`,
`pgsql`, `mongodb`) and `LARAVEL_COMPOSE_ENV`, the remaining variables that
family needs — `DB_HOST: database`, `DB_PORT`, and for mongodb `DB_URI`
instead of host and port.

For the readiness route, splice the probe into `routes/health.php` the same
way, with `DB::connection()->select('select 1');` for SQL and
`DB::connection('mongodb')->getMongoDB()->command(['ping' => 1]);` for mongodb.

- [ ] **Step 6: Add the redis drivers' hook**

`services/redis/drivers/{laravel,nest}.sh` gain a `service_driver_compose_env`
emitting `REDIS_URL`/`REDIS_HOST` pointing at the `cache` service. Task 4's
lint now requires the function of every driver, so neither may be left out.

- [ ] **Step 7: Run the tests**

Run: `mise exec -- bats tests/service.bats tests/contract.bats > /tmp/svc.log 2>&1; tail -5 /tmp/svc.log; grep -A4 '^not ok' /tmp/svc.log`
Expected: all PASS, and `mise exec -- ./scaffold lint` silent.

- [ ] **Step 8: Commit**

```bash
git add services lib tests/service.bats
git commit -m "feat: tell the application how to reach the service it was given"
```

---

### Task 6: install.sh generates APP_KEY and runs migrations

**Files:**
- Modify: `common/install.sh`, `adapters/nestjs/mise.toml`
- Test: `tests/compose.bats` (it already sources `install.sh` per-function)

**Interfaces:**
- Consumes: `APP_KEY: ${APP_KEY}` emitted by Task 5's Laravel driver.
- Produces: a `.env` carrying a Laravel-valid `APP_KEY`; a stack whose schema
  exists before the success message prints.

- [ ] **Step 1: Write the failing test**

Append to `tests/compose.bats`:

```bash
@test "install.sh generates an APP_KEY laravel will accept" {
  # generate_service_passwords' generic 24-character value is rejected with
  # "Unsupported cipher or incorrect key length" — laravel needs base64: and
  # exactly 32 bytes.
  local env_file="${BATS_TEST_TMPDIR}/.env"
  printf 'DB_PASSWORD=changeme\nAPP_KEY=changeme\n' > "$env_file"
  . "${SCAFFOLD_ROOT}/common/install.sh"
  run generate_service_passwords "$env_file"
  assert_ok
  run grep '^APP_KEY=' "$env_file"
  [[ "$output" =~ ^APP_KEY=base64:[A-Za-z0-9+/]{43}=$ ]] \
    || { echo "not a laravel key: ${output}"; false; }
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `mise exec -- bats --filter 'APP_KEY laravel will accept' tests/compose.bats`
Expected: FAIL — the value is a bare 24-character string.

- [ ] **Step 3: Special-case APP_KEY in the generator**

In `common/install.sh`'s `generate_service_passwords`, inside the loop:

```sh
    # APP_KEY is not a password: laravel decrypts with it and rejects anything
    # that is not base64: plus exactly 32 bytes. Handled inside this loop
    # rather than beside it so example.env keeps one placeholder, and the
    # existing-.env guard that greps for a remaining `=changeme` still covers
    # it.
    if [ "$name" = APP_KEY ]; then
      password="base64:$(head -c 32 /dev/urandom | base64)"
    else
      password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    fi
```

The existing `sed` uses `s/^${name}=changeme$/${name}=${password}/`, and a
base64 value can contain `/`. Change the delimiter to `|` and keep the
`grep -qF` confirmation, which already catches a substitution that missed.

- [ ] **Step 4: Run the test**

Run: `mise exec -- bats --filter 'APP_KEY laravel will accept' tests/compose.bats`
Expected: PASS.

- [ ] **Step 5: Give nestjs a migrate task**

In `adapters/nestjs/mise.toml`:

```toml
[tasks.migrate]
# prisma's mongodb provider rejects `migrate deploy` outright — measured:
# `The "mongodb" provider is not supported with this command.` — and takes
# `db push` instead. Branching on the schema rather than on a recorded value
# keeps this true for a project whose provider changes.
run = """
if ! [ -f prisma/schema.prisma ]; then exit 0; fi
if grep -q 'provider *= *"mongodb"' prisma/schema.prisma; then
  pnpm exec prisma db push --skip-generate
else
  pnpm exec prisma migrate deploy
fi
"""
```

- [ ] **Step 6: Keep the Prisma CLI in the Nest runtime image**

`services/shared/nest.sh` installs the CLI as `pnpm add -D prisma@6`, and
`adapters/nestjs/Dockerfile` runs `pnpm prune --prod` before the runtime stage
copies `node_modules` — so the published image has `@prisma/client` and no
`prisma` binary, and cannot migrate itself. Change the driver:

```sh
  # A regular dependency, not -D: `pnpm prune --prod` in the Dockerfile drops
  # devDependencies, and the published image is what runs `migrate deploy` on
  # deploy. The alternative — a second image, or a compose service mounting
  # the source — introduces a build artifact the release does not publish, for
  # a command run once. The engines cost image size; see decision record 0021.
  pnpm add prisma@6 || return 1
```

Laravel needs nothing here: `php artisan` is already in those images.

- [ ] **Step 7: Add the migrate service and run it from install.sh**

`install.sh` cannot run a `mise` task — no image carries `mise`. The driver
writes a compose service instead, sharing the app's image and environment,
behind a profile so it never starts with the stack. In
`services/shared/{laravel,nest}.sh`, extend `service_driver_compose_env`'s
sibling — a new `service_driver_compose_migrate` printing the family's
command — and have `apply_service_compose_env` merge it as
`services.migrate`.

Laravel: `["php", "artisan", "migrate", "--force"]`.
Nest, chosen at generation time from `PRISMA_PROVIDER`:
`["pnpm", "exec", "prisma", "db", "push", "--skip-generate"]` for mongodb,
`["pnpm", "exec", "prisma", "migrate", "deploy"]` otherwise.

In `common/install.sh`, between `start_stack` and its success message:

```sh
# ADR-0014 seam 5 forbids migrations from an *entrypoint* — a container that
# migrates every time it starts cannot be scaled or rolled back. This is a
# human running one command on the target host, which is what that ADR calls
# the one deploy mechanism that exists today. A project with no database
# ships no migrate service, and `--profile` on a service that is not there
# is not an error.
run_migrations() {
  docker compose config --services | grep -qx migrate || return 0
  echo "running migrations..."
  docker compose --profile migrate run --rm migrate
}
```

Move the "the application is running on…" message out of `start_stack` and
into `main`, after `run_migrations`, so the order it reports is the order that
happened.

- [ ] **Step 8: Prove the migrate service runs**

```bash
cd /tmp/dsverify && scaffold new t6 --api laravel-api --db postgres
cd t6 && docker build -f apps/api/Dockerfile -t dsverify/t6:local apps/api
sed -i 's|ghcr.io/CHANGEME/CHANGEME:${IMAGE_TAG:-latest}|dsverify/t6:local|' compose.yaml
cp example.env .env && docker compose up -d && sleep 25
docker compose --profile migrate run --rm migrate
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/health/ready
docker compose down -v
```

Expected: the migrate run prints Laravel's migration table and exits 0, and
the readiness curl prints `200`. Before the migration it returns 503 — check
that too, in that order, because a readiness route that returns 200 against an
empty schema is not reading anything.

- [ ] **Step 9: Run the suite**

Run: `mise exec -- bats tests/compose.bats tests/service.bats > /tmp/compose.log 2>&1; tail -5 /tmp/compose.log; grep -A4 '^not ok' /tmp/compose.log`
Expected: all PASS.

- [ ] **Step 10: Commit**

```bash
git add common/install.sh adapters/nestjs/mise.toml services lib tests
git commit -m "feat: let the released stack migrate its own schema"
```

---

### Task 7: The deploy gate

**Files:**
- Create: `scripts/deploy-check.sh`
- Modify: `.github/workflows/adapters.yml`
- Test: the script runs locally against a generated project

**Interfaces:**
- Consumes: `ADAPTER_LIVENESS_PATH` and `ADAPTER_READINESS_PATH` (Task 1);
  everything Tasks 2–6 built.

- [ ] **Step 1: Write the script**

Create `scripts/deploy-check.sh` — generate, build with the pair the generated
`build.yml` names, start the stack, migrate, curl both paths, tear down. It
reads the two paths from the adapter, never from its own copy of them: the
gate hardcoding a route is how `nestjs` came to probe a `/health` nothing
served.

```sh
#!/usr/bin/env bash
# deploy-check.sh <adapter> [--db <service>]
# Proves a generated project's released stack serves HTTP and reaches its
# database. Everything before this validated YAML; nothing started a container.
set -euo pipefail
```

Body: resolve `role` and both paths from `adapters/<adapter>/adapter.env`;
`scaffold new` into a temp directory with the role's flag; read `context` and
`dockerfile` out of the generated `.github/workflows/build.yml`;
`docker build`; rewrite `compose.yaml`'s image to the built tag; `cp
example.env .env`; `docker compose up -d`; poll `docker compose ps` until the
app container is healthy or 120s elapse; run the adapter's migrate task with
`docker compose exec`; `curl -fsS` the liveness path and, when the adapter
declares one, the readiness path, asserting `200`; `docker compose down -v` in
a trap so a failure still tears down.

- [ ] **Step 2: Run it locally for the cheapest adapter**

Run: `mise exec -- ./scripts/deploy-check.sh nestjs --db postgres`
Expected: exits 0, having printed `200` for both paths.

- [ ] **Step 3: Run it for the shape with no database**

Run: `mise exec -- ./scripts/deploy-check.sh nextjs`
Expected: exits 0, liveness only, and says it skipped readiness.

- [ ] **Step 4: Add the job**

In `.github/workflows/adapters.yml`, after `smoke-tier-b`:

```yaml
  deploy:
    needs: discover
    if: ${{ needs.discover.outputs.tier-a != '[]' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    # a generation plus an image build plus a container start, per adapter.
    timeout-minutes: 30
    strategy:
      fail-fast: false
      matrix:
        adapter: ${{ fromJson(needs.discover.outputs.tier-a) }}
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c # v4.3.0
      - run: corepack enable
      - id: language
        env:
          ADAPTER: ${{ matrix.adapter }}
        run: |
          lang="$(grep '^ADAPTER_LANGUAGE=' "adapters/${ADAPTER}/adapter.env" | cut -d'"' -f2)"
          echo "value=${lang}" >> "$GITHUB_OUTPUT"
      - if: steps.language.outputs.value == 'php'
        uses: shivammathur/setup-php@f3e473d116dcccaddc5834248c87452386958240 # 2.37.2
        with:
          php-version: "8.3"
      - env:
          ADAPTER: ${{ matrix.adapter }}
        run: ./scripts/deploy-check.sh "$ADAPTER"

  deploy-tier-b:
    # Same job, tier b matrix, on the weekly schedule only — ADR-0012 makes
    # this tradeoff once rather than per job, and a container build per
    # adapter on every pull request is exactly the cost it exists to bound.
```

`deploy-tier-b` mirrors `smoke-tier-b`'s `needs`, `if` and matrix.

- [ ] **Step 5: Lint the workflow**

Run: `mise exec -- zizmor .github/workflows/adapters.yml && mise exec -- actionlint`
Expected: both clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/deploy-check.sh .github/workflows/adapters.yml
git commit -m "feat: start the stack in ci and require it to answer"
```

---

### Task 8: Documentation this falsifies

**Files:**
- Create: docs/decisions/0021-the-released-stack-must-run.md
- Modify: `docs/decisions/0003-*`, `docs/decisions/0014-*`,
  `docs/tour/07-containers.md`,
  `docs/runbook/first-project-walkthrough.md`
- Test: `tests/documentation.bats`

- [ ] **Step 1: Write decision record 0021**

Record: the two gates; the port contract and why a variable was rejected
(quoting ADR-0014's own reasoning about `IMAGE_REPOSITORY`); FrankenPHP with
its evidence and the alpine constraint; the environment contract and the
single-password argument; and the readiness route. Preserve seam 4's
reasoning explicitly — a check that cannot fail is worse than none — and say
that what changed is not the reasoning but the premise.

- [ ] **Step 2: Amend ADR-0003**

Its boundary moves from "an adapter writes no application code" to "…except
the health routes the deploy gate requires". State the exception and why it
is narrow.

- [ ] **Step 3: Amend ADR-0014**

Seam 1 and seam 4 both become false. Add a `Superseded in part by 0021` line
naming which seams, rather than editing the record silently.

- [ ] **Step 4: Fix the tour and the runbook**

`docs/tour/07-containers.md` uses the Laravel "why no healthcheck" paragraph
as its worked example. Replace it. Its "Delete test" section admits nothing
asserts a healthcheck exists — that is now false too, and the new assertion
is the answer.

`docs/runbook/first-project-walkthrough.md` step 10 becomes "run it": pull,
`install.sh`, and curl the two paths.

- [ ] **Step 5: Run the docs suite**

Run: `mise exec -- bats tests/documentation.bats`
Expected: 4/4 PASS. Every backticked string containing `/` is treated as a
path by test 2 — write route paths without backticks, or as `apps/…`, which
that test exempts.

- [ ] **Step 6: Commit**

```bash
git add docs
git commit -m "docs: record what a running stack changed about the seams"
```

---

### Task 9: Full verification

- [ ] **Step 1: Lint and the full lane, once**

```bash
mise run lint
mise run test-runner > /tmp/runner.log 2>&1
echo "ok=$(grep -c '^ok ' /tmp/runner.log) notok=$(grep -c '^not ok' /tmp/runner.log)"
grep -A6 '^not ok' /tmp/runner.log | head -40
```

Expected: `notok=0`. A `registry.npmjs.org` `ECONNRESET` under parallel lanes
is a known flake — re-run only the affected suite before treating it as a
failure.

- [ ] **Step 2: Both gates, by hand, on a shape no task used**

```bash
mise exec -- ./scripts/deploy-check.sh laravel-inertia
```

Expected: exits 0. This is the tier-B adapter and the most fragile image; a
task-level check never ran it end to end.

- [ ] **Step 3: Green immediately, from a clone**

```bash
cd /tmp/dsverify && scaffold new final --api nestjs --web nextjs --db postgres --cache redis
git clone final final-clean && cd final-clean
for root in $(mise exec -C /home/ttndev/workspace/personal/scaffold -- yq -r '.monorepo.config_roots[]' mise.toml); do
  mise run "//${root}:ci-unit" || echo "FAILED: ${root}"
done
```

Expected: every root exits 0. The clone is the point — a working tree keeps
artifacts that make the checks pass for the wrong reason.

- [ ] **Step 4: Open the pull request**

Push the branch and open a pull request against `main` with the spec linked.
Wait for every check, including the new `deploy` matrix.

---

## Self-Review

**Spec coverage.** Section 4 (port contract) → Tasks 2, 3. Section 5
(FrankenPHP) → Task 3. Section 6 (environment contract) → Tasks 4, 5.
Section 7 (liveness and readiness) → Tasks 1, 2, 3, 5. Section 8
(migrations) → Task 6. Section 9 (ownership, stale assets, mongodb pin) →
Task 3 for the first two; **the mongodb library pin has no task** — added to
Task 5, Step 5, as part of the mongodb Laravel driver. Section 10 (the gate)
→ Task 7. Section 11 (files) → covered. Section 12 (testing) → the
assertions are written in the tasks that make them pass.

**Placeholders.** None. Writing the plan surfaced one contradiction with the
spec and it was fixed in both, not deferred: the published Nest image carries
`@prisma/client` and no `prisma` binary (`pnpm add -D prisma@6` in the driver,
`pnpm prune --prod` in the Dockerfile), so it could not migrate itself, and
`install.sh` could not run a `mise` task because no image carries `mise`. The
driver now installs the CLI as a regular dependency and writes a profiled
`migrate` compose service; spec section 8 says the same and states the image
size cost.

**Type consistency.** `service_driver_compose_env` is the name in Task 4
(definition), Task 4 Step 5 (contract), and Task 5 (implementations).
`apply_service_compose_env <project> <block>` matches its call site, and
`service_driver_compose_migrate` (Task 6, Step 7) is named the same in the
contract list Task 4 Step 5 defines — add it there when implementing Task 6,
since Task 4 is written before it exists.
`ADAPTER_LIVENESS_PATH` / `ADAPTER_READINESS_PATH` are the names in Tasks 1,
2, 3 and 7. The `@DB_PROBE@` anchor in Task 2's controller is the one Task 5
Step 4 replaces.
