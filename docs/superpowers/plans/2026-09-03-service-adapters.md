# Service Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `scaffold new` choose a database and a cache, and wire the choice
far enough into the generated project that the application actually connects.

**Architecture:** A `services/` directory sits beside `adapters/`. Each service
owns its compose blocks, its infrastructure environment variables, and one
driver script per framework family. `scaffold` assembles the three compose
files and `example.env` from the selected services' fragments, then each
adapter's driver installs the client package, writes the application's
`.env.example` lines, and emits the Dockerfile block spliced in at a
`# @SERVICE_SETUP@` anchor.

**Tech Stack:** bash, `yq` (TOML read + YAML merge), `jq`, `mise`, `bats`,
Docker Compose, Prisma (Nest), Eloquent (Laravel).

**Spec:** `docs/superpowers/specs/2026-09-03-service-adapters-design.md`

## Global Constraints

- Chat is Vietnamese; **every file, comment, commit message and document is
  English**.
- Comment style follows immich and the surrounding repository: explain *why*,
  never *what*. No comment asserts that a mechanism "always" does something
  unless a check enforces it.
- Tests must stay isolated. A test that modifies the toolbox uses
  `copy_toolbox` (`tests/helpers/setup.bash`) — never the real tree. Slow is
  acceptable; interdependent is not.
- Services shipped: `mysql`, `postgres`, `mongodb` (kind `database`) and
  `redis` (kind `cache`). No DynamoDB, no MariaDB, no Valkey.
- `--db` default: `mysql` when the project requests an `api` or `app` adapter,
  `none` otherwise. `--cache` default: `none`.
- Framework families: `laravel`, `nest`, `next`. Only `api` and `app` roles
  take a driver.
- Every image reference is pinned by digest, and a service's digest is written
  in exactly one place: its `service.env`.
- Run `mise run lint` (shellcheck) before every commit. It covers `scaffold`,
  `lib/*.sh`, `scripts/*.sh` and `common/*.sh`.
- Work on branch `feat/service-adapters`, cut from `feat/service-adapters-design`.

## File Structure

**Created:**

| Path | Responsibility |
| --- | --- |
| `lib/service.sh` | load a service, assemble compose and `example.env`, run drivers |
| `services/<name>/service.env` | name, kind, image digest |
| `services/<name>/compose.fragment.yaml` | the block shared by all three lanes |
| `services/<name>/compose.{prod,dev,test}.fragment.yaml` | per-lane delta |
| `services/<name>/env.fragment` | infrastructure variables for `example.env` |
| `services/<name>/drivers/<family>.sh` | per-family parameters |
| `services/shared/laravel.sh` | the Laravel database driver, parameterised |
| `services/shared/nest.sh` | the Prisma driver, parameterised |
| `tests/service.bats` | structural suite — no generation |
| `docs/decisions/0019-services-are-not-adapters.md` | why `services/` is separate |
| `docs/decisions/0020-mysql-is-the-default-database.md` | the default change |

**Modified:** `scaffold`, `lib/contract.sh`, `lib/lint.sh`, `lib/adapter.sh`,
`lib/project.sh`, `common/compose.yaml`, `common/compose.dev.yaml`,
`common/compose.test.yaml`, `common/example.env`, `common/install.sh`,
`common/mise.root.toml`, `adapters/*/adapter.env`, `adapters/*/.env.example`,
`adapters/laravel-api/Dockerfile`, `adapters/laravel-inertia/Dockerfile`,
`adapters/nestjs/Dockerfile`, `adapters/nestjs/mise.toml`, `mise.toml`,
`.github/workflows/adapters.yml`, `docs/tour/07-containers.md`, `README.md`.

---

### Task 0: Branch

- [ ] **Step 1: Cut the branch**

```bash
cd /home/ttndev/workspace/personal/scaffold
git checkout feat/service-adapters-design
git checkout -b feat/service-adapters
```

---

### Task 1: The service loader

**Files:**
- Create: `lib/service.sh`
- Create: `services/mysql/service.env`
- Create: `tests/service.bats`
- Modify: `scaffold` (source the new library)

**Interfaces:**
- Produces: `load_service <name>` — sets `SERVICE_DIR`, `SERVICE_NAME`,
  `SERVICE_KIND`, `SERVICE_IMAGE`; dies on a name that could escape
  `services/`, returns 1 on a malformed `service.env`.
- Produces: `service_compose_key <kind>` — prints the compose service name for
  a kind; dies on an unknown kind.

- [ ] **Step 1: Write the failing test**

Create `tests/service.bats`:

```bash
#!/usr/bin/env bats

setup() {
  load 'helpers/setup'
  source "${SCAFFOLD_ROOT}/lib/log.sh"
  source "${SCAFFOLD_ROOT}/lib/service.sh"
}

@test "load_service reads a service manifest" {
  load_service mysql
  [ "$SERVICE_NAME" = "mysql" ]
  [ "$SERVICE_KIND" = "database" ]
  [[ "$SERVICE_IMAGE" == *"@sha256:"* ]]
}

@test "load_service refuses a name that leaves services/" {
  # `source` runs what it reads, so this is the same class of hole
  # load_adapter closes — a relative name would source an arbitrary file.
  run load_service "../../tmp/evil"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a usable service name"* ]]
}

@test "load_service dies on an unknown service" {
  run load_service nonesuch
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service: nonesuch"* ]]
}

@test "service_compose_key rejects a kind nothing depends on" {
  run service_compose_key storage
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service kind: storage"* ]]
}

@test "every service pins its image by digest" {
  for service in "${SCAFFOLD_ROOT}"/services/*/; do
    [ -f "${service}service.env" ] || continue
    grep -q '@sha256:' "${service}service.env" \
      || { echo "no digest in ${service}service.env"; false; }
  done
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/service.bats
```

Expected: FAIL — `lib/service.sh` does not exist.

- [ ] **Step 3: Resolve the MySQL image digest**

```bash
docker buildx imagetools inspect docker.io/library/mysql:8.4 \
  --format '{{.Manifest.Digest}}'
```

Record the digest it prints; the next step writes it in.

- [ ] **Step 4: Write `services/mysql/service.env`**

Substitute the digest from step 3 for `<digest>`:

```sh
SERVICE_NAME="mysql"
SERVICE_KIND="database"
# The one place this digest is written. The compose fragments carry no image
# line at all, so bumping the version here reaches all three lanes at once —
# the arrangement it replaces wrote the digest once per lane, where missing
# one left development on a different server from production with nothing to
# report it.
SERVICE_IMAGE="docker.io/library/mysql:8.4@sha256:<digest>"
```

- [ ] **Step 5: Write `lib/service.sh`**

```bash
# shellcheck shell=bash

# load_service <name>
# Same guard as load_adapter, for the same reason: `source` below executes
# whatever it reads, so the name must not be able to leave services/.
load_service() {
  local name="$1"

  case "$name" in
    ''|*[!a-z0-9-]*|-*) die "not a usable service name: ${name}" ;;
  esac

  local dir="${SCAFFOLD_ROOT}/services/${name}"
  [ -d "$dir" ] || die "unknown service: ${name}"

  SERVICE_DIR="$dir"
  unset -v SERVICE_NAME SERVICE_KIND SERVICE_IMAGE
  # shellcheck source=/dev/null
  source "${dir}/service.env" || return 1

  [ -n "${SERVICE_NAME:-}" ] && [ -n "${SERVICE_KIND:-}" ] \
    && [ -n "${SERVICE_IMAGE:-}" ] || return 1
}

# service_compose_key <kind>
# The compose service name a kind is published under. An identity mapping
# today, and a function rather than a bare expansion so an unrecognised kind
# fails here instead of writing a service that nothing depends on and nothing
# reports missing.
service_compose_key() {
  case "$1" in
    database) printf 'database\n' ;;
    cache) printf 'cache\n' ;;
    *) die "unknown service kind: ${1}" ;;
  esac
}
```

- [ ] **Step 6: Source it from `scaffold`**

In `scaffold`, after the `lib/adapter.sh` source block, add:

```bash
# shellcheck source=lib/service.sh
source "${SCAFFOLD_ROOT}/lib/service.sh"
```

- [ ] **Step 7: Run the tests and shellcheck**

```bash
mise exec -- bats tests/service.bats
mise run lint
```

Expected: 5 passing, shellcheck clean.

- [ ] **Step 8: Commit**

```bash
git add lib/service.sh services/mysql/service.env tests/service.bats scaffold
git commit -m "feat: a service manifest and the loader that reads it"
```

---

### Task 2: Compose assembly

**Files:**
- Create: `services/mysql/compose.fragment.yaml`
- Create: `services/mysql/compose.prod.fragment.yaml`
- Create: `services/mysql/compose.dev.fragment.yaml`
- Create: `services/mysql/compose.test.fragment.yaml`
- Modify: `lib/service.sh` (add `assemble_compose`)
- Modify: `common/compose.yaml`, `common/compose.dev.yaml`, `common/compose.test.yaml`
- Modify: `scaffold` (`cmd_new` calls `assemble_compose` with `mysql`)
- Modify: `tests/service.bats`

**Interfaces:**
- Consumes: `load_service`, `service_compose_key` (Task 1).
- Produces: `assemble_compose <project> <service>...` — merges each service's
  block into `compose.yaml`, `compose.dev.yaml` and `compose.test.yaml`,
  injects `SERVICE_IMAGE`, and adds the `depends_on` entry on `compose.yaml`
  only (the dev and test lanes carry no application service).

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "assemble_compose writes a valid stack for one database" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" mysql
  assert_ok

  run yq -e '.services.database.image | test("@sha256:")' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.app.depends_on.database.condition == "service_healthy"' \
    "${project}/compose.yaml"
  assert_ok
  run yq -e '.volumes.database != null' "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.database.tmpfs != null' "${project}/compose.test.yaml"
  assert_ok
}

