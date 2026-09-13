# API

A Flask application. It implements this project's task contract, so every
check runs the same way here as in any other config root:

```sh
mise run //<this-root>:ci-unit    # install, format, lint, check, test
```

`mise.toml` in this directory is the whole story of how those tasks are wired.

## conftest.py is intentionally empty

It exists only so pytest's default `prepend` import mode adds this directory
to `sys.path`; without it, `from app import create_app` in the tests raises
`ModuleNotFoundError`. There is nothing to configure, so the file is empty.

## Why python is pinned in .python-version, not mise.toml

uv resolves its own managed interpreter and reads `.python-version` for the
pin; a `python` tool entry in `mise.toml` would install a second interpreter
that uv never uses.
