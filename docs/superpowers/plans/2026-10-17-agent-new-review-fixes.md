# agent-new review fixes — implementation plan (2026-10-17)

Source: the full review of `feat/agent-new` (0725e57) on 2026-10-17. Branch: `fix/agent-new-review`
(from `origin/feat/agent-new`). Files: `bin/agent-new`, `tests/launcher/test-agent-new.sh`, plus
docs where the behaviour changes. Spec: `docs/specs/2026-10-15-agent-new-design.md`.

Ground rules for every task:
- Test first: add or adjust a case in `tests/launcher/test-agent-new.sh` that FAILS on the current
  code, then fix `bin/agent-new`, then run `bash tests/launcher/test-agent-new.sh` (must end
  `AGENT-NEW: ALL PASSED`) and `shellcheck bin/agent-new tests/launcher/test-agent-new.sh` if
  shellcheck is installed.
- Match the script's style: terse one-line helpers, `say`/`skip`/`warn`/`die`, comments only where
  the reason is not obvious. No new dependencies.
- No real gh/op/git/docker/tailscale: extend the existing stubs.
- One commit per task, conventional message `fix(agent-new): ...`.

## Task 1 — small, independent hardening
1. **Hermetic tests:** the suite fails when `GH_TOKEN` is set in the caller's environment (the gh stub
   logs `GH(mu)` for every call). `unset GH_TOKEN GITHUB_TOKEN OP_SERVICE_ACCOUNT_TOKEN` near the top
   of the test file.
2. **Inherited service-account token:** `unset OP_SERVICE_ACCOUNT_TOKEN` once, right after
   `set -euo pipefail`, with a one-line comment. agent-new acts as the owner. The service-account
   token is only ever set explicitly, per command. That fixes `project_vault` calling
   `op signin`/`vault create`/`service-account create` with a leftover token. Keep the existing
   per-call unsets. Test: export a fake `OP_SERVICE_ACCOUNT_TOKEN` and make the op stub log
   `OP(sa): ...` when it is set. Assert no `OP(sa): vault create` or `OP(sa): signin` lines.
3. **Locale-independent sort:** `checks_sorted` must use `LC_ALL=C sort -u`, matching jq's codepoint
   sort. Test: `--require R-CMD-check` with the live norm `...|R-CMD-check+gitleaks|...` →
   SKIP (matches), even under `LC_ALL=en_US.UTF-8` if that locale exists. If not, assert the
   expected string order directly.
4. **`--vault` with `project`:** the spec has no `--vault` for `project`, and `project.env` from
   `agent-up init` hard-codes `op://agent-<project>/...`. Make `agent-new project ... --vault X` die
   with a clear message ("project always uses vault agent-<project>"). Test with `refuses`.
5. **One port helper:** replace the two copies of `port="${port:-$((8443 + t3 - 3774))}"` with one
   `ts_port <conf>` helper that mirrors `bin/agent-up`'s `ts_port_raw`/`ts_port`: decimal `10#`
   handling and validation of 1–65535 (die otherwise). Test: `T3_PORT=03778` gives 8447, and a
   non-numeric override dies.
6. **Digest fallback:** the fallback `sed -i "s|@.*$|@$digest|"` rewrites every line with an `@`.
   Restrict it to the image line (`/^[[:space:]]*image:.*spades-/`). Test: a compose fixture with an
   extra `@` line (for example a comment with an email) keeps that line unchanged when the fallback
   runs.

## Task 2 — Tailscale: tailnet-only check per mapping
`project_tailscale` currently passes if ANY line says `(tailnet only)`. `tailscale serve status`
prints blocks like:
```
https://host.ts.net:8447 (tailnet only)
|-- / proxy http://127.0.0.1:3778
```
and `(Funnel on)` in the header for public ones. Write one awk helper that, given the T3 port, finds
every block whose proxy target is `127.0.0.1:$t3` (or `localhost:$t3`, with the port followed by a
non-digit or end of line). It prints `ok` if there is at least one and ALL their headers contain
`(tailnet only)`, `public` if any header lacks it, and `none` if there is no block. Use it for both
the "mapping exists" skip and the safety check. Die on `public` (keep the "NEVER use Funnel"
wording). Tests:
- this port public, another port tailnet-only → dies (this is the bug);
- this port tailnet-only, another port Funnel → passes;
- the existing prefix-port case (37780 vs 3778) still holds.

