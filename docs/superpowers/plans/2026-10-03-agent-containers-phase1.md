# agent-containers Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build pinned, layered dev-container images (`spades-base` → `spades-gis`, `spades-bio`), a per-project template, CI and runbooks, so that a new GIS/fire SpaDES project can start in a firewalled, secret-compartmentalised container the week of 2026-10-05.

**Architecture:** Dockerfiles under `images/<name>/` build in GitHub Actions: base first, then the children `FROM` the freshly built base via a `BASE_IMAGE` build arg. Each image has a bash smoke test under `tests/smoke/`, run inside the built image. A project template (`project-template/`) holds compose + devcontainer + 1Password references. Merges to `main` publish to GHCR and open a PR updating `digests.md`.

**Tech Stack:** Docker / Buildx, GitHub Actions, GHCR, bash, iptables + ipset + dnsmasq, Node 22 + Claude Code, R 4.5.3 (rocker/r-ver) + Require/SpaDES.project, 1Password CLI (`op`, host only), Docker Compose v2.

## Global Constraints

- Base image: `rocker/r-ver:4.5.3`, **pinned by digest** (resolved in Task 1, never a bare tag after that).
- Non-root user **`agent`, UID/GID 1000**; `docker exec -u agent` (exec defaults to root).
- Claude Code pinned: **`2.1.289`**. uv pinned: **`0.12.19`**. NodeSource **22.x**.
- PredictiveEcology/AI pinned at commit **`e7ae689751316dfe742f31b32d0d659accd0cc41`**: plugins `shared-conventions`, `spades-toolkit-suite`, `landr-suite` from marketplace `predictiveecology-ai`, plus the same checkout on disk at `/opt/reference/pe-ai`.
- Personal plugins carried over from the current container: `superpowers@superpowers-marketplace` (repo `obra/superpowers-marketplace`), `claude-hud@claude-hud` (repo `jarrodwatts/claude-hud`), `message-timestamps@zoharbabin-claude-tools` (repo `zoharbabin/claude-code-message-timestamps`).
- Miniforge pinned: **`26.7.2-0`** (latest release on 2026-10-03).
- R in base: **only** `Require` and `SpaDES.project` preinstalled. Projects use `setupProject(standAlone = TRUE)`. **No renv.**
- GDAL/GEOS/PROJ/udunits in **base**, from **Ubuntu's own packages; never the ubuntugis PPA**.
- `spades-gis` adds only: `libnetcdf-dev`, `netcdf-bin`, `libhdf5-dev`.
- Hooks: **none enabled**. `settings.json` must have no `hooks` key.
- Secrets: no secret in the repo, an image, logs or command-line args. Tier A only reaches a container (spec §5). The user's own GitHub PAT never enters a container.
- Images are **public** on GHCR: `ghcr.io/allenlarocque/spades-{base,gis,bio}`.
- `main` is protected: PR required, CI required. **Agents never merge.**
- No Docker is available inside the agent's own dev container: all build and run verification happens in **CI** (or on the user's host via `scripts/build-local.sh`).

**Deviations from the spec (recorded deliberately):**
1. Resolved tier-A env lives at `~/.config/agent-containers/<project>.env` on the **host** (mode 600, outside any repo), written by `resolve-secrets`. Reason: VS Code "Reopen in Container" runs compose itself, and without a persistent env file it would recreate the container *without* secrets.
2. Base smoke tests use the GDAL CLI, not `terra` (`terra` is not preinstalled); the R/terra check is in the acceptance task (Task 6).

---

## File structure

```
agent-containers/
├── images/
│   ├── base/
│   │   ├── Dockerfile
│   │   ├── init-firewall.sh          # root; reads /etc/firewall/allowlist.d/*.txt
│   │   ├── allowlist.d/00-base.txt   # base domains (baked)
│   │   ├── agent-init.sh             # user; plugins, settings, gh, idempotent
│   │   └── configure-claude-settings.js
│   ├── gis/Dockerfile
│   └── bio/Dockerfile
├── tests/
│   ├── smoke/{base,gis,bio}.sh       # run INSIDE the image
│   ├── firewall/test-firewall.sh     # run inside a started container (needs NET_ADMIN)
│   └── acceptance/minimal-project/global.R
├── project-template/
│   ├── compose.yaml
│   ├── .devcontainer/devcontainer.json
│   ├── project.env                   # op:// references only
│   ├── allowlist.txt
│   ├── resolve-secrets               # host: op inject -> ~/.config/agent-containers/<p>.env
│   ├── up                            # host: resolve-secrets + compose up
│   ├── .gitignore
│   └── README.md
├── scripts/build-local.sh            # host-side build of base -> gis/bio
├── docs/runbooks/{machine-user-and-rulesets,1password-project-vault,new-project}.md
├── digests.md
└── .github/workflows/{ci,publish}.yml
```

---

### Task 1: `spades-base` image + smoke test + PR CI

**Files:**
- Create: `images/base/Dockerfile`, `tests/smoke/base.sh`, `.github/workflows/ci.yml`, `scripts/build-local.sh`, `.gitignore`

**Interfaces:**
- Produces: image tag `spades-base:ci` inside CI jobs; build arg contract `BASE_IMAGE` (used by Tasks 4 and 9); user `agent` (1000:1000) with home `/home/agent`; `/usr/local/bin/init-firewall.sh` path (Task 2 fills it in); `/etc/firewall/allowlist.d/` directory.

- [ ] **Step 1: Write the failing smoke test** — `tests/smoke/base.sh`

