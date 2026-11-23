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
echo "${GH_TOKEN:-}" >> "$STATE/gh-tokens"
case "$*" in
  "pr create"*) "$REALGIT" log -1 --format='AUTHOR: %an <%ae> COMMITTER: %cn <%ce>' >> "$STATE/gh-author" ;;
  "pr merge --squash --admin") [ -f "$STATE/gate" ] && { echo "GraphQL: Repository rule violations found" >&2; exit 1; }; : ;;
  "pr merge --squash") [ -f "$STATE/gate" ] && { echo "the base branch policy prohibits the merge" >&2; exit 1; }; : ;;
  "pr review --approve") [ -f "$STATE/gate" ] && { echo "Review Can not approve your own pull request" >&2; exit 1; }; : ;;
  "api user --jq .login") if [ -n "${GH_TOKEN:-}" ]; then cat "$STATE/mu-login" 2>/dev/null || echo agent-allen
                          else [ -s "$STATE/login" ] || exit 1; cat "$STATE/login"; fi ;;
  api\ repos/*/collaborators/*) [ -f "$STATE/collab" ] ;;
  api\ -X\ PUT\ repos/*/collaborators/*) touch "$STATE/invited" ;;
  "api /user/repository_invitations --jq"*) [ -n "${GH_TOKEN:-}" ] || exit 1; [ -f "$STATE/invited" ] && echo 42 ;;
  "api -X PATCH /user/repository_invitations/42") [ -n "${GH_TOKEN:-}" ] || exit 1; touch "$STATE/collab" ;;
  "api repos/"*"/rulesets --jq"*) [ -f "$STATE/rulesets-list-fail" ] && { echo "HTTP 403: upgrade to Pro" >&2; exit 1; }; [ -f "$STATE/rulesets-stderr" ] && echo "warning: stray stderr line" >&2
    # answers per ruleset name: the name is the first .name=="..." in the --jq argument
    # (a template name may be followed by `or .name=="main"`: answer for every name in the selector, first hit wins)
    for rn in $(grep -o '\.name==\"[^\"]*\"' <<<"$*" | sed 's/^[^"]*"//; s/"$//'); do
      [ -s "$STATE/ruleset-id-$rn" ] && { cat "$STATE/ruleset-id-$rn"; break; }
    done; : ;;
  "api -X POST repos/"*"/rulesets --input -") body="$(cat)"; rn="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)"
    printf '%s\n' "$body" > "$STATE/ruleset-posted-$rn" ;;
  "api repos/"*"/rulesets/"[789]" --jq"*) case "$2" in */7) rn=protect-main ;; */8) rn=agent-fence ;; *) rn=agent-fence-tags ;; esac
    cat "$STATE/ruleset-norm-$rn" ;;
  "api repos/"*"/contents/.github/CODEOWNERS") [ -f "$STATE/has-codeowners" ] ;;
  "api repos/"*"/contents/.github/workflows/gitleaks.yml") [ -f "$STATE/has-gitleaks" ] ;;
  "api repos/"*"/actions/permissions/workflow --jq .can_approve_pull_request_reviews") cat "$STATE/actions-approve" 2>/dev/null || echo false ;;
  "api repos/"*"/branches/allen-dev") [ -f "$STATE/has-allen-dev" ] ;;
  "api repos/"*"/git/ref/heads/"*" --jq .object.sha") [ -f "$STATE/no-commits" ] && { echo "HTTP 409: Git Repository is empty." >&2; exit 1; }
    echo "sha-of-${2##*/heads/}" ;;
  "api -X POST repos/"*"/git/refs -f ref="*) echo "$*" > "$STATE/ref-posted" ;;
  "api -X PATCH repos/"*" -F delete_branch_on_merge=true") touch "$STATE/autodelete-patched" ;;
  "api repos/"*" --jq .default_branch") cat "$STATE/default-branch" 2>/dev/null || echo main ;;
  "api repos/"*" --jq .delete_branch_on_merge") cat "$STATE/autodelete" 2>/dev/null || echo false ;;
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
if [ "${1-}" = whoami ]; then   # markers in $STATE: OP_SIGNED_OUT; OP_NEEDS_SESSION (signed in only with the eval'd OP_SESSION_test=1); OP_WHOAMI_OK=<n> (signed in for the first n calls only)
  [ ! -f "$STATE/OP_SIGNED_OUT" ] || exit 1
  [ ! -f "$STATE/OP_NEEDS_SESSION" ] || [ "${OP_SESSION_test-}" = 1 ] || exit 1
  if [ -f "$STATE/OP_WHOAMI_OK" ]; then
    n=$(( $(cat "$STATE/whoami.count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/whoami.count"
    [ "$n" -le "$(cat "$STATE/OP_WHOAMI_OK")" ] || exit 1
  fi
  exit 0
fi
if [ "${1-}" = signin ]; then   # markers: OP_SIGNIN_FAIL -> exit 1; OP_SIGNIN_NOOP -> stays signed out
  [ ! -f "$STATE/OP_SIGNIN_FAIL" ] || exit 1
  [ -f "$STATE/OP_SIGNIN_NOOP" ] || { rm -f "$STATE/OP_SIGNED_OUT"; : > "$STATE/OP_NEEDS_SESSION"; }
  echo "export OP_SESSION_test=1"; exit 0
fi
case "$1 ${2:-}" in
  "vault get")          [ -f "$STATE/vault" ] ;;
  "vault create")       touch "$STATE/vault" ;;
  "vault list")
    printf 'ID    NAME\n'
    [ -f "$STATE/sa-vault" ] && printf 'v1    %s\n' "$(cat "$STATE/sa-vault")"
    [ -f "$STATE/vault-list-extra" ] && printf 'v2    %s\n' "$(cat "$STATE/vault-list-extra")"
    ;;
  "service-account create") echo "$3" > "$STATE/sa-vault"; echo fake-sa-token ;;
  "item get")           [ -f "$STATE/item-$3" ] ;;
  "item create")        n=$(ls "$STATE"/item-json-* 2>/dev/null | wc -l); cat > "$STATE/item-json-$((n+1))"
                        t="$(sed -n 's/.*"title": *"\([^"]*\)".*/\1/p' "$STATE/item-json-$((n+1))")"; touch "$STATE/item-$t" ;;
  "read "*)             case "$*" in *"service account"*) [ -f "$STATE/op-sa-read-fail" ] && exit 1 ;; esac; if [ -f "$STATE/read-value" ]; then cat "$STATE/read-value"; else echo fake-op-secret; fi ;;
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
  clone) echo "GITENV: global=${GIT_CONFIG_GLOBAL:-} nosystem=${GIT_CONFIG_NOSYSTEM:-} count=${GIT_CONFIG_COUNT:-} helper=${GIT_CONFIG_VALUE_0:-} name=${GIT_CONFIG_VALUE_1:-} email=${GIT_CONFIG_VALUE_2:-}" >> "$GITLOG"
         mkdir -p "${@: -1}"; cd "${@: -1}" && "$REALGIT" init -q -b main && "$REALGIT" commit -q --allow-empty -m seed && "$REALGIT" remote add origin "https://github.com/x/y" && "$REALGIT" update-ref refs/remotes/origin/main HEAD ;;
  fetch) exit 0 ;;
  push)  case "$*" in *HEAD:main*) [ -f "$STATE/gate" ] && { echo "remote: error: GH013: Repository rule violations found" >&2; exit 1; } ;; esac
         [ -f "$STATE/push-fail-once" ] && { rm -f "$STATE/push-fail-once"; echo "remote: push rejected" >&2; exit 1; }
         "$REALGIT" rev-parse --git-dir >/dev/null 2>&1 && "$REALGIT" update-ref refs/remotes/origin/main HEAD; exit 0 ;;
  *)     exec "$REALGIT" "$@" ;;
