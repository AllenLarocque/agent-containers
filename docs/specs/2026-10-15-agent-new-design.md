# agent-new — owner-side new-project automation: design spec

**Status:** draft for review · **Date:** 2026-10-15 · **Owner:** Allen Larocque

**Context.** The first project set up under the new-project runbook (`spades_harvesting`,
2026-10-15) showed that nearly every step is deterministic, and that the step most likely to be
missed (the per-project Tailscale Serve mapping) is exactly the kind a script never misses. This
spec automates the mechanical steps of [`docs/runbooks/new-project.md`](../runbooks/new-project.md)
and [`docs/runbooks/machine-user-and-rulesets.md`](../runbooks/machine-user-and-rulesets.md)
while keeping every judgment call and every credential ceremony with the owner.

## 1. Purpose and non-goals

`bin/agent-new` is a single bash script, a sibling of `bin/agent-up`, that an **owner** runs on
the host to stand up a new agent-container project — repo, config, vault pauses, GitHub wiring,
Tailscale mapping, container start, and the merge-gate verification — in one resumable flow.

Non-goals:
- It never replaces the runbooks: they stay the authoritative reference procedure, and
  `agent-new` cites them in its output. The runbooks gain a one-line pointer to `agent-new`.
- It does not choose project scope, allowlist domains (beyond the base list), module repos, or
  write briefs. Those stay with the owner and their host-side agent.
- It does not create machine-user accounts or 1Password accounts (one-time setup, runbook §1).
- No GUI automation: anything that genuinely requires the browser is printed as a short
  checklist instead.

## 2. Privilege model

`agent-up` runs the sandbox with a project's read-only service-account token. `agent-new` is the
opposite end of the trust spectrum: it runs **as the owner** — their `gh` login (repo admin),
their interactive `op` session — plus, for exactly one call (invitation accept), the machine
user's token read from the project vault at use time. That is why it is a separate binary:
owner-side orchestration with admin powers never lives in the same script as the agent-side
sandbox lifecycle.

Invariants:
- No token is ever written to disk; secrets live in the environment of a single command and are
  unset immediately after (vault runbook §3).
- `agent-new` never pushes to `main` after the ruleset exists, never merges, never approves.
- It never modifies an existing ruleset ("never weaken", house rule): drift is reported,
  changes are refused.
- `tailscale funnel` is never invoked; the check is per mapping for this project's T3 port: a
  mapping not reading `(tailnet only)`, or any Funnel mapping for that port, is a hard error.
- An inherited `OP_SERVICE_ACCOUNT_TOKEN` is ignored (unset at start); the owner's `op` session
  is used.

## 3. Interface

```
agent-new project <folder> [--image base|gis|bio] [--public] [--no-research]
                           [--t3 publish|1|0] [--token-from <vault>] [--machine-user <user>]
agent-new protect <owner>/<repo> [--machine-user <user>] [--vault <op-vault>] [--require <check>]...
agent-new verify  <project> | <owner>/<repo> [--vault <op-vault>]
```

`verify <owner>/<repo>` requires `--vault` (the project vault holding the machine user's
`github-agent` token); `verify <project>` uses the running container's own login.

- `project` — the full flow (§4). `<folder>` as in `agent-up init`: the host folder name under
  `~/GitHub/`, lowercased to form the project name. `--vault` is refused: the project always
  uses vault `agent-<project>`.
- `protect` — GitHub wiring for any single repo the owner admins (§5). `project` calls it; it
  also stands alone for wiring module repos to an existing project (e.g. spades_harvesting
  phase 2).
- `verify` — the merge-gate verification (§6). With a project name it runs inside that
  project's container via `docker exec`; with `<owner>/<repo>` it uses a temporary clone
  authenticated as the machine user.

Defaults encode current conventions: repo private, `RESEARCH=1`, `T3_CONNECT=publish`. The
machine-user name comes from `MACHINE_USER=` in `~/.config/agent-containers/agent-up.conf`
(new, one-time line), overridable with `--machine-user`. Nothing is SpaDES-specific.

