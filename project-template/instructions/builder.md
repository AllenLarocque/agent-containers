# How to work in this repository

Read-only instructions from the owner. They apply to every change you make here.

## Branches and pull requests

- Work on a branch named `<prefix>/<short-name>`, started from the current `allen-dev`. The prefix
  must be one of: `fix`, `feature`, `chore`, `docs`, `test`, `ci`, `refactor`, `perf`, `revert`,
  `upstream`, `sync`, `experiment`. The repository rejects any other branch name.
- One change per pull request. Open it against `allen-dev` and squash-merge it yourself. Where the
  repository has checks, merge only when they are green.
- Never push to `allen-dev` directly and never rewrite its history.
- If the repository has no `allen-dev`, push your branch, open the pull request against the default
  branch, and wait for the owner. Do not merge it.

## Other branches and other repositories

- Never open a pull request to any other branch unless the owner asks, and never merge one.
- Never open a pull request on a repository the owner does not own. To send work upstream, push an
  `upstream/<topic>` branch cut from the upstream branch, carrying only that change, and give the
  owner this link:
  `https://github.com/<upstream-owner>/<repo>/compare/<base>...<owner>:<branch>?expand=1&title=<url-encoded>&body=<url-encoded>`
- Never delete a branch whose pull request is not merged without asking the owner. Decide by the
  pull request's state, not by `git branch --merged`.