esac
STUB
# ---- the pin step: agent-new runs `agent-up update <project>`, which verifies `latest` with scripts/verify-image.sh. The stub agent-up
# below hands `update` to the REAL launcher of a throwaway clone ($NC, on main; its origin is a local bare repo, so every fetch stays
# offline), with $ABIN first on PATH: stub gh and curl (tests/launcher/stubs) answer for GitHub and ghcr.io, git is the real one, and
# docker knows no container. Nothing reaches the real GitHub or ghcr.io.
unset GH_NOAUTH GH_DOWN GH_RUNNING GH_ATTEST_DOWN GH_ATTEST_SAN GH_ATTEST_REF REG_TOKEN_FAIL AGENT_UP_SKIP_GIT_CHECK AGENT_UP_PULLED
NO="$T/norigin.git"; NW="$T/nwork"; NC="$T/nclone"; ABIN="$T/abin"
"$REALGIT" init -q --bare -b main "$NO"; "$REALGIT" init -q -b main "$NW"
mkdir -p "$NW/images/base" "$ABIN"; cp -r "$ROOT/bin" "$ROOT/scripts" "$ROOT/project-template" "$NW/"; cp -r "$ROOT/images/base/agent-clis" "$NW/images/base/"
"$REALGIT" -C "$NW" add -A; "$REALGIT" -C "$NW" commit -q -m fixture; "$REALGIT" -C "$NW" remote add origin "$NO"; "$REALGIT" -C "$NW" push -q origin main
NSHA="$("$REALGIT" -C "$NW" rev-parse HEAD)"; "$REALGIT" clone -q "$NO" "$NC" 2>/dev/null
AN="$NC/bin/agent-new"   # agent-new resolves its clone from its own location: run the throwaway clone's copy
cp "$ROOT/tests/launcher/stubs/gh" "$ROOT/tests/launcher/stubs/curl" "$ABIN/"
printf '#!/bin/sh\nexec "$REALGIT" "$@"\n' > "$ABIN/git"; printf '#!/bin/sh\nexit 1\n' > "$ABIN/docker"; chmod +x "$ABIN"/*
GISD=$(printf 'c%.0s' $(seq 64)); BIOD=$(printf 'd%.0s' $(seq 64))
printf 'spades-gis latest sha256:%s\nspades-bio latest sha256:%s\n' "$GISD" "$BIOD" > "$T/reg"
printf 'spades-gis sha256:%s ghcr.io/allenlarocque/spades-gis %s %s 77 1\nspades-bio sha256:%s ghcr.io/allenlarocque/spades-bio %s %s 77 1\n' \
  "$GISD" "$GISD" "$NSHA" "$BIOD" "$BIOD" "$NSHA" > "$T/attest.good"; cp "$T/attest.good" "$T/attest"
echo "77 1" > "$T/latest"
REG_TABLE="$T/reg" GH_ATTEST="$T/attest" GH_LATEST_RUN="$T/latest" GH_LOG="$T/agh.log" CURL_LOG="$T/curl.log"
export NC ABIN REG_TABLE GH_ATTEST GH_LATEST_RUN GH_LOG CURL_LOG
NOTMAIN="the image 'latest' points to was NOT built by publish on main; do not use it."
# ---- stub agent-up: logs; mimics `init` by materializing the config dir from fixtures; `update` runs the real launcher (above)
cat > "$T/bin/agent-up" <<'STUB'
#!/usr/bin/env bash
echo "AU${OP_SERVICE_ACCOUNT_TOKEN:+(tok)}: $*" >> "$AULOG"
if [ "$1" = update ]; then PATH="$ABIN:$PATH" exec "$NC/bin/agent-up" "$@"; fi
if [ "$1" = init ]; then
  p="$(basename "$2" | tr 'A-Z' 'a-z')"; i=gis; [ "${3:-}" != --image ] || i="$4"
  mkdir -p "$AGENT_CONTAINERS_CONFIG/$p" "$2/.github/workflows"
  printf 'services:\n  agent:\n    image: ghcr.io/allenlarocque/spades-%s@sha256:REPLACE_WITH_DIGEST\n' "$i" > "$AGENT_CONTAINERS_CONFIG/$p/compose.yaml"
  printf 'PROJECT=%s\nIMAGE=%s\nT3_PORT=3778\nT3_CONNECT=0\nRESEARCH=0\n' "$p" "$i" > "$AGENT_CONTAINERS_CONFIG/$p/project.conf"
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
EXPECT_NORM='branch|active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:false|gitleaks|refs:~DEFAULT_BRANCH/|strict:false|merge,rebase,squash'
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
check "no ruleset: POSTs one"              run protect allen/repo1 --vault agent-p1 --main-gate
check "  posted JSON names protect-main"   grep -q '"name": *"protect-main"' "$STATE/ruleset-posted-protect-main"
check "  bypass: admin, PRs only"          grep -q '"bypass_mode": *"pull_request"' "$STATE/ruleset-posted-protect-main"
check "  required check gitleaks"          grep -q '"context": *"gitleaks"' "$STATE/ruleset-posted-protect-main"
check "  no last-push approval (owner may approve after editing the branch)" grep -q '"require_last_push_approval": *false' "$STATE/ruleset-posted-protect-main"
newstate; touch "$STATE/collab" "$STATE/rulesets-list-fail"
refuses "rulesets list fails -> loud die" 'could not list rulesets' run protect allen/repo1 --vault agent-p1 --main-gate
newstate; touch "$STATE/collab" "$STATE/rulesets-list-fail"
refuses "  includes gh output" 'upgrade to Pro' run protect allen/repo1 --vault agent-p1 --main-gate
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id-protect-main"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm-protect-main"
check "identical ruleset -> SKIP"          run protect allen/repo1 --vault agent-p1 --main-gate
check "  nothing POSTed"                   test ! -f "$STATE/ruleset-posted-protect-main"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks" "$STATE/rulesets-stderr"
echo 7 > "$STATE/ruleset-id-protect-main"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm-protect-main"
check "stray gh stderr on success is not the id" run protect allen/repo1 --vault agent-p1 --main-gate
check "  still matched ruleset 7 (SKIP, no POST)" test ! -f "$STATE/ruleset-posted-protect-main"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id-protect-main"; echo 'branch|active|RepositoryRole:5:always|deletion|pr:0:false:false:false|' > "$STATE/ruleset-norm-protect-main"
refuses "divergent ruleset -> refuse, no write" 'refusing to modify' run protect allen/repo1 --vault agent-p1 --main-gate
check "  nothing POSTed on refusal"        test ! -f "$STATE/ruleset-posted-protect-main"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id-protect-main"
echo 'branch|active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:false|gitleaks|refs:~DEFAULT_BRANCH/refs/heads/main|strict:false|merge,rebase,squash' > "$STATE/ruleset-norm-protect-main"
refuses "conditions-only drift -> refuse, no write" 'refusing to modify' run protect allen/repo1 --vault agent-p1 --main-gate
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id-protect-main"; echo "${EXPECT_NORM/pr:1:true:true:false/pr:1:true:true:true}" > "$STATE/ruleset-norm-protect-main"
refuses "older ruleset with last-push approval -> drift reported, no write" 'refusing to modify' run protect allen/repo1 --vault agent-p1 --main-gate
check "  nothing POSTed on last-push drift" test ! -f "$STATE/ruleset-posted-protect-main"
check "  nothing POSTed on conditions drift" test ! -f "$STATE/ruleset-posted-protect-main"
newstate; touch "$STATE/collab"; echo true > "$STATE/actions-approve"
OUT=$(run protect allen/repo1 --vault agent-p1 --main-gate 2>&1)
check "warns: no CODEOWNERS"               grep -q 'WARNING.*CODEOWNERS' <<<"$OUT"
check "warns: no gitleaks workflow"        grep -q 'WARNING.*gitleaks workflow' <<<"$OUT"
check "warns: Actions can approve PRs"     grep -q 'WARNING.*approve' <<<"$OUT"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
check "--require build-test accepted"      run protect allen/repo1 --vault agent-p1 --main-gate --require build-test
check "  build-test present in posted JSON" grep -q '"context": *"build-test"' "$STATE/ruleset-posted-protect-main"
check "  gitleaks still present too"       grep -q '"context": *"gitleaks"' "$STATE/ruleset-posted-protect-main"

echo "== fence: templates =="
FENCE_NORM='branch|active|RepositoryRole:5:always|creation,deletion,non_fast_forward,update|pr:-||refs:~ALL/refs/heads/allen-dev,refs/heads/chore/**,refs/heads/ci/**,refs/heads/docs/**,refs/heads/experiment/**,refs/heads/feature/**,refs/heads/fix/**,refs/heads/perf/**,refs/heads/refactor/**,refs/heads/revert/**,refs/heads/sync/**,refs/heads/test/**,refs/heads/upstream/**|strict:-|'
TAGS_NORM='tag|active|RepositoryRole:5:always|creation,deletion,update|pr:-||refs:~ALL/|strict:-|'
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
check "no fence: protect succeeds"            run protect allen/repo1 --vault agent-p1 --main-gate
check "  agent-fence POSTed"                  test -s "$STATE/ruleset-posted-agent-fence"
check "  agent-fence-tags POSTed"             test -s "$STATE/ruleset-posted-agent-fence-tags"
check "  three POSTs: both fences and protect-main"                     test "$(grep -c 'POST repos/allen/repo1/rulesets' "$GHLOG")" -eq 3
check "  fence targets branches"              grep -q '"target": *"branch"' "$STATE/ruleset-posted-agent-fence"
check "  fence bypass is always"              grep -q '"bypass_mode": *"always"' "$STATE/ruleset-posted-agent-fence"
for t in creation update deletion non_fast_forward; do
  check "  fence rule $t"                     grep -q "\"type\": *\"$t\"" "$STATE/ruleset-posted-agent-fence"
done
check "  fence includes ~ALL"                 grep -q '"~ALL"' "$STATE/ruleset-posted-agent-fence"
for e in allen-dev fix/'**' feature/'**' chore/'**' docs/'**' test/'**' ci/'**' refactor/'**' perf/'**' revert/'**' upstream/'**' sync/'**' experiment/'**'; do
  check "  fence excludes refs/heads/$e"      grep -qF "\"refs/heads/$e\"" "$STATE/ruleset-posted-agent-fence"
done
check "  fence has no feat/**"                bash -c '! grep -qF "refs/heads/feat/**" "$1"' _ "$STATE/ruleset-posted-agent-fence"
check "  fence has no release/**"             bash -c '! grep -qF "refs/heads/release/**" "$1"' _ "$STATE/ruleset-posted-agent-fence"
check "  tags ruleset targets tags"           grep -q '"target": *"tag"' "$STATE/ruleset-posted-agent-fence-tags"
check "  tags ruleset has empty exclude"      grep -q '"exclude": *\[\]' "$STATE/ruleset-posted-agent-fence-tags"
check "  tags ruleset bypass is always"       grep -q '"bypass_mode": *"always"' "$STATE/ruleset-posted-agent-fence-tags"

# the expected strings agent-new builds in bash must equal what its own NORM_JQ makes of each posted template
NORM_JQ_SRC="$(sed -n "/^NORM_JQ='/,/^\] | join/p" "$AN" | sed "1s/^NORM_JQ='//; \$s/'\$//")"
for n in agent-fence agent-fence-tags protect-main; do
  case "$n" in agent-fence) want="$FENCE_NORM" ;; agent-fence-tags) want="$TAGS_NORM" ;; *) want="$EXPECT_NORM" ;; esac
  check "template $n: posted JSON projects to the expected string" test "$(jq -r "$NORM_JQ_SRC" "$STATE/ruleset-posted-$n")" = "$want"
done
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 8 > "$STATE/ruleset-id-agent-fence"; echo "$FENCE_NORM" > "$STATE/ruleset-norm-agent-fence"
echo 9 > "$STATE/ruleset-id-agent-fence-tags"; echo "$TAGS_NORM" > "$STATE/ruleset-norm-agent-fence-tags"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "live fences equal the templates: SKIP" grep -q 'SKIP.*agent-fence' <<<"$OUT"
check "  fence not POSTed"                    test ! -f "$STATE/ruleset-posted-agent-fence"
check "  tags not POSTed"                     test ! -f "$STATE/ruleset-posted-agent-fence-tags"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 8 > "$STATE/ruleset-id-agent-fence"; echo "${FENCE_NORM/'refs/heads/sync/**,'/}" > "$STATE/ruleset-norm-agent-fence"
refuses "fence missing one exclude -> refuse" 'refusing to modify' run protect allen/repo1 --vault agent-p1
check "  nothing POSTed on refusal"           test ! -f "$STATE/ruleset-posted-agent-fence"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 8 > "$STATE/ruleset-id-agent-fence"; echo "$TAGS_NORM" > "$STATE/ruleset-norm-agent-fence"
refuses "tag ruleset named agent-fence -> refuse" 'refusing to modify' run protect allen/repo1 --vault agent-p1
check "  nothing POSTed for the tag mix-up"   test ! -f "$STATE/ruleset-posted-agent-fence"

check "  the cut removed exactly the one entry" test "$(( ${#FENCE_NORM} - $(wc -c < <(printf '%s' "${FENCE_NORM/'refs/heads/sync/**,'/}")) ))" -eq "$(printf '%s' 'refs/heads/sync/**,' | wc -c)"
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
echo 7 > "$STATE/ruleset-id-main"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm-protect-main"
OUT=$(run protect allen/repo1 --vault agent-p1 --main-gate 2>&1)
check "live ruleset named main counts as protect-main: SKIP" grep -q 'SKIP.*ruleset protect-main' <<<"$OUT"
check "  protect-main not POSTed"             test ! -f "$STATE/ruleset-posted-protect-main"
check "  creation message cites the runbook only for protect-main" bash -c '! grep -q "creating ruleset agent-fence.*machine-user" <<<"$1" && grep -q "creating ruleset agent-fence on" <<<"$1"' _ "$OUT"

echo "== fence: protect =="
newstate; touch "$STATE/collab"; echo master > "$STATE/default-branch"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "fresh repo, default master: fence pair posted"  test -s "$STATE/ruleset-posted-agent-fence" -a -s "$STATE/ruleset-posted-agent-fence-tags"
check "  allen-dev created from the head of master"    grep -q 'ref=refs/heads/allen-dev -f sha=sha-of-master' "$STATE/ref-posted"
check "  auto-delete PATCHed"                          test -f "$STATE/autodelete-patched"
check "  no protect-main POST without --main-gate"     test ! -f "$STATE/ruleset-posted-protect-main"
check "  no CODEOWNERS warning without --main-gate"    bash -c '! grep -q CODEOWNERS <<<"$1"' _ "$OUT"
check "  fence posted before the branch is created"    bash -c 'a=$(grep -n "POST repos/allen/repo1/rulesets" "$1" | head -n1 | cut -d: -f1); b=$(grep -n "POST repos/allen/repo1/git/refs" "$1" | cut -d: -f1); [ "$a" -lt "$b" ]' _ "$GHLOG"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "allen-dev exists: SKIP"                         grep -q 'SKIP.*allen-dev' <<<"$OUT"
check "  no POST to git/refs"                          bash -c '! grep -q "git/refs" "$1"' _ "$GHLOG"
newstate; touch "$STATE/collab"; echo true > "$STATE/autodelete"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "auto-delete already true: SKIP"                 grep -q 'SKIP.*merged branches' <<<"$OUT"
check "  no PATCH"                                     test ! -f "$STATE/autodelete-patched"
newstate; touch "$STATE/collab"
check "--no-working-branch accepted"                   run protect allen/repo1 --vault agent-p1 --no-working-branch
check "  no call to branches/allen-dev"                bash -c '! grep -q "branches/allen-dev" "$1"' _ "$GHLOG"
check "  no call to git/refs"                          bash -c '! grep -q "git/ref" "$1"' _ "$GHLOG"
newstate; touch "$STATE/collab"
OUT=$(run protect allen/repo1 --vault agent-p1 --main-gate 2>&1)
check "--main-gate: protect-main posted"               grep -q '"name": *"protect-main"' "$STATE/ruleset-posted-protect-main"
check "  with the gitleaks check"                      grep -q '"context": *"gitleaks"' "$STATE/ruleset-posted-protect-main"
check "  missing CODEOWNERS warning appears"           grep -q 'WARNING.*CODEOWNERS' <<<"$OUT"
newstate; touch "$STATE/collab" "$STATE/rulesets-list-fail"
refuses "ruleset list fails: refused" 'could not list rulesets' run protect allen/repo1 --vault agent-p1
check "  no POST to git/refs"                          bash -c '! grep -q "git/refs" "$1"' _ "$GHLOG"
newstate; touch "$STATE/collab" "$STATE/no-commits"
refuses "repo with no commits: refused" 'no commits' run protect allen/repo1 --vault agent-p1

echo "== task 4: verify =="
export AGENT_NEW_CHECK_TRIES=2 AGENT_NEW_CHECK_SLEEP=0
plan_ok(){ cat > "$STATE/exec-plan" <<'PLAN'
api user|0|agent-allen
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
check "  worktree from fresh origin/main"    grep -q 'DOCKER: exec -w /workspace p1-agent-1 bash -lc git fetch -q origin && git worktree add -f -B verify-ruleset /tmp/agent-new-verify origin/main' "$DLOG"
check "  later commands run in the worktree" grep -q 'DOCKER: exec -w /tmp/agent-new-verify p1-agent-1 bash -lc git push -f -u origin verify-ruleset' "$DLOG"
check "  never switches the owner's checkout" sh -c "! grep -q 'switch main' '$DLOG'"
check "  worktree removed on exit"           grep -q 'DOCKER: exec -w /workspace p1-agent-1 git worktree remove --force /tmp/agent-new-verify' "$DLOG"
check "  checks not retried when they report" test "$(grep -c 'pr checks' "$DLOG")" -eq 1
check "  worktree pre-cleaned before add"     grep -qF 'bash -lc git worktree remove --force /tmp/agent-new-verify 2>/dev/null; git worktree prune; rm -rf /tmp/agent-new-verify' "$DLOG"
check "  trap deletes the local verify-ruleset branch" grep -q 'DOCKER: exec -w /workspace p1-agent-1 git branch -D verify-ruleset' "$DLOG"
newstate; plan_ok; sed -i 's/^api user|0|agent-allen/api user|0|allen/' "$STATE/exec-plan"
refuses "container identity is the owner -> die" 'allen.*agent-allen|agent-allen.*allen' run verify p1
check "  nothing pushed" sh -c "! grep -q 'git push' '$DLOG'"
check "  waits for agent-init's git credentials first" grep -q 'DOCKER: exec -w /workspace p1-agent-1 bash -lc git config --global --get credential.https://github.com.helper' "$DLOG"
newstate; plan_ok; sed -i '1i credential.https://github.com.helper|1|' "$STATE/exec-plan"
AGENT_NEW_INIT_WAIT=2 refuses "git never gets credentials (agent-init unfinished) -> die after the wait" 'no GitHub credentials' run verify p1
check "  nothing pushed" sh -c "! grep -q 'git push' '$DLOG'"
check "  no worktree add attempted" sh -c "! grep -q 'worktree add' '$DLOG'"
newstate; plan_ok; sed -i '1i branch --show-current|0|verify-ruleset' "$STATE/exec-plan"
refuses "/workspace left on verify-ruleset -> die, tells owner to switch" 'git switch main' run verify p1
check "  no worktree add attempted" sh -c "! grep -q 'worktree add' '$DLOG'"
newstate; cat > "$STATE/exec-plan" <<'PLAN'
pr checks|1|no checks reported on the latest commit
pr merge --squash --admin|1|GraphQL: Repository rule violations found (mergePullRequest)
pr merge|1|X Pull request #1 is not mergeable: the base branch policy prohibits the merge.
pr review --approve|1|failed to create review: GraphQL: Review Can not approve your own pull request
push origin HEAD:main|1|remote: error: GH013: Repository rule violations found for refs/heads/main.
PLAN
sed -i '1i api user|0|agent-allen' "$STATE/exec-plan"
VOUT=$(run verify p1 2>&1); VRC=$?
check "no checks reported -> warns UNTESTED, continues" test "$VRC" -eq 0
check "  UNTESTED warning shown"             grep -qi 'UNTESTED' <<<"$VOUT"
check "  still asserts four refusals"        test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 4
check "  checks retried AGENT_NEW_CHECK_TRIES times" test "$(grep -c 'pr checks' "$DLOG")" -eq 2
newstate; cat > "$STATE/exec-plan" <<'PLAN'
pr checks|1|gitleaks fail 10s
pr merge --squash --admin|1|GraphQL: Repository rule violations found (mergePullRequest)
pr merge|1|X Pull request #1 is not mergeable: the base branch policy prohibits the merge.
pr review --approve|1|failed to create review: GraphQL: Review Can not approve your own pull request
push origin HEAD:main|1|remote: error: GH013: Repository rule violations found for refs/heads/main.
PLAN
sed -i '1i api user|0|agent-allen' "$STATE/exec-plan"
refuses "red check -> die, not UNTESTED warning" 'not green' run verify p1
check "  worktree removed on a failing run"  grep -q 'git worktree remove --force /tmp/agent-new-verify' "$DLOG"
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
newstate; echo allen > "$STATE/mu-login"
refuses "repo mode: token resolving to the owner -> die" 'allen.*agent-allen' run verify allen/repo9 --vault agent-p1
check "  nothing cloned"                     sh -c "! grep -q '^GIT: clone' '$GITLOG'"
newstate
refuses "repo mode: permissive stubs -> GATE NOT BINDING" 'GATE NOT BINDING' run verify allen/repo9 --vault agent-p1
check "  temp clone cleaned up by EXIT trap" test -z "$(ls -A "$TMPDIR")"
check "  clone is plain https"               grep -q '^GIT: clone .*https://github.com/allen/repo9 ' "$GITLOG"
check "  git isolated from owner config"     grep -q 'GITENV: global=/dev/null nosystem=1 count=3 ' "$GITLOG"
check "  helper is literal, token via env"   grep -qF 'helper=!f(){ echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' "$GITLOG"
check "  commit identity is the machine user" grep -q 'name=agent-allen email=agent-allen@users.noreply.github.com' "$GITLOG"
check "  token never in argv"                sh -c "! grep -q fake-op-secret '$GITLOG' '$GHLOG'"
newstate; touch "$STATE/gate"
printf 'export GH_TOKEN=bogus-owner-token\n' > "$H/.profile"
VOUT=$(run verify allen/repo9 --vault agent-p1 2>&1); VRC=$?
rm -f "$H/.profile"
check "repo mode: gate passes on the canned refusals" test "$VRC" -eq 0
check "  all four refusals asserted"         test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 4
check "  login profile cannot swap the token (bash -c)" sh -c "! grep -q bogus-owner-token '$STATE/gh-tokens' && grep -q fake-op-secret '$STATE/gh-tokens'"
check "  real commit author+committer is the machine user" grep -qx 'AUTHOR: agent-allen <agent-allen@users.noreply.github.com> COMMITTER: agent-allen <agent-allen@users.noreply.github.com>' "$STATE/gh-author"
newstate; touch "$STATE/gate"; printf '[ "$0" = bash ] && export GH_TOKEN=bogus-bashenv-token\n' > "$T/bashenv"
BASH_ENV="$T/bashenv" run verify allen/repo9 --vault agent-p1 >/dev/null 2>&1
check "  BASH_ENV cannot swap the token either" sh -c "! grep -q bogus-bashenv-token '$STATE/gh-tokens' && grep -q fake-op-secret '$STATE/gh-tokens'"
check "trap freezes tmp at set time (immediate expansion)" grep -q "trap \"rm -rf '" "$AN"
unset TMPDIR

echo "== task 5: project steps 1-6 =="
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
export AGENT_NEW_STOP_AFTER=token
PROJHOME="$H/GitHub"; mkdir -p "$PROJHOME"
check "fresh project run (stops after token)" run project NewProj --token-from agent-old < /dev/null
check "  repo created"            grep -q '^GH: repo create allen/NewProj --private --clone' "$GHLOG"
check "  agent-up init called"    grep -q '^AU: init' "$AULOG"
check "  image pinned to latest's verified digest" grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:$GISD" "$CFGROOT/newproj/compose.yaml"
check "  ...by agent-up update newproj, through the verification" \
  bash -c 'grep -qx "AU: update newproj" "$1" && grep -qx "spades-gis latest" "$2" && grep -q "attestation verify oci://ghcr.io/allenlarocque/spades-gis@sha256:$4" "$3"' _ "$AULOG" "$CURL_LOG" "$GH_LOG" "$GISD"
check "  RESEARCH=1 single line"  test "$(grep -c '^RESEARCH=' "$CFGROOT/newproj/project.conf")" = 1
check "  RESEARCH value 1"        grep -qx 'RESEARCH=1' "$CFGROOT/newproj/project.conf"
check "  T3_CONNECT=publish"      grep -qx 'T3_CONNECT=publish' "$CFGROOT/newproj/project.conf"
check "  CODEOWNERS replaced"     grep -qx '\* @allen' "$PROJHOME/NewProj/.github/CODEOWNERS"
check "  pushed main"             grep -q '^GIT: push -u origin main' "$GITLOG"
check "  vault created"           test -f "$STATE/vault"
check "  sa item in Personal"     test -f "$STATE/item-agent-newproj service account"
check "  github-agent item"       test -f "$STATE/item-github-agent"
check "  token copied from --token-from vault" grep -q '^OP: read op://agent-old/github-agent/token' "$OPLOG"
echo "== secrets stay off argv: items created from JSON on stdin =="
SAJ="$(grep -l 'service account' "$STATE"/item-json-*)"; GHJ="$(grep -l '"github-agent"' "$STATE"/item-json-*)"
check "  no secret in any op argv"       sh -c "! grep -q 'fake-sa-token\|fake-op-secret' '$OPLOG'"
check "  stdin marker '-' in argv"        grep -q '^OP: item create --vault Personal -$' "$OPLOG"
check "  github item also via '-'"        grep -q '^OP: item create --vault agent-newproj -$' "$OPLOG"
check "  sa JSON: category"               grep -q '"category": "API_CREDENTIAL"' "$SAJ"
check "  sa JSON: field id credential"    grep -q '"id": "credential"' "$SAJ"
check "  sa JSON: concealed"              grep -q '"type": "CONCEALED"' "$SAJ"
check "  sa JSON: token value"            grep -q 'fake-sa-token' "$SAJ"
check "  github JSON: field id token"     grep -q '"id": "token"' "$GHJ"
check "  github JSON: token value"        grep -q 'fake-op-secret' "$GHJ"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; rm -rf "$PROJHOME/EscProj" "$CFGROOT/escproj"
printf '%s\n' 'ab"c\d' | run project EscProj >/dev/null 2>&1
ESCJ="$(grep -l '"github-agent"' "$STATE"/item-json-* 2>/dev/null)"
check "  quote/backslash escaped"         grep -qF 'ab\"c\\d' "$ESCJ"
if command -v python3 >/dev/null; then
  check "  escaped JSON parses (python3)" sh -c "python3 -c 'import json,sys; json.load(sys.stdin)' < '$ESCJ'"
fi
check "  pasted token not in argv"        sh -c "! grep -qF 'ab\"c' '$OPLOG'"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; rm -rf "$PROJHOME/CtlProj" "$CFGROOT/ctlproj"
ctl(){ printf 'ab\001c\n' | run project CtlProj; }
refuses "  control char in secret dies"   'control character' ctl
check "  and no github item created"      test ! -f "$STATE/item-github-agent"
rm -rf "$PROJHOME/EscProj" "$CFGROOT/escproj" "$PROJHOME/CtlProj" "$CFGROOT/ctlproj"
: > "$GHLOG"; : > "$GITLOG"; : > "$AULOG"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1); RC=$?
check "re-run exits 0"            test "$RC" -eq 0
check "re-run: >=4 SKIP lines"    test "$(grep -c 'SKIP (done)' <<<"$OUT")" -ge 4
check "  no second repo create"   sh -c "! grep -q 'repo create' '$GHLOG'"
check "  no push on re-run"       sh -c "! grep -q '^GIT: push' '$GITLOG'"
echo "== review fixes: resumable repo files =="
rm -rf "$PROJHOME/NewProj" "$CFGROOT/newproj"; newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
touch "$STATE/push-fail-once"
refuses "push fails once -> run dies" 'push rejected' run project NewProj --token-from agent-old < /dev/null
: > "$GITLOG"
check "re-run after failed push"  run project NewProj --token-from agent-old < /dev/null
check "  push retried on re-run"  grep -q '^GIT: push' "$GITLOG"
mkdir -p "$PROJHOME/Decoy" && git -C "$PROJHOME/Decoy" init -q && git -C "$PROJHOME/Decoy" remote add origin https://github.com/other/thing
refuses "existing folder with wrong origin refused" 'refusing to adopt' run project Decoy --token-from agent-old < /dev/null
mkdir -p "$PROJHOME/Decoy2" && git -C "$PROJHOME/Decoy2" init -q && git -C "$PROJHOME/Decoy2" remote add origin "https://notgithub.com/allen/Decoy2"
refuses "lookalike host refused" 'refusing to adopt' run project Decoy2 --token-from agent-old < /dev/null
echo "== review fixes: re-run after the agent started =="
mkrepo(){ # $1 name: an existing clone of allen/$1 with project config, one commit
  local lc; lc=$(echo "${1:?}" | tr '[:upper:]' '[:lower:]')
  rm -rf "$PROJHOME/${1:?}" "$CFGROOT/${lc:?}"
  mkdir -p "$PROJHOME/$1" "$CFGROOT/$lc"
  printf 'PROJECT=x\nT3_PORT=3790\n' > "$CFGROOT/$lc/project.conf"
  printf 'image: ghcr.io/x/spades-gis@sha256:aaa111\n' > "$CFGROOT/$lc/compose.yaml"
  git -C "$PROJHOME/$1" init -q -b main && git -C "$PROJHOME/$1" commit -q --allow-empty -m seed \
    && git -C "$PROJHOME/$1" remote add origin "https://github.com/allen/$1"; }
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; mkrepo Ahead
git -C "$PROJHOME/Ahead" commit -q --allow-empty -m remote-only
git -C "$PROJHOME/Ahead" update-ref refs/remotes/origin/main HEAD; git -C "$PROJHOME/Ahead" reset -q --hard HEAD~1
check "origin/main ahead of local main: run completes" run project Ahead --token-from agent-old < /dev/null
check "  no push attempted" sh -c "! grep -q '^GIT: push' '$GITLOG'"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; mkrepo Feat
git -C "$PROJHOME/Feat" update-ref refs/remotes/origin/main HEAD
git -C "$PROJHOME/Feat" switch -q -c feature; mkdir -p "$PROJHOME/Feat/.github"; echo '* @OWNER' > "$PROJHOME/Feat/.github/CODEOWNERS"
OUT=$(run project Feat --token-from agent-old < /dev/null 2>&1); RC=$?
check "dirty .github on a feature branch: run completes" test "$RC" -eq 0
check "  WARNING, repo files skipped"     grep -q 'WARNING.*feature' <<<"$OUT"
check "  nothing committed"               test "$(git -C "$PROJHOME/Feat" rev-list --count HEAD)" -eq 1
check "  nothing staged"                  git -C "$PROJHOME/Feat" diff --cached --quiet
check "  agent's file untouched"          grep -qx '\* @OWNER' "$PROJHOME/Feat/.github/CODEOWNERS"
check "  existing clone's branch not renamed" test "$(git -C "$PROJHOME/Feat" branch --show-current)" = feature
check "  no push attempted" sh -c "! grep -q '^GIT: push' '$GITLOG'"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; mkrepo Stage
mkdir -p "$PROJHOME/Stage/.github/workflows"; echo '* @OWNER' > "$PROJHOME/Stage/.github/CODEOWNERS"; echo x > "$PROJHOME/Stage/.github/other.txt"; echo y > "$PROJHOME/Stage/stray.txt"
run project Stage --token-from agent-old < /dev/null >/dev/null 2>&1
check "only the template paths are committed" test "$(git -C "$PROJHOME/Stage" show --name-only --format= HEAD)" = ".github/CODEOWNERS"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; mkrepo Pre
mkdir -p "$PROJHOME/Pre/.github"; echo '* @OWNER' > "$PROJHOME/Pre/.github/CODEOWNERS"; echo work > "$PROJHOME/Pre/agent.R"
git -C "$PROJHOME/Pre" add agent.R
run project Pre --token-from agent-old < /dev/null >/dev/null 2>&1
check "agent's pre-staged file is not in the owner's commit" test "$(git -C "$PROJHOME/Pre" show --name-only --format= HEAD)" = ".github/CODEOWNERS"
check "  and stays staged"                test "$(git -C "$PROJHOME/Pre" diff --cached --name-only)" = "agent.R"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; mkrepo Det
git -C "$PROJHOME/Det" update-ref refs/remotes/origin/main HEAD; git -C "$PROJHOME/Det" checkout -q --detach
mkdir -p "$PROJHOME/Det/.github"; echo '* @OWNER' > "$PROJHOME/Det/.github/CODEOWNERS"
OUT=$(run project Det --token-from agent-old < /dev/null 2>&1); RC=$?
check "detached HEAD: run completes"   test "$RC" -eq 0
check "  WARNING, repo files skipped"  grep -q 'WARNING.*not on main' <<<"$OUT"
check "  nothing committed"            test "$(git -C "$PROJHOME/Det" rev-list --count HEAD)" -eq 1
rm -rf "$PROJHOME/Ahead" "$PROJHOME/Feat" "$PROJHOME/Stage" "$PROJHOME/Pre" "$PROJHOME/Det" "$CFGROOT/pre" "$CFGROOT/det" "$CFGROOT/ahead" "$CFGROOT/feat" "$CFGROOT/stage"
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
check "  no research config: no research up"  sh -c "! grep -q 'up research' '$AULOG'"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1)
check "  checklist printed"          grep -q "codex login --device-auth" <<<"$OUT"
check "  WARNING: research has no container yet"  grep -q "WARNING: .*research" <<<"$OUT"
check "  checklist mentions agent-up init --profile research"  grep -q "no container yet: agent-up init --profile research" <<<"${OUT#*DONE}"
mkdir -p "$CFGROOT/research"; : > "$AULOG"
check "research config exists: run completes"  run project NewProj --token-from agent-old < /dev/null
check "  research up WITHOUT the token"   grep -q '^AU: up research' "$AULOG"
check "  no token-bearing research up"    sh -c "! grep -q 'AU(tok): up research' '$AULOG'"
rmdir "$CFGROOT/research"
fullstate; printf 'https://host:8447 (Funnel on)\n|-- / proxy http://127.0.0.1:3778\n' > "$STATE/ts-status"
refuses "serve status without (tailnet only)" 'tailnet only' run project NewProj --token-from agent-old < /dev/null
fullstate
printf 'https://host:9999 (tailnet only)\n|-- / proxy http://127.0.0.1:37780\n' > "$STATE/ts-status"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1) || true
check "prefix port 37780 does not satisfy 3778 mapping" grep -q '^TS: serve --bg --https=8447 3778' "$TSLOG"
fullstate
rm -f "$STATE/ruleset-posted-protect-main"; echo 'wrong' > "$STATE/ts-status"; touch "$STATE/ts-frozen"
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
LIVE_NORM='branch|active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:false|R-CMD-check+gitleaks|refs:~DEFAULT_BRANCH/|strict:false|merge,rebase,squash'
touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"; echo 7 > "$STATE/ruleset-id-protect-main"; echo "$LIVE_NORM" > "$STATE/ruleset-norm-protect-main"
check "--require R-CMD-check matches C-sorted norm (default locale)" run protect allen/repo1 --vault agent-p1 --require R-CMD-check --main-gate
check "  and under en_US.utf8" env LC_ALL=en_US.utf8 HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" "$AN" protect allen/repo1 --vault agent-p1 --require R-CMD-check --main-gate
check "  nothing POSTed" test ! -f "$STATE/ruleset-posted-protect-main"

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
fullstate
printf 'https://host:9999 (tailnet only)\n|-- / proxy http://127.0.0.1:9999\n\n  https://h:2 (Funnel on)\n  |-- / proxy http://127.0.0.1:3778\n' > "$STATE/ts-status"
refuses "indented Funnel header after a tailnet-only block dies" 'NEVER use Funnel' run project NewProj --token-from agent-old < /dev/null
fullstate
printf '# Funnel on:\n#     - https://other\n\nhttps://host:8447 (Funnel on)\n|-- /x proxy http://127.0.0.1:5000\n|-- / proxy http://127.0.0.1:3778\n' > "$STATE/ts-status"
refuses "two handlers under one Funnel header (ours second) dies" 'NEVER use Funnel' run project NewProj --token-from agent-old < /dev/null
fullstate
printf 'https://host:8447 (tailnet only)\n|-- / proxy http://localhost:3778\n' > "$STATE/ts-status"; : > "$TSLOG"
check "localhost:3778 under tailnet-only header passes" run project NewProj --token-from agent-old < /dev/null
check "  and is recognised (no serve --bg)" sh -c "! grep -q '^TS: serve --bg' '$TSLOG'"
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
sed -i '/^TAILSCALE_HTTPS_PORT=/d; s/^T3_PORT=.*/T3_PORT=abc/' "$CFGROOT/newproj/project.conf"
refuses "non-numeric T3_PORT dies" "T3_PORT='abc'" run project NewProj --token-from agent-old < /dev/null
rm -rf "$PROJHOME/NewProj" "$CFGROOT/newproj"