@test "a project with no services has no depends_on" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" "$project/"

  run assemble_compose "$project"
  assert_ok
  run yq -e '.services.app.depends_on == null' "${project}/compose.yaml"
  assert_ok
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/service.bats
```

Expected: FAIL — `assemble_compose: command not found`.

- [ ] **Step 3: Write the four MySQL fragments**

`services/mysql/compose.fragment.yaml` — everything the three lanes share.
Defaults are `app` because the dev and test lanes run with no `.env` at all;
the production lane overrides them below.

```yaml
services:
  database:
    environment:
      MYSQL_DATABASE: ${DB_DATABASE:-app}
      MYSQL_USER: ${DB_USERNAME:-app}
      MYSQL_PASSWORD: ${DB_PASSWORD:-app}
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD:-app}
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "127.0.0.1", "--silent"]
      interval: 10s
      timeout: 5s
      retries: 5
```

`services/mysql/compose.prod.fragment.yaml` — the password default becomes
`changeme` so a stack started with no `.env` is visibly unconfigured rather
than quietly running on the development password. `install.sh` refuses to
start on that value.

```yaml
services:
  database:
    environment:
      MYSQL_PASSWORD: ${DB_PASSWORD:-changeme}
      MYSQL_ROOT_PASSWORD: ${DB_PASSWORD:-changeme}
    volumes:
      - database:/var/lib/mysql
    restart: always
volumes:
  database:
```

`services/mysql/compose.dev.fragment.yaml` — loopback, not `0.0.0.0`: docker
publishes to every interface by default and its iptables rules bypass most
host firewalls, so the bare form exposes a password-is-`app` database to the
whole local network.

```yaml
services:
  database:
    ports:
      - "127.0.0.1:3306:3306"
```

`services/mysql/compose.test.fragment.yaml`:

```yaml
services:
  database:
    tmpfs:
      - /var/lib/mysql
```

- [ ] **Step 4: Strip the database out of the three common compose files**

`common/compose.yaml` keeps its header comment and becomes:

```yaml
# production-like stack. clients run this file; it is attached to every
# release so the compose file and the image always match (see the scaffold
# toolbox's ADR-0014, not shipped here). every variable below has a default
# so this file validates in a freshly generated project, before a .env
# exists at all — the real values live in .env, written by install.sh from
# example.env.
#
# the database and cache services are not here: scaffold merges in whichever
# were selected at generation time (ADR-0019), so a project that asked for
# neither ships neither, rather than a service nothing opens a connection to.
name: app

services:
  app:
    # ghcr.io/CHANGEME/CHANGEME is a placeholder: scaffold generates this
    # project before it has a github repository, so it cannot know its own
    # registry path. replace it once, by hand, after the repository exists
    # and its first image has been published (see the scaffold toolbox's
    # ADR-0014, not shipped here).
    image: ghcr.io/CHANGEME/CHANGEME:${IMAGE_TAG:-latest}
    env_file:
      # required: false so this validates before a .env exists; install.sh
      # always writes one before starting the stack.
      - path: .env
        required: false
    restart: always
    ports:
      - "${APP_PORT:-8080}:8080"
```

`common/compose.dev.yaml`:

```yaml
# local development only: throwaway services an app started outside docker
# (mise run dev, etc.) can point at on localhost. never shipped as a release
# asset — see compose.yaml for the stack a client actually runs. the services
# themselves are merged in by scaffold from the selection made at generation
# time.
name: app-dev

services: {}
```

`common/compose.test.yaml`:

```yaml
# ci and local test runs: same services as compose.dev.yaml, but tmpfs storage
# so every run starts from an empty database and nothing persists between
# runs.
name: app-test

services: {}
```

- [ ] **Step 5: Write `assemble_compose`**

Append to `lib/service.sh`:

```bash
# assemble_compose <project> <service>...
# The common compose files ship the application service alone; each selected
# service's block is merged in per lane. The image is injected here rather
# than written in a fragment so a service's digest lives only in its
# service.env.
assemble_compose() {
  local project="$1"; shift
  local service lane file key merged

  for service in "$@"; do
    load_service "$service"
    key="$(service_compose_key "$SERVICE_KIND")"

    # The fragment has to publish under the key its kind implies, or the
    # depends_on below would name a service that is not there.
    yq -e ".services.${key} != null" "${SERVICE_DIR}/compose.fragment.yaml" >/dev/null \
      || die "${service}'s compose fragment does not define services.${key}"

    for lane in prod dev test; do
      case "$lane" in
        prod) file="${project}/compose.yaml" ;;
        dev) file="${project}/compose.dev.yaml" ;;
        test) file="${project}/compose.test.yaml" ;;
      esac

      merged="$(mktemp)"
      # cleaned up on both paths: under `set -e` a yq failure leaves
      # immediately and the temporary file survives the run.
      if ! yq eval-all 'select(fileIndex==0) * select(fileIndex==1)' \
        "${SERVICE_DIR}/compose.fragment.yaml" \
        "${SERVICE_DIR}/compose.${lane}.fragment.yaml" > "$merged"; then
        rm -f "$merged"
        die "could not assemble ${service}'s ${lane} block"
      fi

      if ! SERVICE_IMAGE="$SERVICE_IMAGE" yq --inplace \
        ".services.${key}.image = strenv(SERVICE_IMAGE)" "$merged"; then
        rm -f "$merged"
        die "could not set ${service}'s image"
      fi

      if ! yq eval-all --inplace 'select(fileIndex==0) * select(fileIndex==1)' \
        "$file" "$merged"; then
        rm -f "$merged"
        die "could not merge ${service} into ${file}"
      fi
      rm -f "$merged"
    done

    # Only the production lane carries an application service to wait on; the
    # dev and test lanes are the service on its own.
    yq --inplace \
      ".services.app.depends_on.${key}.condition = \"service_healthy\"" \
      "${project}/compose.yaml"
  done
}
```

- [ ] **Step 6: Call it from `cmd_new`**

In `scaffold`, in `cmd_new`, immediately after `init_project "$target" "$name"`:

```bash
  # Hardcoded for now; Task 9 replaces this with the --db and --cache flags.
  assemble_compose "$target" mysql
```

- [ ] **Step 7: Run the tests**

```bash
mise exec -- bats tests/service.bats
mise exec -- bats tests/compose.bats
mise run lint
```

Expected: all pass. `compose.bats` proves `docker compose config` still
validates an assembled stack.

- [ ] **Step 8: Commit**

```bash
git add services/mysql lib/service.sh common/compose*.yaml scaffold tests/service.bats
git commit -m "feat: assemble the compose stack from the services a project selected"
```

---

### Task 3: `example.env` assembly and the password loop

**Files:**
- Create: `services/mysql/env.fragment`
- Modify: `lib/service.sh` (add `assemble_example_env`)
- Modify: `common/example.env`
- Modify: `common/install.sh`
- Modify: `scaffold` (`cmd_new`)
- Modify: `tests/service.bats`, `tests/compose.bats`

**Interfaces:**
- Consumes: `load_service` (Task 1).
- Produces: `assemble_example_env <project> <service>...` — appends each
  service's `env.fragment` to the project's `example.env`.
- Produces (in `common/install.sh`): `generate_service_passwords <file>` —
  replaces every `*_PASSWORD=changeme` line with a fresh random value.

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "assemble_example_env appends only the selected services' variables" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/example.env" "$project/"

  run assemble_example_env "$project" mysql
  assert_ok
  run grep -qx 'DB_PASSWORD=changeme' "${project}/example.env"
  assert_ok
}

@test "example.env carries no database variables until a service adds them" {
  run grep -c '^DB_' "${SCAFFOLD_ROOT}/common/example.env"
  [ "$output" = "0" ]
}
```

Append to `tests/compose.bats`:

```bash
@test "install.sh generates a password for every service that has one" {
  # DB_PASSWORD was a hardcoded name in three places, so a project with a
  # cache as well as a database left REDIS_PASSWORD on the literal default
  # and nothing said so.
  cd "$PROJECT"
  cat > env.fixture <<'EOF'
DB_PASSWORD=changeme
REDIS_PASSWORD=changeme
APP_PORT=8080
EOF
  run bash -c "source ./install.sh 2>/dev/null; generate_service_passwords env.fixture"
  assert_ok
  run grep -c '=changeme$' env.fixture
  [ "$output" = "0" ]
}
```