```bash
#!/usr/bin/env bash
# Smoke test for spades-base. Runs INSIDE the image as the default user.
set -euo pipefail
fail=0
ok()   { echo "OK:   $*"; }
bad()  { echo "FAIL: $*"; fail=1; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

[ "$(id -u)" = "1000" ] && [ "$(id -un)" = "agent" ] && ok "user agent uid 1000" || bad "user is $(id -un)/$(id -u), want agent/1000"
check "R starts"                       Rscript -e 'invisible(1)'
check "R is 4.5.3"                     Rscript -e 'stopifnot(getRversion() == "4.5.3")'
check "Require loads"                  Rscript -e 'library(Require)'
check "SpaDES.project loads"           Rscript -e 'library(SpaDES.project)'
check "SpaDES.core NOT preinstalled"   Rscript -e 'stopifnot(!requireNamespace("SpaDES.core", quietly = TRUE))'
check "terra NOT preinstalled"         Rscript -e 'stopifnot(!requireNamespace("terra", quietly = TRUE))'
check "gdalinfo"                       gdalinfo --version
check "gdal can write+read a GeoTIFF"  bash -c 'gdal_create -outsize 2 2 -bands 1 -burn 1 -of GTiff /tmp/s.tif && gdalinfo /tmp/s.tif | grep -q "Driver: GTiff"'
check "geos/proj present"              bash -c 'dpkg -s libgeos-dev libproj-dev libudunits2-dev'
check "no ubuntugis PPA"               bash -c '! grep -rqi ubuntugis /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null'
check "tmux"                           tmux -V
check "exiftool"                       exiftool -ver
check "gh"                             gh --version
check "uv 0.12.19"                     bash -c 'uv --version | grep -q "0.12.19"'
check "node 22"                        bash -c 'node --version | grep -q "^v22\."'
check "claude 2.1.289"                 bash -c 'claude --version | grep -q "2.1.289"'
check "firewall script present"        test -x /usr/local/bin/init-firewall.sh
check "allowlist dir present"          test -d /etc/firewall/allowlist.d
check "sudo limited to firewall"       bash -c 'sudo -n -l | grep -q "/usr/local/bin/init-firewall.sh"'

[ "$fail" -eq 0 ] && echo "SMOKE base: ALL PASSED" || { echo "SMOKE base: FAILURES"; exit 1; }
```

- [ ] **Step 2: Write the CI workflow that runs it** — `.github/workflows/ci.yml`

```yaml
name: ci
on:
  pull_request:
  workflow_dispatch:
jobs:
  build-test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - name: Build base
        run: docker buildx build --load -t spades-base:ci images/base
      - name: Smoke base
        run: docker run --rm -v "$PWD/tests:/tests:ro" spades-base:ci bash /tests/smoke/base.sh
```

- [ ] **Step 3: Run it to verify it fails**

Run: `git checkout -b feat/base-image && chmod +x tests/smoke/base.sh && git add -A && git commit -m "test: base smoke test + CI" && git push -u origin feat/base-image && gh pr create --fill`, then `gh pr checks --watch`.
Expected: **FAIL** at "Build base" (no `images/base/Dockerfile`).

- [ ] **Step 4: Resolve the base digest** (CI or host; record the value)

Run on the host, or add a temporary CI step: `docker buildx imagetools inspect rocker/r-ver:4.5.3 --format '{{json .Manifest.Digest}}'`
Expected: a string `"sha256:…"`. Paste it into the Dockerfile `FROM` below, replacing `@sha256:RESOLVE_IN_STEP_4`. The build must fail loudly if left unreplaced, because `RESOLVE_IN_STEP_4` is not a valid digest.

- [ ] **Step 5: Write the Dockerfile** — `images/base/Dockerfile`

```dockerfile
# spades-base: everything every SpaDES agent container needs. See docs/specs/2026-10-03-agent-containers-design.md §3.1.
FROM rocker/r-ver:4.5.3@sha256:RESOLVE_IN_STEP_4

ARG TZ=America/Los_Angeles
ARG CLAUDE_CODE_VERSION=2.1.289
ARG UV_VERSION=0.12.19
ARG PE_AI_COMMIT=e7ae689751316dfe742f31b32d0d659accd0cc41
ENV TZ="$TZ" DEBIAN_FRONTEND=noninteractive

# OS + agent tooling. tmux: detached long runs. exiftool: photo metadata (field data).
RUN apt-get update && apt-get install -y --no-install-recommends \
      less git procps sudo fzf zsh man-db unzip gnupg2 gh iptables ipset dnsmasq iproute2 \
      dnsutils aggregate jq nano vim curl wget ca-certificates tmux libimage-exiftool-perl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node 22 (Claude Code requires engines.node >=22).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Geospatial system libraries IN BASE: every SpaDES module depends on terra.
# ⚠️ Ubuntu's own GDAL only — P3M binary R packages are built against it; never add the ubuntugis PPA.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgdal-dev gdal-bin libgeos-dev libproj-dev libudunits2-dev libsqlite3-dev \
      libcurl4-openssl-dev libssl-dev libxml2-dev \
      libfontconfig1-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev \
      libpng-dev libtiff5-dev libjpeg-dev cmake \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# R bootstrap ONLY: enough to run setupProject(). Everything else is provisioned per project
# by setupProject(standAlone = TRUE), which hides the site library anyway.
RUN Rscript -e " \
  options(repos = c(PredictiveEcology = 'https://predictiveecology.r-universe.dev', \
                    CRAN = 'https://packagemanager.posit.co/cran/__linux__/noble/latest')); \
  install.packages(c('Require', 'SpaDES.project'), Ncpus = parallel::detectCores()); \
  stopifnot(all(c('Require', 'SpaDES.project') %in% rownames(installed.packages())))"

# uv, pinned (light Python tooling; reticulate::py_require()).
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" -o /tmp/uv.tgz \
    && tar xzf /tmp/uv.tgz -C /tmp && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv \
    && rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu

# Non-root user, fixed UID/GID 1000 (matches the WSL user for bind-mount ownership).
RUN groupadd --gid 1000 agent && useradd --uid 1000 --gid 1000 --create-home --shell /bin/zsh agent \
    && mkdir -p /workspace /etc/firewall/allowlist.d /usr/local/share/npm-global \
    && chown -R agent:agent /workspace /usr/local/share/npm-global

# Firewall: script + base allowlist (Task 2 fills these in). sudo ONLY for the firewall script.
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowlist.d/ /etc/firewall/allowlist.d/
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && echo "agent ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/agent-firewall \
    && chmod 0440 /etc/sudoers.d/agent-firewall

USER agent
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/usr/local/share/npm-global/bin:$PATH SHELL=/bin/zsh EDITOR=nano
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
WORKDIR /workspace
CMD ["sleep", "infinity"]
```

