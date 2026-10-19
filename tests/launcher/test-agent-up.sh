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
if [ "${1-}" = read ]; then   # op read "op://Personal/agent-<n> service account/credential"
  n="${2#op://Personal/agent-}"; n="${n%% service account/*}"
  [ ! -f "$(dirname "$OPLOG")/OPREAD_FAIL_$n" ] || exit 1
  echo "sat-$n"; exit 0
fi
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
GH_TOKEN=fake-secret-value-123 exec "$@"
STUB
# stub docker: log the arguments and the environment that matters, succeed
cat > "$T/dstub/docker" <<'STUB'
#!/usr/bin/env bash
{ echo "ARGS: $*"
  echo "ENV: COMPOSE_FILE=${COMPOSE_FILE-<unset>} COMPOSE_PROFILES=${COMPOSE_PROFILES-<unset>} PROJECT_DIR=${PROJECT_DIR-<unset>} SPADES_AI_DIR=${SPADES_AI_DIR-<unset>} GH_TOKEN=${GH_TOKEN-<unset>}"
  echo "OPTOK: ${OP_SERVICE_ACCOUNT_TOKEN-<unset>}"
} >> "$DLOG"
case "$*" in
  "inspect -f {{.State.Running}} "*)
    sd="$(dirname "$DLOG")"
    if { [ -f "$sd/RUNNING" ] && [ "$(cat "$sd/RUNNING")" = 0 ]; } || { [ -f "$sd/RUNNING.$4" ] && [ "$(cat "$sd/RUNNING.$4")" = 0 ]; }; then echo false; else echo true; fi ;;
  "exec "*" ps -eo pid=,ppid=,etimes=,cputimes=,comm=,args=")   # first call: $sd/ps.<c>.1, second: .2 (per container: busy --all scans in parallel)
    sd="$(dirname "$DLOG")"; n=$(( $(cat "$sd/ps.$2.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$sd/ps.$2.count"
    cat "$sd/ps.$2.$n" 2>/dev/null || true ;;
  *"agent-t3 pair"*)
    sd="$(dirname "$DLOG")"; n=$(( $(cat "$sd/pair.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$sd/pair.count"
    if [ -f "$sd/PAIR_FAILS" ] && [ "$n" -le "$(cat "$sd/PAIR_FAILS")" ]; then exit 1; fi
    echo "token=fakeTok_123" ;;
  "inspect -f {{range .Config.Env}}{{println .}}{{end}} "*)
    sd="$(dirname "$DLOG")"; [ ! -f "$sd/proto.$4" ] || echo "T3_PROTOCOL=$(cat "$sd/proto.$4")" ;;
  "exec -u agent "*" t3 --version") echo "0.9.9" ;;
  "compose "*" up -d"*)   # a test can make one project's `up` fail, or move its protocol marker
    sd="$(dirname "$DLOG")"; pn="$*"; pn="${pn#*-p }"; pn="${pn%% *}"
    [ ! -f "$sd/UPFAIL.$pn" ] || exit 1
    [ ! -f "$sd/proto.$pn-agent-1.new" ] || cp "$sd/proto.$pn-agent-1.new" "$sd/proto.$pn-agent-1" ;;
  "exec -u agent "*" claude --version")   # CLI_FAILS=N: the first N calls fail (CLIs still installing at container start)
    sd="$(dirname "$DLOG")"; n=$(( $(cat "$sd/cli.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$sd/cli.count"
    if [ -f "$sd/CLI_FAILS" ] && [ "$n" -le "$(cat "$sd/CLI_FAILS")" ]; then exit 1; fi
    echo "9.9.9 (Claude Code)" ;;
  "exec -u agent "*" codex --version")
    sd="$(dirname "$DLOG")"
    if [ -f "$sd/CLI_FAILS" ] && [ "$(cat "$sd/cli.count" 2>/dev/null || echo 0)" -le "$(cat "$sd/CLI_FAILS")" ]; then exit 1; fi
    echo "codex-cli 8.8.8" ;;
esac
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
refuses "init --profile research refuses a project directory" 'takes no project directory' au init "$P" --profile research
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
check "project.conf: first project gets T3_PORT=3773" grep -qx "T3_PORT=3773" "$CFG/project.conf"
check "project.conf: T3_CONNECT=0 (T3 Connect is opt-in)" grep -qx "T3_CONNECT=0" "$CFG/project.conf"
check "project.conf: RESEARCH=0 (opt-in), RESEARCH_DIR=~/agent-research" \
  bash -c 'grep -qx "RESEARCH=0" "$1" && grep -qx "RESEARCH_DIR=$2/agent-research" "$1"' _ "$CFG/project.conf" "$H"
check "a builder init does not create the research exchange" test ! -e "$H/agent-research"
check "project.conf: RSTUDIO=0 (RStudio Server is opt-in)" grep -qx "RSTUDIO=0" "$CFG/project.conf"
check "project.conf: first project gets RSTUDIO_PORT=8787" grep -qx "RSTUDIO_PORT=8787" "$CFG/project.conf"
check "project.env names this project's vault" grep -q "op://agent-$NAME/github-agent/token" "$CFG/project.env"
check "compose uses spades-gis by default, digest placeholder kept" \
  grep -q "spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md" "$CFG/compose.yaml"
check "repo seed CODEOWNERS copied into the project" grep -q "^\* @OWNER" "$P/.github/CODEOWNERS"
check "repo seed .gitignore copied into the project (incl. .Rproj.user/)" grep -qx ".Rproj.user/" "$P/.gitignore"
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
check "  ...second project gets the next free T3_PORT (3774)" grep -qx "T3_PORT=3774" "$CFGROOT/bio2/project.conf"
check "  ...and the next free RSTUDIO_PORT (8788)" grep -qx "RSTUDIO_PORT=8788" "$CFGROOT/bio2/project.conf"
check "project.conf (gis): FTP_HOSTS documented but commented out and empty (FTP is opt-in)" \
  bash -c 'grep -qx "#FTP_HOSTS=" "$1" && ! grep -q "^FTP_HOSTS" "$1"' _ "$CFG/project.conf"
check "project.conf (bio): FTP_HOSTS seeded COMMENTED OUT with ENA Webin; SRA named in the comment" \
  bash -c 'grep -qx "#FTP_HOSTS=webin2.ebi.ac.uk" "$1" && grep -q "^#.*ftp-private\.ncbi\.nlm\.nih\.gov" "$1" && ! grep -q "^FTP_HOSTS" "$1"' _ "$CFGROOT/bio2/project.conf"
check "  ...and the comment warns that FTP is cleartext" grep -q "^#.*CLEARTEXT" "$CFGROOT/bio2/project.conf"

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
refuses "refusal: research with a project dir (again)" 'takes no project directory' au init "$P" --profile research --name zz
refuses "refusal: a builder named research" "'research' is reserved" au init "$P" --name research
refuses "refusal: an unknown profile" 'builder or research' au init "$P" --profile foo --name zz
refuses "refusal: unknown image (again)" 'base, gis or bio' au init "$P" --image foo --name zz
refuses "refusal: a builder with --image research" 'research container only' au init "$P" --image research --name zz
refuses "--image foo still refused" '--image must be' au init "$P" --image foo --name zz
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
cp "$CFG/compose.yaml" "$T/compose-img.bak"
sed -i -E "s|^( *image: *).*|\\1ghcr.io/allenlarocque/spades-research@sha256:$H64|" "$CFG/compose.yaml"
refuses "up refuses a builder pinned to spades-research" 'spades-research is for the research container only' au up "$NAME"
refuses "config refuses a builder pinned to spades-research" 'spades-research is for the research container only' au config "$NAME"
cp "$T/compose-img.bak" "$CFG/compose.yaml"
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
refuses "up refuses a workspace that contains the config dir" 'overlaps the config root' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
cp "$CFG/project.env" "$T/penv.bak"; echo 'PROJECT_DIR=op://v/i/f' >> "$CFG/project.env"
refuses "up refuses a reserved key name in project.env" 'reserved' au up "$NAME"
cp "$T/penv.bak" "$CFG/project.env"
cp "$CFG/project.conf" "$T/pconf.bak"; sed -i "s|^PROFILE=.*|PROFILE=research|" "$CFG/project.conf"
refuses "up refuses PROFILE=research on a project (only the shared research container)" 'only the shared research container' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
sed -i "s|^IMAGE=.*|IMAGE=foo|" "$CFG/project.conf"
refuses "up refuses an unknown IMAGE" 'IMAGE=foo.*base, gis or bio' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$ROOT|" "$CFG/project.conf"
refuses "up refuses a rw mount containing the launcher clone" 'overlaps the agent-containers clone .*agent could rewrite what the host runs. Use a separate agent-only clone' au up "$NAME"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$CFGROOT|" "$CFG/project.conf"
refuses "up refuses a rw mount equal to the config root" 'overlaps the config root .*agent could rewrite what the host runs' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
mv "$CFG/allowlist" "$T/allowlist.off"
refuses "up refuses a missing allowlist" 'missing .*allowlist' au up "$NAME"
mv "$T/allowlist.off" "$CFG/allowlist"
# a rw source INSIDE (or equal to) a protected path is as bad as one containing it
mkdir -p "$CFG/.generated"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$CFGROOT/bio2|" "$CFG/project.conf"
refuses "up refuses PROJECT_DIR inside the config root (another project's config)" 'PROJECT_DIR \(.*/bio2\) overlaps the config root ' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$CFG/.generated|" "$CFG/project.conf"
refuses "up refuses PROJECT_DIR inside this project's config (.generated)" 'PROJECT_DIR \(.*/\.generated\) overlaps the config root ' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$ROOT/bin|" "$CFG/project.conf"
refuses "up refuses PROJECT_DIR inside the agent-containers clone (bin)" 'PROJECT_DIR \(.*/bin\) overlaps the agent-containers clone ' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
sed -i "s|^SPADES_AI_DIR=.*|SPADES_AI_DIR=$ROOT|" "$CFG/project.conf"
refuses "up refuses SPADES_AI_DIR equal to the agent-containers clone" 'SPADES_AI_DIR \(.*\) overlaps the agent-containers clone ' au up "$NAME"
cp "$T/pconf.bak" "$CFG/project.conf"
# COMPOSE is the launcher's internal array: reserved; config validates project.env too
cp "$CFG/project.env" "$T/penv.bak"; echo 'COMPOSE=op://v/i/f' >> "$CFG/project.env"
refuses "config refuses a reserved COMPOSE key in project.env" 'reserved' au config "$NAME"
cp "$T/penv.bak" "$CFG/project.env"
check "a refused up never reached docker" test ! -e "$DLOG"

# ---- up: pre-flight refusals (continued)
cp "$CFG/project.conf" "$T/pconf.bak2"
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=/|" "$CFG/project.conf"
refuses "up refuses PROJECT_DIR=/ (overlaps the config root)" 'overlaps the config root' au up "$NAME"
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
C="compose --env-file $CFG/project.conf -f $CFG/compose.yaml -f $CFG/.generated/env-passthrough.yaml -f $CFG/.generated/t3-connect.yaml -f $CFG/.generated/research.yaml -f $CFG/.generated/rstudio.yaml -f $CFG/.generated/ftp.yaml -f $CFG/.generated/hostname.yaml -f $CFG/.generated/restart.yaml --project-directory $CFG -p $NAME"
check "  ...op run resolves project.env, then runs docker compose" \
  grep -qxF "OP: run --env-file $CFG/project.env -- docker $C up -d --force-recreate" "$OPLOG"
check "  ...docker compose gets ONLY the config dir's files" grep -qxF "ARGS: $C up -d --force-recreate" "$DLOG"
check "  ...ambient COMPOSE_*/PROJECT_DIR/SPADES_AI_DIR unset; the resolved secret reaches compose" \
  bash -c '[ "$(grep "^ENV:" "$1" | tail -n 1)" = "ENV: COMPOSE_FILE=<unset> COMPOSE_PROFILES=<unset> PROJECT_DIR=<unset> SPADES_AI_DIR=<unset> GH_TOKEN=fake-secret-value-123" ]' _ "$DLOG"
check "  ...the shared Require cache volume is ensured" grep -qxF "ARGS: volume inspect require-cache-shared" "$DLOG"
check "  ...the shared npm cache volume is ensured" grep -qxF "ARGS: volume inspect npm-cache-shared" "$DLOG"
check "  ...no secret value on stdout/stderr" bash -c '! grep -q fake-secret-value-123 <<<"$1"' _ "$out"
PT="$CFG/.generated/env-passthrough.yaml"
check "passthrough lists the key NAME" grep -qx "      - GH_TOKEN" "$PT"
check "  ...and holds no value or reference" bash -c '! grep -Eq "fake-secret|op://|=" "$1"' _ "$PT"
T3O="$CFG/.generated/t3-connect.yaml"
check "T3_CONNECT=0: the T3 Connect overlay adds nothing" bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ]' _ "$T3O"
check "  ...and no firewall switch file exists" test ! -e "$CFG/.generated/t3-connect"
check "the container restarts with Docker (after a reboot) unless stopped by hand" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent:\n    restart: unless-stopped")" ]' _ "$CFG/.generated/restart.yaml"
check "the container gets a readable hostname (T3's environment name): the project name" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent:\n    hostname: demo-proj")" ]' _ "$CFG/.generated/hostname.yaml"
RO="$CFG/.generated/research.yaml"
check "RESEARCH=0: the research overlay adds nothing" bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ]' _ "$RO"
check "  ...no profile switch, no instructions file" bash -c '[ ! -e "$1/profile" ] && [ ! -e "$1/agent-instructions.md" ]' _ "$CFG/.generated"
RSO="$CFG/.generated/rstudio.yaml"
check "RSTUDIO=0: the RStudio overlay adds nothing" bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ]' _ "$RSO"
check "  ...no RStudio switch file and no password generated" bash -c '[ ! -e "$1/rstudio" ] && [ ! -e "$1/rstudio-password" ]' _ "$CFG/.generated"
FO="$CFG/.generated/ftp.yaml"
check "FTP_HOSTS unset: the FTP overlay adds nothing" bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ]' _ "$FO"
check "  ...and no FTP host file exists" test ! -e "$CFG/.generated/ftp-hosts"

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
statusout="$(au status "$NAME" 2>&1)" && rc=0 || rc=$?
check "status" test "$rc" -eq 0
check "  ...compose ps" grep -qxF "ARGS: $C ps" "$DLOG"
check "  ...reports the Claude Code version (from the container)" grep -qxF "Claude Code: 9.9.9 (Claude Code)" <<<"$statusout"
check "  ...reports the Codex version (from the container)" grep -qxF "Codex: codex-cli 8.8.8" <<<"$statusout"
check "  ...asked each CLI as agent in the project's container" \
  bash -c 'grep -qxF "ARGS: exec -u agent $2-agent-1 claude --version" "$1" && grep -qxF "ARGS: exec -u agent $2-agent-1 codex --version" "$1"' _ "$DLOG" "$NAME"
check "stop" au stop "$NAME"
check "  ...compose stop" grep -qxF "ARGS: $C stop" "$DLOG"
check "down" au down "$NAME"
check "  ...compose down WITHOUT -v (named volumes kept)" grep -qxF "ARGS: $C down" "$DLOG"
: > "$DLOG"
pairout="$(au pair "$NAME" 2>&1)" || true
check "pair prints a per-project origin link on this project's T3_PORT" grep -qxF "  http://demo-proj.localhost:3773/pair#token=fakeTok_123" <<<"$pairout"
check "  ...and a plain localhost fallback" grep -qF "http://localhost:3773/pair#token=fakeTok_123" <<<"$pairout"
check "  ...minted inside the container, as agent" grep -qE "^ARGS: exec -u agent $NAME-agent-1 agent-t3 pair " "$DLOG"
cp "$CFG/project.conf" "$T/pconf-t3.bak"
sed -i 's/^T3_PORT=.*/T3_PORT=80/' "$CFG/project.conf"
refuses "a privileged/invalid T3_PORT is refused" 'T3_PORT=.80.' au pair "$NAME"
sed -i '/^T3_PORT=/d' "$CFG/project.conf"
refuses "a missing T3_PORT is refused" "T3_PORT=''" au pair "$NAME"
check "stop works on a config that predates T3 (no T3_PORT)" au stop "$NAME"
check "down works on a config that predates T3 (no T3_PORT)" au down "$NAME"
cp "$T/pconf-t3.bak" "$CFG/project.conf"
cp "$CFGROOT/bio2/project.conf" "$T/bio2conf.bak"; sed -i 's/^T3_PORT=.*/T3_PORT=3773/' "$CFGROOT/bio2/project.conf"
refuses "a T3_PORT used by another project is refused" 'T3_PORT=3773 .* also used by bio2' au pair "$NAME"
cp "$T/bio2conf.bak" "$CFGROOT/bio2/project.conf"

