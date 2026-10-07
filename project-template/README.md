# Project template (seeds for `agent-up`)

This folder is **not copied into your project by hand.** `bin/agent-up init` uses it:

| Seed | Copied to | Who edits it |
|---|---|---|
| `config/compose.yaml`, `config/project.env`, `config/allowlist` (+ `config/allowlist.bio-example` for `--image bio`) | `~/.config/agent-containers/<project>/` | you, the owner. **Never mounted** into the container, except `allowlist` (read-only) |
| `repo/.github/CODEOWNERS`, `repo/.github/workflows/gitleaks.yml`, `repo/.gitignore` | the project folder (only where absent) | you; commit them |

**Why outside the project:** the project folder is the agent's read-write workspace. Anything
there could be changed by the agent, so the host never executes or reads configuration from it
(spec §2.1, §4). For the same reason the project folder must be an agent-only clone, never your
agent-containers clone or a folder containing `~/.config/agent-containers`: `agent-up up` refuses those.

## Commands (run on the host, from your agent-containers clone)

Host: Linux or WSL2 (GNU coreutils).

| Command | Does |
|---|---|
| `bin/agent-up init <project-dir> [--image gis\|bio\|base]` | creates `~/.config/agent-containers/<project>/` and adds the repo files to the project |
| `bin/agent-up up <project>` | checks the digest, the mounts and `project.env`, then `op run ... docker compose ... up -d --force-recreate` |
| `bin/agent-up config <project>` | prints the rendered compose config: exactly what will run (no secrets needed) |
| `bin/agent-up shell <project>` | `zsh` in the container as `agent` |
| `bin/agent-up status \| stop \| down <project>` | `down` removes the container; named volumes are kept |

`<project>` is the project folder name, lowercased to `[a-z0-9_-]` (or `--name` at init). The
container is `<project>-agent-1`.

## Lifecycle

| Action | Steps |
|---|---|
| New project | [docs/runbooks/new-project.md](../docs/runbooks/new-project.md) |
| Upgrade the image | put a new digest from `digests.md` in `~/.config/agent-containers/<project>/compose.yaml`; `agent-up up <project>` |
| Change the allowlist | edit `~/.config/agent-containers/<project>/allowlist`; `agent-up up <project>` |
| Change a secret | edit it in 1Password; `agent-up up <project>` (the env is fixed at container creation) |
| Attach | VS Code → **Dev Containers: Attach to Running Container…** → `<project>-agent-1`, or `agent-up shell <project>` |

## What the container gets (builder profile)

| In the container | From the host | Mode |
|---|---|---|
| `/workspace` | the project folder (`PROJECT_DIR` in `project.conf`) | rw |
| `/opt/reference/spades.ai` | `SPADES_AI_DIR` (default `~/GitHub/spades.ai`) | rw |
| `/opt/memory` | `AGENT_MEMORY_DIR` (default `~/agent-memory`, a git repo) | rw |
| `/etc/firewall/allowlist.d/50-project.txt` | `~/.config/agent-containers/<project>/allowlist` | **ro** |
| `~/.claude`, the project R library | volumes `claude-<project>`, `rlib-<project>` | persist across `up` |
| Require's cache | volume `require-cache-shared` | shared by all projects |
| Claude Code (installed at first start, pinned + integrity-checked) | volume `claude-code-shared` | shared by all projects |

Secrets: each `KEY=op://...` line in `project.env` becomes an environment variable in the
container. `op run` resolves the values on the host when you run `agent-up up`; they are never
written to disk.

## Settings worth knowing

- **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"`** in `compose.yaml` turns off Claude Code's
  telemetry, error reports, auto-updates, `/feedback`, artifacts and Remote Control in the
  container. **Any value disables it, even `"0"`.** To re-enable, delete the line.
- **`mem_limit`**: stated explicitly. Memory gates inside the container must read
  `/sys/fs/cgroup/memory.max`, not `/proc/meminfo`.
- **Reserved for Phase 2 (T3 Code):** the commented `t3` volume and `127.0.0.1:3773` port.

## Working in the agent's folders from the host

The agent can write three folders: the project folder, spades.ai and `~/agent-memory`.

**Recommended:** run git and R inside the container (attached VS Code or `agent-up shell`).

On the host, treat all three as untrusted:

- Host git honours the folder's `.git/config` and hooks, which the agent can write. If you do use
  host git there, run `git -c core.hooksPath=/dev/null -c core.fsmonitor=false ...`.
- Never put a direnv `.envrc` in any of them (direnv runs it in your shell).
- Beware git-aware shell prompts: they run git in the current directory.
- A host-side Claude Code session that imports spades.ai is reading agent-writable text.

## Known residual risks

The firewall confines the agent to allowlisted names on ports 22, 80 and 443, and to DNS for
allowlisted names only. It does not remove these risks:

- Read-write shared mounts (spades.ai, ~/agent-memory, the Require cache) are writable by every builder project: a compromised builder could affect the others (accepted for builders, spec §2.1).
- **Upload-capable allowlisted domains.** Anything that accepts uploads, with credentials the agent
  could be handed, is an exfiltration path: github.com with a foreign token, S3, Google Drive or
  googleapis, Zenodo, PyPI. A bucket-style entry such as `s3-us-west-2.amazonaws.com` covers every
  bucket under it. List the narrowest names you can.
- **Shared CDN IPs.** An allowed IP stays allowed, and CDN edge IPs serve many other sites. A
  connection to an allowed IP with a different Host/SNI can reach another site on the same CDN.
- **DNS tunnelling through allowlisted domains** whose zones are delegated to users (dynamic-DNS
  providers, some hosting platforms). Review project allowlists with that in mind.
- **The pre-firewall window at container start.** The container has open networking until
  `init-firewall.sh` applies its DROP policies. Nothing of the agent's runs yet, and
  `conntrack -F` kills any flow opened before.
- **Tier-A secrets are readable inside the container**, and visible to anyone on the host who can
  run `docker inspect`. Keep them scoped and short-lived (spec §5).
- **First real `agent-up up` on WSL2 / Docker Desktop:** check the firewall log
  (`docker logs <project>-agent-1`).
  - The firewall needs the kernel's `xt_owner` match and conntrack netlink (`conntrack -F`). If
    either is missing it fails CLOSED and the container does not finish starting.
  - Also check VS Code extension downloads: `*.gallerycdn.vsassets.io` may need to be allowlisted.
