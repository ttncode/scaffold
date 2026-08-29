# Deployment

This project distributes a container image; it does not deploy it for you.
`.github/workflows/build.yml` publishes `main` and `sha-<commit>` tags on
every push to `main`. `.github/workflows/release.yml` additionally publishes
semver tags (`1.4.0`, `1.4`) plus `latest` when a release is cut. Both are the
same image; they differ only in which tag names it.

`compose.yaml` and `example.env` are attached to every GitHub Release, so a
deployment target always fetches a matching pair rather than whatever is on
`main`. `install.sh` downloads both, generates a random database password,
and starts the stack — safe to re-run: it always overwrites `compose.yaml`
with the release's own copy, and never touches an existing `.env`.

## Two delivery modes, one pipeline

They differ only in which `IMAGE_TAG` the deployment sets.

|              | Client operates the host     | Author operates the host |
| ------------ | ---------------------------- | ------------------------ |
| `IMAGE_TAG`  | `1.4.0`, pinned deliberately | `main`, moving           |
| Upgrades     | The client chooses when      | Every merge              |
| `install.sh` | Handed to the client         | Used by the author       |

## Before the first deploy

`compose.yaml`'s `app.image` ships as a placeholder — ghcr.io, org and image
both spelled CHANGEME — because this project was generated before it had a
repository or a published image. Edit that line, and `install.sh`'s
`RepoUrl`, once — after the repository exists and its first image has been
published. Neither changes again after that.