# ---- Tailscale addresses (shared $CFG_ROOT/agent-up.conf + per-project TAILSCALE_HTTPS_PORT)
AUC="$CFGROOT/agent-up.conf"
pairout="$(au pair "$NAME" 2>&1)" || true
check "pair: desktop app address on this PC" grep -qxF "  desktop app on this PC: http://localhost:3773" <<<"$pairout"
check "  ...phone address uses a placeholder host and the computed port" grep -qxF "  phone (Tailscale on):   https://<tailnet-host>:8442" <<<"$pairout"
check "  ...pairing code on its own line" grep -qxF "  pairing code: fakeTok_123" <<<"$pairout"
check "  ...hint to set TAILSCALE_HOST" grep -qF "set TAILSCALE_HOST in $AUC" <<<"$pairout"
check "  ...the browser-link lines stay" grep -qxF "  http://demo-proj.localhost:3773/pair#token=fakeTok_123" <<<"$pairout"
echo "TAILSCALE_HOST=box.tail1.ts.net" > "$AUC"
pairout="$(au pair "$NAME" 2>&1)" || true
check "pair with TAILSCALE_HOST: phone address" grep -qxF "  phone (Tailscale on):   https://box.tail1.ts.net:8442" <<<"$pairout"
check "  ...no hint any more" bash -c '! grep -q "set TAILSCALE_HOST" <<<"$1"' _ "$pairout"
upout="$(au up "$NAME" 2>&1)" || true
check "up prints the Tailscale Serve command" grep -qxF "agent-up: Tailscale (once, Windows PowerShell): tailscale serve --bg --https=8442 3773" <<<"$upout"
echo "TAILSCALE_HTTPS_PORT=443" >> "$CFG/project.conf"
pairout="$(au pair "$NAME" 2>&1)" || true
check "TAILSCALE_HTTPS_PORT=443: phone address has no :443" grep -qxF "  phone (Tailscale on):   https://box.tail1.ts.net" <<<"$pairout"
upout="$(au up "$NAME" 2>&1)" || true
check "  ...and up prints --https=443" grep -qF "tailscale serve --bg --https=443 3773" <<<"$upout"
cp "$T/pconf-t3.bak" "$CFG/project.conf"
pairout="$(au pair bio2 2>&1)" || true
check "a T3_PORT=3774 project gets 8443 (bio2)" grep -qxF "  phone (Tailscale on):   https://box.tail1.ts.net:8443" <<<"$pairout"
pairout="$(au pair symproj1 2>&1)" || true
check "a T3_PORT=3775 project gets 8444 (symproj1)" grep -qxF "  phone (Tailscale on):   https://box.tail1.ts.net:8444" <<<"$pairout"
cp "$T/bio2conf.bak" "$CFGROOT/bio2/project.conf"
echo "TAILSCALE_HTTPS_PORT=8442" >> "$CFGROOT/bio2/project.conf"
refuses "up refuses a TAILSCALE_HTTPS_PORT used by another project" 'TAILSCALE_HTTPS_PORT.*also used by demo-proj' au up bio2
refuses "pair refuses a TAILSCALE_HTTPS_PORT used by another project" 'TAILSCALE_HTTPS_PORT.*also used by demo-proj' au pair bio2
cp "$T/bio2conf.bak" "$CFGROOT/bio2/project.conf"
echo "TAILSCALE_HTTPS_PORT=08442" >> "$CFGROOT/bio2/project.conf"
refuses "up refuses a zero-padded TAILSCALE_HTTPS_PORT (08442) that collides with 8442" 'TAILSCALE_HTTPS_PORT=8442.*also used by demo-proj' au up bio2
cp "$T/bio2conf.bak" "$CFGROOT/bio2/project.conf"
echo "TAILSCALE_HTTPS_PORT=08450" >> "$CFG/project.conf"
upout="$(au up "$NAME" 2>&1)" || true
check "zero-padded 08450 is printed as 8450" grep -qF "tailscale serve --bg --https=8450 3773" <<<"$upout"
cp "$T/pconf-t3.bak" "$CFG/project.conf"
sed -i 's/^T3_PORT=.*/T3_PORT=08/' "$CFGROOT/bio2/project.conf"
upout="$(au up "$NAME" 2>&1)" || true
check "a neighbour with T3_PORT=08 causes no octal error" bash -c '! grep -q "value too great\|syntax error" <<<"$1"' _ "$upout"
cp "$T/bio2conf.bak" "$CFGROOT/bio2/project.conf"
for h in "https://x.ts.net" "a b" "x.ts.net/p" "UPPER.ts.net" "nodots"; do
  echo "TAILSCALE_HOST=$h" > "$AUC"
  : > "$DLOG"
  rc=0; out="$(au up "$NAME" 2>&1)" || rc=$?
  check "up refuses TAILSCALE_HOST='$h'" bash -c '[ "$1" -ne 0 ] && grep -q "TAILSCALE_HOST=" <<<"$2" && ! grep -q "tailscale serve" <<<"$2"' _ "$rc" "$out"
  refuses "pair refuses TAILSCALE_HOST='$h'" 'TAILSCALE_HOST=' au pair "$NAME"
  check "stop works with TAILSCALE_HOST='$h'" au stop "$NAME"
done
rm -f "$AUC"
for v in 0 70000 abc; do
  echo "TAILSCALE_HTTPS_PORT=$v" >> "$CFG/project.conf"
  refuses "up refuses TAILSCALE_HTTPS_PORT=$v" "TAILSCALE_HTTPS_PORT='$v'.*1-65535" au up "$NAME"
  check "stop works with TAILSCALE_HTTPS_PORT=$v" au stop "$NAME"
  check "down works with TAILSCALE_HTTPS_PORT=$v" au down "$NAME"
  check "status works with TAILSCALE_HTTPS_PORT=$v" au status "$NAME"
  cp "$T/pconf-t3.bak" "$CFG/project.conf"
done
cp "$CFG/project.env" "$T/penv-ts.bak"
for k in TAILSCALE_HTTPS_PORT TAILSCALE_HOST; do
  echo "$k=op://x/y" >> "$CFG/project.env"
  refuses "up refuses reserved key $k in project.env" "reserved.*$k" au up "$NAME"
  cp "$T/penv-ts.bak" "$CFG/project.env"
done
cp "$T/pconf-t3.bak" "$CFG/project.conf"
# ---- pair waits for the T3 server
echo 2 > "$T/PAIR_FAILS"; rm -f "$T/pair.count"; : > "$DLOG"
pairout="$(AMBIENT=(AGENT_UP_PAIR_WAIT=10); au pair "$NAME" 2>&1)" || true
check "pair retries until the T3 server answers (prints the token)" grep -qF "pair#token=fakeTok_123" <<<"$pairout"
check "  ...after 3 pair attempts" test "$(grep -c 'agent-t3 pair' "$DLOG")" = 3
check "  ...says it is waiting" grep -qF "waiting for the T3 server in '$NAME'" <<<"$pairout"
echo 99 > "$T/PAIR_FAILS"; rm -f "$T/pair.count"
AMBIENT=(AGENT_UP_PAIR_WAIT=3)
refuses "pair gives up when the T3 server never answers" "T3 server in '$NAME' did not answer within 3 s" au pair "$NAME"
rm -f "$T/PAIR_FAILS" "$T/pair.count"
echo 0 > "$T/RUNNING"; : > "$DLOG"
refuses "pair refuses at once when the container is not running" "is '$NAME' running\\? agent-up status $NAME" au pair "$NAME"
check "  ...and makes no agent-t3 pair call" bash -c '! grep -q "agent-t3 pair" "$1"' _ "$DLOG"
rm -f "$T/RUNNING"; AMBIENT=()

# ---- T3 Connect (owner opt-in): validated by up/config only; a missing key is 0
cp "$CFG/project.conf" "$T/pconf-t3c.bak"
for v in 2 yes on Publish " 1"; do
  sed -i "s/^T3_CONNECT=.*/T3_CONNECT=$v/" "$CFG/project.conf"
  : > "$DLOG"
  refuses "up refuses T3_CONNECT='$v'" "T3_CONNECT='$v'.*must be 0 \(off\), 1 \(managed tunnel\) or publish \(publish-only\)" au up "$NAME"
  check "  ...without reaching docker" test ! -s "$DLOG"
  refuses "config refuses T3_CONNECT='$v'" "T3_CONNECT='$v'" au config "$NAME"
  check "stop works with T3_CONNECT='$v' (lifecycle never validates it)" au stop "$NAME"
  check "down works with T3_CONNECT='$v'" au down "$NAME"
  check "status works with T3_CONNECT='$v'" au status "$NAME"
  check "  ...and an invalid value opens nothing (no switch file)" test ! -e "$CFG/.generated/t3-connect"
done
sed -i "s/^T3_CONNECT=.*/T3_CONNECT=/" "$CFG/project.conf"
check "config accepts an empty T3_CONNECT= (off)" au config "$NAME"
check "  ...no switch file" test ! -e "$CFG/.generated/t3-connect"
sed -i '/^T3_CONNECT=/d' "$CFG/project.conf"
: > "$DLOG"
check "up accepts a config without T3_CONNECT (predates it: off)" au up "$NAME"
check "  ...overlay adds nothing, no switch file" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$2" ]' _ "$T3O" "$CFG/.generated/t3-connect"
check "  ...docker compose gets the T3 Connect overlay" grep -qxF "ARGS: $C up -d --force-recreate" "$DLOG"
check "stop works without T3_CONNECT" au stop "$NAME"
check "down works without T3_CONNECT" au down "$NAME"
echo "T3_CONNECT=1" >> "$CFG/project.conf"
upout="$(au up "$NAME" 2>&1)" && rc=0 || rc=$?
check "up with T3_CONNECT=1" test "$rc" -eq 0
check "  ...says T3 Connect is ON and how to link it" grep -q "T3 Connect is ON .*t3 connect --headless" <<<"$upout"
check "  ...firewall switch file says T3_CONNECT=1" test "$(cat "$CFG/.generated/t3-connect")" = "T3_CONNECT=1"
check "  ...overlay mounts it read-only at /etc/firewall/t3-connect" \
  bash -c 'grep -qx "        source: ./.generated/t3-connect" "$1" && grep -qx "        target: /etc/firewall/t3-connect" "$1" && grep -qx "        read_only: true" "$1"' _ "$T3O"
check "  ...and sets TUNNEL_EDGE_IP_VERSION=4 for cloudflared" grep -qE '^      TUNNEL_EDGE_IP_VERSION: "4"' "$T3O"
sed -i 's/^T3_CONNECT=.*/T3_CONNECT=publish/' "$CFG/project.conf"
upout="$(au up "$NAME" 2>&1)" && rc=0 || rc=$?
check "up with T3_CONNECT=publish" test "$rc" -eq 0
check "  ...says publish-only and how to link it" grep -q "T3 Connect: publish-only .*t3 connect link --publish-only" <<<"$upout"
check "  ...firewall switch file says exactly T3_CONNECT=publish" test "$(cat "$CFG/.generated/t3-connect")" = "T3_CONNECT=publish"
check "  ...overlay mounts it read-only, env T3_CONNECT=publish" \
  bash -c 'grep -qx "        target: /etc/firewall/t3-connect" "$1" && grep -qx "        read_only: true" "$1" && grep -qE "^      T3_CONNECT: \"publish\"" "$1"' _ "$T3O"
check "  ...and no TUNNEL_EDGE_IP_VERSION (no tunnel)" bash -c '! grep -q TUNNEL_EDGE_IP_VERSION "$1"' _ "$T3O"
sed -i 's/^T3_CONNECT=.*/T3_CONNECT=0/' "$CFG/project.conf"
check "back to T3_CONNECT=0: config succeeds" au config "$NAME"
check "  ...and the switch file is gone" test ! -e "$CFG/.generated/t3-connect"
cp "$CFG/project.env" "$T/penv3.bak"
for k in T3_CONNECT TUNNEL_TOKEN TUNNEL_EDGE_IP_VERSION; do
  echo "$k=op://v/i/f" >> "$CFG/project.env"
  refuses "up refuses reserved key $k in project.env" "reserved.*$k" au up "$NAME"
  cp "$T/penv3.bak" "$CFG/project.env"
done
cp "$T/pconf-t3c.bak" "$CFG/project.conf"
AMBIENT=(T3_CONNECT=1)
au config "$NAME" >/dev/null 2>&1 || true
AMBIENT=()
check "an ambient T3_CONNECT=1 in the owner's shell changes nothing (only project.conf counts)" test ! -e "$CFG/.generated/t3-connect"

# ---- RStudio Server (owner opt-in): validated by up/config/rstudio only; a missing key is 0
cp "$CFG/project.conf" "$T/pconf-rs.bak"
for v in 2 yes on " 1"; do
  sed -i "s/^RSTUDIO=.*/RSTUDIO=$v/" "$CFG/project.conf"
  : > "$DLOG"
  refuses "up refuses RSTUDIO='$v'" "RSTUDIO='$v'.*must be 0 \(off\) or 1 \(on\)" au up "$NAME"
  check "  ...without reaching docker" test ! -s "$DLOG"
  refuses "config refuses RSTUDIO='$v'" "RSTUDIO='$v'" au config "$NAME"
  check "stop works with RSTUDIO='$v' (lifecycle never validates it)" au stop "$NAME"
  check "down works with RSTUDIO='$v'" au down "$NAME"
  check "status works with RSTUDIO='$v'" au status "$NAME"
  check "  ...and an invalid value opens nothing (no switch file, no password)" \
    bash -c '[ ! -e "$1/rstudio" ] && [ ! -e "$1/rstudio-password" ]' _ "$CFG/.generated"
done
sed -i '/^RSTUDIO=/d; /^RSTUDIO_PORT=/d' "$CFG/project.conf"
check "up accepts a config without RSTUDIO/RSTUDIO_PORT (predates them: off)" au up "$NAME"
check "  ...overlay adds nothing" bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ]' _ "$RSO"
check "stop works without RSTUDIO" au stop "$NAME"
check "down works without RSTUDIO" au down "$NAME"
refuses "agent-up rstudio says it is off" "RStudio Server is off for 'demo-proj'.*RSTUDIO=1" au rstudio "$NAME"
echo "RSTUDIO=1" >> "$CFG/project.conf"
refuses "RSTUDIO=1 without RSTUDIO_PORT is refused by up" "RSTUDIO_PORT=''" au up "$NAME"
check "  ...but stop still works" au stop "$NAME"
check "  ...and down" au down "$NAME"
check "  ...rendering RStudio off for them (compose never sees an unset RSTUDIO_PORT)" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$2/rstudio" ] && [ ! -e "$2/rstudio-password" ]' _ "$RSO" "$CFG/.generated"
for v in 80 abc 70000; do
  sed -i '/^RSTUDIO_PORT=/d' "$CFG/project.conf"; echo "RSTUDIO_PORT=$v" >> "$CFG/project.conf"
  refuses "RSTUDIO_PORT=$v is refused" "RSTUDIO_PORT='$v'" au config "$NAME"
done
sed -i 's/^RSTUDIO_PORT=.*/RSTUDIO_PORT=3773/' "$CFG/project.conf"
refuses "RSTUDIO_PORT equal to its own T3_PORT is refused" "equals its T3_PORT" au up "$NAME"
sed -i 's/^RSTUDIO_PORT=.*/RSTUDIO_PORT=3774/' "$CFG/project.conf"
refuses "RSTUDIO_PORT used as another project's T3_PORT is refused" "RSTUDIO_PORT=3774 .*also used by bio2 \(T3_PORT\)" au up "$NAME"
sed -i 's/^RSTUDIO_PORT=.*/RSTUDIO_PORT=8788/' "$CFG/project.conf"
refuses "RSTUDIO_PORT used by another project's RSTUDIO_PORT is refused" "RSTUDIO_PORT=8788 .*also used by bio2 \(RSTUDIO_PORT\)" au rstudio "$NAME"
sed -i 's/^RSTUDIO_PORT=.*/RSTUDIO_PORT=8787/' "$CFG/project.conf"
refuses "agent-up rstudio before any up: no password yet" "no password yet .*agent-up up demo-proj" au rstudio "$NAME"
: > "$DLOG"
upout="$(au up "$NAME" 2>&1)" && rc=0 || rc=$?
check "up with RSTUDIO=1" test "$rc" -eq 0
check "  ...prints the RStudio address and how to get the password" \
  grep -qxF "agent-up: RStudio Server at http://rstudio-demo-proj.localhost:8787 (user and password: agent-up rstudio demo-proj)" <<<"$upout"
check "  ...docker compose gets the RStudio overlay" grep -qxF "ARGS: $C up -d --force-recreate" "$DLOG"
check "  ...firewall switch file says RSTUDIO=1" test "$(cat "$CFG/.generated/rstudio")" = "RSTUDIO=1"
PWF="$CFG/.generated/rstudio-password"
check "  ...password file: mode 600, 32 hex characters (128 bits)" \
  bash -c '[ "$(stat -c %a "$1")" = 600 ] && grep -Eqx "[0-9a-f]{32}" "$1"' _ "$PWF"
check "  ...the password is not printed by up" bash -c '! grep -qF "$(cat "$1")" <<<"$2"' _ "$PWF" "$upout"
check "  ...overlay mounts the switch and the password read-only, adds the port and volume" \
  bash -c 'grep -qx "        target: /etc/firewall/rstudio" "$1" && grep -qx "        target: /run/secrets/rstudio-password" "$1" && [ "$(grep -cx "        read_only: true" "$1")" = 2 ] && grep -qF "127.0.0.1:\${RSTUDIO_PORT" "$1" && grep -qx "    name: rstudio-\${PROJECT}" "$1"' _ "$RSO"
pw1=$(cat "$PWF")
au up "$NAME" >/dev/null 2>&1
check "  ...the password is kept across up" test "$(cat "$PWF")" = "$pw1"
chmod 644 "$PWF"; au config "$NAME" >/dev/null 2>&1
check "  ...and its mode is put back to 600" test "$(stat -c %a "$PWF")" = 600
rsout="$(au rstudio "$NAME" 2>&1)" && rc=0 || rc=$?
check "agent-up rstudio prints the per-project origin, user and password" \
  bash -c '[ "$1" -eq 0 ] && grep -qxF "  http://rstudio-demo-proj.localhost:8787" <<<"$2" && grep -qxF "  user:     agent" <<<"$2" && grep -qxF "  password: $3" <<<"$2"' _ "$rc" "$rsout" "$pw1"
