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
sed -i "s/REPLACE_WITH_DIGEST_FROM_digests.md/$H64/" "$P/compose.yaml"   # so ./up's check-digest passes
git -C "$P" init -q
NAME=demo-proj
CFG="$T/home/.config/agent-containers"
OUT="$CFG/$NAME.env"; ALW="$CFG/$NAME.allowlist"; SUMS="$CFG/$NAME.launcher.sha256"
DLOG="$T/docker.log"
mkdir -p "$T/dockerstub"
cat > "$T/dockerstub/docker" <<STUB
#!/usr/bin/env bash
# stub docker for ./up: records how it was called and the compose-relevant environment
{ echo "ARGS: \$*"
  echo "ENV: COMPOSE_FILE=\${COMPOSE_FILE-<unset>} COMPOSE_PROFILES=\${COMPOSE_PROFILES-<unset>} COMPOSE_PATH_SEPARATOR=\${COMPOSE_PATH_SEPARATOR-<unset>} SPADES_AI_DIR=\${SPADES_AI_DIR-<unset>}"; } >> "$DLOG"
exit 0
STUB
chmod +x "$T/dockerstub/docker"
runrs(){ ( cd "$P"; HOME="$T/home" PATH="$T/bin:$PATH" "$@" ); }
runup(){ ( cd "$P"; HOME="$T/home" PATH="$T/dockerstub:$T/bin:$PATH" SPADES_AI_DIR="$T/spades.ai" "$@" ); }
refuses(){ # $1 label, $2 ERE the message must match, rest = command; must exit non-zero
  local d="$1" re="$2" rc=0 msg; shift 2
  msg=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq -- "$re" <<<"$msg"; then echo "OK:   $d"
  else echo "FAIL: $d (rc=$rc, want non-zero and /$re/)"; printf '%s\n' "$msg" | sed 's/^/        /'; fail=1; fi
}
TOK=(env OP_SERVICE_ACCOUNT_TOKEN=tok)
fresh_env(){ rm -f "$P/.env" "$P/.env.tmp"; runrs "${TOK[@]}" ./resolve-secrets >/dev/null 2>&1; }

# ---- launcher integrity: nothing runs until the owner adopts the launcher files
refuses "resolve-secrets refuses an unadopted launcher" 'not adopted.*--adopt' runrs "${TOK[@]}" ./resolve-secrets
refuses "up refuses an unadopted launcher"              'not adopted.*--adopt' runup "${TOK[@]}" ./up
check "  ...and never reached docker" test ! -e "$DLOG"

# --adopt records the hashes OUTSIDE the workspace, then continues (here: stops at the missing allowlist)
refuses "resolve-secrets --adopt, then refuses when the host allowlist is missing" "agent-containers/$NAME\.allowlist" \
  runrs "${TOK[@]}" ./resolve-secrets --adopt
check "adoption wrote $SUMS" test -f "$SUMS"
check "  ...mode 600" test "$(stat -c %a "$SUMS")" = 600
check "  ...outside the workspace" bash -c 'case "$1" in "$2"/*) exit 1;; esac' _ "$SUMS" "$P"
check "  ...covering exactly the launcher files" bash -c 'diff <(awk "{print \$2}" "$1") <(printf "%s\n" compose.yaml up resolve-secrets check-digest project.env .pre-commit-config.yaml .devcontainer/devcontainer.json)' _ "$SUMS"

rc=0; msg=$(runrs env -u OP_SERVICE_ACCOUNT_TOKEN ./resolve-secrets 2>&1) || rc=$?
check "resolve-secrets exits 1 without token" test "$rc" -eq 1
check "  ...with a clear message" bash -c 'grep -q OP_SERVICE_ACCOUNT_TOKEN <<<"$1"' _ "$msg"

mkdir -p "$(dirname "$ALW")"; printf 'www.python.org\n' > "$ALW"
rc=0; msg=$(runrs "${TOK[@]}" ./resolve-secrets 2>&1) || rc=$?
check "resolve-secrets succeeds with stub op" test "$rc" -eq 0
check "output env file mode 600"  test "$(stat -c %a "$OUT")" = 600
check "env dir mode 700"          test "$(stat -c %a "$CFG")" = 700
check "no secret value in stdout/stderr" bash -c '! grep -q fake-secret-value-123 <<<"$1"' _ "$msg"
check ".env has normalised PROJECT"              grep -qx "PROJECT=$NAME" "$P/.env"
check ".env has COMPOSE_PROJECT_NAME"            grep -qx "COMPOSE_PROJECT_NAME=$NAME" "$P/.env"
check ".env holds ONLY the two identity keys"    test "$(wc -l < "$P/.env")" -eq 2
check "no temp files left beside .env" bash -c '! ls -A "$1" | grep -q "^\.env\."' _ "$P"
# re-run over a wider-mode file must not keep the wider mode
chmod 644 "$OUT"; runrs "${TOK[@]}" ./resolve-secrets >/dev/null
check "overwrite resets mode to 600" test "$(stat -c %a "$OUT")" = 600