`source ./install.sh` runs `main` at the bottom of the file. Guard it so
sourcing is safe — that is step 4.

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/service.bats
```

Expected: FAIL — `assemble_example_env: command not found`.

- [ ] **Step 3: Write the fragment, strip `example.env`, add the assembler**

`services/mysql/env.fragment`:

```
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=changeme
```

`common/example.env` becomes:

```
# copy to .env and edit. install.sh does this for you and generates a random
# value for every password below in place of the literal `changeme`. the
# database and cache variables are appended by scaffold from whichever
# services the project selected.
IMAGE_TAG=latest
APP_PORT=8080
```

Append to `lib/service.sh`:

```bash
# assemble_example_env <project> <service>...
# The infrastructure side of a service's configuration. What the application
# itself needs is written by that service's driver, in the application's own
# .env.example, because DB_CONNECTION is Laravel's phrasing and DATABASE_URL
# is Prisma's for the same server.
assemble_example_env() {
  local project="$1"; shift
  local service

  for service in "$@"; do
    load_service "$service"
    [ -f "${SERVICE_DIR}/env.fragment" ] || continue
    printf '\n' >> "${project}/example.env"
    cat "${SERVICE_DIR}/env.fragment" >> "${project}/example.env"
  done
}
```

- [ ] **Step 4: Rewrite the password handling in `common/install.sh`**

Replace `generate_database_password` with:

```bash
# Every *_PASSWORD the assembled .env carries, not one hardcoded name: a
# project may have a database, a cache, both or neither, and a name that was
# right when this was written stops being generated the moment the set
# changes — silently, because nothing reads back what it did not expect.
#
# Fails hard if a substitution misses: a password staying "changeme" because
# example.env's text drifted is a credential defaulting to a known value.
#
# Known, not fixed: each password is briefly visible in sed's argv to other
# local users. Pre-existing in the immich script this came from.
generate_service_passwords() {
  local file="$1" name password
  while IFS= read -r name; do
    password="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
    sed -i.bak "s/^${name}=changeme\$/${name}=${password}/" "$file"
    rm -f "${file}.bak"
    grep -qF "${name}=${password}" "$file" || {
      echo "could not set ${name} in ${file}; refusing to start with an unconfirmed password"
      return 1
    }
  done < <(sed -n 's/^\([A-Z_]*_PASSWORD\)=changeme$/\1/p' "$file")
}
```

Update the two call sites and the kept-`.env` guard in
`download_release_assets`:

```bash
    if grep -qE '^[A-Z_]*_PASSWORD=changeme$' .env; then
      echo ".env still has a password set to changeme; set real values in .env before running this again"
      return 1
    fi
```

```bash
  if ! generate_service_passwords "$tmp_env"; then
```

Update the comment above `download_release_assets` — it names
`DB_PASSWORD=changeme` and `production postgres` specifically:

```bash
# A kept .env is still checked for any password left at changeme, so an
# upgrade cannot leave a production service on the literal default.
```

Guard the bottom of the file so the test can source it:

```bash
# sourced by the toolbox's tests to exercise one function at a time; running
# main on source would try to download a release from a CHANGEME url.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main
fi
```

- [ ] **Step 5: Call the assembler from `cmd_new`**

In `scaffold`, directly below the `assemble_compose` call from Task 2:

```bash
  assemble_example_env "$target" mysql
```

- [ ] **Step 6: Run the tests**

```bash
mise exec -- bats tests/service.bats tests/compose.bats
mise run lint
```

Expected: all pass, shellcheck clean (`install.sh` is in `mise run lint`'s
file list).

- [ ] **Step 7: Commit**

```bash
git add services/mysql/env.fragment lib/service.sh common/example.env \
        common/install.sh scaffold tests/service.bats tests/compose.bats
git commit -m "feat: build example.env from the selected services, and generate every password"
```

---

### Task 4: Framework families and the Dockerfile anchor

**Files:**
- Modify: `adapters/nextjs/adapter.env`, `adapters/nestjs/adapter.env`,
  `adapters/laravel-api/adapter.env`, `adapters/laravel-inertia/adapter.env`
- Modify: `adapters/laravel-api/Dockerfile`, `adapters/laravel-inertia/Dockerfile`,
  `adapters/nestjs/Dockerfile`
- Modify: `lib/service.sh` (add `apply_service_setup`)
- Modify: `lib/adapter.sh` (`apply_adapter` calls it)
- Modify: `tests/service.bats`

**Interfaces:**
- Produces: `ADAPTER_FAMILY` in every `adapters/*/adapter.env`, one of
  `laravel`, `nest`, `next`.
- Produces: `apply_service_setup <app-dir> <block>` — replaces the
  `# @SERVICE_SETUP@` line in that directory's Dockerfile with `<block>`, or
  removes the line when `<block>` is empty.

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "every adapter declares a framework family" {
  for adapter in "${SCAFFOLD_ROOT}"/adapters/*/; do
    grep -Eq '^ADAPTER_FAMILY="(laravel|nest|next)"$' "${adapter}adapter.env" \
      || { echo "no ADAPTER_FAMILY in ${adapter}adapter.env"; false; }
  done
}

@test "every adapter Dockerfile carries the service anchor" {
  for adapter in "${SCAFFOLD_ROOT}"/adapters/*/; do
    grep -q '^# @SERVICE_SETUP@$' "${adapter}Dockerfile" \
      || { echo "no @SERVICE_SETUP@ anchor in ${adapter}Dockerfile"; false; }
  done
}

@test "apply_service_setup removes the anchor when nothing was selected" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_setup "$app" ""
  assert_ok
  run grep -q '@SERVICE_SETUP@' "${app}/Dockerfile"
  [ "$status" -ne 0 ]
}

@test "apply_service_setup splices in every selected service's block" {
  local app="${BATS_TEST_TMPDIR}/app"
  mkdir -p "$app"
  printf 'FROM scratch\n# @SERVICE_SETUP@\nCMD ["true"]\n' > "${app}/Dockerfile"

  run apply_service_setup "$app" "$(printf 'RUN one\nRUN two\n')"
  assert_ok
  run grep -q '^RUN one$' "${app}/Dockerfile"
  assert_ok
  run grep -q '^RUN two$' "${app}/Dockerfile"
  assert_ok
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/service.bats
```

Expected: FAIL on all four new tests.

- [ ] **Step 3: Add `ADAPTER_FAMILY` to the four adapters**

Insert below the existing `ADAPTER_LANGUAGE` line in each file:

- `adapters/nextjs/adapter.env`: `ADAPTER_FAMILY="next"`
- `adapters/nestjs/adapter.env`: `ADAPTER_FAMILY="nest"`
- `adapters/laravel-api/adapter.env`: `ADAPTER_FAMILY="laravel"`
- `adapters/laravel-inertia/adapter.env`: `ADAPTER_FAMILY="laravel"`

Above the first one, add the explanation once — in
`adapters/laravel-api/adapter.env`:

```sh
# The two laravel adapters need identical service wiring, so drivers are keyed
# on this rather than on the adapter name: one file per family, not two files
# holding the same thing and drifting apart.
ADAPTER_FAMILY="laravel"
```

- [ ] **Step 4: Add the anchor to the three Dockerfiles**

In `adapters/laravel-api/Dockerfile` and `adapters/laravel-inertia/Dockerfile`,
replace the `RUN apk add --no-cache postgresql-dev ...` line in the runtime
stage with:

```dockerfile
RUN docker-php-ext-install opcache
# @SERVICE_SETUP@
```

The anchor is a comment, not a `sed` target on a functional line: rewriting a
real instruction stops matching the moment somebody reformats the file, and
reports nothing when it stops.

In `adapters/nestjs/Dockerfile`, put the anchor in the build stage, after the
dependency install and before the build command, because `prisma generate`
writes the client `tsc` types against:

```dockerfile
# @SERVICE_SETUP@
```

`adapters/nextjs/Dockerfile` gets the anchor too, in its build stage, so the
test above holds for every adapter. The `next` family has no drivers, so it is
always replaced with nothing — which is exactly what the empty-block path
above covers.

- [ ] **Step 5: Write `apply_service_setup`**

Append to `lib/service.sh`:

```bash
# apply_service_setup <app-dir> <block>
# Replaces the Dockerfile's anchor comment with the concatenated output of
# every selected service's driver. Concatenated rather than substituted per
# service, so `--db mongodb --cache redis` produces two blocks instead of one
# overwriting the other.
apply_service_setup() {
  local app="$1" block="$2"
  local file="${app}/Dockerfile"

  [ -f "$file" ] || return 0
  grep -q '^# @SERVICE_SETUP@$' "$file" \
    || die "no @SERVICE_SETUP@ anchor in ${file}"

  local rendered; rendered="$(mktemp)"
  awk -v block="$block" '
    /^# @SERVICE_SETUP@$/ { if (block != "") printf "%s\n", block; next }
    { print }
  ' "$file" > "$rendered"
  mv "$rendered" "$file"
}
```

- [ ] **Step 6: Run the tests**

```bash
mise exec -- bats tests/service.bats
mise run lint
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add adapters lib/service.sh tests/service.bats
git commit -m "feat: name each adapter's framework family and open a seam in its Dockerfile"
```

---

### Task 5: Drivers, and MySQL end to end

**Files:**
- Create: `services/shared/laravel.sh`, `services/shared/nest.sh`
- Create: `services/mysql/drivers/laravel.sh`, `services/mysql/drivers/nest.sh`
- Modify: `lib/service.sh` (add `write_env_lines`, `apply_service_drivers`)
- Modify: `lib/adapter.sh` (`apply_adapter` runs the drivers)
- Modify: `adapters/nestjs/mise.toml`
- Modify: `adapters/laravel-api/.env.example`,
  `adapters/laravel-inertia/.env.example`, `adapters/nestjs/.env.example`
- Modify: `tests/service.bats`, `tests/new-laravel-api.bats`

**Interfaces:**
- Consumes: `load_service`, `ADAPTER_FAMILY` (Tasks 1, 4).
- Produces: `write_env_lines <file> <line>...` — sets each `KEY=value`,
  replacing an existing `KEY=` line or appending a new one.
- Produces: `apply_service_drivers <app-dir> <family> <service>...` — sources
  each service's driver for that family, runs `service_driver_apply` in the
  application directory, collects `service_driver_dockerfile` output, and
  calls `apply_service_setup` once with the concatenation.
- Produces: driver contract — each `services/<name>/drivers/<family>.sh`
  defines `service_driver_apply` (runs with the application directory as its
  working directory) and `service_driver_dockerfile` (prints Dockerfile lines
  to stdout, prints nothing when the family needs none).

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "write_env_lines replaces a key rather than duplicating it" {
  local file="${BATS_TEST_TMPDIR}/.env.example"
  printf 'DB_HOST=localhost\nAPP_ENV=local\n' > "$file"

  run write_env_lines "$file" "DB_HOST=database" "DB_PORT=3306"
  assert_ok
  run grep -c '^DB_HOST=' "$file"
  [ "$output" = "1" ]
  run grep -qx 'DB_HOST=database' "$file"
  assert_ok
  run grep -qx 'DB_PORT=3306' "$file"
  assert_ok
}

@test "every database service has a driver for every family that takes one" {
  # A missing file means the combination was never wired. It never means the
  # tier does not need one — the web role is excluded by role, above.
  local service family
  for service in "${SCAFFOLD_ROOT}"/services/*/; do
    [ -f "${service}service.env" ] || continue
    for family in laravel nest; do
      [ -f "${service}drivers/${family}.sh" ] \
        || { echo "no ${family} driver in ${service}"; false; }
    done
  done
}
```

Append to `tests/new-laravel-api.bats` (this suite already generates a real
project; reuse its fixture rather than generating a second one):

```bash
@test "the api is configured for the project's database" {
  run grep -qx 'DB_CONNECTION=mysql' "${PROJECT}/apps/api/.env.example"
  assert_ok
  run grep -q 'pdo_mysql' "${PROJECT}/apps/api/Dockerfile"
  assert_ok
  run grep -q '@SERVICE_SETUP@' "${PROJECT}/apps/api/Dockerfile"
  [ "$status" -ne 0 ]
}
```

Read the top of `tests/new-laravel-api.bats` first and use whatever variable
that suite already names its generated project with.

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/service.bats
```

