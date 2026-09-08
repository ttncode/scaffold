# Deployment

This project distributes a container image; it does not deploy it for you.
`.github/workflows/build.yml` publishes `main` and `sha-<commit>` tags on
every push to `main`. `.github/workflows/release.yml` additionally publishes
semver tags (`1.4.0`, `1.4`) plus `latest` when a release is cut. Both are the
same image; they differ only in which tag names it.

`compose.yaml` and `example.env` are attached to every GitHub Release, so a
deployment target always fetches a matching pair rather than whatever is on
`main`. `install.sh` downloads both, generates a random database password,
signs in to the registry when it needs to, starts the stack, and applies the
schema — safe to re-run: it always overwrites `compose.yaml` with the
release's own copy, and never touches an existing `.env`.

## If this project is private

A private project needs a token, and it needs it for two separate reasons —
a token carrying only one of the two scopes fails in only one of the two
places:

```sh
GITHUB_TOKEN=ghp_... bash install.sh
```

- **`repo`**, to download the release assets. A private release's browser
  download URL returns 404 *even with a token attached*, so `install.sh`
  fetches assets through the GitHub API instead. Without that, an operator
  who hits a 404, adds a token, and hits another 404 concludes the token is
  wrong and looks in the wrong place.
- **`read:packages`**, to pull the image. A package's visibility on ghcr is
  separate from its repository's, so a private package refuses an anonymous
  pull with `unauthorized` even when the repository is public.

`jq` is required on the host for this path only — `install.sh` uses it to
read the release's JSON. A public project needs neither the token nor `jq`,
and behaves exactly as it always has.

## Two delivery modes, one pipeline

They differ only in which `IMAGE_TAG` the deployment sets.

|              | Client operates the host     | Author operates the host |
| ------------ | ---------------------------- | ------------------------ |
| `IMAGE_TAG`  | `1.4.0`, pinned deliberately | `main`, moving           |
| Upgrades     | The client chooses when      | Every merge              |
| `install.sh` | Handed to the client         | Used by the author       |

## Before the first deploy

Nothing, if the GitHub repository is named after this project's directory.

`compose.yaml`'s `app.image`, `install.sh`'s `RepoUrl`, and the image
`build.yml` and `release.yml` push to were all written at generation time
from the same owner and project name, so they already agree.

If the repository was renamed, all four need the new name. `install.sh`
re-downloads `compose.yaml` from the latest release on every run, so change
it in this repository and cut a release — a hand-edit to a deployed copy is
undone the next time the script runs.