newstate
refuses "--t3 outside publish|1|0 refused" '--t3 must be' run project BadT3 --t3 maybe < /dev/null
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
fullstate; touch "$STATE/op-sa-read-fail"
rm -rf "$PROJHOME/SaFail" "$CFGROOT/safail"
refuses "service-account token read fails -> die" 'could not read the service account token' run project SaFail --token-from agent-old < /dev/null
check "  agent-up up never called" sh -c "! grep -q ' up safail' '$AULOG'"
rm -rf "$PROJHOME/SaFail" "$CFGROOT/safail"

# the pin step on an existing config: old placeholder spelling, verification failure, already pinned, an image line update will not pin
export AGENT_NEW_STOP_AFTER=token
fbcfg(){ # $1 image line: a fresh fbproj config holding it
  rm -rf "$PROJHOME/FbProj" "$CFGROOT/fbproj"; mkdir -p "$CFGROOT/fbproj"; printf 'PROJECT=fbproj\nIMAGE=bio\nT3_PORT=3779\n' > "$CFGROOT/fbproj/project.conf"
  printf '# maintainer: me@example.com\nservices:\n  agent:\n    image: %s\n' "$1" > "$CFGROOT/fbproj/compose.yaml"; cp "$CFGROOT/fbproj/compose.yaml" "$T/fb.before"
  : > "$CURL_LOG"; : > "$GH_LOG"; }
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
fbcfg ghcr.io/allenlarocque/spades-bio@sha256:REPLACE_WITH_DIGEST_FROM_digests.md
check "old placeholder spelling: run completes" run project FbProj --token-from agent-old < /dev/null
check "  ...pinned to latest's verified digest for its own image (spades-bio)" grep -qx "    image: ghcr.io/allenlarocque/spades-bio@sha256:$BIOD" "$CFGROOT/fbproj/compose.yaml"
check "  ...leaves an unrelated @ line untouched" grep -qx '# maintainer: me@example.com' "$CFGROOT/fbproj/compose.yaml"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
fbcfg ghcr.io/allenlarocque/spades-bio@sha256:REPLACE_WITH_DIGEST; : > "$T/attest"
refuses "no attestation -> the pin step dies with the verification's reason" "could not pin the image.*NOT UPDATED \\($(sed 's/[.]/\\./g' <<<"$NOTMAIN")" \
  run project FbProj --token-from agent-old < /dev/null