Expected: FAIL — `write_env_lines: command not found`, no drivers present.

- [ ] **Step 3: Add the two helpers to `lib/service.sh`**

```bash
# write_env_lines <file> <line>...
# Sets each KEY=value, replacing the key if it is already there. A driver runs
# against an .env.example the adapter shipped, so appending blindly would
# leave two values for one key and let the loser win depending on the reader.
write_env_lines() {
  local file="$1"; shift
  local line key

  [ -f "$file" ] || : > "$file"
  for line in "$@"; do
    key="${line%%=*}"
    if grep -q "^${key}=" "$file"; then
      sed -i.bak "s|^${key}=.*|${line}|" "$file"
      rm -f "${file}.bak"
    else
      printf '%s\n' "$line" >> "$file"
    fi
  done
}

# apply_service_drivers <app-dir> <family> <service>...
# A service knows how to run a container; a driver knows how one framework
# talks to it. Runs in a subshell per driver so a driver's parameters cannot
# leak into the next one.
apply_service_drivers() {
  local app="$1" family="$2"; shift 2
  local service driver block=""

  # web is the presentation tier and takes no driver — the caller decides
  # that from ADAPTER_ROLE, so reaching here with a family that has none is a
  # wiring mistake, not a supported case.
  for service in "$@"; do
    load_service "$service"
    driver="${SERVICE_DIR}/drivers/${family}.sh"
    [ -f "$driver" ] \
      || die "${service} has no driver for ${family} — run 'scaffold lint'"

    ( cd "$app" \
        && SERVICE_DIR="$SERVICE_DIR" \
        && . "$driver" \
        && service_driver_apply ) \
      || die "the ${service} driver failed for ${family}"

    block+="$( . "$driver"; service_driver_dockerfile )"$'\n'
  done

  apply_service_setup "$app" "${block%$'\n'}"
}
```

- [ ] **Step 4: Write the two shared driver bodies**

`services/shared/laravel.sh` — sourced by a service's `laravel.sh`, which sets
the parameters first:

```bash
# shellcheck shell=bash
# The Laravel database driver. A service's drivers/laravel.sh sets the four
# parameters below and sources this, so the logic lives once and each service
# records only what is different about it.
#
#   LARAVEL_CONNECTION  the DB_CONNECTION value
#   LARAVEL_PORT        the default port for .env.example
#   LARAVEL_PACKAGE     a composer package to require, or ""
#   LARAVEL_SETUP       the Dockerfile block, or ""

service_driver_apply() {
  [ -z "$LARAVEL_PACKAGE" ] \
    || composer require "$LARAVEL_PACKAGE" --no-interaction

  write_env_lines .env.example \
    "DB_CONNECTION=${LARAVEL_CONNECTION}" \
    "DB_HOST=database" \
    "DB_PORT=${LARAVEL_PORT}" \
    "DB_DATABASE=app" \
    "DB_USERNAME=app" \
    "DB_PASSWORD=app"
}

service_driver_dockerfile() {
  [ -z "$LARAVEL_SETUP" ] || printf '%s\n' "$LARAVEL_SETUP"
}
```

`services/shared/nest.sh`:

```bash
# shellcheck shell=bash
# The Prisma driver. A service's drivers/nest.sh sets the two parameters below
# and sources this. One client API across every database this toolbox ships is
# why Prisma was chosen over TypeORM — the adapter x service matrix collapses
# to a single code path.
#
#   PRISMA_PROVIDER  the datasource provider
#   PRISMA_URL       the DATABASE_URL for .env.example

service_driver_apply() {
  pnpm add @prisma/client
  pnpm add -D prisma
  mkdir -p prisma

  # datasource and generator only. models describe the client's domain, which
  # this toolbox does not know — see the spec's non-goals.
  cat > prisma/schema.prisma <<EOF
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "${PRISMA_PROVIDER}"
  url      = env("DATABASE_URL")
}
EOF

  write_env_lines .env.example "DATABASE_URL=${PRISMA_URL}"
}

service_driver_dockerfile() {
  printf 'RUN pnpm exec prisma generate\n'
}
```

- [ ] **Step 5: Write the two MySQL drivers**

`services/mysql/drivers/laravel.sh`:

```bash
# shellcheck shell=bash
LARAVEL_CONNECTION="mysql"
LARAVEL_PORT="3306"
# pdo_mysql needs no distribution package; it builds from the php source the
# image already carries.
LARAVEL_PACKAGE=""
LARAVEL_SETUP="RUN docker-php-ext-install pdo_mysql"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
```

`services/mysql/drivers/nest.sh`:

```bash
# shellcheck shell=bash
PRISMA_PROVIDER="mysql"
PRISMA_URL="mysql://app:app@localhost:3306/app"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
```

- [ ] **Step 6: Run the drivers from `apply_adapter`**

In `lib/adapter.sh`, in `apply_adapter`, after the `ADAPTER_POST_GENERATE`
block and before `register_config_root`:

```bash
  # After post-generate: the generator and its own follow-up have settled the
  # package manager's state by here, and .env.example has been copied in from
  # the adapter, which is the file the driver edits.
  if [ "${ADAPTER_ROLE}" != "web" ] && [ "${#SCAFFOLD_SERVICES[@]}" -gt 0 ]; then
    apply_service_drivers "$dest" "$ADAPTER_FAMILY" "${SCAFFOLD_SERVICES[@]}"
  else
    # The anchor is not optional: a Dockerfile shipping it verbatim would fail
    # to build.
    apply_service_setup "$dest" ""
  fi
```

`SCAFFOLD_SERVICES` is set by `cmd_new`. Add it to `scaffold`, above `main`:

```bash
# The services this run selected, read by apply_adapter. A global rather than
# another apply_adapter parameter: it is one value for the whole run, and
# apply_adapter already takes three.
SCAFFOLD_SERVICES=()
```

and populate it in `cmd_new` where Task 2 hardcoded `mysql`:

```bash
  SCAFFOLD_SERVICES=(mysql)
  assemble_compose "$target" "${SCAFFOLD_SERVICES[@]}"
  assemble_example_env "$target" "${SCAFFOLD_SERVICES[@]}"
```

- [ ] **Step 7: Add the Prisma step to the nestjs contract tasks**

In `adapters/nestjs/mise.toml`, add above `[tasks.check]`:

```toml
[tasks.prisma]
# prisma writes the client that tsc type-checks against, so it has to run
# before check and before build — the same shape as the nextjs adapter's
# `next typegen`. A project generated with --db none has no schema and no
# prisma, and this does nothing; a real prisma failure still fails.
run = "if [ -f prisma/schema.prisma ]; then pnpm exec prisma generate; fi"
```

and make `check` and `build` depend on it:

```toml
[tasks.check]
run = [{ task = ":prisma" }, "pnpm exec tsc --noEmit"]

[tasks.build]
run = [{ task = ":prisma" }, "pnpm exec nest build"]
```

- [ ] **Step 8: Strip the database lines from the adapters' `.env.example`**

`adapters/laravel-api/.env.example` and `adapters/laravel-inertia/.env.example`
lose every `DB_*` line, keeping the rest. `adapters/nestjs/.env.example` loses
its `DATABASE_URL` line, keeping `PORT=3001`. Add one line to each explaining
the absence:

```
# the database variables are written by the selected service's driver
```

- [ ] **Step 9: Run the tests**

```bash
mise exec -- bats tests/service.bats
mise exec -- bats tests/new-laravel-api.bats
mise exec -- bats tests/new-nestjs.bats
mise run lint
```

Expected: all pass. The Nest suite is the one that proves `prisma generate`
did not break `check` or `build`.

- [ ] **Step 10: Commit**

```bash
git add services lib/service.sh lib/adapter.sh scaffold adapters tests
git commit -m "feat: wire the selected database into the application, not just the stack"
```

