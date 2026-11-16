# 1Password Sign-in Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every launcher run that needs the owner's 1Password session checks it first (signing in on the spot at a terminal), and `agent-up up` fetches the project's service-account token itself when none is set.

**Architecture:** One helper, `op_ready`, defined in `bin/agent-up` and duplicated in `bin/agent-new` (the two scripts share no library; `agent-new` already re-implements `ts_port` "as in agent-up"). `cmd_update` calls it first; `cmd_up` calls it only when no token is in the environment, then reads the one Personal-vault item.

**Tech Stack:** Bash, the `op` CLI (>= 2.6.2), the existing stub-based launcher tests.

**Spec:** `docs/specs/2026-11-16-op-signin-check-design.md`

## Global Constraints

- The launcher reads exactly one item per project on the owner's session: `op://Personal/agent-<project> service account/credential`. No `op vault list`, no other `op read`, on the owner's session in `agent-up`.
- Nothing new reaches a container: no `OP_*` variable, no session, no service-account token.
- No token or session is written to disk or exported to the calling shell.
- Research projects never trigger `op whoami`, `op signin` or `op read`.
- `op_ready` unsets `OP_SERVICE_ACCOUNT_TOKEN` before `op whoami` (a project token makes `op` act as that service account, which cannot see `Personal`).
- Sign-in form: `eval "$(op signin)"`, the form `agent-new` already uses.
- Die message when it cannot sign in, exact text after the script prefix: `1Password: not signed in. Sign in first: eval "$(op signin)"`.
- Branch: `feat/op-signin-check` from `main`. One PR. Do not touch `.github/workflows/`.

## Review Focus

1. `op` is not installed: the run dies with a message naming `op`, before changing anything (not a bare "command not found").
2. `op signin` exits 0 but `op whoami` still fails (wrong account picked): the run dies with the sign-in message; it does not loop or continue.
3. `agent-up update` pulls `main` and re-execs itself: the owner is asked to sign in at most once across both processes.
4. `agent-up up B` with project A's token still exported: behaves exactly as today (uses the given token, never touches the owner's session). The plan must not "helpfully" override a set token.

---

### Task 1: `op_ready` and `agent-up update`

**Files:**
- Modify: `bin/agent-up` (new function near `check_project_env`, ~line 512; `cmd_update`, ~line 1132-1147)
- Test: `tests/launcher/test-agent-up.sh` (the `op` stub at ~line 36; a new section after the existing `update` tests, before the `update_guard` tests at ~line 1740)

**Interfaces:**
- Produces: `op_ready()` in `bin/agent-up`. No arguments. Returns 0 when `op whoami` succeeds (after signing in if needed); otherwise dies. Side effects: unsets `OP_SERVICE_ACCOUNT_TOKEN`; may export `OP_SESSION_*` (from `op signin`) into the launcher's own process.
- Produces (test seam): the `op` stub understands `whoami` and `signin`, driven by marker files next to `$OPLOG`:
  - `OP_SIGNED_OUT` present: `op whoami` exits 1.
  - `op signin`: if `OP_SIGNIN_FAIL` present, exit 1; else if `OP_SIGNIN_NOOP` absent, remove `OP_SIGNED_OUT`; print `export OP_SESSION_test=1`; exit 0.
  - every call is still logged as `OP: <args>`.

- [ ] **Step 1: Extend the `op` stub** in `tests/launcher/test-agent-up.sh` with the `whoami` and `signin` branches above, placed before the existing `read` branch. Today an unknown subcommand falls through to `exec "$@"` with no arguments and exits 0 by accident; `whoami` and `signin` must be explicit.

- [ ] **Step 2: Write the failing tests** in a new section `# ---- 1Password sign-in check`, reusing `uenv`, `ureset`, `uup`, `ucfg` from the update section. `tty(){ script -qec "$*" /dev/null; }` gives a command a terminal on stdin.