# ---- .env is identity-only and never written through a symlink
printf 'SPADES_AI_DIR=%s\n' "$CFG" >> "$P/.env"
refuses "resolve-secrets refuses .env with an extra SPADES_AI_DIR key" '\.env.*SPADES_AI_DIR' runrs "${TOK[@]}" ./resolve-secrets
refuses "up refuses .env with an extra SPADES_AI_DIR key"              '\.env.*SPADES_AI_DIR' runup "${TOK[@]}" ./up
fresh_env
printf 'COMPOSE_FILE=evil.yaml\n' >> "$P/.env"
refuses "up refuses .env with COMPOSE_FILE" '\.env.*COMPOSE_FILE' runup "${TOK[@]}" ./up
check "  ...and never reached docker" test ! -e "$DLOG"
rm -f "$P/.env"; ln -s "$T/evil-env-target" "$P/.env"
refuses "a symlinked .env is refused" '\.env.*symlink' runrs "${TOK[@]}" ./resolve-secrets
check "  ...nothing written through it" test ! -e "$T/evil-env-target"
rm -f "$P/.env"; ln -s "$T/evil-tmp-target" "$P/.env.tmp"
refuses "a symlinked .env.tmp is refused" '\.env\.tmp.*symlink' runrs "${TOK[@]}" ./resolve-secrets
check "  ...nothing written through it" test ! -e "$T/evil-tmp-target"
fresh_env

# ---- tampered launcher files are refused until re-adopted
cp "$P/compose.yaml" "$T/compose.bak"; echo '# tampered' >> "$P/compose.yaml"
refuses "up refuses a tampered compose.yaml"             'changed since adoption.*compose\.yaml|compose\.yaml.*changed since adoption' runup "${TOK[@]}" ./up
refuses "resolve-secrets refuses a tampered compose.yaml" 'changed since adoption' runrs "${TOK[@]}" ./resolve-secrets
refuses "  ...and says how to re-adopt" '--adopt' runrs "${TOK[@]}" ./resolve-secrets
cp "$T/compose.bak" "$P/compose.yaml"
cp "$P/up" "$T/up.bak"; echo '# tampered' >> "$P/up"
refuses "resolve-secrets refuses a tampered up" 'changed since adoption' runrs "${TOK[@]}" ./resolve-secrets
cp "$T/up.bak" "$P/up"
printf '{}\n' > "$P/.devcontainer/extra.json"
refuses "an extra file in .devcontainer/ is refused" 'changed since adoption' runrs "${TOK[@]}" ./resolve-secrets
rm -f "$P/.devcontainer/extra.json"
check "launcher verifies again once restored" runrs "${TOK[@]}" ./resolve-secrets

# ---- other host-executed files: git config keys, git hooks, a root .devcontainer.json
for k in core.fsmonitor core.hooksPath core.sshCommand; do
  git -C "$P" config "$k" "/tmp/evil"
  refuses "up refuses .git/config $k" "$(tr 'A-Z' 'a-z' <<<"$k")" runup "${TOK[@]}" ./up
  git -C "$P" config --unset "$k"
done
printf '[core]\n\tfsmonitor = /tmp/evil\n' > "$P/.git/evil.cfg"; git -C "$P" config include.path evil.cfg
refuses "up refuses an included config setting core.fsmonitor" 'core\.fsmonitor|include\.path' runup "${TOK[@]}" ./up
git -C "$P" config --unset include.path; rm -f "$P/.git/evil.cfg"
printf '#!/bin/sh\necho evil\n' > "$P/.git/hooks/post-checkout"; chmod +x "$P/.git/hooks/post-checkout"
refuses "up refuses a git hook that is not in the launcher checksum" 'post-checkout' runup "${TOK[@]}" ./up
check "an adopted hook is accepted" runup "${TOK[@]}" ./up --adopt
rm -f "$P/.git/hooks/post-checkout"
refuses "removing an adopted hook also needs re-adoption" 'changed since adoption' runup "${TOK[@]}" ./up
runup "${TOK[@]}" ./up --adopt >/dev/null 2>&1
printf 'x\n' > "$P/.git/hooks/new-thing.sample"
check "a new *.sample hook file is ignored" runrs "${TOK[@]}" ./resolve-secrets
rm -f "$P/.git/hooks/new-thing.sample"
printf '{}\n' > "$P/.devcontainer.json"
refuses "up refuses a root .devcontainer.json" '\.devcontainer\.json' runup "${TOK[@]}" ./up
rm -f "$P/.devcontainer.json"

