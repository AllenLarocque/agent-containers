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
