# Getting started

```bash
mise install     # exact toolchain versions, from mise.lock
lefthook install # formatting, secret scan, commit-message check
mise run dev     # the compose stack
```

Before opening a pull request, run `mise run checklist`. It runs exactly what
CI runs.

The docs site ships a placeholder logo at `docs/public/logo.svg`. Replace it
with this project's own mark.
