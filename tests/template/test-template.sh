#!/usr/bin/env bash
# Validates the template WITHOUT real secrets: compose renders, scripts parse and behave, no secret values committed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REAL_HOME="$HOME"
cd "$ROOT/project-template"
fail=0
check(){ # print failing command's output on FAIL
  local d="$1" o; shift
  if o=$("$@" 2>&1); then echo "OK:   $d"; else echo "FAIL: $d"; printf '%s\n' "$o" | sed 's/^/        /'; fail=1; fi
}

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/spades.ai"
docker volume create require-cache-shared >/dev/null

# ---- static checks on the template itself
mkdir -p "$HOME/.config/agent-containers"; : > "$HOME/.config/agent-containers/project-template.env"
check "compose renders (defaults)"   docker compose -p project-template config
check "template carries the documented digest placeholder" \
  grep -q "image: ghcr.io/allenlarocque/spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md" compose.yaml
check "project.env is references"    bash -c '! grep -Ev "^\s*(#|$)" project.env | grep -v "=op://"'
check "resolve-secrets parses"       bash -n resolve-secrets
check "up parses"                    bash -n up
check "check-digest parses"          bash -n check-digest
check "devcontainer.json valid JSON" bash -c 'grep -v "^\s*//" .devcontainer/devcontainer.json | jq -e .dockerComposeFile'
check "devcontainer does not set PROJECT only for resolve-secrets" \
  bash -c '! grep -q "PROJECT=" .devcontainer/devcontainer.json'
check "gitignore covers .env.resolved" grep -q "\.env\.resolved" .gitignore
check "gitignore covers .env"        grep -qx "\.env" .gitignore
check "CODEOWNERS present with placeholder owner" grep -q "^\* @OWNER" .github/CODEOWNERS
check "gitleaks pre-commit"          grep -q "gitleaks/gitleaks" .pre-commit-config.yaml
check "spades.ai mount never auto-created" \
  bash -c 'grep -q "create_host_path: false" compose.yaml'
check "up pre-checks spades.ai dir"  grep -q "SPADES_AI_DIR" up
check "README has New project + Change a secret rows" \
  bash -c 'grep -q "New project" README.md && grep -q "Change a secret" README.md && grep -qi "OP_SERVICE_ACCOUNT_TOKEN" README.md'

# ---- digest format checker (used by new-project flow)
check "check-digest rejects the placeholder" bash -c '! ./check-digest compose.yaml'
H64=$(printf 'a%.0s' $(seq 64))
sed "s/REPLACE_WITH_DIGEST_FROM_digests.md/$H64/" compose.yaml > "$T/good.yaml"
sed "s/REPLACE_WITH_DIGEST_FROM_digests.md/abc123/" compose.yaml > "$T/short.yaml"
check "check-digest accepts a 64-hex digest" ./check-digest "$T/good.yaml"
check "check-digest rejects a short digest"  bash -c '! ./check-digest "$1"' _ "$T/short.yaml"

# ---- behavioural: resolve-secrets with a stub `op`, in a copy named with uppercase + odd chars
cat > "$T/bin/op" <<'STUB'
#!/usr/bin/env bash
# stub: op inject --force -i IN -o OUT  -> writes fake values with a LOOSE umask
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; esac; shift; done
umask 022
printf 'GH_TOKEN=fake-secret-value-123\nSTUB_MARK=ok\n' > "$out"
STUB
chmod +x "$T/bin/op"
P="$T/Demo.Proj"; cp -a "$ROOT/project-template" "$P"; rm -f "$P/.env"
NAME=demo-proj
OUT="$T/home/.config/agent-containers/$NAME.env"
runrs(){ ( cd "$P"; HOME="$T/home" PATH="$T/bin:$PATH" "$@" ); }

rc=0; msg=$(runrs env -u OP_SERVICE_ACCOUNT_TOKEN ./resolve-secrets 2>&1) || rc=$?
check "resolve-secrets exits 1 without token" test "$rc" -eq 1
check "  ...with a clear message" bash -c 'grep -q OP_SERVICE_ACCOUNT_TOKEN <<<"$1"' _ "$msg"

