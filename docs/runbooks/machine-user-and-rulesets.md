# Runbook: machine user and branch rulesets

**Human procedure.** The agent must never perform these steps. You (the repo owner) do them in the GitHub web UI.
GitHub UI paths below are as of 2026-10 and may move; if a label differs, look for the nearest equivalent.

> **Decisions for the owner to confirm** (made while writing these runbooks, not yet confirmed by you):
> 1. The ruleset bypass list contains the **Repository admin** role, mode **"For pull requests only"**. You can merge your own PRs without a second approver, but nobody can push straight to `main`. The machine user has Write, so it is not a bypass actor and the gate binds it.
> 2. **CODEOWNERS** (`* @AllenLarocque`) plus "Require review from Code Owners": only your approval counts.
> 3. "Allow GitHub Actions to create and approve pull requests" is ON for `agent-containers` only, never for project repos.
> 4. The machine-user token has **no** workflow permission by default.
> 5. **Token type (to be verified by you on first setup):** GitHub fine-grained tokens generally cannot target repos owned by another *personal* account, even for a collaborator. So for personal repos the plan is a **classic PAT** on the machine user. If you find a fine-grained token CAN be created for your personal repos, prefer it. See step 3.

**Why this exists.** The agent pushes code and opens pull requests as a separate GitHub account (a "machine user"), not as you.
A branch ruleset on `main` makes it impossible for that account to merge its own work: only you can approve and merge.

For repos you admin, `agent-new protect` automates step 2.1 (the collaborator invite and its acceptance) and step 4 (the ruleset), and warns — without fixing — when step 2.2 (CODEOWNERS) or 2.3 (the Actions approval setting) is missing; `agent-new verify` automates step 6 (as the machine user, in a throwaway worktree or clone, leaving your checkout alone). Step 1 (the account) and step 3 (minting tokens) stay manual.

Step 1 is done once. Steps 2 and 4 are done per repo. Step 3 is done once per project (a token reaches only the repos the machine user is invited to). Step 5 is a note on ordering. Step 6 is done per project after its container is up (see [new-project.md](new-project.md)). Step 7 is done once, for `agent-containers`.

## 1. Create the agent's GitHub account

1. Sign out of GitHub (or use a private window) and sign up at <https://github.com/signup> with a username such as `allen-agent`.
2. Use a **separate email address** (a plus-address or alias that reaches you is fine).
3. Enable 2FA: Settings → Password and authentication → Two-factor authentication.
4. Save the recovery codes in your **Personal** 1Password vault (tier C: only you, never a service account).

*Why a separate account:* permissions are per account. If the agent used yours it would inherit your Admin rights and could remove the ruleset.

## 2. Repo settings and files (as you, per repo)

1. Repo → Settings → Collaborators → Add people → the machine user. **Repos owned by a personal account have no role picker:** collaborators get one fixed level, equivalent to Write (push branches, open PRs; cannot change settings or rulesets). Organisation repos do have roles: choose **Write** (not Maintain, not Admin). Then sign in as the machine user and **accept the invitation** (`https://github.com/<owner>/<repo>/invitations`). *What stops it merging is the ruleset (step 4), not the role.*
2. Add `.github/CODEOWNERS` containing exactly one line, via a PR:

   ```
   * @AllenLarocque
   ```

   (For a new project repo, `.github/CODEOWNERS` (added to the project by `agent-up init`) ships with an `@OWNER` placeholder: replace it with your username rather than copying this line blindly.)

   *Why: with "Require review from Code Owners" (step 4), only an approval from you counts. Without it, any account that is allowed to approve could satisfy the "1 approval" rule.* (`agent-containers` already has this file.)
3. Repo → Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests":
   - **`agent-containers` ONLY: tick it and Save.** The `publish` workflow needs it to open the digests PR.
   - **On every project repo it must stay OFF.** If it is on, a workflow can approve a PR. With Code Owners required (step 4) a bot approval cannot satisfy the gate, so this is defence in depth rather than the only barrier, but there is no reason to leave it on.

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

## 4. Create the ruleset (as you, per repo)

Repo → Settings → Rules → Rulesets → New ruleset → **New branch ruleset**.