---

### Task 6: PostgreSQL

**Files:**
- Create: `services/postgres/service.env`, four compose fragments,
  `env.fragment`, `drivers/laravel.sh`, `drivers/nest.sh`
- Modify: `tests/service.bats`

**Interfaces:**
- Consumes: everything from Tasks 1-5. Adds no new function.

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "postgres assembles a valid stack" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" postgres
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/service.bats
```

Expected: FAIL with `unknown service: postgres`.

- [ ] **Step 3: Resolve the image digest**

```bash
docker buildx imagetools inspect docker.io/library/postgres:17-alpine \
  --format '{{.Manifest.Digest}}'
```

- [ ] **Step 4: Write the service**

`services/postgres/service.env`:

```sh
SERVICE_NAME="postgres"
SERVICE_KIND="database"
SERVICE_IMAGE="docker.io/library/postgres:17-alpine@sha256:<digest>"
```

`services/postgres/compose.fragment.yaml`:

```yaml
services:
  database:
    environment:
      POSTGRES_DB: ${DB_DATABASE:-app}
      POSTGRES_USER: ${DB_USERNAME:-app}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-app}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME:-app}"]
      interval: 10s
      timeout: 5s
      retries: 5
```

`services/postgres/compose.prod.fragment.yaml`:

```yaml
services:
  database:
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD:-changeme}
    volumes:
      - database:/var/lib/postgresql/data
    restart: always
volumes:
  database:
```

`services/postgres/compose.dev.fragment.yaml`:

```yaml
services:
  database:
    ports:
      # loopback, not 0.0.0.0: docker publishes to every interface by default
      # and its iptables rules bypass most host firewalls, so the bare form
      # exposes this password-is-"app" database to the whole local network.
      - "127.0.0.1:5432:5432"
```

`services/postgres/compose.test.fragment.yaml`:

```yaml
services:
  database:
    tmpfs:
      - /var/lib/postgresql/data
```

`services/postgres/env.fragment`:

```
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=changeme
```

`services/postgres/drivers/laravel.sh`:

```bash
# shellcheck shell=bash
LARAVEL_CONNECTION="pgsql"
LARAVEL_PORT="5432"
LARAVEL_PACKAGE=""
LARAVEL_SETUP="RUN apk add --no-cache postgresql-dev \\
 && docker-php-ext-install pdo_pgsql"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
```

`services/postgres/drivers/nest.sh`:

```bash
# shellcheck shell=bash
PRISMA_PROVIDER="postgresql"
PRISMA_URL="postgresql://app:app@localhost:5432/app"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
```

- [ ] **Step 5: Run the tests**

```bash
mise exec -- bats tests/service.bats
mise run lint
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add services/postgres tests/service.bats
git commit -m "feat: postgresql as a selectable service"
```

---

### Task 7: MongoDB

**Files:**
- Create: `services/mongodb/service.env`, four compose fragments,
  `env.fragment`, `drivers/laravel.sh`, `drivers/nest.sh`
- Modify: `tests/service.bats`

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "mongodb assembles a valid stack" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" mongodb
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
}
```

- [ ] **Step 2: Run it to verify it fails**

Expected: FAIL with `unknown service: mongodb`.

- [ ] **Step 3: Resolve the image digest**

```bash
docker buildx imagetools inspect docker.io/library/mongo:8.0 \
  --format '{{.Manifest.Digest}}'
```

- [ ] **Step 4: Write the service**

`services/mongodb/service.env`:

```sh
SERVICE_NAME="mongodb"
SERVICE_KIND="database"
SERVICE_IMAGE="docker.io/library/mongo:8.0@sha256:<digest>"
```

`services/mongodb/compose.fragment.yaml`:

```yaml
services:
  database:
    environment:
      MONGO_INITDB_DATABASE: ${DB_DATABASE:-app}
      MONGO_INITDB_ROOT_USERNAME: ${DB_USERNAME:-app}
      MONGO_INITDB_ROOT_PASSWORD: ${DB_PASSWORD:-app}
    healthcheck:
      # mongosh, not a tcp probe: the port is open well before the server will
      # accept a query, and a check that passes early is worse than none —
      # depends_on releases the application into a database that is not ready.
      test: ["CMD", "mongosh", "--quiet", "--eval", "db.adminCommand('ping')"]
      interval: 10s
      timeout: 5s
      retries: 5
```

`services/mongodb/compose.prod.fragment.yaml`:

```yaml
services:
  database:
    environment:
      MONGO_INITDB_ROOT_PASSWORD: ${DB_PASSWORD:-changeme}
    volumes:
      - database:/data/db
    restart: always
volumes:
  database:
```

`services/mongodb/compose.dev.fragment.yaml`:

```yaml
services:
  database:
    ports:
      - "127.0.0.1:27017:27017"
```

`services/mongodb/compose.test.fragment.yaml`:

```yaml
services:
  database:
    tmpfs:
      - /data/db
```

`services/mongodb/env.fragment`:

```
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=changeme
```

`services/mongodb/drivers/laravel.sh` — the one cell that needs both a
composer package and a built extension:

```bash
# shellcheck shell=bash
LARAVEL_CONNECTION="mongodb"
LARAVEL_PORT="27017"
LARAVEL_PACKAGE="mongodb/laravel-mongodb"
# pecl, not apk: the mongodb extension is not in alpine's repositories, so it
# is built here — which is why this block installs the build dependencies and
# nothing else does.
LARAVEL_SETUP="RUN apk add --no-cache --virtual .build-deps \$PHPIZE_DEPS openssl-dev \\
 && pecl install mongodb \\
 && docker-php-ext-enable mongodb \\
 && apk del .build-deps"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/laravel.sh"
```

`services/mongodb/drivers/nest.sh`:

```bash
# shellcheck shell=bash
PRISMA_PROVIDER="mongodb"
# directConnection, because prisma's mongodb provider otherwise expects a
# replica set and a single-node container is not one.
PRISMA_URL="mongodb://app:app@localhost:27017/app?authSource=admin&directConnection=true"
# shellcheck source=/dev/null
. "${SCAFFOLD_ROOT}/services/shared/nest.sh"
```

- [ ] **Step 5: Verify the Laravel + MongoDB image actually builds**

This cell is the only one that compiles an extension, so prove it before
trusting it:

```bash
WORK="$(mktemp -d)"
mise exec -- ./scaffold new "${WORK}/mongo-check" --api laravel-api
# Task 9 adds --db; until then, edit SCAFFOLD_SERVICES in cmd_new to
# (mongodb) for this one run, or run this step again after Task 9.
docker build -t scaffold-mongo-check "${WORK}/mongo-check/apps/api"
```

Expected: the build succeeds and `pecl install mongodb` completes. If it
fails, fix `LARAVEL_SETUP` before committing — a driver that produces an
unbuildable image is worse than no driver, because `scaffold lint` will
report the cell as covered.

- [ ] **Step 6: Run the tests**

```bash
mise exec -- bats tests/service.bats
mise run lint
```

- [ ] **Step 7: Commit**

```bash
git add services/mongodb tests/service.bats
git commit -m "feat: mongodb as a selectable service"
```

---

### Task 8: Redis

**Files:**
- Create: `services/redis/service.env`, four compose fragments,
  `env.fragment`, `drivers/laravel.sh`, `drivers/nest.sh`
- Modify: `tests/service.bats`

**Interfaces:**
- First service with `SERVICE_KIND="cache"`, so this is what exercises
  `service_compose_key`'s second branch and a two-service assembly.
- Its drivers are self-contained rather than sourcing `services/shared/`:
  there is one cache, so a shared body would be an abstraction with a single
  caller. Extract one when a second cache arrives.

- [ ] **Step 1: Write the failing test**

Append to `tests/service.bats`:

```bash
@test "a database and a cache assemble side by side" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/compose.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.dev.yaml" \
     "${SCAFFOLD_ROOT}/common/compose.test.yaml" "$project/"

  run assemble_compose "$project" mysql redis
  assert_ok
  run yq -e '.services.database != null and .services.cache != null' \
    "${project}/compose.yaml"
  assert_ok
  run yq -e '.services.app.depends_on | keys | length == 2' \
    "${project}/compose.yaml"
  assert_ok
  cd "$project"
  run docker compose -f compose.yaml config --quiet
  assert_ok
}

@test "a cache contributes its own password to example.env" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  cp "${SCAFFOLD_ROOT}/common/example.env" "$project/"

  run assemble_example_env "$project" mysql redis
  assert_ok
  run grep -c '=changeme$' "${project}/example.env"
  [ "$output" = "2" ]
}
```

- [ ] **Step 2: Run it to verify it fails**

Expected: FAIL with `unknown service: redis`.

- [ ] **Step 3: Resolve the image digest**

```bash
docker buildx imagetools inspect docker.io/library/redis:8-alpine \
  --format '{{.Manifest.Digest}}'
```

- [ ] **Step 4: Write the service**

`services/redis/service.env`:

```sh
SERVICE_NAME="redis"
SERVICE_KIND="cache"
SERVICE_IMAGE="docker.io/library/redis:8-alpine@sha256:<digest>"
```

`services/redis/compose.fragment.yaml` — the image has no auth by default, so
the password is passed as a server argument:

```yaml
services:
  cache:
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:-app}"]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD:-app}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
```

`services/redis/compose.prod.fragment.yaml` — persistence on, because a cache
holding sessions and queues is not a cache a restart may empty:

```yaml
services:
  cache:
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD:-changeme}", "--appendonly", "yes"]
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASSWORD:-changeme}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - cache:/data
    restart: always
volumes:
  cache:
```