Create placeholder files so the COPY lines succeed (Task 2 replaces them):

`images/base/init-firewall.sh`:
```bash
#!/bin/bash
echo "init-firewall: placeholder (Task 2)"; exit 1
```
`images/base/allowlist.d/00-base.txt`:
```
# Base allowlist — populated in Task 2.
```

- [ ] **Step 6: Write the host-side build helper** — `scripts/build-local.sh`

```bash
#!/usr/bin/env bash
# Build images on the HOST (Docker required): base, then the requested children FROM it.
#   scripts/build-local.sh            # base + gis
#   scripts/build-local.sh bio        # base + bio
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t spades-base:local images/base
docker run --rm -v "$PWD/tests:/tests:ro" spades-base:local bash /tests/smoke/base.sh
for child in "${@:-gis}"; do
  docker build --build-arg BASE_IMAGE=spades-base:local -t "spades-$child:local" "images/$child"
  docker run --rm -v "$PWD/tests:/tests:ro" "spades-$child:local" bash "/tests/smoke/$child.sh"
done
```

`.gitignore`:
```
*.env.resolved
*.secret
.env
```

- [ ] **Step 7: Run CI to verify it passes**

Run: `chmod +x scripts/build-local.sh && git add -A && git commit -m "feat(base): spades-base image" && git push`, then `gh pr checks --watch`.
Expected: "Smoke base" prints `SMOKE base: ALL PASSED`. (`init-firewall.sh` is a placeholder but executable, so the presence checks pass.)

- [ ] **Step 8: Hand the PR to the user to merge** (agents never merge). Report: "ready: PR #N, CI green".

---

### Task 2: Firewall reading `allowlist.d/` + base allowlist + firewall test in CI

**Files:**
- Modify: `images/base/init-firewall.sh` (replace the placeholder), `images/base/allowlist.d/00-base.txt`, `.github/workflows/ci.yml`
- Create: `tests/firewall/test-firewall.sh`

**Interfaces:**
- Consumes: Task 1 image layout (`/etc/firewall/allowlist.d/`, sudo rule).
- Produces: contract "every `*.txt` in `/etc/firewall/allowlist.d/` is merged; `#` comments and blank lines ignored; a base domain also matches its subdomains (dnsmasq semantics)". Project files mount as `/etc/firewall/allowlist.d/50-project.txt`.

- [ ] **Step 1: Write the failing firewall test** — `tests/firewall/test-firewall.sh`

```bash
#!/usr/bin/env bash
# Run INSIDE a started container AFTER `sudo init-firewall.sh`. Needs NET_ADMIN/NET_RAW.
set -uo pipefail
fail=0
blocked(){ if curl --connect-timeout 5 -s "$1" >/dev/null 2>&1; then echo "FAIL: $1 reachable, should be BLOCKED"; fail=1; else echo "OK:   $1 blocked"; fi; }
allowed(){ if curl --connect-timeout 10 -sSf "$1" >/dev/null 2>&1; then echo "OK:   $1 reachable"; else echo "FAIL: $1 blocked, should be ALLOWED"; fail=1; fi; }
blocked https://example.com
allowed https://api.github.com/zen
allowed https://cloud.r-project.org/src/contrib/PACKAGES.gz
allowed https://packagemanager.posit.co/cran/__linux__/noble/latest/src/contrib/PACKAGES.gz
allowed https://predictiveecology.r-universe.dev/src/contrib/PACKAGES.gz
allowed https://bioconductor.org/packages/release/bioc/src/contrib/PACKAGES.gz
# project-file merge: CI mounts a 50-project.txt containing exactly "httpbin.org"
allowed https://httpbin.org/get
[ "$fail" -eq 0 ] && echo "FIREWALL: ALL PASSED" || { echo "FIREWALL: FAILURES"; exit 1; }
```

- [ ] **Step 2: Add the CI job step** — append to `build-test.steps` in `.github/workflows/ci.yml`

```yaml
      - name: Firewall test (base + project allowlist merge)
        run: |
          echo "httpbin.org" > /tmp/50-project.txt
          docker run -d --name fw --cap-add NET_ADMIN --cap-add NET_RAW \
            -v /tmp/50-project.txt:/etc/firewall/allowlist.d/50-project.txt:ro \
            -v "$PWD/tests:/tests:ro" spades-base:ci sleep infinity
          docker exec fw sudo /usr/local/bin/init-firewall.sh
          docker exec fw bash /tests/firewall/test-firewall.sh
          docker rm -f fw
```

- [ ] **Step 3: Push; verify it fails**

Run: new branch `feat/firewall`, commit, push, open PR, `gh pr checks --watch`.
Expected: **FAIL** at `init-firewall.sh` (placeholder exits 1).

- [ ] **Step 4: Write the base allowlist** — `images/base/allowlist.d/00-base.txt`

```
# Base egress allowlist for every agent container. One domain per line; a base domain
# also matches its subdomains (dnsmasq ipset semantics). Project additions go in the
# project's allowlist.txt, mounted as 50-project.txt. Domain rationale is carried over from
# spades-dev-environment/.devcontainer/init-firewall.sh (2026-09).
# --- Claude Code / npm
api.anthropic.com
registry.npmjs.org
sentry.io
statsig.com
# --- VS Code server + extensions
marketplace.visualstudio.com
vscode.blob.core.windows.net
update.code.visualstudio.com
# --- GitHub (API/web/git ranges are added from api.github.com/meta; these cover downloads + GHCR)
raw.githubusercontent.com
codeload.github.com
objects.githubusercontent.com
ghcr.io
pkg-containers.githubusercontent.com
# --- R package sources used by setupProject/Require/pak
cloud.r-project.org
packagemanager.posit.co
p3m.dev
rspm-sync.rstudio.com
predictiveecology.r-universe.dev
bioc.r-universe.dev
# r-universe 302-redirects tarballs to Cloudflare R2; without this every r-universe source download fails.
r2.ropensci.org
bioconductor.org
# Bioconductor's alternate source mirror (pak/BiocManager fall back to it).
osn.xsede.org
# Require::internetExists() probes www.google.com; if blocked Require flips to offline mode and
# every install fails.
www.google.com
```

