# agent-containers — design spec

**Status:** draft for review · **Date:** 2026-10-03 · **Amended:** 2026-10-06 (draft, for review) ·
**Owner:** Allen Larocque

> **2026-10-06 amendment, in brief.** The opus re-review of PR #3 showed that a launcher living
> *inside* the agent's writable folder can't be made safe. This amendment:
> - adds an explicit threat model with two agent profiles (§2.1);
> - moves everything that defines the sandbox out of the project folder into the owner's config
>   directory, run by an external launcher, `agent-up` (§4);
> - sets the build order **containers → T3 Code orchestrator → memory**, with the seams Phase 1
>   must leave for the later phases (§13).
>
> Docker Sandboxes (`sbx`) was evaluated and put **on hold**: proprietary, mandatory login,
> telemetry on by default. See `docs/spikes/2026-10-05-docker-sandboxes-spike.md` on branch
> `spike/docker-sandboxes`.
**Needed by:** the week of 2026-10-05 (new GIS / predictive-modelling / fire-modelling SpaDES
project; transition to team work).

## 1. Purpose

Replace the single, hand-maintained `spades-dev-environment` devcontainer with a small system
that makes it **easy to start, upgrade and reproduce** containers for AI-assisted SpaDES work
across several projects, while keeping each project **compartmentalised** (its own secrets,
firewall allowlist and agent identity).

### Lessons this design answers (from the spades_bioinformatics campaign, Aug–Oct 2026)

| Lesson | Answer here |
|---|---|
| A rebuild wiped `$HOME` (R library, `gh` auth, agent notes) four times | fixed-name named volumes per project (§4) |
| Changing the firewall needed a rebuild, and there's no sudo inside | allowlist file per project, applied at container start (§4) |
| A floating dependency (`reproducible`) changed behaviour after a rebuild | everything pinned: image digests, Claude Code version, plugin commits, R package snapshots (§7) |
| The user's full GitHub token was passed into the container (`GH_PAT_FROM_HOST`) | per-project scoped agent token from 1Password; the user's own credentials never enter (§5) |
| An agent acting as the repo admin could merge anything | agents propose, humans merge: protected `main` + a separate agent identity (§6) |
| `run-amplicons.R` couldn't run detached: no tmux | tmux in base (§3) |
| The Python env for reticulate: Require doesn't manage it, and reticulate's default silently binds a bare Python | Python envs are baked or pinned explicitly; modules state the interpreter (§3.4) |
| `renv` and `Require` both take over `.libPaths()`/`.Rprofile` | **no renv**; SpaDES projects use `setupProject`/`Require` only (§3.1) |

## 2. Scope (amended 2026-10-06)

Built in this order. Each phase must work before the next starts:

| Phase | Delivers | Status |
|---|---|---|
| **1 — Containers** | images, external launcher + per-project config, firewall, secrets, agent GitHub identity, CI, skills/reference layer (hooks shipped *disabled*); the **builder** profile | images/firewall/CI done on `feat/phase1`; launcher being reworked (§4) |
| **1b — Research profile** | the second profile (§2.1), built on the same images | designed here; built after the builder profile works |
| **2 — Orchestrator** | T3 Code driving agents that run *inside* the containers (§13.1) | seams reserved in Phase 1 |
| **3 — Memory** | per-project + shared memory, handoffs between projects (§13.2) | seams reserved in Phase 1 |

**Other seams left for later (designed in, not built):**
- **Hooks:** to be reviewed and taught before any are enabled (§8).
- **Cloud:** the same images run on the enterprise cloud machine (>100 GB RAM).
- **Memory gates reading the cgroup limit:** handled with the memory-gate and benchmarking work in
  the pipeline repos, not here (§4).
- **Stronger isolation:** gVisor (`runsc`) as the container runtime, and/or microVMs
  (microsandbox, Apache-2.0, once out of beta), mainly for the research profile.
- **Token never visible to the agent:** Claude Code's sandbox credential `mask` inside the
  container, so a scoped token is *used* but never *readable* (threat 3).

**Non-goals:** voice/mobile, Obsidian integration, the NAS services, proprietary sandbox runtimes
(`sbx`: on hold, see above).

