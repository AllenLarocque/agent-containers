# Runbook: working with `allen-dev`

**Human procedure.** For you, the repo owner. The agent's standing rules for this model are in `project-template/instructions/builder.md`; the sync, snapshot and stacked-PR procedures below come from the design spec (`docs/specs/2026-11-21-agent-dev-branch-design.md`). Set-up of the rulesets that make this work is in [machine-user-and-rulesets.md](machine-user-and-rulesets.md), which also defines the terms (ruleset, fork, mirror, squash, default branch, fast-forward) used here.
GitHub UI paths below are as of 2026-11 and may move; if a label differs, look for the nearest equivalent.

**Why this exists.** The agent runs for long stretches. If every PR waited for you, it would build each piece on top of unmerged work. So the agent and you share one working branch, `allen-dev`: the agent lands small changes there by itself, and you decide when anything goes further.

## The routine, on every repo

1. The agent starts a branch from the current `allen-dev`, named `<prefix>/<short-name>` with one of the twelve allowed prefixes (`fix`, `feature`, `chore`, `docs`, `test`, `ci`, `refactor`, `perf`, `revert`, `upstream`, `sync`, `experiment`). *Why: the agent's account may write only to those names and to `allen-dev`.*
2. It makes one change on that branch and opens a pull request into `allen-dev`. Where the repo has checks, it waits for them to pass.
3. It **squash-merges** the PR itself. (Squash turns the branch's commits into one commit on `allen-dev`, so the history stays short.) GitHub deletes the branch at merge time.
4. It never commits to `allen-dev` directly and never rewrites its history. You may commit to `allen-dev` directly.
5. If a repo has no `allen-dev`: on a repo that is not a fork, the agent pushes its branch, opens the PR against the default branch and waits for you; on a fork, it stops and asks you.
6. If a push or a merge is refused by a repository rule, the agent stops and tells you. It does not try another route.
7. Every `gh pr` command the agent runs names the repo (`--repo <owner>/<repo>`, the repo of `origin`), so a PR never lands on upstream or on another repo by accident.

What you see: a stream of small, merged PRs into `allen-dev`, and a default branch that has not moved.

## On a repo you own outright

When you are satisfied with `allen-dev`, you promote it to the default branch:

1. Repo → Pull requests → New pull request. Base: the default branch (usually `main`). Compare: `allen-dev`.
2. Read the diff, then **Create pull request** and merge it. (You can also merge locally and push; you are the only account allowed to write to the default branch.)
3. Repo → Branches: `allen-dev` stays; it is never deleted.

Nothing promotes automatically. The default branch changes only when you do it.

## On a fork

A **fork** is your copy of someone else's repo. The original is **upstream**. On a fork:

- The branches that came from upstream (for example `main`) are **mirrors**. Nobody commits to a mirror. It changes only by being fast-forwarded to match upstream (GitHub's **Sync fork** button does this).
- `allen-dev` is your own line. Your projects run `<you>/<repo>@allen-dev`, so a run includes all your work whether or not upstream has merged it. Nothing waits on upstream.

### Sending a change upstream

Each upstream PR comes from its own `upstream/<topic>` branch on your fork. The agent cuts it from the mirror of upstream's target branch (for example `origin/development`), never from `allen-dev`, and puts in only the commits for that one change. The branch is never merged in your fork. If changes are too entangled to separate, the agent stops and tells you; sending a snapshot cut from `allen-dev` instead is your decision. `allen-dev` itself is never the source of an upstream PR, because it keeps moving.

1. Ask the agent to prepare the change for upstream.
2. It pushes `upstream/<topic>` and gives you a link to GitHub's compare page on the upstream repo, with the title and description already filled in. The link looks like `https://github.com/<upstream-owner>/<repo>/compare/<base>...<you>:<branch>?expand=1&title=...&body=...`.
3. Open the link. You see the diff and the pre-filled text.
4. Read the diff, edit the text if you like, and press **Create pull request**. It is then your PR, under your name. The agent never opens a PR on a repo you do not own.
5. Later pushes to that branch update the open PR.

A change that builds on an upstream PR that has not merged yet is either held on `allen-dev` until it merges, or sent stacked on that PR's branch with "depends on #N" in its description. You choose, per change.

### Bringing upstream's changes into `allen-dev`

Do this when you want upstream's new work in your line.

1. Update the mirror: on your fork's page, **Sync fork → Update branch**.
2. Ask the agent to bring the mirror into `allen-dev`. It pushes a branch `sync/<date-or-topic>` that merges the mirror into `allen-dev`, and opens a PR from it into `allen-dev`.
3. Check the PR page for conflicts and for green checks, then let the agent merge it, or merge it yourself. A sync PR is merged with a **merge commit**, never squashed, so upstream's own commits stay recognisable in `allen-dev`'s history and the next sync merges cleanly.

You see the upstream commits appear on `allen-dev` under one merge commit, and the `sync/` branch disappear.

## Deleting branches

- A branch merged into `allen-dev` is deleted by GitHub at merge time (the repo setting "Automatically delete head branches").
- An `upstream/` branch is kept until upstream merges or closes the PR made from it. The fork check lists the ones that can go.
- The mirrors are fenced, so the agent cannot delete them.
- The agent decides by the PR's state, not by `git branch --merged` (after a squash, git reports the branch as unmerged). It never deletes a branch whose PR is not merged without asking you.