- [ ] **Step 5: Write the firewall script** — `images/base/init-firewall.sh`

Port `spades-dev-environment/.devcontainer/init-firewall.sh` verbatim **except** the `ALLOWED_DOMAINS=( … )` array, which is replaced by reading the allowlist directory:

```bash
#!/bin/bash
# Default-deny egress firewall. GitHub ranges from api.github.com/meta; every other allowed
# domain is authorised lazily by dnsmasq inserting each resolved IP into the ipset (CDN IPs rotate).
# Domains come from /etc/firewall/allowlist.d/*.txt (base baked in; project mounted).
set -euo pipefail
IFS=$'\n\t'
ALLOWLIST_DIR=/etc/firewall/allowlist.d

mapfile -t ALLOWED_DOMAINS < <(cat "$ALLOWLIST_DIR"/*.txt 2>/dev/null \
  | sed 's/#.*//' | tr -d ' \t\r' | grep -v '^$' | sort -u)
if [ "${#ALLOWED_DOMAINS[@]}" -eq 0 ]; then
  echo "ERROR: no domains found in $ALLOWLIST_DIR/*.txt"; exit 1
fi
echo "Allowlist: ${#ALLOWED_DOMAINS[@]} domains from $(ls "$ALLOWLIST_DIR"/*.txt | xargs -n1 basename | tr '\n' ' ')"
```

…followed by the remainder of the original script **unchanged from** `DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)` through the final CRAN soft check, with the original hard-coded `ALLOWED_DOMAINS=( … )` block deleted. (The original builds `IPSET_DIRECTIVE` from `ALLOWED_DOMAINS`, primes it with `dig`, applies the iptables policy, and verifies example.com is blocked + api.github.com reachable; all of that stays.)

- [ ] **Step 6: Push; verify it passes**

Expected in CI: `Allowlist: N domains from 00-base.txt 50-project.txt`, then `FIREWALL: ALL PASSED`, and the base smoke test still passes.

- [ ] **Step 7: Hand the PR to the user to merge.**

---

### Task 3: Agent runtime init — plugins (PE/AI pinned), settings, gh

**Files:**
- Create: `images/base/agent-init.sh`, `images/base/configure-claude-settings.js`
- Modify: `images/base/Dockerfile` (clone PE/AI at the pin into `/opt/reference/pe-ai`; COPY agent-init), `tests/smoke/base.sh` (add runtime checks), `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `PE_AI_COMMIT` build arg (Task 1); `GH_TOKEN` env (tier A, from Task 5); `CLAUDE_CONFIG_DIR=/home/agent/.claude` (a volume at runtime).
- Produces: `/usr/local/bin/agent-init.sh` (idempotent, runs as `agent`, never fails container start: always `exit 0`, logs problems); `/opt/reference/pe-ai` at the pinned commit; a settings file without `hooks`.

- [ ] **Step 1: Add the failing runtime checks** — append to `tests/smoke/base.sh` before the final line

```bash
check "PE/AI on disk at pinned commit" bash -c 'git -C /opt/reference/pe-ai rev-parse HEAD | grep -q "^e7ae689751316dfe742f31b32d0d659accd0cc41$"'
check "agent-init present"             test -x /usr/local/bin/agent-init.sh
check "agent-init succeeds"            bash -c 'CLAUDE_CONFIG_DIR=/tmp/cc /usr/local/bin/agent-init.sh'
check "PE/AI plugins installed"        bash -c 'jq -e ".plugins | keys | map(select(test(\"@predictiveecology-ai$\"))) | length == 3" /tmp/cc/plugins/installed_plugins.json'
check "superpowers installed"          bash -c 'jq -e ".plugins | has(\"superpowers@superpowers-marketplace\")" /tmp/cc/plugins/installed_plugins.json'
check "NO hooks in settings"           bash -c 'jq -e "has(\"hooks\") | not" /tmp/cc/settings.json'
```

CI change: smoke runs with network (no firewall), so marketplace adds work. Leave the smoke step as is.

- [ ] **Step 2: Push; verify it fails** (no `/opt/reference/pe-ai`, no `agent-init.sh`).

- [ ] **Step 3: Write `images/base/configure-claude-settings.js`**

Port `spades-dev-environment/.devcontainer/configure-claude-settings.js` verbatim (statusLine via claude-hud, `skipDangerousModePermissionPrompt: true`, HUD defaults), with one addition before the write:

```js
// Hooks ship DISABLED until the user's hooks review (spec §8). Fail loudly if anything set them.
if (Object.prototype.hasOwnProperty.call(json, 'hooks')) {
  console.error('configure-claude-settings: refusing to keep a "hooks" key (hooks are disabled by policy)');
  delete json.hooks;
}
```

- [ ] **Step 4: Write `images/base/agent-init.sh`**

```bash
#!/usr/bin/env bash
# Runs as `agent` at container start (after the firewall). Idempotent. NEVER fails the start:
# every step is guarded and the script always exits 0, logging what it could not do.
set -uo pipefail
log(){ printf '[agent-init] %s\n' "$*"; }
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
mkdir -p "$CLAUDE_CONFIG_DIR"

# 1. Plugins. PE/AI from the PINNED local checkout (same commit as /opt/reference/pe-ai, so
#    plugin and reading copy cannot disagree); personal plugins from GitHub.
add_mkt(){ claude plugin marketplace add "$1" >/dev/null 2>&1 && log "marketplace: $1" || log "WARN marketplace add failed: $1"; }
inst(){ claude plugin install "$1" >/dev/null 2>&1 && log "plugin: $1" || log "WARN plugin install failed: $1"; }
add_mkt /opt/reference/pe-ai
add_mkt obra/superpowers-marketplace
add_mkt jarrodwatts/claude-hud
add_mkt zoharbabin/claude-code-message-timestamps
for p in shared-conventions spades-toolkit-suite landr-suite; do inst "$p@predictiveecology-ai"; done
inst superpowers@superpowers-marketplace
inst claude-hud@claude-hud
inst message-timestamps@zoharbabin-claude-tools

# 2. Settings (statusLine, no hooks).
node /usr/local/lib/agent/configure-claude-settings.js "$(command -v node)" || log "WARN settings not written"