`services/redis/compose.dev.fragment.yaml`:

```yaml
services:
  cache:
    ports:
      - "127.0.0.1:6379:6379"
```

`services/redis/compose.test.fragment.yaml`:

```yaml
services:
  cache:
    tmpfs:
      - /data
```

`services/redis/env.fragment`:

```
REDIS_PASSWORD=changeme
```

`services/redis/drivers/laravel.sh`:

```bash
# shellcheck shell=bash
# Self-contained rather than sourcing services/shared/: redis is the only
# cache, so a shared body would have exactly one caller. Extract one when a
# second cache arrives.
service_driver_apply() {
  # predis, not the phpredis extension: a composer package needs no build
  # stage, and this is the only difference between the two for a cache this
  # size.
  composer require predis/predis --no-interaction

  write_env_lines .env.example \
    "REDIS_CLIENT=predis" \
    "REDIS_HOST=cache" \
    "REDIS_PORT=6379" \
    "REDIS_PASSWORD=app" \
    "CACHE_STORE=redis" \
    "SESSION_DRIVER=redis" \
    "QUEUE_CONNECTION=redis"
}

service_driver_dockerfile() {
  :
}
```

`services/redis/drivers/nest.sh`:

```bash
# shellcheck shell=bash
service_driver_apply() {
  pnpm add @nestjs/cache-manager cache-manager @keyv/redis

  write_env_lines .env.example "REDIS_URL=redis://:app@localhost:6379"
}

service_driver_dockerfile() {
  :
}
```

- [ ] **Step 5: Run the tests**

```bash
mise exec -- bats tests/service.bats
mise run lint
```

- [ ] **Step 6: Commit**

```bash
git add services/redis tests/service.bats
git commit -m "feat: redis as a selectable cache"
```

---

### Task 9: The `--db` and `--cache` flags

**Files:**
- Modify: `scaffold` (`usage`, `cmd_new`)
- Modify: `lib/service.sh` (add `record_services`)
- Modify: `common/mise.root.toml`
- Modify: `tests/add-app-errors.bats` (the offline error suite), `tests/service.bats`

**Interfaces:**
- Consumes: `load_service`, `assemble_compose`, `assemble_example_env`.
- Produces: `record_services <project> <database> <cache>` — writes the
  selection into the project's `mise.toml` `[vars]` table by substituting the
  `@DATABASE@` and `@CACHE@` placeholders `mise.root.toml` ships.
- Produces: `project_service <project> <key>` — reads one back, printing the
  empty string when the project predates this or the value is `none`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/add-app-errors.bats` — this suite is in the offline
`test-unit` lane and every case below is refused before a generator runs:

```bash
@test "scaffold new rejects an unknown database" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --api laravel-api --db orable
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown service: orable"* ]]
}

@test "scaffold new rejects a cache in the database slot" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --api laravel-api --db redis
  [ "$status" -eq 1 ]
  [[ "$output" == *"redis is a cache, not a database"* ]]
}

@test "scaffold new refuses a database for a project with no backend" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --web nextjs --db mysql
  [ "$status" -eq 1 ]
  [[ "$output" == *"no application to connect it"* ]]
}

@test "scaffold new rejects a repeated --db" {
  run scaffold new "${BATS_TEST_TMPDIR}/p" --db mysql --db postgres
  [ "$status" -eq 1 ]
  [[ "$output" == *"--db given more than once"* ]]
}
```

Append to `tests/service.bats`:

```bash
@test "record_services and project_service round-trip" {
  local project="${BATS_TEST_TMPDIR}/proj"
  mkdir -p "$project"
  sed 's|@PROJECT_NAME@|demo|g' "${SCAFFOLD_ROOT}/common/mise.root.toml" \
    > "${project}/mise.toml"

  run record_services "$project" mysql none
  assert_ok
  run project_service "$project" database
  assert_ok
  [ "$output" = "mysql" ]
  run project_service "$project" cache
  assert_ok
  [ -z "$output" ]
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
mise exec -- bats tests/add-app-errors.bats tests/service.bats
```

Expected: FAIL — the flags are not parsed and `record_services` does not
exist.

- [ ] **Step 3: Add the placeholders to `common/mise.root.toml`**

Below `monorepo_root = true`:

```toml
# The services this project was generated against. `scaffold add` reads these
# so an application added later is wired to the same database as the first
# one. Changing them here does not migrate anything — see the toolbox's
# ADR-0019.
[vars]
database = "@DATABASE@"
cache = "@CACHE@"
```

- [ ] **Step 4: Write `record_services` and `project_service`**

Append to `lib/service.sh`:

```bash
# record_services <project> <database> <cache>
# mise.root.toml ships the two placeholders; substituting them is the same
# technique as @PROJECT_NAME@ rather than a second way of writing toml.
record_services() {
  local project="$1" database="$2" cache="$3"
  local file="${project}/mise.toml"

  sed -i.bak -e "s|@DATABASE@|${database}|" -e "s|@CACHE@|${cache}|" "$file"
  rm -f "${file}.bak"

  grep -q '@DATABASE@\|@CACHE@' "$file" \
    && die "could not record the selected services in ${file} — has [vars] been reformatted?"
  return 0
}

# project_service <project> <database|cache>
# Prints nothing for `none`, and nothing for a project generated before this
# existed, so a caller can test the value rather than compare it to a word.
project_service() {
  local project="$1" key="$2" value

  value="$(yq -p toml -oy -r ".vars.${key} // \"\"" "${project}/mise.toml" 2>/dev/null || true)"
  [ "$value" = "none" ] || [ "$value" = "null" ] && return 0
  printf '%s' "$value"
}
```

- [ ] **Step 5: Parse the flags in `cmd_new`**

Extend `usage`:

```
  scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
                      [--db <service>] [--cache <service>]
```

In `cmd_new`, add two locals beside `requested` and extend the option loop:

```bash
  local database="" cache=""
```

```bash
      --db|--cache)
        [ $# -ge 2 ] || die "${1} requires a service name"
        case "$1" in
          --db)
            [ -z "$database" ] || die "--db given more than once"
            database="$2" ;;
          --cache)
            [ -z "$cache" ] || die "--cache given more than once"
            cache="$2" ;;
        esac
        shift 2
        ;;
```

After the loop, before `require_git_identity`, resolve and validate. Every
check here runs before anything is written, so a bad combination costs no
generation:

```bash
  # A project with no api or app adapter has nothing to connect: the web tier
  # takes no driver, so it would get a running database, a set of variables,
  # and no way to reach either.
  local has_backend=0 entry
  for entry in "${requested[@]-}"; do
    case "$entry" in
      api:*|app:*) has_backend=1 ;;
    esac
  done

  if [ -z "$database" ]; then
    [ "$has_backend" -eq 1 ] && database="mysql" || database="none"
  fi
  [ -n "$cache" ] || cache="none"

  local -a services=()
  if [ "$database" != none ]; then
    [ "$has_backend" -eq 1 ] \
      || die "--db ${database} but there is no application to connect it — add --api or --app"
    load_service "$database"
    [ "$SERVICE_KIND" = database ] \
      || die "${database} is a ${SERVICE_KIND}, not a database"
    services+=("$database")
  fi
  if [ "$cache" != none ]; then
    [ "$has_backend" -eq 1 ] \
      || die "--cache ${cache} but there is no application to connect it — add --api or --app"
    load_service "$cache"
    [ "$SERVICE_KIND" = cache ] \
      || die "${cache} is a ${SERVICE_KIND}, not a cache"
    services+=("$cache")
  fi
```

Replace the hardcoded block from Task 5 with:

```bash
  SCAFFOLD_SERVICES=("${services[@]-}")
  record_services "$target" "$database" "$cache"
  assemble_compose "$target" "${services[@]-}"
  assemble_example_env "$target" "${services[@]-}"
```

- [ ] **Step 6: Run the tests**

```bash
mise exec -- bats tests/add-app-errors.bats tests/service.bats
mise exec -- bats tests/new-project.bats
mise run lint
```

- [ ] **Step 7: Verify a real project end to end**

```bash
WORK="$(mktemp -d)"
mise exec -- ./scaffold new "${WORK}/demo" --api laravel-api --db postgres --cache redis
cd "${WORK}/demo"
docker compose -f compose.yaml config --quiet
grep -x 'DB_CONNECTION=pgsql' apps/api/.env.example
grep -x 'CACHE_STORE=redis' apps/api/.env.example
grep -c '=changeme$' example.env   # expect 2
mise run //apps/api:checklist
```

- [ ] **Step 8: Commit**

```bash
git add scaffold lib/service.sh common/mise.root.toml tests
git commit -m "feat: choose the database and cache at generation time"
```

---

### Task 10: `scaffold add` uses the recorded services

**Files:**
- Modify: `scaffold` (`cmd_add`)
- Modify: `tests/add-app.bats`

**Interfaces:**
- Consumes: `project_service` (Task 9).

- [ ] **Step 1: Write the failing test**

Append to `tests/add-app.bats` — reuse the project this suite already
generates; read its setup first for the variable names it uses:

```bash
@test "an app added later is wired to the project's own database" {
  cd "$PROJECT"
  run scaffold add apps/api --adapter nestjs
  assert_ok
  run grep -q '^DATABASE_URL=' "${PROJECT}/apps/api/.env.example"
  assert_ok
  run grep -q 'provider = "mysql"' "${PROJECT}/apps/api/prisma/schema.prisma"
  assert_ok
}
```

Adjust the adapter and the expected provider to whatever this suite's fixture
project was generated with; the assertion that matters is that the added
application names the *same* database the project recorded.

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/add-app.bats
```

