# Runbook: machine user and branch rulesets

**Human procedure.** The agent must never perform these steps. You (the repo owner) do them in the GitHub web UI.
GitHub UI paths below are as of 2026-10 and may move; if a label differs, look for the nearest equivalent.

> **Decisions for the owner to confirm** (made by the controller, not yet confirmed by you):
> 1. The ruleset bypass list contains the **Repository admin** role, mode **"For pull requests only"**. You can merge your own PRs without a second approver, but nobody can push straight to `main`. The machine user has Write, so it is not a bypass actor and the gate binds it.
> 2. **CODEOWNERS** (`* @AllenLarocque`) plus "Require review from Code Owners": only your approval counts.
> 3. "Allow GitHub Actions to create and approve pull requests" is ON for `agent-containers` only, never for project repos.
> 4. The machine-user token has **no** `Workflows` permission by default.

**Why this exists.** The agent pushes code and opens pull requests as a separate GitHub account (a "machine user"), not as you.
A branch ruleset on `main` makes it impossible for that account to merge its own work: only you can approve and merge.

Do steps 1 and 2 once. Do steps 3 to 5 per repo the agent works on. Step 6 happens after the project container is up (see [new-project.md](new-project.md)). Step 7 is one-time for `agent-containers`.

## 1. Create the agent's GitHub account

1. Sign out of GitHub (or use a private window) and sign up at <https://github.com/signup> with a username such as `allen-agent`.
2. Use a **separate email address** (a plus-address or alias that reaches you is fine).
3. Enable 2FA: Settings → Password and authentication → Two-factor authentication.
4. Save the recovery codes in your **Private** 1Password vault (tier C: only you, never a service account).

*Why a separate account:* permissions are per account. If the agent used yours it would inherit your Admin rights and could remove the ruleset.

## 2. Repo settings and files (as you, per repo)

1. Repo → Settings → Collaborators → Add people → `allen-agent` → role **Write** (not Maintain, not Admin). Then sign in as `allen-agent` and **accept the invitation**. *Why Write: enough to push branches and open PRs; Maintain and Admin can change rules.*
2. Add `.github/CODEOWNERS` containing exactly one line, via a PR:

   ```
   * @AllenLarocque
   ```

   *Why: with "Require review from Code Owners" (step 4), only an approval from you counts. Without it, any account that is allowed to approve could satisfy the "1 approval" rule.* (`agent-containers` already has this file.)
3. Repo → Settings → Actions → General → Workflow permissions → "Allow GitHub Actions to create and approve pull requests":
   - **`agent-containers` ONLY: tick it and Save.** The `publish` workflow needs it to open the digests PR.
   - **On every project repo it must stay OFF.** **If it is on, a workflow can approve a PR, and an agent that can edit workflows could approve its own work, defeating the gate.**

## 3. Create the fine-grained token

Signed in **as `allen-agent`**: profile picture → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.

| Field | Value |
|---|---|
| Resource owner | **your** account (the repo owner) |
| Repository access | Only select repositories: this project's repos only |
| Expiration | 90 days |
| Contents | Read and write |
| Pull requests | Read and write |
| Metadata | Read-only (selected automatically) |
| Workflows | **Not granted by default** (see below) |

*Workflows:* GitHub rejects any push that touches `.github/workflows/` unless the token has `Workflows: read and write`. Grant it **only on a repo where the agent must edit workflows**, and understand it is riskier: workflows run with their own permissions and can, for example, approve PRs or reach secrets. Without it, the agent's push of a workflow change is refused, which is the safe default.

If your account is not selectable as Resource owner for `allen-agent`: first check that `allen-agent` has **accepted the collaborator invitation** (step 2.1). If it is still unavailable, **stop and decide** (alternatives: a GitHub App, or moving the repos to an organisation). Do not work around it.

Copy the token once and store it in 1Password: vault `agent-<project>`, item `github-agent`, field `token` (the `op://agent-<project>/github-agent/token` reference in `project.env`). Create the vault first: [1password-project-vault.md](1password-project-vault.md). Do not paste the token anywhere else.

