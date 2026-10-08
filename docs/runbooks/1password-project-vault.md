# Runbook: 1Password project vault and service account

UI paths are as of 2026-10 and may move.

**Human procedure.** The agent must never perform these steps.

**Why this exists.** Each project gets its own vault and its own read-only service account. A compromised or mistaken container can then only ever see that one project's tier A secrets, and you can cut it off in one click. Replace `<project>` below with the project folder name (lowercase).

## 1. Create the vault

1Password app → New Vault → name `agent-<project>`. Put only tier A items in it (scoped, revocable credentials: the GitHub machine-user token, project API keys).
The GitHub token goes in as item `github-agent`, field `token` (see [machine-user-and-rulesets.md](machine-user-and-rulesets.md), step 3). That is exactly the reference `op://agent-PROJECTNAME/github-agent/token` in the template's `project.env`.

## 2. Create the service account

**Fastest: the CLI** (signed in as you with `eval "$(op signin)"`; the token is never printed). Run it line by line, or as one paste: nothing here waits for input.

```bash
P=<project>
op vault create "agent-$P"
TOK=$(op service-account create "agent-$P" --expires-in 90d --vault "agent-$P:read_items" --raw)
op item create --vault Personal --category "API Credential" --title "agent-$P service account" "credential[concealed]=$TOK" >/dev/null && echo saved
unset TOK
OP_SERVICE_ACCOUNT_TOKEN="$(op read "op://Personal/agent-$P service account/credential")" op vault list
```

The last line must list ONLY `agent-<project>`. (Your personal vault is `Personal` on individual accounts, `Private` on some others: use the name `op vault list` shows.)

**Or in the web UI:**


1. 1Password.com (web) → Developer → Directory → **Service Accounts** → New Service Account (under Infrastructure Secrets).
2. Name: `agent-<project>`.
3. Vault access: add **only** `agent-<project>`, permission **Read** (read-only).
4. Create and copy the token. 1Password shows it **once**.
5. **Immediately** save it as an item in your **Personal** vault (for example item `agent-<project> service account`, field `credential`). Only you can read that vault; no service account is given access to it. If you lose the token you must revoke the account and create a new one.

## 3. Put the token on the host (never in a repo)

Do **not** `export OP_SERVICE_ACCOUNT_TOKEN=...` in a global shell profile: that leaves the token in plaintext on disk and exposes it to every process you start, for every project. Prefer one of:

- **Per-project `direnv`:** keep BOTH the token file and any `.envrc` outside every agent-writable folder (the project folder, spades.ai, `~/agent-memory`). For example, put the `.envrc` in a parent directory the agent never mounts, and have it source `~/.config/agent-tokens/<project>.envrc` (mode 600), which sets `OP_SERVICE_ACCOUNT_TOKEN`. direnv runs the `.envrc` in your shell, so an agent-writable one would run agent-written code with your token. Reading the token at use time (`op read`, next bullet) is safer still.
- **Read at use time:** fetch the token from the macOS Keychain, the Windows credential store, or `op` itself (using your own biometric-unlocked session) into the **current shell only**, then run `agent-up up <project>`, for example `export OP_SERVICE_ACCOUNT_TOKEN="$(op read 'op://Personal/agent-<project> service account/credential')"` (the Personal-vault item saved in step 2).

`agent-up up` reads `OP_SERVICE_ACCOUNT_TOKEN` from the host environment and stops with an error if it is missing.
**Warning:** if the wrong project's token is in your environment, `agent-up up` either fails (vault not readable) or reads a different vault than you intended. Check the project before `agent-up up`.
Never commit the token. Each project repo runs gitleaks in CI as a backstop (`.github/workflows/gitleaks.yml`, added by `agent-up init`).

Check it works (host terminal): `op vault list` should list `agent-<project>` and nothing else.

## 4. Tier B items stay out of reach

Credentials that can do irreversible or public things (ENA submissions, Zenodo publishing) go in a vault named **`human-actions`**. **No service account is ever given access to it.** You use those with your own `op` session on the host, when you decide to.
Recovery codes and anything else tier C live in your **Personal** vault, also never shared with a service account.

## 5. Rotation and revocation

- **Revoke now** (suspected leak, or finished with the project): delete the service account on 1Password.com (Developer → Service Accounts). It takes effect at once; the agent can no longer read the vault.
- **Rotate a service-account token:** revoke the service account and create a new one with the same vault access (tokens cannot be shown again, and vault access is set when the account is created). Then update the token on the host and run `agent-up up <project>`.
- **Change any secret:** edit it in 1Password, then `agent-up up <project>`. The container's environment is fixed at creation, so it must be recreated.
- Also revoke the matching GitHub fine-grained token if it may have leaked (GitHub, signed in as `allen-agent` → Developer settings).
- Rotate the tier-A token every 90 days regardless: once resolved, it is visible to anyone on the host who can run `docker inspect` on the container.

`agent-up` writes no secret to disk: `op run` resolves the values into the environment of `docker compose` only. `~/.config/agent-containers/<project>/.generated/env-passthrough.yaml` holds the key NAMES only.
