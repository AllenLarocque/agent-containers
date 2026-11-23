# How to work in this repository

Read-only instructions from the owner. They apply to every change you make here.

## Always name the repository

- Pass `--repo <owner>/<repo>` to every `gh pr` command, where `<owner>/<repo>` is the repository of
  `origin` (`git remote get-url origin`). Check that every pull request URL that gh prints is on that
  repository.
- If `origin` is not a repository the owner owns, stop and ask the owner.

## Branches and pull requests

- Every branch you push is named `<prefix>/<short-name>`. The prefix must be one of: `fix`,
  `feature`, `chore`, `docs`, `test`, `ci`, `refactor`, `perf`, `revert`, `upstream`, `sync`,
  `experiment`. The repository rejects any other branch name.
- A `fix`, `feature`, `chore`, `docs`, `test`, `ci`, `refactor`, `perf`, `revert` or `experiment`
  branch starts from the current `allen-dev`: run `git fetch origin`, then start the branch from
  `origin/allen-dev`. Open its pull request against `allen-dev` and squash-merge it yourself.
- One change per pull request. Where the repository has checks, merge only when they are green.
- Never push to `allen-dev` directly and never rewrite its history.
- `sync/<name>`: only when the owner asks you to bring upstream changes in. Start the `sync/` branch
  from `origin/allen-dev` and merge into it
  the branch the owner names (the fork's copy of an upstream branch, for example `origin/development`).
  Do not fetch from the upstream repository yourself. Open its pull request into `allen-dev`.
  The owner merges the sync pull request, unless they tell you to merge it; it is merged with a
  merge commit, never squashed.
- `upstream/<topic>`: only when the owner asks. Cut it from the fork's copy of the upstream
  repository's target branch (for example `origin/development`), never from `allen-dev`. It carries
  only that one change, and it is never merged anywhere in the fork. Give the owner this link instead
  of opening a pull request:
  `https://github.com/<upstream-owner>/<repo>/compare/<base>...<owner>:<branch>?expand=1&title=<url-encoded>&body=<url-encoded>`

## When the repository has no `allen-dev`

- On a repository that is not a fork (`gh repo view <owner>/<repo> --json isFork`):
  start the branch from the default branch, push it, open the pull request against the default
  branch, and wait for the owner. Do not merge it.
- On a fork, stop and ask the owner.

## When a rule refuses you

- If a push or a merge is rejected by a repository rule, stop and tell the owner what was refused.
  Do not try another route.

## Other branches and other repositories

- Never open a pull request to any branch other than `allen-dev` unless the owner asks, and never
  merge one.
- Never open a pull request on a repository the owner does not own.
- Never delete a branch whose pull request is not merged without asking the owner. Decide by the
  pull request's state, not by `git branch --merged`.
