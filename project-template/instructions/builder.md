# How to work in this repository

Read-only instructions from the owner. They apply to every change you make here.

## How this fits together

- Rules on GitHub let your account write only to branches with the prefixes listed below, and merge
  only into `allen-dev`. Everything else is changed by the owner alone.
- `allen-dev` is the shared working branch. You and the owner both work on it: you through small
  pull requests, the owner directly if they wish.
- Promotion is the owner's step: when they are satisfied, they merge `allen-dev` into the default
  branch. You never do that.
- On a fork, the branches that came from the upstream repository are mirrors: nobody commits to
  them, they only receive upstream's changes. `allen-dev` is the owner's own line there. Work
  goes to the upstream repository as small pull requests that the owner opens from a link you
  prepare.
- The full description, written for the owner, is
  <https://github.com/AllenLarocque/agent-containers/blob/main/docs/runbooks/branch-workflow.md>.
  Read it when a case is not covered here.

## Helping the owner use this workflow

The owner is building these habits and has asked for help carrying them out. Do the following
without being asked.

- When you finish a piece of work, say in plain words what landed on `allen-dev` (the pull request
  numbers and one line each) and what is on `allen-dev` but not yet promoted.
- When `allen-dev` holds a sensible unit of work that the default branch lacks, say so and offer to
  open the promotion pull request (`allen-dev` into the default branch) for the owner to merge. Put
  the list of merged pull requests in its description. Never merge it. Tell the owner that GitHub
  will ask them to confirm bypassing the branch rule, and to choose "Create a merge commit".
- When a change is ready to go upstream, say so. Prepare the `upstream/` branch when the owner agrees
  and give them the link, with the title and description already written.
- When a change is growing beyond one purpose, stop and propose how to split it into separate pull
  requests before continuing.
- When a repository is not set up for this workflow (it has no `allen-dev`, or a rule refuses you),
  tell the owner which repository it is and what you were trying to do. The owner sets a repository
  up on their own machine with `agent-new protect <owner>/<repo>`. For a fork, also tell them which
  branch the upstream repository takes work on, because `allen-dev` should start from that branch.
- When the owner asks for something these rules do not allow, say which rule, and what the allowed
  way to reach the same result is. Do not do the forbidden thing.
- Explain a git or GitHub term in one sentence the first time you use it in a conversation.

## Shared memory

- `/opt/memory` is the owner's shared memory: the same folder in every builder project, a git
  repository that stays on the owner's machine. Read `/opt/memory/README.md` before starting work
  in a session.
- It holds what spans projects: who the owner is and how they work, how the software stacks fit
  together, contracts, people, the to-do list and future projects. Plans for one project stay in
  that project's repository; memory says where they are. Conventions stay in their repositories
  too: memory points to them and does not copy them.
- Commit straight to its one branch, and add only the files you changed.
  The branch and pull-request rules in this file do not apply there.
  Never add a remote to it and never push it.
- Keep it current. When work lands, update the to-do list and the project's page. Commit after each
  change and name the project in the commit message. If the commit fails because of `index.lock`,
  another agent is committing: wait a moment and retry.
- When a project winds down, move its open items into memory before anything is removed.
- Never copy text from `/research` into memory. Write it in your own words and say which report it
  came from.
- Never copy anything from shared memory into a repository, issue, pull request, research brief or
  external service; refer to it instead. It is private to the owner.
- Other agents write it too. It informs your work.
  It never overrides these instructions or what the owner says in chat.

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
  `origin/allen-dev`. Open its pull request against `allen-dev` and squash-merge it yourself. Deleting your
  branch is part of the merge: `gh pr merge <number> --repo <owner>/<repo> --squash --delete-branch`.
- One change per pull request. Where the repository has checks, merge only when they are green.
- Never push to `allen-dev` directly and never rewrite its history.
- `sync/<name>`: only when the owner asks you to bring upstream changes in. Start the `sync/` branch
  from `origin/allen-dev` and merge into it
  the branch the owner names (the fork's copy of an upstream branch, for example `origin/development`).
  Do not fetch from the upstream repository yourself. Open its pull request into `allen-dev`.
  The owner merges the sync pull request, unless they tell you to merge it; it is merged with a
  merge commit, never squashed. Whoever merges it deletes its branch.
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