check "  ...compose.yaml unchanged (still the placeholder)" cmp -s "$CFGROOT/fbproj/compose.yaml" "$T/fb.before"
check "  ...and the run stopped there (no vault step)" test ! -f "$STATE/vault"
cp "$T/attest.good" "$T/attest"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
fbcfg "ghcr.io/allenlarocque/spades-bio@sha256:$(printf 'e%.0s' $(seq 64))"
OUT=$(run project FbProj --token-from agent-old < /dev/null 2>&1)
check "already pinned -> SKIP, file unchanged" bash -c 'grep -qF "SKIP (done): digest already pinned" <<<"$1" && cmp -s "$2" "$3"' _ "$OUT" "$CFGROOT/fbproj/compose.yaml" "$T/fb.before"
check "  ...no update, no registry or attestation call" bash -c '! grep -q "^AU: update" "$1" && [ ! -s "$2" ] && [ ! -s "$3" ]' _ "$AULOG" "$CURL_LOG" "$GH_LOG"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"
fbcfg ghcr.io/allenlarocque/spades-bio@REPLACE_WITH_DIGEST
refuses "a placeholder without @sha256: -> dies with update's SKIP reason" 'could not pin the image.*SKIP \(no pinned image: line in compose.yaml\)' \
  run project FbProj --token-from agent-old < /dev/null