### 2.1 Threat model and agent profiles (added 2026-10-06)

| # | Threat | Priority |
|---|---|---|
| 1 | **Accidents:** the agent deletes or overwrites things, burns compute, or "fixes" its own sandbox to get unblocked | **all agents** |
| 3 | **Credential theft:** tokens or secrets leave the box | **all agents** |
| 2 | **Prompt injection** from untrusted inputs (web pages, downloaded data, packages, READMEs) steering the agent | research agents |
| 4 | **Cross-project contamination:** one project's compromise spreading to others | research agents |

**Design rule:** *nothing the agent can write is ever executed or interpreted by the host.* This
covers threat 1 as well as attacks. Agents work around blockers (see the setup-workarounds
history), and an agent widening its own allowlist to get unblocked is threat 1 turning into
threat 3.

**Two profiles:**

| | **Builder** (project work: R, pipelines, PRs) | **Research** (open internet; Phase 1b) |
|---|---|---|
| Egress | firewall allowlist (base + project) | open on 80/443 |
| Secrets | tier A (scoped, revocable; §5) | **none**: no GitHub token, no data keys |
| Project folder | read-write at `/workspace` | **not mounted** |
| spades.ai | read-write | not mounted |
| Shared memory (§13.2) | read-write | not mounted |
| Input / output | the project itself | a **task brief** (ro) in; a **quarantine outbox** (rw) out, read by the user or a builder as *untrusted* |
| Shared caches (Require, uv) | shared, read-write | own, not shared |

The research profile follows the "lethal trifecta" rule: an agent that reads untrusted content
and can send data anywhere must not also hold private data or credentials.

**Accepted for builders:**
- content from allowlisted hosts (GitHub issues, READMEs, package docs) is untrusted and still
  read;
- read-write shared mounts (spades.ai, memory, Require cache) mean a compromised builder could
  affect other projects;
- tier-A values are readable inside the container until credential masking lands.

Revisit if builders start consuming untrusted content heavily.

## 3. Images

Built in this repo, published publicly to GHCR (`ghcr.io/allenlarocque/spades-{base,gis,bio}`).
They contain no secrets by design.

### 3.1 `spades-base`
- `FROM rocker/r-ver:4.5.3@sha256:<digest>`, pinned by digest.
- **User:** a non-root user with a **fixed UID/GID 1000** matching the WSL user, so bind-mounted
  files have consistent ownership. Remember `docker exec -u <user>`, since exec defaults to root.
- **OS tooling** (carried over from the current image): git, gh, zsh, fzf, jq, less, procps,
  curl/wget, vim/nano, unzip, man-db, dnsutils, iproute2, iptables, ipset, dnsmasq, aggregate.
  **New:** `tmux`, `libimage-exiftool-perl` (exiftool).
- **Node 22** (NodeSource) + **Claude Code pinned to an exact version** (build arg; never
  `latest`). There's room for other agent CLIs later.
- **The firewall script** (Anthropic reference-devcontainer pattern), extended to read
  `/etc/firewall/allowlist.d/*.txt` (§4).
- **R bootstrap only:** `Require` and `SpaDES.project` in the site library, enough to
  bootstrap `setupProject()`. **Nothing else** (no SpaDES.core/terra/sf): projects use
  `setupProject(standAlone = TRUE)`, which hides the site library anyway, and preinstalled copies
  caused "which copy got loaded" confusion.
- **Geospatial system libraries in base** (`libgdal-dev`, `gdal-bin`, `libgeos-dev`,
  `libproj-dev`, `libudunits2-dev`, `libsqlite3-dev`): every SpaDES module depends on `terra`.
  ⚠️ **Use Ubuntu's own GDAL, never the ubuntugis PPA:** the P3M binary R packages are built
  against Ubuntu's libraries, and mixing breaks them.
- **Common build libraries:** libcurl/SSL/XML2, fontconfig/harfbuzz/fribidi/freetype,
  png/tiff/jpeg, cmake.
- **`uv`** (pinned version) for light Python tooling and reticulate's `py_require()`.

