# A shared working branch (`allen-dev`) and one fence around the agent

Date: 2026-11-21, rewritten 2026-11-23 after discussion with the owner. Status: draft for the
owner's approval.

## Intent

The agent runs unattended for long stretches. Today every pull request targets the default branch
and waits for the owner, so the agent builds each new piece of work on top of unmerged work and
the owner ends up approving one large PR. The owner wants small, clean changes without stopping
mid-work to approve each one, and is happy to keep deciding by hand what reaches the default
branch.

The owner also finds the present GitHub set-up too complex to reason about (four kinds of
ruleset, `CODEOWNERS`, different shapes on different repos) and wants to start simpler. (Owner,
2026-11-23: "I'd like to start simpler since this system is too complex for my current
understanding of GitHub.")

## Goals

- One rule a person can hold in their head: the agent writes only to its own branches and the
  working branch; only the owner changes anything else.
- The agent can land small changes on the working branch by itself.
- The owner promotes the working branch when they choose.
- One `agent-new protect` run sets a repo up completely, and one run can take several repos.
- More branch names are allowed than `fix/**` and `feature/**`.

## Non-goals and anti-goals

- The agent never gets a way to change a default branch, an upstream-mirrored branch or a tag.
- No organisation-level rulesets, no GitHub App, no change of token type.
- No automatic promotion. Promotion is the owner's act.
- Only the repos of the projects configured in agent-containers are touched now. The owner's
  other repos keep what they have until they are moved in, one at a time.
- `agent-new` keeps its rule of never silently changing a ruleset that differs from a template.

## Approaches

1. **A shared working branch behind a single fence (chosen by the owner).**
2. Stacked PRs that all wait for the owner. Rejected: the owner still approves every PR.
3. The agent merges to the default branch for low-risk changes. Rejected: the owner wants to keep
   curating the default branch.

An earlier draft of this design had four rulesets per repo. The owner asked for a simpler system;
the reasoning for what was dropped is under "What is dropped".

## Design

### The workflow

1. The agent and the owner both work on `allen-dev`. The agent makes each change on a branch with
   a free prefix and merges it into `allen-dev` by a small squashed PR; the owner may commit to
   `allen-dev` directly.
2. When the owner is satisfied, they merge `allen-dev` into their own line on that repo: the
   default branch on a repo they own outright; on a fork, the branch that corresponds to the
   upstream branch they send work to (`development` or `main`).
3. On a fork, when the owner is confident in how it runs, they open the PR to the upstream repo
   from that branch. After upstream merges it, they sync the fork's branch from upstream and merge
   it back into `allen-dev`.

The branch is named `allen-dev` on every repo (owner's choice, 2026-11-23). `agent-new protect`
creates it from the default branch's head when it does not exist, leaves an existing one alone,
and refuses a repo with no commits. `--no-working-branch` skips it.

### The fence: two rulesets, on every agent repo, fork or not

| Ruleset | Applies to | Rules | Admin bypass |
|---|---|---|---|
| `agent-fence` | all branches except the free names | no creation, update or deletion; no force push | always |
| `agent-fence-tags` | all tags | no creation, update or deletion | always |

- **Free names** (the `exclude` list of `agent-fence`): `refs/heads/allen-dev` and
  `refs/heads/<p>/**` for `<p>` in `fix`, `feature`, `feat`, `chore`, `docs`, `test`, `ci`,
  `refactor`. *Author's call; the owner has not yet chosen between this and "any name except a
  protected list".*
- The admin role is repository role id 5. The machine user is a collaborator with Write, never an
  admin, so the bypass never applies to it; the owner is the only admin.
- Merging a PR is an update of the target branch, so the fence also stops the agent merging into
  any fenced branch, the default branch included. **This must be proven by `agent-new verify` on
  a real repo before any `protect-main` is removed.**
- These are the same two rulesets the owner made by hand as `protect-fork` and
  `protect-fork-tags`, with a wider `exclude` list and a name that says what they do.

### What is dropped

- **`protect-main`**: with the fence, it restrains only the owner. It is removed from the science
  repos, where it mostly requires a `gitleaks` check those repos have no workflow for. It **stays
  on `agent-containers`**, because a merge to `main` there publishes the images every project
  runs. Accepted costs elsewhere: the fence is the only barrier, the owner's own stray or forced
  push to a default branch is not caught, and nothing requires green checks before promotion.
- **`CODEOWNERS`**: it only decides whose approval counts under `protect-main`. It is not added
  anywhere. Existing files are left in place.
- **A ruleset on the working branch**: none. That the agent uses small squashed PRs is asked for
  in its instructions, not enforced.

### Existing rulesets, and `--migrate`

Without `--migrate`, `agent-new protect` creates what is missing and refuses to touch anything
that exists and differs. With `--migrate` it also does exactly these, and nothing else:

- a `protect-fork` in exactly the owner's hand-made shape (rules creation, update, deletion,
  non_fast_forward; include `~ALL`; exclude `fix/**` and `feature/**`; admin bypass always) is
  renamed `agent-fence` and given the free names above;
- a `protect-fork-tags` in exactly the hand-made shape is renamed `agent-fence-tags`;
- a ruleset named `protect-main` or `main` on the default branch is deleted, but only after the
  fence exists on that repo, and never on `agent-containers`.

Deleting `protect-main` is the one step here that removes a protection, so `--migrate` prints
what it will delete and asks for confirmation per repo at a terminal.

### Several repos in one run

`agent-new protect <owner>/<repo>...` takes one or more repos in order. A failure on one is
reported and the run continues; the exit status is non-zero if any failed, and the last lines list
which succeeded. Flags apply to every repo named. One `--vault` serves all of them: every
project's vault holds a token for the same machine user, used only to accept the invitations.

### Verification

`agent-new verify`, as the machine user, on a repo with the fence:

- a push to the default branch is rejected by the rule;
- a PR into the default branch cannot be merged by the machine user;
- creating a branch outside the free names, and creating a tag, are rejected;
- a free-named branch can be pushed, and a PR from it into `allen-dev` can be squash-merged.

It deletes the branches it made. The last check leaves one empty commit on `allen-dev`.
On `agent-containers` today's `protect-main` checks still run.

### What the agent is told

A builder has no owner-controlled instruction file today unless research is on. This adds
`project-template/instructions/builder.md`, mounted read-only for every builder at the two paths
the research instructions use; when research is on, `builder-research.md` is appended when the
file is generated. The research profile's own instructions are unchanged. Its content:

- Work on a branch named `<prefix>/<short-name>` with a free prefix, started from the current
  `allen-dev`.
- Keep each PR to one change. Open it against `allen-dev` and squash-merge it yourself. Where the
  repo has checks, merge only when they are green.
- Never push to `allen-dev` directly, and never rewrite its history.
- Never open a PR to any other branch unless the owner asks for it, and never merge one.
- If the repo has no `allen-dev`, push the branch, open the PR against the default branch and
  wait for the owner.

### Runbook

`docs/runbooks/machine-user-and-rulesets.md` is rewritten around the fence: what the two rulesets
do, the free names, the workflow above including the fork steps, where `protect-main` still
applies and why, and the `--migrate` procedure.

## Left to the builder

- How the ruleset templates and their normalised comparison are factored in `bin/agent-new`.
- The wording of messages and of `builder.md`, within the content above.
- Test structure in `tests/launcher/test-agent-new.sh` and the launcher tests for the new mount.