check "  ...file unchanged, nothing looked up" bash -c 'cmp -s "$1" "$2" && [ ! -s "$3" ]' _ "$CFGROOT/fbproj/compose.yaml" "$T/fb.before" "$CURL_LOG"
rm -rf "$PROJHOME/FbProj" "$CFGROOT/fbproj"
# the pin step runs agent-up update, so it inherits update_guard: the launcher clone must be on main (AGENT_UP_SKIP_GIT_CHECK unset here)
"$REALGIT" -C "$NC" switch -q -c not-main
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; rm -rf "$PROJHOME/OffMain" "$CFGROOT/offmain"; : > "$CURL_LOG"; : > "$GH_LOG"
OUT=$(run project OffMain --token-from agent-old < /dev/null 2>&1); RC=$?
check "launcher clone not on main -> the pin step dies: could not pin the image: ... is not on main" \
  bash -c '[ "$1" -ne 0 ] && grep -Eq "could not pin the image: .*is not on main" <<<"$2"' _ "$RC" "$OUT"
check "  ...compose.yaml still holds the placeholder" grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:REPLACE_WITH_DIGEST" "$CFGROOT/offmain/compose.yaml"
check "  ...the vault step was not reached (no vault created)" bash -c '! grep -q "^OP: vault create" "$1" && [ ! -f "$2/vault" ]' _ "$OPLOG" "$STATE"
newstate; printf 'MACHINE_USER=agent-allen\n' > "$CFGROOT/agent-up.conf"; rm -rf "$PROJHOME/OffMain" "$CFGROOT/offmain"; : > "$CURL_LOG"; : > "$GH_LOG"
check "same, with AGENT_UP_SKIP_GIT_CHECK=1 (skips the on-main check only) -> run completes" \
  env AGENT_UP_SKIP_GIT_CHECK=1 HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" "$AN" project OffMain --token-from agent-old < /dev/null