```bash
ureset alpha beta; touch "$T/OP_SIGNED_OUT"; cp "$(ucfg alpha)" "$T/a.before"
refuses "update: signed out, no terminal -> dies with the sign-in message" \
  'not signed in\. Sign in first: eval "\$\(op signin\)"' au update --all
check "  ...before anything else: no op read, no compose up, compose.yaml untouched" \
  bash -c '! grep -q "^OP: read" "$1" && [ "$2" -eq 0 ] && cmp -s "$3" "$4"' _ "$OPLOG" "$(uup alpha)" "$(ucfg alpha)" "$T/a.before"
check "  ...op whoami was the first op call" bash -c '[ "$(head -n1 "$1")" = "OP: whoami" ]' _ "$OPLOG"

ureset alpha; touch "$T/OP_SIGNED_OUT"
check "update: signed out at a terminal -> signs in and updates" \
  bash -c 'o=$(script -qec "$1" /dev/null) && grep -q "1Password: not signed in. Signing in:" <<<"$o" && grep -q "^OP: signin" "$2" && [ "$(grep -cE "up -d" "$3")" -ge 1 ]' _ "<the au update alpha command line>" "$OPLOG" "$DLOG"

ureset alpha; touch "$T/OP_SIGNED_OUT" "$T/OP_SIGNIN_FAIL"
refuses "update: sign-in fails at a terminal -> dies, nothing changed" 'not signed in' tty <au update alpha>
rm -f "$T/OP_SIGNIN_FAIL"; touch "$T/OP_SIGNIN_NOOP"
refuses "update: sign-in exits 0 but still signed out -> dies, no loop" 'not signed in' tty <au update alpha>
check "  ...exactly one signin attempt" bash -c '[ "$(grep -c "^OP: signin" "$1")" -eq 1 ]' _ "$OPLOG"
rm -f "$T"/OP_SIGN*

ureset alpha; : > "$OPLOG"
check "update: signed in -> silent (no 1Password line in the output)" bash -c '! grep -q "1Password" <<<"$1"' _ "$(au update alpha </dev/null 2>&1)"

uset research ghcr.io/allenlarocque/spades-base "$OLD1"; uidle research; : > "$OPLOG"; touch "$T/OP_SIGNED_OUT"
check "update research only: signed out is fine, op never called" \
  bash -c 'au_out=$("$@" 2>&1); [ ! -s "$OPLOG" ]' _ <au update research>
rm -f "$T/OP_SIGNED_OUT"

check "update: op not installed -> dies naming op" \
  bash -c 'o=$(<au update alpha with PATH="$T/dstub:/usr/bin:/bin" and no op on it> 2>&1); [ $? -ne 0 ] && grep -q "1Password CLI (op) not found" <<<"$o"'
```

  Write the `<…>` placeholders as real invocations in the file's existing style (`au` is a shell function, so for `script` build the full `env … "$AU" update alpha` command string the way `aureal`/line 1752 do). For "op not installed", build a PATH that has `$T/dstub` and the system dirs but not `$T/bin`, and skip the test with an `OK: (skipped: op is installed system-wide)` line if `command -v op` still resolves.

- [ ] **Step 3: Run the tests; they must fail**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E "^FAIL" | head`
Expected: the new checks FAIL (no `op whoami` call exists yet); no previously passing check fails.

- [ ] **Step 4: Implement `op_ready()` in `bin/agent-up`**

Behaviour, in order: `unset OP_SERVICE_ACCOUNT_TOKEN`; if `op` is not on PATH, die `1Password CLI (op) not found: install it (docs/runbooks/1password-project-vault.md)`; `op whoami >/dev/null 2>&1 </dev/null` succeeds -> return; if `[ -t 0 ]`, print `agent-up: 1Password: not signed in. Signing in:` to stderr, run `eval "$(op signin)"` (ignore its status), then `op whoami` once more and return on success; otherwise die with the Global Constraints message. One sign-in attempt only.

- [ ] **Step 5: Call it from `cmd_update`** immediately after `names` is built and before `[ -f "$digests" ]` / `update_guard`, only when at least one name in `names` has `profile != research` (use the existing `profile "$CFG_ROOT/$n"`; a name whose config is invalid counts as needing it). The existing `unset OP_SERVICE_ACCOUNT_TOKEN` further down stays.

- [ ] **Step 6: Pin Review Focus 3.** In the existing "update_guard pull + re-exec" test (~line 1786, the helper that runs `$c/bin/agent-up update`), add one run with `OP_SIGNED_OUT` present under `tty`, and assert `grep -c "^OP: signin" "$OPLOG"` is exactly 1 and the pulled run completed. (`OP_SESSION_*` is exported by the `eval`, so it survives the `exec`; the stub also removes the marker.)

- [ ] **Step 7: Run the whole file**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -cE "^FAIL"`
Expected: `0`

