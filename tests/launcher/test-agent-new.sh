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
lacks(){ # $1 a log file, $2 an ERE it must not contain; a missing or unreadable log fails too
  [ -r "$1" ] || { echo "no readable log: $1"; return 1; }
  ! grep -Eq -- "$2" "$1"; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
H="$T/home"; CFGROOT="$H/.config/agent-containers"; STATE="$T/state"
mkdir -p "$H" "$CFGROOT" "$STATE" "$T/bin"
GHLOG="$T/gh.log" OPLOG="$T/op.log" GITLOG="$T/git.log" DLOG="$T/docker.log" AULOG="$T/agent-up.log" TSLOG="$T/ts.log"
export STATE GHLOG OPLOG GITLOG DLOG AULOG TSLOG
newstate(){ rm -rf "$STATE"; mkdir -p "$STATE"; : > "$GHLOG"; : > "$OPLOG"; : > "$GITLOG"; : > "$DLOG"; : > "$AULOG"; : > "$TSLOG"
  echo allen > "$STATE/login"; }

# ---- stub gh: logs every call; behavior driven by $STATE files. Writes (rulesets, refs, settings, invitations) change the
# live state, so a second run sees what the first one made. GH: is the owner (no GH_TOKEN), GH(mu): the machine user.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
# $STATE/drop-token: an ERE; a machine-user call matching it runs as the owner instead (an identity mix-up, for a test)
if [ -n "${GH_TOKEN:-}" ] && [ -s "$STATE/drop-token" ] && [[ "$*" =~ $(cat "$STATE/drop-token") ]]; then unset GH_TOKEN; fi
echo "GH${GH_TOKEN:+(mu)}: $*" >> "$GHLOG"
echo "${GH_TOKEN:-}" >> "$STATE/gh-tokens"
# the vault token may reach gh only as GH_TOKEN: any other variable carrying it is a leak
env | grep -v '^GH_TOKEN=' | grep -q fake-op-secret && env | grep -v '^GH_TOKEN=' | grep fake-op-secret | cut -d= -f1 >> "$STATE/env-leak"
last="${@: -1}"
# the machine user's call that a test lets through: $STATE/accept-gh holds an ERE matched against the arguments
accepted(){ [ -n "${GH_TOKEN:-}" ] && [ -s "$STATE/accept-gh" ] && [[ "$ARGS" =~ $(cat "$STATE/accept-gh") ]]; }
ARGS="$*"
fenced(){ case "$1" in allen-dev|fix/*|feature/*|chore/*|docs/*|test/*|ci/*|refactor/*|perf/*|revert/*|upstream/*|sync/*|experiment/*) return 1 ;; esac; }
# refs (heads/<b> | tags/<t>): the default branch, allen-dev (with $STATE/has-allen-dev) and whatever was created since
# exist; $STATE/refs-live / refs-gone record creations and deletions; $STATE/ref-exists-match (an ERE) makes names exist
ref_exists(){ grep -qxF "$1" "$STATE/refs-gone" 2>/dev/null && return 1; grep -qxF "$1" "$STATE/refs-live" 2>/dev/null && return 0
  [ -s "$STATE/ref-exists-match" ] && [[ $1 =~ $(cat "$STATE/ref-exists-match") ]] && return 0
  [ "$1" = "heads/$(cat "$STATE/default-branch" 2>/dev/null || echo main)" ] && return 0
  [ "$1" = heads/allen-dev ] && [ -f "$STATE/has-allen-dev" ]; }
rsfind(){ # $1 a ruleset id -> the ruleset-id-<name> file holding it (seeded by a test, or live/<repo>/ after a POST)
  local f; for f in "$STATE"/ruleset-id-* "$STATE"/live/*/ruleset-id-*; do
    [ -f "$f" ] && [ "$(cat "$f")" = "$1" ] && { printf '%s' "$f"; return 0; }; done; return 1; }
case "$*" in
  # pull requests: numbered from 7, each remembers its base, head and state; $STATE/fence and $STATE/gate play the rulesets
  "pr create"*) [ -f "$STATE/pr-create-fail" ] && { echo "GraphQL: something broke (createPullRequest)" >&2; exit 1; }
    "$REALGIT" log -1 --format='AUTHOR: %an <%ae> COMMITTER: %cn <%ce>' >> "$STATE/gh-author" 2>/dev/null
    a="$*"; r="${a#*-R }"; b="${a#*--base }"; h="${a#*--head }"
    n=$(( $(cat "$STATE/next-pr" 2>/dev/null || echo 6) + 1 )); echo "$n" > "$STATE/next-pr"
    echo "${b%% *}" > "$STATE/pr-base-$n"; echo "${h%% *}" > "$STATE/pr-head-$n"; echo OPEN > "$STATE/pr-state-$n"
    echo "https://github.com/${r%% *}/pull/$n" ;;
  "api -X PUT repos/"*"/pulls/"*"/merge -f merge_method=squash") n="${4%/merge}"; n="${n##*/}"; b="$(cat "$STATE/pr-base-$n" 2>/dev/null)"
    if [ -n "${GH_TOKEN:-}" ] && ! accepted && [ -f "$STATE/fence" ] && fenced "$b"; then echo "gh: Repository rule violations found for refs/heads/$b. (HTTP 405)" >&2; exit 1; fi
    echo MERGED > "$STATE/pr-state-$n" ;;
  "pr merge "[0-9]*) n="$3"; b="$(cat "$STATE/pr-base-$n" 2>/dev/null)"
    if [ -n "${GH_TOKEN:-}" ] && ! accepted && [ -f "$STATE/gate" ] && [ "$b" = "$(cat "$STATE/default-branch" 2>/dev/null || echo main)" ]; then
      case "$*" in *--admin*) echo "GraphQL: Repository rule violations found" >&2 ;; *) echo "the base branch policy prohibits the merge" >&2 ;; esac; exit 1; fi
    if [ -n "${GH_TOKEN:-}" ] && ! accepted && [ -f "$STATE/fence" ] && fenced "$b"; then echo "GraphQL: Repository rule violations found for refs/heads/$b" >&2; exit 1; fi
    [ -f "$STATE/merge-noop" ] && exit 0
    echo MERGED > "$STATE/pr-state-$n"
    case "$*" in *--delete-branch*) echo "heads/$(cat "$STATE/pr-head-$n")" >> "$STATE/refs-gone" ;; esac ;;
  "pr review "[0-9]*" --approve") [ -n "${GH_TOKEN:-}" ] && ! accepted && [ -f "$STATE/gate" ] && { echo "Review Can not approve your own pull request" >&2; exit 1; }; : ;;
  "pr view "[0-9]*" -R "*" --json state --jq .state") cat "$STATE/pr-state-$3" 2>/dev/null || echo OPEN ;;
  "pr close "[0-9]*) [ -f "$STATE/pr-close-fail" ] && { echo "gh: could not close" >&2; exit 1; }; echo CLOSED > "$STATE/pr-state-$3" ;;
  "pr checks "*) echo "gitleaks	pass" ;;
  "api user --jq .login") if [ -n "${GH_TOKEN:-}" ]; then cat "$STATE/mu-login" 2>/dev/null || echo agent-allen
                          else [ -s "$STATE/login" ] || exit 1; cat "$STATE/login"; fi ;;
  # the repository as GitHub describes it to the owner: name, admin?, owner, fork?, parent, default branch (one per line)
  "api repos/"*" --jq [.full_name"*) [ -f "$STATE/info-fail" ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    r="${2#repos/}"
    cat "$STATE/full-name" 2>/dev/null || echo "$r"
    if [ -f "$STATE/not-admin" ]; then echo false; else echo true; fi
    cat "$STATE/repo-owner" 2>/dev/null || echo "${r%%/*}"
    if [ -f "$STATE/parent" ]; then echo true; cat "$STATE/parent"; else echo false; echo; fi
    cat "$STATE/default-branch" 2>/dev/null || echo main ;;
  "api repos/"*"/collaborators/"*"/permission --jq .permission") cat "$STATE/collab-permission" 2>/dev/null || echo write ;;
  api\ repos/*/collaborators/*) [ -f "$STATE/collab-probe-fail" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    [ -f "$STATE/collab" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  api\ -X\ PUT\ repos/*/collaborators/*) r="${4#repos/}"; r="${r%/collaborators/*}"
    if [ -f "$STATE/invited-as" ]; then cp "$STATE/invited-as" "$STATE/invited"; else echo "$r" > "$STATE/invited"; fi ;;
  "api /user/repository_invitations --jq"*) [ -n "${GH_TOKEN:-}" ] || exit 1
    if [ -f "$STATE/invited" ]; then printf '[{"id": 42, "repository": {"full_name": "%s"}}]' "$(cat "$STATE/invited")"; else echo '[]'; fi | jq -r "$last" ;;
  "api -X PATCH /user/repository_invitations/42") [ -n "${GH_TOKEN:-}" ] || exit 1; touch "$STATE/collab" ;;
  "api repos/"*"/rulesets --jq"*) [ -f "$STATE/fail-repo" ] && [ "$2" = "repos/$(cat "$STATE/fail-repo")/rulesets" ] && { echo "HTTP 403: no admin on this repo" >&2; exit 1; }
    [ -f "$STATE/rulesets-list-fail" ] && { echo "HTTP 403: upgrade to Pro" >&2; exit 1; }; [ -f "$STATE/rulesets-stderr" ] && echo "warning: stray stderr line" >&2
    # answers per ruleset name: every .name=="..." in the --jq selector, first hit wins; this repo's live rulesets first
    live="$STATE/live/$(r="${2#repos/}"; echo "${r%/rulesets}" | tr / _)"
    for rn in $(grep -o '\.name==\"[^\"]*\"' <<<"$*" | sed 's/^[^"]*"//; s/"$//'); do
      [ -s "$live/ruleset-id-$rn" ] && { cat "$live/ruleset-id-$rn"; break; }
      [ -s "$STATE/ruleset-id-$rn" ] && { cat "$STATE/ruleset-id-$rn"; break; }
    done; : ;;
  "api -X POST repos/"*"/rulesets --input -") body="$(cat)"; rn="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)"
    printf '%s\n' "$body" > "$STATE/ruleset-posted-$rn"
    live="$STATE/live/$(r="${4#repos/}"; echo "${r%/rulesets}" | tr / _)"; mkdir -p "$live"
    n=$(( $(cat "$STATE/next-ruleset-id" 2>/dev/null || echo 20) + 1 )); echo "$n" > "$STATE/next-ruleset-id"
    echo "$n" > "$live/ruleset-id-$rn"; printf '%s\n' "$body" > "$live/ruleset-json-$rn" ;;
  "api -X PUT repos/"*"/rulesets/"*" --input -") body="$(cat)"; id="${4##*/}"; rn="$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' <<<"$body" | head -n1)"
    printf '%s\n' "$body" > "$STATE/ruleset-put-$id"
    # the rename takes effect: the live ruleset is now the template, under its new name
    f="$(rsfind "$id")" && { d="${f%/*}"; old="${f##*/ruleset-id-}"; rm -f "$f" "$d/ruleset-norm-$old" "$d/ruleset-json-$old"
      echo "$id" > "$d/ruleset-id-$rn"; printf '%s\n' "$body" > "$d/ruleset-json-$rn"; } ;;
  "api -X DELETE repos/"*"/rulesets/"*) echo "${4##*/}" >> "$STATE/ruleset-deleted"; f="$(rsfind "${4##*/}")" && rm -f "$f" ;;
  "api repos/"*"/rulesets/"[0-9]*" --jq"*) f="$(rsfind "${2##*/}")" || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    rn="${f##*/ruleset-id-}"; d="${f%/*}"
    # ruleset-json-<name>.later replaces the JSON after the number of reads in ruleset-later-after-<name>
    c=$(( $(cat "$d/.reads-$rn" 2>/dev/null || echo 0) + 1 )); echo "$c" > "$d/.reads-$rn"
    if [ -s "$d/ruleset-json-$rn.later" ] && [ "$c" -gt "$(cat "$d/ruleset-later-after-$rn")" ]; then jq -r "$last" "$d/ruleset-json-$rn.later"
    elif [ -s "$d/ruleset-json-$rn" ]; then jq -r "$last" "$d/ruleset-json-$rn"
    elif [ "$last" = "$NORM_JQ_SRC" ]; then cat "$d/ruleset-norm-$rn"
    elif [ "$last" = .name ]; then echo "$rn"
    else echo "stub: ruleset $rn has no JSON to answer --jq $last" >&2; exit 1; fi ;;
  "api repos/"*"/contents/.github/CODEOWNERS") [ -f "$STATE/has-codeowners" ] ;;
  "api repos/"*"/contents/.github/workflows/gitleaks.yml") [ -f "$STATE/has-gitleaks" ] ;;
  "api repos/"*"/contents/.github/dependabot.yml") [ -f "$STATE/has-dependabot" ] ;;
  "api repos/"*"/actions/permissions/workflow --jq .can_approve_pull_request_reviews") cat "$STATE/actions-approve" 2>/dev/null || echo false ;;
  "api --paginate repos/"*"/branches?per_page=100 --jq .[].name") r="${3#repos/}"; r="${r%/branches*}"
    [ -f "$STATE/branches-fail" ] && { echo "HTTP 500: branches exploded" >&2; exit 1; }
    cat "$STATE/branches-$(tr / _ <<<"$r")" 2>/dev/null || echo main ;;
  "api repos/"*"/branches/"*) b="${2#*/branches/}"
    [ -f "$STATE/branch-probe-fail" ] && { echo "gh: Server Error (HTTP 500)" >&2; exit 1; }
    case "$b" in allen-dev) [ -f "$STATE/has-allen-dev" ] ;; gh-pages) [ -f "$STATE/has-gh-pages" ] ;; *) false ;; esac \
      || { echo "gh: Branch not found (HTTP 404)" >&2; exit 1; } ;;
  "api repos/"*"/git/ref/heads/"*" --jq .object.sha") [ -f "$STATE/ref-fail" ] && { echo "HTTP 500: ref lookup exploded" >&2; exit 1; }
    [ -f "$STATE/no-commits" ] && { echo "HTTP 409: Git Repository is empty." >&2; exit 1; }
    b="${2##*/heads/}"; cat "$STATE/ref-sha-$(tr / _ <<<"$b")" 2>/dev/null || echo "sha-of-$b" ;;
  "api repos/"*"/git/ref/"*" --jq .ref") r="${2#*/git/ref/}"
    if ref_exists "$r"; then echo "refs/$r"; else echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi ;;
  "api -X POST repos/"*"/git/refs -f ref="*) [ -f "$STATE/ref-create-fail" ] && { echo "gh: Validation Failed (HTTP 422)" >&2; exit 1; }
    a="$*"; r="${a#* ref=refs/}"; r="${r%% *}"
    ref_exists "$r" && { echo "gh: Reference already exists (HTTP 422)" >&2; exit 1; }
    echo "$r" >> "$STATE/refs-live"; sed -i "\#^$r\$#d" "$STATE/refs-gone" 2>/dev/null
    echo "$*" >> "$STATE/ref-posted"
    case "$*" in *" ref=refs/heads/allen-dev "*) touch "$STATE/has-allen-dev" ;; esac ;;
  "api -X DELETE repos/"*"/git/refs/"*) r="${4#*/git/refs/}"
    if [ -s "$STATE/ref-delete-fail" ] && [[ $r == *"$(cat "$STATE/ref-delete-fail")"* ]]; then echo "gh: Server Error (HTTP 500)" >&2; exit 1; fi
    ref_exists "$r" || { echo "gh: Reference does not exist (HTTP 422)" >&2; exit 1; }
    echo "$r" >> "$STATE/refs-deleted"; echo "$r" >> "$STATE/refs-gone" ;;
  "api -X PATCH repos/"*" -F delete_branch_on_merge=false") touch "$STATE/autodelete-patched"; echo false > "$STATE/autodelete" ;;
  "api -X PATCH repos/"*" -F delete_branch_on_merge="*) echo "stub: delete_branch_on_merge must only ever be set to false" >&2; exit 1 ;;
  "api repos/"*" --jq .delete_branch_on_merge") [ -f "$STATE/autodelete-get-fail" ] && { echo "gh: Bad Gateway (HTTP 502)" >&2; exit 1; }
    cat "$STATE/autodelete" 2>/dev/null || echo true ;;
  "repo view "*" --json defaultBranchRef --jq .defaultBranchRef.name") cat "$STATE/default-branch" 2>/dev/null || echo main ;;
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
# ---- stub docker: logs; exec plan driven by $STATE/exec-plan (marker = an ERE matched against the command, first hit wins).
# Without a matching marker, the machine user's gh, git push and git ls-remote in the container run through the host's stubs
# with the container's token (outside any git repository); anything else succeeds silently.
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "DOCKER: $*" >> "$DLOG"
if [ "$1" = ps ]; then printf 'p1-agent-1\nnewproj-agent-1\n'; exit 0; fi
# docker exec -w /workspace <name> bash -lc CMD
cmd="${@: -1}"
if [ -f "$STATE/exec-plan" ]; then
  while IFS='|' read -r marker rc out; do
    [ -n "$marker" ] || continue
    if [[ $cmd =~ $marker ]]; then printf '%s\n' "$out"; exit "$rc"; fi
  done < "$STATE/exec-plan"
