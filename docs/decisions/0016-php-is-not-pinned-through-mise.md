# 0016 — PHP is not pinned through mise

Status: Accepted
Date: 2026-08-27

## Context

Every other adapter pins its language runtime in the app's own `mise.toml`
(`node`, `pnpm`) so the project root never has to know what a given app is
written in. `laravel-api` was built to do the same for `php`, and it fails.

mise's only backends for `php` are `vfox:jdx/vfox-php` and
`asdf:mise-plugins/asdf-php`, and both compile PHP from source on install.
That build dies on this machine with a missing system library:

```
Package 'gdlib', required by 'virtual:world', not found
```

Prebuilt alternatives were checked and rejected before giving up on mise
entirely:

- `static-php-cli` publishes only its own builder tool, not prebuilt PHP
  binaries, so it does not solve the "no compiler toolchain available"
  problem — it moves it.
- mise's registry has no `aqua:` or `ubi:` backend entry for `php` itself
  (unlike `composer`, which does resolve through `ubi:composer/composer`
  and fetches a prebuilt phar — that one is pinned normally).

With no prebuilt route available through mise, the only remaining option
was to depend on a PHP already present on the machine.

## Decision

`laravel-api` relies on system PHP rather than a mise-managed one.
`apps/api/mise.toml` pins nothing for php; its `install` task opens with a
version guard that runs `php -r 'exit(version_compare(PHP_VERSION, "8.3.0",
">=") ? 0 : 1);'` and fails with a message naming the required minimum
(8.3.0, matching the pinned Laravel major's `composer.json` requirement of
`php ^8.3`) and how to get it, before `composer.phar install` ever runs.
Composer itself stays pinned through `ubi:composer/composer`, since that
backend does resolve.

## Consequences

The project root's `mise.toml` still never learns the app is written in
php — the property every other adapter guarantees holds here too.

The cost: CI will need an explicit step that provisions PHP on whatever
runner it uses, because nothing in this repository does. Every other
adapter's toolchain comes from `mise install` alone; this is the first,
permanent exception to "CI never learns what language a project is written
in" — CI at least has to know to provision a PHP interpreter, even though
it still never has to know the app is Laravel specifically. Gated on
`composer.json`'s presence in `dot-github/.github/workflows/app-ci.yml`,
not on an adapter name.

Second, permanent exception: `dot-github/.github/workflows/app-security.yml`'s
CodeQL job names `javascript-typescript` in its language matrix. Unlike
provisioning an interpreter, CodeQL's own API requires naming a language to
scan — there is no file-presence check that avoids the literal string the
way `has-composer` avoids naming Laravel above. What file presence (gated
on `apps/*/package.json`, the same shape as `has-composer`) does fix is the
job running unconditionally: without it, a PHP-only project got a CodeQL
job that scanned its docs site and reported that as security coverage,
which is worse than the language name itself.

## Alternatives considered

- Compiling PHP in CI from source, matching what mise's own backends
  attempt locally. Rejected: the same missing-system-library failure seen
  here would have to be solved with a package-install step anyway, so
  compiling gains nothing over just installing a distro PHP package
  directly, and it is slower on every run.
- Containerizing every contract task for `laravel-api` (running `install`,
  `check`, `test`, etc. inside the adapter's own Docker image instead of
  via `mise run`) so the host never needs a PHP at all. Rejected as
  premature: it would make this adapter's task execution model different
  from every other adapter's, trading one exception (php provisioning) for
  a bigger one (a second way contract tasks run at all).
- A prebuilt PHP through some other backend outside mise's registry
  (e.g. a third-party `ubi`-compatible GitHub release of static PHP
  binaries). Rejected: none was found that mise's `ubi`/`aqua` backends can
  resolve today; revisit if one appears.
