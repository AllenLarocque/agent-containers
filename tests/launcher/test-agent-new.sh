#!/usr/bin/env bash
# Tests for bin/agent-new (docs/specs/2026-10-15-agent-new-design.md). No real gh/op/git/docker:
# all are stubs on PATH that log how they were called and replay canned responses from $STATE.
set -uo pipefail
# hermetic: the stubs assume the caller is not already authenticated as anyone
unset GH_TOKEN GITHUB_TOKEN OP_SERVICE_ACCOUNT_TOKEN
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AN="$ROOT/bin/agent-new"
fail=0
check(){ local d="$1" o; shift
  if o=$("$@" 2>&1); then echo "OK:   $d"; else echo "FAIL: $d"; printf '%s\n' "$o" | sed 's/^/        /'; annotate "$d"; fail=1; fi; }
refuses(){ local d="$1" re="$2" rc=0 msg; shift 2
  msg=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq -- "$re" <<<"$msg"; then echo "OK:   $d"
  else echo "FAIL: $d (rc=$rc, want non-zero and /$re/)"; printf '%s\n' "$msg" | sed 's/^/        /'; annotate "$d"; fail=1; fi; }
annotate(){ [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=agent-new test::FAIL: $1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/home"; CFGROOT="$H/.config/agent-containers"; STATE="$T/state"
mkdir -p "$H" "$CFGROOT" "$STATE" "$T/bin"
GHLOG="$T/gh.log" OPLOG="$T/op.log" GITLOG="$T/git.log" DLOG="$T/docker.log" AULOG="$T/agent-up.log" TSLOG="$T/ts.log"
export STATE GHLOG OPLOG GITLOG DLOG AULOG TSLOG
newstate(){ rm -rf "$STATE"; mkdir -p "$STATE"; : > "$GHLOG"; : > "$OPLOG"; : > "$GITLOG"; : > "$DLOG"; : > "$AULOG"; : > "$TSLOG"
  echo allen > "$STATE/login"; }

# ---- stub gh: logs every call; behavior driven by $STATE files (grown in later tasks)
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "GH${GH_TOKEN:+(mu)}: $*" >> "$GHLOG"
case "$*" in
  "api user --jq .login") [ -s "$STATE/login" ] || exit 1; cat "$STATE/login" ;;
  api\ repos/*/collaborators/*) [ -f "$STATE/collab" ] ;;
  api\ -X\ PUT\ repos/*/collaborators/*) touch "$STATE/invited" ;;
  "api /user/repository_invitations --jq"*) [ -n "${GH_TOKEN:-}" ] || exit 1; [ -f "$STATE/invited" ] && echo 42 ;;
  "api -X PATCH /user/repository_invitations/42") [ -n "${GH_TOKEN:-}" ] || exit 1; touch "$STATE/collab" ;;
  "api repos/"*"/rulesets --jq"*) cat "$STATE/ruleset-id" 2>/dev/null; : ;;
  "api -X POST repos/"*"/rulesets --input -") cat > "$STATE/ruleset-posted" ;;
  "api repos/"*"/rulesets/7 --jq"*) cat "$STATE/ruleset-norm" ;;
  "api repos/"*"/contents/.github/CODEOWNERS") [ -f "$STATE/has-codeowners" ] ;;
  "api repos/"*"/contents/.github/workflows/gitleaks.yml") [ -f "$STATE/has-gitleaks" ] ;;
  "api repos/"*"/actions/permissions/workflow --jq .can_approve_pull_request_reviews") cat "$STATE/actions-approve" 2>/dev/null || echo false ;;
  "repo view "*) [ -f "$STATE/repo-exists" ] ;;
  "repo create "*)
    touch "$STATE/repo-exists"; mkdir -p "$STATE/created"
    d="$(basename "$3")"
    mkdir -p "$d" && (cd "$d" && "$REALGIT" init -q -b main && "$REALGIT" commit -q --allow-empty -m seed && "$REALGIT" remote add origin "https://github.com/$3")
    ;;
  "repo clone "*) mkdir -p "${*: -1}" ;;
  *) exit 0 ;;
esac
STUB
# ---- stub op: logs; grows state (vault/service-account/item) for project steps
cat > "$T/bin/op" <<'STUB'
#!/usr/bin/env bash
echo "OP${OP_SERVICE_ACCOUNT_TOKEN:+(sa)}: $*" >> "$OPLOG"
case "$1 ${2:-}" in
  "signin ")            echo ":" ;;
  "vault get")          [ -f "$STATE/vault" ] ;;
  "vault create")       touch "$STATE/vault" ;;
  "vault list")
    printf 'ID    NAME\n'
    [ -f "$STATE/sa-vault" ] && printf 'v1    %s\n' "$(cat "$STATE/sa-vault")"
    [ -f "$STATE/vault-list-extra" ] && printf 'v2    %s\n' "$(cat "$STATE/vault-list-extra")"
    ;;
  "service-account create") echo "$3" > "$STATE/sa-vault"; echo fake-sa-token ;;
  "item get")           [ -f "$STATE/item-$3" ] ;;
  "item create")        for a in "$@"; do case "$a" in --title) want=next ;; *) [ "${want:-}" = next ] && { touch "$STATE/item-$a"; want=; } ;; esac; done; true ;;
  "read "*)             echo fake-op-secret ;;
esac
STUB
chmod +x "$T/bin/gh" "$T/bin/op"
# ---- stub docker: logs; exec plan driven by $STATE/exec-plan
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "DOCKER: $*" >> "$DLOG"
if [ "$1" = ps ]; then printf 'p1-agent-1\nnewproj-agent-1\n'; exit 0; fi
# docker exec -w /workspace <name> bash -lc CMD
cmd="${@: -1}"
while IFS='|' read -r marker rc out; do
  case "$cmd" in *"$marker"*) printf '%s\n' "$out"; exit "$rc" ;; esac
done < "$STATE/exec-plan"
exit 0
STUB
chmod +x "$T/bin/docker"
# ---- stub git: intercepts clone/push (log + simulate); everything else -> real git
REALGIT="$(command -v git)"; export REALGIT
# the sandboxed $H has no git identity configured; give the stub's seed commits one
export GIT_AUTHOR_NAME=agent-new-test GIT_AUTHOR_EMAIL=agent-new-test@example.com
export GIT_COMMITTER_NAME=agent-new-test GIT_COMMITTER_EMAIL=agent-new-test@example.com
cat > "$T/bin/git" <<'STUB'
#!/usr/bin/env bash
echo "GIT: $*" >> "$GITLOG"
case "$1" in
  clone) mkdir -p "${@: -1}"; cd "${@: -1}" && "$REALGIT" init -q -b main && "$REALGIT" commit -q --allow-empty -m seed && "$REALGIT" remote add origin "https://github.com/x/y" ;;
  push)  exit 0 ;;
  *)     exec "$REALGIT" "$@" ;;
esac
STUB
# ---- stub agent-up: logs; mimics `init` by materializing the config dir from fixtures
cat > "$T/bin/agent-up" <<'STUB'
#!/usr/bin/env bash
echo "AU${OP_SERVICE_ACCOUNT_TOKEN:+(tok)}: $*" >> "$AULOG"
if [ "$1" = init ]; then
  p="$(basename "$2" | tr 'A-Z' 'a-z')"
  mkdir -p "$AGENT_CONTAINERS_CONFIG/$p" "$2/.github/workflows"
  printf 'image: ghcr.io/x/spades-gis@sha256:REPLACE_WITH_DIGEST_FROM_digests.md\n' > "$AGENT_CONTAINERS_CONFIG/$p/compose.yaml"
  printf 'PROJECT=%s\nT3_PORT=3778\nT3_CONNECT=0\nRESEARCH=0\n' "$p" > "$AGENT_CONTAINERS_CONFIG/$p/project.conf"
  printf '* @OWNER\n' > "$2/.github/CODEOWNERS"
  touch "$2/.github/workflows/gitleaks.yml" "$2/.gitignore"
fi
STUB
chmod +x "$T/bin/git" "$T/bin/agent-up"
# ---- stub tailscale.exe: logs; serve status replayed from $STATE/ts-status
cat > "$T/bin/tailscale.exe" <<'STUB'
#!/usr/bin/env bash
echo "TS: $*" >> "$TSLOG"
case "$1" in
  serve) if [ "$2" = status ]; then cat "$STATE/ts-status" 2>/dev/null; else touch "$STATE/ts-served"
    [ -e "$STATE/ts-frozen" ] || printf 'https://host:%s (tailnet only)\n|-- / proxy http://127.0.0.1:%s\n' "${2#--https=}" "$4" >> "$STATE/ts-status"; fi ;;
esac
STUB
chmod +x "$T/bin/tailscale.exe"
mkdir -p "$T/repo-root"
printf '| image | tag | digest |\n|---|---|---|\n| spades-gis | 2026.10.12 | `sha256:aaa111` |\n| spades-bio | 2026.10.12 | `sha256:bbb222` |\n' > "$T/repo-root/digests.md"
run(){ HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" "$AN" "$@"; }

echo "== task 1: CLI and preflight =="
newstate
refuses "no args -> usage" 'usage' run
refuses "unknown subcommand -> usage" 'usage' run frobnicate
refuses "protect without owner/repo" 'protect wants <owner>/<repo>' run protect lonely
refuses "no MACHINE_USER anywhere" 'MACHINE_USER' run protect o/r
OUT=$(run protect o/r 2>&1) && { echo "FAIL: no-machine-user run should exit non-zero"; fail=1; } || true
check "  dies at the guard (nothing after runs)" bash -c "! grep -q 'not implemented' <<<\"\$0\"" "$OUT"
printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
newstate; echo agent-allen > "$STATE/login"
refuses "gh logged in as the machine user" 'machine user' run protect o/r
newstate; : > "$STATE/login"
refuses "gh not logged in" 'not logged in' run protect o/r

echo "== task 2: protect / collaborator =="
newstate
check "fresh: invite + accept as machine user" run protect allen/repo1 --vault agent-p1
check "  invite was PUT as owner"            grep -q '^GH: api -X PUT repos/allen/repo1/collaborators/agent-allen' "$GHLOG"
check "  accept listed+patched AS machine user" grep -q '^GH(mu): api -X PATCH /user/repository_invitations/42' "$GHLOG"
check "  token came from the project vault"  grep -q '^OP: read op://agent-p1/github-agent/token' "$OPLOG"
newstate; touch "$STATE/collab"
check "re-run: collaborator -> SKIP"         run protect allen/repo1 --vault agent-p1
check "  no second invite"                   test ! -f "$STATE/invited"
newstate
OUT=$(run protect allen/repo2 2>&1)
check "no --vault: invite happens"           test -f "$STATE/invited"
check "no --vault: WARNING to accept manually" grep -q 'WARNING.*accept the invitation' <<<"$OUT"

echo "== task 3: protect / ruleset + warnings =="
EXPECT_NORM='active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:true|gitleaks|refs:~DEFAULT_BRANCH/|strict:false|merge,rebase,squash'
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
check "no ruleset: POSTs one"              run protect allen/repo1 --vault agent-p1
check "  posted JSON names protect-main"   grep -q '"name": *"protect-main"' "$STATE/ruleset-posted"
check "  bypass: admin, PRs only"          grep -q '"bypass_mode": *"pull_request"' "$STATE/ruleset-posted"
check "  required check gitleaks"          grep -q '"context": *"gitleaks"' "$STATE/ruleset-posted"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm"
check "identical ruleset -> SKIP"          run protect allen/repo1 --vault agent-p1
check "  nothing POSTed"                   test ! -f "$STATE/ruleset-posted"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id"; echo 'active|RepositoryRole:5:always|deletion|pr:0:false:false:false|' > "$STATE/ruleset-norm"
refuses "divergent ruleset -> refuse, no write" 'refusing to modify' run protect allen/repo1 --vault agent-p1
check "  nothing POSTed on refusal"        test ! -f "$STATE/ruleset-posted"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id"
echo 'active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:true|gitleaks|refs:~DEFAULT_BRANCH/refs/heads/main|strict:false|merge,rebase,squash' > "$STATE/ruleset-norm"
refuses "conditions-only drift -> refuse, no write" 'refusing to modify' run protect allen/repo1 --vault agent-p1
check "  nothing POSTed on conditions drift" test ! -f "$STATE/ruleset-posted"
newstate; touch "$STATE/collab"; echo true > "$STATE/actions-approve"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "warns: no CODEOWNERS"               grep -q 'WARNING.*CODEOWNERS' <<<"$OUT"
check "warns: no gitleaks workflow"        grep -q 'WARNING.*gitleaks workflow' <<<"$OUT"
check "warns: Actions can approve PRs"     grep -q 'WARNING.*approve' <<<"$OUT"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
check "--require build-test accepted"      run protect allen/repo1 --vault agent-p1 --require build-test
check "  build-test present in posted JSON" grep -q '"context": *"build-test"' "$STATE/ruleset-posted"
check "  gitleaks still present too"       grep -q '"context": *"gitleaks"' "$STATE/ruleset-posted"

echo "== task 4: verify =="
plan_ok(){ cat > "$STATE/exec-plan" <<'PLAN'
pr checks|0|gitleaks	pass
pr merge --squash --admin|1|GraphQL: Repository rule violations found (mergePullRequest)
pr merge|1|X Pull request #1 is not mergeable: the base branch policy prohibits the merge.
pr review --approve|1|failed to create review: GraphQL: Review Can not approve your own pull request
push origin HEAD:main|1|remote: error: GH013: Repository rule violations found for refs/heads/main.
PLAN
}
newstate; plan_ok
VOUT=$(run verify p1 2>&1); VRC=$?
check "gate passes on the canned refusals"   test "$VRC" -eq 0
check "  all four refusals asserted"         test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 4
newstate; cat > "$STATE/exec-plan" <<'PLAN'
pr checks|1|no checks reported on the latest commit
pr merge --squash --admin|1|GraphQL: Repository rule violations found (mergePullRequest)
pr merge|1|X Pull request #1 is not mergeable: the base branch policy prohibits the merge.
pr review --approve|1|failed to create review: GraphQL: Review Can not approve your own pull request
push origin HEAD:main|1|remote: error: GH013: Repository rule violations found for refs/heads/main.
PLAN
VOUT=$(run verify p1 2>&1); VRC=$?
check "no checks reported -> warns UNTESTED, continues" test "$VRC" -eq 0
check "  UNTESTED warning shown"             grep -qi 'UNTESTED' <<<"$VOUT"
check "  still asserts four refusals"        test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 4
newstate; cat > "$STATE/exec-plan" <<'PLAN'
pr checks|1|gitleaks fail 10s
pr merge --squash --admin|1|GraphQL: Repository rule violations found (mergePullRequest)
pr merge|1|X Pull request #1 is not mergeable: the base branch policy prohibits the merge.
pr review --approve|1|failed to create review: GraphQL: Review Can not approve your own pull request
push origin HEAD:main|1|remote: error: GH013: Repository rule violations found for refs/heads/main.
PLAN
refuses "red check -> die, not UNTESTED warning" 'not green' run verify p1
newstate; plan_ok
sed -i 's|^push origin HEAD:main.1.remote.*|push origin HEAD:main\|0\|pushed!|' "$STATE/exec-plan"
refuses "push-to-main success -> GATE NOT BINDING" 'GATE NOT BINDING' run verify p1
newstate; plan_ok
sed -i 's|GH013[^|]*|! [rejected] main -> main (non-fast-forward)|' "$STATE/exec-plan"
refuses "wrong refusal reason -> GATE NOT BINDING" 'GATE NOT BINDING' run verify p1
newstate
refuses "container not running" 'not running' sh -c 'echo > /dev/null; HOME='"$H"' AGENT_CONTAINERS_CONFIG='"$CFGROOT"' PATH='"$T"'/bin:$PATH '"$AN"' verify nosuch'
refuses "repo mode without --vault refused" 'needs --vault' run verify allen/repo9
export TMPDIR="$T/tmpdirs"; mkdir -p "$TMPDIR"
refuses "repo mode: aborts in empty clone" 'not a git repository|fatal' run verify allen/repo9 --vault agent-p1
check "  temp clone cleaned up by EXIT trap" test -z "$(ls -A "$TMPDIR")"
check "trap freezes tmp at set time (immediate expansion)" grep -q "trap \"rm -rf '" "$AN"
unset TMPDIR

echo "== task 5: project steps 1-6 =="
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
export AGENT_NEW_DIGESTS="$T/repo-root/digests.md"
export AGENT_NEW_STOP_AFTER=token
PROJHOME="$H/GitHub"; mkdir -p "$PROJHOME"
check "fresh project run (stops after token)" run project NewProj --token-from agent-old < /dev/null
check "  repo created"            grep -q '^GH: repo create allen/NewProj --private --clone' "$GHLOG"
check "  agent-up init called"    grep -q '^AU: init' "$AULOG"
check "  digest injected"         grep -q 'sha256:aaa111' "$CFGROOT/newproj/compose.yaml"
check "  RESEARCH=1 single line"  test "$(grep -c '^RESEARCH=' "$CFGROOT/newproj/project.conf")" = 1
check "  RESEARCH value 1"        grep -qx 'RESEARCH=1' "$CFGROOT/newproj/project.conf"
check "  T3_CONNECT=publish"      grep -qx 'T3_CONNECT=publish' "$CFGROOT/newproj/project.conf"
check "  CODEOWNERS replaced"     grep -qx '\* @allen' "$PROJHOME/NewProj/.github/CODEOWNERS"
check "  pushed main"             grep -q '^GIT: push -u origin main' "$GITLOG"
check "  vault created"           test -f "$STATE/vault"
check "  sa item in Personal"     test -f "$STATE/item-agent-newproj service account"
check "  github-agent item"       test -f "$STATE/item-github-agent"
check "  token copied from --token-from vault" grep -q '^OP: read op://agent-old/github-agent/token' "$OPLOG"
: > "$GHLOG"; : > "$GITLOG"; : > "$AULOG"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1); RC=$?
check "re-run exits 0"            test "$RC" -eq 0
check "re-run: >=4 SKIP lines"    test "$(grep -c 'SKIP (done)' <<<"$OUT")" -ge 4
check "  no second repo create"   sh -c "! grep -q 'repo create' '$GHLOG'"
check "  no push on re-run"       sh -c "! grep -q '^GIT: push' '$GITLOG'"
mkdir -p "$PROJHOME/Decoy" && git -C "$PROJHOME/Decoy" init -q && git -C "$PROJHOME/Decoy" remote add origin https://github.com/other/thing
refuses "existing folder with wrong origin refused" 'refusing to adopt' run project Decoy --token-from agent-old < /dev/null
mkdir -p "$PROJHOME/Decoy2" && git -C "$PROJHOME/Decoy2" init -q && git -C "$PROJHOME/Decoy2" remote add origin "https://notgithub.com/allen/Decoy2"
refuses "lookalike host refused" 'refusing to adopt' run project Decoy2 --token-from agent-old < /dev/null
unset AGENT_NEW_STOP_AFTER

echo "== task 5b: vault scope exclusivity =="
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
export AGENT_NEW_STOP_AFTER=token
OUT=$(run project VaultOk --token-from agent-old < /dev/null 2>&1)
check "normal scope: no scope warning"  bash -c '! grep -q "scoped vault list" <<<"$0"' "$OUT"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
echo other-vault > "$STATE/vault-list-extra"
OUT=$(run project VaultWarn --token-from agent-old < /dev/null 2>&1); RC=$?
check "extra vault visible -> scope WARNING, not die" grep -q "expected ONLY 'agent-vaultwarn'" <<<"$OUT"
check "  run still completes (warn, not die)"          test "$RC" -eq 0
unset AGENT_NEW_STOP_AFTER
rm -rf "$PROJHOME/VaultOk" "$CFGROOT/vaultok" "$PROJHOME/VaultWarn" "$CFGROOT/vaultwarn"

echo "== task 6: project steps 7-10 =="
fullstate(){ newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
  touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
  printf 'https://host:8447 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' > "$STATE/ts-status"
  plan_ok; }
rm -rf "$PROJHOME/NewProj" "$CFGROOT/newproj"
fullstate
check "full project run"             run project NewProj --token-from agent-old < /dev/null
check "  serve mapping with formula port" grep -q '^TS: serve --bg --https=8447 3778' "$TSLOG"
check "  up with token in env"       grep -q '^AU(tok): up newproj' "$AULOG"
check "  research up too"            grep -q '^AU(tok): up research' "$AULOG"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1)
check "  checklist printed"          grep -q "codex login --device-auth" <<<"$OUT"
fullstate; printf 'https://host:8447 (Funnel on)\n|-- / proxy http://127.0.0.1:3778\n' > "$STATE/ts-status"
refuses "serve status without (tailnet only)" 'tailnet only' run project NewProj --token-from agent-old < /dev/null
fullstate
printf 'https://host:9999 (tailnet only)\n|-- / proxy http://127.0.0.1:37780\n' > "$STATE/ts-status"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1) || true
check "prefix port 37780 does not satisfy 3778 mapping" grep -q '^TS: serve --bg --https=8447 3778' "$TSLOG"
fullstate
rm -f "$STATE/ruleset-posted"; echo 'wrong' > "$STATE/ts-status"; touch "$STATE/ts-frozen"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1) && { echo "FAIL: resume setup should have died at tailscale"; fail=1; } || true
rm -f "$STATE/ts-frozen"; printf 'https://host:8447 (tailnet only)\n|-- / proxy http://127.0.0.1:3778\n' > "$STATE/ts-status"
: > "$GITLOG"
check "resume after tailscale failure"  run project NewProj --token-from agent-old < /dev/null
check "  earlier steps all SKIPPED (no push)" sh -c "! grep -q '^GIT: push' '$GITLOG'"
check "  later steps ran (up called)"   grep -q '^AU(tok): up newproj' "$AULOG"

echo "== review fixes: hardening =="
export AGENT_NEW_STOP_AFTER=token
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
OP_SERVICE_ACCOUNT_TOKEN=leftover run project InhTok --token-from agent-old < /dev/null >/dev/null 2>&1
check "inherited SA token: no signin as the service account" sh -c "! grep -q '^OP(sa): signin' '$OPLOG'"
check "  no vault create as the service account"            sh -c "! grep -q '^OP(sa): vault create' '$OPLOG'"
check "  owner session did create the vault"                grep -q '^OP: vault create' "$OPLOG"
unset AGENT_NEW_STOP_AFTER
rm -rf "$PROJHOME/InhTok" "$CFGROOT/inhtok"

newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
LIVE_NORM='active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:true|R-CMD-check+gitleaks|refs:~DEFAULT_BRANCH/|strict:false|merge,rebase,squash'
touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"; echo 7 > "$STATE/ruleset-id"; echo "$LIVE_NORM" > "$STATE/ruleset-norm"
check "--require R-CMD-check matches C-sorted norm (default locale)" run protect allen/repo1 --vault agent-p1 --require R-CMD-check
check "  and under en_US.utf8" env LC_ALL=en_US.utf8 HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" "$AN" protect allen/repo1 --vault agent-p1 --require R-CMD-check
check "  nothing POSTed" test ! -f "$STATE/ruleset-posted"

newstate
refuses "project --vault refused" 'project always uses vault agent-<project>' run project NoVault --vault foo < /dev/null

rm -rf "$PROJHOME/NewProj" "$CFGROOT/newproj"
fullstate
run project NewProj --token-from agent-old < /dev/null >/dev/null 2>&1
sed -i 's/^T3_PORT=.*/T3_PORT=03778/' "$CFGROOT/newproj/project.conf"; : > "$TSLOG"
printf 'wrong\n' > "$STATE/ts-status"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1) || true
check "T3_PORT=03778 (leading zero) gives port 8447" grep -q -- '--https=8447' "$TSLOG"
check "  and serve targets 3778" grep -q -- ' 3778$' "$TSLOG"
sed -i 's/^T3_PORT=.*/T3_PORT=3778/' "$CFGROOT/newproj/project.conf"
fullstate
printf 'https://host:8447 (Funnel on)\n|-- / proxy http://127.0.0.1:3778\nhttps://host:9999 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n' > "$STATE/ts-status"
refuses "this port public while another is tailnet-only dies" 'NEVER use Funnel' run project NewProj --token-from agent-old < /dev/null
fullstate
printf 'https://host:8447 (tailnet only)\n|-- / proxy http://127.0.0.1:3778\nhttps://host:9999 (Funnel on)\n|-- / proxy http://127.0.0.1:9999\n' > "$STATE/ts-status"
check "this port tailnet-only, another Funnel passes" run project NewProj --token-from agent-old < /dev/null
sed -i 's/^T3_PORT=.*/T3_PORT=03778/' "$CFGROOT/newproj/project.conf"
fullstate
printf 'https://host:8447 (tailnet only)\n|-- / proxy http://127.0.0.1:3778\n' > "$STATE/ts-status"; : > "$TSLOG"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1) || true
check "T3_PORT=03778: existing 3778 mapping recognised (SKIP)" grep -q 'SKIP (done): tailscale serve mapping for 3778' <<<"$OUT"
check "  and no serve call made" sh -c "! grep -q '^TS: serve --bg' '$TSLOG'"
sed -i 's/^T3_PORT=.*/T3_PORT=3778/' "$CFGROOT/newproj/project.conf"
printf 'TAILSCALE_HTTPS_PORT=abc\n' >> "$CFGROOT/newproj/project.conf"
refuses "non-numeric TAILSCALE_HTTPS_PORT dies" 'must be a port 1-65535' run project NewProj --token-from agent-old < /dev/null
sed -i 's/^TAILSCALE_HTTPS_PORT=.*/TAILSCALE_HTTPS_PORT=70000/' "$CFGROOT/newproj/project.conf"
refuses "out-of-range TAILSCALE_HTTPS_PORT dies" 'must be a port 1-65535' run project NewProj --token-from agent-old < /dev/null
rm -rf "$PROJHOME/NewProj" "$CFGROOT/newproj"

newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
export AGENT_NEW_STOP_AFTER=token
mkdir -p "$CFGROOT/fbproj"; printf 'PROJECT=fbproj\nT3_PORT=3779\n' > "$CFGROOT/fbproj/project.conf"
printf '# maintainer: me@example.com\nimage: ghcr.io/x/spades-gis@REPLACE_WITH_DIGEST\n' > "$CFGROOT/fbproj/compose.yaml"
run project FbProj --token-from agent-old < /dev/null >/dev/null 2>&1
check "digest fallback rewrites the image line"      grep -qx 'image: ghcr.io/x/spades-gis@sha256:aaa111' "$CFGROOT/fbproj/compose.yaml"
check "  leaves an unrelated @ line untouched"       grep -qx '# maintainer: me@example.com' "$CFGROOT/fbproj/compose.yaml"
unset AGENT_NEW_STOP_AFTER
rm -rf "$PROJHOME/FbProj" "$CFGROOT/fbproj"

[ "$fail" -eq 0 ] && echo "AGENT-NEW: ALL PASSED" || { echo "AGENT-NEW: FAILURES"; exit 1; }