Rotate about every 90 days (it expires anyway), then run `./up`. Another reason: the resolved token is visible to anyone on the host who can run `docker inspect` on the container, so keep its lifetime short.

## 4. Create the ruleset (as you, per repo)

Repo → Settings → Rules → Rulesets → New ruleset → **New branch ruleset**.

1. Ruleset name: `protect-main`. Enforcement status: **Active**.
2. **Bypass list:** Add bypass → **Repository admin** role → bypass mode **"For pull requests only"**. *Why: you are the repo's only admin, so you can merge your own PRs without needing a second approver (otherwise the 1-approval rule would lock you out), but the "pull requests only" mode means no one, you included, can push directly to `main`. The machine user is Write, not admin, so it is not a bypass actor and every rule binds it.*
3. Target branches → Add target → Include default branch.
4. Tick:
   - **Restrict deletions**
   - **Block force pushes**
   - **Require a pull request before merging**, with: Required approvals = **1**; **Dismiss stale pull request approvals when new commits are pushed**; **Require review from Code Owners**; **Require approval of the most recent reviewable push**
   - **Require status checks to pass** → Add checks → `build-test`
5. Create.

*Why `build-test` only:* it builds the images and runs the smoke, firewall and template tests, so it is the real quality gate. `publish-dryrun` is a heavier rehearsal of the publish pipeline and would make unrelated merges wait; add it later if publish breakage becomes recurring.
**The `build-test` check only appears in the picker after CI has run once on the repo.** If it is missing, open any PR first (CI runs), then come back and add it. On non-`agent-containers` repos, require whatever CI job you have, or skip that rule if there is none.

Editing rulesets needs Admin; the agent (Write) cannot.

## 5. Order of operations for a new project

Steps 1 to 4 (the "set up" half) happen **before** `./up`. Step 6 (verify the gate) happens **after** `./up`, because it needs the container and the token. See [new-project.md](new-project.md).

## 6. Verify the gate (required, after `./up`)

Run as the machine user **inside the project container** (`docker exec -it -u agent <project>-agent-1 zsh`; `GH_TOKEN` is the `allen-agent` token). Use a throwaway branch.

```bash
git switch -c verify-ruleset
git commit --allow-empty -m "chore: verify ruleset"
git push -u origin verify-ruleset
gh pr create --fill                 # 1. expected: SUCCEEDS
```

Now **wait for `build-test` to go green** on the PR (`gh pr checks --watch`). Then:

```bash
gh pr merge --squash                # 2. expected: FAILS, citing review/approval required
gh pr review --approve              # 3. expected: REFUSED (cannot approve your own PR)
git push origin HEAD:main           # 4. expected: REJECTED (protected branch)
gh pr merge --squash --admin        # 5. expected: FAILS (the machine user is not an admin)
```

**Why wait for green first:** if you try `gh pr merge` while the check is still pending, it fails because of the pending check alone, which proves nothing about the approval rule. With checks green, a failure that cites the required review is a real test of the gate.

Pass criteria: all of 2 to 5 fail as described. If any succeeds, stop: the ruleset is not active, the account has too much access, or the Actions-approval setting is on. Fix before real work.

Finally, as **you** in the browser: open the PR, approve it, and merge it (or close it and delete the branch). Only your approval should be accepted.

## 7. First publish of `agent-containers` (one-time)

After the first run of the `publish` workflow:

1. GitHub → your profile → Packages → `spades-base`, then `spades-gis` (later `spades-bio`) → Package settings. Confirm the package is **linked to the `agent-containers` repo**, then Danger Zone → **Change visibility → Public**. *Why: public images pull without credentials.*
2. Open the auto-created `chore/digests-*` PR and confirm a `build-test` run appears as a check on it. *Why: PRs opened by Actions do not trigger workflows by themselves; `publish` dispatches CI explicitly, and this proves it worked.* If it does not appear, **stop and decide**: the fallback is a GitHub App token, which would be a documented exception to the "no extra credentials" rule.
3. Review and merge that PR yourself. Copy the digest from `digests.md` into projects as in [new-project.md](new-project.md).
