# Project template

Copy this folder into a SpaDES project root. The folder name becomes the compose project name (`PROJECT`).

**Never run plain `docker compose up`: use `./up`, so secrets are current.**

## Setup

1. Replace `REPLACE_WITH_DIGEST_FROM_digests.md` in `compose.yaml` with a digest from `agent-containers/digests.md`.
2. Replace `PROJECTNAME` in `project.env` with the project name (vault `agent-<project>`).
3. Put this project's `OP_SERVICE_ACCOUNT_TOKEN` in your host environment (never in the repo).
4. Ensure `~/GitHub/spades.ai` (or `$SPADES_AI_DIR`) exists on the host.
5. `pre-commit install` once per clone (gitleaks).

## Lifecycle

| Action | Command | Effect |
|---|---|---|
| New project | Copy this folder into the project root; create 1Password vault `agent-<project>` + its service account + a scoped GitHub token (`github-agent/token`); set the digest (`./check-digest`); `./up` | Container `<project>-agent-1` running |
| Change a secret | Edit it in 1Password, then `./up` | Env is fixed at container creation, so the container must be recreated |
| Start / refresh secrets or env | `./up` | Resolves `op://` refs to `~/.config/agent-containers/<project>.env` (mode 600), recreates the container |
| Attach | `docker exec -it -u agent <project>-agent-1 zsh` or VS Code "Reopen in Container" | Shell in the container |
| Edit project allowlist | edit `allowlist.txt`, then `./up` | Firewall re-initialised on start |
| Update image | change the digest in `compose.yaml`, then `./up` | Claude config persists in volume `claude-<project>` |
| Stop | `docker compose -p <project> stop` | Container stopped, volumes kept |
| Remove | `docker compose -p <project> down` | Container removed; named volumes kept |

### VS Code and `OP_SERVICE_ACCOUNT_TOKEN`

"Reopen in Container" runs `./resolve-secrets` on the host with VS Code's own environment. A VS Code started from the
dock/Start menu may NOT inherit variables from your shell profile. Either launch it from a shell that has the token
(`code .`), or run `./up` in a terminal first and then attach. If the token is missing, `resolve-secrets` stops with a clear message.

### Project name

`./resolve-secrets` writes a gitignored `.env` (`PROJECT`, `COMPOSE_PROJECT_NAME`, lowercased to `[a-z0-9_-]`). Compose reads it
in both `./up` and VS Code, so both use the same compose project, env file and `claude-<project>` volume. This relies on the Dev
Containers tooling honouring `COMPOSE_PROJECT_NAME` from `.env` (otherwise it names the project `<folder>_devcontainer`);
if the container is named `<folder>_devcontainer-agent-1`, that assumption failed.

Volumes: `claude-<project>` (per project, survives rebuilds) and `require-cache-shared` (external, shared across projects).
