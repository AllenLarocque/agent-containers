# Runbook: machine user and branch rulesets

**Human procedure.** The agent must never perform these steps. You (the repo owner) do them in the GitHub web UI.

**Why this exists.** The agent pushes code and opens pull requests as a separate GitHub account (a "machine user"), not as you.
A branch ruleset on `main` then makes it impossible for that account to merge its own work: only you can approve and merge.
This is the main guard against the agent changing `main` unreviewed.

Do steps 1 to 3 once. Do steps 4 to 6 for every repo the agent works on (including `agent-containers` itself).

## 1. Create the agent's GitHub account

1. Sign out of GitHub (or use a private window) and sign up at <https://github.com/signup> with a username such as `allen-agent`.
2. Use a **separate email address** (GitHub will not let one account share your primary). A plus-address or alias that reaches you is fine.
3. Enable 2FA: Settings → Password and authentication → Two-factor authentication.
4. Save the recovery codes in your **Private** 1Password vault (tier C: only you, never a service account).

*Why a separate account:* permissions are per account. If the agent used your account it would inherit your Admin rights and could remove the ruleset.

## 2. Give it Write access on each repo

As **you**: repo → Settings → Collaborators → Add people → `allen-agent` → role **Write** (not Maintain, not Admin). Then accept the invitation while signed in as `allen-agent`.

*Why Write:* enough to push branches and open PRs. Maintain and Admin can change rules.

## 3. Create the fine-grained token

Signed in **as `allen-agent`**: profile picture → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.

| Field | Value |
|---|---|
| Resource owner | **your** account (the repo owner), not `allen-agent` |
| Repository access | Only select repositories: this project's repos only |
| Expiration | 90 days |
| Contents | Read and write |
| Pull requests | Read and write |
| Metadata | Read-only (selected automatically) |
| Workflows | Read and write, **only if the agent should edit `.github/workflows/*`** |

*Why Workflows:* GitHub refuses any push that touches `.github/workflows/` unless the token has this permission. Without it the agent's push is rejected. Leave it off for projects where the agent has no reason to edit CI.

If the resource owner is an organisation, the organisation may need to approve the token before it works.

Copy the token once (GitHub shows it only once) and store it in 1Password: vault `agent-<project>`, item `github-agent`, field `token`. This is the `op://agent-<project>/github-agent/token` reference in `project.env`. Create the vault first: see [1password-project-vault.md](1password-project-vault.md). Do not paste the token anywhere else.

After rotating the token (about every 90 days), run `./up` in the project so the container picks it up.

## 4. One-time repo settings (as you)

Repo → Settings → Actions → General → Workflow permissions: tick **Allow GitHub Actions to create and approve pull requests** and Save.
*Why:* the `publish` workflow opens a PR that updates `digests.md`; without this it fails. Only needed on `agent-containers`.

## 5. Create the ruleset on each repo (as you)

Repo → Settings → Rules → Rulesets → New ruleset → **New branch ruleset**.

1. Ruleset name: `protect-main`. Enforcement status: **Active**.
2. Bypass list: leave **empty**. *Why: anyone on the list (including you) can skip the rules; an empty list means the rules bind everyone.*
3. Target branches → Add target → Include default branch (or "Include by pattern" `main`).
4. Tick these rules:
   - **Restrict deletions**
   - **Block force pushes**
   - **Require a pull request before merging**, with **Required approvals = 1**
   - **Require status checks to pass**: Add checks → `build-test`
5. Create.

*Why `build-test` only:* it is the job that builds the images and runs the smoke, firewall and template tests, so it is the real quality gate. `publish-dryrun` is a heavier rehearsal of the publish pipeline (local registry); it is informational and would make unrelated merges wait on it. Add it later if publish breakage becomes a recurring problem.
The check name appears in the picker only after the workflow has run once on that repo; push a PR first if it is missing. On repos other than `agent-containers`, require whatever CI job you have, or skip that rule if there is none.

Ruleset editing needs **you** (Admin). The agent cannot do it: its role is Write.

## 6. Verify (required)

Run these **as the machine user from inside a project container** (`docker exec -it -u agent <project>-agent-1 zsh`), where `GH_TOKEN` is the `allen-agent` token. Use a throwaway branch.

```bash
git switch -c verify-ruleset
git commit --allow-empty -m "chore: verify ruleset"
git push -u origin verify-ruleset
gh pr create --fill          # expected: SUCCEEDS
gh pr merge --squash         # expected: FAILS (required approval / required checks)
```

Then, as **you** in the browser: open the PR, review, approve and merge it (or close it and delete the branch).

Pass criteria: `gh pr create` works, `gh pr merge` is refused, and only your own account can complete the merge. If `gh pr merge` succeeds, stop: the ruleset is not active, the bypass list is not empty, or the account has Admin. Fix before any real work.

## 7. First publish of `agent-containers` (one-time)

After the first run of the `publish` workflow:

1. GitHub → your profile → Packages → open `spades-base`, then `spades-gis` (later `spades-bio`) → Package settings. Confirm the package is **linked to the `agent-containers` repo**, then Danger Zone → **Change visibility → Public**. *Why: private packages need a login to pull; public images let containers pull with no credentials.*
2. Open the auto-created `chore/digests-*` PR and confirm a `build-test` run appears as a check on it. *Why: PRs opened by Actions do not trigger workflows by themselves; `publish` dispatches CI explicitly, and this proves it worked.* If it does not appear, **stop and contact the maintainer**. The fallback is a GitHub App token, which would be a documented exception to the "no extra credentials" rule.
3. Review and merge that PR yourself. Copy the digest from `digests.md` into projects as in [new-project.md](new-project.md).