check "  ...pinned to latest's verified digest" grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:$GISD" "$CFGROOT/offmain/compose.yaml"
check "  ...verification still ran (a registry lookup and an attestation verify)" \
  bash -c 'grep -qx "spades-gis latest" "$1" && grep -q "attestation verify oci://ghcr.io/allenlarocque/spades-gis@sha256:" "$2"' _ "$CURL_LOG" "$GH_LOG"
"$REALGIT" -C "$NC" switch -q main; "$REALGIT" -C "$NC" branch -q -D not-main
check "  (fixture: the launcher clone is back on main)" test "$("$REALGIT" -C "$NC" rev-parse --abbrev-ref HEAD)" = main
rm -rf "$PROJHOME/OffMain" "$CFGROOT/offmain"
unset AGENT_NEW_STOP_AFTER

echo "== 1Password sign-in check =="
SIGNIN_RE='not signed in\. Sign in first'
fullstate; touch "$STATE/OP_SIGNED_OUT"
refuses "verify <owner>/<repo>, signed out, no terminal: refused" "$SIGNIN_RE" run verify allen/repo9 --vault agent-p1 < /dev/null
check "  ...first op call was whoami, no op read after it" bash -c 'head -n1 "$1" | grep -qx "OP: whoami" && ! grep -q "^OP: read" "$1"' _ "$OPLOG"
fullstate; touch "$STATE/OP_SIGNED_OUT"
vo=$(run verify newproj < /dev/null 2>&1) || true
check "verify <project> reads no 1Password: not refused for sign-in" bash -c '! grep -Eq "$2" <<<"$1"' _ "$vo" "$SIGNIN_RE"
check "  ...and never calls op whoami" bash -c '! grep -q "^OP: whoami" "$1"' _ "$OPLOG"
fullstate; touch "$STATE/OP_SIGNED_OUT"
po=$(run protect allen/repo9 < /dev/null 2>&1) || true
check "protect <owner>/<repo> without --vault: not refused for sign-in" bash -c '! grep -Eq "$2" <<<"$1"' _ "$po" "$SIGNIN_RE"
check "  ...and never calls op whoami" bash -c '! grep -q "^OP: whoami" "$1"' _ "$OPLOG"
fullstate; touch "$STATE/OP_SIGNED_OUT"
refuses "protect <owner>/<repo>, signed out, no terminal: refused" "$SIGNIN_RE" run protect allen/repo9 --vault agent-p1 < /dev/null
check "  ...first op call was whoami, no op read after it" bash -c 'head -n1 "$1" | grep -qx "OP: whoami" && ! grep -q "^OP: read" "$1"' _ "$OPLOG"
fullstate; echo 4 > "$STATE/OP_WHOAMI_OK"   # signed in for the pin step (agent-new, then agent-up update), the vault and protect steps; out by the up step
rm -rf "$PROJHOME/SoProj" "$CFGROOT/soproj"
refuses "project flow, signed out at the up step: refused" "$SIGNIN_RE" run project SoProj --token-from agent-old < /dev/null
check "  ...no op call after the failed whoami (no token read)" bash -c 'tail -n1 "$1" | grep -qx "OP: whoami"' _ "$OPLOG"
check "  ...agent-up up never called" bash -c '! grep -q " up soproj" "$1"' _ "$AULOG"
rm -rf "$PROJHOME/SoProj" "$CFGROOT/soproj"
fullstate; echo 2 > "$STATE/OP_WHOAMI_OK"   # signed in for the pin step (agent-new, then agent-up update); out by the vault step
rm -rf "$PROJHOME/SoProj2" "$CFGROOT/soproj2"
OUT=$(run project SoProj2 --token-from agent-old < /dev/null 2>&1); RC=$?
check "project flow, signed out at the vault step: refused there" \
  bash -c '[ "$1" -ne 0 ] && grep -Eq "$3" <<<"$2" && grep -qF "agent-new: 1Password (1password-project-vault.md):" <<<"$2"' _ "$RC" "$OUT" "$SIGNIN_RE"