fi
case "$cmd" in
  "gh "*|"git push "*|"git ls-remote "*) tok=container-mu-token
    [ -s "$STATE/drop-token" ] && [[ $cmd =~ $(cat "$STATE/drop-token") ]] && tok=""   # an identity mix-up, for a test
    cd "$STATE" && GH_TOKEN="$tok" GIT_DIR=/nonexistent bash -c "$cmd"; exit ;;
esac
exit 0
STUB
chmod +x "$T/bin/docker"
# ---- fence-sim: the rulesets as GitHub applies them to a push ($@: git push's arguments). The owner (no GH_TOKEN) bypasses
# them. $STATE/fence: refs outside the free names and every tag are refused; $STATE/gate: the default branch is refused.
# $STATE/wbr: deleting or force-pushing allen-dev is refused (agent-working-branch).
# $STATE/accept-push / reject-push: an ERE on the arguments that is let through / refused for another reason.
cat > "$T/bin/fence-sim" <<'STUB'
#!/usr/bin/env bash
echo "PUSH${GH_TOKEN:+(mu)}: $*" >> "$STATE/pushes"
if [ -s "$STATE/reject-push" ] && [[ "$*" =~ $(cat "$STATE/reject-push") ]]; then
  for a in "$@"; do case "$a" in https://*) u="$a" ;; esac; done
  echo "remote: rejected by a hook" >&2; echo "error: failed to push some refs to '${u:-origin}'" >&2; exit 1; fi
acc=""; [ -s "$STATE/accept-push" ] && [[ "$*" =~ $(cat "$STATE/accept-push") ]] && acc=1
def="$(cat "$STATE/default-branch" 2>/dev/null || echo main)"
force=0 del=0 refs=()
for a in "$@"; do case "$a" in
  -f|--force|--force-with-lease|--force-with-lease=*) force=1 ;;
  -d|--delete) del=1 ;;
  -*|https://*|origin) ;;
  *) refs+=("$a") ;;
