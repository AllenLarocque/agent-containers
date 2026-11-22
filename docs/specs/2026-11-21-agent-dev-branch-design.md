# An integration branch the agent merges into (`agent-dev`), and looser branch names

Date: 2026-11-21. Status: draft for the owner's approval.

## Intent

The agent runs unattended for long stretches. Today every pull request targets the default branch
and waits for the owner, so the agent builds each new piece of work on top of unmerged work and
the owner ends up approving one large PR. The owner wants small, clean PRs without having to stop
mid-work to approve each one, and is happy to keep curating the default branch by hand. (Owner,
2026-11-21: "That will also enforce upon me better testing and release schedule.")

Two side problems go with it. Setting a repo up for the agent is tedious, one repo at a time. And
the hand-made `protect-fork` ruleset on many repos allows only `fix/**` and `feature/**` branch
names, which the owner finds too narrow.

## Goals

- The agent can land a small PR by itself, on a branch that is not the default branch, once the
  repo's checks are green.
- The owner promotes that branch to the default branch when they choose, with one PR, and the
  default branch's history shows each small PR as its own commit.
- One `agent-new protect` run sets a repo up completely, and one run can take several repos.
- More branch names are allowed, without making upstream-mirrored branches on a fork writable.

## Non-goals and anti-goals

- The agent never gets a way to change the default branch without the owner's approval.
  `protect-main` is not weakened in any way.
- The agent must not be able to write to a fork's upstream-mirrored branches (`development`,
  `dev`, `master`, or any other name upstream uses), nor to tags.
- No organisation-level rulesets, no GitHub App, no change of token type.
- No automatic promotion, and no schedule for it. Promotion is the owner's act.
- `agent-new` keeps its rule of never silently changing a ruleset that differs from its template.

## Approaches

1. **Integration branch (chosen by the owner).** A long-lived branch the agent merges its own PRs
   into; the owner promotes it. Costs one extra ruleset per repo, and the branch holds unreviewed
   code until promoted.
2. **Stacked PRs.** Each small PR sits on the previous one's branch and nothing merges until the
   owner approves. No new permissions, but the owner still approves every PR one by one, and a
   stack is fiddly when an early PR changes.
3. **The agent merges to the default branch for low-risk classes of change.** Rejected: the owner
   wants to keep curating the default branch, and the classes cannot be enforced.

For branch names, two options were put to the owner, who has not yet chosen; this design takes
the first as the author's call:

- **A wider list of free prefixes (taken).** Upstream branches stay protected whatever their name.
- Any name except a protected list. Freer, but an upstream branch with an unusual name would be
  writable.

## Design

### The branch

- Its name is `agent-dev` on every repo. *Author's call.* A fixed name that no upstream uses
  avoids colliding with a fork's `dev` or `development`, which is a mirror in some of the owner's
  forks and the owner's working line (even the default branch) in others.
- It is promoted to the repo's default branch, whatever that is called.
- `agent-new protect` creates it from the default branch's head when it does not exist. An
  existing `agent-dev` is left as it is, whatever it contains. A repo with no commits is refused.
- `--no-agent-dev` skips the branch and `protect-agent-dev`. It is for a fork kept only to send
  changes upstream, where the agent's work should never collect on the fork. *Author's call.*

### Rulesets

`agent-new protect <owner>/<repo>` ends with these on the repo. The admin role is repository role
id 5, as in today's template. The machine user is a collaborator with Write, never an admin, so no
bypass below applies to it; the owner is the only admin.

| Ruleset | Applies to | Rules | Admin bypass |
|---|---|---|---|
| `protect-main` | default branch | unchanged from today's template | pull requests only |
| `protect-agent-dev` (new) | `refs/heads/agent-dev` | no deletion; no force push; pull request required with 0 approvals, no code-owner review, merge method squash only; the same required checks as `protect-main` | always |
| `protect-fork` | all branches except the free names below | no creation, update or deletion; no force push | always |
| `protect-fork-tags` | all tags | no creation, update or deletion | always |

- **Free names** (the `exclude` list of `protect-fork`): `refs/heads/agent-dev` and
  `refs/heads/<p>/**` for `<p>` in `fix`, `feature`, `feat`, `chore`, `docs`, `test`, `ci`,
  `refactor`.
