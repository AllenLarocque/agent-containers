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

On every repo, the agent and the owner both work on `allen-dev`. The agent makes each change on a
branch with a free prefix and merges it into `allen-dev` by a small squashed PR; the owner may
commit to `allen-dev` directly.

**On a repo the owner owns outright**, the owner merges `allen-dev` into the default branch when
satisfied.

**On a fork**, `allen-dev` is the owner's line and every branch that came from upstream is a
mirror:

- Nobody commits to a mirror. It changes only by being fast-forwarded from upstream.
- The owner's projects run `AllenLarocque/<repo>@allen-dev`, so a run includes all of the owner's
  work whether or not upstream has merged it. Upstream is often slow to merge; nothing here waits
  on it.
- Work goes upstream as small PRs, each from an `upstream/<topic>` branch on the fork: cut from
  the mirror, carrying only the commits for one change. When changes are too entangled to
  separate, the agent stops and asks; the owner may send a snapshot cut from `allen-dev` instead.
  `allen-dev` itself is never the head
  of an upstream PR, because it keeps moving.
- **The agent drafts, the owner sends.** When asked, the agent pushes the `upstream/<topic>` branch
  and gives the owner a link to GitHub's compare page on the upstream repo with the title and
  description pre-filled (`.../compare/<base>...AllenLarocque:<branch>?expand=1&title=…&body=…`).
  The owner reads the diff there, edits the text and creates the PR under their own name. The
  agent never opens a PR on an upstream repo. Later pushes to the branch update the open PR.
- A change that builds on a PR upstream has not merged is either held on `allen-dev` until then,
  or sent stacked on that PR's branch with "depends on #N" in its description. Owner's choice per
  change.
- Upstream's changes enter `allen-dev` when the owner asks: the agent opens a PR into `allen-dev`
  from a `sync/` branch that merges in the synced mirror the owner names.

The branch is named `allen-dev` on every repo (owner's choice, 2026-11-23). `agent-new protect`
creates it from the default branch's head when it does not exist, leaves an existing one alone,
and refuses a repo with no commits. `--no-working-branch` skips it.

### The fence: two rulesets, on every agent repo, fork or not

| Ruleset | Applies to | Rules | Admin bypass |
|---|---|---|---|
| `agent-fence` | all branches except the free names | no creation, update or deletion; no force push | always |
| `agent-fence-tags` | all tags | no creation, update or deletion | always |

- **Free names** (the `exclude` list of `agent-fence`): `refs/heads/allen-dev` and
  `refs/heads/<p>/**` for `<p>` in `fix`, `feature`, `chore`, `docs`, `test`, `ci`, `refactor`,
  `perf`, `revert`, `upstream`, `sync`, `experiment` (owner's choice, 2026-11-23). `upstream/` is
  for branches prepared to go to the upstream repo, `sync/` for merges of a mirror into
  `allen-dev`, `experiment/` for throwaway work. There is no `feat` (one spelling only) and no
  `release` (releases are the owner's). The list limits the agent only; the owner may name their
  own branches anything.
- The admin role is repository role id 5. The machine user is a collaborator with Write, never an
  admin, so the bypass never applies to it; the owner is the only admin.
- Merging a PR is an update of the target branch, so the fence also stops the agent merging into
  any fenced branch, the default branch included. The owner runs `agent-new verify` before
  retiring a main gate.
- `agent-new protect` sets up only repositories the signed-in owner owns and administers, and
  refuses a repository whose default branch is `allen-dev` or starts with a free prefix (that
  branch would be outside the fence).
- These are the same two rulesets the owner made by hand as `protect-fork` and
  `protect-fork-tags`, with a wider `exclude` list and a name that says what they do.

### The working branch's ruleset

`agent-working-branch` applies to `refs/heads/allen-dev` only, with the rules deletion and
non_fast_forward. It stops the agent's account from deleting `allen-dev` or rewriting its history;
the owner, as repository admin, can bypass it (admin role 5, mode always). `agent-new protect` creates it right after the working branch exists (skipped with
`--no-working-branch`) and before it turns on automatic deletion of merged branches, which would
otherwise delete `allen-dev` when a promotion PR from it is merged.

### Deleting branches

- `agent-new protect` turns on the repo setting "Automatically delete head branches"
  (`delete_branch_on_merge`), so a branch merged into `allen-dev` is deleted at merge time.
- An `upstream/` branch is kept until upstream merges or closes its PR. The fork check lists the
  ones that can go.
- The mirrors are fenced, so the agent cannot delete them. The agent's account cannot delete
  `allen-dev`: `agent-working-branch`.
- The agent decides by the PR's state, never by `git branch --merged` (after a squash git reports
  the branch as unmerged), and never deletes a branch whose PR is not merged without asking.

### What is dropped

- **`protect-main`**: with the fence, it restrains only the owner. It is removed from the science
  repos, where it mostly requires a `gitleaks` check those repos have no workflow for. It **stays
  where `--main-gate` is given** (`agent-containers`: `agent-new protect --main-gate`), because a merge to `main` there publishes the images every project
  runs.
- **`CODEOWNERS`**: it only decides whose approval counts under `protect-main`. `agent-new protect`
  does not add it. The project template (`project-template/repo/.github/CODEOWNERS`) still ships
  it, `agent-up init` copies it into a new project and `agent-new project` commits that copy with
  the owner's name filled in; existing files are left in place.

### Existing rulesets, and `--migrate`

Without `--migrate`, `agent-new protect` creates what is missing and refuses to touch anything
that exists and differs. A `protect-fork` in exactly the hand-made shape is left in place, and no
`agent-fence` is created beside it, so that a later `--migrate` can still convert it; the tool
warns and sets up the rest. With `--migrate` it also does exactly these, and nothing else:

- a `protect-fork` in exactly the owner's hand-made shape (rules creation, update, deletion,
  non_fast_forward; include `~ALL`; exclude `fix/**` and `feature/**`; admin bypass always) is
  renamed `agent-fence` and given the free names above (the old and the new list are printed);
- a `protect-fork-tags` in exactly the hand-made shape is renamed `agent-fence-tags`.

Both are checked before either is changed: if one exists in any other shape, neither is touched.

Retiring the main gate is a separate step, `--retire-main-gate`, run after `agent-new verify` has
passed on that repo: `protect --migrate`, then `verify`, then `protect --retire-main-gate`. It
looks up `protect-main` and `main` each by its exact name, and offers to delete one only if it is
a branch ruleset on exactly the default branch, after the fence is in place in the same run. It
prints the ruleset, asks `delete ruleset '<name>' on <repo>? [y/N]`, accepts only an answer typed
at a terminal, and reads the ruleset again just before deleting it. It is never combined with
`--main-gate` (which is how `agent-containers` keeps its gate).

### Several repos in one run

`agent-new protect <owner>/<repo>...` takes one or more repos in order. A failure on one is
reported and the run continues; the exit status is non-zero if any failed, and the last lines list
which succeeded. Flags apply to every repo named. One `--vault` serves all of them: every
project's vault holds a token for the same machine user, used only to accept the invitations.

### Verification

`agent-new verify` first reads the repository's rulesets as the owner: `agent-fence` and
`agent-fence-tags` must equal their templates (and `agent-working-branch` when `allen-dev` exists,
and `protect-main` with `--main-gate`), and no
`protect-fork` or `protect-fork-tags` may be left. Then the owner creates a throwaway branch and
tag named `zz-agent-new-verify-<run id>` at the default branch's head (only if no ref of that name
exists), and, as the machine user:

