#!/usr/bin/env bash
# T3 Code server inside the container (spec §13.1). One container = one T3 environment.
#   agent-t3 start          start `t3 serve` in the background (idempotent) and add the missing T3 projects
#   agent-t3 projects       list T3's projects; flag those outside this container's project folders (read-only)
#   agent-t3 pair [LABEL]   mint a one-time pairing token (10 min) and print it as token=<...>
# The server listens on container port 3773; compose publishes it on the HOST's loopback only
# (127.0.0.1:<T3_PORT>), and the firewall accepts it only from the container's gateway (the host).
set -uo pipefail
log(){ printf '[agent-t3] %s\n' "$*"; }
BASE="${T3_BASE_DIR:-$HOME/.t3}"
PORT=3773
WS="${T3_WORKSPACE:-/workspace}"              # the mounted project folder (T3_WORKSPACE: tests only)
PROJECT_DIR="${T3_PROJECT_DIR:-$WS}"          # T3's start folder: builders /workspace; research sets /research/_general

# A T3 project is only a title + a folder; the app's folder picker starts in $HOME and makes it easy to
# pick a folder that is not mounted (wiped at the next `agent-up up`). So the container adds its own:
#   research (T3_PROJECT_DIR set)        that folder
#   /workspace is a git repo             /workspace
#   /workspace is a folder of git repos  each repo (one T3 project per repo; all share this container)
#   neither                              /workspace
project_roots(){
  if [ -n "${T3_PROJECT_DIR:-}" ]; then printf '%s\n' "$T3_PROJECT_DIR"; return; fi
  if [ -e "$WS/.git" ]; then printf '%s\n' "$WS"; return; fi
  local d any=0
  for d in "$WS"/*/; do
    d="${d%/}"; [ -e "$d/.git" ] && [ ! -L "$d" ] || continue
    printf '%s\n' "$d"; any=1
  done
  [ "$any" = 1 ] || printf '%s\n' "$WS"
}
# Add each missing project. T3 refuses a second live project for the same folder
# (ProjectAlreadyExistsError), so repeating this is safe. Nothing is ever removed here: removing a
# project deletes its threads, which stays the owner's decision.
sync_projects(){
  local root out title
  while IFS= read -r root; do
    [ -d "$root" ] || { log "WARN T3 project folder $root does not exist"; continue; }
    title=(); [ "$root" != "$PROJECT_DIR" ] || title=(--title "$(hostname)")   # a sub-repo keeps T3's default: its folder name
    if out=$(T3CODE_TELEMETRY_ENABLED=false t3 project add --base-dir "$BASE" "${title[@]}" "$root" 2>&1); then
      log "added T3 project $root"
    elif ! grep -q 'ProjectAlreadyExistsError' <<<"$out"; then
      log "WARN could not add T3 project $root: $(grep -m1 'ERROR' <<<"$out" || tail -n 1 <<<"$out")"
    fi
  done < <(project_roots)
}
persistent_base(){ # T3 projects belong inside this folder: everything else is wiped by `agent-up up`
  if [ -n "${T3_PROJECT_DIR:-}" ]; then dirname "$T3_PROJECT_DIR"; else printf '%s\n' "$WS"; fi
}

case "${1:-}" in
  start)
    mkdir -p "$BASE" || { log "WARN cannot create $BASE"; exit 0; }
    if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null; then
      log "already running on :$PORT"; sync_projects; exit 0
    fi
    # Telemetry off (also set in the image ENV); the PostHog host is not allowlisted anyway.
    T3CODE_TELEMETRY_ENABLED=false setsid nohup t3 serve --host 0.0.0.0 --port "$PORT" --base-dir "$BASE" \
      "$PROJECT_DIR" >>"$BASE/serve.log" 2>&1 </dev/null &
    for _ in $(seq 1 30); do
      curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null && { log "server up on :$PORT (log: $BASE/serve.log)"; sync_projects; exit 0; }
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
  projects)
    base="$(persistent_base)"
    live="$(node --no-warnings /usr/local/lib/agent/t3-projects.js 2>/dev/null)" \
      || { echo "T3 projects: could not read T3's project list"; exit 0; }
    while IFS=$'\t' read -r root title; do
      [ -n "$root" ] || continue
      case "$root/" in
        "$base"/*) echo "T3 project: $root ($title)" ;;
        *) echo "T3 project OUTSIDE $base: $root ($title). Files there are lost at the next 'agent-up up'. Remove it in T3, or: t3 project remove --force '$root' (deletes its threads)" ;;
      esac
    done <<<"$live"
    while IFS= read -r root; do
      awk -F'\t' -v r="$root" '$1 == r {f=1} END {exit !f}' <<<"$live" || echo "T3 project MISSING: $root (add it: agent-t3 start)"
    done < <(project_roots) ;;
  *) echo "usage: agent-t3 start | projects | pair [LABEL]" >&2; exit 2 ;;
esac
