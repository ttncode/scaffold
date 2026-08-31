# API

A NestJS application. It implements this project's task contract, so every
check runs the same way here as in any other config root:

```sh
mise run //<this-root>:ci-unit    # install, format, lint, check, test
mise run //<this-root>:dev        # not part of the contract; see mise.toml
```

`mise.toml` in this directory is the whole story of how those tasks are wired.

## Why this replaces the generator's README

`nest new` writes a README describing NestJS itself, including badge URLs that
carry a placeholder `?token=` query string. gitleaks reads that as a leaked
credential and blocks the first commit of every project — a false positive that
teaches people to ignore the one tool that would catch a real secret.

Documenting the application rather than the framework is the point; not
training anyone to skip a security check is the reason it could not wait.