## Task 3 — research: do not die, do not pass the token
`project_up` runs `agent-up up research` with the project's service-account token. agent-up strips
it, and the call dies if `~/.config/agent-containers/research` does not exist, killing the run before
verify.
- Never pass the token to `agent-up up research`; run it with `env -u OP_SERVICE_ACCOUNT_TOKEN`.
- If `$CFG_ROOT/research` does not exist: `warn` that research is on but there is no research
  container yet. Tell the owner what to run (`agent-up init --profile research`, then
  `agent-up up research`) and continue. Do NOT auto-create it.
- If it exists: run `agent-up up research` (this restarts research so it mounts the new project's
  exchange folder, so say that in the `say` line).
- Mention the missing-research case in the final checklist too.
Tests: the stub's agent-up log shows `AU: up research` (NO `(tok)`); with no research config there
is no research up, a WARNING is shown, and the run still reaches verify and the checklist.

## Task 4 — resumable repo files + loud ruleset errors
1. `project_repo_files`: after the commit, a failed push is never retried, because re-runs only look
   at staged changes. New logic: commit if anything is staged. Then push if local `HEAD` exists and
   differs from `refs/remotes/origin/main` (missing remote ref = differs). Otherwise SKIP. Update the
   git stub so `push` also runs
   `"$REALGIT" update-ref refs/remotes/origin/main HEAD` (when run inside a repo), so the
   "no push on re-run" test still holds. New test: make the stub push fail once (state file), check
   that the run dies, then re-run and assert that a push happens.
2. `protect_ruleset`: the rulesets list call discards stderr and dies silently under set -e. Capture
   the output and rc. On failure, `die "could not list rulesets on $repo (needs admin; private repos
   on GitHub Free have no rulesets): <gh output>"`, and say that re-running resumes. Test: the gh stub
   fails the list call when a state file exists → `refuses` with /could not list rulesets/.

## Task 5 — verify: fresh branch, right identity, clean workspace, patient checks
1. **Container mode** must not touch the owner's checkout: do the work in a temporary worktree
   inside the container:
   `git fetch -q origin && git worktree add -f -B verify-ruleset /tmp/agent-new-verify origin/main`,
   then run the commit, push, gh and refusal commands with `-w`/`cd` in that worktree. Clean up with
   `git worktree remove --force /tmp/agent-new-verify` in an EXIT trap (same frozen-value idiom, and
   `|| true`). Then delete the "switch back to main" line.
2. **Fresh base in both modes:** the branch always starts from `origin/main`, freshly fetched. Push
   with `git push -f -u origin verify-ruleset` (the throwaway branch is not protected, and a
   force-push replaces a leftover from an earlier run). Then `push origin HEAD:main` is a
   fast-forward, so a refusal can only be the ruleset (GH013), not "non-fast-forward".
3. **Repo mode identity:** before cloning, assert `GH_TOKEN="$tok" gh api user --jq .login` equals
   `machine_user`, or die. Clone over HTTPS with git isolated from the owner's config:
   `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`, and a credential helper supplied through
   `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0`, with
   `credential.helper='!f(){ echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'`. The
   token stays in the environment only, never in argv or on disk. Set the commit identity to the
   machine user (`user.name`, `user.email` = `<mu>@users.noreply.github.com`) through the same
   mechanism. Clone with `git clone https://github.com/$VTARGET`, not `gh repo clone`, so gh's
   `git_protocol` cannot switch it to SSH. Update the stubs, and add tests that assert the identity
   check dies when the token resolves to the owner and that the clone URL is https.
   **Container mode identity:** run `gh api user --jq .login` in the container and compare it to
   `machine_user` (die on mismatch).
4. **Checks race:** `gh pr checks --watch` straight after `gh pr create` can say "no checks
   reported" before CI registers. Retry up to `${AGENT_NEW_CHECK_TRIES:-6}` times with
   `sleep ${AGENT_NEW_CHECK_SLEEP:-10}` while the output says "no checks reported". Only then warn
   UNTESTED. Tests set both to small values: 2 and 0.
Tests: update the docker stub's plan to the worktree flow. Assert no `switch main` and that
`worktree remove` was called, also on a failing run.

## Task 6 — secrets off argv (BLOCKED on the research brief)
`op item create ... "credential[concealed]=$tok"` and `"token[concealed]=$ghtok"` put secrets in
argv. Brief: `/research/briefs/2026-10-17-op-item-create-stdin.md`. Do not implement until the
documented stdin-template syntax is confirmed from official 1Password docs.

## Task 7 — docs
Update the spec and `docs/runbooks/new-project.md` only where behaviour changed: research skip/warn,
`--vault` rejected for `project`, the verify worktree, and the identity checks. Keep it short.