check "  ...and a plain localhost fallback" grep -qF "http://localhost:8787" <<<"$rsout"
printf 'two words here!!\n' > "$PWF"
refuses "a password file with spaces is refused" "rstudio-password must be one line of 16\+ printable" au config "$NAME"
printf 'short\n' > "$PWF"
refuses "a short password file is refused" "rstudio-password must be one line" au config "$NAME"
rm -f "$PWF"; au config "$NAME" >/dev/null 2>&1
check "deleting the password file rotates it" bash -c 'grep -Eqx "[0-9a-f]{32}" "$1" && [ "$(cat "$1")" != "$2" ]' _ "$PWF" "$pw1"
sed -i 's/^RSTUDIO=.*/RSTUDIO=0/' "$CFG/project.conf"
check "back to RSTUDIO=0: config succeeds" au config "$NAME"
check "  ...the switch file is gone (the password is kept for next time)" bash -c '[ ! -e "$1/rstudio" ] && [ -e "$1/rstudio-password" ]' _ "$CFG/.generated"
cp "$CFG/project.env" "$T/penv-rs.bak"
for k in RSTUDIO RSTUDIO_PORT RSTUDIO_CONFIG_DIR RS_LOG_LEVEL; do
  echo "$k=op://v/i/f" >> "$CFG/project.env"
  refuses "up refuses reserved key $k in project.env" "reserved.*$k" au up "$NAME"
  cp "$T/penv-rs.bak" "$CFG/project.env"
done
AMBIENT=(RSTUDIO=1 RSTUDIO_PORT=9999)
au config "$NAME" >/dev/null 2>&1 || true
AMBIENT=()
check "an ambient RSTUDIO=1 in the owner's shell changes nothing (only project.conf counts)" test ! -e "$CFG/.generated/rstudio"
# a project name with an underscore: hyphens in the browser origin
UP="$T/my_proj"; mkdir -p "$UP"
au init "$UP" >/dev/null 2>&1
sed -i 's/^RSTUDIO=.*/RSTUDIO=1/' "$CFGROOT/my_proj/project.conf"
au config my_proj >/dev/null 2>&1
# six projects so far hold RSTUDIO_PORT 8787-8792
check "init of my_proj: the next RSTUDIO_PORT free across all projects (8793)" grep -qx "RSTUDIO_PORT=8793" "$CFGROOT/my_proj/project.conf"
rsout="$(au rstudio my_proj 2>&1)" || true
check "my_proj: hostname my-proj (underscore -> hyphen)" grep -qx "    hostname: my-proj" "$CFGROOT/my_proj/.generated/hostname.yaml"
au config odd-name- >/dev/null 2>&1 || true
check "odd-name-: hostname odd-name (no trailing hyphen)" grep -qx "    hostname: odd-name" "$CFGROOT/odd-name-/.generated/hostname.yaml"
check "agent-up rstudio my_proj: origin rstudio-my-proj.localhost (underscore -> hyphen)" grep -qxF "  http://rstudio-my-proj.localhost:8793" <<<"$rsout"
rm -rf "$CFGROOT/my_proj"
cp "$T/pconf-rs.bak" "$CFG/project.conf"
au config "$NAME" >/dev/null 2>&1 || true
# ---- FTP uploads (owner opt-in, spec §13.4): validated by up/config only; absent or empty = off
cp "$CFG/project.conf" "$T/pconf-ftp.bak"
setftp(){ sed -i '/^FTP_HOSTS=/d' "$CFG/project.conf"; printf 'FTP_HOSTS=%s\n' "$1" >> "$CFG/project.conf"; }
for v in "ftp://webin2.ebi.ac.uk" "webin2.ebi.ac.uk:21" "*.ebi.ac.uk" "webin2.ebi.ac.uk/upload" "webin2.ebi.ac.uk,ftp.ebi.ac.uk" "-webin2.ebi.ac.uk" "webin2.ebi.ac.uk # ENA"; do
  setftp "$v"
  : > "$DLOG"
  refuses "up refuses FTP_HOSTS='$v'" "FTP_HOSTS in .*is not a bare domain" au up "$NAME"
  check "  ...without reaching docker" test ! -s "$DLOG"
  refuses "config refuses FTP_HOSTS='$v'" "FTP_HOSTS in .*is not a bare domain" au config "$NAME"
  check "stop works with FTP_HOSTS='$v' (lifecycle never validates it)" au stop "$NAME"
  check "down works with FTP_HOSTS='$v'" au down "$NAME"
  check "status works with FTP_HOSTS='$v'" au status "$NAME"
  check "  ...and an invalid list opens nothing (empty overlay, no host file)" \
    bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$2" ]' _ "$FO" "$CFG/.generated/ftp-hosts"
done
setftp "webin2.ebi.ac.uk ftp://evil.example"
refuses "up names the offending token of a mixed list" "'ftp://evil.example' is not a bare domain" au up "$NAME"
setftp ""
check "config accepts an empty FTP_HOSTS= (off)" au config "$NAME"
check "  ...empty overlay, no host file" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$2" ]' _ "$FO" "$CFG/.generated/ftp-hosts"
setftp '""'
check 'config accepts FTP_HOSTS="" (off)' au config "$NAME"
check "  ...no host file" test ! -e "$CFG/.generated/ftp-hosts"
setftp '"Webin2.EBI.ac.uk  ftp-private.ncbi.nlm.nih.gov webin2.ebi.ac.uk"'
TOK=tok; : > "$DLOG"
upout="$(au up "$NAME" 2>&1)" && rc=0 || rc=$?
check "up with a quoted, mixed-case, duplicated FTP_HOSTS list" test "$rc" -eq 0
check "  ...says FTP is ON, cleartext, and to which hosts" \
  grep -qF "agent-up: FTP uploads ON (tcp 21 + conntrack ftp helper; cleartext) to: ftp-private.ncbi.nlm.nih.gov webin2.ebi.ac.uk" <<<"$upout"
check "  ...docker compose gets the FTP overlay" grep -qxF "ARGS: $C up -d --force-recreate" "$DLOG"
check "  ...host file: one domain per line, lower-cased, sorted, unique" \
  test "$(cat "$CFG/.generated/ftp-hosts")" = "$(printf 'ftp-private.ncbi.nlm.nih.gov\nwebin2.ebi.ac.uk')"
check "  ...host file is owner-only (mode 600)" test "$(stat -c %a "$CFG/.generated/ftp-hosts")" = 600
check "  ...overlay mounts it read-only at /etc/firewall/ftp-hosts, and adds nothing else" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent:\n    volumes:\n      - type: bind                  # read by the root firewall at start; the agent cannot change it\n        source: ./.generated/ftp-hosts\n        target: /etc/firewall/ftp-hosts\n        read_only: true\n        bind: {create_host_path: false}")" ]' _ "$FO"
check "  ...never an environment variable" bash -c '! grep -rq "FTP_HOSTS:" "$1"' _ "$CFG/.generated"
setftp "webin2.ebi.ac.uk"
check "an unquoted single host: config succeeds" au config "$NAME"
check "  ...host file says exactly webin2.ebi.ac.uk" test "$(cat "$CFG/.generated/ftp-hosts")" = webin2.ebi.ac.uk
sed -i '/^FTP_HOSTS=/d' "$CFG/project.conf"
check "back to no FTP_HOSTS: config succeeds" au config "$NAME"
check "  ...the host file is gone, the overlay is empty" \
  bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$2" ]' _ "$FO" "$CFG/.generated/ftp-hosts"
cp "$CFG/project.env" "$T/penv-ftp.bak"
echo "FTP_HOSTS=op://v/i/f" >> "$CFG/project.env"
refuses "up refuses reserved key FTP_HOSTS in project.env" "reserved.*FTP_HOSTS" au up "$NAME"
cp "$T/penv-ftp.bak" "$CFG/project.env"
echo "FTP_PASSWORD=op://agent-demo-proj/webin/password" >> "$CFG/project.env"
check "  ...but other FTP_* keys are not reserved (Webin credentials may come from project.env)" au config "$NAME"
cp "$T/penv-ftp.bak" "$CFG/project.env"
AMBIENT=(FTP_HOSTS=webin2.ebi.ac.uk)
au config "$NAME" >/dev/null 2>&1 || true
AMBIENT=()
check "an ambient FTP_HOSTS in the owner's shell changes nothing (only project.conf counts)" test ! -e "$CFG/.generated/ftp-hosts"
cp "$T/pconf-ftp.bak" "$CFG/project.conf"
au config "$NAME" >/dev/null 2>&1 || true
TOK=""
# ---- research profile: the ONE shared research container (spec §2.1, Phase 1b)
RCFG="$CFGROOT/research"; RD="$H/agent-research"
refuses "init --profile research refuses another name" "always named 'research'" au init --profile research --name foo
rinit="$(au init --profile research 2>&1)" && rrc=0 || rrc=$?
check "init --profile research (no project dir)" test "$rrc" -eq 0
check "  ...the Next text names the spades-research row" grep -q "the spades-research row" <<<"$rinit"
check "  ...config dir 'research', mode 700" test "$(stat -c %a "$RCFG")" = 700
check "  ...holds compose.yaml + project.conf ONLY (no project.env: no secrets; no allowlist)" \
  test "$(ls -A "$RCFG" | sort | paste -sd' ' -)" = "compose.yaml project.conf"
check "  ...project.conf: PROFILE=research, IMAGE=research, RESEARCH_DIR, T3_PORT, T3_CONNECT=0" \
  bash -c 'grep -qx PROJECT=research "$1" && grep -qx PROFILE=research "$1" && grep -qx IMAGE=research "$1" && grep -qx "RESEARCH_DIR=$2/agent-research" "$1" && grep -qE "^T3_PORT=[0-9]+$" "$1" && grep -qx T3_CONNECT=0 "$1"' _ "$RCFG/project.conf" "$H"
check "  ...and NO project folder, spades.ai or memory settings" bash -c '! grep -Eq "^(PROJECT_DIR|SPADES_AI_DIR|AGENT_MEMORY_DIR)=" "$1"' _ "$RCFG/project.conf"
check "  ...its T3_PORT is unique" bash -c '[ "$(grep -h "^T3_PORT=" "$1"/*/project.conf | sort | uniq -d)" = "" ]' _ "$CFGROOT"
check "  ...compose: the research seed (spades-research, 16g, cwd /research, own volumes)" \
  bash -c 'grep -q "spades-research@sha256:REPLACE_WITH_DIGEST_FROM_digests.md" "$1" && grep -qE "^    mem_limit: 16g" "$1" && grep -qE "^    working_dir: /research" "$1" && ! sed "s/#.*//" "$1" | grep -Eq "[^_]PROJECT_DIR|SPADES_AI_DIR|AGENT_MEMORY_DIR|require-cache|npm-cache-shared|allowlist|/workspace"' _ "$RCFG/compose.yaml"
check "  ...created the research exchange root" test -d "$RD"
refuses "init --profile research never overwrites" 'already exists' au init --profile research
refuses "up research refuses the placeholder digest" 'not pinned to a real digest' au up research
sed -i "s/REPLACE_WITH_DIGEST_FROM_digests.md/$H64/" "$RCFG/compose.yaml"
RC="compose --env-file $RCFG/project.conf -f $RCFG/compose.yaml -f $RCFG/.generated/env-passthrough.yaml -f $RCFG/.generated/t3-connect.yaml -f $RCFG/.generated/research.yaml -f $RCFG/.generated/rstudio.yaml -f $RCFG/.generated/ftp.yaml -f $RCFG/.generated/hostname.yaml -f $RCFG/.generated/restart.yaml --project-directory $RCFG -p research"
: > "$DLOG"; rm -f "$OPLOG"; TOK=""
AMBIENT=(OP_SERVICE_ACCOUNT_TOKEN=owner-op-token GH_TOKEN=owner-gh-token)
rc=0; out=$(au up research 2>&1) || rc=$?
AMBIENT=()
check "up research succeeds with NO 1Password (no project.env)" test "$rc" -eq 0
check "  ...never runs op" test ! -e "$OPLOG"
check "  ...runs docker compose directly, with the research overlay" grep -qxF "ARGS: $RC up -d --force-recreate" "$DLOG"
check "  ...the owner's OP_SERVICE_ACCOUNT_TOKEN is not in compose's environment" bash -c 'grep -qx "OPTOK: <unset>" "$1" && ! grep -q owner-op-token "$1"' _ "$DLOG"
check "  ...no shared cache volumes are touched" bash -c '! grep -q "volume inspect" "$1"' _ "$DLOG"
check "  ...passthrough is empty (no secret names)" grep -qx "    environment: \[\]" "$RCFG/.generated/env-passthrough.yaml"
check "  ...profile switch says PROFILE=research" test "$(cat "$RCFG/.generated/profile")" = PROFILE=research
check "  ...research instructions written (readable: mode 644)" \
  bash -c 'cmp -s "$1" "$2" && [ "$(stat -c %a "$1")" = 644 ]' _ "$RCFG/.generated/agent-instructions.md" "$ROOT/project-template/instructions/research.md"
check "  ...switch read-only at /etc/firewall/profile; instructions read-only at Claude's managed CLAUDE.md + Codex's AGENTS.md" \
  bash -c 'f="$1"; for t in /etc/firewall/profile /etc/claude-code/CLAUDE.md /home/agent/.codex/AGENTS.md; do grep -A1 "target: \"$t\"" "$f" | grep -q "read_only: true" || { echo "not ro: $t"; exit 1; }; done' _ "$RCFG/.generated/research.yaml"
check "  ...no project subfolders yet: only the /research/_general mount" bash -c '! grep "target: \"/research/" "$1" | grep -qv "target: \"/research/_general\""' _ "$RCFG/.generated/research.yaml"
check "  ...created RD/_general, said so" bash -c 'test -d "$1/_general" && ! test -L "$1/_general" && grep -qxF "agent-up: created $1/_general" <<<"$2"' _ "$RD" "$out"
check "  ...no 'skipped' message for _general; not in the research projects line" bash -c '! grep -q "skipped .*_general" <<<"$1" && ! grep "research projects:" <<<"$1" | grep -q _general' _ "$out"
check "  ..._general read-write at /research/_general (no read_only)" \
  bash -c 'grep -A2 "source: \"$2/_general\"" "$1" | grep -q "target: \"/research/_general\"" && ! grep -A2 "source: \"$2/_general\"" "$1" | grep -q read_only' _ "$RCFG/.generated/research.yaml" "$RD"
check "  ...overlay sets working_dir and T3_PROJECT_DIR to /research/_general" \
  bash -c 'grep -qE "^    working_dir: /research/_general( |$)" "$1" && grep -qE "^      T3_PROJECT_DIR: /research/_general( |$)" "$1"' _ "$RCFG/.generated/research.yaml"
check "  ...a builder's overlay has no _general" bash -c '! grep -rq _general "$1"' _ "$CFG/.generated"
mv "$RD/_general" "$T/_general.real"; ln -s "$T/_general.real" "$RD/_general"
refuses "up research refuses a symlinked _general" '_general is a symlink' au up research
rm "$RD/_general"; mv "$T/_general.real" "$RD/_general"
# Review Focus 1: the owner's existing research config (IMAGE=gis, compose pinned to spades-gis) must still work
cp "$RCFG/compose.yaml" "$T/rcompose-res.bak"; cp "$RCFG/project.conf" "$T/rconf-res.bak"
sed -i 's|/spades-research@sha256:|/spades-gis@sha256:|' "$RCFG/compose.yaml"
sed -i 's/^IMAGE=.*/IMAGE=gis/' "$RCFG/project.conf"
check "up research still accepts a spades-gis compose" au up research
check "config research still accepts a spades-gis compose" au config research
cp "$T/rcompose-res.bak" "$RCFG/compose.yaml"; cp "$T/rconf-res.bak" "$RCFG/project.conf"
check "up research accepts a spades-research compose" au up research
check "  ...no RStudio Server for the research container (overlay adds nothing, no switch, no password)" \
  bash -c '[ "$(grep -v "^#" "$1/rstudio.yaml")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$1/rstudio" ] && [ ! -e "$1/rstudio-password" ]' _ "$RCFG/.generated"
cp "$RCFG/project.conf" "$T/rconf-rs.bak"
printf 'RSTUDIO=1\nRSTUDIO_PORT=8999\n' >> "$RCFG/project.conf"
refuses "config research refuses RSTUDIO=1 (builders only)" "RStudio Server is for builder projects only" au config research
refuses "rstudio research refuses (builders only)" "RStudio Server is for builder projects only" au rstudio research
check "  ...stop research still works with RSTUDIO=1 in its config (renders RStudio off)" au stop research
check "  ...and its overlay stays empty" bash -c '[ ! -e "$1/rstudio" ] && [ ! -e "$1/rstudio-password" ]' _ "$RCFG/.generated"
cp "$T/rconf-rs.bak" "$RCFG/project.conf"
check "  ...no FTP for the research container (overlay adds nothing, no host file)" \
  bash -c '[ "$(grep -v "^#" "$1/ftp.yaml")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$1/ftp-hosts" ]' _ "$RCFG/.generated"
check "  ...and init --profile research does not seed FTP_HOSTS" bash -c '! grep -q "FTP_HOSTS" "$1"' _ "$RCFG/project.conf"
printf 'FTP_HOSTS=webin2.ebi.ac.uk\n' >> "$RCFG/project.conf"
refuses "config research refuses FTP_HOSTS (builders only; its egress is already open)" "FTP uploads are for builder projects only; the research container's egress is already open" au config research
refuses "up research refuses FTP_HOSTS" "FTP uploads are for builder projects only" au up research
check "  ...stop research still works with FTP_HOSTS in its config (renders FTP off)" au stop research
check "  ...and its overlay stays empty, no host file" \
  bash -c '[ "$(grep -v "^#" "$1/ftp.yaml")" = "$(printf "services:\n  agent: {}")" ] && [ ! -e "$1/ftp-hosts" ]' _ "$RCFG/.generated"