# 3. GitHub: gh reads GH_TOKEN (tier A, scoped agent token) directly; make git use gh.
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 && log "git uses gh credentials (agent identity)" || log "WARN gh setup-git failed"
else
  log "NOTE: no GH_TOKEN — GitHub write access disabled in this container"
fi
exit 0
```

- [ ] **Step 5: Wire into the Dockerfile** — insert before `USER agent` in `images/base/Dockerfile`

```dockerfile
# PredictiveEcology/AI at the pinned commit: reading copy AND plugin marketplace source.
RUN git clone --quiet https://github.com/PredictiveEcology/AI.git /opt/reference/pe-ai \
    && git -C /opt/reference/pe-ai checkout --quiet "${PE_AI_COMMIT}" \
    && chown -R agent:agent /opt/reference
COPY agent-init.sh /usr/local/bin/agent-init.sh
COPY configure-claude-settings.js /usr/local/lib/agent/configure-claude-settings.js
RUN chmod 0755 /usr/local/bin/agent-init.sh
```

and after `USER agent`: `ENV CLAUDE_CONFIG_DIR=/home/agent/.claude`

- [ ] **Step 6: Push; verify it passes** — all base smoke checks including the six new ones.

- [ ] **Step 7: Hand the PR to the user to merge.**

---

### Task 4: `spades-gis` image + smoke test

**Files:**
- Create: `images/gis/Dockerfile`, `tests/smoke/gis.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `BASE_IMAGE` build arg; `spades-base:ci` in CI.
- Produces: `spades-gis:ci` (used by Task 6).

- [ ] **Step 1: Write the failing smoke test** — `tests/smoke/gis.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
fail=0
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "OK:   $d"; else echo "FAIL: $d"; fail=1; fi; }
check "inherits base smoke"     bash /tests/smoke/base.sh
check "netcdf dev headers"      bash -c 'dpkg -s libnetcdf-dev libhdf5-dev'
check "ncdump"                  bash -c 'ncdump 2>&1 | grep -qi usage'
check "GDAL writes+reads NetCDF" bash -c 'gdal_create -outsize 2 2 -bands 1 -burn 1 -of GTiff /tmp/g.tif && gdal_translate -q -of netCDF /tmp/g.tif /tmp/g.nc && ncdump -h /tmp/g.nc | grep -q dimensions'
[ "$fail" -eq 0 ] && echo "SMOKE gis: ALL PASSED" || { echo "SMOKE gis: FAILURES"; exit 1; }
```

- [ ] **Step 2: Add CI steps** — append to `build-test.steps`

```yaml
      - name: Build gis
        run: docker buildx build --load --build-arg BASE_IMAGE=spades-base:ci -t spades-gis:ci images/gis
      - name: Smoke gis
        run: docker run --rm -v "$PWD/tests:/tests:ro" spades-gis:ci bash /tests/smoke/gis.sh
```

- [ ] **Step 3: Push; verify it fails** (no `images/gis/Dockerfile`).

- [ ] **Step 4: Write `images/gis/Dockerfile`**

```dockerfile
# spades-gis: R-only geospatial work (mapping, predictive modelling, R-based fire models).
# Adds only NetCDF/HDF5 on top of base (GDAL/GEOS/PROJ are already in base). Spec §3.2.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-base:latest
FROM ${BASE_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      libnetcdf-dev netcdf-bin libhdf5-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
USER agent
```

- [ ] **Step 5: Push; verify it passes** (`SMOKE gis: ALL PASSED`).

- [ ] **Step 6: Hand the PR to the user to merge.**

---

### Task 5: Project template (compose, devcontainer, secrets helpers)

**Files:**
- Create: everything under `project-template/`, `tests/template/test-template.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: image names; firewall mount path `/etc/firewall/allowlist.d/50-project.txt`; `agent-init.sh`; `GH_TOKEN`.
- Produces: the per-project contract:
  - `PROJECT` (compose project name) = the folder name;
  - host env file `~/.config/agent-containers/${PROJECT}.env` (mode 600);
  - volume `claude-${PROJECT}`;
  - external volume `require-cache-shared`.

- [ ] **Step 1: Write the failing template test** — `tests/template/test-template.sh`

```bash
#!/usr/bin/env bash
# Validates the template WITHOUT secrets: compose renders, scripts parse, no secret values committed.
set -euo pipefail
cd "$(dirname "$0")/../../project-template"
fail=0
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "OK:   $d"; else echo "FAIL: $d"; fail=1; fi; }
mkdir -p "$HOME/.config/agent-containers"; : > "$HOME/.config/agent-containers/project-template.env"
docker volume create require-cache-shared >/dev/null
check "compose renders"              docker compose -p project-template config
check "image pinned by digest"       bash -c 'grep -Eq "image: ghcr.io/allenlarocque/spades-(gis|bio|base)@sha256:" compose.yaml'
check "project.env is references"    bash -c '! grep -Ev "^\s*(#|$)" project.env | grep -v "=op://"'
check "resolve-secrets parses"       bash -n resolve-secrets
check "up parses"                    bash -n up
check "devcontainer.json valid JSON" bash -c 'grep -v "^\s*//" .devcontainer/devcontainer.json | jq -e .dockerComposeFile'
check "gitignore covers env"         grep -q "\.env\.resolved" .gitignore
check "gitleaks pre-commit"          grep -q "gitleaks/gitleaks" .pre-commit-config.yaml
[ "$fail" -eq 0 ] && echo "TEMPLATE: ALL PASSED" || { echo "TEMPLATE: FAILURES"; exit 1; }
```

CI step (append):
```yaml
      - name: Template test
        run: bash tests/template/test-template.sh
