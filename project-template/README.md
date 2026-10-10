# Project template (seeds for `agent-up`)

This folder is **not copied into your project by hand.** `bin/agent-up init` uses it:

| Seed | Copied to | Who edits it |
|---|---|---|
| `config/compose.yaml`, `config/project.env`, `config/allowlist` (+ `config/allowlist.bio-example` for `--image bio`) | `~/.config/agent-containers/<project>/` | you, the owner. **Never mounted** into the container, except `allowlist` (read-only) and, with `T3_CONNECT=1` / `RSTUDIO=1`, the generated switches and RStudio password (read-only) |
| `repo/.github/CODEOWNERS`, `repo/.github/workflows/gitleaks.yml`, `repo/.gitignore` | the project folder (only where absent) | you; commit them |
| `config/compose.research.yaml` | `~/.config/agent-containers/research/compose.yaml` (`init --profile research`) | you |
| `instructions/research.md`, `instructions/builder-research.md` | `<config>/.generated/agent-instructions.md` at every `agent-up` run, mounted **read-only** as Claude's managed `CLAUDE.md` and Codex's `AGENTS.md` (research container; builders with `RESEARCH=1`) | change them here (PR) |

**Why outside the project:** the project folder is the agent's read-write workspace. Anything
there could be changed by the agent, so the host never executes or reads configuration from it
(spec §2.1, §4). For the same reason the project folder must be an agent-only clone, never your
agent-containers clone or a folder containing `~/.config/agent-containers`: `agent-up up` refuses those.

## Commands (run on the host, from your agent-containers clone)

Host: Linux or WSL2 (GNU coreutils).

| Command | Does |
|---|---|
| `bin/agent-up init <project-dir> [--image gis\|bio\|base]` | creates `~/.config/agent-containers/<project>/` and adds the repo files to the project |
| `bin/agent-up init --profile research` | creates the shared research container's config (`research`) and `~/agent-research/` (see "Research container") |
| `bin/agent-up up <project>` | checks the digest, the mounts and `project.env`, then `op run ... docker compose ... up -d --force-recreate` |
| `bin/agent-up config <project>` | prints the rendered compose config: exactly what will run (no secrets needed) |
| `bin/agent-up shell <project>` | `zsh` in the container as `agent` |
| `bin/agent-up pair <project>` | prints a one-time T3 Code pairing link (`http://localhost:<T3_PORT>/pair#token=…`, valid 10 min) |
| `bin/agent-up rstudio <project>` | prints the RStudio Server address, user and password (only with `RSTUDIO=1`) |
| `bin/agent-up status \| stop \| down <project>` | `down` removes the container; named volumes are kept |

`<project>` is the project folder name, lowercased to `[a-z0-9_-]` (or `--name` at init). The
container is `<project>-agent-1`.

## T3 Code

Each container runs a T3 Code server (`t3 serve`, pinned in the image, telemetry off) started by
`agent-entrypoint` after the firewall and `agent-init`.
- It is published on the HOST's loopback only: `127.0.0.1:<T3_PORT>` (from `project.conf`, unique
  per project; `init` picks the next free port from 3773). The firewall accepts container port 3773
  from the Docker gateway alone, so sibling containers and the network cannot reach it.
- First time: `agent-up pair <project>`, open the link in your browser (Windows reaches WSL's
  localhost). Each project gets its own origin, `http://<project>.localhost:<T3_PORT>` (underscores
  become hyphens), so browser sessions of different projects stay apart. The pairing persists in
  the `t3-<project>` volume.
- T3 drives the container's own Claude Code (your login, behind the firewall). Don't enable the
  desktop app's local environment or WSL integration: those run agents on the host, outside any sandbox.

**Upgrading a project created before T3** (its `compose.yaml` predates it):

```bash
CFG=~/.config/agent-containers/<project>
cp ~/GitHub/agent-containers/project-template/config/compose.yaml "$CFG/compose.yaml"
sed -i 's|/spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md|/spades-<image>@sha256:<digest>|' "$CFG/compose.yaml"
grep -h '^T3_PORT=' ~/.config/agent-containers/*/project.conf   # ports already taken
grep -q '^T3_PORT=' "$CFG/project.conf" || echo 'T3_PORT=3773' >> "$CFG/project.conf"   # a FREE one; `up` refuses a duplicate
agent-up up <project>
```

