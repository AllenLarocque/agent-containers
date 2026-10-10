#!/usr/bin/env bash
# T3 Code server inside the container (spec §13.1). One container = one T3 environment.
#   agent-t3 start          start `t3 serve` in the background (idempotent)
#   agent-t3 pair [LABEL]   mint a one-time pairing token (10 min) and print it as token=<...>
# The server listens on container port 3773; compose publishes it on the HOST's loopback only
# (127.0.0.1:<T3_PORT>), and the firewall accepts it only from the container's gateway (the host).
set -uo pipefail
log(){ printf '[agent-t3] %s\n' "$*"; }
BASE="${T3_BASE_DIR:-$HOME/.t3}"
PORT=3773
PROJECT_DIR="${T3_PROJECT_DIR:-/workspace}"   # T3's project: builders /workspace; the research container sets /research

case "${1:-}" in
  start)
    mkdir -p "$BASE" || { log "WARN cannot create $BASE"; exit 0; }
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null; then
      log "already running on :$PORT"; exit 0
    fi
    # Telemetry off (also set in the image ENV); the PostHog host is not allowlisted anyway.
    T3CODE_TELEMETRY_ENABLED=false setsid nohup t3 serve --host 0.0.0.0 --port "$PORT" --base-dir "$BASE" \
      --auto-bootstrap-project-from-cwd "$PROJECT_DIR" >>"$BASE/serve.log" 2>&1 </dev/null &
    for _ in $(seq 1 30); do
      curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null && { log "server up on :$PORT (log: $BASE/serve.log)"; exit 0; }
      sleep 1
    done
    log "WARN server did not answer on :$PORT within 30 s (see $BASE/serve.log)"
    exit 0 ;;
  pair)
    out=$(T3CODE_TELEMETRY_ENABLED=false t3 pair --base-dir "$BASE" --ttl 10m --label "${2:-agent-up}" 2>&1) \
      || { log "ERROR t3 pair failed:"; printf '%s\n' "$out" >&2; exit 1; }
    # The exact field t3 prints: "Pairing URL: http://<host>:<port>/pair#token=<token>"
    tok=$(sed -n 's|^Pairing URL: [^ ]*/pair#\(token=[^[:space:]]*\)$|\1|p' <<<"$out" | head -n 1)
    [[ $tok =~ ^token=[A-Za-z0-9._~%-]+$ ]] || { log "ERROR no well-formed pairing token in t3 pair output"; exit 1; }
    echo "$tok" ;;
  *) echo "usage: agent-t3 start | pair [LABEL]" >&2; exit 2 ;;
esac
