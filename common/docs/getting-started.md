# Getting started

```bash
mise install     # exact toolchain versions, from mise.lock
lefthook install # formatting, secret scan, commit-message check
mise run dev     # the compose stack
```

Before opening a pull request, run `mise run checklist`. It runs exactly what
CI runs.

The docs site ships a placeholder logo at `docs/public/logo.png`, borrowed from
[escrcpy](https://github.com/viarotel-org/escrcpy) along with the theme colours
in `docs/.vitepress/theme/vendor/escrcpy/NOTICE`. A logo is a trademark, not
something the Apache licence hands over — replace it with this project's own
mark before the site is published.
