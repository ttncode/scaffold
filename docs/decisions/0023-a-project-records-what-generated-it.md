# 0023 — A project records what generated it

Status: Accepted
Date: 2026-09-11

## Context

ADR-0005 opens by stating the problem this record finishes:

> A project generated in January carries January's CI pipeline forever unless
> something keeps it current — there is no prune step, no template sync,
> nothing that revisits a generated project after it exists.

That ADR solved it for one thing: the workflow bodies moved into a second
repository behind a moving `v1` tag, so a CI fix reaches every project at
once. It worked — moving `v1` for ADR-0022 brought multi-image builds to
`acme-portal` without editing a file in it.

Everything else stayed frozen. Every `Dockerfile`, `lefthook.yml`,
`renovate.json`, `install.sh`, `commitlint.config.js`, every compose fragment,
every file an adapter overlays: fixed at the moment the project was generated,
with no mechanism to revisit it.

Measured on the day of this record. Twelve fixes landed in one session.
`acme-portal`, generated a few hours earlier, received none of them: no
`README.md`, a first commit Release Please ignores so it has never cut a
release and `install.sh` has nothing to download, one image where it should
publish two, and an empty `deploy-adapters/` directory. Nothing existed that
could tell it otherwise.

Worse, nothing in a generated project recorded which toolbox produced it. Even
doing the work by hand was guesswork: there is no answer to "what changed since
this was generated" without an answer to "generated when".

With one or two projects a person copies the files across. At five the copying
stops happening, the projects drift to different states, and nobody can say
which state any of them is in.

## Decision

**A generated project records its own origin** in `.scaffold.toml`: the
toolbox commit (`git describe`, `-dirty` included), and the adapter behind
each application. `scaffold add` appends a line. A file of its own rather than
another `mise.toml` `[vars]` entry, because the apps table is a mapping and
mise's vars are flat strings.

**`scaffold update` brings across what the project never received.** The files
scaffold owns in a project came from `common/` and `adapters/<name>/` at the
recorded commit, so `git diff <recorded>..HEAD` over those paths is exactly the
set of missed changes. The patch's paths are rewritten onto the project's own
layout (`common/lefthook.yml` → `lefthook.yml`, `adapters/nextjs/Dockerfile` →
`apps/web/Dockerfile`) and its placeholders substituted with the project's real
values, because the context lines have to match the project or no hunk applies.

**Applied with `git apply --reject`, not `--3way`.** Measured: a three-way
merge needs the pre-image blobs, which live in this toolbox's object database
and not the project's, so git reports the missing blob and falls back to a
direct apply — and a direct apply is atomic, so one diverged file discards
every other file's changes. `--reject` works per hunk: what fits lands, what
does not is written beside it as a `.rej` naming exactly what a human still has
to place.

**What is computed is re-derived, not patched.** The CI matrix comes from
`config_roots` and the build targets from the applications; the templates carry
their uncomputed forms (`roots: '[]'`, `images: "[]"`). Applying those verbatim
would leave a project building nothing, and it would read in `git diff` as a
comment change. After the patch, `sync_ci_roots` runs and the build targets are
rebuilt from the manifest — only when the array actually came back empty, so a
project whose targets survived is untouched.

**It refuses a dirty working tree**, because `git diff` afterwards is the only
review this gets and it has to show one run's changes alone. It never commits.

## Consequences

- A fix to the toolbox can reach projects that already exist, for the first
  time. `scaffold update --dry-run` answers "what has this project missed"
  without touching it.
- A project generated before this can adopt it by writing `.scaffold.toml` by
  hand; the command refuses with the exact file to write. Verified on a real
  clone of `acme-portal`: eight files updated (its `README.md` created, the
  empty `deploy-adapters/` removed, `install.sh`, `docs/deployment.md` and
  three workflows brought forward) and five rejects, each on a file scaffold
  computes or the services rewrite.
- **An update moves files, not structure.** ADR-0022 changed how compose
  services and build targets are shaped; no patch can perform that migration on
  a project built the old way, and the hunks that would half-perform it are
  exactly the ones that reject. That is the honest outcome: a `.rej` the
  operator reads beats a silent half-migration.
- `.rej` files are untracked litter until someone deals with them. The command
  names every one it wrote; nothing deletes them.
- A project generated from a dirty toolbox records `-dirty` and cannot be
  updated at all, because there is no commit to diff from. The command says
  so rather than failing on an unknown revision.
- A project whose adapter has since been removed from the toolbox is skipped
  for that application, with a warning, rather than failing the whole run.

## Alternatives considered

- **Report only (`scaffold diff`).** Rejected as the whole feature, kept as
  part of it: `--dry-run` prints the patch and changes nothing, so the
  cautious mode costs nothing extra and the expensive half of the work is
  still done for people who want it.
- **Regenerate and three-way merge (cruft, copier).** Generate the project
  twice — once at the recorded commit, once at HEAD — and diff the two trees.
  More correct in principle, and rejected on two measurements: a generation
  takes minutes, so an update would take ten, and `pnpm-lock.yaml` differs
  between two runs of the same inputs, so the diff would carry noise unrelated
  to any toolbox change.
- **Keeping the record in `mise.toml`.** Rejected: the apps table is a
  mapping, mise's `[vars]` are flat strings, and nesting tables under a key
  mise parses itself invites a break in someone else's tool.
- **Excluding the computed files from the patch** (as `mise.root.toml` is
  excluded). Rejected: `build.yml` and `ci.yml` are mostly parts nobody
  computes, and dropping them entirely would throw away every change to those
  parts forever.