cp "$T/rconf-rs.bak" "$RCFG/project.conf"
: > "$DLOG"
check "shell research opens /research/_general" au shell research
check "  ...docker exec -w /research/_general" grep -qxF "ARGS: exec -it -u agent -w /research/_general research-agent-1 zsh" "$DLOG"
check "stop research without 1Password" au stop research
check "down research without 1Password" au down research
# research holds no secrets: project.env may exist only empty (comments)
printf '# nothing\n\n' > "$RCFG/project.env"
check "up research accepts a comments-only project.env" au up research
sed -i 's/^T3_CONNECT=.*/T3_CONNECT=publish/' "$RCFG/project.conf"
check "up research with T3_CONNECT=publish" au up research
check "  ...research switch file says T3_CONNECT=publish" test "$(cat "$RCFG/.generated/t3-connect")" = "T3_CONNECT=publish"
sed -i 's/^T3_CONNECT=.*/T3_CONNECT=0/' "$RCFG/project.conf"
au config research >/dev/null 2>&1 || true
echo 'GH_TOKEN=op://agent-research/github-agent/token' >> "$RCFG/project.env"
refuses "up research refuses ANY key in project.env" 'holds no secrets.*line number' au up research
refuses "config research refuses ANY key in project.env" 'holds no secrets' au config research
msg=$(au up research 2>&1 || true)
check "  ...without echoing the value" bash -c '! grep -q "op://" <<<"$1"' _ "$msg"
rm -f "$RCFG/project.env"

# RESEARCH_CONTACT_EMAIL: a setting (not a secret) for the research container only
cp "$RCFG/project.conf" "$T/rconf-ce.bak"
check "init seeds a commented RESEARCH_CONTACT_EMAIL line" grep -qx '#RESEARCH_CONTACT_EMAIL=' "$RCFG/project.conf"
check "  ...with a forwarding-alias comment above it" bash -c 'grep -B1 -x "#RESEARCH_CONTACT_EMAIL=" "$1" | head -n 1 | grep -q "forwarding alias"' _ "$RCFG/project.conf"
au config research >/dev/null 2>&1 || true
check "unset: the research overlay has no RESEARCH_CONTACT_EMAIL" bash -c '! grep -q RESEARCH_CONTACT_EMAIL "$1"' _ "$RCFG/.generated/research.yaml"
echo 'RESEARCH_CONTACT_EMAIL=papers+research@relay.example' >> "$RCFG/project.conf"
check "config research accepts a plain alias" au config research
check "  ...the agent service environment carries it" grep -qx '      RESEARCH_CONTACT_EMAIL: "papers+research@relay.example"' "$RCFG/.generated/research.yaml"
check "  ...under environment:" bash -c 'grep -B3 "RESEARCH_CONTACT_EMAIL" "$1" | grep -qx "    environment:"' _ "$RCFG/.generated/research.yaml"
cp "$T/rconf-ce.bak" "$RCFG/project.conf"
for bad in 'a b@x.org' 'a@x.org"' '$HOME@x.org' 'a@b@x.org' 'nobody'; do
  echo "RESEARCH_CONTACT_EMAIL=$bad" >> "$RCFG/project.conf"
  refuses "up research refuses RESEARCH_CONTACT_EMAIL='$bad'" 'not a plain email address' au up research
  refuses "config research refuses RESEARCH_CONTACT_EMAIL='$bad'" 'not a plain email address' au config research
  msg=$(au up research 2>&1 || true)
  check "  ...without echoing the value" bash -c '! grep -qF -- "$2" <<<"$1"' _ "$msg" "$bad"
  cp "$T/rconf-ce.bak" "$RCFG/project.conf"
done
echo 'RESEARCH_CONTACT_EMAIL=a b@x.org' >> "$RCFG/project.conf"
check "stop research works with an invalid RESEARCH_CONTACT_EMAIL" au stop research
check "  ...and the value is omitted from the overlay" bash -c '! grep -q RESEARCH_CONTACT_EMAIL "$1"' _ "$RCFG/.generated/research.yaml"
cp "$T/rconf-ce.bak" "$RCFG/project.conf"
AMBIENT=(RESEARCH_CONTACT_EMAIL=leak@evil.example)
au config research >/dev/null 2>&1 || true
check "an ambient RESEARCH_CONTACT_EMAIL never reaches the research overlay" bash -c '! grep -rq "leak@evil.example" "$1"' _ "$RCFG/.generated"
check "  ...nor the config output" bash -c '! grep -q "leak@evil.example" <<<"$1"' _ "$(au config research 2>&1 || true)"
AMBIENT=()
cp "$CFG/project.conf" "$T/pconf-ce.bak"
echo 'RESEARCH_CONTACT_EMAIL=papers+research@relay.example' >> "$CFG/project.conf"
refuses "up refuses RESEARCH_CONTACT_EMAIL on a builder" 'for the research container only' au up "$NAME"
refuses "config refuses RESEARCH_CONTACT_EMAIL on a builder" 'for the research container only' au config "$NAME"
cp "$T/pconf-ce.bak" "$CFG/project.conf"
au config research >/dev/null 2>&1 || true

# builder opt-in: RESEARCH=1
cp "$CFG/project.conf" "$T/pconf-res.bak"
sed -i 's/^RESEARCH=.*/RESEARCH=1/' "$CFG/project.conf"
TOK=tok; : > "$DLOG"
upout="$(au up "$NAME" 2>&1)" && rc=0 || rc=$?
check "builder up with RESEARCH=1" test "$rc" -eq 0
check "  ...created $NAME's briefs/, reports/, downloads/" bash -c 'for d in briefs reports downloads; do [ -d "$1/$2/$d" ] || exit 1; done' _ "$RD" "$NAME"
check "  ...says so, and how the research container picks it up" grep -q "agent-up up research" <<<"$upout"
check "  ...briefs read-write at /research/briefs" \
  bash -c 'grep -A3 "source: \"$2/$3/briefs\"" "$1" | grep -q "target: \"/research/briefs\"" && ! grep -A2 "source: \"$2/$3/briefs\"" "$1" | grep -q read_only' _ "$RO" "$RD" "$NAME"
for d in reports downloads; do
  check "  ...$d READ-ONLY at /research/$d" \
    bash -c 'grep -A2 "source: \"$2/$3/$4\"" "$1" | grep -q "target: \"/research/$4\"" && grep -A2 "source: \"$2/$3/$4\"" "$1" | grep -q "read_only: true"' _ "$RO" "$RD" "$NAME" "$d"
done
check "  ...builder instructions (untrusted data) at Claude's managed CLAUDE.md, read-only" \
  bash -c 'cmp -s "$1/agent-instructions.md" "$2" && grep -A1 "target: \"/etc/claude-code/CLAUDE.md\"" "$1/research.yaml" | grep -q "read_only: true"' _ "$CFG/.generated" "$ROOT/project-template/instructions/builder-research.md"
check "  ...no profile switch for a builder (its firewall stays the allowlist)" test ! -e "$CFG/.generated/profile"
check "  ...still uses op run (a builder's secrets are unchanged)" grep -q "^OP: run --env-file $CFG/project.env" "$OPLOG"
# a second builder opts in but is NOT started: the research container's up creates its folders anyway
cp "$CFGROOT/bio2/project.conf" "$T/bio2-res.bak"; echo "RESEARCH=1" >> "$CFGROOT/bio2/project.conf"
mkdir -p "$RD/Bad Name/briefs" "$T/elsewhere"; ln -s "$T/elsewhere" "$RD/linked"
mkdir -p "$RD/partial/briefs"
: > "$DLOG"; TOK=""
upr="$(au up research 2>&1)" && rc=0 || rc=$?
check "up research with two opted-in projects" test "$rc" -eq 0
check "  ...created bio2's folders (builder not started: order of ups does not matter)" test -d "$RD/bio2/downloads"
check "  ...lists both projects" grep -q "research projects: bio2 $NAME" <<<"$upr"
RRO="$RCFG/.generated/research.yaml"
for p in bio2 "$NAME"; do
  check "  ...$p: briefs READ-ONLY, reports + downloads read-write under /research/$p" \
    bash -c 'grep -A2 "source: \"$2/$3/briefs\"" "$1" | grep -q "target: \"/research/$3/briefs\"" && grep -A2 "source: \"$2/$3/briefs\"" "$1" | grep -q "read_only: true" && for d in reports downloads; do grep -A2 "source: \"$2/$3/$d\"" "$1" | grep -q "target: \"/research/$3/$d\"" && ! grep -A2 "source: \"$2/$3/$d\"" "$1" | grep -q read_only || exit 1; done' _ "$RRO" "$RD" "$p"
done
check "  ...skips a symlinked folder, a non-project name and an incomplete folder" \
  bash -c '! grep -Eq "linked|Bad Name|partial|elsewhere" "$1" && grep -q "skipped" <<<"$2"' _ "$RRO" "$upr"
check "  ...exactly 2 projects x 3 exchange mounts + _general + switch + 2 instruction mounts" test "$(grep -c "^      - type: bind" "$RRO")" = 10
rm -rf "$RD/Bad Name" "$RD/partial"; rm -f "$RD/linked"
echo "x" > "$RD/$NAME/downloads/big.tif"
stout="$(au status research 2>&1)" || true
check "status research prints du -sh of each downloads folder" \
  bash -c 'grep -qE "^[0-9.]+[KMGT]?[[:space:]]+$2/bio2/downloads$" <<<"$1" && grep -qE "^[0-9.]+[KMGT]?[[:space:]]+$2/$3/downloads$" <<<"$1"' _ "$stout" "$RD" "$NAME"
# RESEARCH: validated by up/config only; a missing key is 0
for v in 2 yes " 1"; do
  sed -i "s/^RESEARCH=.*/RESEARCH=$v/" "$CFG/project.conf"
  refuses "up refuses RESEARCH='$v'" "RESEARCH='$v'.*must be 0 \(off\) or 1 \(on\)" au up "$NAME"
  check "stop works with RESEARCH='$v'" au stop "$NAME"
  check "  ...and an invalid value mounts nothing" bash -c '[ "$(grep -v "^#" "$1")" = "$(printf "services:\\n  agent: {}")" ]' _ "$RO"
done
sed -i "s/^RESEARCH=.*/RESEARCH=1/" "$CFG/project.conf"
sed -i "s|^RESEARCH_DIR=.*|RESEARCH_DIR=agent-research|" "$CFG/project.conf"
refuses "up refuses a relative RESEARCH_DIR" "RESEARCH_DIR='agent-research'.*absolute" au up "$NAME"
cp "$T/pconf-res.bak" "$CFG/project.conf"; sed -i 's/^RESEARCH=.*/RESEARCH=1/' "$CFG/project.conf"
cp "$CFG/project.env" "$T/penv-res.bak"
for k in RESEARCH RESEARCH_DIR; do
  echo "$k=op://v/i/f" >> "$CFG/project.env"
  refuses "up refuses reserved key $k in project.env" "reserved.*$k" au up "$NAME"
  cp "$T/penv-res.bak" "$CFG/project.env"