Expected: FAIL — no `prisma/schema.prisma`, because `SCAFFOLD_SERVICES` is
empty on the `add` path.

- [ ] **Step 3: Populate `SCAFFOLD_SERVICES` in `cmd_add`**

In `scaffold`, in `cmd_add`, after the `monorepo_root` guard proves this is a
scaffold project and before `apply_adapter`:

```bash
  # Read back rather than asked for: an application added in month six is
  # wired to the database the project has had since month one, and a second
  # answer to a question already settled is a way for the two to disagree.
  local recorded
  SCAFFOLD_SERVICES=()
  for recorded in database cache; do
    recorded="$(project_service "$project" "$recorded")"
    [ -n "$recorded" ] && SCAFFOLD_SERVICES+=("$recorded")
  done
```

- [ ] **Step 4: Run the tests**

```bash
mise exec -- bats tests/add-app.bats tests/add-app-errors.bats
mise run lint
```

- [ ] **Step 5: Commit**

```bash
git add scaffold tests/add-app.bats
git commit -m "feat: scaffold add wires the new app to the project's own services"
```

---

### Task 11: The lint gates

**Files:**
- Modify: `lib/contract.sh`, `lib/lint.sh`, `scaffold` (`cmd_lint`, `cmd_list`)
- Create: `tests/fixtures/lint-services/missing-driver/`,
  `tests/fixtures/lint-services/complete/`
- Modify: `tests/contract.bats`

**Interfaces:**
- Consumes: `load_service`.
- Produces: `lint_services <services-dir> <adapters-dir>` — prints one line
  per problem, returns 1 when any service is incomplete or any (service,
  family) cell is unwired.
- Produces: `ADAPTER_FAMILY` added to `REQUIRED_ADAPTER_VARS`, so a new
  adapter without one fails `scaffold lint` rather than dying mid-generation
  on an unbound variable.

- [ ] **Step 1: Write the failing test**

Append to `tests/contract.bats`:

```bash
@test "lint_services accepts the services that ship" {
  run lint_services "${SCAFFOLD_ROOT}/services" "${SCAFFOLD_ROOT}/adapters"
  assert_ok
  [ -z "$output" ]
}

@test "lint_services reports a service missing a driver" {
  # The gate exists so an adapter in a new family cannot merge until every
  # service has been taught about it. A gate that cannot fail is worse than
  # no gate, so this fixture proves this one can.
  run lint_services \
    "${SCAFFOLD_ROOT}/tests/fixtures/lint-services/missing-driver" \
    "${SCAFFOLD_ROOT}/adapters"
  [ "$status" -eq 1 ]
  [[ "$output" == *"sample: no driver for laravel"* ]]
}

@test "lint_adapters requires a framework family" {
  run lint_adapters "${SCAFFOLD_ROOT}/tests/fixtures/lint/no-generator"
  [ "$status" -eq 1 ]
  [[ "$output" == *"adapter.env does not set ADAPTER_FAMILY"* ]]
}

@test "scaffold lint covers the services that ship" {
  run scaffold lint
  assert_ok
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/contract.bats
```

Expected: FAIL — `lint_services: command not found`.

- [ ] **Step 3: Build the fixtures**

```bash
cd /home/ttndev/workspace/personal/scaffold
mkdir -p tests/fixtures/lint-services/missing-driver/sample/drivers
cat > tests/fixtures/lint-services/missing-driver/sample/service.env <<'EOF'
SERVICE_NAME="sample"
SERVICE_KIND="database"
SERVICE_IMAGE="docker.io/library/busybox:1@sha256:0000000000000000000000000000000000000000000000000000000000000000"
EOF
for lane in "" .prod .dev .test; do
  printf 'services:\n  database: {}\n' \
    > "tests/fixtures/lint-services/missing-driver/sample/compose${lane}.fragment.yaml"
done
printf 'DB_PASSWORD=changeme\n' \
  > tests/fixtures/lint-services/missing-driver/sample/env.fragment
printf '# shellcheck shell=bash\nservice_driver_apply() { :; }\nservice_driver_dockerfile() { :; }\n' \
  > tests/fixtures/lint-services/missing-driver/sample/drivers/nest.sh
```

The fixture has a `nest` driver and no `laravel` one, which is the case the
second test asserts.

- [ ] **Step 4: Extend `lib/contract.sh`**

```bash
REQUIRED_ADAPTER_VARS=(ADAPTER_NAME ADAPTER_ROLE ADAPTER_FAMILY ADAPTER_GENERATOR)

# apply_service_drivers sources these and calls both, so a service shipping
# neither fails at generation rather than at lint.
REQUIRED_SERVICE_FILES=(
  service.env
  compose.fragment.yaml
  compose.prod.fragment.yaml
  compose.dev.fragment.yaml
  compose.test.fragment.yaml
  env.fragment
)

REQUIRED_SERVICE_VARS=(SERVICE_NAME SERVICE_KIND SERVICE_IMAGE)

# The web tier is the presentation layer and opens no connection, so it takes
# no driver — stated once, about the role, rather than as a "not applicable"
# entry repeated in every service.
DRIVEN_ROLES=(api app)
```

- [ ] **Step 5: Write `lint_services`**

Append to `lib/lint.sh`:

```bash
# lint_services <services-dir> <adapters-dir>
# prints one line per problem and returns 1 when any service is incomplete or
# any family that takes a driver has no driver in some service.
lint_services() {
  local dir="$1" adapters="$2"
  local service name file var family status=0
  local -a families=()

  # The families to require, read from the adapters themselves rather than
  # listed here: a list would be a second copy of the same fact, and the copy
  # is what goes stale.
  local adapter role
  for adapter in "$adapters"/*/; do
    [ -f "${adapter}adapter.env" ] || continue
    role="$(sed -n 's/^ADAPTER_ROLE="\(.*\)"$/\1/p' "${adapter}adapter.env")"
    case " ${DRIVEN_ROLES[*]} " in
      *" ${role} "*) ;;
      *) continue ;;
    esac
    family="$(sed -n 's/^ADAPTER_FAMILY="\(.*\)"$/\1/p' "${adapter}adapter.env")"
    [ -n "$family" ] || continue
    case " ${families[*]-} " in
      *" ${family} "*) ;;
      *) families+=("$family") ;;
    esac
  done

  for service in "$dir"/*/; do
    [ -d "$service" ] || continue
    name="$(basename "$service")"
    # services/shared holds the parameterised driver bodies, not a service
    [ "$name" = shared ] && continue

    for file in "${REQUIRED_SERVICE_FILES[@]}"; do
      if [ ! -f "${service}${file}" ]; then
        printf '%s: missing file %s\n' "$name" "$file"
        status=1
      fi
    done

    if [ -f "${service}service.env" ]; then
      for var in "${REQUIRED_SERVICE_VARS[@]}"; do
        grep -Eq "^${var}=" "${service}service.env" || {
          printf '%s: service.env does not set %s\n' "$name" "$var"
          status=1
        }
      done
      grep -q '@sha256:' "${service}service.env" || {
        printf '%s: SERVICE_IMAGE is not pinned by digest\n' "$name"
        status=1
      }
    fi

    for family in "${families[@]-}"; do
      [ -f "${service}drivers/${family}.sh" ] || {
        printf '%s: no driver for %s\n' "$name" "$family"
        status=1
      }
    done
  done

  return "$status"
}
```

- [ ] **Step 6: Extend `cmd_lint`**

In `scaffold`:

```bash
cmd_lint() {
  local status=0
  lint_adapters "${SCAFFOLD_ROOT}/adapters" || status=1
  lint_services "${SCAFFOLD_ROOT}/services" "${SCAFFOLD_ROOT}/adapters" || status=1
  return "$status"
}
```

Both run even when the first fails: reporting one problem, fixing it, and
finding the next is three round trips where one would do.

- [ ] **Step 7: Show services in `scaffold list`**

In `cmd_list`, after the adapter loop, add the services:

```bash
  local service
  for service in "${SCAFFOLD_ROOT}"/services/*/; do
    [ -d "$service" ] || continue
    name="$(basename "$service")"
    [ "$name" = shared ] && continue
    if ( load_service "$name" >/dev/null 2>&1 ); then
      ( load_service "$name" >/dev/null 2>&1
        printf '%s\t%s\t%s\n' "$SERVICE_NAME" "$SERVICE_KIND" "-" )
    else
      output+=("[error]"$'\t'"$name"$'\t'"(malformed service)")
      status=1
    fi
  done
```

Fold that into the existing `output` array rather than printing separately, so
the single `sort` at the end still orders the whole listing.

- [ ] **Step 8: Run the tests**

```bash
mise exec -- bats tests/contract.bats tests/cli.bats tests/service.bats
mise run lint
```

- [ ] **Step 9: Commit**

```bash
git add lib/contract.sh lib/lint.sh scaffold tests
git commit -m "feat: lint the services and the driver matrix"
```

---

### Task 12: Test lanes

**Files:**
- Modify: `mise.toml`
- Modify: `.github/workflows/adapters.yml`
- Modify: `tests/contract.bats`

**Interfaces:**
- Consumes: nothing new. Places `tests/service.bats` in the offline lane and
  adds the scheduled matrix.

- [ ] **Step 1: Write the failing test**

`tests/contract.bats` already asserts that every suite in `test-unit` is
offline. Add the complement — that the new suite is actually in a lane:

```bash
@test "tests/service.bats runs in a lane" {
  run grep -q 'tests/service.bats' "${SCAFFOLD_ROOT}/mise.toml"
  assert_ok
}
```