- a fast-forward push to that branch, a force-push that rewinds it to the default head's parent,
  and its deletion are refused;
- creating a new branch outside the free names, and a new tag, are refused;
- moving and deleting the throwaway tag are refused;
- a free-named branch can be pushed, and a PR from it into the throwaway branch cannot be merged;
- a PR into `allen-dev` can be squash-merged.

`agent-working-branch` is proved by the comparison with its template before any push; verify never
deletes or force-pushes `allen-dev` itself.

The default branch is never pushed to or merged into in these checks; a wrongly accepted attempt
changes only a throwaway ref. The owner removes everything the run created; anything that cannot
be removed is listed and the run ends without a clean success. The last check leaves one empty
commit on `allen-dev`. With `--main-gate` (`agent-containers`), the `protect-main` checks run
after the fence checks.

### What the agent is told

A builder has no owner-controlled instruction file today unless research is on. This adds
`project-template/instructions/builder.md`, mounted read-only for every builder at the two paths
the research instructions use; when research is on, `builder-research.md` is appended when the
file is generated. The research profile's own instructions are unchanged. Its content:

- Name the repository (`--repo`, the repository of `origin`) in every `gh pr` command, and check
  that the PR URLs gh prints are on it.
- Work on a branch named `<prefix>/<short-name>` with a free prefix. `fix`, `feature`, `chore`,
  `docs`, `test`, `ci`, `refactor`, `perf`, `revert` and `experiment` branches start from the
  current `allen-dev` and are squash-merged into it.
- `sync/<name>`, only when the owner asks: a `sync/` branch from `allen-dev` merges in the branch
  the owner names (the fork's copy of an upstream branch); its PR into `allen-dev` is merged by the
  owner unless they say otherwise, with a merge commit, never squashed.
- `upstream/<topic>`, only when the owner asks: cut from the fork's copy of the upstream
  repository's target branch, never from `allen-dev`; one change; never merged in the fork; the
  owner gets the link.
- Keep each PR to one change. Where the repo has checks, merge only when they are green.
- Never push to `allen-dev` directly, and never rewrite its history.
- Never open a PR to any other branch unless the owner asks for it, and never merge one. Never
  open a PR on a repo the owner does not own.
- Never delete a branch whose PR is not merged without asking the owner.
- If the repo has no `allen-dev`: on a repo that is not a fork, open the PR against the default
  branch and wait for the owner; on a fork, stop and ask.
- If a push or a merge is rejected by a repository rule, stop and tell the owner; do not try
  another route.

### Runbook

`docs/runbooks/machine-user-and-rulesets.md` is rewritten around the fence: what the two rulesets
do, the free names, the workflow above including the fork steps, where `protect-main` still
applies and why, the `--migrate` and `--retire-main-gate` procedure, and what `verify` creates and
removes.

## Left to the builder

- How the ruleset templates and their normalised comparison are factored in `bin/agent-new`.
- The wording of messages and of `builder.md`, within the content above.
- Test structure in `tests/launcher/test-agent-new.sh` and the launcher tests for the new mount.