done
# overlaps: every RESEARCH_DIR is writable by the research container
cp "$RCFG/project.conf" "$T/rconf.bak"
ov(){ sed -i "s|^RESEARCH_DIR=.*|RESEARCH_DIR=$2|" "$RCFG/project.conf"; refuses "up research refuses RESEARCH_DIR = $1" "$3" au up research; cp "$T/rconf.bak" "$RCFG/project.conf"; }
mkdir -p "$H/GitHub/spades.ai/sub"
ov "the config root" "$CFGROOT" 'overlaps the config root'
ov "a project's config dir (inside the config root)" "$CFG" 'overlaps the config root'
ov "the agent-containers clone" "$ROOT" 'overlaps the agent-containers clone'
ov "a builder's project clone" "$P" "overlaps PROJECT_DIR of project $NAME"
ov "a folder containing every project (HOME)" "$H" 'overlaps (the config root|PROJECT_DIR)'
ov "a folder inside spades.ai" "$H/GitHub/spades.ai/sub" 'overlaps SPADES_AI_DIR of project'
ov "the shared agent memory" "$H/agent-memory" 'overlaps AGENT_MEMORY_DIR of project'
TOK=tok
sed -i "s|^RESEARCH_DIR=.*|RESEARCH_DIR=$H|" "$CFG/project.conf"
refuses "builder up refuses its own RESEARCH_DIR overlapping its project" 'RESEARCH_DIR .* overlaps' au up "$NAME"
cp "$T/pconf-res.bak" "$CFG/project.conf"
# a builder whose clone sits INSIDE the research root is refused even with RESEARCH=0
mkdir -p "$RD/clone-inside"; sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$RD/clone-inside|" "$CFG/project.conf"
refuses "builder up refuses a project clone inside the research container's RESEARCH_DIR (RESEARCH=0)" "overlaps PROJECT_DIR of project $NAME" au up "$NAME"
cp "$T/pconf-res.bak" "$CFG/project.conf"; rmdir "$RD/clone-inside"
cp "$T/pconf-res.bak" "$CFG/project.conf"; cp "$T/bio2-res.bak" "$CFGROOT/bio2/project.conf"
check "builder back to RESEARCH=0: config succeeds" au config "$NAME"
check "  ...and its overlay, instructions are gone" bash -c '[ "$(grep -v "^#" "$1/research.yaml")" = "$(printf "services:\\n  agent: {}")" ] && [ ! -e "$1/agent-instructions.md" ]' _ "$CFG/.generated"
TOK=""

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
  check "rendered: T3 published on the host's 127.0.0.1 ONLY, project port -> 3773" \
    jq -e '[.services.agent.ports[] | {host_ip, target, published: (.published|tostring), protocol}] == [{"host_ip":"127.0.0.1","target":3773,"published":"3773","protocol":"tcp"}]' <<<"$J"
  check "rendered: t3-$NAME volume at /home/agent/.t3" \
    bash -c '[ "$(jq -r ".volumes.t3.name" <<<"$1")" = "t3-$2" ] && jq -e ".services.agent.volumes[] | select(.target==\"/home/agent/.t3\")" <<<"$1" >/dev/null' _ "$J" "$NAME"
  check "rendered: codex-$NAME volume at /home/agent/.codex (the Codex login survives rebuilds)" \
    bash -c '[ "$(jq -r ".volumes[\"codex-config\"].name" <<<"$1")" = "codex-$2" ] && jq -e ".services.agent.volumes[] | select(.target==\"/home/agent/.codex\" and .source==\"codex-config\")" <<<"$1" >/dev/null' _ "$J" "$NAME"
  check "rendered: hostname is the project name (T3 shows it as the environment)" \
    test "$(jq -r .services.agent.hostname <<<"$J")" = "$NAME"
  check "rendered: restart unless-stopped (back after a reboot)" \
    test "$(jq -r .services.agent.restart <<<"$J")" = unless-stopped
  check "rendered: command is the image entrypoint (firewall first)" \
    jq -e '.services.agent.command == ["/usr/local/bin/agent-entrypoint"]' <<<"$J"
  check "rendered: no env_file (secrets only via op run)" test -z "$(jq -r '.services.agent.env_file // empty' <<<"$J")"
  check "rendered: NET_ADMIN + NET_RAW, explicit mem_limit" \
    jq -e '(.services.agent.cap_add | index("NET_ADMIN") and index("NET_RAW")) and (.services.agent.mem_limit != null)' <<<"$J"
  check "rendered: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" \
    test "$(jq -r '.services.agent.environment.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC' <<<"$J")" = 1
  check "rendered: T3_CONNECT=0 sets no cloudflared env" \
    jq -e '(.services.agent.environment.TUNNEL_EDGE_IP_VERSION == null) and (.services.agent.environment.T3_CONNECT == null)' <<<"$J"
  sed -i 's/^T3_CONNECT=.*/T3_CONNECT=1/' "$CFG/project.conf"
  J1="$(render "$T")"
  sed -i 's/^T3_CONNECT=.*/T3_CONNECT=0/' "$CFG/project.conf"
  check "rendered (T3_CONNECT=1): the switch file from the config dir, read-only, at /etc/firewall/t3-connect" \
    bash -c 'jq -e --arg s "$2" "[.services.agent.volumes[] | select(.target==\"/etc/firewall/t3-connect\") | {type, source, read_only}] == [{\"type\":\"bind\",\"source\":\$s,\"read_only\":true}]" <<<"$1"' _ "$J1" "$CFG/.generated/t3-connect"
  check "rendered (T3_CONNECT=1): exactly two mounts under /etc/firewall (allowlist + switch)" \
    test "$(jq '[.services.agent.volumes[] | select(.target|startswith("/etc/firewall"))] | length' <<<"$J1")" = 2
  check "rendered (T3_CONNECT=1): TUNNEL_EDGE_IP_VERSION=4, T3_CONNECT=1 in the env" \
    jq -e '.services.agent.environment.TUNNEL_EDGE_IP_VERSION == "4" and .services.agent.environment.T3_CONNECT == "1"' <<<"$J1"
  check "rendered (T3_CONNECT=1): otherwise identical to T3_CONNECT=0" \
    bash -c 'diff <(jq -S "del(.services.agent.environment.T3_CONNECT, .services.agent.environment.TUNNEL_EDGE_IP_VERSION) | .services.agent.volumes |= map(select(.target != \"/etc/firewall/t3-connect\"))" <<<"$1") <(jq -S . <<<"$2")' _ "$J1" "$J"
  sed -i 's/^T3_CONNECT=.*/T3_CONNECT=publish/' "$CFG/project.conf"
  JP="$(render "$T")"
  sed -i 's/^T3_CONNECT=.*/T3_CONNECT=0/' "$CFG/project.conf"
  check "rendered (T3_CONNECT=publish): switch mount read-only, env T3_CONNECT=publish, no TUNNEL_EDGE_IP_VERSION" \
    jq -e '.services.agent.environment.T3_CONNECT == "publish" and .services.agent.environment.TUNNEL_EDGE_IP_VERSION == null and ([.services.agent.volumes[] | select(.target=="/etc/firewall/t3-connect") | .read_only] == [true])' <<<"$JP"
  check "rendered (T3_CONNECT=publish): otherwise identical to T3_CONNECT=0" \
    bash -c 'diff <(jq -S "del(.services.agent.environment.T3_CONNECT) | .services.agent.volumes |= map(select(.target != \"/etc/firewall/t3-connect\"))" <<<"$1") <(jq -S . <<<"$2")' _ "$JP" "$J"
  # Research exchange, builder opt-in: exactly three /research mounts + the two instruction files, nothing else changes.
  sed -i 's/^RESEARCH=.*/RESEARCH=1/' "$CFG/project.conf"
  JR="$(render "$T")"
  sed -i 's/^RESEARCH=.*/RESEARCH=0/' "$CFG/project.conf"
  RDR="$(cd "$H/agent-research" && pwd -P)"
  mr(){ jq -c --arg t "$2" '[.services.agent.volumes[] | select(.target==$t) | {type, source, ro: (.read_only // false)}]' <<<"$1"; }
  check "rendered (RESEARCH=1): /research/briefs read-WRITE from RESEARCH_DIR/<project>/briefs" \
    test "$(mr "$JR" /research/briefs)" = "[{\"type\":\"bind\",\"source\":\"$RDR/$NAME/briefs\",\"ro\":false}]"
  for d in reports downloads; do
    check "rendered (RESEARCH=1): /research/$d READ-ONLY from RESEARCH_DIR/<project>/$d" \
      test "$(mr "$JR" "/research/$d")" = "[{\"type\":\"bind\",\"source\":\"$RDR/$NAME/$d\",\"ro\":true}]"
  done
  for t in /etc/claude-code/CLAUDE.md /home/agent/.codex/AGENTS.md; do
    check "rendered (RESEARCH=1): instructions read-only at $t" \
      test "$(mr "$JR" "$t")" = "[{\"type\":\"bind\",\"source\":\"$CFG/.generated/agent-instructions.md\",\"ro\":true}]"
  done
  check "rendered (RESEARCH=1): no profile switch (the builder firewall is unchanged)" \
    test "$(jq '[.services.agent.volumes[] | select(.target=="/etc/firewall/profile")] | length' <<<"$JR")" = 0
  check "rendered (RESEARCH=1): otherwise identical to RESEARCH=0" \
    bash -c 'diff <(jq -S ".services.agent.volumes |= map(select((.target|startswith(\"/research/\")|not) and .target != \"/etc/claude-code/CLAUDE.md\" and .target != \"/home/agent/.codex/AGENTS.md\"))" <<<"$1") <(jq -S . <<<"$2")' _ "$JR" "$J"
  # The shared research container.
  JS="$(cd "$T" && aureal config research --format json)"
  RCFGR="$CFGROOT/research"
  check "rendered research: project name 'research', cwd /research/_general, mem_limit 16g" \
    jq -e '.name == "research" and .services.agent.working_dir == "/research/_general" and ((.services.agent.mem_limit|tostring) == "17179869184")' <<<"$JS"
  check "rendered research: image pinned by digest" bash -c 'jq -r .services.agent.image <<<"$1" | grep -Eq "spades-gis@sha256:[0-9a-f]{64}$"' _ "$JS"
  check "rendered research: NO project, spades.ai, memory, Require cache or project allowlist mount" \
    jq -e '[.services.agent.volumes[].target | select(. == "/workspace" or . == "/opt/memory" or . == "/opt/reference/spades.ai" or . == "/home/agent/.cache/R/Require" or startswith("/etc/firewall/allowlist.d"))] == []' <<<"$JS"
  check "rendered research: environment holds no secret (exactly the 3 seed variables)" \
    jq -e '(.services.agent.environment | keys) == ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC","CLAUDE_CONFIG_DIR","T3_PROJECT_DIR"] and .services.agent.environment.T3_PROJECT_DIR == "/research/_general"' <<<"$JS"
  check "rendered research: /research/_general read-write from RESEARCH_DIR/_general" \
    test "$(mr "$JS" /research/_general)" = "[{\"type\":\"bind\",\"source\":\"$RDR/_general\",\"ro\":false}]"
  check "rendered research: profile switch read-only at /etc/firewall/profile (the only /etc/firewall mount)" \
    bash -c '[ "$(jq -c "[.services.agent.volumes[] | select(.target|startswith(\"/etc/firewall\")) | {target, source, ro: (.read_only // false)}]" <<<"$1")" = "[{\"target\":\"/etc/firewall/profile\",\"source\":\"$2/.generated/profile\",\"ro\":true}]" ]' _ "$JS" "$RCFGR"
  for t in /etc/claude-code/CLAUDE.md /home/agent/.codex/AGENTS.md; do
    check "rendered research: instructions read-only at $t" \
      test "$(mr "$JS" "$t")" = "[{\"type\":\"bind\",\"source\":\"$RCFGR/.generated/agent-instructions.md\",\"ro\":true}]"
  done
  for p in bio2 "$NAME"; do
    check "rendered research: /research/$p/briefs READ-ONLY" test "$(mr "$JS" "/research/$p/briefs")" = "[{\"type\":\"bind\",\"source\":\"$RDR/$p/briefs\",\"ro\":true}]"
    for d in reports downloads; do
      check "rendered research: /research/$p/$d read-write" test "$(mr "$JS" "/research/$p/$d")" = "[{\"type\":\"bind\",\"source\":\"$RDR/$p/$d\",\"ro\":false}]"
    done
  done
  check "rendered research: every read-write bind is inside RESEARCH_DIR" \
    bash -c 'jq -r ".services.agent.volumes[] | select(.type==\"bind\" and ((.read_only // false)|not)) | .source" <<<"$1" | while IFS= read -r s; do case "$s" in "$2"/*) ;; *) echo "rw outside: $s"; exit 1;; esac; done' _ "$JS" "$RDR"
  check "rendered research: its OWN volumes (claude/codex/npm-cache/rlib/t3-research), nothing shared or external" \
    jq -e '[.volumes[] | {name, external: (.external // false)}] | sort_by(.name) == [{"name":"claude-research","external":false},{"name":"codex-research","external":false},{"name":"npm-cache-research","external":false},{"name":"rlib-research","external":false},{"name":"t3-research","external":false}]' <<<"$JS"
  check "rendered research: T3 on the host's 127.0.0.1 only" \
    jq -e '[.services.agent.ports[] | {host_ip, target}] == [{"host_ip":"127.0.0.1","target":3773}]' <<<"$JS"
  research_hidden(){ local o; o="$(cd "$T" && aureal config research --format json)" || return 1; ! grep -q dummy-render <<<"$o"; }
  AMBIENT=(GH_TOKEN=dummy-render OP_SERVICE_ACCOUNT_TOKEN=dummy-render)
  check "rendered research: ambient GH_TOKEN / OP_SERVICE_ACCOUNT_TOKEN never appear" research_hidden
  AMBIENT=()
  ( cd "$T" && aureal config "$NAME" >/dev/null 2>&1 ) || true   # regenerate the T3_CONNECT=0 overlay
  # RStudio OFF must render exactly what the launcher rendered before RStudio existed (no overlay).
  JPRE="$(cd "$T" && env -u PROJECT -u PROJECT_DIR -u SPADES_AI_DIR -u AGENT_MEMORY_DIR -u T3_PORT -u T3_CONNECT HOME="$H" DOCKER_CONFIG="$REAL_HOME/.docker" \
          docker compose --env-file "$CFG/project.conf" -f "$CFG/compose.yaml" -f "$CFG/.generated/env-passthrough.yaml" \
          -f "$CFG/.generated/t3-connect.yaml" -f "$CFG/.generated/research.yaml" -f "$CFG/.generated/hostname.yaml" -f "$CFG/.generated/restart.yaml" --project-directory "$CFG" -p "$NAME" config --format json)"
  check "rendered (RSTUDIO=0): identical to the config rendered without the RStudio overlay" \
    bash -c 'diff <(jq -S . <<<"$1") <(jq -S . <<<"$2")' _ "$JPRE" "$J"
  check "rendered (RSTUDIO=0): no rstudio volume, no 8787" \
    bash -c '[ "$(jq -r ".volumes.rstudio // empty" <<<"$1")" = "" ] && ! grep -q 8787 <<<"$1"' _ "$J"
  sed -i 's/^RSTUDIO=.*/RSTUDIO=1/' "$CFG/project.conf"
  JR="$(render "$T")"
  sed -i 's/^RSTUDIO=.*/RSTUDIO=0/' "$CFG/project.conf"
  ( cd "$T" && aureal config "$NAME" >/dev/null 2>&1 ) || true   # regenerate the RSTUDIO=0 overlay
  check "rendered (RSTUDIO=1): ports = T3 + RStudio, both on the host's 127.0.0.1 only" \
    jq -e '[.services.agent.ports[] | {host_ip, target, published: (.published|tostring), protocol}] | sort_by(.target) == [{"host_ip":"127.0.0.1","target":3773,"published":"3773","protocol":"tcp"},{"host_ip":"127.0.0.1","target":8787,"published":"8787","protocol":"tcp"}]' <<<"$JR"
  check "rendered (RSTUDIO=1): rstudio-$NAME volume at /home/agent/.local/share/rstudio" \
    bash -c '[ "$(jq -r ".volumes.rstudio.name" <<<"$1")" = "rstudio-$2" ] && jq -e ".services.agent.volumes[] | select(.target==\"/home/agent/.local/share/rstudio\" and .source==\"rstudio\")" <<<"$1" >/dev/null' _ "$JR" "$NAME"
  check "rendered (RSTUDIO=1): switch + password from the config dir, read-only" \
    bash -c 'jq -e --arg s "$2" --arg p "$3" "[.services.agent.volumes[] | select(.target==\"/etc/firewall/rstudio\" or .target==\"/run/secrets/rstudio-password\") | {type, source, read_only}] | sort_by(.source) == ([{\"type\":\"bind\",\"source\":\$s,\"read_only\":true},{\"type\":\"bind\",\"source\":\$p,\"read_only\":true}] | sort_by(.source))" <<<"$1"' _ "$JR" "$CFG/.generated/rstudio" "$CFG/.generated/rstudio-password"
  check "rendered (RSTUDIO=1): the password is not in the environment" \
    bash -c '! jq -r ".services.agent.environment | to_entries[] | .value" <<<"$1" | grep -qF "$(cat "$2")"' _ "$JR" "$CFG/.generated/rstudio-password"
  check "rendered (RSTUDIO=1): otherwise identical to RSTUDIO=0" \
    bash -c 'diff <(jq -S "del(.volumes.rstudio) | .services.agent.ports |= map(select(.target != 8787)) | .services.agent.volumes |= map(select(.target != \"/etc/firewall/rstudio\" and .target != \"/run/secrets/rstudio-password\" and .target != \"/home/agent/.local/share/rstudio\"))" <<<"$1") <(jq -S . <<<"$2")' _ "$JR" "$J"
  # FTP_HOSTS unset must render exactly what the launcher rendered before FTP existed (no overlay).
  JNOFTP="$(cd "$T" && env -u PROJECT -u PROJECT_DIR -u SPADES_AI_DIR -u AGENT_MEMORY_DIR -u T3_PORT -u T3_CONNECT HOME="$H" DOCKER_CONFIG="$REAL_HOME/.docker" \
          docker compose --env-file "$CFG/project.conf" -f "$CFG/compose.yaml" -f "$CFG/.generated/env-passthrough.yaml" \
          -f "$CFG/.generated/t3-connect.yaml" -f "$CFG/.generated/research.yaml" -f "$CFG/.generated/rstudio.yaml" -f "$CFG/.generated/hostname.yaml" -f "$CFG/.generated/restart.yaml" --project-directory "$CFG" -p "$NAME" config --format json)"
  check "rendered (FTP_HOSTS unset): identical to the config rendered without the FTP overlay" \
    bash -c 'diff <(jq -S . <<<"$1") <(jq -S . <<<"$2")' _ "$JNOFTP" "$J"
  cp "$CFG/project.conf" "$T/pconf-ftp-render.bak"
  echo "FTP_HOSTS=webin2.ebi.ac.uk ftp-private.ncbi.nlm.nih.gov" >> "$CFG/project.conf"   # unquoted, with a space: compose's --env-file must accept it
  JF="$(render "$T")"
  cp "$T/pconf-ftp-render.bak" "$CFG/project.conf"
  ( cd "$T" && aureal config "$NAME" >/dev/null 2>&1 ) || true   # regenerate the FTP-off overlay
  check "rendered (FTP_HOSTS set): the host file from the config dir, read-only, at /etc/firewall/ftp-hosts" \
    bash -c 'jq -e --arg s "$2" "[.services.agent.volumes[] | select(.target==\"/etc/firewall/ftp-hosts\") | {type, source, read_only}] == [{\"type\":\"bind\",\"source\":\$s,\"read_only\":true}]" <<<"$1"' _ "$JF" "$CFG/.generated/ftp-hosts"
  check "rendered (FTP_HOSTS set): exactly two mounts under /etc/firewall (allowlist + FTP hosts)" \
    test "$(jq '[.services.agent.volumes[] | select(.target|startswith("/etc/firewall"))] | length' <<<"$JF")" = 2
  check "rendered (FTP_HOSTS set): no FTP setting in the environment (the firewall reads only the file)" \
    bash -c '! jq -r ".services.agent.environment | keys[]" <<<"$1" | grep -qi ftp' _ "$JF"
  check "rendered (FTP_HOSTS set): otherwise identical to FTP_HOSTS unset" \
    bash -c 'diff <(jq -S ".services.agent.volumes |= map(select(.target != \"/etc/firewall/ftp-hosts\"))" <<<"$1") <(jq -S . <<<"$2")' _ "$JF" "$J"
  check "rendered (back to unset): the host file is gone" test ! -e "$CFG/.generated/ftp-hosts"
  ambient_hidden(){ local o; o="$(cd "$T" && aureal config "$NAME" --format json)" || return 1; ! grep -q dummy-render <<<"$o"; }
  AMBIENT=(GH_TOKEN=dummy-render)
  check "rendered: config never prints the owner's ambient value of a passthrough key" ambient_hidden
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

# In CI, a container's state and log tail as ONE annotation (job logs are not readable remotely).
diag(){ [ -n "${GITHUB_ACTIONS:-}" ] || return 0
  local m; m=$( { docker inspect -f 'state={{.State.Status}} exit={{.State.ExitCode}} err={{.State.Error}}' "$1"; docker logs "$1" 2>&1 | grep -vE '^\[install-|^Adding GitHub range' | tail -n 40; } 2>&1 | sed 's/%/%25/g; s/\r//g' | awk '{printf "%s%%0A", $0}')
  echo "::notice title=$2 container::$m"; }
# ---- behavioural: the rendered sandbox against the CI-built image (TEMPLATE_IMAGE=spades-base:ci).
# `agent-up up` needs a registry digest, so this uses the SAME compose arguments agent-up uses
# (pinned above) plus one override that swaps in the local image and skips agent-init.
if [ -n "${TEMPLATE_IMAGE:-}" ]; then
  docker image inspect "$TEMPLATE_IMAGE" >/dev/null 2>&1 || { echo "FAIL: TEMPLATE_IMAGE=$TEMPLATE_IMAGE not present"; exit 1; }
  printf 'www.python.org\n' >> "$CFG/allowlist"
  # T3 Connect ON here: proves the whole chain project.conf -> agent-up overlay -> read-only switch ->
  # root firewall. (OFF is the absent switch, which the CI firewall steps cover.)
  sed -i 's/^T3_CONNECT=.*/T3_CONNECT=1/' "$CFG/project.conf"
  # Research exchange ON too (its folders exist from the research section above).
  sed -i 's/^RESEARCH=.*/RESEARCH=1/' "$CFG/project.conf"
  # RStudio Server ON too: project.conf -> overlay -> read-only switch -> firewall + entrypoint -> rserver.
  sed -i 's/^RSTUDIO=.*/RSTUDIO=1/' "$CFG/project.conf"
  # FTP uploads ON too: project.conf -> overlay -> read-only host list -> firewall. Only where the kernel
  # has the FTP conntrack helper (CI loads it on the runner); without it the firewall refuses to start.
  FTP_BEHAV=0
  if [ -d /sys/module/nf_conntrack_ftp ]; then
    echo "FTP_HOSTS=ftp.ebi.ac.uk" >> "$CFG/project.conf"; FTP_BEHAV=1
  else
    echo "SKIP: FTP behavioural checks (nf_conntrack_ftp not loaded on this host: sudo modprobe nf_conntrack_ftp)"
  fi
  au config "$NAME" >/dev/null 2>&1 || true   # (re)writes .generated/ (stub docker)
  # CI-ONLY: the runner's uid is not 1000, so the agent could not read the 0600 password file.
  # In real use the host user IS uid 1000 (spec §3.1) and the file stays 0600.
  chmod 644 "$CFG/.generated/rstudio-password"
  cp "$ROOT/tests/rstudio/fixture-Rprofile" "$P/.Rprofile"; cp "$ROOT/tests/rstudio/fixture.Rproj" "$P/demo.Rproj"
  # CI-ONLY: GH_META_FIXTURE (the workflow's ONE authenticated api.github.com/meta fetch) is mounted
  # read-only where init-firewall.sh takes it instead of fetching, so these containers (and their
  # firewall re-runs) do not spend the runner's unauthenticated rate limit. Only in this test-owned
  # override, which the render checks above never see; agent-up and the template never mount it.
  OVR_VOLS="\"$ROOT/tests:/tests:ro\""; GH_META_BEHAV=0
  if [ -n "${GH_META_FIXTURE:-}" ] && [ -f "$GH_META_FIXTURE" ] && [ -r "$GH_META_FIXTURE" ]; then
    GH_META_ABS="$(cd "$(dirname "$GH_META_FIXTURE")" && pwd -P)/$(basename "$GH_META_FIXTURE")"
    OVR_VOLS="$OVR_VOLS, \"$GH_META_ABS:/etc/firewall/github-meta.json:ro\""; GH_META_BEHAV=1
    echo "NOTE: behavioural containers get the host-supplied GitHub meta ($GH_META_ABS)"
  fi
  cat > "$T/override.yaml" <<OVR
