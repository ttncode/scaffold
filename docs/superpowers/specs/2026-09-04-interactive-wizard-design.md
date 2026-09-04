# Interactive Wizard — Design

Status: approved for planning
Date: 2026-09-04
Follows: `2026-09-03-service-adapters-design.md`, whose section 12 settled this
design's shape by mock.

## 1. Context

`scaffold new` now takes five decisions on the command line — a name, up to
three adapters, a database and a cache:

```
scaffold new shop --web nextjs --api laravel-api --db postgres --cache redis
```

Every one of those names has to be known before the command is typed. `scaffold
list` prints them, but a first-time user does not know it exists, does not know
which adapter fills which role, and does not know that `laravel-inertia` cannot
be combined with `--web` because it is one application serving both tiers. The
command is only obvious to someone who already knows the answer.

Run bare, `scaffold` prints its usage and exits 1. That is the moment a new user
reaches, and it tells them the shape of a command rather than helping them build
one.

## 2. Goals

1. `scaffold`, run with no arguments in a terminal, walks the user to a complete
   selection and generates the project.
2. A combination the command line refuses cannot be assembled in the wizard at
   all — not offered and then rejected.
3. The wizard shows the equivalent `scaffold new` command before running it, so
   the second project is scripted rather than clicked.
4. Nothing about the wizard is a second copy of what adapters and services
   already declare.
5. Anything that is not an interactive terminal behaves exactly as it does
   today.

## 3. Non-goals

- **A menu for `add`, `list` or `lint`.** `new` is the command with five
  interacting decisions; the others take one argument or none.
- **Re-editing an earlier answer.** Ctrl-C and re-run. A back stack is state
  the wizard would have to reconcile against the shape question that gates
  everything after it, for a flow that is four screens long.
- **Remembering the last run.** A preference file is a fourth place a default
  can live, after the flag, the derived rule and the adapter's own declaration.
- **Replacing the flags.** They stay the primary interface. The wizard writes
  them.

## 4. Shape

A wizard: one question per screen, in the order the answers constrain each
other. This is what `npm create astro` and `create-vue` do, and the mock built
during the service-adapter brainstorming compared it against a single screen of
grouped radio buttons.

The single-screen version lost on one concrete point. `laravel-inertia` has
`ADAPTER_ROLE=app` — it *is* both tiers — so on one screen it becomes a third
group whose selection silently invalidates the other two, with nothing on
screen saying so. The user finds out at the summary. Asking the shape first
means that state cannot be represented:

```
? What are you building?

 » ● web+api   separate frontend and backend, one repository
   ○ app       one application serving both pages and data
   ○ api       backend only
   ○ web       frontend only
```

The remaining questions follow from the answer. `web` never asks about a
database, because the web tier has no driver and `scaffold new` refuses
`--db` there (service-adapter spec §7) — the refusal becomes an absence.

| Shape | Then asks |
| --- | --- |
| `web+api` | frontend, backend, database, cache |
| `app` | fullstack framework, database, cache |
| `api` | backend, database, cache |
| `web` | frontend |

## 5. Where the options come from

The wizard shells out to `scaffold list --adapters` and `scaffold list
--services` and groups the rows by the role and kind columns those commands
already print. It hardcodes no adapter name, no service name, and no tier.

This is the design's load-bearing constraint, and it is not theoretical. This
repository has twice shipped a second copy of a list that drifted from the
first: `scripts/adapter-matrix.sh` exists precisely because a CI matrix baked
into a workflow drifts from `adapter.env`, and the service-adapter branch broke
that script by adding rows to `scaffold list` without checking who parsed it.
A wizard with its own list of adapters would be the third.

The consequence is the promise in ADR-0019 finally being true end to end: a
fifth service costs one directory, and it appears in the wizard because the
wizard asks.

## 6. The terminal layer

Taken from `~/.dotfiles/scripts/lib/menu.sh`, which already solves the parts
that are tedious and easy to get wrong: hiding and restoring the cursor,
turning terminal echo off for the whole menu rather than per-read, draining the
autorepeat backlog so a held key does not spill onto the next prompt, and a
50ms window for the rest of an escape sequence so a slow arrow key is not read
as a bare Esc.

What is not taken is that menu's selection model. It keeps a boolean per row,
because it exists to select several independent actions. This wizard needs one
choice per question, so the array of booleans becomes a single index, and
`space` stops being a key at all.

## 7. When the wizard runs, and when it does not

```
scaffold                 # a terminal: the wizard. Not a terminal: usage, exit 1
scaffold new <name> ...  # never the wizard
```

The TTY check is the whole safety argument. `scaffold` appears in scripts, in
CI, and in `mise exec -- ./scaffold list` inside this repository's own tests. A
bare invocation that blocked on a menu would hang all of them, and the failure
would be a timeout rather than an error. So the wizard is reached only when
standard input is a terminal, and every other context keeps today's behaviour
exactly.

`scaffold new` with a name and no adapters stays what it is today — a project
with no application in it — because a partially specified command is a
scripted command, not an invitation.

## 8. Testing

A TUI resists the suite this project already has, so the design splits it in
two rather than testing it through a terminal.

**The decisions are pure functions and carry the tests.** Given the rows
`scaffold list` prints and a shape, which questions follow, in what order, with
what options — and given a set of answers, what command does that produce.
Those are string-in, string-out, and they hold everything that could be wrong
about the wizard's logic: a shape that offers a database to a web-only project,
an adapter listed under the wrong role, a `none` option missing where it
belongs.

**The rendering is smoke-tested through a pty.** One test drives the wizard
with a scripted key sequence and asserts on the command it prints at the end.
It proves the loop reads keys and terminates; it does not try to assert on
frames. `script -qec` is in coreutils and the mock was driven this way during
the brainstorming, so the technique is known to work here.

**One test asserts the wizard offers exactly what `scaffold list` prints.** Not
a fixed list — a comparison, the same shape as the test that keeps
`adapters.yml`'s service matrix honest.

## 9. Known limits

1. **No back navigation** (§3). Ctrl-C and re-run.
2. **A project with both `web` and `api` still builds one image.**
   `set_image_context` records one context per project, whichever role was
   applied last. Unchanged by this work, and the wizard makes it easier to
   reach the `web+api` shape than the flags did — so it is stated on the
   summary screen rather than discovered after the first release build.
3. **Terminals narrower than 60 columns** get a one-line header instead of the
   banner, inherited from `menu.sh`'s own behaviour.
