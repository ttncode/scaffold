# Installing a Private Project — Design

Status: approved for planning
Date: 2026-09-07
Scope: `common/install.sh` only. What a client runs on their own host to
start a released stack, when the project they were given is private.

## 1. Context

A real-user acceptance run on 2026-09-07 took two generated projects through
the whole walkthrough — real repositories, real releases, images published to
ghcr — and ran `install.sh` end to end for the first time anywhere. Against a
**public** repository it works: all four of its previously-unrun functions
executed, migrations applied, and both declared health paths returned 200.

Against a **private** repository it fails on its first line.

```
$ bash install.sh
downloading compose.yaml...
curl: (22) The requested URL returned error: 404
could not download the release assets
```

Adding a token does not fix it. Measured against the same private repository:

```
anonymous browser URL       : 404
browser URL + Bearer PAT    : 404
API asset endpoint + Bearer : 200
```

`RepoUrl` is `https://github.com/<owner>/<repo>/releases/latest/download`,
which is a browser redirect that wants a session. A personal access token on
that URL is ignored — the request still 404s. So this is not a missing
credential, it is the wrong endpoint: a private release asset is reachable
only through `api.github.com/repos/<o>/<r>/releases/assets/<id>` with
`Accept: application/octet-stream`.

There is a second half, and it fails independently. A package's visibility on
ghcr is separate from its repository's, and a private package refuses an
anonymous pull:

```
$ docker logout ghcr.io && docker pull ghcr.io/ttncode/<project>:latest
Error response from daemon: Head "https://ghcr.io/v2/...": unauthorized
```

`install.sh` contains no `docker login` and no mention of a registry
credential. So for a private project it is broken in two places, and fixing
only the download would move the failure to `docker compose up` rather than
remove it.

This matters more than a normal defect because of what the surrounding
documents claim. ADR-0014 calls `install.sh` "the one deploy mechanism that
exists today", and step 10 of the walkthrough presents it as the deploy path.
Neither says the project has to be public for that to be true.

## 2. Goals

1. `install.sh` works against a private repository and a private package,
   given a token the operator already needs.
2. The public path is unchanged — same commands, same output, no new
   dependency, no token.
3. A client who does not supply a token against a private project gets a
   message naming what to set, rather than a bare 404.

## 3. Non-goals

- **Any other credential source.** No `gh` CLI, no `~/.netrc`, no keyring.
  A production host may have none of them.
- **A registry other than ghcr.** `compose.yaml`'s image is a ghcr path
  (ADR-0014), and a second registry is a different design.
- **Changing what the release publishes.** The three assets stay as they are.
- **The two-release placeholder problem.** Fixing `ghcr.io/CHANGEME/CHANGEME`
  still requires a repository edit and a second release; that is recorded in
  the runbook and is not this design's subject.

## 4. One token, both halves

`install.sh` takes `GITHUB_TOKEN` from the environment. When it is set, the
script switches both halves to their authenticated form; when it is not, every
line behaves exactly as it does today.

The operator of a private project already needs this token — without one they
cannot pull the image at all — so this asks for nothing they do not have.

**Downloading assets.** With a token, resolve the release through the API and
fetch each asset by its id:

```
GET /repos/<owner>/<repo>/releases/latest
GET /repos/<owner>/<repo>/releases/assets/<id>   Accept: application/octet-stream
```

The owner and repository come from `RepoUrl`, which already carries both and
is already the one line a project edits after its first release.

**Pulling the image.** With a token, `docker login ghcr.io` before
`docker compose up`, using the same token as the password. The username can be
any non-empty string for a token-based ghcr login; use the owner from
`RepoUrl` so a failure names something recognisable.

## 5. Parsing the release, and the trap in it

The API returns JSON and `install.sh` has no JSON parser today. Adding one is
a real cost — it lands on a client's production host, not on ours.

**Use `jq`, required only on the token path.** When `GITHUB_TOKEN` is set and
`jq` is absent, fail immediately with a message naming it. The public path
keeps its current dependencies exactly: `curl` and `docker compose`.

The alternative — a `grep`/`sed` parse — is rejected, and the reason is
specific rather than aesthetic. Measured document order inside a release's
JSON:

```
"id":548466515          <- the asset's own id
"name":"compose.yaml"
"id":41898282           <- the uploader's id
"browser_download_url":"...compose.yaml"
```

The asset's id **precedes** its name, and an uploader id **follows** it. So
the obvious hand-rolled parse — find the name, take the next id — silently
yields the uploader's id for every asset. That request does not fail: it
returns a different, valid object, and the script writes it to `compose.yaml`.
A wrong value that looks like success is the exact defect class this project
has spent weeks removing; a parser that cannot make that mistake is worth one
dependency on a path that is opt-in anyway.

## 6. Failure messages

Each failure must say what to do, because the operator is on their own host
with no access to this repository.

| Condition | What the message says |
|---|---|
| 404 with no token | the project may be private; set `GITHUB_TOKEN` to a token with `repo` and `read:packages` |
| `GITHUB_TOKEN` set, `jq` missing | `jq` is required when installing from a private project |
| API returns 401/403 | the token was rejected; name the two scopes |
| Asset absent from the release | name the asset and say the release may be incomplete |
| `docker login` fails | the token cannot read packages; name `read:packages` |

The existing guard that refuses to start when a password is still `changeme`
stays as it is.

## 7. Changes to files that already exist

| File | Change |
|---|---|
| `common/install.sh` | token-aware `download_release_assets`; a `docker login` step; the messages above |
| `tests/compose.bats` | assertions per section 8 |
| `docs/runbook/first-project-walkthrough.md` | step 10 says what a private project needs |
| `docs/decisions/0014-deployment-deferred-with-seams.md` | its "one deploy mechanism" claim is true only for a public project today; amend, do not rewrite |

## 8. Testing

`install.sh` is sourced per-function by `tests/compose.bats` already, which is
how the `APP_KEY` behaviour is tested. Follow that.

- **The token path picks the asset's own id, not the uploader's.** Feed the
  parser a fixture holding the real document order from section 5 and assert
  the id it returns. This is the one test that must exist: it is the failure
  that would otherwise look like success.
- **No token means no API call.** Assert the public path still builds the
  browser URL, so the change cannot quietly make every client need a token.
- **`GITHUB_TOKEN` set with no `jq` fails with a message naming `jq`.**
- **A 404 without a token names `GITHUB_TOKEN`**, so the operator is not left
  with curl's own text.

**End to end, against a real private repository.** The unit tests above cannot
prove the endpoint is right — that is what this whole design exists to correct,
and the previous round proved that reasoning about an endpoint is not enough.
Run `install.sh` against a private project and a public one, and require both
to reach a served `/health/ready`. A repository and a package in each state
already exist from the 2026-09-07 run.

## 9. Known limits

- **The token is visible in the process list** while `docker login` runs, to
  other local users. `install.sh` already carries this exposure for generated
  passwords in `sed`'s argv, inherited from the immich script it came from.
  Reading the password from stdin (`--password-stdin`) removes it for the
  login half; the API calls pass it in a header, not argv.
- **`jq` becomes a requirement for private installs.** Common, but not
  universal, and it is a dependency on someone else's production host.
- **A fine-grained token needs both `contents: read` and `packages: read`**,
  and the failure modes differ: the first breaks the download, the second
  breaks the pull. The messages distinguish them; nothing validates the token
  up front.
- **Nothing detects a private repository with a public package, or the
  reverse.** Each half fails on its own terms with its own message, which is
  honest but means an operator can be told about two problems in sequence.