## 4. The `project` flow

Every step is check-then-act: it tests whether its outcome already exists and skips with an
`agent-new: SKIP (done):` line when it does, so a failed run is re-run from the top and resumes.
Steps in order:

1. **Preflight.** `gh auth status` must be the owner (refuse if it is the machine user);
   `op`, `docker`, `agent-up` on PATH; `MACHINE_USER` known; folder absent or already a clone
   of the target repo.
2. **Repo.** `gh repo create <owner>/<Folder>` (private unless `--public`) and clone to
   `~/GitHub/<Folder>`; normalize the initial branch to `main`.
3. **Config.** `agent-up init` with `--image`; replace the digest placeholder in
   `compose.yaml` with the newest matching row parsed from `digests.md`; set `RESEARCH` and
   `T3_CONNECT` in `project.conf` per flags (edit the existing lines, never append
   duplicates).
4. **Repo files.** Replace `@OWNER` in `.github/CODEOWNERS` with the owner's login; commit
   `.github/CODEOWNERS`, `.github/workflows/gitleaks.yml` and `.gitignore` and push. The push
   happens only if `origin/main` is missing or local `main` has commits it lacks (a failed push
   is retried on re-run; a fetch that moved `origin/main` ahead is not pushed over). If the
   checkout is not on `main` (the agent is working), the step is skipped with a warning. Ordering
   is load-bearing: this direct push happens **before** the ruleset exists and gives gitleaks its
   first run.
5. **Vault (interactive).** Pause for `eval "$(op signin)"`, then the vault runbook §2 CLI
   sequence verbatim: create vault `agent-<project>`, 90-day read-only service account, token
   saved to the Personal vault, and the scoped `op vault list` self-check (must list exactly
   the one vault). Skipped cleanly if the vault already exists.
   Items are created from JSON on stdin (`op item create --vault V -`), so no secret is ever in
   argv; needs op CLI >= 2.6.2.
6. **GitHub token.** `--token-from <vault>` copies the `github-agent` item from another
   project's vault (the shared classic PAT); otherwise prompt with `read -rs` (printed on its
   own line, per the paste-block house rule) and create the item.
7. **Wiring.** The `protect` flow (§5) against the new repo.
8. **Tailscale.** Compute the HTTPS port (`8443 + T3_PORT - 3774`, README formula; honor
   `TAILSCALE_HTTPS_PORT` overrides). If a Windows `tailscale.exe` is reachable (WSL2), run
   `tailscale serve --bg --https=<port> <T3_PORT>` and assert `serve status` shows the mapping
   `(tailnet only)`; otherwise print the PowerShell command and wait for the owner to confirm.
9. **Up.** Read the project's service-account token from the owner's Personal vault into the
   environment of `agent-up up <project>` only. When `RESEARCH=1`, `agent-up up research` runs
   **without** the token (and restarts research). If no research config exists, warn and
   continue, telling the owner to run `agent-up init --profile research` then
   `agent-up up research`; `agent-new` never creates it.
10. **Gate.** The `verify` flow (§6). Only on a pass does the script declare success, then
    print: the interactive-login checklist (`claude`, `codex login --device-auth`, the
    `t3 connect` publish sequence when `T3_CONNECT=publish`), `agent-up pair <project>`, and
    the phone URL `https://$TAILSCALE_HOST:<port>`.

## 5. The `protect` flow

For one repo the owner admins:

1. **Collaborator.** `gh api PUT /repos/<r>/collaborators/<machine-user>` (as the owner).
   Personal repos have one fixed level (≈ Write); org repos pass `permission=push`.
2. **Accept.** As the machine user — token read from the project vault via `op read` for this
   one call — `GET /user/repository_invitations`, find the repo, `PATCH` to accept. Already a
   collaborator → skip.