check "  ...the image was pinned first" grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:$GISD" "$CFGROOT/soproj2/compose.yaml"
check "  ...no vault created, no op call after the failed whoami" bash -c '! grep -q "^OP: vault" "$1" && [ ! -f "$2/vault" ] && tail -n1 "$1" | grep -qx "OP: whoami"' _ "$OPLOG" "$STATE"
rm -rf "$PROJHOME/SoProj2" "$CFGROOT/soproj2"
fullstate; touch "$STATE/OP_SIGNED_OUT"
rm -rf "$PROJHOME/SoProj3" "$CFGROOT/soproj3"
refuses "project flow, signed out at the pin step: refused" "$SIGNIN_RE" run project SoProj3 --token-from agent-old < /dev/null
check "  ...compose.yaml still holds the placeholder, update never ran" \
  bash -c 'grep -qx "    image: ghcr.io/allenlarocque/spades-gis@sha256:REPLACE_WITH_DIGEST" "$1" && ! grep -q "^AU: update" "$2"' _ "$CFGROOT/soproj3/compose.yaml" "$AULOG"
rm -rf "$PROJHOME/SoProj3" "$CFGROOT/soproj3"

[ "$fail" -eq 0 ] && echo "AGENT-NEW: ALL PASSED" || { echo "AGENT-NEW: FAILURES"; exit 1; }
