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
| Start / refresh secrets or env | `./up` | Resolves `op://` refs to `~/.config/agent-containers/<project>.env` (mode 600), recreates the container |
| Attach | `docker exec -it -u agent <project>-agent-1 zsh` or VS Code "Reopen in Container" | Shell in the container |
| Edit project allowlist | edit `allowlist.txt`, then `./up` | Firewall re-initialised on start |
| Update image | change the digest in `compose.yaml`, then `./up` | Claude config persists in volume `claude-<project>` |
| Stop | `docker compose -p <project> stop` | Container stopped, volumes kept |
| Remove | `docker compose -p <project> down` | Container removed; named volumes kept |

Volumes: `claude-<project>` (per project, survives rebuilds) and `require-cache-shared` (external, shared across projects).
