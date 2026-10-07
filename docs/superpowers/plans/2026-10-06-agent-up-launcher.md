# agent-up launcher (spec §4 rework) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the in-folder project template (overlays, checksums, `--adopt`, `.env` scrubbing,
devcontainer) with an external launcher, `bin/agent-up`, and per-project config in
`~/.config/agent-containers/<project>/`. Apply the spec's 2026-10-06 decisions B (no non-essential
Claude traffic) and "interim shared memory", and move secret scanning to CI.

**Architecture:**
- `bin/agent-up` (bash) lives in the owner's agent-containers clone.
- `agent-up init` copies seeds from `project-template/config/` into the owner's config dir, and the
  repo files from `project-template/repo/` into the project.
- `agent-up up` runs `op run --env-file <cfg>/project.env -- docker compose --env-file
  <cfg>/project.conf -f <cfg>/compose.yaml -f <cfg>/.generated/env-passthrough.yaml
  --project-directory <cfg> -p <project> up -d --force-recreate`.
- **Nothing in the project folder is ever executed or read as configuration by the host.**
- Tests are one bash script: a stub `op` and a stub `docker` for the lifecycle, the REAL
  `docker compose config` for rendering, and a behavioural section against the CI-built image.

**Tech Stack:** bash, Docker Compose v2, 1Password CLI (`op run`, host only; stubbed in tests),
jq, GitHub Actions, gitleaks (container image).

**Spec:** `docs/specs/2026-10-03-agent-containers-design.md`. The amended §2, §2.1, §4, §12 and
§13 are what this plan implements.

## Global Constraints

- **Design rule (spec §2.1):** nothing the agent can write is ever executed or interpreted by the
  host. `agent-up` reads only `~/.config/agent-containers/<project>/` (override:
  `AGENT_CONTAINERS_CONFIG`) and its own seeds; never a file in the project folder.
- Config root mode **700**; each project config dir mode **700**; files in it mode **600**.
- `project.env` holds **`KEY=op://...` references only**. `agent-up` refuses anything else and
  never prints a refused line's content (it might be a pasted secret), only line numbers.
- Secret **values never touch disk.** `op run` puts them in the environment of `docker compose`
  only. The generated `.generated/env-passthrough.yaml` holds key **names** only.
- Image pinned by digest: `image: <repo>@sha256:<64 hex>`. The seed carries the placeholder
  `REPLACE_WITH_DIGEST_FROM_digests.md`.
- Volumes: `claude-<project>` → `/home/agent/.claude`; `rlib-<project>` →
  `/home/agent/.local/share/R`; external `require-cache-shared` → `/home/agent/.cache/R/Require`.
- Mounts (builder profile):
  - `PROJECT_DIR` → `/workspace` (rw);
  - `<cfg>/allowlist` → `/etc/firewall/allowlist.d/50-project.txt` (**ro**);
  - `SPADES_AI_DIR` → `/opt/reference/spades.ai` (rw);
  - `AGENT_MEMORY_DIR` → `/opt/memory` (rw);
  - all binds use `create_host_path: false`.
- No rw bind source may contain the config dir.
- Defaults recorded in `project.conf`: `SPADES_AI_DIR=$HOME/GitHub/spades.ai`,
  `AGENT_MEMORY_DIR=$HOME/agent-memory`.
- **Decision B:** remove `sentry.io` and `statsig.com` from
  `images/base/allowlist.d/00-base.txt`, and set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"`
  in the compose seed. Any value, even `0`, disables, so the README says to *delete* the line to
  re-enable.
- **Decision C:** `release-assets.githubusercontent.com` stays in base.
- `--profile research` is refused with a message naming Phase 1b. Only `builder` is built.
- T3 seams (spec §13.1) are **commented** reservations in the compose seed only: `t3-<project>`
  volume, `127.0.0.1:3773` port, firewall INPUT note.
- Secret scanning: gitleaks **`v8.30.1`** as a CI job, image `ghcr.io/gitleaks/gitleaks:v8.30.1`,
  run with `-u "$(id -u):$(id -g)"`. No host pre-commit hook.
- No Docker inside the agent's own dev container: **all docker-dependent verification happens in
  CI.** Locally, the test script skips render/behavioural sections when `docker compose` is
  missing. Push and read CI.
