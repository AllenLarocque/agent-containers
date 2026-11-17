# 1Password sign-in check, and `up` fetches its own token

Date: 2026-11-16. Status: approved by the owner in conversation, 2026-11-16. Small change;
independent of `2026-11-16-attested-images-design.md` and shipped before it, as its own PR.

## Intent

The owner often forgets to sign in to the `op` CLI before `agent-up update --all`. Today that is
only discovered mid-run: update pulls `main`, asks about busy projects, then fails each project
with `NOT UPDATED (could not read op://Personal/…)`. The owner wants every run that needs
1Password to check first, and wants `agent-up up` to stop needing a hand-typed `op read`.

## Goals

- A run that needs the owner's 1Password session finds out before it changes or asks anything.
- If signed out at a terminal, the run signs in on the spot and continues.
- `agent-up up <project>` works with no token in the environment.

## Non-goals and anti-goals

- Nothing changes about what reaches a container. It still gets only the resolved values of the
  keys in `project.env`. No `op` session and no service-account token ever enters it.
- The launcher reads exactly one item per project as the owner:
  `op://Personal/agent-<project> service account/credential`. It must not list vaults or read any
  other item on the owner's session. (Owner, 2026-11-16: "I definitely do not want it to have
  access to my passwords outside of its token.")
- No caching of the token or the session on disk, and none exported to the calling shell.
- Research projects never trigger a sign-in check: they have no secrets.

## Approaches

1. **Check, and sign in on the spot (chosen).** `op whoami`; if signed out and stdin is a terminal,
   run the sign-in in the launcher's own process and continue.
2. **Check and stop.** Simpler, but the owner still has to sign in and re-run. Rejected.
3. **Leave `up` alone, only improve its error message.** Offered; the owner chose to have `up`
   fetch the token itself, as `update` and `agent-new up` already do.

## Behaviour

One shared helper (call it `op_ready`), used wherever the launcher needs the owner's session:

- Unsets `OP_SERVICE_ACCOUNT_TOKEN` for the check (with a project token exported, `op` acts as that
  service account and cannot see `Personal`).
- `op whoami` succeeds: return silently.
- Signed out, stdin is a terminal: say "1Password: not signed in. Signing in:" and run
  `eval "$(op signin)"`, the form `agent-new` already uses. Check again; continue if it worked.
- Signed out with no terminal, sign-in failed, or `op` missing: die with
  `sign in first: eval "$(op signin)"`, having changed nothing.

Where it runs:

| Command | When | Notes |
|---|---|---|
| `agent-up update` | first thing, before `update_guard`, any lookup and any busy prompt | only if at least one selected project is not research |
| `agent-up up <project>` | when `OP_SERVICE_ACCOUNT_TOKEN` is not set and the project is not research | then reads the project's token (below) |
| `agent-new` | at the start of each subcommand that reads from 1Password (`up`, `verify`, the token copy, the vault step) | replaces the bare `eval "$(op signin)"` in `project_vault` |

`agent-up up` with no token set: after `op_ready`, read
`op://Personal/agent-<project> service account/credential` into a local variable, use it for that
one `op run`, and drop it. An empty or failed read dies naming the item and pointing at
`docs/runbooks/1password-project-vault.md`. If a token **is** set (direnv, a manual export, or
`update` / `agent-new` passing one), `up` uses it exactly as today and never touches the owner's
session. The existing "is not set" die goes away, since that case now fetches.

`update` keeps reading each project's token itself and passing it to `up`, so its per-project
`NOT UPDATED (could not read …)` row still covers a missing item.

## Docs

`docs/runbooks/1password-project-vault.md` (the "read at use time" section becomes: just run
`agent-up up <project>`; the export form stays as an alternative), README, `agent-up` usage text,
and a dated amendment to §5 of `2026-10-03-agent-containers-design.md` noting that `up` may read
the one service-account item on the owner's session.

## Tests

Launcher tests, with `op` stubbed: signed in (silent); signed out with a terminal (signs in,
continues); signed out without one (dies before any change); `update --all` with only research
projects (no check); `up` with a token set (no `op whoami`, no `op read`); `up` without one (reads
exactly the one item); a failed read (dies naming the item).

## Left to the builder

Helper name and location, message wording, how the tests fake "stdin is a terminal".