**Upgrading a project created before Codex** (its `compose.yaml` has no `codex-config` volume, so a
Codex login would be lost at every `agent-up up`). This keeps your `image:` line (digest) and
`project.conf` (`T3_PORT`) as they are:

```bash
CFG=~/.config/agent-containers/<project>
cp "$CFG/compose.yaml" "$CFG/compose.yaml.bak"
img=$(grep -m1 '^    image: ' "$CFG/compose.yaml.bak")          # your image + digest
cp ~/GitHub/agent-containers/project-template/config/compose.yaml "$CFG/compose.yaml"
sed -i "s|^    image: .*|$img|" "$CFG/compose.yaml"
diff "$CFG/compose.yaml.bak" "$CFG/compose.yaml"   # expect only the codex lines; re-apply any edits of your own
grep '^T3_PORT=' "$CFG/project.conf"                 # must print one line (else: the T3 upgrade above)
```

Then upgrade the image as usual (a digest from `digests.md` that includes Codex) and `agent-up up <project>`.

## T3 Connect (opt-in)

T3 Connect lets the T3 phone app, the desktop app and app.t3.codes reach this project's T3 server
from anywhere, with push notifications. It is two things: T3's relay (you sign in with a T3
account) and a Cloudflare Tunnel that the T3 server runs inside the container (`cloudflared`,
which T3 downloads from GitHub releases on first use and checks against a pinned sha256). It is
**off by default, per project** (decision 2026-10-09, spec §13.1).

What `T3_CONNECT=1` changes, and nothing else:
- the firewall allowlists `t3.codes` (relay and login: `app.`, `relay.`, `clerk.`) on ports 22/80/443
  like any entry;
- `argotunnel.com` (Cloudflare's tunnel edge) resolves, but its addresses go into a **separate**
  set that is open on **port 7844 only** (QUIC over UDP, HTTP2 over TCP). No other host gets 7844,
  and the edge gets no other port. IPv6 stays closed (`TUNNEL_EDGE_IP_VERSION=4` in the container);
- the relay's tracing host is **not** allowlisted: its traces are dropped.

The switch is yours, not the agent's: it lives in `project.conf` on your host, and `agent-up`
mounts it read-only into the container, where the root firewall reads it at start. The agent can
neither turn it on nor off (re-running the firewall reads the same mounted file).

**Enable** (the T3 login persists in the `t3-<project>` volume, so steps 3–4 are once only):

1. Add `T3_CONNECT=1` to `~/.config/agent-containers/<project>/project.conf` (it may already
   say `T3_CONNECT=0`: change that line).
2. `agent-up up <project>`. `docker logs <project>-agent-1` shows `T3 Connect: ON`.
3. `agent-up shell <project>`, then in the container:
   ```bash
   t3 connect --headless   # device-code login: open the printed link on your phone or host, enter the code
   t3 connect publish      # push notifications / Live Activities (off unless you enable them)
   ```
   If it offers to install a background service, decline: the container starts the server itself.
4. `agent-up up <project>` again: the server links at start (it downloads `cloudflared` into the
   volume the first time). Check with `t3 connect status` in the container.

**Phone / desktop:** sign in to T3 Connect with the same account and choose this project's
environment. For notifications: Settings → Notifications → **Device Notifications**. Activity
publishing must be on for the environment (`t3 connect publish` above); the matching switch in the
apps is *to be confirmed on first use*.

**Disable:** `t3 connect unlink` in the container (keeps the T3 login; `t3 connect logout` also
clears it), then `T3_CONNECT=0` in `project.conf` and `agent-up up <project>`. Unlink first:
without it, the server keeps trying to reach the relay, which the firewall now blocks.

**Upgrading an existing project:** nothing to do to keep it off (a `project.conf` without
`T3_CONNECT` means 0). To opt in, add the line `T3_CONNECT=1` to its `project.conf` and follow
the steps above; the image must be one that includes T3 Connect support (a digest from
`digests.md` dated after this change).

## Research container

One **shared** container, `research`, does the web research for every project (spec §2.1). It has
open internet (public IPv4, any port) and **nothing to lose**: no secrets, no GitHub token, no
project, spades.ai or memory mount. Builders stay behind their allowlists and exchange files with
it through `~/agent-research/<project>/` (`RESEARCH_DIR` in `project.conf`), where `<project>` is
the builder's exact project name:

| `~/agent-research/<project>/` | research container | builder with `RESEARCH=1` |
|---|---|---|
| `briefs/` | `/research/<project>/briefs` **read-only** | `/research/briefs` read-write |
| `reports/` | `/research/<project>/reports` read-write | `/research/reports` **read-only** |
| `downloads/` | `/research/<project>/downloads` read-write | `/research/downloads` **read-only** |

**Set up** (once; no 1Password vault, no service account):

```bash
agent-up init --profile research          # ~/.config/agent-containers/research/ + ~/agent-research/
# set the spades-gis digest from digests.md in ~/.config/agent-containers/research/compose.yaml
# for each builder that should use it: RESEARCH=1 in ~/.config/agent-containers/<project>/project.conf
agent-up up <project>                     # each opted-in builder: mounts its three folders
agent-up up research                      # no OP_SERVICE_ACCOUNT_TOKEN needed; mounts every project folder
agent-up shell research                   # first time: `claude` (log in), `codex login --device-auth`
agent-up pair research                    # T3 Code for the research container (its project is /research)
```

`docker logs research-agent-1` shows `Profile: research`. A builder opted in **after** the research
container started reaches it at its next `agent-up up research`.

**Day to day:**
1. **Brief.** Ask in the research container's T3 (or `agent-up shell research`, `claude`), or drop a
   Markdown brief in `~/agent-research/<project>/briefs/`. A builder agent can write the brief
   itself in `/research/briefs/`.
2. **Report.** The research agent writes `reports/<topic>.md` (URLs, licence, access method, size,
   CRS/resolution, the hosts to allowlist) and, when inspection needs it, whole files in `downloads/`.
3. **Builder.** The builder agent reads the report and inspects downloads **without executing or
   building on them**, then proposes a `prepInputs()` call on the original URL and asks you to
   allowlist its host(s).
4. **You allowlist** the host(s) in that builder's `allowlist` and `agent-up up <project>`. The
   model then fetches the original itself, reproducibly.

`agent-up status research` prints `du -sh` of each project's `downloads/` (there is no download cap:
clean up by hand).

