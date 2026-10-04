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
7. `pre-commit install` once per clone (gitleaks). This writes `.git/hooks/pre-commit`, which the launcher checksum covers, so do it before step 8.
8. **Adopt the launcher:** review `compose.yaml`, `up`, `resolve-secrets`, `check-digest`, `project.env`, `.pre-commit-config.yaml`, `.devcontainer/` and any `.git/hooks/*` (for example `diff -r` against `agent-containers/project-template`), then run `./up --adopt`. It records their hashes in `~/.config/agent-containers/<project>.launcher.sha256` and starts the container. Without adoption, `./up` and VS Code refuse to start.

## Lifecycle

| Action | Command | Effect |
|---|---|---|
| New project | Copy this folder into the project root; create 1Password vault `agent-<project>` + its service account + a scoped GitHub token (`github-agent/token`); set the digest (`./check-digest`); create the host allowlist; review the launcher files, then `./up --adopt` | Container `<project>-agent-1` running |
| Change a secret | Edit it in 1Password, then `./up` | Env is fixed at container creation, so the container must be recreated |
| Start / refresh secrets or env | `./up` | Resolves `op://` refs to `~/.config/agent-containers/<project>.env` (mode 600), recreates the container |
| Attach | `docker exec -it -u agent <project>-agent-1 zsh` or VS Code "Reopen in Container" | Shell in the container |
| Edit project allowlist | edit `~/.config/agent-containers/<project>.allowlist` on the host, then `./up` | Firewall re-initialised on start. Editing `allowlist.txt` in the repo does nothing |
| Update image | change the digest in `compose.yaml`, then `./up --adopt` (any launcher edit needs re-adoption) | Claude config persists in volume `claude-<project>`; project R packages persist in volume `rlib-<project>` (no reinstall after `./up`) |
| Intended edit to a launcher file | review the diff, then `./up --adopt` | Re-records the hashes. `./up` refuses ANY unadopted change to `compose.yaml`, `up`, `resolve-secrets`, `check-digest`, `project.env`, `.pre-commit-config.yaml`, `.devcontainer/` or a `.git/hooks/*` file |
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

### Host-side safety: this folder is the agent's workspace

The agent has read-write access to this folder, and the host reads or runs files from it. So:

- **Read-only overlays.** Inside the container, `compose.yaml`, `up`, `resolve-secrets`, `check-digest`, `project.env`,
  `.env`, `.pre-commit-config.yaml`, `.devcontainer/` and `.git/hooks/` are mounted read-only over the workspace. The agent
  cannot edit, rename or delete them.
- **Launcher checksum.** `./up` and VS Code (through `./resolve-secrets`) verify those files, plus any non-sample
  `.git/hooks/*`, against the hashes you adopted, before anything else from the folder runs. On a mismatch they refuse and
  name the changed files: review the change (`git diff`, `git log`) and run `./up --adopt` only if it is intended. This
  catches edits made before the overlay existed or from outside the container. It cannot protect you if you run a
  tampered `up` on purpose, so review before adopting.
- **`.env` holds only `PROJECT` and `COMPOSE_PROJECT_NAME`.** It is rewritten from scratch on every run; any other key
  (such as `SPADES_AI_DIR` or `COMPOSE_FILE`), or a symlinked `.env` or `.env.tmp`, makes `./up` refuse. Put personal
  compose settings (`SPADES_AI_DIR`, ...) in your shell environment instead. `./up` always uses `-f compose.yaml` and
  ignores `COMPOSE_FILE`, `COMPOSE_PROFILES` and `COMPOSE_PATH_SEPARATOR`.
- **Git on the host.** `./up` refuses if `.git/config` sets a key that makes git run a program (`core.fsmonitor`,
  `core.hooksPath`, `core.sshCommand`, pagers/editors, filters, diff/merge drivers, credential helpers, `include.path`,
  aliases, ...) or if `.git/hooks/` has a non-sample hook you did not adopt, or if a root `.devcontainer.json` exists. The
  agent can still change `.git/config` while it runs, so when you run git on the host in this folder, disable both
  hooks and fsmonitor:

  ```bash
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false status
  ```

- **Do not open this folder locally in VS Code with workspace trust.** `.vscode/tasks.json` (`runOn: folderOpen`) and
  workspace settings run on the host when the folder is trusted. Use "Reopen in Container", or open it in Restricted Mode.
- **`.pre-commit-config.yaml` is your choice.** It runs on your host at commit time, so changes to it need review and
  re-adoption, like the other launcher files.

### Known residual risks

The firewall confines the agent to allowlisted names on ports 22, 80 and 443, and to DNS for allowlisted names only.
It does not remove these risks:

- **Upload-capable allowlisted domains.** Anything that accepts uploads with credentials the agent could be handed is an
  exfiltration path: github.com with a foreign token, S3 (a bucket-style entry such as `s3-us-west-2.amazonaws.com` covers
  every bucket under it), Google Drive / googleapis, Zenodo, PyPI. List the narrowest names you can.
- **Shared CDN IPs.** An allowed IP stays allowed, and CDN edge IPs serve many other sites, so a connection to an allowed IP
  with a different Host/SNI can reach another site on the same CDN.
- **DNS tunnelling through allowlisted domains** whose zones are delegated to users (dynamic-DNS providers, some
  hosting platforms). Review project allowlists with that in mind.
- **The pre-firewall window at container start.** The container has open networking until `init-firewall.sh` applies
  its DROP policies; nothing of the agent's runs yet, and `conntrack -F` kills any flow opened before.
- **SSH only to allowlisted hostnames.** There is no `ssh` client in the base image (git uses HTTPS via `gh`); if you
  add one, it reaches only hosts resolved from allowlisted names.
- **First real `./up` on WSL2 / Docker Desktop:** check the firewall log. It needs the kernel's `xt_owner` match and
  conntrack netlink (`conntrack -F`); if either is missing it fails CLOSED and the container does not finish starting.
  Also check VS Code extension downloads (`*.gallerycdn.vsassets.io` may need to be allowlisted).

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