A suite nobody runs is the shape that let two dot-github tests sit skipped
through every CI run.

- [ ] **Step 2: Run it to verify it fails**

```bash
mise exec -- bats tests/contract.bats
```

Expected: FAIL — `service.bats` is in no lane.

- [ ] **Step 3: Add the suite to the offline lane**

In `mise.toml`, extend `[tasks."test-unit"]`'s file list with
`tests/service.bats`. It generates no project: every case either operates on
copied `common/` files or on a fixture in `BATS_TEST_TMPDIR`.

The two `docker compose config` assertions need docker but no network beyond
image metadata; if that makes the lane unreliable on a runner, move only
those two cases into `tests/compose.bats` rather than moving the suite.

- [ ] **Step 4: Add the scheduled service matrix**

In `.github/workflows/adapters.yml`, add a job. The `if` reuses the two cron
strings already in the file:

```yaml
  services:
    # Four databases and two caches across two families is eight combinations
    # per adapter, and one tier a generation costs minutes — so the full grid
    # is nightly, and every pull request gets the default cell through
    # tests/new-*.bats instead.
    if: ${{ github.event_name == 'schedule' || github.event_name == 'workflow_dispatch' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    timeout-minutes: 40
    strategy:
      fail-fast: false
      matrix:
        adapter: [laravel-api, nestjs]
        db: [mysql, postgres, mongodb, none]
        cache: [none, redis]
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - uses: jdx/mise-action@c2a87611a18de5b3828c5652fe268e992400cb5c # v4.3.0
      - run: corepack enable
      - uses: shivammathur/setup-php@f3e473d116dcccaddc5834248c87452386958240 # 2.37.2
        with:
          php-version: "8.3"
      - env:
          ADAPTER: ${{ matrix.adapter }}
          DB: ${{ matrix.db }}
          CACHE: ${{ matrix.cache }}
        run: |
          work="$(mktemp -d)"
          ./scaffold new "${work}/demo" --api "$ADAPTER" --db "$DB" --cache "$CACHE"
          cd "${work}/demo"
          docker compose -f compose.yaml config --quiet
          docker compose -f compose.test.yaml config --quiet
          mise run //apps/api:checklist
```

Add `services` to `notify-on-schedule-failure`'s `needs` and to its `if`
condition, or a red matrix cell lands in a schedule tab nobody opens:

```yaml
    if: >-
      ${{ always() && github.event_name == 'schedule' &&
      (needs.smoke.result == 'failure' || needs.smoke-tier-b.result == 'failure' ||
       needs.compose.result == 'failure' || needs.services.result == 'failure') }}
    needs: [smoke, smoke-tier-b, compose, services]
```

- [ ] **Step 5: Verify the workflow parses**

```bash
mise exec -- actionlint .github/workflows/adapters.yml
mise exec -- zizmor .github/workflows/adapters.yml
```

- [ ] **Step 6: Run the whole suite under runner conditions**

```bash
CI=true mise run test-runner
```

This is the eight-minute feedback loop that three consecutive CI failures came
from skipping. Run it before pushing, not after.

- [ ] **Step 7: Commit**

```bash
git add mise.toml .github/workflows/adapters.yml tests/contract.bats
git commit -m "ci: run the service matrix nightly and the default cell on every change"
```

---

### Task 13: Documentation

**Files:**
- Create: `docs/decisions/0019-services-are-not-adapters.md`
- Create: `docs/decisions/0020-mysql-is-the-default-database.md`
- Modify: `docs/tour/07-containers.md`, `docs/tour/08-adapters.md`,
  `README.md`, `CONTRIBUTING.md`

- [ ] **Step 1: Write ADR-0019**

Match the existing ADRs' format — read `docs/decisions/0012-tiered-adapter-support.md`
first and follow its heading structure exactly. Content:

- **Context:** a database owns no `apps/<role>` directory, has no
  `ADAPTER_GENERATOR`, and satisfies none of `REQUIRED_ADAPTER_FILES`.
- **Decision:** `services/` is a sibling category with its own manifest, its
  own lint, and drivers keyed on framework family.
- **Consequences:** adding a service costs one directory; adding an adapter in
  a new family costs one file per service, enforced by `scaffold lint`;
  changing a project's database after generation is not supported.
- **Rejected:** a new `ADAPTER_ROLE`, which would require loosening every
  invariant `lib/lint.sh` enforces — a check loosened until it cannot fail
  still reads like a guarantee.

- [ ] **Step 2: Write ADR-0020**

- **Context:** PostgreSQL was never chosen; it was the only option, written
  into three compose files and two Dockerfiles.
- **Decision:** `--db` defaults to `mysql` when the project has an `api` or
  `app` adapter, and to `none` otherwise.
- **Consequences:** projects generated from 2026-09-03 differ from earlier
  ones; `scaffold` never revisits a generated project, so nothing migrates.
  A frontend-only project stops shipping a database.

- [ ] **Step 3: Update the tour**

`docs/tour/07-containers.md`: replace the passage describing a fixed
PostgreSQL service with how the three compose files are assembled — the
common files ship the application service alone, each selected service
contributes a body plus a per-lane delta, and the image digest lives only in
`service.env`. Point at ADR-0019.

`docs/tour/08-adapters.md`: add `ADAPTER_FAMILY` to the description of
`adapter.env`, and a paragraph on the `# @SERVICE_SETUP@` anchor and what a
driver is expected to do.

- [ ] **Step 4: Update `README.md`**

Extend the usage block:

```sh
scaffold new <name> [--web <adapter>] [--api <adapter>] [--app <adapter>]
                    [--db <service>] [--cache <service>]
```

and add a services table beside the adapter tier table: `mysql` (default),
`postgres`, `mongodb`, `redis`, and `none` for either slot.

- [ ] **Step 5: Update `CONTRIBUTING.md`**

Add a section on adding a service: the six required files, one driver per
family, and `scaffold lint` as the gate. State that a new framework family
means a driver in every existing service, which is why the lint requires the
full matrix.

- [ ] **Step 6: Verify the documentation tests still pass**

```bash
mise exec -- bats tests/documentation.bats tests/docs.bats
```

`documentation.bats` checks that documented commands and paths exist; a usage
block naming a flag that does not parse fails there.

- [ ] **Step 7: Commit**

```bash
git add docs README.md CONTRIBUTING.md
git commit -m "docs: how services are selected, assembled and wired"
```

---

### Task 14: Full verification

- [ ] **Step 1: Lint and the full suite under runner conditions**

```bash
cd /home/ttndev/workspace/personal/scaffold
mise run lint
mise exec -- ./scaffold lint
CI=true mise run test-runner
```

- [ ] **Step 2: Generate one project per database, by hand**

```bash
WORK="$(mktemp -d)"
for db in mysql postgres mongodb; do
  mise exec -- ./scaffold new "${WORK}/${db}" --api laravel-api --db "$db" --cache redis
  ( cd "${WORK}/${db}" \
      && docker compose -f compose.yaml config --quiet \
      && docker compose -f compose.test.yaml config --quiet \
      && mise run //apps/api:checklist )
done
mise exec -- ./scaffold new "${WORK}/none" --web nextjs
grep -c 'depends_on' "${WORK}/none/compose.yaml"   # expect 0
```

- [ ] **Step 3: Confirm the tree is clean**

```bash
git status --short
```

Expected: empty. A generation run inside the toolbox has committed
`node_modules` here before.

- [ ] **Step 4: Push and open a pull request**

```bash
git push -u origin feat/service-adapters
```

Follow `.github/pull_request_template.md` — CI's `pull-request-body` job
parses the headings out of that file and fails a body missing any of them.

---

## Self-Review

**Spec coverage.** Section 4 (service category) is Task 1; section 5 (compose
and `example.env` assembly, the password loop) is Tasks 2-3; section 6 (the
driver matrix, the Dockerfile anchor, Prisma and the task contract) is Tasks
4-8; section 7 (command surface, defaults, the web-tier refusal) is Task 9;
section 8 (recording the choice) is Tasks 9-10; section 9 (changes to existing
files) is spread across Tasks 2-5 and 13; section 10 (layered testing) is
Task 12; section 11 (known limits) is documented in Task 13's two ADRs.

**Type consistency.** `load_service`, `service_compose_key`, `assemble_compose`,
`assemble_example_env`, `apply_service_setup`, `write_env_lines`,
`apply_service_drivers`, `record_services`, `project_service`, `lint_services`
are each defined in exactly one task and used under the same name afterwards.
`SCAFFOLD_SERVICES`, `ADAPTER_FAMILY`, `SERVICE_KIND`, `DRIVEN_ROLES`,
`LARAVEL_*` and `PRISMA_*` likewise.

**Known soft spots, called out rather than hidden.**

1. Three image digests (Tasks 1, 6, 7, 8) cannot be written here — they are
   resolved by a `docker buildx imagetools inspect` command in the step that
   needs them.
2. Task 5 and Task 10's tests reuse fixtures from suites this plan does not
   quote in full (`tests/new-laravel-api.bats`, `tests/add-app.bats`). Read
   each suite's `setup()` before writing the assertion and use its own
   variable names.
3. Task 7's `pecl install mongodb` block is the only cell that compiles an
   extension, so Task 7 step 5 builds the image rather than trusting the
   Dockerfile block to be right.
4. Task 12 places `tests/service.bats` in the offline lane on the assumption
   that `docker compose config` needs no network. If a runner disagrees, move
   the two `docker compose config` cases to `tests/compose.bats` — not the
   whole suite.