### 3.2 `spades-gis` (FROM base)
- `libnetcdf-dev`, `netcdf-bin`, `libhdf5-dev`, and the GDAL CLI (already in base). Nothing else:
  R-only, R-based fire models (fireSense/SCFM need nothing beyond `setupProject`), no Python
  geospatial, no GRASS/SAGA/Whitebox, no Java. Add later by rebuilding this layer.

### 3.3 `spades-bio` (FROM base)
- cutadapt, fasttree, mafft, `libglpk-dev`, `libmagick++-dev`.
- Miniforge at `/opt/conda` with pinned envs: `picrust2` (2.5.2, bioconda) and `sklearn`
  (Python 3.12, scikit-learn 1.9.0, joblib, numpy, scipy, biopython).

### 3.4 Python for reticulate (policy)
`Require` manages R packages only. Python environments are either:
1. **baked** into the domain image with exact versions (heavy/stable; e.g. `sklearn` in `bio`); or
2. **declared in module code** with `reticulate::py_require()` and **exact pins**, with a shared
   `uv` cache volume, and PyPI plus the python-build-standalone hosts on that project's allowlist.

Either way, modules **state the interpreter explicitly before the first Python call**. With no
interpreter configured, reticulate silently auto-provisions a bare Python, and that binding
cannot be undone in-process.

## 4. Project setup and the launcher (amended 2026-10-06: replaces the in-folder template)

**Principle (§2.1):** the project folder holds only project content. Everything that *defines the
sandbox* lives in the owner's config directory, which the container never mounts. The one
exception is the allowlist file, mounted read-only. The host never executes or interprets a file
from the project folder.

```
~/GitHub/agent-containers/              # the owner's clone: launcher + seeds (never mounted)
  bin/agent-up
  project-template/                     # seeds copied by `agent-up init`
~/.config/agent-containers/<project>/   # owner-maintained, per project (never mounted)
  compose.yaml                          # generated from the seed, then owner-edited
  project.env                           # op:// references only
  allowlist                             # project domains → /etc/firewall/allowlist.d/50-project.txt:ro
  project.conf                          # PROJECT_DIR, PROFILE (builder|research), IMAGE (base|gis|bio)
<project-dir>/                          # the agent's read-write workspace: code, data, outputs, CLAUDE.md
```