services:
  agent:
    image: $TEMPLATE_IMAGE
    mem_limit: 4g
    volumes: [$OVR_VOLS]   # test scripts only (tests/rstudio)
OVR
  dc(){ env -u PROJECT -u PROJECT_DIR -u SPADES_AI_DIR -u AGENT_MEMORY_DIR -u COMPOSE_FILE HOME="$H" DOCKER_CONFIG="$REAL_HOME/.docker" GH_TOKEN=dummy-in-container \
          docker compose --env-file "$CFG/project.conf" -f "$CFG/compose.yaml" -f "$CFG/.generated/env-passthrough.yaml" \
          -f "$CFG/.generated/t3-connect.yaml" -f "$CFG/.generated/research.yaml" -f "$CFG/.generated/rstudio.yaml" -f "$CFG/.generated/ftp.yaml" -f "$CFG/.generated/hostname.yaml" -f "$CFG/.generated/restart.yaml" -f "$T/override.yaml" --project-directory "$CFG" -p "$NAME" "$@"; }
  # The research container: agent-up's exact arguments, with the owner's ambient secrets in compose's
  # environment (they must NOT reach the container).
  rdc(){ env -u PROJECT -u PROJECT_DIR -u SPADES_AI_DIR -u AGENT_MEMORY_DIR -u COMPOSE_FILE HOME="$H" DOCKER_CONFIG="$REAL_HOME/.docker" \
          GH_TOKEN=ambient-gh OP_SERVICE_ACCOUNT_TOKEN=ambient-op \
          docker compose --env-file "$RCFG/project.conf" -f "$RCFG/compose.yaml" -f "$RCFG/.generated/env-passthrough.yaml" \
          -f "$RCFG/.generated/t3-connect.yaml" -f "$RCFG/.generated/research.yaml" -f "$RCFG/.generated/rstudio.yaml" -f "$RCFG/.generated/ftp.yaml" -f "$RCFG/.generated/hostname.yaml" -f "$RCFG/.generated/restart.yaml" -f "$T/override.yaml" --project-directory "$RCFG" -p research "$@"; }
  # The agent (uid 1000) writes into the project dir (e.g. RStudio's .Rproj.user): hand $T back to the
  # runner before removing it, or the EXIT trap's rm fails and turns a passing run into exit 1.
  reclaim(){ docker run --rm -u root -v "$T:/t" "$TEMPLATE_IMAGE" chown -R "$(id -u):$(id -g)" /t >/dev/null 2>&1 || true; }
  trap 'dc down -v >/dev/null 2>&1 || true; rdc down -v >/dev/null 2>&1 || true; reclaim; rm -rf "$T"' EXIT
  for v in require-cache-shared npm-cache-shared; do
    docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null
  done
  # CI runner UID != 1000. In real use these are the agent's own (UID 1000) directories.
  touch "$P/.from-host"   # sentinel: proves /workspace is the host project dir, not the image's empty dir
  chmod -R a+rwX "$P" "$H/GitHub/spades.ai" "$H/agent-memory" "$H/agent-research"
  echo "# a finding" > "$H/agent-research/$NAME/reports/host-report.md"
  check "sandbox starts" dc up -d
  CID="$(dc ps -q agent || true)"
  if [ -z "$CID" ]; then
    check "sandbox container id" false
  else
    # The REAL entrypoint runs: firewall -> agent-init (Claude Code, Codex, plugins) -> T3. T3 answering on the
    # host's published port means all three finished.
    T3P=$(sed -n 's/^T3_PORT=//p' "$CFG/project.conf")
    for _ in $(seq 1 240); do curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$T3P/" 2>/dev/null && break; sleep 2; done
    check "firewall initialised by the entrypoint" bash -c 'docker logs "$1" 2>&1 | grep -q "Firewall verification passed - CRAN reachable"' _ "$CID"
    diag "$CID" builder
    if [ "$GH_META_BEHAV" = 1 ]; then
      check "  ...with the host-supplied GitHub meta (no live fetch)" \
        bash -c 'l="$(docker logs "$1" 2>&1)"; grep -q "^GitHub meta: from /etc/firewall/github-meta.json" <<<"$l" && ! grep -q "Fetching GitHub IP ranges" <<<"$l"' _ "$CID"
    fi
    check "  ...and BEFORE agent-init and T3 started (log order)" \
      bash -c 'docker logs "$1" 2>&1 | grep -nE "Firewall verification passed - CRAN|\[agent-init\]|\[agent-t3\]" | head -n 1 | grep -q "Firewall verification"' _ "$CID"
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
    # dc runs with a dummy GH_TOKEN in its environment (what `op run` supplies in real use).
    check "a project.env secret reaches the container env" test "$(docker exec "$CID" printenv GH_TOKEN)" = dummy-in-container
    check "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 in the container" \
      test "$(docker exec "$CID" printenv CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC)" = 1
    for host in sentry.io statsig.com; do
      check "$host is refused by the firewall DNS (decision B)" \
        bash -c 'docker exec -u agent "$1" dig @127.0.0.1 "$2" A +time=2 +tries=1 +noall +comments | grep -q "status: REFUSED"' _ "$CID" "$host"
    done
    check "release-assets.githubusercontent.com still resolves (decision C)" \
      bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 release-assets.githubusercontent.com A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
    # Claude Code is not in the image: it installs at start, BEHIND the firewall, into the shared volume.
    check "the entrypoint installed Claude Code behind the firewall (npm ci, integrity-checked)" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "\[install-claude-code\] installed: claude"' _ "$CID"
    check "install-claude-code reruns cleanly" docker exec -u agent "$CID" install-claude-code
    check "  ...claude reports the pinned version" \
      bash -c 'want=$(docker exec "$1" jq -r ".dependencies[\"@anthropic-ai/claude-code\"]" /usr/local/lib/agent/clis/claude-code/package.json); docker exec -u agent "$1" claude --version | grep -qE "^${want//./\\.}( |$)"' _ "$CID"
    check "  ...installed in the container's own layer, under the lockfile's hash" \
      bash -c 'id=$(docker exec "$1" cat /usr/local/lib/agent/clis/claude-code/INSTALL_ID); docker exec "$1" test -x "/opt/claude-code/$id/node_modules/.bin/claude"' _ "$CID"
    check "  ...the download landed in the shared npm cache volume" \
      bash -c '[ -n "$(docker run --rm -v npm-cache-shared:/v "$2" find /v/_cacache -type f -print -quit)" ]' _ "$CID" "$TEMPLATE_IMAGE"
    check "  ...a second run reuses it (no reinstall)" \
      bash -c 'docker exec -u agent "$1" install-claude-code | grep -q "present: claude"' _ "$CID"
    check "  ...no temp dirs left behind" \
      bash -c '[ -z "$(docker exec "$1" find /opt/claude-code -maxdepth 1 -name ".tmp.*")" ]' _ "$CID"
    check "auto-updater disabled in the image" test "$(docker exec "$CID" printenv DISABLE_AUTOUPDATER)" = 1
    # Codex: the same install path (install-agent-cli), its own lockfile, its own login volume.
    check "the entrypoint installed Codex behind the firewall (npm ci, integrity-checked)" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "\[install-codex\] installed: codex"' _ "$CID"
    check "  ...codex reports the pinned version" \
      bash -c 'want=$(docker exec "$1" jq -r ".dependencies[\"@openai/codex\"]" /usr/local/lib/agent/clis/codex/package.json); docker exec -u agent "$1" codex --version | grep -qE "^codex-cli ${want//./\\.}$"' _ "$CID"
    check "  ...installed in the container's own layer, under the lockfile's hash, with its native build" \
      bash -c 'id=$(docker exec "$1" cat /usr/local/lib/agent/clis/codex/INSTALL_ID); docker exec "$1" test -x "/opt/codex/$id/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex"' _ "$CID"
    check "  ...a second run reuses it (no reinstall)" \
      bash -c 'docker exec -u agent "$1" install-codex | grep -q "present: codex"' _ "$CID"
    check "  ...CODEX_HOME is the codex-<project> volume, owned by agent" \
      bash -c '[ "$(docker exec "$1" printenv CODEX_HOME)" = /home/agent/.codex ] && [ "$(docker exec "$1" stat -c %u:%g /home/agent/.codex)" = 1000:1000 ] && docker inspect -f "{{range .Mounts}}{{.Name}}={{.Destination}} {{end}}" "$1" | grep -q "codex-$2=/home/agent/.codex"' _ "$CID" "$NAME"
    check "  ...config.toml: analytics off, no update check, the container is the sandbox" \
      bash -c 'c=$(docker exec "$1" cat /home/agent/.codex/config.toml); for l in "approval_policy = \"never\"" "sandbox_mode = \"danger-full-access\"" "check_for_update_on_startup = false" "[analytics]" "enabled = false"; do grep -qxF "$l" <<<"$c" || { echo "missing: $l"; exit 1; }; done' _ "$CID"
    # `login status` loads (and so validates) config.toml first: a parse error says "Error loading configuration".
    check "  ...codex accepts that config (login status: not logged in, no config error)" \
      bash -c 'out=$(docker exec -u agent "$1" codex login status 2>&1); echo "$out"; grep -q "Not logged in" <<<"$out"' _ "$CID"
    # T3 Code: reachable from the host through the published loopback port, and ONLY from the gateway.
    check "T3 server started by the entrypoint" bash -c 'docker logs "$1" 2>&1 | grep -q "\[agent-t3\] server up"' _ "$CID"
    check "  ...reachable from the host at 127.0.0.1:<T3_PORT>" curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$T3P/"
    check "  ...also under the per-project origin <project>.localhost" \
      curl -fsS -o /dev/null --max-time 5 -H "Host: $NAME.localhost:$T3P" "http://127.0.0.1:$T3P/"
    check "the container's hostname is the project name" test "$(docker exec "$CID" hostname)" = "$NAME"
    check "  ...agent-t3 start is idempotent" bash -c 'docker exec -u agent "$1" agent-t3 start | grep -q "already running"' _ "$CID"
    check "  ...NOT reachable from a sibling container on the same network (firewall: gateway only)" \
      bash -c 'net=$(docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" "$1"); ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$1"); [ -n "$net" ] && [ -n "$ip" ] || exit 1; rc=0; docker run --rm --network "$net" "$2" curl -sS -o /dev/null --max-time 5 "http://$ip:3773/" || rc=$?; echo "curl rc=$rc (28 = timed out: dropped by the firewall)"; [ "$rc" -eq 28 ]' _ "$CID" "$TEMPLATE_IMAGE"
    check "  ...a pairing token can be minted (exact field, untruncated)" bash -c 'docker exec -u agent "$1" agent-t3 pair ci | grep -Eqx "token=[A-Za-z0-9._~%-]+"' _ "$CID"
    check "platform.claude.com resolves (Claude subscription login)" \
      bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 platform.claude.com A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
    for host in chatgpt.com auth.openai.com; do
      check "$host resolves (Codex: ChatGPT login and backend)" \
        bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 "$2" A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID" "$host"
    done
    # T3 Connect (T3_CONNECT=1 above): the firewall read the owner's switch, and the agent cannot flip it.
    check "T3 Connect: the firewall read the switch (log says ON)" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "^T3 Connect: ON"' _ "$CID"
    check "  ...port 7844 open to the t3-tunnel set only (udp + tcp)" \
      bash -c '[ "$(docker exec -u root "$1" iptables -S OUTPUT | grep -c -- "--dport 7844")" = 2 ] && [ "$(docker exec -u root "$1" iptables -S OUTPUT | grep -- "--dport 7844" | grep -vc -- "--match-set t3-tunnel dst")" = 0 ]' _ "$CID"
    check "  ...the switch is a read-only mount (even root cannot write it)" \
      bash -c 'out="$(docker exec -u root "$1" sh -c "echo T3_CONNECT=0 > /etc/firewall/t3-connect" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$CID"
    check "  ...cloudflared gets TUNNEL_EDGE_IP_VERSION=4" test "$(docker exec "$CID" printenv TUNNEL_EDGE_IP_VERSION)" = 4
    check "  ...relay.t3.codes resolves" \
      bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 relay.t3.codes A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
    check "  ...an agent re-run of the firewall keeps it ON (the switch, not the env, decides)" \
      bash -c 'out=$(docker exec -u agent -e T3_CONNECT=0 "$1" sudo /usr/local/bin/init-firewall.sh 2>&1) && grep -q "^T3 Connect: ON" <<<"$out"' _ "$CID"
    # FTP uploads (FTP_HOSTS above): the firewall read the owner's host list, and the agent cannot change it.
    if [ "$FTP_BEHAV" = 1 ]; then
      check "FTP: the firewall read the host list (log says ON for ftp.ebi.ac.uk)" \
        bash -c 'docker logs "$1" 2>&1 | grep -q "^FTP: ON (hosts ftp.ebi.ac.uk;"' _ "$CID"
      check "  ...exactly one tcp 21 rule, to the ftp-hosts set only" \
        bash -c '[ "$(docker exec -u root "$1" iptables -S OUTPUT | grep -E -- "--dport 21( |\$)")" = "-A OUTPUT -p tcp -m tcp --dport 21 -m set --match-set ftp-hosts dst -j ACCEPT" ]' _ "$CID"
      check "  ...the ftp conntrack helper is attached in the raw table" \
        bash -c 'docker exec -u root "$1" iptables-save -t raw | grep -qx -- "-A AGENT_FTP -p tcp -m tcp --dport 21 -m set --match-set ftp-hosts dst -j CT --helper ftp"' _ "$CID"
      check "  ...the in-container host list == the generated file" \
        bash -c 'diff <(docker exec -u root "$1" cat /etc/firewall/ftp-hosts) "$2"' _ "$CID" "$CFG/.generated/ftp-hosts"
      check "  ...the host list is a read-only mount (even root cannot write it)" \
        bash -c 'out="$(docker exec -u root "$1" sh -c "echo evil.example >> /etc/firewall/ftp-hosts" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$CID"
      check "  ...an agent re-run of the firewall keeps it ON (the file, not the env, decides)" \
        bash -c 'out=$(docker exec -u agent -e FTP_HOSTS= "$1" sudo /usr/local/bin/init-firewall.sh 2>&1) && grep -q "^FTP: ON" <<<"$out"' _ "$CID"
    fi
    # RStudio Server (RSTUDIO=1 above): started by the entrypoint after T3, only because of the switch.
    RSP=$(sed -n 's/^RSTUDIO_PORT=//p' "$CFG/project.conf")
    for _ in $(seq 1 60); do [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$RSP/")" != 000 ] && break; sleep 2; done
    check "RStudio: the firewall read the switch (log says ON)" bash -c 'docker logs "$1" 2>&1 | grep -q "^RStudio Server: ON"' _ "$CID"
    check "  ...one INPUT rule for 8787, from the gateway only" \
      bash -c 'gw=$(docker exec "$1" ip -4 route show default | awk "{print \$3; exit}"); [ "$(docker exec -u root "$1" iptables -S INPUT | grep -- "--dport 8787")" = "-A INPUT -s $gw/32 -p tcp -m tcp --dport 8787 -j ACCEPT" ]' _ "$CID"
    check "  ...the switch is a read-only mount (even root cannot write it)" \
      bash -c 'out="$(docker exec -u root "$1" sh -c "echo RSTUDIO=0 > /etc/firewall/rstudio" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$CID"
    check "  ...so is the password file" \
      bash -c 'out="$(docker exec -u root "$1" sh -c "echo x > /run/secrets/rstudio-password" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$CID"
    check "  ...the password is not in the container's environment" \
      bash -c '! docker exec "$1" env | grep -qF "$(cat "$2")"' _ "$CID" "$CFG/.generated/rstudio-password"
    check "  ...started by the entrypoint after T3" \
      bash -c 'docker logs "$1" 2>&1 | grep -nE "\[agent-t3\] server up|\[agent-rstudio\] server up" | cut -d: -f2- | tr "\n" "|" | grep -q "^\[agent-t3\] server up.*|\[agent-rstudio\] server up"' _ "$CID"
    check "  ...reachable from the host at 127.0.0.1:<RSTUDIO_PORT> under rstudio-<project>.localhost (sign-in page)" \
      bash -c '[ "$(curl -s -o /dev/null -w "%{http_code} %{redirect_url}" --max-time 5 -H "Host: rstudio-$2.localhost:$1" "http://127.0.0.1:$1/")" != "000 " ]' _ "$RSP" "$NAME"
    check "  ...NOT reachable from a sibling container on the same network (firewall: gateway only)" \
      bash -c 'net=$(docker inspect -f "{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{end}}" "$1"); ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$1"); [ -n "$net" ] && [ -n "$ip" ] || exit 1; rc=0; docker run --rm --network "$net" "$2" curl -sS -o /dev/null --max-time 5 "http://$ip:8787/" || rc=$?; echo "curl rc=$rc (28 = timed out: dropped by the firewall)"; [ "$rc" -eq 28 ]' _ "$CID" "$TEMPLATE_IMAGE"
    check "  ...rstudio-$NAME volume at ~/.local/share/rstudio, owned by agent" \
      bash -c 'docker inspect -f "{{range .Mounts}}{{.Name}}={{.Destination}} {{end}}" "$1" | grep -q "rstudio-$2=/home/agent/.local/share/rstudio" && [ "$(docker exec "$1" stat -c %u /home/agent/.local/share/rstudio)" = 1000 ]' _ "$CID" "$NAME"
    # Sign in with the generated password, open the IDE, and check the R session (tests/rstudio).
    check "  ...sign-in + R session end to end (tests/rstudio/test-rstudio.sh)" \
      docker exec -u agent -e EXPECT_GH_TOKEN=dummy-in-container "$CID" bash /tests/rstudio/test-rstudio.sh
    check "project-allowlisted www.python.org resolves" \
      bash -c '[ -n "$(docker exec -u agent "$1" dig @127.0.0.1 www.python.org A +short +time=3 +tries=2 | grep -E "^[0-9.]+$")" ]' _ "$CID"
    # Research exchange (RESEARCH=1): briefs out read-write; reports and downloads in, read-only.
    check "RESEARCH=1: the agent can write /research/briefs" docker exec -u agent "$CID" sh -c 'echo brief > /research/briefs/b.md'
    check "  ...it lands in the host's RESEARCH_DIR/<project>/briefs" test -f "$H/agent-research/$NAME/briefs/b.md"
    check "  ...the agent reads the research reports" docker exec -u agent "$CID" grep -q "a finding" /research/reports/host-report.md
    for d in reports downloads; do
      check "  .../research/$d is a read-only mount (even root cannot write it)" \
        bash -c 'out="$(docker exec -u root "$1" sh -c "echo x > /research/$2/x" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$CID" "$d"
    done
    check "  ...the owner's instructions at Claude's managed CLAUDE.md (untrusted data), read-only" \
      bash -c 'docker exec -u agent "$1" grep -q "UNTRUSTED DATA" /etc/claude-code/CLAUDE.md && ! docker exec -u root "$1" sh -c "echo x >> /etc/claude-code/CLAUDE.md" 2>/dev/null' _ "$CID"
    check "  ...the same for Codex (AGENTS.md in CODEX_HOME)" docker exec -u agent "$CID" grep -q "UNTRUSTED DATA" /home/agent/.codex/AGENTS.md
    check "  ...the builder firewall is unchanged (no profile switch: allowlist only)" \
      bash -c '! docker exec "$1" test -e /etc/firewall/profile && ! docker logs "$1" 2>&1 | grep -q "^Profile: research"' _ "$CID"
  fi
  dc down -v >/dev/null 2>&1 || true

  # ---- the shared research container (PROFILE=research), real entrypoint
  au config research >/dev/null 2>&1 || true   # (re)writes its .generated/ (stub docker)
  check "research container starts" rdc up -d
  RID="$(rdc ps -q agent || true)"
  if [ -z "$RID" ]; then
    check "research container id" false
  else
    RP=$(sed -n 's/^T3_PORT=//p' "$RCFG/project.conf")
    for _ in $(seq 1 240); do curl -fsS -o /dev/null --max-time 3 "http://127.0.0.1:$RP/" 2>/dev/null && break; sleep 2; done
    diag "$RID" research
    if [ "$GH_META_BEHAV" = 1 ]; then
      check "research: firewall used the host-supplied GitHub meta (no live fetch)" \
        bash -c 'l="$(docker logs "$1" 2>&1)"; grep -q "^GitHub meta: from /etc/firewall/github-meta.json" <<<"$l" && ! grep -q "Fetching GitHub IP ranges" <<<"$l"' _ "$RID"
    fi
    check "research: firewall in research mode (read from the switch)" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "^Profile: research" && docker logs "$1" 2>&1 | grep -q "Firewall verification passed - research"' _ "$RID"
    check "research: NO GH_TOKEN and no OP_* in the container (ambient owner secrets did not leak)" \
      bash -c 'e="$(docker exec "$1" env)"; ! grep -Eq "^(GH_TOKEN|GITHUB_TOKEN|OP_[A-Z_]*)=" <<<"$e" && ! grep -q ambient- <<<"$e"' _ "$RID"
    check "research: no project, spades.ai or memory mount" \
      bash -c '! docker inspect -f "{{range .Mounts}}{{.Destination}} {{end}}" "$1" | grep -Eq "(^| )(/workspace|/opt/memory|/opt/reference/spades.ai)( |$)"' _ "$RID"
    check "research: /research holds exactly the exchange projects + _general" \
      test "$(docker exec -u agent "$RID" sh -c 'LC_ALL=C ls /research' | paste -sd' ' -)" = "_general bio2 $NAME"
    check "  ...briefs are READ-ONLY for the research agent (even root)" \
      bash -c 'out="$(docker exec -u root "$1" sh -c "echo x > /research/$2/briefs/x" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$RID" "$NAME"
    check "  ...it reads the builder's brief" docker exec -u agent "$RID" grep -q brief "/research/$NAME/briefs/b.md"
    for d in reports downloads; do
      check "  ...it writes /research/$NAME/$d" docker exec -u agent "$RID" sh -c "echo r > /research/$NAME/$d/from-research.txt"
    done
    check "  ...and cannot create a new project folder" bash -c '! docker exec -u agent "$1" mkdir /research/newproj 2>/dev/null' _ "$RID"
    check "research: its instructions at Claude's managed CLAUDE.md, read-only" \
      bash -c 'docker exec -u agent "$1" grep -q "shared RESEARCH agent" /etc/claude-code/CLAUDE.md && ! docker exec -u root "$1" sh -c "echo x >> /etc/claude-code/CLAUDE.md" 2>/dev/null' _ "$RID"
    check "research: the profile switch is a read-only mount (even root cannot write it)" \
      bash -c 'out="$(docker exec -u root "$1" sh -c "echo PROFILE=builder > /etc/firewall/profile" 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && printf "%s" "$out" | grep -q "Read-only file system"' _ "$RID"
    check "research: an agent re-run of the firewall stays research (the switch, not the env, decides)" \
      bash -c 'out=$(docker exec -u agent -e PROFILE=builder "$1" sudo /usr/local/bin/init-firewall.sh 2>&1) && grep -q "^Profile: research" <<<"$out"' _ "$RID"
    check "research: open egress (non-allowlisted https://example.com)" docker exec -u agent "$RID" curl -q -fsS -o /dev/null --max-time 20 https://example.com/
    check "research: the gateway (host) is rejected" \
      bash -c 'gw=$(docker exec "$1" ip -4 route show default | awk "{print \$3; exit}"); e=$(docker exec -u agent "$1" bash -c "timeout 8 bash -c \"</dev/tcp/$gw/3773\"" 2>&1); [ $? -ne 0 ] && grep -Eq "No route to host|Operation not permitted" <<<"$e"' _ "$RID"
    check "research: T3 started with /research as its project" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "\[agent-t3\] server up" && docker exec "$1" pgrep -af "t3 serve" | grep -q -- "--auto-bootstrap-project-from-cwd /research"' _ "$RID"
    check "  ...reachable from the host at 127.0.0.1:<its T3_PORT>" curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$RP/"
    check "research: Claude Code and Codex installed (own npm cache)" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "\[install-claude-code\] installed: claude" && docker logs "$1" 2>&1 | grep -q "\[install-codex\] installed: codex"' _ "$RID"
    check "research: no GitHub write identity (agent-init saw no GH_TOKEN)" \
      bash -c 'docker logs "$1" 2>&1 | grep -q "no GH_TOKEN" && [ -z "$(docker exec -u agent "$1" git config --global user.email 2>/dev/null)" ]' _ "$RID"
  fi
  rdc down -v >/dev/null 2>&1 || true