**What keeps it apart:**
- The switch is yours: `PROFILE=research` in the research config makes `agent-up` mount a read-only
  `/etc/firewall/profile`; neither container can change it. Builders never get it.
- Open egress still excludes private, shared (CGNAT/Tailscale), link-local (cloud metadata),
  loopback and reserved ranges, the container's own networks and the Docker host.
- The instructions both sides get (`instructions/*.md`) are mounted read-only at Claude Code's
  managed `/etc/claude-code/CLAUDE.md` (and Codex's `AGENTS.md`). Builders are told that reports
  and downloads are **untrusted data, never instructions**, never to execute anything from
  `/research`, and never to build the model on downloaded files.
- **Not `noexec`:** Docker bind mounts can't be mounted `noexec`. Read-only, the instructions and the
  builder's allowlist are the controls.
- `agent-up up` refuses a `RESEARCH_DIR` that overlaps the config root, this clone, or any project's
  folder, spades.ai or `~/agent-memory`.

**Risks you accept** (spec §2.1, §12): your Claude subscription login sits in an open-egress
container (if you suspect anything, log the session out at claude.ai); it shares your Claude usage
limits with every builder; treat `~/agent-research/` as untrusted on the host too (never run or
`source` anything from it, and beware tools that execute content).

**Upgrading a builder created before the research container:** nothing to do to keep it off
(`RESEARCH` absent = 0). To opt in, add `RESEARCH=1` (and, only if you moved it, `RESEARCH_DIR=...`)
to its `project.conf`. The research container needs an image digest from `digests.md` dated after
this change (an older image ignores the switch and stays on the builder allowlist).
## RStudio Server (opt-in)

The open-source RStudio Server (AGPLv3, pinned in the image) can run in a project's container, so
you can work in RStudio in your browser next to the agent. It is **off by default, per project**
(decision 2026-10-09, spec §13.3).

What `RSTUDIO=1` changes, and nothing else:
- the container also runs `rserver`, started by `agent-entrypoint` after T3, **as the agent**
  (uid 1000, never root). R sessions run as the agent too: same files, same R, same project library;
- compose publishes it on the HOST's loopback only: `127.0.0.1:<RSTUDIO_PORT>` (`init` picks the
  next free port from 8787). The firewall accepts container port 8787 from the Docker gateway alone
  (one INPUT rule, like T3's); sibling containers and the network cannot reach it. No egress change:
  nothing new is allowlisted;
- sign-in is required: user `agent` and a random per-project password that `agent-up` writes to
  `~/.config/agent-containers/<project>/.generated/rstudio-password` (mode 600) and mounts
  read-only. It is never an environment variable. Delete the file and `agent-up up` to rotate it;
- RStudio's own state (open files, history, preferences, its logs) lives in the
  `rstudio-<project>` volume.

**Enable:**

1. In `~/.config/agent-containers/<project>/project.conf` set `RSTUDIO=1` (it may say
   `RSTUDIO=0`: change that line). `RSTUDIO_PORT` must be set too (`init` writes it).
2. `agent-up up <project>`. `docker logs <project>-agent-1` shows `RStudio Server: ON` and
   `[agent-rstudio] server up`.
3. `agent-up rstudio <project>`: open the printed `http://rstudio-<project>.localhost:<RSTUDIO_PORT>`
   (underscores become hyphens) and sign in as `agent` with the printed password. The per-project
   host is required: RStudio's sign-in cookies are per host, not per port, so two projects (or T3)
   on `localhost` would sign each other out.

**Working alongside the agent:**
- The first R session opens the project's `.Rproj` (when `/workspace` has exactly one), so R starts in
  `/workspace` and sources its `.Rprofile`: the setupProject library is active, as in the agent's
  shell. Sessions never suspend (a resumed session could skip `.Rprofile`).
- R in RStudio gets the same environment as R in the agent's shell (including `GH_TOKEN` and the
  other `project.env` secrets), minus anything `OP_*`.
