# Project template

Copy this folder into a SpaDES project root. The folder name becomes the compose project name (`PROJECT`).

**Never run plain `docker compose up`: use `./up`, so secrets are current.**

## Setup

1. Replace `REPLACE_WITH_DIGEST_FROM_digests.md` in `compose.yaml` with a digest from `agent-containers/digests.md`.
2. Replace `PROJECTNAME` in `project.env` with the project name (vault `agent-<project>`).
3. Make this project's `OP_SERVICE_ACCOUNT_TOKEN` available in your host shell: a per-project `direnv` `.envrc` kept outside the repo, or `op read` into the current shell at use time. Not a global shell-profile export, and never in the repo (see `docs/runbooks/1password-project-vault.md`).
4. Replace `@OWNER` in `.github/CODEOWNERS` with your GitHub username.
5. Ensure `~/GitHub/spades.ai` (or `$SPADES_AI_DIR`) exists on the host.
6. Create the project allowlist **on the host, outside the repo**: `cp allowlist.txt ~/.config/agent-containers/<project>.allowlist`, then edit that copy (see "Project allowlist" below). `./up` and VS Code stop if it is missing.
7. `pre-commit install` once per clone (gitleaks).

## Lifecycle

| Action | Command | Effect |
|---|---|---|
| New project | Copy this folder into the project root; create 1Password vault `agent-<project>` + its service account + a scoped GitHub token (`github-agent/token`); set the digest (`./check-digest`); `./up` | Container `<project>-agent-1` running |
| Change a secret | Edit it in 1Password, then `./up` | Env is fixed at container creation, so the container must be recreated |
| Start / refresh secrets or env | `./up` | Resolves `op://` refs to `~/.config/agent-containers/<project>.env` (mode 600), recreates the container |
| Attach | `docker exec -it -u agent <project>-agent-1 zsh` or VS Code "Reopen in Container" | Shell in the container |
| Edit project allowlist | edit `~/.config/agent-containers/<project>.allowlist` on the host, then `./up` | Firewall re-initialised on start. Editing `allowlist.txt` in the repo does nothing |
| Update image | change the digest in `compose.yaml`, then `./up` | Claude config persists in volume `claude-<project>`; project R packages persist in volume `rlib-<project>` (no reinstall after `./up`) |
| Stop | `docker compose -p <project> stop` | Container stopped, volumes kept |
| Remove | `docker compose -p <project> down` | Container removed; named volumes kept |

### Project allowlist

The firewall reads the project's extra domains from `~/.config/agent-containers/<project>.allowlist` on the host,
mounted read-only into the container. It is kept out of the project folder on purpose: the project folder is the
agent's read-write workspace, so an allowlist there could be edited by the agent and would take effect at the next
start. The repo's `allowlist.txt` is only a seed for the first copy; edits to it have no effect.

- One domain per line; a domain also covers its subdomains; `#` comments allowed.
- Names that are not allowlisted do not resolve at all inside the container (DNS is answered only for allowlisted domains).
- **SSH to your own servers** (a cloud VM, a NAS) needs an allowlist entry too: port 22 is open only to allowlisted hosts,
  like 80 and 443, and only to an IP the container resolved from an allowlisted name, so connect by that name
  (`ssh me@nas.example.org`), not by a bare IP. GitHub SSH works out of the box.
- No ports other than 22, 80 and 443 are reachable, even on allowlisted hosts.

### VS Code and `OP_SERVICE_ACCOUNT_TOKEN`

"Reopen in Container" runs `./resolve-secrets` on the host with VS Code's own environment. A VS Code started from the
dock/Start menu may NOT inherit variables from your shell environment. Either launch it from a shell that has the token
(`code .`), or run `./up` in a terminal first and then attach. If the token is missing, `resolve-secrets` stops with a clear message.

### Project name

`./resolve-secrets` writes a gitignored `.env` (`PROJECT`, `COMPOSE_PROJECT_NAME`, lowercased to `[a-z0-9_-]`). Compose reads it
in both `./up` and VS Code, so both use the same compose project, env file and `claude-<project>` volume. This relies on the Dev
Containers tooling honouring `COMPOSE_PROJECT_NAME` from `.env` (otherwise it names the project `<folder>_devcontainer`);
if the container is named `<folder>_devcontainer-agent-1`, that assumption failed.

Volumes: `claude-<project>` (per project, survives rebuilds) and `require-cache-shared` (external, shared across projects).