else
  echo "SKIP: behavioural sandbox checks (set TEMPLATE_IMAGE to a built image; CI does)"
fi

# ---- busy: is R work or an agent running? (two ps snapshots per container)
BC="$NAME-agent-1"
snap(){ # $1 container, $2 snapshot number (1|2), stdin = ps -eo pid=,ppid=,etimes=,cputimes=,comm=,args= lines
  cat > "$T/ps.$1.$2"; rm -f "$T/ps.$1.count"; }
BASEPS='    1     0  9000   2 t3             t3 serve --port 3773
  300     1  8000   5 claude         claude --dangerously-skip-permissions'
AMBIENT=(AGENT_UP_BUSY_SAMPLE=0)
printf '%s\n' "$BASEPS" | snap "$BC" 1; printf '%s\n' "$BASEPS" | snap "$BC" 2
bout="$(au busy "$NAME" 2>&1)" && rc=0 || rc=$?
check "busy: nothing running -> exit 0" test "$rc" -eq 0
check "  ...reports the idle agent" grep -qxF "IDLE: agent idle (claude)" <<<"$bout"
# Rscript execs into R in the rocker images: ps shows comm R with --file= or -e (no CPU growth needed).
RFILE='  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=/workspace/run.R --args --long'
{ printf '%s\n' "$BASEPS"; echo "$RFILE"; } | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo "$RFILE"; } | snap "$BC" 2
refuses "busy: Rscript file.R (comm R, --file=), no CPU growth -> BUSY" 'BUSY: Rscript /workspace/run.R --long \(running 2h1m\)' au busy "$NAME"
REXPR='  410   300   130   0 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore -e Sys.sleep(8)'
{ printf '%s\n' "$BASEPS"; echo "$REXPR"; } | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo "$REXPR"; } | snap "$BC" 2
refuses "busy: Rscript -e (comm R, -e), no CPU growth -> BUSY" 'BUSY: Rscript -e Sys.sleep\(8\) \(running 0h2m\)' au busy "$NAME"
{ printf '%s\n' "$BASEPS"; echo '  420   300  7300  60 Rscript       /usr/lib/R/bin/Rscript /workspace/old.R'; } | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo '  420   300  7300  60 Rscript       /usr/lib/R/bin/Rscript /workspace/old.R'; } | snap "$BC" 2
refuses "busy: comm Rscript -> BUSY (kept)" 'BUSY: Rscript /workspace/old.R \(running 2h1m\)' au busy "$NAME"
{ printf '%s\n' "$BASEPS"; echo '  500     1  100  100 R              /usr/local/lib/R/bin/exec/R --no-save'; } | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo '  500     1  103  103 R              /usr/local/lib/R/bin/exec/R --no-save'; } | snap "$BC" 2
refuses "busy: interactive R using CPU -> BUSY" 'BUSY: R using CPU' au busy "$NAME"
{ printf '%s\n' "$BASEPS"; echo '  500     1  100  100 R              /usr/local/lib/R/bin/exec/R --no-save'; } | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo '  500     1  103  100 R              /usr/local/lib/R/bin/exec/R --no-save'; } | snap "$BC" 2
bout="$(au busy "$NAME" 2>&1)" && rc=0 || rc=$?
check "busy: interactive R idle -> IDLE, exit 0" bash -c '[ "$1" -eq 0 ] && grep -qxF "IDLE: idle R session (R)" <<<"$2"' _ "$rc" "$bout"
{ printf '%s\n' "$BASEPS"; echo '  600     1  100   50 rsession       /usr/lib/rstudio-server/bin/rsession'; } | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo '  600     1  103   50 rsession       /usr/lib/rstudio-server/bin/rsession'; } | snap "$BC" 2
bout="$(au busy "$NAME" 2>&1)" && rc=0 || rc=$?
check "busy: idle rsession -> IDLE, exit 0" test "$rc" -eq 0
check "  ...says idle R session (rsession)" grep -qxF "IDLE: idle R session (rsession)" <<<"$bout"
printf '%s\n' "$BASEPS" | snap "$BC" 1
{ printf '%s\n' "$BASEPS"; echo '  700   300  5    0 bash           bash -c sleep 100'; } | snap "$BC" 2
refuses "busy: claude with a child -> BUSY" 'agent may be mid-task \(claude, pid 300\)' au busy "$NAME"
printf '%s\n' "$BASEPS" | snap "$BC" 1; printf '%s\n' "$BASEPS" | sed 's/ 5 claude/ 8 claude/' | snap "$BC" 2
refuses "busy: claude using CPU -> BUSY" 'agent may be mid-task' au busy "$NAME"
echo 0 > "$T/RUNNING"
bout="$(au busy "$NAME" 2>&1)" && rc=0 || rc=$?
check "busy: stopped container -> nothing, exit 0" test "$rc" -eq 0 -a -z "$bout"
rm -f "$T/RUNNING"
rm -f "$T/ps.$BC".*
refuses "busy: running container whose ps prints nothing -> BUSY (fail closed), exit 1" 'BUSY: cannot inspect processes \(docker exec ps failed\)' au busy "$NAME"
refuses "busy: unknown project" 'no config for' au busy nosuch
refuses "busy: no arguments prints usage" 'usage:' au busy

# busy --all / project_names: a private config root with three projects (+ one living in this clone)
BR="$T/busy-cfg"; mkdir -p "$BR"
for pn in pa pb pc; do mkdir -p "$BR/$pn"; printf 'PROJECT=%s\nPROJECT_DIR=%s\n' "$pn" "$T/elsewhere-$pn" > "$BR/$pn/project.conf"; done
AMBIENT=(AGENT_UP_BUSY_SAMPLE=0 AGENT_CONTAINERS_CONFIG="$BR")
{ printf '%s\n' "$BASEPS"; echo '  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=x.R'; } | snap pa-agent-1 1
{ printf '%s\n' "$BASEPS"; echo '  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=x.R'; } | snap pa-agent-1 2
printf '%s\n' "$BASEPS" | snap pb-agent-1 1; printf '%s\n' "$BASEPS" | snap pb-agent-1 2
echo 0 > "$T/RUNNING.pc-agent-1"
aout="$(au busy --all 2>&1)" && rc=0 || rc=$?
check "busy --all: exit 1 when one project is busy" test "$rc" -eq 1
check "  ...headers in project_names order, 'not running' for the stopped one" \
  test "$(grep -E '^(==|not running)' <<<"$aout" | tr '\n' '|')" = "== pa|== pb|== pc|not running|"
