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

`compose.yaml`'s `app.image` ships as a placeholder — ghcr.io, org and image
both spelled CHANGEME — because this project was generated before it had a
repository or a published image. Edit that line, and `install.sh`'s
`RepoUrl`, once — after the repository exists and its first image has been
published. Neither changes again after that.