1. Ruleset name: `protect-main`. Enforcement status: **Active**.
2. **Bypass list:** Add bypass → **Repository admin** role → bypass mode **"For pull requests only"**. *Why: you are the repo's only admin, so you can merge your own PRs without needing a second approver (otherwise the 1-approval rule would lock you out), but the "pull requests only" mode means no one, you included, can push directly to `main`. The machine user is Write, not admin, so it is not a bypass actor and every rule binds it.*
3. Target branches → Add target → Include default branch.
4. Tick:
   - **Restrict deletions**
   - **Block force pushes**
   - **Require a pull request before merging**, with: Required approvals = **1**; **Dismiss stale pull request approvals when new commits are pushed**; **Require review from Code Owners**. Leave **Require approval of the most recent reviewable push** OFF.
     *Why off: you are the only code owner and the bot cannot approve, so this rule only blocks you from approving a PR after you pushed to it yourself. "Dismiss stale approvals" plus "Code Owners" already mean your approval must be of the final commit.*
   - **Require status checks to pass** → Add checks → `build-test` and `gitleaks` (both are jobs in this repo's `ci.yml`; selectable after CI has run once). Project repos get their own `gitleaks` workflow from `agent-up init`.
5. Create.

*Why `build-test` and `gitleaks`:* `build-test` builds the images through the publish script itself (against a local registry, layers cached), smoke-tests them by digest, then runs the firewall, launcher and acceptance tests, so it is the real quality gate and the publish rehearsal in one; `gitleaks` is the full-history secret scan. `lint` (shellcheck, actionlint) is advisory here.
**The `build-test` check only appears in the picker after CI has run once on the repo.** If it is missing, open any PR first (CI runs), then come back and add it. On non-`agent-containers` repos, require whatever CI job you have, or skip that rule if there is none.

**Note:** your "pull requests only" bypass also skips the required status check, so do not merge a red PR just because you can.

Editing rulesets needs Admin; the agent (Write) cannot.

## 5. Order of operations for a new project

Steps 1 to 4 (the "set up" half) happen **before** `agent-up up <project>`. Step 6 (verify the gate) happens **after** `agent-up up <project>`, because it needs the container and the token. See [new-project.md](new-project.md).

## 6. Verify the gate (required, after `agent-up up <project>`)

Run as the machine user **inside the project container** (`agent-up shell <project>`; `GH_TOKEN` is the `allen-agent` token). Use a throwaway branch.

```bash
git switch -c verify-ruleset
git commit --allow-empty -m "chore: verify ruleset"
git push -u origin verify-ruleset
gh pr create --fill                 # 1. expected: SUCCEEDS
```

Now **wait for `build-test` to go green** on the PR (`gh pr checks --watch`). *If the project repo has no CI check yet, skip this wait and note that the required-check rule is untested; you still verify the approval gate below, but a failure may then be caused by the missing check only, so re-run step 2 once the check exists.* Then:

```bash
gh pr merge --squash                # 2. expected: FAILS, citing review/approval required
gh pr review --approve              # 3. expected: REFUSED
git push origin HEAD:main           # 4. expected: REJECTED, message mentions protected branch / repository rule
gh pr merge --squash --admin        # 5. expected: FAILS (the machine user is not an admin)
```

**Why wait for green first:** `gh pr merge` fails while a check is pending, and that failure alone proves nothing about the approval rule. With checks green, a failure citing the required review is a real test.
**Item 3** is GitHub behaviour regardless of rulesets (nobody can approve their own PR), so it is a sanity check, not proof of the ruleset.
**Item 4** must be rejected because of the protected branch or repository rule. A "non-fast-forward" rejection is not the right reason: it means the branch merely diverged, and the rule was not what stopped you.

Pass criteria: 2, 4 and 5 fail as described (and 3 is refused). If any succeeds, stop: the ruleset is not active, the account has too much access, or its bypass is misconfigured. Also confirm that on **project repos** the "Allow GitHub Actions to create and approve pull requests" setting is OFF (on `agent-containers` it is ON by design). With "Require review from Code Owners", a bot approval cannot satisfy the gate anyway, so that setting is defence in depth.

Finally, as **you** in the browser: open the PR, approve it, and merge it (or close it and delete the branch). Only your approval should count.

## 7. First publish of `agent-containers` (one-time)

After the first run of the `publish` workflow:

1. GitHub → your profile → Packages → `spades-base`, then `spades-gis`, `spades-research` (later `spades-bio`) → Package settings. Confirm the package is **linked to the `agent-containers` repo**, then Danger Zone → **Change visibility → Public**. *Why: public images pull without credentials.*
2. Open the auto-created `chore/digests-*` PR and confirm a `build-test` run appears as a check on it. *Why: PRs opened by Actions do not trigger workflows by themselves; `publish` dispatches CI explicitly, and this proves it worked.* If it does not appear, **stop and decide**: the fallback is a GitHub App token, which would be a documented exception to the "no extra credentials" rule.
3. Review and merge that PR yourself. Copy the digest from `digests.md` into projects as in [new-project.md](new-project.md).

**A package added later** (e.g. `spades-research`): its first `chore/digests-*` PR shows a red `build-test`, because CI checks digests anonymously and a new package starts private. Make it public (step 1), re-run the failed job (or `gh workflow run ci.yml --ref chore/digests-<tag>`), then merge.
