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
  if o=$("$@" 2>&1); then echo "OK:   $d"; else echo "FAIL: $d"; printf '%s\n' "$o" | sed 's/^/        /'; annotate "$d"; fail=1; fi
}
refuses(){ # $1 label, $2 ERE the message must match, rest = command that must FAIL
  local d="$1" re="$2" rc=0 msg; shift 2
  msg=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq -- "$re" <<<"$msg"; then echo "OK:   $d"
  else echo "FAIL: $d (rc=$rc, want non-zero and /$re/)"; printf '%s\n' "$msg" | sed 's/^/        /'; annotate "$d"; fail=1; fi
}
# In GitHub Actions, also surface each failure as an annotation (readable via the checks API even
# where the raw log is not).
annotate(){ [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=launcher test::FAIL: $1"; }

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
check "init succeeds" env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" OPLOG="$OPLOG" DLOG="$DLOG" PATH="$T/dstub:$T/bin:$PATH" bash -c "umask 022; exec '$AU' init '$P'"
check "agent-memory dir created with mode 755 (not restricted by umask)" test "$(stat -c %a "$H/agent-memory")" = 755
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
check "repo seed gitleaks workflow copied into the project" grep -q "ghcr.io/gitleaks/gitleaks:v8.30.1" "$P/.github/workflows/gitleaks.yml"
check "no launcher, compose or env file written into the project" \
  bash -c '! ls -A "$1" | grep -Eqx "compose\.ya?ml|docker-compose\.ya?ml|up|\.env|\.devcontainer|project\.(env|conf)|allowlist"' _ "$P"
check "shared agent memory created as a git repo" test -d "$H/agent-memory/.git"
refuses "init never overwrites an existing config" 'already exists' au init "$P"
P2="$T/other"; mkdir -p "$P2/.github"; echo "* @me" > "$P2/.github/CODEOWNERS"
check "init --image bio --name Bio2" au init "$P2" --image bio --name Bio2
check "  ...existing CODEOWNERS kept" grep -qx '\* @me' "$P2/.github/CODEOWNERS"
check "  ...compose uses spades-bio" grep -q "spades-bio@sha256:" "$CFGROOT/bio2/compose.yaml"
check "  ...bio domains appended to the allowlist" grep -qx "mycoportal.org" "$CFGROOT/bio2/allowlist"

# ---- init: symlinks, permissions, atomicity, names
SP1="$T/symproj1"; mkdir -p "$SP1/.github"; ln -s "$T/evil-target" "$SP1/.github/CODEOWNERS"
check "init succeeds with a dangling CODEOWNERS symlink" au init "$SP1" --name symproj1
check "  ...nothing written through the dangling symlink" test ! -e "$T/evil-target"
check "  ...the symlink is still a symlink" test -L "$SP1/.github/CODEOWNERS"
SP2="$T/symproj2"; mkdir -p "$SP2" "$T/evil-dir"; ln -s "$T/evil-dir" "$SP2/.github"
out2="$(au init "$SP2" --name symproj2 2>&1)" || { echo "FAIL: init with symlinked .github"; fail=1; }
check "  ...nothing written into the symlinked directory" test -z "$(ls -A "$T/evil-dir")"
check "  ...output says skipped" grep -q "skipped" <<<"$out2"
check "seed .gitignore copied with normal mode (644)" test "$(stat -c %a "$P/.gitignore")" = 644
noleft(){ local f; for f in "$CFGROOT"/.init.*; do [ -e "$f" ] && return 1; done; return 0; }
refuses "refusal: missing dir (again)" 'project directory not found' au init "$T/nope"
refuses "refusal: research (again)" 'Phase 1b' au init "$P" --profile research --name zz
refuses "refusal: unknown image (again)" 'base, gis or bio' au init "$P" --image foo --name zz
check "no .init.* leftovers after refusals and successes" noleft
check "no config dir for refused inits" test ! -e "$CFGROOT/zz"
check "config dirs are exactly the expected ones" test "$(ls -A "$CFGROOT" | sort | tr '\n' ' ')" = "bio2 demo-proj symproj1 symproj2 "
OD="$T/_Odd Name!"; mkdir -p "$OD"
check "init of '_Odd Name!' derives a letter-first name" au init "$OD"
check "  ...config is odd-name-" test -d "$CFGROOT/odd-name-"
XD="$T/xdir"; mkdir -p "$XD"
check "init --name .x" au init "$XD" --name .x
check "  ...config is x" test -d "$CFGROOT/x"

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

# ---- up: pre-flight refusals (continued)
cp "$CFG/project.conf" "$T/pconf.bak2"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=/|" "$CFG/project.conf"
refuses "up refuses PROJECT_DIR=/ (contains the config dir)" 'contains the config dir' au up "$NAME"
cp "$T/pconf.bak2" "$CFG/project.conf"
check "  ...a refused up never reached docker" test ! -e "$DLOG"

cp "$CFG/project.conf" "$T/pconf.bak3"
sed -i "s/^PROJECT=.*/PROJECT=mismatch/" "$CFG/project.conf"
refuses "up refuses PROJECT mismatch with config dir name" 'must equal the config dir name' au up "$NAME"
cp "$T/pconf.bak3" "$CFG/project.conf"
check "  ...a refused up never reached docker" test ! -e "$DLOG"

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

# ---- passthrough coverage
cp "$CFG/project.env" "$T/penv2.bak"
cat > "$CFG/project.env" <<'PENV'
ZED=op://v/i/f
# a comment
GH_TOKEN=op://agent-demo-proj/github-agent/token
ALPHA=op://v/i/f
PENV
au config "$NAME" > /dev/null 2>&1
check "passthrough: sorted names, comments ignored" bash -c '[ "$(grep "^      - " "$1" | sed "s/^      - //" | paste -sd, -)" = "ALPHA,GH_TOKEN,ZED" ]' _ "$PT"
cat > "$CFG/project.env" <<'PENV'
# nothing here
PENV
au config "$NAME" > /dev/null 2>&1
check "passthrough: empty list when only comments" bash -c 'grep -qx "    environment: \[\]" "$1"' _ "$PT"
cp "$T/penv2.bak" "$CFG/project.env"
au config "$NAME" > /dev/null 2>&1
check "passthrough: restored to single GH_TOKEN" grep -qx "      - GH_TOKEN" "$PT"

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
  touch "$P/.from-host"   # sentinel: proves /workspace is the host project dir, not the image's empty dir
  chmod -R a+rwX "$P" "$H/GitHub/spades.ai" "$H/agent-memory"
  check "sandbox starts" dc up -d
  CID="$(dc ps -q agent || true)"
  if [ -z "$CID" ]; then
    check "sandbox container id" false
  else
    for _ in $(seq 1 90); do docker exec "$CID" test -e /tmp/fw-ready 2>/dev/null && break; sleep 2; done
    check "firewall initialised" docker exec "$CID" test -e /tmp/fw-ready
    # The file is mode 600 owned by the CI runner (not UID 1000), so only root can read it.
    check "in-container allowlist == the config dir's allowlist" \
      bash -c 'diff <(docker exec -u root "$1" cat /etc/firewall/allowlist.d/50-project.txt) "$2"' _ "$CID" "$CFG/allowlist"
    # Root, so permissions cannot explain a failure: only the read-only mount can.
    check "the in-container allowlist is a read-only mount (even root cannot write it)" \
      bash -c 'out="$(docker exec -u root "$1" sh -c "echo example.com >> /etc/firewall/allowlist.d/50-project.txt" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$CID"
    check "/workspace is the host project dir (sees the host sentinel)" docker exec "$CID" test -e /workspace/.from-host
    for d in /workspace /opt/memory /opt/reference/spades.ai; do
      check "agent can write $d" docker exec -u agent "$CID" sh -c "echo x > $d/.agent-up-test && rm $d/.agent-up-test"
    done
    check "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 in the container" \
      test "$(docker exec "$CID" printenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)" = 1
    for host in sentry.io statsig.com; do
      check "$host is refused by the firewall DNS (decision B)" \
        bash -c 'docker exec -u agent "$1" dig @127.0.0.1 "$2" A +time=2 +tries=1 +noall +comments | grep -q "status: REFUSED"' _ "$CID" "$host"
    done
    check "release-assets.githubusercontent.com still resolves (decision C)" \
      bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 release-assets.githubusercontent.com A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
    check "project-allowlisted www.python.org resolves" \
      bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 www.python.org A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
  fi
  dc down -v >/dev/null 2>&1 || true
else
  echo "SKIP: behavioural sandbox checks (set TEMPLATE_IMAGE to a built image; CI does)"
fi

# ---- END OF SECTIONS (later tasks insert above this line)
[ "$fail" -eq 0 ] && echo "LAUNCHER: ALL PASSED" || { echo "LAUNCHER: FAILURES"; exit 1; }