- **Don't run `setupProject()` (or install packages) from RStudio while the agent is installing
  into the same library**, and vice versa: two installers in one library corrupt it. Take turns.
- RStudio cannot attach to an R process the agent started (`Rscript`, a tmux run). Follow those
  through their outputs and logs (Files pane, or a terminal in RStudio: `tail -f`).
- Copilot and Posit Assistant are off in `rsession.conf` (and nothing of theirs is allowlisted).

**Disable:** `RSTUDIO=0` in `project.conf`, then `agent-up up <project>`. The port, the firewall
rule and the server are gone; the password file and the `rstudio-<project>` volume are kept for
next time.

**Upgrading an existing project:** nothing to do to keep it off (no `RSTUDIO` line means 0). To opt
in, add both lines to its `project.conf`, with a port no other project uses
(`grep -h '_PORT=' ~/.config/agent-containers/*/project.conf` lists the taken ones):
```bash
printf 'RSTUDIO=1\nRSTUDIO_PORT=8787\n' >> ~/.config/agent-containers/<project>/project.conf
```
The image must include RStudio Server (a digest from `digests.md` dated after this change).
`agent-up up` refuses a port that is taken.

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
| `/etc/firewall/t3-connect` (only with `T3_CONNECT=1`) | `~/.config/agent-containers/<project>/.generated/t3-connect`, written by `agent-up` from `project.conf` | **ro** |
| `/research/briefs` (only with `RESEARCH=1`) | `RESEARCH_DIR/<project>/briefs` | rw |
| `/research/reports`, `/research/downloads` (only with `RESEARCH=1`) | `RESEARCH_DIR/<project>/reports`, `.../downloads`: written by the research container | **ro** (untrusted) |
| `/etc/claude-code/CLAUDE.md`, `~/.codex/AGENTS.md` (only with `RESEARCH=1`) | `.generated/agent-instructions.md`, from `instructions/builder-research.md` | **ro** |
| `/etc/firewall/rstudio`, `/run/secrets/rstudio-password` (only with `RSTUDIO=1`) | `~/.config/agent-containers/<project>/.generated/rstudio{,-password}`, written by `agent-up` | **ro** |
| `~/.local/share/rstudio` (only with `RSTUDIO=1`) | volume `rstudio-<project>` | persists across `up` |
| `~/.claude`, `~/.codex`, the project R library | volumes `claude-<project>`, `codex-<project>`, `rlib-<project>` | persist across `up` |
| Require's cache | volume `require-cache-shared` | shared by all projects |
| npm's download cache (Claude Code and Codex install from it at each start, pinned + integrity-checked) | volume `npm-cache-shared` | shared by all projects |

