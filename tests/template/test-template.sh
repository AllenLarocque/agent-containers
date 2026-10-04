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

[ "$fail" -eq 0 ] && echo "TEMPLATE: ALL PASSED" || { echo "TEMPLATE: FAILURES"; exit 1; }
