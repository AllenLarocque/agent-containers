# A weekly check of the owner's forks against upstream

Date: 2026-11-23. Status: draft for the owner's approval. Depends on
`2026-11-21-agent-dev-branch-design.md` (the fence and `allen-dev`) and is built after it.

## Intent

On a fork, the owner's line is `allen-dev` and the upstream branches are mirrors. Upstream moves
on its own schedule and merges the owner's PRs slowly. The owner wants to know each week what is
waiting, and wants the mechanical part done for them. (Owner, 2026-11-23: "I think I want it to
fast-forward the mirrors for me and flag that it has done so.")

## Goals

- One command reports, per fork in scope: how far `allen-dev` is behind each mirror, and the
  owner's open PRs upstream with their age.
- The same run fast-forwards every mirror that can be fast-forwarded and says which it moved.

## Non-goals and anti-goals

- It never merges anything into `allen-dev`. That stays a decision of the owner, carried out by a
  PR the agent prepares.
- It never forces a mirror. A mirror with commits upstream does not have is left alone and
  flagged: it means something was committed where it should not have been.
- It adds no workflow file to any fork (it would travel upstream in the owner's PRs).
- It does not run in a project container: the fence stops the agent writing to mirrors.

## Approaches

1. **A host command run as the owner (chosen).** The owner's `gh` session can fast-forward the
   mirrors; the fence's admin bypass allows it.
2. A scheduled GitHub workflow in each fork. Rejected: it puts a file in every fork.
3. The agent does it at the start of its work. Rejected: the agent cannot write to mirrors.

## Design

- **Command:** `agent-new forks [--no-sync]`. Runs as the owner, like the rest of `agent-new`.
- **Scope:** the forks among the repos the machine user is a collaborator on that have an
  `allen-dev` branch. *Author's call:* that is exactly the set brought under this workflow.
- **Mirrors:** every branch of the fork that also exists upstream under the same name.
- **Sync:** for each mirror behind upstream and not ahead of it, fast-forward it (the equivalent
  of `gh repo sync --branch <b>` without `--force`). `--no-sync` only reports.
- **Report, per fork:** mirrors fast-forwarded in this run and by how many commits; mirrors that
  have diverged (not synced); how many commits `allen-dev` is behind each mirror the owner's work
  targets; the owner's open PRs upstream, with age in days; `upstream/` branches whose PR
  upstream is merged or closed, as ready to delete (it deletes nothing itself). A fork with
  nothing to say prints one "up to date" line.
- **Exit status:** 0 when every fork was read; non-zero if any could not be, with the others still
  reported.
- **Scheduling:** none at first; the owner runs it by hand. A weekly timer comes later, and the
  owner intends to host it on their NAS eventually, so the command must not depend on anything in
  `~/.config/agent-containers` beyond the machine user's name, which a flag can supply.

## Left to the builder

- Output layout, and how the upstream PR list is queried.
- Tests, in the style of `tests/launcher/test-agent-new.sh` (a fake `gh`).