check "  ...last line names the busy project" test "$(tail -n 1 <<<"$aout")" = "Busy: pa"
check "  ...pb's idle agent is listed under its header" grep -qxF "IDLE: agent idle (claude)" <<<"$aout"
printf '%s\n' "$BASEPS" | snap pa-agent-1 1; printf '%s\n' "$BASEPS" | snap pa-agent-1 2
printf '%s\n' "$BASEPS" | snap pb-agent-1 1; printf '%s\n' "$BASEPS" | snap pb-agent-1 2
aout="$(au busy --all 2>&1)" && rc=0 || rc=$?
check "busy --all: all idle -> exit 0" test "$rc" -eq 0
check "  ...last line is 'Nothing busy.'" test "$(tail -n 1 <<<"$aout")" = "Nothing busy."
{ printf '%s\n' "$BASEPS"; echo '  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=x.R'; } | snap pa-agent-1 1
{ printf '%s\n' "$BASEPS"; echo '  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=x.R'; } | snap pa-agent-1 2
printf '%s\n' "$BASEPS" | snap pb-agent-1 1; printf '%s\n' "$BASEPS" | snap pb-agent-1 2
refuses "busy pa pb: several names behave like --all" '== pa' au busy pa pb
# A launcher clone fixture (a copy of agent-up with an ssh-form origin) and a startable project whose
# PROJECT_DIR is a SEPARATE clone of the same GitHub repo (https form, other case): it goes last.
LC="$T/lclone"; mkdir -p "$LC/bin" "$LC/images/base"; cp "$AU" "$LC/bin/agent-up"; cp -r "$ROOT/project-template" "$LC/"; cp -r "$ROOT/images/base/agent-clis" "$LC/images/base/"
git -C "$LC" init -q; git -C "$LC" remote add origin git@github.com:allenlarocque/Agent-Containers.git
SELFREPO="$T/selfrepo"; mkdir -p "$SELFREPO"; git -C "$SELFREPO" init -q; git -C "$SELFREPO" remote add origin https://github.com/AllenLarocque/agent-containers.git
auc(){ ( cd "$LC" && env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" OPLOG="$OPLOG" DLOG="$DLOG" PATH="$T/dstub:$T/bin:$PATH" "${AMBIENT[@]}" "$LC/bin/agent-up" "$@" ); }
mkdir -p "$BR/aa"; printf 'PROJECT=aa\nPROJECT_DIR=%s\n' "$SELFREPO" > "$BR/aa/project.conf"
mkdir -p "$BR/research"; printf 'PROJECT=research\nPROFILE=research\n' > "$BR/research/project.conf"   # empty PROJECT_DIR must not count as "here" (cwd is the clone)
NOTGIT="$T/notgit"; mkdir -p "$NOTGIT"; mkdir -p "$BR/ab"; printf 'PROJECT=ab\nPROJECT_DIR=%s\n' "$NOTGIT" > "$BR/ab/project.conf"
OTHERREPO="$T/otherrepo"; mkdir -p "$OTHERREPO"; git -C "$OTHERREPO" init -q; git -C "$OTHERREPO" remote add origin ssh://git@github.com/someone/else.git; mkdir -p "$BR/ac"; printf 'PROJECT=ac\nPROJECT_DIR=%s\n' "$OTHERREPO" > "$BR/ac/project.conf"
check "project_names: the project cloned from this repo goes last even when it sorts first (origin match; not-git, other-origin and empty PROJECT_DIR stay in order)" \
  test "$(auc busy --all 2>&1 | grep '^==' | tr '\n' ' ')" = "== ab == ac == pa == pb == pc == research == aa "
git -C "$LC" remote remove origin
check "project_names: a launcher clone without origin -> nothing goes last" \
  test "$(auc busy --all 2>&1 | grep '^==' | tr '\n' ' ')" = "== aa == ab == ac == pa == pb == pc == research "
git -C "$LC" remote add origin ssh://git@github.com/AllenLarocque/agent-containers.git
check "project_names: ssh:// origin form matches too" \
  test "$(auc busy --all 2>&1 | grep '^==' | tr '\n' ' ')" = "== ab == ac == pa == pb == pc == research == aa "
rm -f "$T/RUNNING.pc-agent-1"; AMBIENT=()

# ---- update: agent-up update --all | <project>... (owner-run; moves projects to the digests in digests.md)
UR="$T/upd-cfg"; mkdir -p "$UR"
OLD1=$(printf '1%.0s' $(seq 64))
GISD=$(printf 'c%.0s' $(seq 64)); BASED=$(printf 'b%.0s' $(seq 64))
cat > "$T/digests.md" <<DIGESTS
# Image digests

| image | tag | digest |
|---|---|---|
| spades-base | 2026.10.17-x | \`sha256:$BASED\` |
| spades-gis | 2026.10.17-x | \`sha256:$GISD\` |
DIGESTS
uenv(){ AMBIENT=(AGENT_UP_BUSY_SAMPLE=0 AGENT_CONTAINERS_CONFIG="$UR" AGENT_UP_DIGESTS="$T/digests.md" AGENT_UP_SKIP_GIT_CHECK=1); }
ucfg(){ echo "$UR/$1/compose.yaml"; }
uset(){ # $1 project, $2 image path, $3 digest hex: rewrite the compose image line
  sed -i -E "s|^( *image: *).*|\1$2@sha256:$3|" "$(ucfg "$1")"; }
uidle(){ printf '%s\n' "$BASEPS" | snap "$1-agent-1" 1; printf '%s\n' "$BASEPS" | snap "$1-agent-1" 2; }
ubusy(){ { printf '%s\n' "$BASEPS"; echo '  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=x.R'; } | snap "$1-agent-1" 1
         { printf '%s\n' "$BASEPS"; echo '  400   300  7300  60 R              /usr/local/lib/R/bin/exec/R --no-save --no-restore --no-echo --no-restore --file=x.R'; } | snap "$1-agent-1" 2; }
uup(){ grep -cE "^ARGS: compose .* -p $1 up -d" "$DLOG" || true; }
ureset(){ for pn in "$@"; do uset "$pn" ghcr.io/allenlarocque/spades-gis "$OLD1"; uidle "$pn"; done; : > "$DLOG"; : > "$OPLOG"; }
uenv
for pn in alpha beta; do
  mkdir -p "$T/upd-$pn"; au init "$T/upd-$pn" --name "$pn" >/dev/null
done
au init --profile research --image base >/dev/null
ureset alpha beta; uset research ghcr.io/allenlarocque/spades-base "$OLD1"; uidle research
rm -f "$T"/RUNNING*
uout="$(au update --all </dev/null 2>&1)" && rc=0 || rc=$?
check "update --all: exit 0 when all three updated" test "$rc" -eq 0
check "  ...builders' compose digest rewritten" bash -c 'grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:$2" "$1/alpha/compose.yaml" && grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:$2" "$1/beta/compose.yaml"' _ "$UR" "$GISD"
check "  ...research digest rewritten (spades-base)" grep -qx "    image: ghcr.io/allenlarocque/spades-base@sha256:$BASED" "$(ucfg research)"
check "  ...compose.yaml keeps its mode (600)" test "$(stat -c %a "$(ucfg alpha)")" = 600
check "  ...an up call per project" test "$(uup alpha)$(uup beta)$(uup research)" = 111
check "  ...builder up got the token only in its environment (OPTOK: sat-alpha)" \
  bash -c 'grep -A2 -E "^ARGS: compose .* -p alpha up -d" "$1" | grep -qx "OPTOK: sat-alpha"' _ "$DLOG"
check "  ...and sat-beta for beta" bash -c 'grep -A2 -E "^ARGS: compose .* -p beta up -d" "$1" | grep -qx "OPTOK: sat-beta"' _ "$DLOG"
check "  ...research up got no token (<unset>)" bash -c 'grep -A2 -E "^ARGS: compose .* -p research up -d" "$1" | grep -qx "OPTOK: <unset>"' _ "$DLOG"
check "  ...the token never appears in a docker ARGS line" bash -c '! grep -E "^ARGS:.*sat-" "$1"' _ "$DLOG"
check "  ...nor in the update output" bash -c '! grep -q "sat-" <<<"$1"' _ "$uout"
check "  ...summary lists versions (t3 0.9.9)" grep -q "0.9.9" <<<"$uout"
check "  ...ends with the phone/desktop reminder" test "$(tail -n 1 <<<"$uout")" = "Now update the T3 apps on your phone and desktop (and turn their auto-update back off if an update turned it on)."
check "  ...no marker on the old containers: 'unknown' heading printed" \
  grep -qxF "Can't tell whether these need re-pairing (no protocol marker on the old container); if the app still connects, ignore:" <<<"$uout"
check "  ...lists the idle sessions of a project it restarts (IDLE: agent idle (claude))" grep -qxF "IDLE: agent idle (claude)" <<<"$uout"

# order: a startable project whose PROJECT_DIR is another clone of this repo goes last; research (empty PROJECT_DIR) does not
mkdir -p "$T/upd-zz"; au init "$T/upd-zz" --name aaa-self >/dev/null
sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=$SELFREPO|" "$UR/aaa-self/project.conf"
ureset alpha beta aaa-self research; uset research ghcr.io/allenlarocque/spades-base "$OLD1"
uout="$(auc update --all </dev/null 2>&1)" && rc=0 || rc=$?
check "update --all: the project cloned from this repo runs last, and its up succeeds (research is not mistaken for it)" \
  test "$rc" -eq 0 -a "$(grep -oE '^agent-up: [a-z-]+: (updated|FAILED)' <<<"$uout" | awk '{print $2}' | tr '\n' ' ')" = "alpha: beta: research: aaa-self: "
rm -rf "$UR/aaa-self"

# already current / stopped
: > "$DLOG"
uset alpha ghcr.io/allenlarocque/spades-gis "$GISD"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: already-current project -> 'current', exit 0, no up" bash -c '[ "$1" -eq 0 ] && grep -q "current" <<<"$2" && [ "$3" -eq 0 ]' _ "$rc" "$uout" "$(uup alpha)"
check "  ...nothing to re-pair: 'No re-pairing needed.'" grep -qxF "No re-pairing needed." <<<"$uout"
check "  ...ends with the phone/desktop reminder" test "$(tail -n 1 <<<"$uout")" = "Now update the T3 apps on your phone and desktop (and turn their auto-update back off if an update turned it on)."
ureset alpha
echo 0 > "$T/RUNNING.alpha-agent-1"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: stopped project -> digest rewritten, 'updated, not started'" bash -c '[ "$1" -eq 0 ] && grep -q "updated, not started" <<<"$2" && grep -q "sha256:$3" "$4"' _ "$rc" "$uout" "$GISD" "$(ucfg alpha)"
check "  ...no up, and no token read" bash -c '[ "$(grep -c " up -d" "$1")" -eq 0 ] && ! grep -q "^OP: read" "$2"' _ "$DLOG" "$OPLOG"
check "  ...'updated, not started' still ends with the phone/desktop reminder" test "$(tail -n 1 <<<"$uout")" = "Now update the T3 apps on your phone and desktop (and turn their auto-update back off if an update turned it on)."
# rewrite_digest: only the image line the digest was read from changes
ureset alpha; printf '  sidecar:\n    image: ghcr.io/allenlarocque/spades-gis@sha256:%s\n' "$OLD1" >> "$(ucfg alpha)"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: only the first pinned image: line is rewritten (a later one keeps its digest)" \
  bash -c '[ "$(grep -c "@sha256:$2" "$1")" -eq 1 ] && [ "$(grep -c "@sha256:$3" "$1")" -eq 1 ] && [ "$(tail -n 1 "$1")" = "    image: ghcr.io/allenlarocque/spades-gis@sha256:$3" ]' _ "$(ucfg alpha)" "$GISD" "$OLD1"
sed -i '/^  sidecar:$/,$d' "$(ucfg alpha)"
rm -f "$T/RUNNING.alpha-agent-1"

# busy: skip on EOF, restart on 'r', quit on 'q'
ureset alpha beta; ubusy alpha
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: busy project with EOF on stdin -> skipped, exit 0" bash -c '[ "$1" -eq 0 ] && grep -q "BUSY: Rscript" <<<"$2" && grep -q "skipped" <<<"$2"' _ "$rc" "$uout"
check "  ...last line warns: still on the old image, finish with agent-up update alpha first" \
  bash -c 'l="$(tail -n 1 <<<"$1")"; [[ $l == WARNING:* ]] && grep -qF "alpha" <<<"$l" && grep -qF "still on the old image" <<<"$l" && grep -qF "may disconnect" <<<"$l" && grep -qF "agent-up update alpha" <<<"$l"' _ "$uout"
check "  ...and no 'Now update the T3 apps' line" bash -c '! grep -qF "Now update the T3 apps" <<<"$1"' _ "$uout"
check "  ...compose unchanged, no up" bash -c 'grep -q "sha256:$2" "$1" && [ "$3" -eq 0 ]' _ "$(ucfg alpha)" "$OLD1" "$(uup alpha)"
uout="$(printf 'r\n' | au update alpha 2>&1)" && rc=0 || rc=$?
check "update: busy project, answer r -> restarted (digest rewritten, up called)" bash -c '[ "$1" -eq 0 ] && grep -q "sha256:$2" "$3" && [ "$4" -eq 1 ]' _ "$rc" "$GISD" "$(ucfg alpha)" "$(uup alpha)"
ureset alpha beta; ubusy alpha
uout="$(printf 'q\n' | au update alpha beta 2>&1)" && rc=0 || rc=$?
check "update: answer q stops the run (beta untouched), summary still printed" bash -c '[ "$1" -eq 0 ] && grep -q "sha256:$2" "$3" && grep -q "^project" <<<"$4"' _ "$rc" "$OLD1" "$(ucfg beta)" "$uout"

# token unreadable / up failure
touch "$T/OPREAD_FAIL_alpha"; ureset alpha beta
uout="$(au update alpha beta </dev/null 2>&1)" && rc=0 || rc=$?
check "update: token unreadable -> NOT UPDATED, exit non-zero" bash -c '[ "$1" -ne 0 ] && grep -qF "NOT UPDATED (could not read op://Personal/agent-alpha service account/credential; run: agent-up up alpha)" <<<"$2"' _ "$rc" "$uout"
check "  ...the warning names only the project left behind (alpha, not beta)" \
  bash -c 'l="$(tail -n 1 <<<"$1")"; [[ $l == WARNING:* ]] && grep -qF "agent-up update alpha" <<<"$l" && ! grep -qF "beta" <<<"$l"' _ "$uout"
check "  ...compose unchanged, no up for it; the other project updated" bash -c 'grep -q "sha256:$2" "$1" && [ "$3" -eq 0 ] && grep -q "sha256:$4" "$5" && [ "$6" -eq 1 ]' _ "$(ucfg alpha)" "$OLD1" "$(uup alpha)" "$GISD" "$(ucfg beta)" "$(uup beta)"
rm -f "$T/OPREAD_FAIL_alpha"
touch "$T/UPFAIL.alpha"; ureset alpha beta
uout="$(au update alpha beta </dev/null 2>&1)" && rc=0 || rc=$?
check "update: a failing up -> FAILED, exit non-zero" bash -c '[ "$1" -ne 0 ] && grep -qF "FAILED (compose already on the new digest; fix, then: agent-up up alpha; logs: docker logs alpha-agent-1)" <<<"$2"' _ "$rc" "$uout"
check "  ...the later project is still updated" bash -c 'grep -q "sha256:$2" "$1"' _ "$(ucfg beta)" "$GISD"
rm -f "$T/UPFAIL.alpha"

# re-pair markers: unknown (old empty, new 2), yes (1 -> 2), no (2 -> 2)
ureset alpha beta; rm -f "$T"/proto.* "$T/pair.count"; echo 2 > "$T/proto.alpha-agent-1.new"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: old container without marker, new with 2 -> 'unknown' heading and pairing code" bash -c 'grep -qF "Can'"'"'t tell whether these need re-pairing" <<<"$1" && grep -qF "pairing code: fakeTok_123" <<<"$1"' _ "$uout"
ureset alpha beta; rm -f "$T"/proto.* "$T/pair.count"
echo 1 > "$T/proto.alpha-agent-1"; echo 2 > "$T/proto.alpha-agent-1.new"; echo 2 > "$T/proto.beta-agent-1"; echo 2 > "$T/proto.beta-agent-1.new"
uout="$(au update alpha beta </dev/null 2>&1)" && rc=0 || rc=$?
check "update: marker 1 -> 2 pairs alpha ('yes'); 2 -> 2 does not pair beta" bash -c 'grep -qF "T3 Code for '"'"'alpha'"'"'" <<<"$1" && ! grep -qF "T3 Code for '"'"'beta'"'"'" <<<"$1" && [ "$(grep -c "agent-t3 pair" "$2")" -eq 1 ]' _ "$uout" "$DLOG"
check "  ...no 'Can't tell' heading when nothing is unknown" bash -c '! grep -qF "Can'"'"'t tell" <<<"$1"' _ "$uout"
rm -f "$T"/proto.* "$T/pair.count"

# versions: the CLIs install at container start; poll (bounded by AGENT_UP_PAIR_WAIT), then say "installing"
mkdir -p "$T/fastsleep"; printf '#!/bin/sh\nexit 0\n' > "$T/fastsleep/sleep"; chmod +x "$T/fastsleep/sleep"
uenv; AMBIENT+=(AGENT_UP_PAIR_WAIT=10 PATH="$T/fastsleep:$T/dstub:$T/bin:$PATH")
ureset alpha; echo 2 > "$T/CLI_FAILS"; rm -f "$T/cli.count"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: CLIs missing right after up, present after a wait -> real versions in the summary" \
  bash -c '[ "$1" -eq 0 ] && grep -qF "Claude Code: 9.9.9" <<<"$2" && grep -qF "Codex: codex-cli 8.8.8" <<<"$2" && ! grep -qE "MISSING|installing" <<<"$2" && [ "$(grep -c " claude --version" "$3")" -ge 3 ]' _ "$rc" "$uout" "$DLOG"
ureset alpha; echo 100000 > "$T/CLI_FAILS"; rm -f "$T/cli.count"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: CLIs still missing when the wait expires -> 'installing (check later: agent-up status alpha)', never MISSING" \
  bash -c '[ "$1" -eq 0 ] && grep -qF "Claude Code: installing (check later: agent-up status alpha)" <<<"$2" && grep -qF "Codex: installing (check later: agent-up status alpha)" <<<"$2" && ! grep -qF "MISSING" <<<"$2"' _ "$rc" "$uout"
rm -f "$T/CLI_FAILS" "$T/cli.count"; uenv

# an image not in digests.md
ureset alpha; uset alpha ghcr.io/x/custom "$OLD1"; cp "$(ucfg alpha)" "$T/alpha.compose.before"
uout="$(au update alpha </dev/null 2>&1)" && rc=0 || rc=$?
check "update: image not in digests.md -> SKIP (image custom not in digests.md), non-zero, file unchanged" \
  bash -c '[ "$1" -ne 0 ] && grep -qF "SKIP (image custom not in digests.md)" <<<"$2" && cmp -s "$3" "$4" && [ "$5" -eq 0 ]' _ "$rc" "$uout" "$(ucfg alpha)" "$T/alpha.compose.before" "$(uup alpha)"
refuses "update: unknown project" 'no config for' au update nosuch
refuses "update: no arguments prints usage" 'usage:' au update

# the git guard: a clone not on main is refused (the test-only override is off)
GC="$T/gitclone"; mkdir -p "$GC/bin" "$GC/project-template"; cp "$AU" "$GC/bin/agent-up"; git -C "$GC" init -q -b side; git -C "$GC" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
refuses "update: refuses when the clone is not on main" "pull main in .* first: digests.md is not current" \
  env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" PATH="$T/dstub:$T/bin:$PATH" AGENT_CONTAINERS_CONFIG="$UR" AGENT_UP_DIGESTS="$T/digests.md" "$GC/bin/agent-up" update --all
# the fetch never prompts for credentials (GIT_TERMINAL_PROMPT=0): a failing fetch takes the warning path
git -C "$GC" branch -q -m side main
REALGIT="$(command -v git)"; mkdir -p "$T/gitstub"
printf '#!/bin/sh\ncase " $* " in *" fetch "*) echo "GTP=${GIT_TERMINAL_PROMPT-<unset>}" >> "%s"; exit 128 ;; esac\nexec "%s" "$@"\n' "$T/git.log" "$REALGIT" > "$T/gitstub/git"; chmod +x "$T/gitstub/git"
uset alpha ghcr.io/allenlarocque/spades-gis "$GISD"; rm -f "$T/git.log"
gout="$(env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" OPLOG="$OPLOG" DLOG="$DLOG" PATH="$T/gitstub:$T/dstub:$T/bin:$PATH" AGENT_UP_BUSY_SAMPLE=0 AGENT_CONTAINERS_CONFIG="$UR" AGENT_UP_DIGESTS="$T/digests.md" "$GC/bin/agent-up" update alpha </dev/null 2>&1)" || true
check "update: git fetch runs with GIT_TERMINAL_PROMPT=0; its failure is a warning" \
  bash -c 'grep -qx "GTP=0" "$1" && grep -qF "WARNING: could not fetch origin main" <<<"$2"' _ "$T/git.log" "$gout"

# pair: the default wait is 180 s (the first start after an image update installs the CLIs)
AMBIENT=(); mkdir -p "$T/fastsleep"; printf '#!/bin/sh\nexit 0\n' > "$T/fastsleep/sleep"; chmod +x "$T/fastsleep/sleep"
echo 1000 > "$T/PAIR_FAILS"; rm -f "$T/pair.count"
refuses "pair: default wait is 180 s" "did not answer within 180 s" env -u OP_SERVICE_ACCOUNT_TOKEN HOME="$H" OPLOG="$OPLOG" DLOG="$DLOG" PATH="$T/fastsleep:$T/dstub:$T/bin:$PATH" "$AU" pair "$NAME"
rm -f "$T/PAIR_FAILS" "$T/pair.count"

check "Dockerfile sets an integer T3_PROTOCOL" grep -Eq '^ENV T3_PROTOCOL=[0-9]+$' "$ROOT/images/base/Dockerfile"

# ---- END OF SECTIONS (later tasks insert above this line)
[ "$fail" -eq 0 ] && echo "LAUNCHER: ALL PASSED" || { echo "LAUNCHER: FAILURES"; exit 1; }