- One branch, `feat/phase1`, one PR (#3). Commit per task. **Agents never merge.**
- The commit trailer on every commit:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

---

## File structure

```
bin/
  agent-up                                   CREATE  host launcher (init|up|config|shell|status|stop|down)
project-template/
  README.md                                  REWRITE owner guide for agent-up
  config/                                    CREATE  seeds copied to ~/.config/agent-containers/<project>/
    compose.yaml                             (moved from project-template/compose.yaml, rewritten)
    project.env                              (moved, header rewritten)
    allowlist                                (moved from allowlist.txt, header rewritten)
    allowlist.bio-example                    (moved from allowlist.bio-example.txt, header rewritten)
  repo/                                      CREATE  seeds copied into the PROJECT repo (never overwrite)
    .github/CODEOWNERS                       (moved)
    .github/workflows/gitleaks.yml           CREATE (Task 4)
    .gitignore                               (moved)
  up, resolve-secrets, check-digest,         DELETE
  .devcontainer/, .pre-commit-config.yaml    DELETE
tests/
  launcher/test-agent-up.sh                  CREATE  replaces tests/template/test-template.sh
  template/test-template.sh                  DELETE
images/base/allowlist.d/00-base.txt          MODIFY  (Task 3: drop sentry.io, statsig.com)
images/base/configure-claude-settings.js     MODIFY  (Task 5: stale comment)
.github/workflows/ci.yml                     MODIFY  (Tasks 1, 4)
docs/runbooks/new-project.md                 REWRITE (Task 5)
docs/runbooks/1password-project-vault.md     MODIFY  (Task 5)
docs/runbooks/machine-user-and-rulesets.md   MODIFY  (Task 5)
README.md                                    MODIFY  (Task 5)
```

---

### Task 1: Seeds layout + `agent-up init`

**Files:**
- Create: `bin/agent-up`
- Create: `project-template/config/compose.yaml`, `project-template/config/project.env`,
  `project-template/config/allowlist`, `project-template/config/allowlist.bio-example`
- Move: `project-template/.github/CODEOWNERS` → `project-template/repo/.github/CODEOWNERS`;
  `project-template/.gitignore` → `project-template/repo/.gitignore`
- Delete: `project-template/{compose.yaml,project.env,allowlist.txt,allowlist.bio-example.txt,up,resolve-secrets,check-digest,.pre-commit-config.yaml}`,
  `project-template/.devcontainer/`, `tests/template/test-template.sh`
- Create: `tests/launcher/test-agent-up.sh`
- Modify: `.github/workflows/ci.yml` (template test step, bio allowlist path, shellcheck list)

**Interfaces:**
- Produces:
  - CLI `agent-up init <project-dir> [--name NAME] [--image base|gis|bio] [--profile builder]`;
  - the config dir `$CFG_ROOT/<name>/` with `compose.yaml`, `project.env`, `allowlist`,
    `project.conf`;
  - `project.conf` keys `PROJECT`, `PROJECT_DIR`, `PROFILE`, `IMAGE`, `SPADES_AI_DIR`,
    `AGENT_MEMORY_DIR`;
  - bash helpers in `agent-up`: `die`, `usage`, `normalise <str>`, `conf_get <file> <KEY>`;
  - variables `HERE`, `SEEDS`, `CFG_ROOT`.
- Test helpers in `tests/launcher/test-agent-up.sh`, used by Tasks 2–4:
  - `check`, `refuses`;
  - `au` (stub op/docker on PATH, fake HOME) and `aureal` (real docker, fake HOME);
  - variables `T`, `H`, `CFGROOT`, `P`, `NAME`, `CFG`, `OPLOG`, `DLOG`, `TOK`, `AMBIENT`, `H64`;
  - the marker line `# ---- END OF SECTIONS (later tasks insert above this line)`.

- [ ] **Step 1: Create the seeds (moves first, so history follows the files)**

```bash
cd /workspace/projects/agent-containers
mkdir -p project-template/config project-template/repo/.github bin tests/launcher
git mv project-template/compose.yaml project-template/config/compose.yaml
git mv project-template/project.env project-template/config/project.env
git mv project-template/allowlist.txt project-template/config/allowlist
git mv project-template/allowlist.bio-example.txt project-template/config/allowlist.bio-example
git mv project-template/.github/CODEOWNERS project-template/repo/.github/CODEOWNERS
git mv project-template/.gitignore project-template/repo/.gitignore
git rm -q -r project-template/up project-template/resolve-secrets project-template/check-digest \
  project-template/.pre-commit-config.yaml project-template/.devcontainer tests/template/test-template.sh
```

Write `project-template/config/compose.yaml` (full replacement):

```yaml
# agent-containers: per-project compose file (spec §4, amended 2026-10-06).
# It lives in ~/.config/agent-containers/<project>/, OUTSIDE the project folder, and is started only
# by `agent-up up <project>`. Owner-edited. Interpolation variables come from project.conf (agent-up
# passes it as --env-file). Secret NAMES come from project.env via the generated
# .generated/env-passthrough.yaml; secret VALUES exist only in the environment of `op run`.
name: ${PROJECT:?set PROJECT in project.conf}
services:
  agent:
    image: ghcr.io/allenlarocque/spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md
    user: "1000:1000"
    working_dir: /workspace
    init: true
    cap_add: [NET_ADMIN, NET_RAW]          # firewall
    mem_limit: 100g                        # state it explicitly; memory gates must read the cgroup limit
    environment:
      CLAUDE_CONFIG_DIR: /home/agent/.claude
      # Spec §12 decision B. ANY value disables (even "0"): delete the line to re-enable.
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1"
    volumes:
      - type: bind                         # the project: the agent's read-write workspace
        source: ${PROJECT_DIR:?set PROJECT_DIR in project.conf}
        target: /workspace
        bind: {create_host_path: false}
      - claude-config:/home/agent/.claude
      - require-cache:/home/agent/.cache/R/Require
      - rlib:/home/agent/.local/share/R     # setupProject standAlone library: persists across `agent-up up`
      - type: bind                         # project allowlist: owner-maintained in THIS config dir
        source: ./allowlist
        target: /etc/firewall/allowlist.d/50-project.txt
        read_only: true
        bind: {create_host_path: false}
      - type: bind                         # personal conventions, live (rw for builders)
        source: ${SPADES_AI_DIR:?set SPADES_AI_DIR in project.conf}
        target: /opt/reference/spades.ai
        bind: {create_host_path: false}
      - type: bind                         # shared agent memory (spec §13.2; rw for builders)
        source: ${AGENT_MEMORY_DIR:?set AGENT_MEMORY_DIR in project.conf}
        target: /opt/memory
        bind: {create_host_path: false}
      # - uv-cache:/home/agent/.cache/uv  # OPTIONAL: shared uv cache for reticulate::py_require() (spec §3.4)
      # - t3:/home/agent/.t3              # RESERVED Phase 2: T3 Code state (spec §13.1)
    command: >
      bash -c "sudo /usr/local/bin/init-firewall.sh && /usr/local/bin/agent-init.sh && exec sleep infinity"
    # RESERVED Phase 2 (T3 Code, spec §13.1). Localhost ONLY, and the firewall needs a matching INPUT
    # rule (INPUT is default-DROP; see the note in images/base/init-firewall.sh):
    # ports: ["127.0.0.1:3773:3773"]
volumes:
  claude-config:
    name: claude-${PROJECT}                # FIXED name: survives rebuilds
  rlib:
    name: rlib-${PROJECT}                  # FIXED name, per project
  require-cache:
    name: require-cache-shared             # shared across all SpaDES projects
    external: true
  # t3:
  #   name: t3-${PROJECT}                  # RESERVED Phase 2
```

Write `project-template/config/project.env`:

```
# op:// REFERENCES ONLY: agent-up refuses any other value. Lives in ~/.config/agent-containers/<project>/.
# Tier A only (spec §5): scoped, revocable. Vault = agent-<project>.
# Each KEY is passed into the container; `op run` resolves the values at `agent-up up`.
GH_TOKEN=op://agent-PROJECTNAME/github-agent/token
```

Write `project-template/config/allowlist`:

```
# Project allowlist: domains THIS project needs beyond the base list
# (agent-containers images/base/allowlist.d/00-base.txt). Owner-maintained in
# ~/.config/agent-containers/<project>/, outside the project folder; mounted read-only into the
# container. Edit it, then run `agent-up up <project>`.
# One domain per line; a domain also matches its subdomains; `#` comments allowed. Names not
# listed do not even resolve. SSH to your own servers (cloud VM, NAS) needs their domain here too.
```

In `project-template/config/allowlist.bio-example`, replace ONLY line 1 with:

```
# Amplicon (spades-bio) domains. `agent-up init --image bio` appends this file to the project allowlist.
```

- [ ] **Step 2: Write the failing test (init section + shared harness)**

Create `tests/launcher/test-agent-up.sh`:

```bash
#!/usr/bin/env bash
# Tests for bin/agent-up (spec §4, amended 2026-10-06). No real secrets: `op` and (for lifecycle
# commands) `docker` are stubs that record how they were called. Rendering checks use the REAL
# `docker compose config`. With TEMPLATE_IMAGE set (CI), a behavioural section starts the rendered
# sandbox against that built image.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AU="$ROOT/bin/agent-up"
REAL_HOME="$HOME"
fail=0
check(){ # $1 label, rest = command that must succeed
  local d="$1" o; shift
  if o=$("$@" 2>&1); then echo "OK:   $d"; else echo "FAIL: $d"; printf '%s\n' "$o" | sed 's/^/        /'; fail=1; fi
}
refuses(){ # $1 label, $2 ERE the message must match, rest = command that must FAIL
  local d="$1" re="$2" rc=0 msg; shift 2
  msg=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq -- "$re" <<<"$msg"; then echo "OK:   $d"
  else echo "FAIL: $d (rc=$rc, want non-zero and /$re/)"; printf '%s\n' "$msg" | sed 's/^/        /'; fail=1; fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/home"; CFGROOT="$H/.config/agent-containers"
mkdir -p "$H/GitHub/spades.ai" "$T/bin" "$T/dstub"
OPLOG="$T/op.log"; DLOG="$T/docker.log"
H64=$(printf 'a%.0s' $(seq 64))
TOK=""        # fake service-account token; empty = unset for agent-up
AMBIENT=()    # extra (hostile) environment for a call

# stub op: `op run --env-file F -- CMD...` -> log, then exec CMD with a fake resolved secret
cat > "$T/bin/op" <<'STUB'
#!/usr/bin/env bash
echo "OP: $*" >> "$OPLOG"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
GH_TOKEN=fake-secret-value-123 exec "$@"
STUB
# stub docker: log the arguments and the environment that matters, succeed
cat > "$T/dstub/docker" <<'STUB'
#!/usr/bin/env bash
{ echo "ARGS: $*"
  echo "ENV: COMPOSE_FILE=${COMPOSE_FILE-<unset>} COMPOSE_PROFILES=${COMPOSE_PROFILES-<unset>} PROJECT_DIR=${PROJECT_DIR-<unset>} SPADES_AI_DIR=${SPADES_AI_DIR-<unset>} GH_TOKEN=${GH_TOKEN-<unset>}"
} >> "$DLOG"
exit 0
STUB
chmod +x "$T/bin/op" "$T/dstub/docker"

# au: agent-up with a fake HOME, stub op + stub docker first on PATH, and only the token we choose
au(){ env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" OPLOG="$OPLOG" DLOG="$DLOG" PATH="$T/dstub:$T/bin:$PATH" \
        ${TOK:+OP_SERVICE_ACCOUNT_TOKEN="$TOK"} "${AMBIENT[@]}" "$AU" "$@"; }
# aureal: agent-up with the fake HOME and the REAL docker CLI (for `config` rendering)
aureal(){ env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" DOCKER_CONFIG="$REAL_HOME/.docker" "${AMBIENT[@]}" "$AU" "$@"; }

P="$T/Demo.Proj"; mkdir -p "$P"; git -C "$P" init -q
NAME=demo-proj; CFG="$CFGROOT/$NAME"

# ---- init
check "agent-up parses" bash -n "$AU"
refuses "no arguments prints usage" 'usage:' au
refuses "init refuses a missing project dir" 'project directory not found' au init "$T/nope"
refuses "init refuses --profile research (Phase 1b)" 'Phase 1b' au init "$P" --profile research
refuses "init refuses an unknown image" 'base, gis or bio' au init "$P" --image foo
check "init succeeds" au init "$P"
check "config dir named by the normalised project name" test -d "$CFG"
check "config root mode 700" test "$(stat -c %a "$CFGROOT")" = 700
check "config dir mode 700" test "$(stat -c %a "$CFG")" = 700
for f in compose.yaml project.env allowlist project.conf; do
  check "init wrote $f (mode 600)" test "$(stat -c %a "$CFG/$f")" = 600
done
check "project.conf: absolute PROJECT_DIR" grep -qx "PROJECT_DIR=$(cd "$P" && pwd -P)" "$CFG/project.conf"
check "project.conf: PROJECT, PROFILE, IMAGE" \
  bash -c 'grep -qx "PROJECT=demo-proj" "$1" && grep -qx "PROFILE=builder" "$1" && grep -qx "IMAGE=gis" "$1"' _ "$CFG/project.conf"
check "project.conf: SPADES_AI_DIR and AGENT_MEMORY_DIR defaults" \
  bash -c 'grep -qx "SPADES_AI_DIR=$2/GitHub/spades.ai" "$1" && grep -qx "AGENT_MEMORY_DIR=$2/agent-memory" "$1"' _ "$CFG/project.conf" "$H"
check "project.env names this project's vault" grep -q "op://agent-$NAME/github-agent/token" "$CFG/project.env"
check "compose uses spades-gis by default, digest placeholder kept" \
  grep -q "spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md" "$CFG/compose.yaml"
check "repo seed CODEOWNERS copied into the project" grep -q "^\* @OWNER" "$P/.github/CODEOWNERS"
check "repo seed .gitignore copied into the project" test -f "$P/.gitignore"
check "no launcher, compose or env file written into the project" \
  bash -c '! ls -A "$1" | grep -Eqx "compose\.ya?ml|docker-compose\.ya?ml|up|\.env|\.devcontainer|project\.(env|conf)|allowlist"' _ "$P"
check "shared agent memory created as a git repo" test -d "$H/agent-memory/.git"
refuses "init never overwrites an existing config" 'already exists' au init "$P"
P2="$T/other"; mkdir -p "$P2/.github"; echo "* @me" > "$P2/.github/CODEOWNERS"
check "init --image bio --name Bio2" au init "$P2" --image bio --name Bio2
check "  ...existing CODEOWNERS kept" grep -qx '\* @me' "$P2/.github/CODEOWNERS"
check "  ...compose uses spades-bio" grep -q "spades-bio@sha256:" "$CFGROOT/bio2/compose.yaml"
check "  ...bio domains appended to the allowlist" grep -qx "mycoportal.org" "$CFGROOT/bio2/allowlist"

# ---- END OF SECTIONS (later tasks insert above this line)
[ "$fail" -eq 0 ] && echo "LAUNCHER: ALL PASSED" || { echo "LAUNCHER: FAILURES"; exit 1; }
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `bash tests/launcher/test-agent-up.sh`
Expected: `FAIL: agent-up parses` (no `bin/agent-up` yet), many FAILs, final line
`LAUNCHER: FAILURES`, exit 1.

- [ ] **Step 4: Write the minimal implementation**

Create `bin/agent-up` and `chmod +x bin/agent-up`:

```bash
#!/usr/bin/env bash
# agent-up: the HOST-side launcher for agent containers (spec §4, amended 2026-10-06).
# It lives in the owner's agent-containers clone; symlink it onto your PATH if you like.
# It reads ONLY the owner's config dir, ~/.config/agent-containers/<project>/, plus its own seeds.
# It NEVER executes or reads configuration from the project folder (the agent's rw workspace).
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SEEDS="$HERE/../project-template"
CFG_ROOT="${AGENT_CONTAINERS_CONFIG:-$HOME/.config/agent-containers}"

die(){ printf 'agent-up: %s\n' "$*" >&2; exit 1; }
usage(){
  cat >&2 <<'EOF'
usage:
  agent-up init <project-dir> [--name NAME] [--image base|gis|bio] [--profile builder]
  agent-up up <project>                  resolve secrets with `op run`, (re)create the container
  agent-up config <project> [ARGS...]    print the rendered compose config (no secrets needed)
  agent-up shell <project>               zsh in the container as `agent`
  agent-up status|stop|down <project>
EOF
  exit 2
}
normalise(){ printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g'; }
conf_get(){ sed -n "s/^$2=//p" "$1" | tail -n 1; }   # $1 project.conf, $2 KEY

cmd_init(){
  local dir="" name="" image="gis" profile="builder"
  while [ $# -gt 0 ]; do
    case "$1" in
      --name)    [ $# -ge 2 ] || usage; name="$2"; shift 2 ;;
      --image)   [ $# -ge 2 ] || usage; image="$2"; shift 2 ;;
      --profile) [ $# -ge 2 ] || usage; profile="$2"; shift 2 ;;
      -*) usage ;;
      *) [ -z "$dir" ] || usage; dir="$1"; shift ;;
    esac
  done
  [ -n "$dir" ] || usage
  [ -d "$dir" ] || die "project directory not found: $dir"
  dir="$(cd "$dir" && pwd -P)"
  case "$image" in base|gis|bio) ;; *) die "--image must be base, gis or bio (got: $image)" ;; esac
  case "$profile" in
    builder) ;;
    research) die "--profile research is not built yet (spec §2: Phase 1b)" ;;
    *) die "--profile must be builder (got: $profile)" ;;
  esac
  name="$(normalise "${name:-$(basename "$dir")}")"
  [ -n "$name" ] || die "could not derive a project name from '$dir'; pass --name"
  local cfg="$CFG_ROOT/$name"
  { [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; } || die "config already exists: $cfg (edit it there; init never overwrites)"

  mkdir -p "$CFG_ROOT"; chmod 700 "$CFG_ROOT"
  mkdir -m 700 "$cfg"
  sed "s|/spades-gis@sha256:|/spades-$image@sha256:|" "$SEEDS/config/compose.yaml" > "$cfg/compose.yaml"
  sed "s|PROJECTNAME|$name|g" "$SEEDS/config/project.env" > "$cfg/project.env"
  cp "$SEEDS/config/allowlist" "$cfg/allowlist"
  if [ "$image" = bio ]; then
    { echo; cat "$SEEDS/config/allowlist.bio-example"; } >> "$cfg/allowlist"
  fi
  cat > "$cfg/project.conf" <<EOF
# Owner-maintained settings for agent-up; also compose interpolation variables (--env-file).
# KEY=VALUE, no quotes.
PROJECT=$name
PROJECT_DIR=$dir
PROFILE=$profile
IMAGE=$image
SPADES_AI_DIR=$HOME/GitHub/spades.ai
AGENT_MEMORY_DIR=$HOME/agent-memory
EOF
  chmod 600 "$cfg/compose.yaml" "$cfg/project.env" "$cfg/allowlist" "$cfg/project.conf"

  local mem="$HOME/agent-memory"
  if [ ! -d "$mem" ]; then
    mkdir -p "$mem" && git -C "$mem" init -q
    echo "agent-up: created the shared agent memory repo $mem (spec §13.2)"
  fi

  local f rel
  while IFS= read -r -d '' f; do
    rel="${f#"$SEEDS/repo/"}"
    if [ -e "$dir/$rel" ]; then
      echo "agent-up: kept the project's existing $rel"
    else
      mkdir -p "$dir/$(dirname "$rel")"; cp "$f" "$dir/$rel"
      echo "agent-up: added $rel to the project (review and commit it)"
    fi
  done < <(find "$SEEDS/repo" -type f -print0 | sort -z)

  cat <<EOF
agent-up: created $cfg
Next (docs/runbooks/new-project.md):
  1. set the image digest in $cfg/compose.yaml (from agent-containers/digests.md)
  2. vault agent-$name + service account + scoped GitHub token (docs/runbooks/1password-project-vault.md)
  3. add the project's domains to $cfg/allowlist
  4. replace @OWNER in $dir/.github/CODEOWNERS
  5. agent-up up $name
EOF
}

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  init) cmd_init "$@" ;;
  *) usage ;;
esac
```

- [ ] **Step 5: Wire CI**

In `.github/workflows/ci.yml`:
- Replace the step named `Template test (static + behavioural against the built base image)`
  (both lines) with:

```yaml
      - name: Launcher test (agent-up; render + behavioural against the built base image)
        if: always()
        run: TEMPLATE_IMAGE=spades-base:ci bash tests/launcher/test-agent-up.sh
```

- In the step `Bio allowlist example passes firewall validation`, change
  `$PWD/project-template/allowlist.bio-example.txt` to
  `$PWD/project-template/config/allowlist.bio-example`.
- In the `lint` job's shellcheck step, replace the two-line command with:

```yaml
          shellcheck -S warning images/base/*.sh tests/*/*.sh scripts/*.sh bin/agent-up
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bash tests/launcher/test-agent-up.sh`
Expected: every line `OK:`, last line `LAUNCHER: ALL PASSED`. Also run
`shellcheck -S warning bin/agent-up tests/launcher/test-agent-up.sh` if shellcheck is installed;
expected: no output.

- [ ] **Step 7: Commit**

```bash
git add -A bin tests project-template .github/workflows/ci.yml
git commit -m "feat(launcher): agent-up init + config/repo seeds; drop the in-folder template

Seeds move to project-template/config (copied to ~/.config/agent-containers/<project>/) and
project-template/repo (copied into the project, never overwriting). Removes up, resolve-secrets,
check-digest, the devcontainer, the pre-commit hook and the overlay test (spec §4, 2026-10-06).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `agent-up up | config | shell | status | stop | down`

**Files:**
- Modify: `bin/agent-up` (add functions; replace the final dispatch block)
- Modify: `tests/launcher/test-agent-up.sh` (insert sections above the END marker)

**Interfaces:**
- Consumes: from Task 1, `die`, `usage`, `normalise`, `conf_get`, `CFG_ROOT`; the config files;
  the test harness (`au`, `aureal`, `TOK`, `AMBIENT`, `OPLOG`, `DLOG`, `CFG`, `NAME`, `P`, `H`,
  `H64`).
- Produces:
  - `cfg_dir <project>` (prints the config dir path or dies);
  - `COMPOSE` array: `docker compose --env-file <cfg>/project.conf -f <cfg>/compose.yaml -f
    <cfg>/.generated/env-passthrough.yaml --project-directory <cfg> -p <name>`;
  - `<cfg>/.generated/env-passthrough.yaml`;
  - container name `<name>-agent-1`.
  - **Task 3 relies on the exact compose argument order above.**

- [ ] **Step 1: Write the failing tests**

Insert above `# ---- END OF SECTIONS` in `tests/launcher/test-agent-up.sh`:

```bash
# ---- up: pre-flight refusals (the stub docker must never be reached)
TOK=tok
refuses "up refuses an unknown project" 'no config' au up nosuch
refuses "up refuses the placeholder digest" 'not pinned to a real digest' au up "$NAME"
sed -i "s/REPLACE_WITH_DIGEST_FROM_digests.md/$H64/" "$CFG/compose.yaml"
TOK=""
refuses "up refuses without OP_SERVICE_ACCOUNT_TOKEN" 'OP_SERVICE_ACCOUNT_TOKEN' au up "$NAME"
TOK=tok
mv "$H/GitHub/spades.ai" "$H/GitHub/spades.ai.off"
refuses "up refuses a missing spades.ai dir" 'SPADES_AI_DIR directory not found' au up "$NAME"
mv "$H/GitHub/spades.ai.off" "$H/GitHub/spades.ai"
mv "$H/agent-memory" "$H/agent-memory.off"
refuses "up refuses a missing agent memory dir" 'AGENT_MEMORY_DIR directory not found' au up "$NAME"
mv "$H/agent-memory.off" "$H/agent-memory"
cp "$CFG/project.env" "$T/penv.bak"; echo 'API_KEY=supersecret-plaintext' >> "$CFG/project.env"
refuses "up refuses a plaintext value in project.env" 'only KEY=op://.*line number' au up "$NAME"
msg=$(au up "$NAME" 2>&1 || true)
check "  ...without echoing the value" bash -c '! grep -q supersecret <<<"$1"' _ "$msg"
cp "$T/penv.bak" "$CFG/project.env"
cp "$CFG/project.conf" "$T/pconf.bak"; sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$H|" "$CFG/project.conf"
refuses "up refuses a workspace that contains the config dir" 'contains the config dir' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
check "a refused up never reached docker" test ! -e "$DLOG"

# ---- up: success, with hostile ambient compose/interpolation variables
AMBIENT=(COMPOSE_FILE=evil.yaml COMPOSE_PROFILES=evil PROJECT_DIR=/evil SPADES_AI_DIR=/evil)
rc=0; out=$(au up "$NAME" 2>&1) || rc=$?
AMBIENT=()
check "up succeeds (stub op + stub docker)" test "$rc" -eq 0
C="compose --env-file $CFG/project.conf -f $CFG/compose.yaml -f $CFG/.generated/env-passthrough.yaml --project-directory $CFG -p $NAME"
check "  ...op run resolves project.env, then runs docker compose" \
  grep -qxF "OP: run --env-file $CFG/project.env -- docker $C up -d --force-recreate" "$OPLOG"
check "  ...docker compose gets ONLY the config dir's files" grep -qxF "ARGS: $C up -d --force-recreate" "$DLOG"
check "  ...ambient COMPOSE_*/PROJECT_DIR/SPADES_AI_DIR unset; the resolved secret reaches compose" \
  bash -c '[ "$(grep "^ENV:" "$1" | tail -n 1)" = "ENV: COMPOSE_FILE=<unset> COMPOSE_PROFILES=<unset> PROJECT_DIR=<unset> SPADES_AI_DIR=<unset> GH_TOKEN=fake-secret-value-123" ]' _ "$DLOG"
check "  ...the shared Require cache volume is ensured" grep -qxF "ARGS: volume inspect require-cache-shared" "$DLOG"
check "  ...no secret value on stdout/stderr" bash -c '! grep -q fake-secret-value-123 <<<"$1"' _ "$out"
PT="$CFG/.generated/env-passthrough.yaml"
check "passthrough lists the key NAME" grep -qx "      - GH_TOKEN" "$PT"
check "  ...and holds no value or reference" bash -c '! grep -Eq "fake-secret|op://|=" "$1"' _ "$PT"

# ---- lifecycle commands
: > "$DLOG"
check "shell" au shell "$NAME"
check "  ...docker exec as agent in /workspace" grep -qxF "ARGS: exec -it -u agent -w /workspace $NAME-agent-1 zsh" "$DLOG"
check "status" au status "$NAME"
check "  ...compose ps" grep -qxF "ARGS: $C ps" "$DLOG"
check "stop" au stop "$NAME"
check "  ...compose stop" grep -qxF "ARGS: $C stop" "$DLOG"
check "down" au down "$NAME"
check "  ...compose down WITHOUT -v (named volumes kept)" grep -qxF "ARGS: $C down" "$DLOG"

# ---- rendering with the REAL docker compose (CI; skipped where docker is absent)
if docker compose version >/dev/null 2>&1; then
  render(){ ( cd "$1" && aureal config "$NAME" --format json ); }   # rendered FROM the given cwd
  J="$(render "$T")"
  m(){ jq -c --arg t "$1" '.services.agent.volumes[] | select(.target==$t)' <<<"$J"; }
  rw_from(){ [ "$(jq -r .source <<<"$1")" = "$2" ] && [ "$(jq -r '.read_only // false' <<<"$1")" = false ]; }
  PD="$(cd "$P" && pwd -P)"
  check "rendered: project name" test "$(jq -r .name <<<"$J")" = "$NAME"
  check "rendered: image pinned by digest" bash -c 'jq -r .services.agent.image <<<"$1" | grep -Eq "@sha256:[0-9a-f]{64}$"' _ "$J"
  check "rendered: /workspace = PROJECT_DIR, read-write" rw_from "$(m /workspace)" "$PD"
  check "rendered: /opt/reference/spades.ai read-write" rw_from "$(m /opt/reference/spades.ai)" "$H/GitHub/spades.ai"
  check "rendered: /opt/memory read-write" rw_from "$(m /opt/memory)" "$H/agent-memory"
  check "rendered: allowlist from the config dir, read-only" \
    bash -c '[ "$(jq -r .source <<<"$1")" = "$2" ] && [ "$(jq -r .read_only <<<"$1")" = true ]' _ "$(m /etc/firewall/allowlist.d/50-project.txt)" "$CFG/allowlist"
  check "rendered: nothing else under /etc/firewall" \
    test "$(jq '[.services.agent.volumes[] | select(.target|startswith("/etc/firewall"))] | length' <<<"$J")" = 1
  check "rendered: no rw bind contains the config dir" \
    bash -c 'jq -r ".services.agent.volumes[] | select(.type==\"bind\" and ((.read_only // false)|not)) | .source" <<<"$1" | while IFS= read -r s; do case "$2/" in "${s%/}/"*) echo "rw $s contains $2"; exit 1;; esac; done' _ "$J" "$CFG"
  check "rendered: claude-$NAME, rlib-$NAME, external require-cache-shared" \
    bash -c '[ "$(jq -r ".volumes[\"claude-config\"].name" <<<"$1")" = "claude-$2" ] && [ "$(jq -r ".volumes.rlib.name" <<<"$1")" = "rlib-$2" ] && [ "$(jq -r ".volumes[\"require-cache\"].name" <<<"$1")" = require-cache-shared ] && [ "$(jq -r ".volumes[\"require-cache\"].external" <<<"$1")" = true ]' _ "$J" "$NAME"
  check "rendered: no env_file (secrets only via op run)" test -z "$(jq -r '.services.agent.env_file // empty' <<<"$J")"
  check "rendered: NET_ADMIN + NET_RAW, explicit mem_limit" \
    jq -e '(.services.agent.cap_add | index("NET_ADMIN") and index("NET_RAW")) and (.services.agent.mem_limit != null)' <<<"$J"
  check "rendered: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
    test "$(jq -r '.services.agent.environment.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' <<<"$J")" = 1
  AMBIENT=(GH_TOKEN=dummy-render)
  check "rendered: a project.env key passes through from op run's environment" \
    test "$(cd "$T" && aureal config "$NAME" --format json | jq -r .services.agent.environment.GH_TOKEN)" = dummy-render
  AMBIENT=()
  # Acceptance (spec §11): planted files in the project folder change nothing.
  mkdir -p "$P/.devcontainer"
  printf 'services:\n  agent:\n    image: evil\n' | tee "$P/compose.yaml" "$P/docker-compose.yml" "$P/compose.override.yaml" >/dev/null
  printf 'PROJECT_DIR=/\nCOMPOSE_FILE=compose.yaml\nPROJECT=evil\n' > "$P/.env"
  cp "$P/.env" "$P/project.conf"; printf 'evil.example.com\n' > "$P/allowlist"
  printf '#!/bin/sh\necho evil\n' > "$P/up"; printf '{}\n' > "$P/.devcontainer/devcontainer.json"
  check "planted project files change NOTHING (rendered from inside the project)" \
    bash -c 'diff <(jq -S . <<<"$1") <(jq -S . <<<"$2")' _ "$J" "$(render "$P")"
  rm -rf "$P/.devcontainer" "$P/compose.yaml" "$P/docker-compose.yml" "$P/compose.override.yaml" "$P/.env" "$P/project.conf" "$P/allowlist" "$P/up"
else
  echo "SKIP: render checks (docker compose not available here; CI runs them)"
fi
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/launcher/test-agent-up.sh`
Expected: FAIL on the `up`, `shell`, `status`, `stop` and `down` checks (they print usage),
`LAUNCHER: FAILURES`.

- [ ] **Step 3: Implement**

In `bin/agent-up`, insert these functions **after `cmd_init`** and replace the final dispatch
block (from `[ $# -ge 1 ] || usage` to the end of the file) as shown:

```bash
cfg_dir(){ # $1 project -> its config dir (must exist)
  local p; p="$(normalise "$1")"
  [ -n "$p" ] || die "empty project name"
  [ -d "$CFG_ROOT/$p" ] || die "no config for '$p' in $CFG_ROOT (run: agent-up init <project-dir>)"
  printf '%s' "$CFG_ROOT/$p"
}
check_files(){
  local f
  for f in compose.yaml project.env allowlist project.conf; do
    [ -f "$1/$f" ] || die "missing $1/$f (re-create it from agent-containers/project-template/config)"
  done
}
check_digest(){
  grep -Eq '^[[:space:]]*image:[[:space:]]*[^[:space:]]+@sha256:[0-9a-f]{64}[[:space:]]*$' "$1" \
    || die "$1: the image is not pinned to a real digest (@sha256:<64 hex>). Copy one from agent-containers/digests.md."
}
check_project_env(){ # op:// references only; never echo a line (it could hold a pasted secret)
  local bad
  bad="$(grep -nEv '^[[:space:]]*(#|$)' "$1" | grep -Ev '^[0-9]+:[A-Za-z_][A-Za-z0-9_]*=op://[^[:space:]]+$' | cut -d: -f1 | paste -sd, - || true)"
  [ -z "$bad" ] || die "$1 may hold only KEY=op://... references; offending line number(s): $bad (values not shown)"
}
check_mounts(){ # every rw bind source exists and does not contain the config dir
  local cfgreal key src
  cfgreal="$(cd "$1" && pwd -P)"
  for key in PROJECT_DIR SPADES_AI_DIR AGENT_MEMORY_DIR; do
    src="$(conf_get "$1/project.conf" "$key")"
    [ -n "$src" ] || die "$key is not set in $1/project.conf"
    [ -d "$src" ] || die "$key directory not found: $src (create it, or fix $key in $1/project.conf)"
    src="$(cd "$src" && pwd -P)"
    case "$cfgreal/" in "$src"/*) die "$key ($src) contains the config dir $1: the agent could edit its own sandbox. Move one of them." ;; esac
  done
}
write_passthrough(){ # container env NAMES from project.env; values never touch disk
  local keys k out="$1/.generated/env-passthrough.yaml"
  keys="$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1/project.env" | sort -u)"
  mkdir -p -m 700 "$1/.generated"
  {
    echo "# GENERATED by agent-up from the key NAMES in project.env. Values are never written. Do not edit."
    echo "services:"
    echo "  agent:"
    if [ -n "$keys" ]; then
      echo "    environment:"
      while IFS= read -r k; do echo "      - $k"; done <<<"$keys"
    else
      echo "    environment: []"
    fi
  } > "$out"
}
compose_cmd(){ # sets COMPOSE for config dir $1
  COMPOSE=(docker compose --env-file "$1/project.conf" -f "$1/compose.yaml" -f "$1/.generated/env-passthrough.yaml"
           --project-directory "$1" -p "$(basename "$1")")
}
prepare(){ check_files "$1"; write_passthrough "$1"; compose_cmd "$1"; }

cmd_up(){
  [ $# -eq 1 ] || usage
  local cfg name; cfg="$(cfg_dir "$1")"; name="$(basename "$cfg")"
  check_files "$cfg"
  check_digest "$cfg/compose.yaml"
  check_project_env "$cfg/project.env"
  check_mounts "$cfg"
  [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die "OP_SERVICE_ACCOUNT_TOKEN is not set for this project (docs/runbooks/1password-project-vault.md)"
  prepare "$cfg"
  docker volume inspect require-cache-shared >/dev/null 2>&1 || docker volume create require-cache-shared >/dev/null
  op run --env-file "$cfg/project.env" -- "${COMPOSE[@]}" up -d --force-recreate
  echo "agent-up: '$name' running. Attach: agent-up shell $name, or VS Code: Dev Containers: Attach to Running Container... -> ${name}-agent-1"
}
cmd_config(){
  [ $# -ge 1 ] || usage
  local cfg; cfg="$(cfg_dir "$1")"; shift
  prepare "$cfg"
  "${COMPOSE[@]}" config "$@"
}
cmd_shell(){
  [ $# -eq 1 ] || usage
  local cfg; cfg="$(cfg_dir "$1")"
  docker exec -it -u agent -w /workspace "$(basename "$cfg")-agent-1" zsh
}
cmd_compose(){ # $1 compose subcommand, $2 project
  local sub="$1"; shift
  [ $# -eq 1 ] || usage
  local cfg; cfg="$(cfg_dir "$1")"
  prepare "$cfg"
  "${COMPOSE[@]}" "$sub"
}

# Only the owner's config defines the sandbox: ambient compose settings and interpolation variables
# must not override it (a shell variable beats --env-file in compose).
unset COMPOSE_FILE COMPOSE_PROFILES COMPOSE_PATH_SEPARATOR COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES \
      PROJECT PROJECT_DIR PROFILE IMAGE SPADES_AI_DIR AGENT_MEMORY_DIR

[ $# -ge 1 ] || usage
cmd="$1"; shift
case "$cmd" in
  init)   cmd_init "$@" ;;
  up)     cmd_up "$@" ;;
  config) cmd_config "$@" ;;
  shell)  cmd_shell "$@" ;;
  status) cmd_compose ps "$@" ;;
  stop)   cmd_compose stop "$@" ;;
  down)   cmd_compose down "$@" ;;
  *) usage ;;
esac
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/launcher/test-agent-up.sh`
Expected: all `OK:`. Without docker, one `SKIP: render checks`. Last line `LAUNCHER: ALL PASSED`.

- [ ] **Step 5: Commit, push, and verify the render checks in CI**

```bash
git add bin/agent-up tests/launcher/test-agent-up.sh
git commit -m "feat(launcher): agent-up up/config/shell/status/stop/down

op run resolves project.env into the environment of docker compose only; compose gets ONLY the
config dir's files (+ a generated, names-only env passthrough); ambient COMPOSE_* and
interpolation variables are unset. Tests pin the exact compose call, the refusals, and that
files planted in the project folder change nothing in the rendered config.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
gh pr checks 3 --watch -R AllenLarocque/agent-containers
```

Expected: `build-test` and `lint` pass, and the CI log of `Launcher test` shows the `rendered:`
lines as `OK:`. If CI fails, read the log (`gh run view --log-failed`), fix, and re-push. Do not
mark the task done on a red check.

---

### Task 3: Decision B + behavioural sandbox test

**Files:**
- Modify: `images/base/allowlist.d/00-base.txt` (remove `sentry.io`, `statsig.com`)
- Modify: `tests/launcher/test-agent-up.sh` (insert above the END marker)

**Interfaces:**
- Consumes: Task 2's compose argument order; harness variables; `TEMPLATE_IMAGE` (CI sets
  `spades-base:ci`).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Insert above `# ---- END OF SECTIONS`:

```bash
# ---- behavioural: the rendered sandbox against the CI-built image (TEMPLATE_IMAGE=spades-base:ci).
# `agent-up up` needs a registry digest, so this uses the SAME compose arguments agent-up uses
# (pinned above) plus one override that swaps in the local image and skips agent-init.
if [ -n "${TEMPLATE_IMAGE:-}" ]; then
  docker image inspect "$TEMPLATE_IMAGE" >/dev/null 2>&1 || { echo "FAIL: TEMPLATE_IMAGE=$TEMPLATE_IMAGE not present"; exit 1; }
  printf 'www.python.org\n' >> "$CFG/allowlist"
  cat > "$T/override.yaml" <<OVR
services:
  agent:
    image: $TEMPLATE_IMAGE
    mem_limit: 4g
    command: bash -c "sudo /usr/local/bin/init-firewall.sh && touch /tmp/fw-ready && exec sleep infinity"
OVR
  dc(){ env -u PROJECT -u PROJECT_DIR -u SPADES_AI_DIR -u AGENT_MEMORY_DIR -u COMPOSE_FILE HOME="$H" DOCKER_CONFIG="$REAL_HOME/.docker" \
          docker compose --env-file "$CFG/project.conf" -f "$CFG/compose.yaml" -f "$CFG/.generated/env-passthrough.yaml" \
          -f "$T/override.yaml" --project-directory "$CFG" -p "$NAME" "$@"; }
  trap 'dc down -v >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
  docker volume inspect require-cache-shared >/dev/null 2>&1 || docker volume create require-cache-shared >/dev/null
  # CI runner UID != 1000. In real use these are the agent's own (UID 1000) directories.
  chmod -R a+rwX "$P" "$H/GitHub/spades.ai" "$H/agent-memory"
  check "sandbox starts" dc up -d
  CID="$(dc ps -q agent)"
  for _ in $(seq 1 90); do docker exec "$CID" test -e /tmp/fw-ready 2>/dev/null && break; sleep 2; done
  check "firewall initialised" docker exec "$CID" test -e /tmp/fw-ready
  check "in-container allowlist == the config dir's allowlist" \
    bash -c 'diff <(docker exec "$1" cat /etc/firewall/allowlist.d/50-project.txt) "$2"' _ "$CID" "$CFG/allowlist"
  check "agent cannot write the in-container allowlist" \
    bash -c '! docker exec -u agent "$1" sh -c "echo example.com >> /etc/firewall/allowlist.d/50-project.txt" 2>/dev/null' _ "$CID"
  for d in /workspace /opt/memory /opt/reference/spades.ai; do
    check "agent can write $d" docker exec -u agent "$CID" sh -c "echo x > $d/.agent-up-test && rm $d/.agent-up-test"
  done
  check "the config dir is not visible in the container" bash -c '! docker exec "$1" test -e "$2"' _ "$CID" "$CFG"
  check "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 in the container" \
    test "$(docker exec "$CID" printenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)" = 1
  for host in sentry.io statsig.com; do
    check "$host does not resolve (decision B)" \
      bash -c '[ -z "$(docker exec -u agent "$1" dig @127.0.0.1 "$2" A +short +time=2 +tries=1 | grep -E "^[0-9.]+$")" ]' _ "$CID" "$host"
  done
  check "release-assets.githubusercontent.com still resolves (decision C)" \
    bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 release-assets.githubusercontent.com A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
  check "project-allowlisted www.python.org resolves" \
    bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 www.python.org A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
  dc down -v >/dev/null 2>&1 || true
else
  echo "SKIP: behavioural sandbox checks (set TEMPLATE_IMAGE to a built image; CI does)"
fi
```

- [ ] **Step 2: Push and verify it fails in CI for the right reason**

```bash
git add tests/launcher/test-agent-up.sh
git commit -m "test(launcher): behavioural sandbox checks against the built image

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
gh pr checks 3 --watch -R AllenLarocque/agent-containers
```

Expected: `build-test` FAILS. In `Launcher test`, exactly the two lines
`FAIL: sentry.io does not resolve (decision B)` and `FAIL: statsig.com does not resolve (decision B)`
fail; every other behavioural line is `OK:`. If anything else fails, fix that first.

- [ ] **Step 3: Implement decision B**

In `images/base/allowlist.d/00-base.txt`, replace:

```
# --- Claude Code / npm
api.anthropic.com
registry.npmjs.org
sentry.io
statsig.com
```

with:

```
# --- Claude Code / npm. sentry.io and statsig.com (error reports, telemetry) are deliberately NOT
# here: containers set CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 (spec §12, decision B).
api.anthropic.com
registry.npmjs.org
```

- [ ] **Step 4: Push and verify it passes**

```bash
git add images/base/allowlist.d/00-base.txt
git commit -m "feat(firewall): drop sentry.io and statsig.com from the base allowlist (decision B)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
gh pr checks 3 --watch -R AllenLarocque/agent-containers
```

Expected: `build-test`, `lint` and `publish-dryrun` pass. `Launcher test` ends with
`LAUNCHER: ALL PASSED`, and its behavioural lines show `OK:` (not `SKIP:`).

---

### Task 4: Secret scanning in CI (gitleaks) instead of a host pre-commit hook

**Files:**
- Create: `project-template/repo/.github/workflows/gitleaks.yml`
- Modify: `.github/workflows/ci.yml` (`lint` job: full-history checkout, gitleaks step, actionlint
  of the seed)
- Modify: `tests/launcher/test-agent-up.sh` (one check in the init section)
- Create only if Step 4 finds fixture false positives: `.gitleaks.toml`

**Interfaces:**
- Consumes: Task 1's repo-seed copy in `init`.
- Produces: `gitleaks` job name in project repos (for their rulesets).

- [ ] **Step 1: Write the failing test**

In `tests/launcher/test-agent-up.sh`, directly after the line
`check "repo seed .gitignore copied into the project" test -f "$P/.gitignore"`, add:

```bash
check "repo seed gitleaks workflow copied into the project" grep -q "ghcr.io/gitleaks/gitleaks:v8.30.1" "$P/.github/workflows/gitleaks.yml"
```

Run: `bash tests/launcher/test-agent-up.sh`
Expected: `FAIL: repo seed gitleaks workflow copied into the project`.

- [ ] **Step 2: Create the seed workflow**

`project-template/repo/.github/workflows/gitleaks.yml`:

```yaml
# Secret scanner (spec §5 guard, amended 2026-10-06): runs in CI, never as a host-side git hook.
# Make the `gitleaks` check required in this repo's ruleset.
name: gitleaks
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  gitleaks:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: gitleaks (full history, redacted output)
        run: docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --verbose
```

Run: `bash tests/launcher/test-agent-up.sh`
Expected: the new check is `OK:`, `LAUNCHER: ALL PASSED`.

- [ ] **Step 3: Scan this repo too, and lint the seed workflow**

In `.github/workflows/ci.yml`, `lint` job:
- change its checkout step to:

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
```

- in the `actionlint` step, after `/tmp/actionlint -color`, add a line:

```yaml
          /tmp/actionlint -color project-template/repo/.github/workflows/gitleaks.yml
```

- append a step at the end of the `lint` job:

```yaml
      - name: gitleaks (full history, redacted)
        if: always()
        run: docker run --rm -u "$(id -u):$(id -g)" -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --verbose
```

- [ ] **Step 4: Push and verify**

```bash
git add project-template/repo/.github/workflows/gitleaks.yml .github/workflows/ci.yml tests/launcher/test-agent-up.sh
git commit -m "feat(ci): gitleaks as a CI check here and in the project repo seed (no host hook)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
gh pr checks 3 --watch -R AllenLarocque/agent-containers
```

Expected: `lint` passes, including `gitleaks` with `no leaks found`.

**If gitleaks reports findings:**
- Look at each one: `gh run view --log-failed`. The output is redacted, but shows the file and
  rule.
- If **every** finding is a test fixture under `tests/` (fake values such as
  `fake-secret-value-123`), create `.gitleaks.toml` with the content below, then commit and push
  again.
- If **any** finding is outside `tests/`, **stop and report it to the controller.** Never add an
  allowlist for it.

```toml
# Test fixtures use fake secret-shaped values on purpose. Everything else is scanned.
[extend]
useDefault = true

[allowlist]
description = "test fixtures with fake values"
paths = ['''^tests/''']
```

When `.gitleaks.toml` exists, the CI command must load it: append `--config /repo/.gitleaks.toml`
to the `docker run ... git /repo --redact --verbose` line in `ci.yml` (this repo only, not the
seed).

---

### Task 5: Documentation

**Files:**
- Rewrite: `project-template/README.md`
- Rewrite: `docs/runbooks/new-project.md`
- Modify: `docs/runbooks/1password-project-vault.md`, `docs/runbooks/machine-user-and-rulesets.md`,
  `README.md`, `images/base/configure-claude-settings.js` (comment only)

**Interfaces:**
- Consumes: the command names and paths from Tasks 1–4.
- Produces: nothing in code.

- [ ] **Step 1: Write the check that fails**

Run:

```bash
grep -rn -E '\./up\b|resolve-secrets|check-digest|Reopen in Container|--adopt|pre-commit install|launcher\.sha256' \
  README.md project-template docs/runbooks images/base/configure-claude-settings.js
```

Expected now: many matches.

- [ ] **Step 2: Rewrite `project-template/README.md`**

```markdown
# Project template (seeds for `agent-up`)

This folder is **not copied into your project by hand.** `bin/agent-up init` uses it:

| Seed | Copied to | Who edits it |
|---|---|---|
| `config/compose.yaml`, `config/project.env`, `config/allowlist` (+ `config/allowlist.bio-example` for `--image bio`) | `~/.config/agent-containers/<project>/` | you, the owner. **Never mounted** into the container, except `allowlist` (read-only) |
| `repo/.github/CODEOWNERS`, `repo/.github/workflows/gitleaks.yml`, `repo/.gitignore` | the project folder (only where absent) | you; commit them |

**Why outside the project:** the project folder is the agent's read-write workspace. Anything
there could be changed by the agent, so the host never executes or reads configuration from it
(spec §2.1, §4).

## Commands (run on the host, from your agent-containers clone)

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

## Working in the project folder from the host

**Recommended:** run git and R inside the container (attached VS Code or `agent-up shell`).

Host git in the project folder is allowed, but host git honours the folder's `.git/config` and
hooks, which the agent can write. If you do use host git there, run
`git -c core.hooksPath=/dev/null -c core.fsmonitor=false ...`.
```

- [ ] **Step 3: Rewrite `docs/runbooks/new-project.md`**

````markdown
# Runbook: set up a new SpaDES project

**Human procedure.** The agent must never perform these steps (they involve host secrets and repo
permissions).

**Prerequisites on the host:**
- Docker;
- the 1Password CLI (`op`);
- a clone of this repo at `~/GitHub/agent-containers`. The commands below assume
  `~/GitHub/agent-containers/bin` is on your `PATH`; otherwise type the full path.

`<project>` is the project folder name, lowercased to `[a-z0-9_-]`. The container is
`<project>-agent-1`.

## Steps

1. **Create the project's config** (outside the project folder):

   ```bash
   agent-up init ~/GitHub/<project>                # GIS / fire projects (spades-gis)
   agent-up init ~/GitHub/<project> --image bio    # amplicon projects (spades-bio; adds the bio domains)
   ```

   - This creates `~/.config/agent-containers/<project>/` (`compose.yaml`, `project.env`,
     `allowlist`, `project.conf`).
   - It also creates `~/agent-memory` the first time.
   - It adds `.github/CODEOWNERS`, `.github/workflows/gitleaks.yml` and `.gitignore` to the
     project wherever they're missing.

2. **Set the image digest.** In `~/.config/agent-containers/<project>/compose.yaml`, replace
   `REPLACE_WITH_DIGEST_FROM_digests.md` with the digest from `agent-containers/digests.md` (the
   matching `spades-gis` or `spades-bio` row). `agent-up up` refuses to run until it's a real
   digest.
3. **Run the vault runbook:** [1password-project-vault.md](1password-project-vault.md) (vault,
   service account, host token). `project.env` already names the vault `agent-<project>`.
4. **Machine user, "set up" half (before `agent-up up`):**
   [machine-user-and-rulesets.md](machine-user-and-rulesets.md) steps 2 to 4.
   - In the project repo: replace `@OWNER` in `.github/CODEOWNERS`, then commit it together with
     `.github/workflows/gitleaks.yml` and `.gitignore`.
   - Make **`build-test`** (once CI exists) and **`gitleaks`** required checks in the ruleset.
     They only become selectable after they have run once.
5. **Project domains:** add the extra domains the project needs to
   `~/.config/agent-containers/<project>/allowlist`.
   - One domain per line; a domain also matches its subdomains.
   - Anything not listed is blocked and doesn't even resolve.
   - Only ports 22, 80 and 443 are open, and only to listed hosts. **SSH to your own servers
     (cloud VM, NAS) needs their domain here too.**
6. **Clone `spades.ai`** to `~/GitHub/spades.ai`, or point `SPADES_AI_DIR` in
   `~/.config/agent-containers/<project>/project.conf` at your clone. `agent-up up` stops if it's
   missing.
7. **Check what will run**, then start it:

   ```bash
   agent-up config <project>     # the fully rendered sandbox: mounts, volumes, environment
   agent-up up <project>
   ```

   `agent-up up` needs `OP_SERVICE_ACCOUNT_TOKEN` for **this** project in your shell (see the
   vault runbook).
8. **Machine user, "verify the gate" (after `agent-up up`):** run
   [machine-user-and-rulesets.md](machine-user-and-rulesets.md) step 6 inside the container
   (`agent-up shell <project>`). Don't start real work until it passes.
9. **Attach and work:**
   - VS Code: **Dev Containers: Attach to Running Container…** → `<project>-agent-1`, then open
     `/workspace`.
   - Or use `agent-up shell <project>`.

   Inside the container, run `claude`. Set up R with `setupProject` as usual.

Later changes: edit the files in `~/.config/agent-containers/<project>/`, then `agent-up up <project>`.
Nothing in the project folder configures the container.
````

- [ ] **Step 4: Edit `docs/runbooks/1password-project-vault.md`**

Apply these replacements (the exact old text is shown first):
- `into the **current shell only**, then run \`./up\`, for example` → `into the **current shell only**, then run \`agent-up up <project>\`, for example`
- `` `./resolve-secrets` reads `OP_SERVICE_ACCOUNT_TOKEN` from the host environment and stops with an error if it is missing. `` → `` `agent-up up` reads `OP_SERVICE_ACCOUNT_TOKEN` from the host environment and stops with an error if it is missing. ``
- `` **Warning:** if the wrong project's token is in your environment, `resolve-secrets` either fails (vault not readable) or reads a different vault than you intended. Check the project before `./up`. `` → `` **Warning:** if the wrong project's token is in your environment, `agent-up up` either fails (vault not readable) or reads a different vault than you intended. Check the project before `agent-up up`. ``
- `Never commit the token. The template ships a gitleaks pre-commit hook as a backstop (\`pre-commit install\` once per clone).` → `Never commit the token. Each project repo runs gitleaks in CI as a backstop (\`.github/workflows/gitleaks.yml\`, added by \`agent-up init\`).`
- Delete the line that starts `VS Code started from the dock or Start menu may not see your shell environment`.
- In section 5, replace both `then run \`./up\`` and `then \`./up\`` with `then \`agent-up up <project>\``.
- Replace the last line (`Files written by \`./resolve-secrets\`: ...`) with: `` `agent-up` writes no secret to disk: `op run` resolves the values into the environment of `docker compose` only. `~/.config/agent-containers/<project>/.generated/env-passthrough.yaml` holds the key NAMES only. ``

- [ ] **Step 5: Edit `docs/runbooks/machine-user-and-rulesets.md`**

- Line 36: `` `project-template/.github/CODEOWNERS` `` → `` `.github/CODEOWNERS` (added to the project by `agent-up init`) ``
- Every `` `./up` `` → `` `agent-up up <project>` `` (lines 66, 91 ×2, 93).
- Line 95: `` (`docker exec -it -u agent <project>-agent-1 zsh`; `` → `` (`agent-up shell <project>`; ``

- [ ] **Step 6: Edit `README.md` and the settings-script comment**

In `README.md`, replace the paragraph that starts `Projects don't build images:` and the
`Status:` line with:

```markdown
Projects don't build images: each one references an image **by digest** from its own
`compose.yaml`, which lives with its allowlist and 1Password references in the owner's
`~/.config/agent-containers/<project>/`, outside the agent-writable project folder. Start and
manage containers with `bin/agent-up` (see `project-template/README.md`).

Status: **Phase 1 in progress** (PR #3). See `docs/specs/2026-10-03-agent-containers-design.md`.
```

In `images/base/configure-claude-settings.js`, replace the comment lines
`// baked into the image at /home/node/.claude so a fresh named volume` and
`// (mounted there by devcontainer.json) is seeded with this content on first` with:

```js
// written into $CLAUDE_CONFIG_DIR (the claude-<project> named volume, see the
// compose seed in project-template/config) and seeded with this content on first
```

- [ ] **Step 7: Verify the check passes**

Run the Step 1 grep again.
Expected: **no matches**, apart from `--adopt` or `./up` inside quoted history in the spec (the
spec isn't in the grep paths).

Then run `bash tests/launcher/test-agent-up.sh`. Expected: `LAUNCHER: ALL PASSED`.

- [ ] **Step 8: Commit and push**

```bash
git add README.md project-template/README.md docs/runbooks images/base/configure-claude-settings.js
git commit -m "docs: agent-up replaces ./up, resolve-secrets, devcontainer and the pre-commit hook

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
gh pr checks 3 --watch -R AllenLarocque/agent-containers
```

Expected: all checks green.

---

## Not in this plan (deliberately)

- The research profile (Phase 1b), T3 Code (Phase 2), memory structure (Phase 3): spec §13.
- The first real run on the user's WSL2 machine (xt_owner, conntrack, VS Code extension hosts,
  GHCR publish): the pickup note's "to verify on first real use" list, done with the user.
