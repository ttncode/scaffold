# 04 — Guardrails

## What it does

A generated project ships four independent layers that all have to agree
before code lands on `main`: lefthook runs formatting, a secret scan, and a
commit-message check locally, before a commit is even made; CI (via
*you/.github*'s security workflow) repeats the secret scan and adds
`zizmor` (workflow-injection scanning) and CodeQL, because a local hook can
always be bypassed with `--no-verify`; Renovate opens the dependency-bump
pull requests those checks then have to pass; and branch protection on
`main` is the one piece that isn't a file at all — a repository setting
that makes the required checks actually block a merge instead of just
turning red.

## Read this

- `common/lefthook.yml` — `pre-commit` (prettier, gitleaks), `commit-msg`
  (commitlint), `pre-push` (the full `checklist`).
- `common/commitlint.config.js` — Conventional Commits, nothing custom.
- `common/renovate.json` — deliberately minimal: `$schema` plus the public
  `config:recommended` preset.
- ADR-0007 for lefthook over husky, ADR-0006 for why every commit has to be
  conventional in the first place (Release Please parses them).
- Upstream for comparison: immich runs no git hooks at all. ADR-0007's
  Context ("Git hooks must work in a PHP-only project") is why this
  project couldn't just reuse immich's tooling wholesale; its Alternatives
  considered section is where husky specifically gets rejected, for being
  Node-only.

## Delete test

`common/renovate.json` is the sharpest lesson in this project. Delete it
and a generated project simply gets no automated dependency updates —
visible, if you go looking. Far worse happened when the file was merely
*wrong* instead of missing: for nine tasks and every review in between,
this repository shipped a byte-for-byte copy of immich's own
`renovate.json` — invalid JSON (a trailing comma), extending an
organisation-internal preset (`local>immich-app/.github:renovate-config`)
no client's Renovate installation could ever resolve, and full of rules
for `mobile/**` and `machine-learning/**` paths that don't exist in a
generated project. It passed every check because the check being asked was
"is this identical to upstream," and the answer was truthfully yes. Nobody
asked "is this right for this project" until `docs/PROVENANCE.md` gave that
question a place to be asked. A file can be verbatim and broken at the same
time; those are different claims.

## Try it

```bash
node -e "import('./common/commitlint.config.js').then(c => console.log(c.default))"
```