**Commands** (run on the host, from the owner's clone):

| Command | Does |
|---|---|
| `agent-up init <project-dir> [--image gis] [--profile builder]` | creates `~/.config/agent-containers/<project>/` from the seeds; prints the remaining steps (vault, digest) |
| `agent-up up <project>` | checks the image digest, then `op run --env-file <cfg>/project.env -- docker compose -f <cfg>/compose.yaml --project-directory <cfg> -p <project> up -d --force-recreate` |
| `agent-up shell <project>` | `docker exec -it -u agent <project>-agent-1 zsh` |
| `agent-up status \| stop \| down <project>` | compose wrappers |

**`compose.yaml`** (the seed):
- `image:` by **digest**;
- `user: "1000:1000"`, `init: true`;
- `cap_add: [NET_ADMIN, NET_RAW]` (firewall);
- an explicit **`mem_limit`**;
- the firewall and `agent-init` run at start;
- volumes (builder profile):
  - `${PROJECT_DIR}` → `/workspace` (rw);
  - `claude-<project>` → `~/.claude` (**fixed name**: logins, settings, per-project memory survive
    rebuilds);
  - `rlib-<project>` → the setupProject standAlone library (fixed name);
  - `require-cache-shared` → Require's cache (shared, external);
  - `uv-cache` (optional, shared);
  - the allowlist → `/etc/firewall/allowlist.d/50-project.txt:ro`;
  - spades.ai → `/opt/reference/spades.ai` (rw);
  - **reserved:** `memory` (§13.2), `t3-<project>` (§13.1);
- ports, if ever needed, published on **`127.0.0.1` only**, with a matching firewall INPUT rule
  (INPUT is default-DROP).

**Secrets:** `op run` resolves them in the launcher's process only. No plaintext env file is
written to disk. This drops `resolve-secrets` and the mode-600 env file.

**Editor:** VS Code **"Dev Containers: Attach to Running Container…"**. There is no
`devcontainer.json` in the project folder, so a planted one can't redefine the container.

**Working practice:**
- **Recommended:** do git and R inside the container (attached VS Code or `agent-up shell`).
- Host git in the project folder is *allowed*, but it honours agent-writable `.git/config` and
  hooks. That's accepted for builders under §2.1; don't do it on research output.
- Secret scanning (gitleaks) runs in **CI** as a required check, not as a host-side pre-commit
  hook.

**Removed from the 2026-10-04 template:**
- the read-only overlays;
- launcher checksums and `--adopt`;
- `.env` rewriting and refusal;
- `check-digest` and `resolve-secrets` in the folder (`agent-up` absorbs them);
- the project `.devcontainer/`;
- the host pre-commit hook.

**Lifecycle**

| Action | Steps |
|---|---|
| New project | create vault `agent-<project>` + service account + scoped GitHub token; `agent-up init <dir>`; set the digest; `agent-up up <project>` |
| Upgrade the image | bump the digest in `<cfg>/compose.yaml` (from `digests.md`); `agent-up up <project>` |
| Change the allowlist | edit `<cfg>/allowlist`; `agent-up up <project>` |
| Change a secret | edit it in 1Password; `agent-up up <project>` (env is fixed at creation) |
| Attach | VS Code *Attach to Running Container*, or `agent-up shell <project>` |

⚠️ **Memory limits vs. memory gates:** with `mem_limit` set, `/proc/meminfo` inside the container
still reports the **host's** memory. Pipeline memory gates must read `/sys/fs/cgroup/memory.max`.
That is tracked in the pipeline repos' memory-gate/benchmark work, but every project template
must state its limit explicitly.

## 5. Secrets (1Password)

**Rules:** no secret in a repo, an image, logs, command-line arguments or agent chat. Anything in
an agent container's environment or files is readable by the agent, so only **scoped,
revocable** secrets go there.

**Tiers**

| Tier | Meaning | Examples | Where it lives |
|---|---|---|---|
| A | agent may hold | fine-grained GitHub token (one project's repos; push branches + open PRs; no merge to `main`, no admin), read-only data API keys | vault `agent-<project>` (read-only for that project's **service account**) |
| B | agent prepares, **human executes** | ENA Webin submission, Zenodo publish, merging to `main` | vault `human-actions`, used via the user's own biometric `op run` **on the host or a non-agent container** |
| C | never in any container | the user's GitHub login/PAT, the 1Password account, cloud root credentials | the user's personal vaults |

**Mechanics:**
- **Service accounts** are scoped per vault; the vault is the unit of compartmentalisation, and
  a token is revoked in one click.
- The service-account token lives in the host session or keychain only.
- `op run --env-file project.env` resolves values into the container at creation; the agent never
  sees the service-account token.

**Known exposures (accepted):**
- tier A values are readable by the agent;
- `docker inspect` shows the container's env on the host;
- service accounts are rate-limited.

**Guards:**
- `.gitignore` patterns for resolved env files (`.env.resolved`, `*.secret`);
- a secret scanner (gitleaks) as a **required CI check** in each repo (amended 2026-10-06: not a
  host-side pre-commit hook, per §2.1);
- the egress firewall limits where a leaked tier-A secret could go.

## 6. Agent identity and the merge gate

**Decision (2026-10-03): agents propose, humans merge.**
- **Rulesets on `main`** (this repo first; then each project repo): PR required; required
  status checks (CI); no force-push or deletion.
- **Agents use a separate GitHub identity** (machine user or GitHub App) via the tier-A token:
  it can push branches and open PRs, and **cannot merge to `main` or bypass rules**.
- **The user merges** (button, mobile app, or `gh pr merge` from their own terminal).
- **Team repos** (PredictiveEcology) follow the org's own rules and shared CI actions
  (`PredictiveEcology/actions`). There, a second-person approval / `CODEOWNERS` becomes
  possible.
- **Until the agent identity exists:** agents never merge unasked.

## 7. Pinning policy

| Thing | Pinned how | Bumped how |
|---|---|---|
| Base OS/R image | `rocker/r-ver@sha256:` in `images/base/Dockerfile` | PR |
| Our images | by digest in each project's `compose.yaml` | copy from `digests.md` |
| Claude Code, uv, NodeSource major | exact versions as build args | PR |
| PredictiveEcology/AI plugins + reference | one commit SHA (build arg) | PR (CI rebuilds and smoke-tests) |
| R packages | per project: `setupProject`/`Require`; `Require::pkgSnapshot()` recorded for anything frozen or cited | per project |
| spades.ai (personal conventions) | **not pinned:** mounted live from the host (§8) | n/a |

**Policy:** float while developing *but record* what you got; **pin hard** for anything cited
or re-run (freezes, release verification, cloud runs). Bump small and often.

## 8. Skills and reference layer

| Layer | Inclusion | Rationale |
|---|---|---|
| PredictiveEcology/AI (team) | plugins `shared-conventions`, `spades-toolkit-suite`, `landr-suite` baked into base at the pinned commit (`/plugin marketplace` source = that commit); the full repo on disk at `/opt/reference/pe-ai`, **same commit** | team conventions change slowly; one commit means plugin and reading copy can't disagree |
| spades.ai (personal) | the host clone **bind-mounted read-write** at `/opt/reference/spades.ai` | nimble: edit/commit/PR conventions while working; all containers see changes immediately |
| Project | the project's own `CLAUDE.md`, importing only a **short index** from spades.ai (critical rules + where to look) | on-disk files cost no context until read; only auto-imports do |

**Hooks:** the PredictiveEcology/AI hook files ship **disabled**. Enabling waits for the hooks
review and tutorial. After that, settings layer as team-adopted → personal → project. That is
also when agent-side enforcement of the merge gate (e.g. blocking `gh pr merge`) is decided.

## 9. CI (`.github/workflows/`)

- **On PR:**
  - build `base`, then `gis` and `bio` FROM the freshly built base;
  - run smoke tests;
  - a red result blocks the merge.
- **Smoke tests:**
  - base: R starts; `Require` and `SpaDES.project` load; `terra` reads a bundled tiny GeoTIFF;
    the firewall script parses the allowlist directory; `tmux`, `exiftool` and `claude --version`
    run;
  - gis: `terra` reads a bundled tiny NetCDF; `gdalinfo --version`;
  - bio: `mafft --version`; `conda run -n sklearn python -c "import sklearn"`.
- **On merge to `main`:** push to GHCR (public) tagged `YYYY.MM.DD-<sha>`; update `digests.md`
  with the digests.
- **Weekly (scheduled):** rebuild for OS security patches and **open a PR** with the new digests.
  Nothing upgrades silently.

## 10. Migration

1. Build and verify `spades-base` + `spades-gis` + the template; use them for the new GIS/fire
   project (first consumer, week of 2026-10-05).
2. Keep `spades-dev-environment` running unchanged for `spades_bioinformatics` until the
   `spades-bio` image is proven (a cheap smoke run), then move that project.
3. Archive `spades-dev-environment` once nothing uses it.

## 11. Acceptance (Phase 1 done when…)

- [ ] `spades-base`, `spades-gis` and `spades-bio` build in CI from pinned inputs and pass their smoke tests.
- [ ] Images are public on GHCR; `digests.md` lists them.
- [ ] A new project set up with `agent-up init` + `agent-up up` (amended 2026-10-06) starts with:
  - [ ] the firewall applied (base + project allowlist);
  - [ ] tier-A secrets resolved from its own vault;
  - [ ] Claude config on the fixed-name volume;
  - [ ] the shared Require cache.
- [ ] Recreating the container keeps Claude config, notes, the project R library and the Require cache.
- [ ] Nothing in the project folder is executed or read as configuration by the host launcher
  (verified: a planted `compose.yaml`, `.devcontainer/`, `.env` or `up` in the project folder
  changes nothing).
- [ ] VS Code attaches to the running container; R and the terminal work there.
- [ ] The agent's GitHub identity can open a PR but **cannot** merge to `main` (verified by trying).
- [ ] `main` of this repo is protected (PR + CI required).
- [ ] `setupProject()` runs in a fresh `spades-gis` container for a minimal SpaDES project, with plain `Rscript`.

## 12. Open questions

**Added 2026-10-06:**
- **B:** drop `sentry.io` and `statsig.com` from the base allowlist and set
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`? (Recommended: yes.)
- **C:** keep `release-assets.githubusercontent.com` in base? (Recommended: yes.)
- **Interim shared memory:** mount an empty `~/agent-memory` git repo read-write for builders now,
  so cross-project handoffs work before Phase 3 designs its structure? (Recommended: yes.)
- **Research profile and the Claude login:** a research container still holds a Claude
  credential while having open egress. Use a separate API key with a spend cap, or accept the
  subscription token there?
- **T3 connection method** (Phase 2): SSH into the container, or `t3 serve` + pairing on a
  127.0.0.1 port? (§13.1)

**Earlier:**

- **Agent identity:** machine user or GitHub App? A machine user is simpler; an App is cleaner
  for org use. Revisit with the team.
- **Exact base allowlist** for the new project's data sources (NRCan, climate data hosts): fill in
  when they're known.
- **Whether the PredictiveEcology/AI plugins are already used by the team in Posit Assistant**
  in a way that requires matching versions.

## 13. Seams for Phase 2 (orchestrator) and Phase 3 (memory) (added 2026-10-06)

Phase 1 doesn't build these. It must not block them, and it reserves the pieces listed.

### 13.1 T3 Code (Phase 2)

**Vetting (licence, account, telemetry checked first):**
- MIT, open source (`pingdotgg/t3code`).
- **Pre-1.0:** "very early, expect bugs", so pin an exact version.
- No account needed for local pairing. T3 Connect (a cloud relay) is optional and **not used**.
- Product telemetry (PostHog) is **on by default**: set `T3CODE_TELEMETRY_ENABLED=false`. It
  isn't on any allowlist, so it's blocked anyway.

**Fit:** T3 keeps execution where the workspace is. Its server ("environment") owns the agent
processes, git and files, and clients only display and steer over authenticated RPC. So:
- **one container = one T3 environment.** `t3` runs *inside* each builder container, behind the
  firewall, using that container's Claude login;
- **the T3 desktop app on Windows is only a client**, showing every project in one sidebar;
- **⛔ never use T3's local environment or its WSL-distro integration.** Both run agents directly
  on the host, with the user's credentials, outside the sandbox. Disable `localEnvironmentEnabled`.
- T3 never routes work between environments, which preserves per-project isolation. Its
  orchestrator MCP (sub-agents, threads) works within one environment only.
- Git worktrees for parallel threads are created inside the container's checkout.

**Reserved in Phase 1:**
- a volume name `t3-<project>` for `~/.t3` (thread history, event log, worktrees);
- one commented `127.0.0.1` port line in the compose seed, plus the firewall INPUT rule pattern
  (already documented in `init-firewall.sh`);
- the earlier `sshd` toggle, if Phase 2 chooses SSH.

**Phase 2 checks:**
- `node-pty` builds in our image (needs `g++`, `make`, `python3`);
- T3's default permission mode is **Full access**. That's acceptable inside a builder container,
  but decide it explicitly;
- hooks policy (§8) still applies to the Claude that T3 starts.

### 13.2 Memory (Phase 3)

| Layer | Where | Who writes |
|---|---|---|
| Per-project working memory | Claude's own memory in the `claude-<project>` volume | that project's agent (exists today) |
| Shared memory and handoffs | a git repo on the host, mounted at `/opt/memory` | builders: rw; research: not mounted |
| Curated conventions | spades.ai (§8) | builders: rw; changes reviewed as PRs |

**Reserved in Phase 1:** the `/opt/memory` mount point (optionally live now; see §12).

**Phase 3 designs:** structure, what goes where, curation, how handoffs are written and found, and
whether shared memory needs provenance (which project wrote what). T3 thread history isn't
memory: it is per environment and won't be relied on.