- **Which repos get `protect-fork` and `protect-fork-tags`:** forks, and any repo (fork or not)
  that already has either ruleset; a missing one of the pair is then created. A flag `--restrict-branches` asks for them on a non-fork. *Author's
  call:* on a repo the owner owns outright there is no mirror to protect.
- **Where the required checks come from:** the `--require` flags of the run, exactly as for
  `protect-main` today, and the same list goes into both rulesets. Nothing is read from the live
  `protect-main`.
- **Required checks when the repo has none:** `protect-agent-dev` then carries no status-check
  rule, and the agent can merge as soon as the PR exists. This is accepted: the branch is not the
  one anyone runs from, and the owner reviews at promotion.
- **Squash into `agent-dev`, merge commit into the default branch.** Each small PR becomes one
  commit on `agent-dev`; promoting with a merge commit carries those commits to the default
  branch unchanged. If the owner squashes a promotion instead, `agent-dev` and the default branch
  diverge; the runbook says how to reset `agent-dev` (the admin bypass allows it).

### Existing rulesets

- An existing `protect-main` that differs from the template: refused, as today.
- An existing `protect-fork` in exactly the old hand-made shape (same rules and bypass, `exclude`
  equal to `fix/**` and `feature/**` only): `agent-new protect` reports the difference and stops,
  unless `--migrate` is given, in which case it replaces the `exclude` list with the free names
  above. Any other difference is refused whether or not `--migrate` is given. `--migrate` changes
  nothing else; missing rulesets are created with or without it.
- An existing `protect-agent-dev` or `protect-fork-tags` that differs from the template: refused.

### Several repos in one run

`agent-new protect <owner>/<repo>...` takes one or more repos and handles them in order. A failure
on one repo is reported and the run goes on to the next; the exit status is non-zero if any repo
failed, and the last lines list which succeeded and which did not. `--vault`, `--require`,
`--migrate`, `--restrict-branches` and `--no-agent-dev` apply to every repo named in the run. One
`--vault` serves all of them: every project's vault holds a token for the same machine user, and
the token is used only to accept the invitations.

### Verification

`agent-new verify` keeps today's checks on the default branch and adds, as the machine user:

- a PR into `agent-dev` from a free-named branch can be opened and squash-merged (after checks,
  where the repo has any);
- a direct push to `agent-dev` is rejected by the rule;
- creating a branch outside the free names is rejected, on a repo that has `protect-fork`.

The verification PR adds an empty commit to `agent-dev`. *Author's call:* acceptable, because it
is the only way to prove the merge path works. Verify waits for checks the way it does today,
deletes the branches it made, skips the `agent-dev` checks on a repo without that branch, and
skips the free-name check on a repo without `protect-fork`.

### What the agent is told

A builder has no owner-controlled instruction file today unless research is on. This adds
`project-template/instructions/builder.md`, mounted read-only for every builder at the same two
paths the research instructions use; when research is on, `builder-research.md` is appended to it
when the file is generated. The research profile's own instructions are unchanged. Its content:

- Work on a branch named `<prefix>/<short-name>` with a free prefix.
- Keep each PR to one change. Open it against `agent-dev` and squash-merge it yourself when the
  checks are green. Do not merge a PR with failing or pending checks.
- Start each new piece of work from the current `agent-dev`.
- Never open a PR to the default branch, except the promotion PR (`agent-dev` into the default
  branch) when the owner asks for it. Never merge that one.
- If the repo has no `agent-dev`, push the branch, open the PR against the default branch and
  wait for the owner. Never push to any other existing branch.

### Runbook

`docs/runbooks/machine-user-and-rulesets.md` gains the three rulesets, the free names, the
promotion steps (open the `agent-dev` PR, review the list of squashed commits, choose "Create a
merge commit"), and the reset procedure after an accidental squash.

## Left to the builder

- How the ruleset templates and their normalised comparison are factored in `bin/agent-new`.
- The wording of messages and of `builder.md`, within the content above.
- Test structure in `tests/launcher/test-agent-new.sh` and the launcher tests for the new mount.