# ---- ./up itself: only compose.yaml, ambient COMPOSE_* ignored, SPADES_AI_DIR from the owner's shell
rm -f "$DLOG"
check "up succeeds (stub docker) with hostile COMPOSE_* in the environment" \
  runup env OP_SERVICE_ACCOUNT_TOKEN=tok COMPOSE_FILE=evil.yaml COMPOSE_PROFILES=evil COMPOSE_PATH_SEPARATOR=: ./up
check "  ...compose called with -f compose.yaml -p $NAME" grep -qx "ARGS: compose -f compose.yaml -p $NAME up -d --force-recreate" "$DLOG"
check "  ...COMPOSE_FILE/PROFILES/PATH_SEPARATOR unset for docker" \
  bash -c 'grep "^ENV:" "$1" | grep -qv "COMPOSE_FILE=<unset> COMPOSE_PROFILES=<unset> COMPOSE_PATH_SEPARATOR=<unset>" && exit 1; grep -q "^ENV:" "$1"' _ "$DLOG"
check "  ...SPADES_AI_DIR from the owner's shell" grep -q "SPADES_AI_DIR=$T/spades.ai\$" "$DLOG"
check "  ....env still holds only the identity keys" test "$(wc -l < "$P/.env")" -eq 2

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
check "the agent-containers config dir itself is never mounted" \
  bash -c '! jq -r ".services.agent.volumes[].source" <<<"$1" | grep -qx "$2"' _ "$J" "$T/home/.config/agent-containers"

# ---- CRITICAL-1: host-read/executed files are overlaid READ-ONLY over the rw workspace
OVERLAYS=(compose.yaml up resolve-secrets check-digest project.env .env .pre-commit-config.yaml .devcontainer .git/hooks)
for o in "${OVERLAYS[@]}"; do
  m=$(jq -c --arg t "/workspace/$o" '.services.agent.volumes[] | select(.target==$t)' <<<"$J")
  check "ro overlay for $o" bash -c '[ "$(jq -r .source <<<"$1")" = "$2" ] && [ "$(jq -r .read_only <<<"$1")" = true ]' _ "$m" "$P/$o"
done

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
  chmod -R a+rwX "$P"     # the agent owns its workspace in real use: a refusal below must be the ro overlay
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
  # The agent cannot write, rename or delete any overlaid launcher file (the workspace itself is rw).
  check "precondition: agent can create, rename and delete a workspace file" \
    docker exec -u agent "$C" sh -c 'echo x > /workspace/scratch && mv /workspace/scratch /workspace/scratch2 && rm /workspace/scratch2'
  for o in compose.yaml up resolve-secrets check-digest project.env .env .pre-commit-config.yaml .devcontainer/devcontainer.json; do
    check "agent cannot write $o"  bash -c '! docker exec -u agent "$1" sh -c "echo x >> /workspace/$2" 2>/dev/null' _ "$C" "$o"
    check "agent cannot rename $o" bash -c '! docker exec -u agent "$1" mv "/workspace/$2" "/workspace/$2.moved" 2>/dev/null' _ "$C" "$o"
    check "agent cannot delete $o" bash -c '! docker exec -u agent "$1" rm -f "/workspace/$2" 2>/dev/null' _ "$C" "$o"
  done
  for d in .devcontainer .git/hooks; do
    check "agent cannot add a file to $d" bash -c '! docker exec -u agent "$1" touch "/workspace/$2/evil" 2>/dev/null' _ "$C" "$d"
    check "agent cannot rename $d"        bash -c '! docker exec -u agent "$1" mv "/workspace/$2" "/workspace/$2.moved" 2>/dev/null' _ "$C" "$d"
    check "agent cannot delete $d"        bash -c '! docker exec -u agent "$1" rm -rf "/workspace/$2" 2>/dev/null' _ "$C" "$d"
  done
  check "launcher still verifies after the agent's attempts" runrs "${TOK[@]}" ./resolve-secrets
  dc down -v >/dev/null 2>&1 || true
else
  echo "SKIP: behavioural template checks (set TEMPLATE_IMAGE to a built image; CI does)"
fi

[ "$fail" -eq 0 ] && echo "TEMPLATE: ALL PASSED" || { echo "TEMPLATE: FAILURES"; exit 1; }