ALW="$T/home/.config/agent-containers/$NAME.allowlist"
rc=0; msg=$(runrs env OP_SERVICE_ACCOUNT_TOKEN=tok ./resolve-secrets 2>&1) || rc=$?
check "resolve-secrets refuses when the host allowlist is missing" test "$rc" -ne 0
check "  ...naming the host allowlist path" bash -c 'grep -q "agent-containers/demo-proj.allowlist" <<<"$1"' _ "$msg"
mkdir -p "$(dirname "$ALW")"; printf 'www.python.org\n' > "$ALW"
rc=0; msg=$(runrs env OP_SERVICE_ACCOUNT_TOKEN=tok ./resolve-secrets 2>&1) || rc=$?
check "resolve-secrets succeeds with stub op" test "$rc" -eq 0
check "output env file mode 600"  test "$(stat -c %a "$OUT")" = 600
check "env dir mode 700"          test "$(stat -c %a "$T/home/.config/agent-containers")" = 700
check "no secret value in stdout/stderr" bash -c '! grep -q fake-secret-value-123 <<<"$1"' _ "$msg"
check ".env has normalised PROJECT"              grep -qx "PROJECT=$NAME" "$P/.env"
check ".env has COMPOSE_PROJECT_NAME"            grep -qx "COMPOSE_PROJECT_NAME=$NAME" "$P/.env"
# re-run over a wider-mode file must not keep the wider mode
chmod 644 "$OUT"; runrs env OP_SERVICE_ACCOUNT_TOKEN=tok ./resolve-secrets >/dev/null
check "overwrite resets mode to 600" test "$(stat -c %a "$OUT")" = 600

# ---- the divergence guard: compose in that dir (as VS Code would run it, no PROJECT in env)
cfg(){ ( cd "$P"; env -u PROJECT -u COMPOSE_PROJECT_NAME HOME="$T/home" DOCKER_CONFIG="$REAL_HOME/.docker" \
        SPADES_AI_DIR="$T/spades.ai" docker compose config --format json ); }
J="$(cfg)"
check "compose project name == $NAME (not project-template)" test "$(jq -r .name <<<"$J")" = "$NAME"
check "env_file resolved to THIS project's env file" test "$(jq -r .services.agent.environment.STUB_MARK <<<"$J")" = ok
check "claude volume is claude-$NAME" test "$(jq -r '.volumes["claude-config"].name' <<<"$J")" = "claude-$NAME"
check "rlib volume is rlib-$NAME" test "$(jq -r '.volumes["rlib"].name' <<<"$J")" = "rlib-$NAME"
check "rlib mounted at the setupProject library root" \
  test "$(jq -r '.services.agent.volumes[] | select(.source=="rlib") | .target' <<<"$J")" = "/home/agent/.local/share/R"

# ---- I2b: the project allowlist must NOT be reachable through any agent-writable mount
FWT=/etc/firewall/allowlist.d/50-project.txt
fwm(){ jq -c --arg t "$FWT" '.services.agent.volumes[] | select(.target==$t)' <<<"$J"; }
check "exactly one mount provides $FWT" test "$(fwm | wc -l)" -eq 1
check "allowlist source is the owner-maintained host file" \
  test "$(fwm | jq -r .source)" = "$T/home/.config/agent-containers/$NAME.allowlist"
check "allowlist mount is read-only" test "$(fwm | jq -r .read_only)" = true
# (compose renders create_host_path only when true; absent == false for the long syntax)
check "allowlist mount never auto-creates its source" test "$(fwm | jq -r '.bind.create_host_path // false')" = false
check "nothing else is mounted under /etc/firewall" \
  test "$(jq -r '[.services.agent.volumes[] | select(.target | startswith("/etc/firewall"))] | length' <<<"$J")" = 1