- [ ] **Step 8: Commit**

```bash
git add bin/agent-up tests/launcher/test-agent-up.sh
git commit -m "feat(agent-up): update checks the 1Password sign-in first, and signs in at a terminal"
```

### Task 2: `agent-up up` fetches its own token

**Files:**
- Modify: `bin/agent-up` (`cmd_up`, the non-research branch at ~line 855-863; usage text at line 18)
- Test: `tests/launcher/test-agent-up.sh` (line 185 and a new block right after it)

**Interfaces:**
- Consumes: `op_ready()` from Task 1; the stub's `read` branch (prints `sat-<project>`, fails when `OPREAD_FAIL_<project>` exists).
- Produces: `cmd_up` works with `OP_SERVICE_ACCOUNT_TOKEN` unset. Nothing else changes for callers that set it (`cmd_update`, `agent-new`).

- [ ] **Step 1: Replace the test at line 185** (`up refuses without OP_SERVICE_ACCOUNT_TOKEN`) with:

```bash
TOK=""; : > "$OPLOG"; : > "$DLOG"
check "up with no token: reads the project's own service-account item and starts" au up "$NAME"
check "  ...op calls, in order: whoami, read (that one item), run" \
  bash -c 'diff <(sed -E "s/^(OP: run) .*/\1/" "$1") <(printf "%s\n" "OP: whoami" "OP: read op://Personal/agent-$2 service account/credential" "OP: run")' _ "$OPLOG" "$NAME"
check "  ...op run got that token; the container did not" \
  bash -c 'grep -qx "OPTOK: sat-$2" "$1" && ! grep -q "OP_SERVICE_ACCOUNT_TOKEN" <(grep "^ENV:" "$1")' _ "$DLOG" "$NAME"
touch "$T/OPREAD_FAIL_$NAME"
refuses "up with no token: a failed read dies naming the item and the runbook" \
  "op://Personal/agent-$NAME service account/credential.*1password-project-vault\.md" au up "$NAME"
rm -f "$T/OPREAD_FAIL_$NAME"
touch "$T/OP_SIGNED_OUT"
refuses "up with no token, signed out, no terminal: dies with the sign-in message" 'not signed in' au up "$NAME"
TOK=given-token; : > "$OPLOG"
check "up with a token set: uses it; no whoami, no read (signed out does not matter)" \
  bash -c '"$@" && ! grep -qE "^OP: (whoami|read|signin)" "$OPLOG"' _ au up "$NAME"
rm -f "$T/OP_SIGNED_OUT"; TOK=""
```

  Note the stub docker logs `OPTOK:` from compose's environment; confirm from the existing tests around line 649-655 which assertion shape matches how the token is visible there and keep the same shape. Then scan the file for other calls that relied on `up` refusing without a token (`grep -n 'TOK=""' tests/launcher/test-agent-up.sh`) and adjust any that now succeed.

