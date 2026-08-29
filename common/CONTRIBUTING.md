# Contributing

```bash
mise install     # exact toolchain versions, from mise.lock
lefthook install # formatting, secret scan, commit-message check
mise run dev     # the compose stack
```

Before opening a pull request, run `mise run checklist`. It runs exactly what
CI runs.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/).