esac; done
for r in "${refs[@]}"; do
  f=$force; case "$r" in +*) f=1; r="${r#+}" ;; esac
  if [ "$del" = 1 ]; then dst="$r"; else dst="${r##*:}"; fi
  case "$dst" in refs/*) ;; *) dst="refs/heads/$dst" ;; esac
  no=""
  if [ -f "$STATE/fence" ]; then
    case "$dst" in
      refs/tags/*) no=1 ;;
      refs/heads/allen-dev) if [ -f "$STATE/wbr" ] && { [ "$del" = 1 ] || [ "$f" = 1 ]; }; then no=1; fi ;;
      refs/heads/fix/*|refs/heads/feature/*|refs/heads/chore/*|refs/heads/docs/*|refs/heads/test/*|refs/heads/ci/*|refs/heads/refactor/*|refs/heads/perf/*|refs/heads/revert/*|refs/heads/upstream/*|refs/heads/sync/*|refs/heads/experiment/*) ;;
      *) no=1 ;;
    esac
  fi
  if [ -f "$STATE/gate" ] && [ "$dst" = "refs/heads/$def" ]; then no=1; fi
  [ -n "${GH_TOKEN:-}" ] || no=""   # the owner bypasses every ruleset
  if [ -n "$no" ] && [ -z "$acc" ]; then
    echo "remote: error: GH013: Repository rule violations found for $dst." >&2
    echo " ! [remote rejected] ${r%%:*} -> $dst (push declined due to repository rule violations)" >&2; exit 1
  fi
  case "$dst" in refs/heads/*) [ "$del" = 1 ] || echo "pushed-by-mu" > "$STATE/ref-sha-$(tr / _ <<<"${dst#refs/heads/}")" ;; esac
  if [ "$del" = 1 ]; then echo "${dst#refs/}" >> "$STATE/refs-gone"
  else echo "${dst#refs/}" >> "$STATE/refs-live"; sed -i "\#^${dst#refs/}\$#d" "$STATE/refs-gone" 2>/dev/null; fi
done
exit 0
STUB
chmod +x "$T/bin/fence-sim"
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
         db="$(cat "$STATE/default-branch" 2>/dev/null || echo main)"
         org="$(cat "$STATE/clone-origin" 2>/dev/null || printf '%s' "${@: -2:1}")"
         mkdir -p "${@: -1}"; cd "${@: -1}" && "$REALGIT" init -q -b main && "$REALGIT" commit -q --allow-empty -m seed && "$REALGIT" remote add origin "$org" && "$REALGIT" update-ref refs/remotes/origin/main HEAD \
           && "$REALGIT" update-ref "refs/remotes/origin/$db" HEAD && { [ ! -f "$STATE/has-allen-dev" ] || "$REALGIT" update-ref refs/remotes/origin/allen-dev HEAD; } ;;
  fetch) # FETCH_HEAD: the seed commit, or for allen-dev a commit on top of it
         if gd="$("$REALGIT" rev-parse --git-dir 2>/dev/null)"; then
           c="$("$REALGIT" rev-list --max-parents=0 HEAD | tail -n1)"
           case "$*" in *refs/heads/allen-dev*) c="$("$REALGIT" commit-tree -p "$c" -m allen-dev "$c^{tree}")" ;; esac
           printf '%s\t\tfetched by the stub\n' "$c" > "$gd/FETCH_HEAD"
         fi; exit 0 ;;
  ls-remote) case "$*" in *" refs/heads/allen-dev")
               [ -f "$STATE/ls-remote-fail" ] && { echo "fatal: unable to access the remote" >&2; exit 128; }
               [ -f "$STATE/has-allen-dev" ] || exit 2
               echo "3333333333333333333333333333333333333333	refs/heads/allen-dev" ;; esac; exit 0 ;;
  push)  [ -s "$STATE/drop-token" ] && [[ "push $*" =~ $(cat "$STATE/drop-token") ]] && unset GH_TOKEN   # an identity mix-up, for a test
         fence-sim "${@:2}" || exit 1
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
# the normalisation agent-new asks gh to apply to a ruleset: the gh stub answers it from the ruleset's JSON (or a seeded string)
NORM_JQ_SRC="$(sed -n "/^NORM_JQ='/,/^\] | join/p" "$AN" | sed "1s/^NORM_JQ='//; \$s/'\$//")"; export NORM_JQ_SRC
[ -n "$NORM_JQ_SRC" ] || { echo "FAIL: could not read NORM_JQ from $AN"; exit 1; }
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
newstate
refuses "project, no MACHINE_USER anywhere: dies" 'no machine user known' run project NoMu < /dev/null
check "  ...before any repo is looked up or created" lacks "$GHLOG" 'repo (view|create|clone)'
check "  ...and nothing after the owner check ran" lacks "$AULOG" '.'
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
check "  invite was PUT as owner, for Write"  grep -q '^GH: api -X PUT repos/allen/repo1/collaborators/agent-allen -f permission=push$' "$GHLOG"
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
EXPECT_NORM='branch|active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:false|gitleaks|refs:~DEFAULT_BRANCH/|strict:false|merge,rebase,squash|upd:-'
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
echo 'branch|active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:false|gitleaks|refs:~DEFAULT_BRANCH/refs/heads/main|strict:false|merge,rebase,squash|upd:-' > "$STATE/ruleset-norm-protect-main"
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
FENCE_NORM='branch|active|RepositoryRole:5:always|creation,deletion,non_fast_forward,update|pr:-||refs:~ALL/refs/heads/allen-dev,refs/heads/chore/**,refs/heads/ci/**,refs/heads/docs/**,refs/heads/experiment/**,refs/heads/feature/**,refs/heads/fix/**,refs/heads/perf/**,refs/heads/refactor/**,refs/heads/revert/**,refs/heads/sync/**,refs/heads/test/**,refs/heads/upstream/**|strict:-||upd:false'
TAGS_NORM='tag|active|RepositoryRole:5:always|creation,deletion,update|pr:-||refs:~ALL/|strict:-||upd:false'
newstate; touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"
check "no fence: protect succeeds"            run protect allen/repo1 --vault agent-p1 --main-gate
check "  agent-fence POSTed"                  test -s "$STATE/ruleset-posted-agent-fence"
check "  agent-fence-tags POSTed"             test -s "$STATE/ruleset-posted-agent-fence-tags"
check "  four POSTs: both fences, the working branch's ruleset and protect-main" test "$(grep -c 'POST repos/allen/repo1/rulesets' "$GHLOG")" -eq 4
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
WB_NORM='branch|active|RepositoryRole:5:always|deletion,non_fast_forward|pr:-||refs:refs/heads/allen-dev/|strict:-||upd:-'
for n in agent-fence agent-fence-tags protect-main agent-working-branch; do
  case "$n" in agent-fence) want="$FENCE_NORM" ;; agent-fence-tags) want="$TAGS_NORM" ;; agent-working-branch) want="$WB_NORM" ;; *) want="$EXPECT_NORM" ;; esac
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
echo 7 > "$STATE/ruleset-id-main"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm-main"
OUT=$(run protect allen/repo1 --vault agent-p1 --main-gate 2>&1)
check "live ruleset named main counts as protect-main: SKIP" grep -q 'SKIP.*ruleset protect-main' <<<"$OUT"
check "  protect-main not POSTed"             test ! -f "$STATE/ruleset-posted-protect-main"
check "  creation message cites the runbook only for protect-main" bash -c '! grep -q "creating ruleset agent-fence.*machine-user" <<<"$1" && grep -q "creating ruleset agent-fence on" <<<"$1"' _ "$OUT"

echo "== the working branch's ruleset =="
newstate; touch "$STATE/collab"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "fresh repo: agent-working-branch POSTed"         bash -c '[ "$1" -eq 0 ] && [ -s "$2" ]' _ "$rc" "$STATE/ruleset-posted-agent-working-branch"
check "  it covers exactly refs/heads/allen-dev"        grep -q '"include": \["refs/heads/allen-dev"\], "exclude": \[\]' "$STATE/ruleset-posted-agent-working-branch"
check "  rules: deletion and non_fast_forward only"     bash -c 'grep -q "\"type\": \"deletion\"" "$1" && grep -q "\"type\": \"non_fast_forward\"" "$1" && [ "$(grep -o "\"type\":" "$1" | wc -l)" -eq 2 ]' _ "$STATE/ruleset-posted-agent-working-branch"
check "  the repository admin bypasses it, mode always" grep -q '"bypass_actors": \[{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}\]' "$STATE/ruleset-posted-agent-working-branch"
check "  after allen-dev is created, before auto-delete is switched off" \
  bash -c 'a=$(grep -n "POST repos/allen/repo1/git/refs" "$1" | cut -d: -f1); b=$(grep -n "POST repos/allen/repo1/rulesets" "$1" | tail -n1 | cut -d: -f1); c=$(grep -n "PATCH repos/allen/repo1 -F delete_branch_on_merge=false" "$1" | cut -d: -f1); [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]' _ "$GHLOG"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
check "allen-dev exists already: the ruleset is still ensured" run protect allen/repo1 --vault agent-p1
check "  POSTed"                                        test -s "$STATE/ruleset-posted-agent-working-branch"
newstate; touch "$STATE/collab"
check "--no-working-branch: no working-branch ruleset" run protect allen/repo1 --vault agent-p1 --no-working-branch
check "  not POSTed"                                    test ! -f "$STATE/ruleset-posted-agent-working-branch"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"; echo 10 > "$STATE/ruleset-id-agent-working-branch"; echo "$WB_NORM" > "$STATE/ruleset-norm-agent-working-branch"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "live working-branch ruleset equals the template: SKIP" grep -q 'SKIP.*ruleset agent-working-branch' <<<"$OUT"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"; echo 10 > "$STATE/ruleset-id-agent-working-branch"; echo "${WB_NORM/'branch|active|RepositoryRole:5:always|'/'branch|active||'}" > "$STATE/ruleset-norm-agent-working-branch"
refuses "working-branch ruleset with an EMPTY bypass list: refused, not modified" 'ruleset agent-working-branch on allen/repo1 differs from the template' run protect allen/repo1 --vault agent-p1
check "  no write to it"                                lacks "$GHLOG" 'api -X (PUT|DELETE) repos/allen/repo1/rulesets'
check "  nothing POSTed"                                test ! -f "$STATE/ruleset-posted-agent-working-branch"

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
newstate; touch "$STATE/collab"; echo false > "$STATE/autodelete"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "auto-delete already false: SKIP"                grep -q 'SKIP.*does not delete merged branches automatically' <<<"$OUT"
check "  no PATCH"                                     test ! -f "$STATE/autodelete-patched"
newstate; touch "$STATE/collab"; echo true > "$STATE/autodelete"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "auto-delete true: exits 0"                      test "$rc" -eq 0
check "  says it is turning it off"                    grep -q 'turning off delete_branch_on_merge for allen/repo1 (it would delete allen-dev when it is promoted)' <<<"$OUT"
check "  one PATCH, delete_branch_on_merge=false"      test "$(grep -c 'PATCH repos/allen/repo1 -F delete_branch_on_merge=false' "$GHLOG")" -eq 1
check "  no PATCH to true"                             lacks "$GHLOG" 'delete_branch_on_merge=true'
for st in true false; do
  newstate; touch "$STATE/collab"; echo "$st" > "$STATE/autodelete"
  run protect allen/repo1 --vault agent-p1 >/dev/null 2>&1; rc=$?
  : > "$GHLOG"; rm -f "$STATE/autodelete-patched"
  OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc2=$?
  check "second run starting from $st: exits 0, no PATCH, no POST" bash -c '[ "$1" -eq 0 ] && [ "$2" -eq 0 ] && [ ! -f "$3" ] && ! grep -qE "PATCH|POST" "$4"' _ "$rc" "$rc2" "$STATE/autodelete-patched" "$GHLOG"
done
newstate; touch "$STATE/collab" "$STATE/autodelete-get-fail"
run protect allen/repo1 --vault agent-p1 >/dev/null 2>&1; rc=$?
check "setting unreadable: dies, no PATCH"             bash -c '[ "$1" -ne 0 ] && [ ! -f "$2" ]' _ "$rc" "$STATE/autodelete-patched"
newstate; touch "$STATE/collab"
check "--no-working-branch accepted"                   run protect allen/repo1 --vault agent-p1 --no-working-branch
check "  auto-delete still switched off"               test -f "$STATE/autodelete-patched"
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

check "  creating protect-main cites the runbook step"    bash -c 'grep -q "creating ruleset protect-main on allen/repo1 (machine-user-and-rulesets.md step 4)" <<<"$1"' _ "$OUT"
newstate; touch "$STATE/collab" "$STATE/ref-fail"
refuses "head lookup fails for another reason: gh error shown" 'ref lookup exploded' run protect allen/repo1 --vault agent-p1
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1) || true
check "  and it is not blamed on an empty repo"           bash -c '! grep -q "has no commits" <<<"$1"' _ "$OUT"

echo "== fence: migrate =="
OLD_FORK='branch|active|RepositoryRole:5:always|creation,deletion,non_fast_forward,update|pr:-||refs:~ALL/refs/heads/feature/**,refs/heads/fix/**|strict:-||upd:false'
OLD_FORK_TAGS='tag|active|RepositoryRole:5:always|creation,deletion,update|pr:-||refs:~ALL/|strict:-||upd:false'
migstate(){ newstate; touch "$STATE/collab" "$STATE/has-allen-dev"; }
fencepair(){ echo 8 > "$STATE/ruleset-id-agent-fence"; echo "$FENCE_NORM" > "$STATE/ruleset-norm-agent-fence"
  echo 9 > "$STATE/ruleset-id-agent-fence-tags"; echo "$TAGS_NORM" > "$STATE/ruleset-norm-agent-fence-tags"; }
oldfork(){ echo 4 > "$STATE/ruleset-id-protect-fork"; echo "${1:-$OLD_FORK}" > "$STATE/ruleset-norm-protect-fork"; }
oldtags(){ echo 5 > "$STATE/ruleset-id-protect-fork-tags"; echo "${1:-$OLD_FORK_TAGS}" > "$STATE/ruleset-norm-protect-fork-tags"; }
NOPUT='api -X PUT repos/allen/repo1/rulesets'
migstate; oldfork
OUT=$(run protect allen/repo1 --vault agent-p1 --migrate 2>&1); rc=$?
check "old protect-fork + --migrate: protect succeeds"  test "$rc" -eq 0
check "  one PUT, to its id"                             test "$(grep -c 'api -X PUT repos/allen/repo1/rulesets/' "$GHLOG")" -eq 1
check "  the PUT went to ruleset 4"                      grep -q 'api -X PUT repos/allen/repo1/rulesets/4 ' "$GHLOG"
check "  its body names agent-fence"                     grep -q '"name": *"agent-fence"' "$STATE/ruleset-put-4"
check "  agent-fence not POSTed beside it"               test ! -f "$STATE/ruleset-posted-agent-fence"
check "  prints the free names before"                   grep -qx 'agent-new:   free names before: fix/\*\*, feature/\*\*' <<<"$OUT"
check "  ...and after"                                   grep -qx 'agent-new:   free names after:  allen-dev, fix/\*\*, feature/\*\*, chore/\*\*, docs/\*\*, test/\*\*, ci/\*\*, refactor/\*\*, perf/\*\*, revert/\*\*, upstream/\*\*, sync/\*\*, experiment/\*\*' <<<"$OUT"
: > "$GHLOG"
check "  a second --migrate run changes nothing"         run protect allen/repo1 --vault agent-p1 --migrate
check "  ...(no POST, PUT, PATCH or DELETE)"             lacks "$GHLOG" 'api -X (POST|PUT|PATCH|DELETE) '
migstate; oldtags
check "old protect-fork-tags + --migrate: succeeds"     run protect allen/repo1 --vault agent-p1 --migrate
check "  PUT to its id naming agent-fence-tags"          grep -q '"name": *"agent-fence-tags"' "$STATE/ruleset-put-5"
check "  agent-fence-tags not POSTed"                    test ! -f "$STATE/ruleset-posted-agent-fence-tags"
migstate; oldfork "${OLD_FORK/'refs/heads/fix/**'/'refs/heads/extra/**,refs/heads/fix/**'}"
refuses "protect-fork with a third exclude + --migrate: refused" 'refusing to modify' run protect allen/repo1 --vault agent-p1 --migrate
check "  no PUT"                                         lacks "$GHLOG" "$NOPUT"
migstate; oldtags "${OLD_FORK_TAGS/'refs:~ALL/'/'refs:~ALL/refs/tags/x'}"
refuses "altered protect-fork-tags + --migrate: refused" 'refusing to modify' run protect allen/repo1 --vault agent-p1 --migrate
check "  no PUT"                                         lacks "$GHLOG" "$NOPUT"
migstate; oldfork; oldtags "${OLD_FORK_TAGS/'creation,deletion,update'/'deletion,update'}"
refuses "protect-fork in the old shape, protect-fork-tags altered + --migrate: refused" 'protect-fork-tags on allen/repo1 is not the shape --migrate renames' run protect allen/repo1 --vault agent-p1 --migrate
check "  neither is changed (both checked before the first PUT)" lacks "$GHLOG" "$NOPUT"
migstate; oldfork "${OLD_FORK/'upd:false'/'upd:true'}"
refuses "old protect-fork whose update rule allows fetch-and-merge + --migrate: refused" 'refusing to modify' run protect allen/repo1 --vault agent-p1 --migrate
migstate; oldfork
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "old protect-fork without --migrate: exits 0"        test "$rc" -eq 0
check "  warning names --migrate"                         grep -q 'WARNING.*older, narrower.*--migrate' <<<"$OUT"
check "  warning says the agent is still limited to fix/ and feature/" grep -q 'WARNING.*fix/.*feature/' <<<"$OUT"
check "  no PUT"                                          lacks "$GHLOG" "$NOPUT"
check "  no agent-fence created beside it (a later --migrate stays possible)" test ! -f "$STATE/ruleset-posted-agent-fence"
check "  agent-fence-tags is still created"               test -s "$STATE/ruleset-posted-agent-fence-tags"
check "  the rest still runs (auto-delete)"               test -f "$STATE/autodelete-patched"
for mig in none --migrate; do
  margs=(); [ "$mig" = none ] || margs=("$mig")
  migstate; fencepair; oldfork; oldtags
  OUT=$(run protect allen/repo1 --vault agent-p1 "${margs[@]}" 2>&1); rc=$?
  check "agent-fence and protect-fork both exist ($mig): protect exits 0" test "$rc" -eq 0
  check "  warns protect-fork must be removed by hand"   grep -q 'WARNING.*protect-fork.*by hand' <<<"$OUT"
  check "  warns protect-fork-tags must be removed by hand" grep -q 'WARNING.*protect-fork-tags.*by hand' <<<"$OUT"
  check "  no PUT"                                       lacks "$GHLOG" "$NOPUT"
done

echo "== fence: retiring the main gate =="
# a pseudo-terminal: confirm takes its answer only from a terminal; $1 is what is typed (printf format)
runtty(){ local typed="$1"; shift
  printf "$typed" | HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" SHELL=/bin/bash \
    script -qec "$(printf '%q ' "$AN" "$@")" /dev/null | tr -d '\r'; return "${PIPESTATUS[1]}"; }
pmjson(){ # $1 name, $2 include list, $3 exclude list, $4 target: a main-gate ruleset as GitHub returns it
  printf '{"id": 0, "name": "%s", "target": "%s", "enforcement": "active", "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}], "conditions": {"ref_name": {"include": %s, "exclude": %s}}, "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]}\n' \
    "$1" "${4:-branch}" "${2:-[\"~DEFAULT_BRANCH\"]}" "${3:-[]}"; }
gate(){ echo "$2" > "$STATE/ruleset-id-$1"; pmjson "$1" "${@:3}" > "$STATE/ruleset-json-$1"; }   # $1 name, $2 id, then pmjson's $2..
retstate(){ migstate; fencepair; }
retstate; gate protect-main 7
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "protect-main + --retire-main-gate, typed y at a terminal: exits 0" test "$rc" -eq 0
check "  prints the ruleset and asks"                     grep -q "delete ruleset 'protect-main' on allen/repo1? \[y/N\]" <<<"$OUT"
check "  exactly one DELETE, of its id"                   test "$(cat "$STATE/ruleset-deleted")" = 7
check "  DELETE comes after the fence calls"              bash -c 'a=$(grep -n "rulesets/9 --jq" "$1" | head -n1 | cut -d: -f1); b=$(grep -n "api -X DELETE" "$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$GHLOG"
check "  the ruleset (name, target, include, exclude) is read again right before the DELETE" bash -c 'tail -n4 "$1" | head -n3 | grep -q "rulesets/7 --jq \[.name, .target" && tail -n2 "$1" | grep -q "api -X DELETE repos/allen/repo1/rulesets/7"' _ "$(grep -v collaborators "$GHLOG" > "$T/ghlog.nocollab"; echo "$T/ghlog.nocollab")"
check "  describes it in plain words, not the internal string" bash -c 'grep -qF "applies to: the default branch" <<<"$1" && grep -qF "who may bypass it: repository admins, through a pull request only" <<<"$1" && grep -qF "also blocks: deleting the branch, force pushes" <<<"$1" && grep -qF "requires: no pull request; no checks" <<<"$1" && ! grep -qF "RepositoryRole:5:" <<<"$1"' _ "$OUT"
retstate; echo 7 > "$STATE/ruleset-id-protect-main"
cat > "$STATE/ruleset-json-protect-main" <<'JSON'
{"id": 7, "name": "protect-main", "target": "branch", "enforcement": "active",
 "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "rules": [{"type": "deletion"}, {"type": "non_fast_forward"},
  {"type": "pull_request", "parameters": {"required_approving_review_count": 1, "dismiss_stale_reviews_on_push": true, "require_code_owner_review": true, "require_last_push_approval": false}},
  {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": false, "required_status_checks": [{"context": "gitleaks"}, {"context": "build-test"}]}}]}
JSON
OUT=$(runtty 'n\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "full protect-main, answered n: exits 0, nothing deleted" bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ]' _ "$rc" "$STATE/ruleset-deleted"
check "  the plain description, line by line" bash -c 'for l in "ruleset '"'"'protect-main'"'"' on allen/repo1:" "  applies to: the default branch" "  requires: a pull request with 1 approval; these checks: build-test, gitleaks" "  also blocks: deleting the branch, force pushes" "  who may bypass it: repository admins, through a pull request only"; do grep -qxF "agent-new: $l" <<<"$1" || { echo "missing: $l" >&2; exit 1; }; done; ! grep -qF "RepositoryRole:5:" <<<"$1"; a=$(grep -n "applies to" <<<"$1" | cut -d: -f1); b=$(grep -n "delete ruleset" <<<"$1" | cut -d: -f1); [ "$a" -lt "$b" ]' _ "$OUT"
for typed in 'n\n' '' 'yes please\n'; do
  retstate; gate protect-main 7
  OUT=$(runtty "$typed" protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
  check "typed '${typed%\\n}' at the terminal: exit 0, nothing deleted" bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ]' _ "$rc" "$STATE/ruleset-deleted"
done
retstate; gate protect-main 7
OUT=$(runtty 'y\004\004' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "typed y, then end of input without ENTER: nothing deleted" bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ]' _ "$rc" "$STATE/ruleset-deleted"
retstate; gate protect-main 7; pmjson protect-main '["~ALL"]' > "$STATE/ruleset-json-protect-main.later"; echo 2 > "$STATE/ruleset-later-after-protect-main"
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "ruleset changed between the prompt and the DELETE: dies, nothing deleted" bash -c '[ "$1" -ne 0 ] && grep -q "changed while you answered: nothing was deleted" <<<"$2" && [ ! -f "$3" ]' _ "$rc" "$OUT" "$STATE/ruleset-deleted"
retstate; gate protect-main 7
OUT=$(run protect allen/repo1 --vault agent-p1 --retire-main-gate </dev/null 2>&1); rc=$?
check "stdin not a terminal: exit 0"                      test "$rc" -eq 0
check "  no DELETE"                                       test ! -f "$STATE/ruleset-deleted"
check "  warns NOT deleted"                               grep -q 'WARNING.*NOT deleted' <<<"$OUT"
retstate; gate protect-main 7
OUT=$(printf 'y\n' | run protect allen/repo1 --vault agent-p1 --retire-main-gate 2>&1); rc=$?
check "y piped in (not a terminal): nothing deleted"      bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ]' _ "$rc" "$STATE/ruleset-deleted"
retstate; gate protect-main 7
OUT=$(AGENT_NEW_CONFIRM=y run protect allen/repo1 --vault agent-p1 --retire-main-gate </dev/null 2>&1)
check "AGENT_NEW_CONFIRM=y in the environment answers nothing" test ! -f "$STATE/ruleset-deleted"
retstate; gate protect-main 7
refuses "--retire-main-gate with --main-gate: usage error" 'cannot be used together' run protect allen/repo1 --vault agent-p1 --retire-main-gate --main-gate
check "  no gh call"                                      bash -c '[ ! -s "$1" ]' _ "$GHLOG"
retstate; gate main 6
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "ruleset named main: offered and deleted"           bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2")" = 6 ]' _ "$rc" "$STATE/ruleset-deleted"
check "  prompt names it main"                            grep -q "delete ruleset 'main' on allen/repo1" <<<"$OUT"
retstate; gate protect-main 7; gate main 6
OUT=$(runtty 'n\ny\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "protect-main and main both present: each asked separately" bash -c '[ "$(grep -c "delete ruleset" <<<"$1")" -eq 2 ] && grep -q "delete ruleset .protect-main." <<<"$1" && grep -q "delete ruleset .main." <<<"$1"' _ "$OUT"
check "  n for protect-main, y for main: only main deleted" bash -c '[ "$1" -eq 0 ] && [ "$(cat "$2")" = 6 ]' _ "$rc" "$STATE/ruleset-deleted"
for bad in 'include ["~DEFAULT_BRANCH","refs/heads/x"]' 'exclude ["refs/heads/x"]' 'target tag' 'include ["refs/heads/main"]'; do
  retstate
  case "$bad" in include*) gate protect-main 7 "${bad#include }" ;; exclude*) gate protect-main 7 '["~DEFAULT_BRANCH"]' "${bad#exclude }" ;; *) gate protect-main 7 '["~DEFAULT_BRANCH"]' '[]' tag ;; esac
  OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
  check "protect-main with $bad: left alone, warned"     bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ] && grep -q "WARNING: ruleset protect-main on allen/repo1 does not apply to just the default branch" <<<"$3" && ! grep -q "delete ruleset" <<<"$3"' _ "$rc" "$STATE/ruleset-deleted" "$OUT"
done
retstate; gate protect-main 7
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --migrate); rc=$?
check "--migrate alone never offers to delete the main gate" bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ] && ! grep -q "delete ruleset" <<<"$3"' _ "$rc" "$STATE/ruleset-deleted" "$OUT"
retstate; gate protect-main 7
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1); rc=$?
check "no flag: never deleted"                            bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ]' _ "$rc" "$STATE/ruleset-deleted"
migstate; gate protect-main 7; touch "$STATE/rulesets-list-fail"
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "--retire-main-gate, fence cannot be created: refused, no DELETE" bash -c '[ "$1" -ne 0 ] && grep -q "could not list rulesets" <<<"$2" && ! grep -q "api -X DELETE" "$3"' _ "$rc" "$OUT" "$GHLOG"
retstate; echo "${FENCE_NORM/'refs/heads/sync/**,'/}" > "$STATE/ruleset-norm-agent-fence"; gate protect-main 7
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "--retire-main-gate, fence differs from template: refused, no DELETE" bash -c '[ "$1" -ne 0 ] && grep -q "refusing to modify" <<<"$2" && [ ! -f "$3" ]' _ "$rc" "$OUT" "$STATE/ruleset-deleted"
migstate; oldfork; gate protect-main 7
OUT=$(runtty 'y\n' protect allen/repo1 --vault agent-p1 --retire-main-gate); rc=$?
check "--retire-main-gate while the old protect-fork stands in for the fence: not retired" bash -c '[ "$1" -eq 0 ] && [ ! -f "$2" ] && grep -q "WARNING: .*not retiring the main gate" <<<"$3"' _ "$rc" "$STATE/ruleset-deleted" "$OUT"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/one allen/two --vault agent-p1 --retire-main-gate </dev/null 2>&1)
check "--retire-main-gate with two repos: warned once that it applies to each" test "$(grep -c 'WARNING: --retire-main-gate applies to every repo named' <<<"$OUT")" -eq 1
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/one allen/two --vault agent-p1 --main-gate 2>&1)
check "--main-gate with two repos: warned once"           test "$(grep -c 'WARNING: --main-gate applies to every repo named' <<<"$OUT")" -eq 1
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/one --vault agent-p1 --main-gate 2>&1)
check "--main-gate with one repo: no such warning"        bash -c '! grep -q "applies to every repo" <<<"$1"' _ "$OUT"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/one --vault agent-p1 --require build-test 2>&1); rc=$?
check "--require without --main-gate: warned that it is ignored" bash -c '[ "$1" -eq 0 ] && grep -q "WARNING: --require is ignored without --main-gate" <<<"$2"' _ "$rc" "$OUT"

echo "== fence: several repos =="
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"; echo allen/two > "$STATE/fail-repo"
OUT=$(run protect allen/one allen/two allen/three --vault agent-p1 2>&1); rc=$?
check "three repos, the second failing: exit non-zero"     test "$rc" -ne 0
check "  first repo's fence POSTed"                         grep -q 'POST repos/allen/one/rulesets' "$GHLOG"
check "  third repo's fence POSTed"                         grep -q 'POST repos/allen/three/rulesets' "$GHLOG"
check "  second repo got no POST"                           bash -c '! grep -q "POST repos/allen/two/" "$1"' _ "$GHLOG"
check "  protect: ok allen/one"                                 grep -q '^agent-new: protect: ok allen/one$' <<<"$OUT"
check "  protect: ok allen/three"                               grep -q '^agent-new: protect: ok allen/three$' <<<"$OUT"
check "  protect: FAILED allen/two"                             grep -q '^agent-new: protect: FAILED allen/two$' <<<"$OUT"
check "  exactly one FAILED line"                           test "$(grep -c 'protect: FAILED' <<<"$OUT")" -eq 1
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/one allen/two allen/three --vault agent-p1 2>&1); rc=$?
check "three repos all fine: exit 0"                        test "$rc" -eq 0
check "  three protect: ok lines"                           test "$(grep -c 'protect: ok' <<<"$OUT")" -eq 3
check "  no FAILED line"                                    bash -c '! grep -q "protect: FAILED" <<<"$1"' _ "$OUT"
check "  op read ran once for three repos"                  test "$(grep -c '^OP: read' "$OPLOG")" -eq 1
newstate
OUT=$(run protect allen/one allen/two allen/three --vault agent-p1 2>&1); rc=$?
check "three repos, machine user not yet invited: exit 0"   test "$rc" -eq 0
check "  the vault token is read exactly once"              test "$(grep -c '^OP: read' "$OPLOG")" -eq 1
check "  ...and used: an invitation accepted as the machine user" grep -q '^GH(mu): api -X PATCH /user/repository_invitations/42' "$GHLOG"
newstate
refuses "protect a/b notarepo: refused"                     'protect wants <owner>/<repo>' run protect a/b notarepo
check "  no gh call for a/b"                                bash -c '! grep -q "a/b" "$1"' _ "$GHLOG"
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"
OUT=$(run protect allen/solo --vault agent-p1 2>&1); rc=$?
check "one repo: exit 0"                                    test "$rc" -eq 0
check "  one protect: ok line"                              test "$(grep -c 'protect: ok' <<<"$OUT")" -eq 1
newstate; touch "$STATE/collab" "$STATE/has-allen-dev"; echo allen/solo > "$STATE/fail-repo"
OUT=$(run protect allen/solo --vault agent-p1 2>&1); rc=$?
check "one repo failing: exit non-zero"                     test "$rc" -ne 0

echo "== protect: whose repository, the order of the steps, the machine user's access =="
WRITES='api -X (POST|PUT|PATCH|DELETE) '
newstate
refuses "owner starting with a non-alphanumeric: refused"   'protect wants <owner>/<repo>' run protect _x/repo1
refuses "repo named ..: refused"                            'protect wants <owner>/<repo>' run protect allen/..
check "  no gh call"                                        bash -c '[ ! -s "$1" ]' _ "$GHLOG"
newstate; touch "$STATE/collab"; echo someone-else > "$STATE/repo-owner"
refuses "repo owned by another account: refused"            'only sets up repositories you own' run protect allen/repo1 --vault agent-p1
check "  nothing written"                                   lacks "$GHLOG" "$WRITES"
newstate; touch "$STATE/collab" "$STATE/not-admin"
refuses "you are not an admin of the repo: refused"         'only sets up repositories you own' run protect allen/repo1 --vault agent-p1
check "  nothing written"                                   lacks "$GHLOG" "$WRITES"
newstate; touch "$STATE/info-fail"
refuses "repo lookup fails: refused with gh's error"        'could not read allen/repo1 on GitHub as you: gh: Not Found' run protect allen/repo1
check "  nothing written"                                   lacks "$GHLOG" "$WRITES"
newstate; touch "$STATE/collab"; echo Allen/Repo1 > "$STATE/full-name"; echo Allen > "$STATE/repo-owner"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "GitHub spells owner and repo differently: accepted"  test "$rc" -eq 0
check "  every later call uses GitHub's spelling"           bash -c 'grep -q "POST repos/Allen/Repo1/rulesets" "$1" && ! grep -q "repos/allen/repo1/" "$1"' _ "$GHLOG"
for d in feature/x allen-dev; do
  newstate; touch "$STATE/collab"; echo "$d" > "$STATE/default-branch"
  refuses "default branch $d: refused"                      "default branch $d of allen/repo1 would be outside the fence" run protect allen/repo1 --vault agent-p1
  check "  nothing written"                                 lacks "$GHLOG" "$WRITES"
done
newstate; touch "$STATE/collab"; echo admin > "$STATE/collab-permission"
refuses "machine user is a collaborator with admin: refused" 'must have Write, not Admin or Maintain' run protect allen/repo1 --vault agent-p1
newstate; echo someone-else > "$STATE/mu-login"
refuses "vault token for another login: refused"            "for 'someone-else', not the machine user 'agent-allen'" run protect allen/repo1 --vault agent-p1
check "  no invitation sent"                                lacks "$GHLOG" 'collaborators/'
check "  nothing written"                                   lacks "$GHLOG" "$WRITES"
newstate; touch "$STATE/collab-probe-fail"
refuses "collaborator lookup fails (not a 404): refused with gh's error" 'could not tell whether agent-allen is a collaborator on allen/repo1: gh: Server Error' run protect allen/repo1 --vault agent-p1
check "  no invitation sent"                                lacks "$GHLOG" 'PUT repos/allen/repo1/collaborators'
newstate
OUT=$(MU_TOK=inherited VTOK=inherited tok=inherited s=inherited REPLY=inherited run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "token variables exported by the caller: the token still reaches gh only as GH_TOKEN" bash -c '[ "$1" -eq 0 ] && [ ! -s "$2" ] && grep -q fake-op-secret "$3"' _ "$rc" "$STATE/env-leak" "$STATE/gh-tokens"
newstate; echo ALLEN/REPO1 > "$STATE/invited-as"
check "invitation listed under another spelling: accepted"  run protect allen/repo1 --vault agent-p1
check "  PATCHed as the machine user"                       grep -q '^GH(mu): api -X PATCH /user/repository_invitations/42' "$GHLOG"
newstate; touch "$STATE/collab" "$STATE/autodelete-get-fail"
refuses "auto-delete setting cannot be read: refused with gh's error" 'could not read the settings of allen/repo1: gh: Bad Gateway' run protect allen/repo1 --vault agent-p1
check "  no PATCH"                                          test ! -f "$STATE/autodelete-patched"
newstate; touch "$STATE/collab" "$STATE/branch-probe-fail"
refuses "allen-dev lookup fails (not a 404): refused with gh's error" 'could not tell whether allen-dev exists on allen/repo1: gh: Server Error' run protect allen/repo1 --vault agent-p1
check "  no branch created"                                 lacks "$GHLOG" 'git/refs'
newstate; touch "$STATE/rulesets-list-fail"
refuses "fence cannot be set up: refused"                   'could not list rulesets' run protect allen/repo1 --vault agent-p1
check "  no invitation sent"                                lacks "$GHLOG" 'collaborators/'
newstate
run protect allen/repo1 --vault agent-p1 >/dev/null 2>&1
check "fresh repo: the invitation is the last write to the repo" \
  bash -c 'w=$(grep -E "api -X (POST|PUT|PATCH|DELETE) repos/" "$1"); [ "$(grep -c . <<<"$w")" -ge 5 ] && tail -n1 <<<"$w" | grep -q "PUT repos/allen/repo1/collaborators/agent-allen"' _ "$GHLOG"
: > "$GHLOG"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "second protect run on the same repo: exit 0"         test "$rc" -eq 0
check "  changes nothing (no POST, PUT, PATCH or DELETE)"   lacks "$GHLOG" "$WRITES"
check "  every step reported done"                          test "$(grep -c 'SKIP (done)' <<<"$OUT")" -ge 5
newstate
refuses "shell tracing on: refused"                         'refusing to run with shell tracing on' env HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" bash -x "$AN" protect allen/repo1
check "  ...before any gh call"                             bash -c '[ ! -s "$1" ]' _ "$GHLOG"
newstate; touch "$STATE/collab" "$STATE/has-gh-pages"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "gh-pages branch: warned"                             grep -q 'WARNING: allen/repo1 has a gh-pages branch: once the fence is on, pushes by GitHub Actions or Dependabot' <<<"$OUT"
check "  ...before the fence is created"                    bash -c 'a=$(grep -n gh-pages <<<"$1" | head -n1 | cut -d: -f1); b=$(grep -n "creating ruleset agent-fence " <<<"$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$OUT"
newstate; touch "$STATE/collab" "$STATE/has-dependabot"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "dependabot.yml: warned"                              grep -q 'WARNING: allen/repo1 has .github/dependabot.yml' <<<"$OUT"
newstate; touch "$STATE/collab"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1)
check "no gh-pages, no dependabot, not a fork: no warning"  bash -c '! grep -q WARNING <<<"$1"' _ "$OUT"
newstate; touch "$STATE/collab"; echo up/stream > "$STATE/parent"
printf 'main\nfix/mine\nfeature/shared\ndevelopment\n' > "$STATE/branches-allen_repo1"; printf 'main\nfeature/shared\ndevelopment\nfix/theirs\n' > "$STATE/branches-up_stream"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "fork: exit 0 (warn only)"                            test "$rc" -eq 0
check "  upstream branch under a free name warned, by name" grep -q 'WARNING: allen/repo1 is a fork of up/stream, .*: feature/shared$' <<<"$OUT"
check "  ...and only that one"                              bash -c '! grep -Eq "fork of.*(fix/mine|fix/theirs|development)" <<<"$1"' _ "$OUT"
newstate; touch "$STATE/collab" "$STATE/branches-fail"; echo up/stream > "$STATE/parent"
OUT=$(run protect allen/repo1 --vault agent-p1 2>&1); rc=$?
check "fork, branch list fails: warned, not fatal"          bash -c '[ "$1" -eq 0 ] && grep -q "WARNING: could not list the branches of allen/repo1 and up/stream" <<<"$2"' _ "$rc" "$OUT"

echo "== verify: the fence, in the container =="
export AGENT_NEW_CHECK_TRIES=2 AGENT_NEW_CHECK_SLEEP=0
# the container's answers that are not GitHub's: who gh is, origin's URLs, the unrelated commit's id. GitHub's part (pushes,
# PRs, merges, refs) is played by the stubs from $STATE (fence on, rulesets equal to their templates, allen-dev present).
wbrule(){ echo 10 > "$STATE/ruleset-id-agent-working-branch"; echo "$WB_NORM" > "$STATE/ruleset-norm-agent-working-branch"; touch "$STATE/wbr"; }
plan_fence(){ local r="${1:-allen/p1}"; touch "$STATE/fence" "$STATE/has-allen-dev"; fencepair; wbrule
  cat > "$STATE/exec-plan" <<PLAN
api user|0|agent-allen
remote get-url --push origin|0|https://github.com/$r.git
remote get-url origin|0|https://github.com/$r.git
commit-tree|0|1111111111111111111111111111111111111111
HEAD~2|0|6666666666666666666666666666666666666666
PLAN
}
fence_in(){ grep -qE -- "$1" "$DLOG"; }                                              # $1 an ERE the docker log must contain
fence_not(){ [ -r "$DLOG" ] || { echo "no readable log: $DLOG"; return 1; }; ! grep -qE -- "$1" "$DLOG"; }  # ...or must not
VID_RE='[0-9]+-[0-9]+-[0-9]+'
URL1='https://github\.com/allen/p1\.git'
# every merge sent to the server was for a PR into a throwaway branch, never into the default branch
merges_only_throwaway(){ local n ok=1; while read -r n; do grep -Eqx "zz-agent-new-verify-$VID_RE" "$STATE/pr-base-$n" || ok=0; done \
  < <(grep -oE 'pulls/[0-9]+/merge' "$GHLOG" | grep -oE '[0-9]+'); [ "$ok" = 1 ] && grep -q '/merge' "$GHLOG"; }
newstate; plan_fence
VOUT=$(run verify p1 2>&1); VRC=$?
check "fence on: verify passes"                         test "$VRC" -eq 0
check "  says FENCE VERIFIED, naming the repo and the project" grep -qx 'agent-new: FENCE VERIFIED on allen/p1 (project p1)' <<<"$VOUT"
check "  eight refusals asserted"                       test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 8
check "  the rulesets were read as you"                 grep -q '^GH: api repos/allen/p1/rulesets/9 --jq' "$GHLOG"
check "  you created the throwaway branch from the default branch's head" grep -Eq "^GH: api -X POST repos/allen/p1/git/refs -f ref=refs/heads/zz-agent-new-verify-$VID_RE -f sha=sha-of-main$" "$GHLOG"
check "  ...and the throwaway tag"                      grep -Eq "^GH: api -X POST repos/allen/p1/git/refs -f ref=refs/tags/zz-agent-new-verify-$VID_RE -f sha=sha-of-main$" "$GHLOG"
check "  worktree, detached, from the default branch fetched by URL" fence_in "git fetch -q $URL1 refs/heads/main && git worktree add -q --detach /tmp/agent-new-verify-$VID_RE FETCH_HEAD"
check "  fast-forward push to the throwaway branch tried" fence_in "bash -lc git push $URL1 HEAD:refs/heads/zz-agent-new-verify-$VID_RE\$"
check "  force-push of the default head's parent tried (a one-commit rewind)" fence_in "git push --force $URL1 6{40}:refs/heads/zz-agent-new-verify-$VID_RE\$"
check "  delete tried"                                  fence_in "git push $URL1 --delete refs/heads/zz-agent-new-verify-$VID_RE\$"
check "  new branch outside the free names tried"       fence_in "git push $URL1 HEAD:refs/heads/zz-agent-new-verify-$VID_RE-new\$"
check "  new tag tried"                                 fence_in "git push $URL1 HEAD:refs/tags/zz-agent-new-verify-$VID_RE-new\$"
check "  tag move tried"                                fence_in "git push --force $URL1 HEAD:refs/tags/zz-agent-new-verify-$VID_RE\$"
check "  tag delete tried"                              fence_in "git push $URL1 --delete refs/tags/zz-agent-new-verify-$VID_RE\$"
check "  chore/verify-fence-<id> pushed, without force" fence_in "bash -lc git push $URL1 HEAD:refs/heads/chore/verify-fence-$VID_RE\$"
check "  PR into the throwaway branch, with -R, --base and --head" fence_in "gh pr create -R allen/p1 --base zz-agent-new-verify-$VID_RE --head chore/verify-fence-$VID_RE "
check "  its merge sent to the server, not through gh pr merge" bash -c 'grep -Eq "gh api -X PUT repos/allen/p1/pulls/7/merge -f merge_method=squash" "$1" && ! grep -q "gh pr merge 7 " "$1"' _ "$DLOG"
check "  every merge sent to the server was into a throwaway branch" merges_only_throwaway
check "  the default branch was never pushed to"        lacks "$STATE/pushes" '(:|^PUSH.*--delete )(refs/heads/)?main( |$)'
check "  no PR into the default branch"                 fence_not 'gh pr create [^|]*--base main '
check "  every push and fetch names the URL, never origin" fence_not 'git (push|fetch|ls-remote)( -q)? origin( |$)'
check "  force only in the two deliberate attempts, both on throwaway refs" \
  bash -c 'f=$(grep -E "git push [^|]*(--force|-f )" "$1"); [ "$(grep -c . <<<"$f")" -eq 2 ] && ! grep -Ev "refs/(heads|tags)/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+$" <<<"$f"' _ "$DLOG"
check "  no fixed name: every verify ref carries the run's id" fence_not 'verify-ruleset|verify-fence($|[^-]|-[^0-9])'
check "  allen-dev checked by its full ref name"        fence_in "git ls-remote --exit-code $URL1 refs/heads/allen-dev"
check "  dev commit made on allen-dev fetched by URL"   fence_in "git fetch -q $URL1 refs/heads/allen-dev && git checkout -q --detach FETCH_HEAD"
check "  PR into allen-dev opened"                      fence_in "gh pr create -R allen/p1 --base allen-dev --head chore/verify-fence-$VID_RE-dev "
check "  ...its checks watched by number"               fence_in 'gh pr checks 8 -R allen/p1 --watch'
check "  ...merged by number, --squash --delete-branch" fence_in 'gh pr merge 8 -R allen/p1 --squash --delete-branch'
check "  ...and you confirmed it MERGED"                grep -q '^GH: pr view 8 -R allen/p1 --json state --jq .state' "$GHLOG"
check "  no direct push to allen-dev"                   fence_not 'HEAD:(refs/heads/)?allen-dev'
check "  allen-dev itself is never deleted or force-pushed" lacks "$STATE/pushes" 'allen-dev'
check "  the working-branch ruleset was checked as you" grep -q '^GH: api repos/allen/p1/rulesets/10 --jq' "$GHLOG"
check "  you closed the refused PR"                     grep -q '^GH: pr close 7 -R allen/p1' "$GHLOG"
check "  you removed the throwaway branch, tag and both chore branches" \
  bash -c 'for r in "heads/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "tags/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "heads/chore/verify-fence-[0-9]+-[0-9]+-[0-9]+"; do grep -Eqx "$r" "$1" || exit 1; done' _ "$STATE/refs-deleted"
check "  ...each deletion as you"                       bash -c '[ -z "$(grep "git/refs/" "$1" | grep -v "^GH: ")" ]' _ "$GHLOG"
check "  the merged dev branch counts as gone, not as left behind" bash -c '! grep -q "left on" <<<"$1"' _ "$VOUT"
check "  none of the main-gate steps"                   fence_not 'pr review|--admin|verify-gate'
check "  worktree removed on exit"                      fence_in "DOCKER: exec -w /workspace p1-agent-1 git worktree remove --force /tmp/agent-new-verify-$VID_RE"
check "  every gh pr call names allen/p1 (origin), never gh's default repo" bash -c 'grep -Eq "gh pr " "$1" && [ -z "$(grep -E "gh pr " "$1" | grep -Ev -- " -R allen/p1( |$)")" ]' _ "$DLOG"

# each attempt on the throwaway refs, wrongly accepted on its own: verify stops, and you remove the throwaway refs
for a in "fast-forward push to zz-agent-new-verify::HEAD:refs/heads/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+\$" \
         "force-push to zz-agent-new-verify::--force .*:refs/heads/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+\$" \
         "delete zz-agent-new-verify::--delete refs/heads/zz-agent-new-verify-" \
         "create a branch outside the free names::refs/heads/zz-agent-new-verify-.*-new\$" \
         "create a tag::refs/tags/zz-agent-new-verify-.*-new\$" \
         "move a tag::--force .*refs/tags/" \
         "delete a tag::--delete refs/tags/"; do
  label="${a%%::*}"; re="${a#*::}"
  newstate; plan_fence; printf '%s' "$re" > "$STATE/accept-push"
  VOUT=$(run verify p1 2>&1); VRC=$?
  check "'$label' wrongly accepted: GATE NOT BINDING" bash -c '[ "$1" -ne 0 ] && grep -Eq "GATE NOT BINDING: .$2[^ ]*. SUCCEEDED on allen/p1" <<<"$3"' _ "$VRC" "$label" "$VOUT"
  check "  the throwaway branch and tag are gone (removed by you, or deleted by the accepted attempt)" bash -c 'grep -Eqx "heads/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "$1" && grep -Eqx "tags/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "$1" && ! grep -q "left on" <<<"$2"' _ "$STATE/refs-gone" "$VOUT"
  check "  nothing pushed to the default branch"       lacks "$STATE/pushes" '(refs/heads/)?main( |$)'
  case "$label" in create*) check "  ...and the ref it created"  grep -Eq -- "-new$" "$STATE/refs-deleted" ;; esac
done
newstate; plan_fence; printf '%s' '/merge -f merge_method=squash' > "$STATE/accept-gh"
VOUT=$(run verify p1 2>&1); VRC=$?
check "merge into the throwaway branch wrongly accepted: GATE NOT BINDING" bash -c '[ "$1" -ne 0 ] && grep -Eq "GATE NOT BINDING: .merge a PR into zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+. SUCCEEDED" <<<"$2"' _ "$VRC" "$VOUT"
check "  the merged PR is not closed again"             lacks "$GHLOG" '^GH: pr close'
check "  you removed the throwaway refs and chore branch" bash -c 'grep -Eqx "heads/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "$1" && grep -Eqx "heads/chore/verify-fence-[0-9]+-[0-9]+-[0-9]+" "$1"' _ "$STATE/refs-deleted"
check "  ...before the worktree goes"                   bash -c 'tail -n1 "$1" | grep -q "git worktree remove"' _ "$DLOG"

newstate; plan_fence; rm -f "$STATE/ruleset-id-agent-working-branch"
refuses "allen-dev without its ruleset: dies"           'has no ruleset agent-working-branch: run agent-new protect' run verify p1
check "  ...before any push"                            bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
newstate; plan_fence; rm -f "$STATE/has-allen-dev" "$STATE/ruleset-id-agent-working-branch"
check "no allen-dev and no working-branch ruleset: passes (nothing to protect)" run verify p1

newstate; plan_fence; sed -i '1i HEAD~2|1|' "$STATE/exec-plan"
VOUT=$(run verify p1 2>&1); VRC=$?
check "default head is a root commit: the force-push uses an unrelated commit" bash -c '[ "$1" -eq 0 ] && grep -Eq "git push --force https://github.com/allen/p1.git 1{40}:refs/heads/zz-agent-new-verify-" "$2"' _ "$VRC" "$DLOG"
newstate; plan_fence; echo 'zz-agent-new-verify-' > "$STATE/ref-exists-match"
VOUT=$(run verify p1 2>&1); VRC=$?
check "throwaway name already exists: dies without creating it" bash -c '[ "$1" -ne 0 ] && grep -q "already exists on allen/p1: refusing to use it" <<<"$2" && ! grep -q "POST repos/allen/p1/git/refs" "$3"' _ "$VRC" "$VOUT" "$GHLOG"
check "  ...and the existing ref is NOT deleted"        lacks "$GHLOG" 'DELETE repos/allen/p1/git/refs/.*zz-agent-new-verify'
check "  ...nothing pushed"                             bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
newstate; plan_fence; touch "$STATE/ref-create-fail"
VOUT=$(run verify p1 2>&1); VRC=$?
check "creating the throwaway branch fails: dies"       bash -c '[ "$1" -ne 0 ] && grep -q "could not create refs/heads/zz-agent-new-verify-" <<<"$2"' _ "$VRC" "$VOUT"
check "  ...and nothing of that name is deleted"        lacks "$GHLOG" 'DELETE repos/allen/p1/git/refs'
newstate; plan_fence; echo feature/x > "$STATE/default-branch"
refuses "default branch feature/x: verify dies"         'default branch feature/x of allen/p1 would be outside the fence' run verify p1
check "  ...before any push or ref"                     bash -c '[ ! -s "$1" ] && ! grep -q "git/refs" "$2"' _ "$STATE/pushes" "$GHLOG"
newstate; plan_fence allen/protected-areas; echo 'HEAD:refs/heads/zz-agent-new-verify-[0-9-]+$' > "$STATE/reject-push"
refuses "repo named protected-areas, push fails for another reason: not taken as the rule" "was refused, but not for the expected reason" run verify p1
for step in 'HEAD:refs/heads/zz-agent-new-verify-[0-9-]+$' '/merge -f merge_method=squash'; do
  newstate; plan_fence; printf '%s' "$step" > "$STATE/drop-token"
  refuses "an attempt made as you instead of the machine user ($step): GATE NOT BINDING" 'GATE NOT BINDING: .* SUCCEEDED' run verify p1
done

# the rulesets are checked as you before the machine user does anything
for c in "no fence rulesets::rm -f \$STATE/ruleset-id-agent-fence \$STATE/ruleset-id-agent-fence-tags::has no ruleset agent-fence: run agent-new protect" \
         "agent-fence differs::sed -i 's#refs/heads/sync/\\*\\*,##' \$STATE/ruleset-norm-agent-fence::ruleset agent-fence on allen/p1 differs from its template" \
         "agent-fence-tags differs::sed -i 's#creation,##' \$STATE/ruleset-norm-agent-fence-tags::ruleset agent-fence-tags on allen/p1 differs" \
         "protect-fork still there::echo 4 > \$STATE/ruleset-id-protect-fork::still has the older ruleset protect-fork: migrate first" \
         "protect-fork-tags still there::echo 5 > \$STATE/ruleset-id-protect-fork-tags::still has the older ruleset protect-fork-tags: migrate first"; do
  label="${c%%::*}"; rest="${c#*::}"; how="${rest%%::*}"; want="${rest#*::}"
  newstate; plan_fence; STATE="$STATE" bash -c "$how"
  refuses "$label: dies"                               "$want" run verify p1
  check "  ...before any push, PR or throwaway ref"    bash -c '[ ! -s "$1" ] && ! grep -q "git/refs" "$2" && ! grep -q "pr create" "$3"' _ "$STATE/pushes" "$GHLOG" "$DLOG"
done

newstate; plan_fence; sed -i 's#^remote get-url --push origin|0|.*#remote get-url --push origin|0|https://github.com/evil/p1.git#' "$STATE/exec-plan"
refuses "push URL names another repo: dies"             'fetches from allen/p1 but pushes to evil/p1' run verify p1
check "  ...before any push"                            bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
for o in git@github.com:allen/p1.git ssh://git@github.com/allen/p1; do
  newstate; plan_fence; sed -i "s#^remote get-url \\(--push \\)\\?origin|0|.*#remote get-url \\1origin|0|$o#" "$STATE/exec-plan"
  refuses "ssh origin ($o): dies"                       'verify needs an https origin' run verify p1
  check "  ...before any push"                          bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
done
for bad in /srv/git/p1.git https://gitlab.com/allen/p1.git 'https://github.com/allen/p1/extra' 'https://github.com/allen' 'https://github.com/-x/p1'; do
  newstate; plan_fence; sed -i "s#^remote get-url origin|0|.*#remote get-url origin|0|$bad#" "$STATE/exec-plan"
  refuses "unparseable origin ($bad): dies"            'cannot tell which GitHub repo origin is' run verify p1
  check "  ...before any push or gh pr call"            bash -c '[ ! -s "$1" ] && ! grep -Eq "gh pr " "$2"' _ "$STATE/pushes" "$DLOG"
done
newstate; plan_fence; sed -i 's#^remote get-url origin|0|.*#remote get-url origin|0|https://agent:s3cr3t@pw@github.com/allen/p1.git#' "$STATE/exec-plan"
VOUT=$(run verify p1 2>&1); VRC=$?
check "origin with user:password@: dies without printing the password" bash -c '[ "$1" -ne 0 ] && grep -q "cannot tell which GitHub repo origin is (origin: .https://github.com/allen/p1.git.)" <<<"$2" && ! grep -q s3cr3t <<<"$2"' _ "$VRC" "$VOUT"
newstate; plan_fence; sed -i 's#allen/p1\.git#Allen/P1.git#' "$STATE/exec-plan"; echo allen/p1 > "$STATE/full-name"
VOUT=$(run verify p1 2>&1); VRC=$?
check "origin spelled Allen/P1: passes under GitHub's spelling" bash -c '[ "$1" -eq 0 ] && grep -q "FENCE VERIFIED on allen/p1 " <<<"$2" && grep -q "gh pr create -R allen/p1 " "$3"' _ "$VRC" "$VOUT" "$DLOG"
newstate; plan_fence; touch "$STATE/not-admin"
refuses "you are not an admin of the repo: dies"        'you are not an admin of allen/p1' run verify p1
check "  ...before any push"                            bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"

newstate; plan_fence; echo master > "$STATE/default-branch"
VOUT=$(run verify p1 2>&1); VRC=$?
check "default branch master: passes"                   test "$VRC" -eq 0
check "  throwaway refs made from master's head"        grep -Eq "ref=refs/heads/zz-agent-new-verify-$VID_RE -f sha=sha-of-master$" "$GHLOG"
check "  worktree from master"                          fence_in "git fetch -q $URL1 refs/heads/master && git worktree add"
check "  master never pushed to"                        lacks "$STATE/pushes" '(refs/heads/)?master( |$)'

newstate; plan_fence; rm -f "$STATE/has-allen-dev"
VOUT=$(run verify p1 2>&1); VRC=$?
check "allen-dev missing: passes"                       test "$VRC" -eq 0
check "  says the working-branch check was skipped"     grep -q 'working-branch check was skipped' <<<"$VOUT"
check "  no dev branch pushed, no dev PR"               fence_not 'zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+-dev'
check "  still FENCE VERIFIED"                          grep -q 'FENCE VERIFIED on allen/p1' <<<"$VOUT"

newstate; plan_fence; touch "$STATE/ls-remote-fail"
VOUT=$(run verify p1 2>&1); VRC=$?
check "allen-dev lookup fails: dies (not read as missing)" test "$VRC" -ne 0
check "  shows the error"                               grep -q 'unable to access the remote' <<<"$VOUT"
check "  not skipped"                                   bash -c '! grep -q skipped <<<"$1"' _ "$VOUT"
check "  EXIT trap: you closed the PR and removed the throwaway refs" bash -c 'grep -q "^GH: pr close 7 " "$1" && grep -Eqx "tags/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "$2"' _ "$GHLOG" "$STATE/refs-deleted"

newstate; plan_fence; echo 'HEAD:refs/heads/chore/' > "$STATE/reject-push"
VOUT=$(run verify p1 2>&1); VRC=$?
check "chore push fails: dies, names the step and the error" bash -c '[ "$1" -ne 0 ] && grep -Eq "could not push chore/verify-fence-[0-9]+-[0-9]+-[0-9]+ " <<<"$2" && grep -q "rejected by a hook" <<<"$2"' _ "$VRC" "$VOUT"
check "  no PR opened"                                  fence_not 'pr create'
check "  the chore branch is not listed for removal (never created)" bash -c '! grep -q chore "$1" 2>/dev/null' _ "$STATE/refs-deleted"
newstate; plan_fence; touch "$STATE/pr-create-fail"
VOUT=$(run verify p1 2>&1); VRC=$?
check "PR into the throwaway branch cannot be opened: dies" bash -c '[ "$1" -ne 0 ] && grep -q "could not open the PR" <<<"$2" && grep -q "something broke" <<<"$2"' _ "$VRC" "$VOUT"
check "  no merge tried (neither gh pr merge nor the REST merge)" bash -c '! grep -Eq "pr merge|/merge" "$1" && ! grep -Eq "pr merge|/merge" "$2"' _ "$DLOG" "$GHLOG"
newstate; plan_fence; sed -i '1i gh pr merge 8 |1|X Pull request #8 is not mergeable' "$STATE/exec-plan"
VOUT=$(run verify p1 2>&1); VRC=$?
check "merge into allen-dev fails: dies, names the step and the error" bash -c '[ "$1" -ne 0 ] && grep -q "could not squash-merge the PR into allen-dev" <<<"$2" && grep -q "is not mergeable" <<<"$2"' _ "$VRC" "$VOUT"
check "  not FENCE VERIFIED"                            bash -c '! grep -q "FENCE VERIFIED" <<<"$1"' _ "$VOUT"
check "  EXIT trap: you closed the dev PR and removed its branch" bash -c 'grep -q "^GH: pr close 8 " "$1" && grep -Eqx "heads/chore/verify-fence-[0-9]+-[0-9]+-[0-9]+-dev" "$2"' _ "$GHLOG" "$STATE/refs-deleted"
newstate; plan_fence; touch "$STATE/merge-noop"
refuses "merge into allen-dev reports success but the PR is not MERGED: dies" "is 'OPEN' after the merge, not MERGED" run verify p1
newstate; plan_fence; sed -i '1i pr checks|1|no checks reported on the branch' "$STATE/exec-plan"
VOUT=$(run verify p1 2>&1); VRC=$?
check "no checks on the PR into allen-dev: passes"      test "$VRC" -eq 0
check "  says no checks were reported"                  grep -q 'no checks reported' <<<"$VOUT"
check "  checks retried AGENT_NEW_CHECK_TRIES times"    test "$(grep -c 'pr checks' "$DLOG")" -eq 2
check "  merged anyway"                                 fence_in 'gh pr merge 8 -R allen/p1 --squash --delete-branch'
newstate; plan_fence; sed -i '1i pr checks|1|gitleaks	fail	10s' "$STATE/exec-plan"
refuses "red check on the PR into allen-dev: dies"      'not green' run verify p1
check "  not merged"                                    fence_not 'pr merge'

newstate; plan_fence; echo 'tags/zz-agent-new-verify' > "$STATE/ref-delete-fail"
VOUT=$(run verify p1 2>&1); VRC=$?
check "cleanup fails: exit non-zero"                    test "$VRC" -ne 0
check "  says FENCE VERIFIED, but cleanup is incomplete" grep -q 'FENCE VERIFIED, but cleanup is incomplete on allen/p1' <<<"$VOUT"
check "  names what is left, and how to remove it"      grep -Eq "left on allen/p1: refs/tags/zz-agent-new-verify-$VID_RE: delete it with: gh api -X DELETE repos/allen/p1/git/refs/tags/zz-agent-new-verify-" <<<"$VOUT"
check "  no clean success line"                         bash -c '! grep -q "^agent-new: FENCE VERIFIED on" <<<"$1"' _ "$VOUT"
newstate; plan_fence; touch "$STATE/pr-close-fail"
VOUT=$(run verify p1 2>&1); VRC=$?
check "a PR cannot be closed: cleanup incomplete, exit non-zero" bash -c '[ "$1" -ne 0 ] && grep -q "left on allen/p1: pull request #7" <<<"$2"' _ "$VRC" "$VOUT"

newstate; plan_fence; sed -i 's/^api user|0|agent-allen/api user|0|allen/' "$STATE/exec-plan"
refuses "container identity is the owner -> die" 'allen.*agent-allen|agent-allen.*allen' run verify p1
check "  nothing pushed"                                bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
check "  waits for agent-init's git credentials first"  grep -q 'DOCKER: exec -w /workspace p1-agent-1 bash -lc git config --global --get credential.https://github.com.helper' "$DLOG"
newstate; plan_fence; sed -i '1i credential.https://github.com.helper|1|' "$STATE/exec-plan"
AGENT_NEW_INIT_WAIT=2 refuses "git never gets credentials (agent-init unfinished) -> die after the wait" 'no GitHub credentials' run verify p1
check "  nothing pushed"                                bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
check "  no worktree add attempted"                     fence_not 'worktree add'
newstate
refuses "container not running"                         'not running' run verify nosuch

echo "== verify --main-gate =="
EXPECT_NORM_LIVE="$EXPECT_NORM"
gatestate(){ newstate; plan_fence; touch "$STATE/gate"; echo 7 > "$STATE/ruleset-id-protect-main"; echo "$EXPECT_NORM_LIVE" > "$STATE/ruleset-norm-protect-main"; }
gatestate
VOUT=$(run verify p1 --main-gate 2>&1); VRC=$?
check "--main-gate: passes"                             test "$VRC" -eq 0
check "  runs the fence first"                          bash -c 'a=$(grep -n "FENCE VERIFIED on" <<<"$1" | cut -d: -f1); b=$(grep -n "verifying the merge gate" <<<"$1" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]' _ "$VOUT"
check "  then the gate: twelve refusals in all"         test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 12
check "  GATE VERIFIED, naming the PR"                  grep -q 'GATE VERIFIED on allen/p1. Approve-and-merge or close PR #9' <<<"$VOUT"
check "  gate commit on the default branch, fetched by URL" fence_in "git fetch -q $URL1 refs/heads/main && git checkout -q --detach FETCH_HEAD && git commit -q --allow-empty -m 'chore: verify ruleset'"
check "  gate PR from chore/verify-gate-<id> into main" fence_in "gh pr create -R allen/p1 --base main --head chore/verify-gate-$VID_RE "
check "  push straight to main tried"                   fence_in "git push $URL1 HEAD:refs/heads/main\$"
check "  merge, approve and admin-merge tried by number" bash -c 'grep -q "gh pr merge 9 -R allen/p1 --squash$" "$1" && grep -q "gh pr review 9 -R allen/p1 --approve" "$1" && grep -q "gh pr merge 9 -R allen/p1 --squash --admin" "$1"' _ "$DLOG"
check "  the gate PR and its branch stay for you"       bash -c '! grep -q "pr close 9" "$1" && ! grep -q verify-gate "$2"' _ "$GHLOG" "$STATE/refs-deleted"
check "  the protect-main ruleset was checked too"      grep -q '^GH: api repos/allen/p1/rulesets/7 --jq' "$GHLOG"
gatestate; rm -f "$STATE/ruleset-id-protect-main"
refuses "--main-gate without protect-main: dies before any push" 'has no ruleset protect-main' run verify p1 --main-gate
check "  ...nothing pushed"                             bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
gatestate
refuses "--main-gate, protect-main needs another check: dies (verify takes --require too)" 'ruleset protect-main on allen/p1 differs' run verify p1 --main-gate --require build-test
gatestate; rm -f "$STATE/has-allen-dev"; sed -i '1i pr checks|1|no checks reported on the latest commit' "$STATE/exec-plan"
VOUT=$(run verify p1 --main-gate 2>&1); VRC=$?
check "no checks reported on the gate PR -> warns UNTESTED, continues" test "$VRC" -eq 0
check "  UNTESTED warning shown"                        grep -qi 'UNTESTED' <<<"$VOUT"
check "  checks retried AGENT_NEW_CHECK_TRIES times"    test "$(grep -c 'pr checks' "$DLOG")" -eq 2
gatestate; rm -f "$STATE/has-allen-dev"; sed -i '1i pr checks|1|gitleaks fail 10s' "$STATE/exec-plan"
refuses "red check on the gate PR -> die, not UNTESTED warning" 'required checks are not green' run verify p1 --main-gate
check "  worktree removed on a failing run"             fence_in 'git worktree remove --force /tmp/agent-new-verify-'
gatestate; printf '%s' 'HEAD:refs/heads/main$' > "$STATE/accept-push"
VOUT=$(run verify p1 --main-gate 2>&1); VRC=$?
check "push to main wrongly accepted -> GATE NOT BINDING" bash -c '[ "$1" -ne 0 ] && grep -q "GATE NOT BINDING: .push straight to main. SUCCEEDED" <<<"$2"' _ "$VRC" "$VOUT"
check "  ...naming the empty commit now on main, and how it can be removed" grep -qF "main now holds verify's empty commit pushed-by-mu on top of sha-of-main. It changes no files. Removing it needs a revert PR, or the ruleset switched off first" <<<"$VOUT"
check "  ...and no restore command"                     bash -c '! grep -q -- "--force-with-lease=refs/heads/main" <<<"$1"' _ "$VOUT"
check "  the gate PR is closed on the way out"          grep -q '^GH: pr close 9 ' "$GHLOG"
gatestate; sed -i 's|^\(api user.*\)|\1|' "$STATE/exec-plan"; sed -i '1i gh pr review 9 -R allen/p1 --approve|1|failed: something unrelated' "$STATE/exec-plan"
refuses "wrong refusal reason on the gate -> GATE NOT BINDING" "'approve own PR' was refused, but not for the expected reason" run verify p1 --main-gate

echo "== verify: <owner>/<repo>, in a temporary clone =="
refuses "repo mode without --vault refused"             'needs --vault' run verify allen/repo9
export TMPDIR="$T/tmpdirs"; mkdir -p "$TMPDIR"
repostate(){ newstate; touch "$STATE/fence" "$STATE/has-allen-dev"; fencepair; wbrule; }
repostate; echo allen > "$STATE/mu-login"
refuses "repo mode: token resolving to the owner -> die" 'allen.*agent-allen' run verify allen/repo9 --vault agent-p1
check "  nothing cloned"                                lacks "$GITLOG" '^GIT: clone'
repostate
VOUT=$(run verify allen/repo9 --vault agent-p1 2>&1); VRC=$?
check "repo mode, fence on: passes"                     test "$VRC" -eq 0
check "  FENCE VERIFIED on allen/repo9"                 grep -qx 'agent-new: FENCE VERIFIED on allen/repo9' <<<"$VOUT"
check "  eight refusals asserted"                       test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 8
check "  the attempts were the machine user's"          bash -c '[ "$(grep -c "^PUSH(mu):" "$1")" -ge 9 ] && ! grep -q "^PUSH:" "$1"' _ "$STATE/pushes"
check "  every push names the URL, never origin"        bash -c 'grep -q "^GIT: push https://github.com/allen/repo9.git " "$1" && ! grep -Eq "^GIT: (push|fetch)( -q)? origin" "$1"' _ "$GITLOG"
check "  the refs were created and removed as you"      bash -c 'grep -q "^GH: api -X POST repos/allen/repo9/git/refs" "$1" && grep -q "^GH: api -X DELETE repos/allen/repo9/git/refs" "$1" && ! grep -q "^GH(mu): api -X (POST|DELETE) repos/allen/repo9/git/refs" "$1"' _ "$GHLOG"
check "  PR into allen-dev merged as the machine user"  grep -q '^GH(mu): pr merge 8 -R allen/repo9 --squash --delete-branch' "$GHLOG"
check "  merge into the throwaway branch sent to the server as the machine user" grep -q '^GH(mu): api -X PUT repos/allen/repo9/pulls/7/merge -f merge_method=squash' "$GHLOG"
check "  every merge sent to the server was into a throwaway branch" merges_only_throwaway
check "  every gh pr call names allen/repo9"            bash -c 'grep -Eq "^GH\(mu\): pr " "$1" && [ -z "$(grep -E "^GH(\(mu\))?: pr " "$1" | grep -Ev -- " -R allen/repo9( |$)")" ]' _ "$GHLOG"
check "  temp clone cleaned up by EXIT trap"            test -z "$(ls -A "$TMPDIR")"
check "  clone is plain https, by the canonical name"   grep -q '^GIT: clone .*https://github.com/allen/repo9.git ' "$GITLOG"
check "  git isolated from owner config"                grep -q 'GITENV: global=/dev/null nosystem=1 count=3 ' "$GITLOG"
check "  helper is literal, token via env"              grep -qF 'helper=!f(){ echo username=x-access-token; echo "password=$GH_TOKEN"; }; f' "$GITLOG"
check "  commit identity is the machine user"           grep -q 'name=agent-allen email=agent-allen@users.noreply.github.com' "$GITLOG"
check "  the token is in no log and no output"          bash -c '! grep -q fake-op-secret "$1" "$2" "$3" "$4" "$5" && ! grep -q fake-op-secret <<<"$6"' _ "$GITLOG" "$GHLOG" "$DLOG" "$OPLOG" "$STATE/pushes" "$VOUT"
check "  real commit author+committer is the machine user" grep -qx 'AUTHOR: agent-allen <agent-allen@users.noreply.github.com> COMMITTER: agent-allen <agent-allen@users.noreply.github.com>' "$STATE/gh-author"
repostate; echo Allen/Repo9 > "$STATE/full-name"
VOUT=$(run verify allen/repo9 --vault agent-p1 2>&1); VRC=$?
check "repo mode, GitHub spells it Allen/Repo9: passes under that name" bash -c '[ "$1" -eq 0 ] && grep -q "FENCE VERIFIED on Allen/Repo9" <<<"$2" && grep -q "^GIT: clone .*https://github.com/Allen/Repo9.git " "$3"' _ "$VRC" "$VOUT" "$GITLOG"
repostate; echo https://github.com/other/repo9.git > "$STATE/clone-origin"
refuses "repo mode, clone's origin is another repo: dies" "the clone's origin is other/repo9, not allen/repo9" run verify allen/repo9 --vault agent-p1
check "  nothing pushed"                                bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
repostate; echo master > "$STATE/default-branch"; rm -f "$STATE/has-allen-dev"
VOUT=$(run verify allen/repo9 --vault agent-p1 2>&1); VRC=$?
check "repo mode, master, no allen-dev: passes"         test "$VRC" -eq 0
check "  never pushed to master"                        lacks "$STATE/pushes" '(refs/heads/)?master( |$)'
check "  working-branch check skipped"                  grep -q 'working-branch check was skipped' <<<"$VOUT"
repostate; printf '%s' 'HEAD:refs/heads/zz-agent-new-verify-[0-9-]+$' > "$STATE/drop-token"
refuses "repo mode, the push made as you: GATE NOT BINDING" "GATE NOT BINDING: 'fast-forward push to zz-agent-new-verify-" run verify allen/repo9 --vault agent-p1
repostate; rm -f "$STATE/fence"
VOUT=$(run verify allen/repo9 --vault agent-p1 2>&1); VRC=$?
check "repo mode, fence off: GATE NOT BINDING at the first attempt" bash -c '[ "$1" -ne 0 ] && grep -q "GATE NOT BINDING: .fast-forward push to zz-agent-new-verify-" <<<"$2"' _ "$VRC" "$VOUT"
check "  you removed the throwaway refs"                bash -c 'grep -Eqx "heads/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "$1" && grep -Eqx "tags/zz-agent-new-verify-[0-9]+-[0-9]+-[0-9]+" "$1"' _ "$STATE/refs-deleted"
check "  temp clone cleaned up"                         test -z "$(ls -A "$TMPDIR")"
repostate; touch "$STATE/gate"; echo 7 > "$STATE/ruleset-id-protect-main"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm-protect-main"
printf 'export GH_TOKEN=bogus-owner-token\n' > "$H/.profile"
VOUT=$(run verify allen/repo9 --vault agent-p1 --main-gate 2>&1); VRC=$?
rm -f "$H/.profile"
check "repo mode --main-gate: passes"                   test "$VRC" -eq 0
check "  fence and gate refusals asserted"              test "$(grep -c 'OK (refused as expected)' <<<"$VOUT")" -eq 12
check "  login profile cannot swap the token (bash -c)" bash -c '! grep -q bogus-owner-token "$1" && grep -q fake-op-secret "$1"' _ "$STATE/gh-tokens"
repostate; touch "$STATE/gate"; echo 7 > "$STATE/ruleset-id-protect-main"; echo "$EXPECT_NORM" > "$STATE/ruleset-norm-protect-main"
printf '[ "$0" = bash ] && export GH_TOKEN=bogus-bashenv-token\n' > "$T/bashenv"
BASH_ENV="$T/bashenv" run verify allen/repo9 --vault agent-p1 --main-gate >/dev/null 2>&1
check "  BASH_ENV cannot swap the token either" sh -c "! grep -q bogus-bashenv-token '$STATE/gh-tokens' && grep -q fake-op-secret '$STATE/gh-tokens'"
check "trap freezes tmp at set time (immediate expansion)" grep -qF "rm -rf '\$tmp' || true\" EXIT" "$AN"
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
  plan_fence allen/NewProj; }
rm -rf "$PROJHOME/NewProj" "$CFGROOT/newproj"
fullstate
check "full project run"             run project NewProj --token-from agent-old < /dev/null
check "  serve mapping with formula port" grep -q '^TS: serve --bg --https=8447 3778' "$TSLOG"
check "  up with token in env"       grep -q '^AU(tok): up newproj' "$AULOG"
check "  no research config: no research up"  sh -c "! grep -q 'up research' '$AULOG'"
OUT=$(run project NewProj --token-from agent-old < /dev/null 2>&1)
check "  checklist printed"          grep -q "codex login --device-auth" <<<"$OUT"
check "  its verify proved the fence (no --main-gate)" bash -c 'grep -q "FENCE VERIFIED on allen/NewProj (project newproj)" <<<"$1" && ! grep -q "GATE VERIFIED" <<<"$1"' _ "$OUT"
check "  checklist: no verification PR to close"  bash -c '! grep -q "verification PR" <<<"${1#*DONE}"' _ "$OUT"
check "  checklist: allowlist sentence kept"      grep -q "^Allowlist extra domains in .*/newproj/allowlist as the project needs them, then: agent-up up newproj" <<<"$OUT"
fullstate; touch "$STATE/gate"
OUT=$(run project NewProj --token-from agent-old --main-gate < /dev/null 2>&1); RC=$?
check "--main-gate project run: completes"        test "$RC" -eq 0
check "  its verify ran the main gate"            grep -q "GATE VERIFIED on allen/NewProj" <<<"$OUT"
check "  checklist: close the verification PR"    grep -qx "Close or approve-and-merge the verification PR in the browser." <<<"$OUT"
check "  checklist: allowlist sentence kept"      grep -q "^Allowlist extra domains in .*/newproj/allowlist" <<<"$OUT"
fullstate; plan_fence allen/p1
OUT2=$(run project NewProj --token-from agent-old < /dev/null 2>&1); RC2=$?
check "project whose container works on another repo: verify dies" bash -c '[ "$1" -ne 0 ] && grep -q "the container newproj-agent-1 works on allen/p1, not allen/NewProj" <<<"$2"' _ "$RC2" "$OUT2"
check "  ...before any push"                      bash -c '[ ! -s "$1" ]' _ "$STATE/pushes"
fullstate   # back to the fence plan for the checks below
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
check "  earlier steps all SKIPPED (main not pushed again)" lacks "$GITLOG" '^GIT: push( -u)? origin '
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
LIVE_NORM='branch|active|RepositoryRole:5:pull_request|deletion,non_fast_forward,pull_request,required_status_checks|pr:1:true:true:false|R-CMD-check+gitleaks|refs:~DEFAULT_BRANCH/|strict:false|merge,rebase,squash|upd:-'
touch "$STATE/collab" "$STATE/has-codeowners" "$STATE/has-gitleaks"; echo 7 > "$STATE/ruleset-id-protect-main"; echo "$LIVE_NORM" > "$STATE/ruleset-norm-protect-main"
check "--require R-CMD-check matches C-sorted norm (default locale)" run protect allen/repo1 --vault agent-p1 --require R-CMD-check --main-gate
check "  and under en_US.utf8" env LC_ALL=en_US.utf8 HOME="$H" AGENT_CONTAINERS_CONFIG="$CFGROOT" PATH="$T/bin:$PATH" "$AN" protect allen/repo1 --vault agent-p1 --require R-CMD-check --main-gate
check "  nothing POSTed" test ! -f "$STATE/ruleset-posted-protect-main"

newstate
refuses "project --vault refused" 'project always uses vault agent-<project>' run project NoVault --vault foo < /dev/null
for f in --migrate --retire-main-gate; do
  newstate
  refuses "project $f: usage error"                  'are for agent-new protect, not project' run project NoFlag "$f" < /dev/null
  check "  nothing ran"                               bash -c '[ ! -s "$1" ]' _ "$GHLOG"
done

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