```

- [ ] **Step 2: Push; verify it fails** (no template).

- [ ] **Step 3: Write `project-template/compose.yaml`**

```yaml
# One compose project per SpaDES project. Copy this folder into the project root.
# Image: copy a digest from agent-containers/digests.md. Secrets: run ./up (never plain compose).
name: ${PROJECT:-project-template}
services:
  agent:
    image: ghcr.io/allenlarocque/spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md
    user: "1000:1000"
    working_dir: /workspace
    init: true
    cap_add: [NET_ADMIN, NET_RAW]          # firewall
    mem_limit: 100g                        # state it explicitly; memory gates must read the cgroup limit
    env_file:
      - path: ${HOME}/.config/agent-containers/${PROJECT:-project-template}.env   # written by ./resolve-secrets (mode 600)
        required: true
    environment:
      CLAUDE_CONFIG_DIR: /home/agent/.claude
    volumes:
      - ./:/workspace
      - claude-config:/home/agent/.claude
      - require-cache:/home/agent/.cache/R/Require
      - ./allowlist.txt:/etc/firewall/allowlist.d/50-project.txt:ro
      - ${SPADES_AI_DIR:-${HOME}/GitHub/spades.ai}:/opt/reference/spades.ai   # personal conventions, live (rw). MUST exist on the host first, or Docker creates a root-owned empty dir
      # - uv-cache:/home/agent/.cache/uv  # OPTIONAL: shared uv cache for reticulate::py_require() (spec §3.4)
      # - ${MEMORY_DIR}:/opt/memory        # RESERVED: future memory repo (spec §2)
    command: >
      bash -c "sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/agent-init.sh && exec sleep infinity"
    # ports: ["127.0.0.1:3100:3100"]       # if ever needed: localhost ONLY
volumes:
  claude-config:
    name: claude-${PROJECT:-project-template}    # FIXED name: survives rebuilds
  require-cache:
    name: require-cache-shared                   # shared across all SpaDES projects
    external: true
