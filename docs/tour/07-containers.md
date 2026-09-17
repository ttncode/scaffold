# 07 — Containers

## What it does

- Every adapter ships a multi-stage `Dockerfile` that exposes 8080 and has a `HEALTHCHECK` on its `ADAPTER_LIVENESS_PATH`.
- `compose.yaml` is the released stack (ADR-0014); `compose.dev.yaml` runs throwaway services for an app outside docker; `compose.test.yaml` runs them on tmpfs.
- Each app gets one compose service and one image, named after its directory (ADR-0022).
- Each selected service merges `compose.fragment.yaml` plus a per-lane delta into all three files; an api or app service `depends_on` it as `service_healthy` in `compose.yaml` (ADR-0019).
- A service's image digest lives only in its `service.env`; `assemble_compose` writes it in.

![Generated project](../diagrams/generated-project.svg)

## Read this

| File | Why |
| --- | --- |
| `adapters/laravel-api/Dockerfile` | composer vendor stage, FrankenPHP runtime, `HEALTHCHECK` on `/up` |
| `adapters/nestjs/Dockerfile` | Same shape; probes `/health/live` |
| `lib/service.sh` | `assemble_compose`, `service_compose_key` (`database` or `cache`), `add_app_service` |
| `lib/manifest.sh` | `register_image_target`: one image per app in the build and release workflows |
| `services/mysql/` | One full service: `service.env`, four compose fragments, `env.fragment`, `drivers/` |
| `scripts/deploy-check.sh` | The only gate that starts containers and calls the app over HTTP (ADR-0021) |

## Delete test

Delete the `HEALTHCHECK` line from `adapters/nestjs/Dockerfile` and `tests/compose.bats` fails:
"every adapter Dockerfile probes the liveness path its adapter declares".
That test reads text only; whether the app really answers is checked by `scripts/deploy-check.sh`.

## Try it

```bash
docker compose -f common/compose.dev.yaml config --quiet && echo valid
```