- [ ] **Step 2: Run; the new checks must fail**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E "^FAIL" | head`
Expected: the five new checks FAIL with the old "OP_SERVICE_ACCOUNT_TOKEN is not set" refusal.

- [ ] **Step 3: Implement in `cmd_up`.** Replace the `[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || die …` line: when the variable is empty, call `op_ready`, read `op://Personal/agent-$name service account/credential` with stdin from `/dev/null` and stderr discarded into a `local` variable, die if the read fails or is empty with `could not read op://Personal/agent-$name service account/credential (docs/runbooks/1password-project-vault.md)`, and pass it to the one `op run` as `OP_SERVICE_ACCOUNT_TOKEN="$tok" op run …` (command-scoped, not exported). When the variable is set, the `op run` line runs exactly as today. Update the usage line 18 to say the token is read from the Personal vault when not set.

- [ ] **Step 4: Run the whole file, then the agent-new tests (they call `agent-up up`)**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -cE "^FAIL"; bash tests/launcher/test-agent-new.sh 2>&1 | grep -cE "^FAIL"`
Expected: `0` and `0`

- [ ] **Step 5: Commit**

```bash
git add bin/agent-up tests/launcher/test-agent-up.sh
git commit -m "feat(agent-up): up reads the project's service-account token itself when none is set"
```

### Task 3: `agent-new` uses the same check

**Files:**
- Modify: `bin/agent-new` (`project_vault` line 142-144, `project_up` line 206, `cmd_protect` line 372, `cmd_verify` line 393; new `op_ready` near `die`)
- Test: `tests/launcher/test-agent-new.sh` (its own `op` stub and a new block)

**Interfaces:**
- Produces: `op_ready()` in `bin/agent-new`, same behaviour and messages as Task 1 with the `agent-new:` prefix, headed by a comment `# as in agent-up`.

- [ ] **Step 1: Read `tests/launcher/test-agent-new.sh`'s `op` stub** and add the same `whoami` / `signin` marker-file behaviour as Task 1 Step 1.

- [ ] **Step 2: Write the failing tests**: with `OP_SIGNED_OUT` present and no terminal, each of `agent-new verify <project>`, `agent-new protect <owner>/<repo>` and the project flow at the `up` step (use the existing `AGENT_NEW_STOP_AFTER` seam to reach it) is refused with `not signed in\. Sign in first`, and the op log's first line is `OP: whoami` with no `OP: read` after it. With the marker absent, the existing tests still pass unchanged.

- [ ] **Step 3: Run; expect the new checks to FAIL**

Run: `bash tests/launcher/test-agent-new.sh 2>&1 | grep -E "^FAIL" | head`

- [ ] **Step 4: Implement.** Add `op_ready`; in `project_vault` replace `eval "$(op signin)"` with `op_ready` (keep the `say` line); call `op_ready` at the top of `project_up`'s non-research path, `cmd_verify`, and `cmd_protect`. These are top-level calls, never inside `$(…)`: a sign-in inside a command substitution would be lost and prompt again. `project_up` keeps passing the token it read to `agent-up up` (so `up` does not read a second time).

- [ ] **Step 5: Run both launcher test files**

Run: `bash tests/launcher/test-agent-new.sh 2>&1 | grep -cE "^FAIL"; bash tests/launcher/test-agent-up.sh 2>&1 | grep -cE "^FAIL"`
Expected: `0` and `0`

- [ ] **Step 6: Commit**

```bash
git add bin/agent-new tests/launcher/test-agent-new.sh
git commit -m "feat(agent-new): every step that reads 1Password checks the sign-in first"
```

### Task 4: Docs, lint, PR

**Files:**
- Modify: `docs/runbooks/1password-project-vault.md` (the "Read at use time" bullet, lines ~42-55), `README.md` (wherever `agent-up up` is shown with an exported token), `docs/specs/2026-10-03-agent-containers-design.md` (dated amendment under §5)

- [ ] **Step 1: Runbook.** "Read at use time" becomes: run `agent-up up <project>`; it checks the sign-in and reads the one item `op://Personal/agent-<project> service account/credential` for that command. Keep the `export … op read` form as the alternative for a project whose item is named differently, with its existing `unset` warning.

- [ ] **Step 2: Spec amendment**, headed `## Amendment 2026-11-16: up may read the service-account item`: three lines stating that `agent-up up` (like `update` and `agent-new up` before it) reads that single item on the owner's session when no token is set; that it reads nothing else; that containers are unaffected. Link the design doc.

- [ ] **Step 3: Lint as CI does**

Run: `shellcheck bin/agent-up bin/agent-new tests/launcher/*.sh`
Expected: no new findings compared with `main` (`git stash; shellcheck … > /tmp/before; git stash pop` if unsure).

- [ ] **Step 4: Commit, push, open the PR**

```bash
git add docs README.md
git commit -m "docs: up reads its own 1Password token; sign-in check"
git push -u origin feat/op-signin-check
gh pr create --fill
```

PR body: why (owner forgets to sign in before `update --all`), what changed, test counts from both launcher files, and what was not checked (a real `op signin` prompt: the tests stub `op`). Ask the owner to try `agent-up update --all` signed out once before merging.
