#!/usr/bin/env bash
# Tests for bin/agent-new (docs/specs/2026-10-15-agent-new-design.md). No real gh/op/git/docker:
# all are stubs on PATH that log how they were called and replay canned responses from $STATE.
set -uo pipefail
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
    mkdir -p "$d" && (cd "$d" && "$REALGIT" init -q -b main && "$REALGIT" commit -q --allow-empty -m seed && "$REALGIT" remote add origin "https://github.com/x/y")
    ;;
  "repo clone "*) mkdir -p "${*: -1}" ;;
  *) exit 0 ;;
esac
STUB
# ---- stub op: logs; grows state (vault/service-account/item) for project steps
cat > "$T/bin/op" <<'STUB'
#!/usr/bin/env bash
echo "OP: $*" >> "$OPLOG"
case "$1 ${2:-}" in
  "signin ")            echo ":" ;;
  "vault get")          [ -f "$STATE/vault" ] ;;
  "vault create")       touch "$STATE/vault" ;;
  "service-account create") echo fake-sa-token ;;
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
EXPECT_NORM='active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:true|gitleaks'
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
newstate; plan_ok
sed -i 's|^push origin HEAD:main.1.remote.*|push origin HEAD:main\|0\|pushed!|' "$STATE/exec-plan"
refuses "push-to-main success -> GATE NOT BINDING" 'GATE NOT BINDING' run verify p1
newstate; plan_ok
sed -i 's|GH013[^|]*|! [rejected] main -> main (non-fast-forward)|' "$STATE/exec-plan"
refuses "wrong refusal reason -> GATE NOT BINDING" 'GATE NOT BINDING' run verify p1
newstate
refuses "container not running" 'not running' sh -c 'echo > /dev/null; HOME='"$H"' AGENT_CONTAINERS_CONFIG='"$CFGROOT"' PATH='"$T"'/bin:$PATH '"$AN"' verify nosuch'
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
unset AGENT_NEW_STOP_AFTER

[ "$fail" -eq 0 ] && echo "AGENT-NEW: ALL PASSED" || { echo "AGENT-NEW: FAILURES"; exit 1; }