# No rw bind may contain (or equal) the allowlist source: the workspace bind in particular.
src="$(fwm | jq -r .source)"
rwsrcs="$(jq -r '.services.agent.volumes[] | select(.type=="bind" and (.read_only|not)) | .source' <<<"$J")"
check "no rw bind mount contains the allowlist source (workspace included)" \
  bash -c 'while IFS= read -r r; do [ -z "$r" ] && continue; case "$1/" in "${r%/}/"*) echo "rw $r contains $1"; exit 1;; esac; done <<<"$2"' _ "$src" "$rwsrcs"
check "the workspace rw bind does not contain the allowlist" bash -c 'case "$1" in "$2"/*) exit 1;; esac' _ "$src" "$P"
check "~/.config/agent-containers itself is never mounted" \
  bash -c '! jq -r ".services.agent.volumes[].source" <<<"$1" | grep -qx "$2"' _ "$J" "$T/home/.config/agent-containers"

# ---- behavioural (CI: TEMPLATE_IMAGE=spades-base:ci): the template's REAL mounts, on its compose
# network, against the built image. The agent edits the workspace allowlist.txt and re-runs the
# firewall; the in-container allowlist must not change and the new name must not resolve.
if [ -n "${TEMPLATE_IMAGE:-}" ]; then
  docker image inspect "$TEMPLATE_IMAGE" >/dev/null 2>&1 || { echo "FAIL: TEMPLATE_IMAGE=$TEMPLATE_IMAGE not present"; exit 1; }
  cat > "$T/override.yaml" <<OVR
services:
  agent:
    image: $TEMPLATE_IMAGE
    mem_limit: 4g
    command: bash -c "sudo /usr/local/bin/init-firewall.sh && touch /tmp/fw-ready && exec sleep infinity"
OVR
  dc(){ ( cd "$P"; env -u PROJECT -u COMPOSE_PROJECT_NAME HOME="$T/home" DOCKER_CONFIG="$REAL_HOME/.docker" \
          SPADES_AI_DIR="$T/spades.ai" docker compose -f compose.yaml -f "$T/override.yaml" "$@" ); }
  trap 'dc down -v >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
  chmod 666 "$P/allowlist.txt"     # the agent owns its workspace in real use
  check "template container starts" dc up -d
  C="$(dc ps -q agent)"
  for _ in $(seq 1 90); do docker exec "$C" test -e /tmp/fw-ready 2>/dev/null && break; sleep 2; done
  check "firewall initialised in the template container" docker exec "$C" test -e /tmp/fw-ready
  check "in-container allowlist == host file" bash -c 'diff <(docker exec "$1" cat '"$FWT"') "$2"' _ "$C" "$ALW"
  check "agent cannot write the in-container allowlist" \
    bash -c '! docker exec -u agent "$1" sh -c "echo example.com >> '"$FWT"'" 2>/dev/null' _ "$C"
  check "agent CAN edit the workspace allowlist.txt (precondition)" \
    docker exec -u agent "$C" sh -c 'echo example.com >> /workspace/allowlist.txt'
  check "agent can re-run the firewall" docker exec -u agent "$C" sudo /usr/local/bin/init-firewall.sh
  check "workspace edit did not reach the in-container allowlist" \
    bash -c '! docker exec "$1" grep -q example.com '"$FWT" _ "$C"
  check "workspace edit did not allow example.com (no DNS answer)" \
    bash -c '[ -z "$(docker exec -u agent "$1" dig @127.0.0.1 example.com A +short +time=2 +tries=1 | grep -E "^[0-9.]+$")" ]' _ "$C"
  check "host-allowlisted www.python.org resolves after the re-run" \
    bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 www.python.org A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$C"
  check "agent cannot use Docker DNS 127.0.0.11 on the compose network" \
    bash -c '[ -z "$(docker exec -u agent "$1" dig @127.0.0.11 example.com A +short +time=2 +tries=1 | grep -E "^[0-9.]+$")" ]' _ "$C"
  dc down -v >/dev/null 2>&1 || true
else
  echo "SKIP: behavioural template checks (set TEMPLATE_IMAGE to a built image; CI does)"
fi

[ "$fail" -eq 0 ] && echo "TEMPLATE: ALL PASSED" || { echo "TEMPLATE: FAILURES"; exit 1; }