3. **Ruleset.** If no ruleset named `protect-main` exists, create it via
   `gh api POST /repos/<r>/rulesets` from a canned JSON template: enforcement active; bypass =
   Repository admin role, mode `pull_request`; target = default branch; restrict deletions;
   block force pushes; pull request rule (1 approval, dismiss stale, code-owner review, last
   push approval); required status checks from `--require` (default `gitleaks` — the API
   accepts check contexts that have not run yet, so there is no wait). If `protect-main`
   exists: diff the live rules against the template, print the drift, and **refuse to touch
   it**.
4. **Warnings, not fixes.** Missing `.github/CODEOWNERS` or gitleaks workflow (runbook §2.2);
   "Allow GitHub Actions to create and approve pull requests" enabled (must stay off on
   project repos, runbook §2.3). Printed loudly; the owner decides.

## 6. The `verify` flow

Runbook §6, mechanized, as the machine user (via `docker exec -w /workspace` on the project
container, or a temp clone for a bare repo): both modes first assert the acting identity is the
machine user. Container mode works in a temporary worktree `/tmp/agent-new-verify` from a fresh
`origin/main`, leaving the owner's checkout alone; repo mode clones over https with git isolated
from the owner's git config. Then: throwaway branch (force-pushed) → empty commit → push →
`gh pr create` (must succeed) → wait for required checks green (retrying while CI registers its checks, tunable via
`AGENT_NEW_CHECK_TRIES` / `AGENT_NEW_CHECK_SLEEP`, then `gh pr checks --watch`; if the
repo has no CI yet, note the required-check rule as untested and continue) → then assert each
expected failure **by reason**, not just by exit code:

| Attempt | Must fail matching |
|---|---|
| `gh pr merge --squash` | `base branch policy\|review` |
| `gh pr review --approve` | `approve your own` |
| `git push origin HEAD:main` | `GH013\|repository rule` |
| `gh pr merge --squash --admin` | `rule violations\|not.*admin` |

Any unexpected success (or a rejection for the wrong reason, e.g. non-fast-forward on the push)
exits non-zero with `GATE NOT BINDING` and the evidence. On a pass it prints the PR URL and
reminds the owner to approve-and-merge or close it in the browser — `agent-new` itself never
closes the loop, by design.

## 7. Errors and style

`set -euo pipefail`, the `die()`/`conf_get` idioms of `bin/agent-up`, and `agent-new:`-prefixed
output in the same style. Interactive pauses are explicit (`read`), never hidden. Each owner-visible
action prints the exact command being run, so the script doubles as a narrated version of the
runbooks. If any step fails, the script says what succeeded, what to fix, and that re-running
resumes.

## 8. Testing

`tests/launcher/test-agent-new.sh`, in the harness style of `test-agent-up.sh`: stub `gh`,
`op`, `docker`, `git` and `tailscale.exe` that log invocations and replay canned GitHub API
responses (including the real error strings for §6's reason-matching). Covered:

- fresh `project` run: full call sequence in order, correct ruleset JSON posted;
- idempotent re-run: every step logs SKIP, zero mutating calls;
- resume: fail at the ruleset step, re-run, only the remaining steps execute;
- never-weaken: existing divergent `protect-main` → drift report, non-zero, no write;
- verify: all four refusals matched by reason; a stubbed *success* on push-to-main →
  `GATE NOT BINDING`, non-zero;
- preflight refusals: `gh` logged in as the machine user; missing `MACHINE_USER`; funnel/serve
  status without `(tailnet only)`.

Wired into `ci.yml` alongside the launcher job.

## 9. Documentation changes

- `docs/runbooks/new-project.md`: lead with `agent-new project <folder>`; manual steps kept as
  the reference ("what the script does, and what to do when it can't").
- `docs/runbooks/machine-user-and-rulesets.md`: note that steps 2–4 and 6 are automated by
  `agent-new protect` / `agent-new verify` for repos the owner admins.
- `project-template/README.md`: mention `agent-new` where the per-project Tailscale step is
  described.