**Agent CLIs:** `claude` (Claude Code) and `codex` (OpenAI Codex CLI), each pinned by a lockfile in
`images/base/agent-clis/<tool>/` and installed at container start (`agent-up status` prints both
versions). First time in a project: `claude` (log in with your subscription) and
`codex login --device-auth` (ChatGPT plan: open the printed link on the host, enter the code).
Both logins live in the project's volumes.

Secrets: each `KEY=op://...` line in `project.env` becomes an environment variable in the
container. `op run` resolves the values on the host when you run `agent-up up`; they are never
written to disk.

## Settings worth knowing

- **`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"`** in `compose.yaml` turns off Claude Code's
  telemetry, error reports, auto-updates, `/feedback`, artifacts and Remote Control in the
  container. **Any value disables it, even `"0"`.** To re-enable, delete the line.
- **Codex `~/.codex/config.toml`**: at every start `agent-init` enforces `approval_policy = "never"`,
  `sandbox_mode = "danger-full-access"` (the container is the sandbox, as for Claude's
  `bypassPermissions`), `check_for_update_on_startup = false` and `[analytics] enabled = false`.
  Your other keys are kept. `chatgpt.com` and `openai.com` are in the base allowlist (login, model
  backend); analytics would go to chatgpt.com too, so the config switch is what turns it off.
- **`mem_limit`**: stated explicitly. Memory gates inside the container must read
  `/sys/fs/cgroup/memory.max`, not `/proc/meminfo`.
- **Reserved for Phase 2 (T3 Code):** the commented `t3` volume and `127.0.0.1:3773` port.

## Working in the agent's folders from the host

The agent can write three folders: the project folder, spades.ai and `~/agent-memory` (plus, with
the research container, `~/agent-research/`: its reports and downloads come from the open internet).

**Recommended:** run git and R inside the container (attached VS Code or `agent-up shell`).

On the host, treat all of them as untrusted:

- Host git honours the folder's `.git/config` and hooks, which the agent can write. If you do use
  host git there, run `git -c core.hooksPath=/dev/null -c core.fsmonitor=false ...`.
- Never put a direnv `.envrc` in any of them (direnv runs it in your shell).
- Beware git-aware shell prompts: they run git in the current directory.
- A host-side Claude Code session that imports spades.ai is reading agent-writable text.

## Known residual risks

The firewall confines the agent to allowlisted names on ports 22, 80 and 443 (plus 7844 to
Cloudflare's tunnel edge only, where T3 Connect is on), and to DNS for allowlisted names only. It does not remove these risks:

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
- **T3 Connect, where enabled (`T3_CONNECT=1`):**
  - each enabled project has a **public tunnel hostname**. Access is gated by T3's
    authentication, but the endpoint itself is on the internet;
  - you trust **T3's relay**. Its own docs say a compromised relay signing key could mint
    sessions, i.e. drive that project's agents;
  - your **T3 account must have 2FA**: it is now a way into the container.
  The blast radius is that project's agent capabilities (its workspace, its tier-A secrets, its
  allowlist), not the host or other projects.
- **RStudio Server, where enabled (`RSTUDIO=1`):** it runs as the agent, so the password protects it
  from other local users and browser pages, **not from the agent**: the agent can read the password
  file and could replace the server on port 8787 with its own. Treat what you see there as you treat
  the agent's files. It is reachable only from your host's loopback.
- **Tier-A secrets are readable inside the container**, and visible to anyone on the host who can
  run `docker inspect`. Keep them scoped and short-lived (spec §5).
- **First real `agent-up up` on WSL2 / Docker Desktop:** check the firewall log
  (`docker logs <project>-agent-1`).
  - The firewall needs the kernel's `xt_owner` match and conntrack netlink (`conntrack -F`). If
    either is missing it fails CLOSED and the container does not finish starting.
  - Also check VS Code extension downloads: `*.gallerycdn.vsassets.io` may need to be allowlisted.