```

- [ ] **Step 4: Write the host helpers**

`project-template/resolve-secrets`:
```bash
#!/usr/bin/env bash
# HOST ONLY. Resolves op:// references in project.env into ~/.config/agent-containers/<project>.env
# (mode 600, outside any repo). Needs OP_SERVICE_ACCOUNT_TOKEN for THIS project's service account
# in the host environment (from your keychain/shell profile) — never in the repo.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="${PROJECT:-$(basename "$PWD")}"
out="$HOME/.config/agent-containers/$PROJECT.env"
mkdir -p "$(dirname "$out")"; umask 077
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || { echo "resolve-secrets: OP_SERVICE_ACCOUNT_TOKEN not set (see docs/runbooks/1password-project-vault.md)"; exit 1; }
op inject --force -i project.env -o "$out"
chmod 600 "$out"
echo "resolve-secrets: wrote $(grep -c = "$out") value(s) to $out"
```

`project-template/up`:
```bash
#!/usr/bin/env bash
# HOST ONLY. Resolve secrets, then (re)create the container so it picks up current env.
set -euo pipefail
cd "$(dirname "$0")"
export PROJECT="${PROJECT:-$(basename "$PWD")}"
./resolve-secrets
docker volume inspect require-cache-shared >/dev/null 2>&1 || docker volume create require-cache-shared >/dev/null
docker compose -p "$PROJECT" up -d --force-recreate
echo "up: '$PROJECT' running. Attach: docker exec -it -u agent ${PROJECT}-agent-1 zsh   (or VS Code: Reopen in Container)"
```

- [ ] **Step 5: Write the rest of the template**

`project-template/project.env`:
```
# op:// REFERENCES ONLY — committable. Resolved on the host by ./resolve-secrets.
# Tier A only (spec §5): scoped, revocable. Vault = agent-<project>.
GH_TOKEN=op://agent-PROJECTNAME/github-agent/token
```

`project-template/allowlist.txt`:
```
# Domains THIS project needs beyond the base allowlist (agent-containers images/base/allowlist.d/00-base.txt).
# One per line; a base domain also matches its subdomains. Restart the container after editing.
```

`project-template/.devcontainer/devcontainer.json`:
```jsonc
{
  // VS Code "Reopen in Container": runs ./resolve-secrets on the host first, then uses compose.yaml.
  "name": "${localWorkspaceFolderBasename}",
  "initializeCommand": "PROJECT=${localWorkspaceFolderBasename} ./resolve-secrets",
  "dockerComposeFile": ["../compose.yaml"],
  "service": "agent",
  "workspaceFolder": "/workspace",
  "remoteUser": "agent",
  "overrideCommand": false,
  "shutdownAction": "none",
  "customizations": { "vscode": { "extensions": ["anthropic.claude-code", "eamodio.gitlens"] } }
}
```

`project-template/.gitignore`:
```
*.env.resolved
*.secret
.env
```

`project-template/.pre-commit-config.yaml` (secret scanner, spec §5 guard; enable once per clone with `pre-commit install` on the host):
```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
```
Before committing, confirm the pin: `gh api repos/gitleaks/gitleaks/releases/latest --jq .tag_name`, and use that tag if newer.

`project-template/README.md`: the lifecycle table from spec §4, plus "Never run plain `docker compose up`: use `./up`, so secrets are current."

- [ ] **Step 6: Push; verify it passes** (`TEMPLATE: ALL PASSED`).

- [ ] **Step 7: Hand the PR to the user to merge.**

---

### Task 6: Acceptance — a minimal SpaDES project runs in `spades-gis` behind the firewall

**Files:**
- Create: `tests/acceptance/minimal-project/global.R`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `spades-gis:ci` (Task 4), the firewall (Task 2).

- [ ] **Step 1: Write the acceptance project** — `tests/acceptance/minimal-project/global.R`

```r
# Acceptance: setupProject(standAlone = TRUE) provisions SpaDES.core + terra from binaries behind
# the firewall, then a trivial simInit + a terra read work. Run with PLAIN Rscript from this folder.
Require::setupOff()
options(pkgType = "both",
        repos = c(PredictiveEcology = "https://predictiveecology.r-universe.dev",
                  CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest"))
out <- SpaDES.project::setupProject(
  paths = list(projectPath = getwd()),
  standAlone = TRUE,
  packages = c("terra", "SpaDES.core"),
  updateRprofile = TRUE)
f <- tempfile(fileext = ".tif")
r <- terra::rast(nrows = 2, ncols = 2, vals = 1:4); terra::writeRaster(r, f)
stopifnot(terra::global(terra::rast(f), "sum")[[1]] == 10)
sim <- SpaDES.core::simInit(times = list(start = 0, end = 1))
stopifnot(inherits(sim, "simList"))
cat("ACCEPTANCE: PASSED\n")
```

- [ ] **Step 2: Add the CI step** (append)

```yaml
      - name: Acceptance (setupProject behind firewall, plain Rscript)
        run: |
          docker run -d --name acc --cap-add NET_ADMIN --cap-add NET_RAW \
            -v "$PWD/tests/acceptance/minimal-project:/workspace" spades-gis:ci sleep infinity
          docker exec acc sudo /usr/local/bin/init-firewall.sh
          docker exec -u agent -w /workspace acc Rscript global.R
          docker exec -u agent -w /workspace acc Rscript -e 'library(SpaDES.core); cat("second run OK\n")'
          docker rm -f acc
```

- [ ] **Step 3: Push; run.** Expected: `ACCEPTANCE: PASSED`, then `second run OK`. The second plain `Rscript` reads the `.Rprofile` setupProject wrote, which proves child processes see the project library.
  - If an install fails with a connection error: add the missing host to `00-base.txt` (with a comment saying why). **Do not** add flags (`--vanilla`, `--no-init-file`) or `R_LIBS` overrides. Those are the setup workarounds that cost 57 h in August; if the fix isn't obviously an allowlist entry, stop and ask the user.

- [ ] **Step 4: Hand the PR to the user to merge.**

---

### Task 7: Publish to GHCR, `digests.md` PR, weekly rebuild

**Files:**
- Create: `.github/workflows/publish.yml`, `digests.md`

**Interfaces:**
- Produces: public images `ghcr.io/allenlarocque/spades-{base,gis}:<YYYY.MM.DD>-<sha7>` (+ `latest`), and a PR updating `digests.md`, which projects copy into `compose.yaml`.

- [ ] **Step 1: Write `digests.md`**

```markdown
# Image digests

Copy a digest into a project's `compose.yaml` (`image: ghcr.io/allenlarocque/spades-gis@sha256:…`).
Updated by the `publish` workflow via PR — never edit by hand.

| image | tag | digest |
|---|---|---|
```

- [ ] **Step 2: Write `.github/workflows/publish.yml`**

```yaml
name: publish
on:
  push:
    branches: [main]
    paths: ["images/**"]
  schedule:
    - cron: "17 9 * * 1"        # Mondays: rebuild for OS security patches -> digest PR
  workflow_dispatch:
permissions:
  contents: write
  packages: write
  pull-requests: write
jobs:
  publish:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with: { registry: ghcr.io, username: "${{ github.actor }}", password: "${{ secrets.GITHUB_TOKEN }}" }
      - id: tag
        run: echo "tag=$(date -u +%Y.%m.%d)-${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"
      - name: Build + push base
        id: base
        run: |
          ref=ghcr.io/allenlarocque/spades-base:${{ steps.tag.outputs.tag }}
          docker buildx build --pull --no-cache --push -t "$ref" -t ghcr.io/allenlarocque/spades-base:latest images/base
          echo "digest=$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest.Digest}}' | tr -d '"')" >> "$GITHUB_OUTPUT"
      - name: Build + push gis
        id: gis
        run: |
          ref=ghcr.io/allenlarocque/spades-gis:${{ steps.tag.outputs.tag }}
          docker buildx build --push --build-arg BASE_IMAGE=ghcr.io/allenlarocque/spades-base@${{ steps.base.outputs.digest }} \
            -t "$ref" -t ghcr.io/allenlarocque/spades-gis:latest images/gis
          echo "digest=$(docker buildx imagetools inspect "$ref" --format '{{json .Manifest.Digest}}' | tr -d '"')" >> "$GITHUB_OUTPUT"
      - name: Update digests.md
        run: |
          {
            printf '# Image digests\n\nCopy a digest into a project'"'"'s `compose.yaml`. Updated by the `publish` workflow via PR — never edit by hand.\n\n'
            printf '| image | tag | digest |\n|---|---|---|\n'
            printf '| spades-base | %s | `%s` |\n' "${{ steps.tag.outputs.tag }}" "${{ steps.base.outputs.digest }}"
            printf '| spades-gis | %s | `%s` |\n' "${{ steps.tag.outputs.tag }}" "${{ steps.gis.outputs.digest }}"
          } > digests.md
      - uses: peter-evans/create-pull-request@v7
        with:
          branch: chore/digests-${{ steps.tag.outputs.tag }}
          title: "chore: image digests ${{ steps.tag.outputs.tag }}"
          commit-message: "chore: image digests ${{ steps.tag.outputs.tag }}"
          body: "Published by the `publish` workflow. Merge, then bump projects when convenient."
```

- [ ] **Step 3: Merge (user), then verify**

Run: `gh run watch` on the publish run; `gh pr list` shows `chore: image digests …`.
Expected: images pushed. **One-time manual step (user):** on GitHub → Packages → each of `spades-base` and `spades-gis` → Package settings → Change visibility → **Public**. Then on the host, `docker pull ghcr.io/allenlarocque/spades-gis@<digest>` without logging in succeeds.

---

### Task 8: Runbooks — machine user, rulesets, 1Password project vault, new project

**Files:**
- Create: `docs/runbooks/machine-user-and-rulesets.md`, `docs/runbooks/1password-project-vault.md`, `docs/runbooks/new-project.md`

These are **human** procedures (the agent cannot and must not perform them). The task deliverable is the documents plus the user running the verification checklist.

- [ ] **Step 1: Write `docs/runbooks/machine-user-and-rulesets.md`** with exactly these steps:
  1. Create a GitHub account for the agent (e.g. `allen-agent`) with a separate email, and enable 2FA (store its recovery codes in your Private 1Password vault: tier C).
  2. On each repo the agent works on: Settings → Collaborators → add `allen-agent` with role **Write** (not Maintain, not Admin).
  3. Signed in **as `allen-agent`**: Settings → Developer settings → Fine-grained tokens → new token: Resource owner = your account; Repository access = only the project's repos; Permissions = Contents **Read and write**, Pull requests **Read and write**, Metadata Read; expiry 90 days. Save it to 1Password vault `agent-<project>`, item `github-agent`, field `token`.
  4. On each repo (as **you**): Settings → Rules → Rulesets → New branch ruleset "protect-main", target `main`, enforcement Active, **bypass list empty**. Rules:
     - Restrict deletions; Block force pushes;
     - Require a pull request before merging: **1 required approval**;
     - Require status checks to pass: `build-test`.
  5. **Verify (required):** in the project container, `gh pr create` from a branch works. `gh pr merge` **fails** ("required approval"). You approve and merge from your own account.
- [ ] **Step 2: Write `docs/runbooks/1password-project-vault.md`**:
  1. Create vault `agent-<project>`.
  2. Developer → Service accounts → new account `agent-<project>`, access **read-only to that vault only**.
  3. Store its token in your host keychain or shell profile as `OP_SERVICE_ACCOUNT_TOKEN` for that project. Never in a repo.
  4. Tier B items (ENA, Zenodo) go in vault `human-actions`, which **no** service account can access; you use them with your own `op` session on the host.
  5. Rotation and revocation: delete or regenerate the service account token in one click; then `./up`.
- [ ] **Step 3: Write `docs/runbooks/new-project.md`**:
  1. `cp -r agent-containers/project-template/. <project>/`;
  2. set the image digest from `digests.md`;
  3. replace `PROJECTNAME` in `project.env`;
  4. run the vault runbook;
  5. run the machine-user runbook for the project repo;
  6. fill `allowlist.txt`;
  7. clone `spades.ai` to `~/GitHub/spades.ai` (or set `SPADES_AI_DIR`);
  8. `./up`;
  9. in the container: `claude`, then `Rscript -e 'SpaDES.project::setupProject(...)'` as usual.
- [ ] **Step 4: Commit, open the PR; the user merges after running the Step 1.5 verification on this repo.**

---

### Task 9: `spades-bio` image + smoke test + publish

**Files:**
- Create: `images/bio/Dockerfile`, `tests/smoke/bio.sh`, `project-template/allowlist.bio-example.txt`
- Modify: `.github/workflows/ci.yml`, `.github/workflows/publish.yml`

- [ ] **Step 1: Write the failing smoke test** — `tests/smoke/bio.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
fail=0
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "OK:   $d"; else echo "FAIL: $d"; fail=1; fi; }
check "inherits base smoke"   bash /tests/smoke/base.sh
check "mafft"                 bash -c 'mafft --version 2>&1 | grep -q v7'
check "cutadapt"              cutadapt --version
check "fasttree"              bash -c 'fasttree 2>&1 | grep -qi fasttree'
check "glpk + magick headers" bash -c 'dpkg -s libglpk-dev libmagick++-dev'
check "sklearn env 1.9.0"     bash -c '/opt/conda/envs/sklearn/bin/python -c "import sklearn; assert sklearn.__version__.startswith(\"1.9\")"'
check "picrust2 env"          bash -c 'test -x /opt/conda/envs/picrust2/bin/picrust2_pipeline.py'
[ "$fail" -eq 0 ] && echo "SMOKE bio: ALL PASSED" || { echo "SMOKE bio: FAILURES"; exit 1; }
```

CI steps (append): build `spades-bio:ci` with `--build-arg BASE_IMAGE=spades-base:ci images/bio`; run `tests/smoke/bio.sh`.

- [ ] **Step 2: Push; verify it fails.**

- [ ] **Step 3: Write `images/bio/Dockerfile`**

```dockerfile
# spades-bio: amplicon bioinformatics on top of base. Spec §3.3.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-base:latest
FROM ${BASE_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      cutadapt fasttree mafft libglpk-dev libmagick++-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# Miniforge + PINNED envs. Python for reticulate is baked here; modules must state the
# interpreter explicitly (reticulate otherwise silently binds a bare uv Python). Spec §3.4.
ENV CONDA_DIR=/opt/conda
RUN curl -fsSL "https://github.com/conda-forge/miniforge/releases/download/26.7.2-0/Miniforge3-Linux-x86_64.sh" -o /tmp/mf.sh \
    && bash /tmp/mf.sh -b -p "$CONDA_DIR" && rm /tmp/mf.sh \
    && "$CONDA_DIR/bin/conda" create -y -n picrust2 -c conda-forge -c bioconda picrust2=2.5.2 \
    && "$CONDA_DIR/bin/conda" create -y -n sklearn -c conda-forge python=3.12 scikit-learn=1.9.0 joblib numpy scipy biopython \
    && "$CONDA_DIR/bin/conda" clean -afy && chmod -R a+rX "$CONDA_DIR"
USER agent
```

`project-template/allowlist.bio-example.txt`: the amplicon-specific hosts moved out of base, with their comments copied from `spades-dev-environment/.devcontainer/init-firewall.sh`:
`mycoportal.org`, `stbates.org`, `doi.org`, `unite.ut.ee`, `plutof.ut.ee`, `s3.hpc.ut.ee`, `www2.decipher.codes`, `arb-silva.de`, `zenodo.org`, `pypi.org`, `files.pythonhosted.org`, `conda.anaconda.org`, `repo.anaconda.com`, `anaconda.org`, `qiime2.org`, `s3-us-west-2.amazonaws.com`, `qiime2-data.s3.us-west-2.amazonaws.com`, `drive.google.com`, `drive.usercontent.google.com`, `www.googleapis.com`, `oauth2.googleapis.com`, `accounts.google.com`.

- [ ] **Step 4: Add bio to `publish.yml`:** a "Build + push bio" step mirroring "Build + push gis", with `images/bio` and the `spades-bio` names, plus a `spades-bio` row in the digests table.

- [ ] **Step 5: Push; verify CI passes; hand the PR to the user to merge.**

---

### Task 10: Close out Phase 1

- [ ] **Step 1:** In the spec, record the two deviations from this plan's header under a new "§13 Changes during implementation".
- [ ] **Step 2:** Tick spec §11 acceptance items against the evidence: CI runs, the published digests, the runbook verification.
- [ ] **Step 3:** Open the PR; the user merges.

**Out of scope here (separate plan later):** moving `spades_bioinformatics` from `spades-dev-environment` to `spades-bio` + the template (needs a cheap smoke run of that pipeline), then archiving `spades-dev-environment`.
