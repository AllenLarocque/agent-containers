# agent-containers — design spec

**Status:** draft for review · **Date:** 2026-10-03 · **Owner:** Allen Larocque
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

## 2. Scope

**Phase 1 (this spec, needed next week):** images, project template, firewall, secrets,
agent GitHub identity, CI, skills/reference layer (hooks shipped *disabled*).

**Seams left for later (designed in, not built):**
- **Memory / knowledge base:** a git repo for now; a mount point is reserved (§4).
- **Hooks:** to be reviewed and taught before any are enabled (§8).
- **Remote execution:** an `sshd` toggle (off by default), so a container can later be an SSH
  target for an orchestrator.
- **Cloud:** the same images run on the enterprise cloud machine (>100 GB RAM).
- **Memory gates reading the cgroup limit:** handled with the memory-gate and benchmarking work in
  the pipeline repos, not here (§4).

**Non-goals:** orchestrators (Paperclip etc.: parked), voice/mobile, Obsidian integration, the
NAS services.

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

## 4. Project template (`project-template/`)

Copied into each project. Four files plus a helper:

- **`compose.yaml`:**
  - `image:` by **digest**;
  - `user: "1000:1000"`;
  - the project bind-mounted at `/workspace`;
  - `cap_add: [NET_ADMIN, NET_RAW]` (firewall);
  - an explicit **`mem_limit`**;
  - `command: sleep infinity`;
  - volumes:
    - `claude-config` → `~/.claude`, **fixed name** `claude-<project>`, so logins, settings and
      agent notes survive rebuilds;
    - `require-cache` → Require's package cache, **one shared external volume** across all
      SpaDES projects;
    - `uv-cache` (optional, shared);
    - `~/.config/agent-containers/<project>.allowlist` (host, owner-maintained, outside the
      agent-writable workspace) → `/etc/firewall/allowlist.d/50-project.txt:ro` (amended 2026-10-04);
    - **reserved:** a `memory` mount point (empty until the memory repo exists).
  - Ports, if ever needed, publish on **`127.0.0.1` only**. The compose project name gives one
    group in lazydocker/Dockge.
- **`devcontainer.json`:** points at `compose.yaml` (`dockerComposeFile`, `service`,
  `workspaceFolder`), so VS Code's "Reopen in Container" still works.
- **`project.env`:** **`op://` references only**; committable. Example:
  `GH_TOKEN=op://agent-<project>/github/token`.
- **`allowlist.txt`:** a seed only (amended 2026-10-04): copied once to
  `~/.config/agent-containers/<project>.allowlist` on the host, which the firewall reads; edits in the
  repo have no effect. Domains beyond the base list; SSH to own servers needs an entry too. The base list is CRAN/P3M, PredictiveEcology
  r-universe, Bioconductor, GitHub (+ GHCR), Anthropic, and the npm registry for the CLI.
- **`up`** (helper): `op run --env-file project.env -- docker compose up -d --force-recreate`.

**Lifecycle**

| Action | Steps |
|---|---|
| New project | copy the template; create vault `agent-<project>` + its service account + scoped GitHub token; `./up` |
| Upgrade the image | bump the digest in `compose.yaml` (from `digests.md`); `./up` |
| Change the allowlist | edit `~/.config/agent-containers/<project>.allowlist` on the host; `./up` |
| Change a secret | edit it in 1Password; `./up` (env is fixed at container creation) |

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
- a pre-commit secret scanner (gitleaks) in each repo;
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
- [ ] A new project created from the template, given the user's `./up`, starts with:
  - [ ] the firewall applied (base + project allowlist);
  - [ ] tier-A secrets resolved from its own vault;
  - [ ] Claude config on the fixed-name volume;
  - [ ] the shared Require cache.
- [ ] Recreating the container keeps Claude config, notes and the Require cache.
- [ ] The agent's GitHub identity can open a PR but **cannot** merge to `main` (verified by trying).
- [ ] `main` of this repo is protected (PR + CI required).
- [ ] `setupProject()` runs in a fresh `spades-gis` container for a minimal SpaDES project, with plain `Rscript`.

## 12. Open questions

- **Agent identity:** machine user or GitHub App? A machine user is simpler; an App is cleaner
  for org use. Revisit with the team.
- **Exact base allowlist** for the new project's data sources (NRCan, climate data hosts): fill in
  when they're known.
- **Whether the PredictiveEcology/AI plugins are already used by the team in Posit Assistant**
  in a way that requires matching versions.
