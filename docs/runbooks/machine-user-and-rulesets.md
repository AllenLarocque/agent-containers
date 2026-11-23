# Runbook: machine user and the agent fence

**Human procedure.** The agent must never perform these steps. You (the repo owner) do them, with `agent-new` or in the GitHub web UI.
GitHub UI paths below are as of 2026-11 and may move; if a label differs, look for the nearest equivalent.

## The model in brief

- The agent pushes code as a separate GitHub account, the **machine user** (`allen-agent`), not as you.
- That account may write to two kinds of branch only: branches whose name starts with an allowed **prefix** (`fix/`, `feature/` and ten others, listed below), and the working branch `allen-dev`.
- Only you change anything else: the **default branch** (the branch GitHub shows first, usually `main`), the tags, and every other branch.
- On a **fork** (your own copy of someone else's repo), the branches that came from the original ("upstream") repo are **mirrors**: copies you keep up to date but never edit. `allen-dev` is your own line on the fork, and it is the branch your projects run.
- On a repo you own outright, `allen-dev` is where work collects, and you decide when it moves to the default branch.
- This is done by two **rulesets** (rules that GitHub enforces on branches or tags). Everything else in this runbook sets those rulesets up, checks them, or explains how to work inside them. The daily routine is in [branch-workflow.md](branch-workflow.md).

Terms used below:

- **Ruleset:** a named set of rules that GitHub enforces on a repo's branches or tags. Repo → Settings → Rules → Rulesets.
- **Bypass:** a role that a ruleset does not apply to. Both fence rulesets let the **Repository admin** role through (you are the only admin); the machine user is not an admin, so it is always bound.
- **Pull request (PR):** a request to merge one branch into another, with a page for review.
- **Squash:** a way of merging a PR that turns all its commits into one commit on the target branch.
- **Prefix:** the part of a branch name before the first slash. In `fix/typo`, the prefix is `fix`.

## The two rulesets

`agent-new protect` gives every agent repo the same two rulesets, fork or not.

| Ruleset | Applies to | What it forbids | Bypass |
|---|---|---|---|
| `agent-fence` | all branches except the allowed names | creating, updating or deleting a branch; force-pushing | Repository admin, always |
| `agent-fence-tags` | all tags | creating, updating or deleting a tag | Repository admin, always |

Merging a PR into a branch counts as updating that branch, so the machine user also cannot merge anything into the default branch or any mirror.

**The allowed names** (the branches the fence leaves free): `allen-dev`, and any branch starting with one of these twelve prefixes: `fix`, `feature`, `chore`, `docs`, `test`, `ci`, `refactor`, `perf`, `revert`, `upstream`, `sync`, `experiment`. There is no `feat` (one spelling only) and no `release` (releases are yours). Uses:

| Prefix | For |
|---|---|
| `fix/`, `feature/`, `chore/`, `docs/`, `test/`, `ci/`, `refactor/`, `perf/`, `revert/` | ordinary changes, named for their kind |
| `upstream/` | a branch prepared to go to the original repo of a fork |
| `sync/` | a merge of a mirror into `allen-dev` |
| `experiment/` | throwaway work |

The list limits the agent only. You may name your own branches anything.

*Why two rulesets:* GitHub keeps branch rules and tag rules apart.
*Why the admin bypass is "always":* you are the only admin and must be able to move `allen-dev`, mirrors and tags yourself. The machine user holds Write access, never Admin, so the bypass never reaches it.

## Branch deletion

`agent-new protect` turns on the repo setting **Automatically delete head branches**: when a PR is merged, GitHub deletes its source branch. A branch merged into `allen-dev` therefore disappears at merge time. An `upstream/` branch is kept until the original repo merges or closes the PR made from it. `allen-dev` and the mirrors are never deleted.

## Where the older main gate still applies

Before the fence, each repo had a ruleset `protect-main` on its default branch: one approval from you, a code-owner review, and green checks before anything could merge. The fence replaces it on the science repos.

`agent-containers` keeps it, because a merge to `main` there publishes the images every project runs. Always pass `--main-gate` for that repo, to `protect` and to `verify`, and never run `--migrate` on it without `--main-gate`. The by-hand steps for it are step 4.3 below. (A repo with `--main-gate` also gets the fence; the gate sits on top.)

## Using `agent-new` (the automated route)

Run these on the host as yourself (`gh auth login` as you, not as the machine user).

```bash
agent-new protect <owner>/<repo> [<owner>/<repo>...] [--vault agent-<project>] [--migrate]
                 [--main-gate] [--no-working-branch] [--require <check>]
agent-new verify <project>                       # inside the running container
agent-new verify <owner>/<repo> --vault agent-<project>   # from a temporary clone
```

For each repo, `protect` does these in order, and prints `SKIP (done)` for anything that is already right:

1. Invites the machine user as a collaborator, and accepts the invitation for it when you give `--vault` (the project vault that holds its token; one `--vault` serves every repo in the run).
2. Creates the ruleset `agent-fence`, then `agent-fence-tags`.
3. Creates the branch `allen-dev` from the head of the default branch, unless it exists. It stops with a message for a repo that has no commits yet. `--no-working-branch` skips this.
4. Turns on "Automatically delete head branches".
5. With `--main-gate`: creates `protect-main` and warns if the repo lacks `.github/CODEOWNERS` or a gitleaks workflow, or lets Actions approve PRs.

Rules of the tool:

- **It never changes a ruleset that already exists and differs from its template.** It prints the live and expected settings and stops on that repo. Edit such a ruleset in the GitHub UI if the difference is intended.
- **Several repos:** repos are done in the order given. A failure on one is reported, the rest continue, and the last lines read `protect: ok <repo>` or `protect: FAILED <repo>`. The exit status is non-zero if any failed. Flags apply to every repo in the run.
- **`--require <check>`** adds a required check to `protect-main` (`gitleaks` is always required). It matters only with `--main-gate`.

### `--migrate`: moving a repo from the older rulesets

Before this design, some repos had hand-made rulesets `protect-fork` and `protect-fork-tags` (which limit the agent to `fix/` and `feature/` branches) and `protect-main`. Without `--migrate`, `protect` leaves them alone and warns. With `--migrate` it does exactly these things and nothing else:

1. A `protect-fork` in exactly the hand-made shape is renamed `agent-fence` and gets the full list of allowed names.
2. A `protect-fork-tags` in exactly the hand-made shape is renamed `agent-fence-tags`.
3. A ruleset named `protect-main` or `main` that applies only to the default branch is deleted, but only after the fence exists on that repo. Deleting it is the one step that removes a protection, so the tool prints the ruleset's settings and asks `delete ruleset '<name>' on <repo>? [y/N]`. Answer `y` to delete. Where there is no terminal to ask, nothing is deleted and the tool says so; run it again at a terminal. A ruleset of either name that targets anything more than the default branch is left alone.

A `protect-fork` that is not exactly the hand-made shape makes `--migrate` stop with a message and no change. If `protect-fork` still sits beside an existing `agent-fence`, it is left, and the tool warns you to remove it by hand because it still limits the agent to `fix/` and `feature/`.

With `--main-gate`, `--migrate` still renames the hand-made fence rulesets but does not offer to delete the main gate.

### `agent-new verify`: proving the fence

Run it after `protect`, as the machine user (it uses that account's token, never yours). With a project name it works in that project's running container, in a temporary git worktree, so your checkout is not touched. With `<owner>/<repo> --vault ...` it works in a temporary clone that it removes afterwards.

It makes one empty commit and then tries, in order:

1. a direct push to the default branch (must be refused);
2. creating a branch outside the allowed names (must be refused);
3. creating a tag (must be refused);
4. a PR from `chore/verify-fence` into the default branch, and merging it (the merge must be refused; the PR is then closed);
5. if `allen-dev` exists: a PR from `chore/verify-fence-dev` into `allen-dev`, waiting for its checks, then a squash merge (must succeed, and its branch is deleted).

You should see one line `OK (refused as expected): ...` for each refusal, then `OK (merged as expected): ...`, and last `FENCE VERIFIED on <repo>`. The temporary branches and PRs are removed, except that the last check leaves one empty commit on `allen-dev`. If `allen-dev` is missing, check 5 is skipped and the tool says so. If the repo's checks are red on the PR into `allen-dev`, it stops and asks you to fix CI first.

How to read a failure:

- `GATE NOT BINDING: '<check>' SUCCEEDED`: a push or merge that should have been refused went through. Stop. The tool deletes what it created where it can, and prints the command to run if it cannot. Do not use the repo until the rulesets are fixed.
- `GATE NOT BINDING: '<check>' was refused, but not for the expected reason`: GitHub refused, but its message did not say that a rule did it. The tool prints GitHub's message. Do not work around it; report the text.

With `--main-gate`, `verify` runs the older merge-gate checks instead (step 6.2 below), not the fence checks.

## Rollout order

Do this order the first time, on the repos you already have.

1. **Pick a first repo that has no ruleset on its default branch except the fence**: no `protect-main`, and no ruleset named `main`. Run `agent-new protect <owner>/<repo> --vault agent-<project>`, then `agent-new verify <project>`. *Why: `verify` has to show that the fence alone stops a merge into the default branch. On a repo that still has the older gate, a refusal could come from that gate instead, and the check would prove nothing about the fence.*
2. **Note GitHub's exact refusal text for each check.** `verify` prints it when a refusal is "not for the expected reason". If `verify` stops with that message, that is a finding to report, not something to work around.
3. **Only after step 2 is clean:** take the other repos one at a time. For each: `agent-new protect <owner>/<repo> --migrate --vault agent-<project>`, answer the delete question, then `agent-new verify <project>`. Move to the next repo only when `FENCE VERIFIED` has printed.
4. **`agent-containers` keeps its main gate:** `agent-new protect <owner>/agent-containers --main-gate`, never `--migrate` without `--main-gate`.

The numbered steps that follow are the by-hand procedure. Step 1 is done once, step 3 once per project, steps 2, 4 and 5 per repo (`agent-new protect` does 2.1, 4 and 5), step 6 per project after its container is up, and step 7 once, for `agent-containers`.

## 1. Create the agent's GitHub account

1. Sign out of GitHub (or use a private window) and sign up at <https://github.com/signup> with a username such as `allen-agent`.
2. Use a **separate email address** (a plus-address or alias that reaches you is fine).
3. Enable 2FA: Settings → Password and authentication → Two-factor authentication.
4. Save the recovery codes in your **Personal** 1Password vault (tier C: only you, never a service account).

*Why a separate account:* permissions are per account. If the agent used yours it would inherit your Admin rights and could remove the ruleset.

## 2. Repo settings and files (as you, per repo)

`agent-new protect` does 2.1 for you. 2.2 and 2.3 concern the main gate and the Actions setting.

1. Repo → Settings → Collaborators → Add people → the machine user. **Repos owned by a personal account have no role picker:** collaborators get one fixed level, equivalent to Write (push branches, open PRs; cannot change settings or rulesets). Organisation repos do have roles: choose **Write** (not Maintain, not Admin). Then sign in as the machine user and **accept the invitation** (`https://github.com/<owner>/<repo>/invitations`). *What stops it merging into the default branch is the fence (step 4), not the role.*
2. **Only for a repo with the main gate:** add `.github/CODEOWNERS` containing exactly one line, via a PR:

   ```
   * @AllenLarocque
   ```

   (For a new project repo, `.github/CODEOWNERS` (added to the project by `agent-up init`) ships with an `@OWNER` placeholder: replace it with your username rather than copying this line blindly.)

   *Why: with "Require review from Code Owners" (step 4.3), only an approval from you counts.* (`agent-containers` already has this file. Repos without the main gate do not need it; the template still adds it and an existing file does no harm.)
3. Repo → Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests": **leave it OFF on every repo, `agent-containers` included.** (`publish` no longer opens a pull request, so it does not need it. If you turned it on for `agent-containers` earlier, turn it off.)

## 3. Create the machine user's GitHub token

**To be verified by the owner on first setup.** Signed in **as `allen-agent`**: profile picture → Settings → Developer settings → Personal access tokens.

**First, try a fine-grained token** (Fine-grained tokens → Generate new token): check whether your personal account is selectable as Resource owner. GitHub generally does not allow this for repos owned by another personal account, even for a collaborator. If it is selectable, prefer it, with: Repository access = only this project's repos; Expiration 90 days; Contents Read and write; Pull requests Read and write; Metadata Read-only; **no** Workflows permission unless needed (see below).

**If it is not selectable (the likely case for personal repos): use a classic PAT** (Tokens (classic) → Generate new token (classic)):

| Field | Value |
|---|---|
| Note | `agent-<project>` |
| Expiration | 90 days |
| Scope | `repo` |
| Scope `workflow` | **Not granted by default** |

A classic PAT with `repo` can act on **every repo the machine user can access**. Its reach is bounded only by which repos you invited `allen-agent` to (step 2.1), so **invite it only to the repos it needs**.

*Workflow permission (`workflow` scope on a classic PAT, or `Workflows: read and write` on a fine-grained one):* GitHub rejects any push that touches `.github/workflows/` without it. Grant it **only on a repo where the agent must edit workflows**. It is riskier because workflows run with their own permissions and can, for example, approve PRs or reach secrets. Without it, a workflow edit is refused, which is the safe default.

**Repos in an organisation** (for example PredictiveEcology later): prefer a fine-grained PAT with the organisation as Resource owner (if the organisation allows it), or a GitHub App installed by an organisation admin. Decide this with the organisation's admins.

Copy the token once and store it in 1Password: vault `agent-<project>`, item `github-agent`, field `token` (the `op://agent-<project>/github-agent/token` reference in `project.env`). Create the vault first: [1password-project-vault.md](1password-project-vault.md). Do not paste the token anywhere else.

**Rotation (every 90 days, or on suspected leak):** revoke the old token on GitHub (signed in as `allen-agent`), create a new one, update the vault item, then run `agent-up up <project>`. Short lifetimes matter because the resolved tier-A values (for example `GH_TOKEN`) are visible to anyone on the host who can run `docker inspect` on the container. (The 1Password service-account token is not: it stays on the host.)

## 4. Create the rulesets (as you, per repo)

This is what `agent-new protect` does, for someone doing it by hand. Repo → Settings → Rules → Rulesets → New ruleset.

### 4.1 `agent-fence` (New branch ruleset)

1. Ruleset name: `agent-fence`. Enforcement status: **Active**.
2. **Bypass list:** Add bypass → **Repository admin** role → bypass mode **Always allow**.
3. Target branches → Add target → **Include all branches**. Then Add target → **Exclude by pattern**, once for each of these 13 patterns: `allen-dev`, `fix/**`, `feature/**`, `chore/**`, `docs/**`, `test/**`, `ci/**`, `refactor/**`, `perf/**`, `revert/**`, `upstream/**`, `sync/**`, `experiment/**`.
4. Tick: **Restrict creations**, **Restrict updates**, **Restrict deletions**, **Block force pushes**. Tick nothing else.
5. Create. You should see the ruleset listed as Active.

### 4.2 `agent-fence-tags` (New tag ruleset)

1. Ruleset name: `agent-fence-tags`. Enforcement status: **Active**.
2. **Bypass list:** **Repository admin**, **Always allow**.
3. Target tags → Add target → **Include all tags**. No exclusions.
4. Tick: **Restrict creations**, **Restrict updates**, **Restrict deletions**.
5. Create.

### 4.3 `protect-main` (the main gate; `agent-containers` only)

Repo → Settings → Rules → Rulesets → New ruleset → **New branch ruleset**.

1. Ruleset name: `protect-main`. Enforcement status: **Active**.
2. **Bypass list:** Add bypass → **Repository admin** role → bypass mode **"For pull requests only"**. *Why: you are the repo's only admin, so you can merge your own PRs without needing a second approver (otherwise the 1-approval rule would lock you out), but "pull requests only" means nobody, you included, can push directly to `main`.*
3. Target branches → Add target → Include default branch.
4. Tick:
   - **Restrict deletions**
   - **Block force pushes**
   - **Require a pull request before merging**, with: Required approvals = **1**; **Dismiss stale pull request approvals when new commits are pushed**; **Require review from Code Owners**. Leave **Require approval of the most recent reviewable push** OFF. *Why off: you are the only code owner and the machine user cannot approve, so this rule would only block you from approving after you pushed to the PR yourself.*
   - **Require status checks to pass** → Add checks → `build-test` and `gitleaks` (both are jobs in this repo's `ci.yml`; selectable after CI has run once).
5. Create.

*Why `build-test` and `gitleaks`:* `build-test` builds the images through the publish script itself, smoke-tests them, then runs the firewall, launcher and acceptance tests, so it is the real quality gate and the publish rehearsal in one; `gitleaks` is the full-history secret scan. `lint` (shellcheck, actionlint) is advisory.
**The `build-test` check only appears in the picker after CI has run once on the repo.** If it is missing, open any PR first (CI runs), then come back and add it. Merge a PR only when its checks are green.

Editing rulesets needs Admin; the agent (Write) cannot.

## 5. The working branch and automatic deletion (as you, per repo)

`agent-new protect` does both.

1. Create `allen-dev`: Repo → Code → the branch drop-down → type `allen-dev` → **Create branch: allen-dev from main** (use the default branch's name if it is not `main`). You should see `allen-dev` in the branch list.
2. Repo → Settings → General → Pull Requests → tick **Automatically delete head branches**.

## 6. Verify (required, after `agent-up up <project>`)

### 6.1 The fence

Use `agent-new verify` (above). By hand, as the machine user inside the project container (`agent-up shell <project>`; `GH_TOKEN` is the `allen-agent` token), with `<default>` the default branch:

```bash
git switch -c chore/verify-fence <default>
git commit --allow-empty -m "chore: verify fence"
git push origin HEAD:<default>                      # 1. expected: REJECTED, message mentions a repository rule
git push origin HEAD:refs/heads/not-a-free-name     # 2. expected: REJECTED, same kind of message
git push origin HEAD:refs/tags/verify-tag           # 3. expected: REJECTED, same kind of message
git push -u origin chore/verify-fence               # 4. expected: succeeds
gh pr create --base <default> --fill                # 5. expected: succeeds
gh pr merge --squash                                # 6. expected: REFUSED
gh pr close chore/verify-fence
git push origin --delete chore/verify-fence         # clean up
```

*Why the rejection message matters:* a push rejected as "non-fast-forward" is not the right reason. It means the branch merely diverged, and a rule was not what stopped you. Then repeat items 4 and 5 against `allen-dev` (`--base allen-dev`); there the squash merge must succeed.

### 6.2 The main gate (`agent-containers` only)

`agent-new verify <project> --main-gate`, or by hand with a throwaway branch `verify-ruleset`:

```bash
git switch -c verify-ruleset
git commit --allow-empty -m "chore: verify ruleset"
git push -u origin verify-ruleset
gh pr create --fill                 # 1. expected: SUCCEEDS
```

Wait for `build-test` to go green (`gh pr checks --watch`). *If the repo has no CI check yet, skip the wait and note that the required-check rule is untested; a failure below may then come from the missing check only, so re-run once the check exists.* Then:

```bash
gh pr merge --squash                # 2. expected: FAILS, citing review/approval required
gh pr review --approve              # 3. expected: REFUSED
git push origin HEAD:main           # 4. expected: REJECTED, message mentions protected branch / repository rule
gh pr merge --squash --admin        # 5. expected: FAILS (the machine user is not an admin)
```

**Why wait for green first:** `gh pr merge` fails while a check is pending, and that alone proves nothing about the approval rule.
**Item 3** is GitHub behaviour regardless of rulesets (nobody can approve their own PR), so it is a sanity check.
Pass criteria: 2, 4 and 5 fail as described, and 3 is refused. If any succeeds, stop and fix the ruleset before any real work.
Finally, as **you** in the browser: open the PR, approve it, and merge it (or close it and delete the branch).

## 7. First publish of `agent-containers` (one-time)

After the first run of the `publish` workflow on `main`:

1. GitHub → your profile → Packages → `spades-base`, then `spades-gis`, `spades-research` (later `spades-bio`) → Package settings. Confirm the package is **linked to the `agent-containers` repo**, then Danger Zone → **Change visibility → Public**. *Why: public images pull without credentials.*
2. Run `agent-up update <project>` on a project. *Why: it asks ghcr.io anonymously for the digest, so it also proves the packages are public, and it checks the build attestation `publish` attached.*

**A package added later** (e.g. `spades-research`): do step 1 for it after the first `publish` run that builds it. Until it is public, `agent-up update` cannot read its digest and skips the project.

**The host needs `gh` logged in** (`gh auth login`, any account that can read the public repo), because `agent-up update` and `agent-new` verify the build attestation with it.

## 8. Order of operations for a new project

Steps 1 to 5 (the "set up" half, or `agent-new protect`) happen **before** `agent-up up <project>`. Step 6 (verify) happens **after** it, because it needs the container and the token. See [new-project.md](new-project.md).
