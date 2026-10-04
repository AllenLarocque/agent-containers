# Runbook: 1Password project vault and service account

**Human procedure.** The agent must never perform these steps.

**Why this exists.** Each project gets its own vault and its own read-only service account. A compromised or mistaken container can then only ever see that one project's tier A secrets, and you can cut it off in one click. Replace `<project>` below with the project folder name (lowercase).

## 1. Create the vault

1Password app → New Vault → name `agent-<project>`. Put only tier A items in it (scoped, revocable credentials: the GitHub machine-user token, project API keys).
The GitHub token goes in as item `github-agent`, field `token` (see [machine-user-and-rulesets.md](machine-user-and-rulesets.md), step 3). That is exactly the reference `op://agent-PROJECTNAME/github-agent/token` in the template's `project.env`.

## 2. Create the service account

1. 1Password.com (web) → Developer → Directory → **Service Accounts** → New Service Account (under Infrastructure Secrets).
2. Name: `agent-<project>`.
3. Vault access: add **only** `agent-<project>`, permission **Read** (read-only).
4. Create and copy the token. 1Password shows it once.

## 3. Put the token on the host (never in a repo)

Store it where only your host login sees it: your OS keychain, or a line in your shell profile:

```bash
export OP_SERVICE_ACCOUNT_TOKEN='<paste token here>'
```

`./resolve-secrets` reads `OP_SERVICE_ACCOUNT_TOKEN` from the host environment and stops with an error if it is missing.
Only one project's token can be in the environment at a time: if you work on several projects, set it per shell (for example in a small per-project `direnv`/profile snippet kept outside the repo).
Never commit it. The template ships a gitleaks pre-commit hook as a backstop (`pre-commit install` once per clone).
VS Code started from the dock or Start menu may not see your shell profile: see "VS Code and `OP_SERVICE_ACCOUNT_TOKEN`" in the project template `README.md`.

Check it works (host terminal): `op vault list` should list `agent-<project>` and nothing else.

## 4. Tier B items stay out of reach

Credentials that can do irreversible or public things (ENA submissions, Zenodo publishing) go in a vault named **`human-actions`**. **No service account is ever given access to it.** You use those with your own `op` session on the host, when you decide to.
Recovery codes and anything else tier C live in your **Private** vault, also never shared with a service account.

## 5. Rotation and revocation

- **Revoke now** (suspected leak, or finished with the project): 1Password.com → Developer → Service Accounts → `agent-<project>` → Revoke/Delete. Effective immediately; the agent can no longer read the vault.
- **Rotate**: create a new token for the same service account (or a new account with the same access), update `OP_SERVICE_ACCOUNT_TOKEN` on the host.
- **Change any secret**: edit it in 1Password, then run `./up` in the project. The container's environment is fixed at creation, so it must be recreated to see the new value.
- Also revoke the matching GitHub fine-grained token if it may have leaked (GitHub, signed in as `allen-agent` → Developer settings).

Files written by `./resolve-secrets`: `~/.config/agent-containers/<project>.env` (mode 600; the directory is mode 700). These are outside every repo.
