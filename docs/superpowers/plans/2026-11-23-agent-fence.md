# Agent fence and `allen-dev` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `agent-new protect` sets a repo up with one fence (two rulesets), an `allen-dev` working branch and auto-delete on merge; `agent-new verify` proves the fence; every builder is told the workflow.

**Architecture:** All GitHub changes stay in `bin/agent-new`, run as the owner through `gh api`. The single `protect-main` template becomes a small table of ruleset templates sharing one create/compare/refuse routine. `bin/agent-up` gains one generated instruction file for builders. No container or image change.

**Tech Stack:** bash, `gh api`, `jq` expressions passed to `gh --jq`; tests are the stub-driven shell suites in `tests/launcher/`.

**Spec:** `docs/specs/2026-11-21-agent-dev-branch-design.md`

## Global Constraints

- The working branch is named `allen-dev`.
- Free prefixes, exactly: `fix`, `feature`, `chore`, `docs`, `test`, `ci`, `refactor`, `perf`, `revert`, `upstream`, `sync`, `experiment`. No `feat`, no `release`.
- Ruleset names: `agent-fence` (target `branch`) and `agent-fence-tags` (target `tag`). Admin bypass is `{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}` on both.
- `agent-new` never changes a ruleset that exists and differs from its template, except the three exact cases under `--migrate` (Task 3).
- Nothing in this plan runs against a real GitHub repo, the owner's `~/.config/agent-containers`, or a real container. Tests use the stubs only.
- Weak-point detail does not go in commit messages, code comments or docs in this repo.
- Messages use the existing helpers `say`, `skip`, `warn`, `die`. shellcheck must stay clean (`lint` is a required check).
- Run both suites before every commit: `bash tests/launcher/test-agent-new.sh` and `bash tests/launcher/test-agent-up.sh`; each must end `ALL PASSED`.

## Rulings made while planning

- **The main gate is opt-in by flag, not by repo name.** The spec says `protect-main` stays on `agent-containers`. The tool gets `--main-gate`: with it, `protect` creates or checks `protect-main` exactly as today and `--migrate` never deletes it. Without it, `protect` does not create `protect-main`. Cost if wrong: one flag to remember for `agent-containers`.
- **`CODEOWNERS` handling in the project template is left alone.** New projects still get the file from `agent-up init`; it is harmless without `protect-main`. Removing it touches `agent-up`, both test suites and two runbooks, and is not needed for the goal. The `protect` warnings about a missing `CODEOWNERS` and a missing gitleaks workflow are printed only with `--main-gate`.
- **A ruleset named `main` on the default branch is treated as `protect-main`** wherever `protect-main` is looked up (three of the owner's repos use that name).

## Review Focus

- **Default branch is not `main`** (`master`, `dev`, `development`): `allen-dev` must be created from the real default branch and `verify` must test the real default branch. Tasks 2 and 5.
- **`allen-dev` already exists**, possibly diverged: left untouched, reported as done. Task 2.
- **Rulesets unavailable** (private repo on a free plan; the list call fails): `protect` fails for that repo with today's message and creates no branch. Task 2.
- **`--migrate` away from a terminal:** nothing is deleted; a warning says so; the run still succeeds. Task 3.
- **One repo of several fails:** the others are still processed and the summary names each. Task 4.

---

### Task 1: Fence templates and a shared ruleset routine

**Files:**
- Modify: `bin/agent-new` (`NORM_JQ`, `ruleset_json`, `ruleset_norm_expected`, `protect_ruleset`)
- Test: `tests/launcher/test-agent-new.sh`

**Interfaces:**
- Produces:
  - `FREE_PREFIXES=(fix feature chore docs test ci refactor perf revert upstream sync experiment)` and `WORK_BRANCH=allen-dev`.
  - `ruleset_json <name>`: prints the JSON for `protect-main`, `agent-fence` or `agent-fence-tags`.
  - `ruleset_norm_expected <name>`: the normalised string for that template.
  - `ensure_ruleset <owner/repo> <name>`: creates the ruleset when no ruleset of that name exists; `skip`s when the live one normalises equal; otherwise prints live and template and `die`s with `refusing to modify`. For `protect-main` a live ruleset named `main` counts as the same ruleset.
  - `ruleset_id <owner/repo> <name>`: prints the id or nothing; dies with today's "could not list rulesets" message when the list call fails.
- `NORM_JQ` gains `.target` as its first field, so a branch ruleset and a tag ruleset can never compare equal. Update the `protect-main` expected string and the tests' `EXPECT_NORM` to match.

The two new templates, exactly:

```json
{"name": "agent-fence", "target": "branch", "enforcement": "active",
 "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
 "conditions": {"ref_name": {"include": ["~ALL"], "exclude": [
   "refs/heads/allen-dev", "refs/heads/fix/**", "refs/heads/feature/**", "refs/heads/chore/**",
   "refs/heads/docs/**", "refs/heads/test/**", "refs/heads/ci/**", "refs/heads/refactor/**",
   "refs/heads/perf/**", "refs/heads/revert/**", "refs/heads/upstream/**", "refs/heads/sync/**",
   "refs/heads/experiment/**"]}},
 "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}, {"type": "non_fast_forward"}]}
```

```json
{"name": "agent-fence-tags", "target": "tag", "enforcement": "active",
 "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
 "conditions": {"ref_name": {"include": ["~ALL"], "exclude": []}},
 "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}]}
```

The `exclude` list is generated from `WORK_BRANCH` and `FREE_PREFIXES`, not typed twice.

- [ ] **Step 1: Write failing tests** in a new section `== fence: templates ==`. The stub `gh` must answer the ruleset list per name (state files `ruleset-id-<name>`, `ruleset-norm-<name>`) and record each POST body per name (`ruleset-posted-<name>`). Assertions, calling the functions through `protect` once Task 2 wires them, or through a `AGENT_NEW_STOP_AFTER`-style seam if needed now:
  - no fence present: one POST each for `agent-fence` and `agent-fence-tags`;
  - posted `agent-fence` has `"target": "branch"`, bypass mode `always`, the four rule types, `~ALL`, and each of the 13 exclude entries; it contains neither `refs/heads/feat/**` nor `refs/heads/release/**`;
  - posted `agent-fence-tags` has `"target": "tag"` and an empty `exclude`;
  - live fence equal to the template: `SKIP`, nothing posted;
  - live fence with one exclude entry missing: refused with `refusing to modify`, nothing posted;
  - a tag ruleset stored under the name `agent-fence`: refused (the `.target` field).
- [ ] **Step 2: Run** `bash tests/launcher/test-agent-new.sh`. Expected: the new checks FAIL, the rest pass.
- [ ] **Step 3: Implement** the interfaces above. Keep `protect_ruleset` behaviour for `protect-main` unchanged apart from the `.target` field and the `main` alias.
- [ ] **Step 4: Run** both suites. Expected: `ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-new): fence ruleset templates and a shared ensure routine`.

### Task 2: `protect` builds the fence, the working branch and auto-delete

**Files:**
- Modify: `bin/agent-new` (`cmd_protect`, `protect_warnings`, `usage`, flag parsing)
- Test: `tests/launcher/test-agent-new.sh`

**Interfaces:**
- Consumes: `ensure_ruleset`, `WORK_BRANCH`.
- Produces: flags `--main-gate` (sets `MAIN_GATE=1`) and `--no-working-branch` (sets `WORK_BRANCH_ON=0`); functions `protect_work_branch <owner/repo>` and `protect_autodelete <owner/repo>`.

`cmd_protect <owner/repo>` order: collaborator (unchanged); `ensure_ruleset agent-fence`; `ensure_ruleset agent-fence-tags`; `protect_work_branch` unless `--no-working-branch`; `protect_autodelete`; with `--main-gate`, `ensure_ruleset protect-main` and today's warnings; `say "protect: done (<repo>)"`.

GitHub calls to use:
- default branch: `gh api "repos/$repo" --jq .default_branch`
- branch exists: `gh api "repos/$repo/branches/allen-dev"` (non-zero when missing)
- head sha: `gh api "repos/$repo/git/ref/heads/$default" --jq .object.sha` (fails on a repo with no commits: `die "… has no commits: nothing to branch allen-dev from"`)
- create: `gh api -X POST "repos/$repo/git/refs" -f ref=refs/heads/allen-dev -f sha="$sha"`
- auto-delete: read `gh api "repos/$repo" --jq .delete_branch_on_merge`; set with `gh api -X PATCH "repos/$repo" -F delete_branch_on_merge=true`

The fence is created before the branch, so a repo whose rulesets cannot be listed gets no branch.

- [ ] **Step 1: Write failing tests**, section `== fence: protect ==`, extending the stub for the calls above (state: `default-branch` content, `has-allen-dev`, `no-commits`, `autodelete` content):
  - fresh repo, default branch `master`: fence pair posted; a POST to `git/refs` with `ref=refs/heads/allen-dev` and the sha of `master`; PATCH with `delete_branch_on_merge=true`; no POST of `protect-main`; no `CODEOWNERS` warning;
  - `allen-dev` exists: `SKIP`, no POST to `git/refs`;
  - auto-delete already true: `SKIP`, no PATCH;
  - `--no-working-branch`: no call to `branches/allen-dev` or `git/refs`;
  - `--main-gate`: `protect-main` posted with the `--require` checks, and the missing-`CODEOWNERS` warning appears;
  - ruleset list fails: non-zero exit, `could not list rulesets`, and no POST to `git/refs`;
  - repo with no commits: refused with `no commits`.
  Update the existing "task 3: protect" tests to pass `--main-gate`, since they test the main gate.
- [ ] **Step 2: Run** the suite. Expected: new checks FAIL.
- [ ] **Step 3: Implement.** `cmd_project` keeps calling `cmd_protect "$REPO"` and so now gets the fence; its `cmd_verify` call is fixed in Task 5.
- [ ] **Step 4: Run** both suites. Expected: `ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-new): protect sets up the fence, allen-dev and auto-delete`.

### Task 3: `--migrate`

**Files:**
- Modify: `bin/agent-new`
- Test: `tests/launcher/test-agent-new.sh`

**Interfaces:**
- Consumes: `ruleset_id`, `ruleset_json`, `NORM_JQ`.
- Produces: flag `--migrate` (`MIGRATE=1`); `migrate_fence <owner/repo>` called at the start of `cmd_protect` (after the collaborator step); `migrate_main_gate <owner/repo>` called at the end; `confirm <question>` returning 0 for yes.

Behaviour, and nothing beyond it:
1. No `agent-fence`, and a `protect-fork` whose normalised form is exactly `branch|active|RepositoryRole:5:always|creation,deletion,non_fast_forward,update|pr:-||refs:~ALL/refs/heads/feature/**,refs/heads/fix/**|strict:-|`: `PUT "repos/$repo/rulesets/$id"` with the `agent-fence` JSON (this renames it). Any other `protect-fork`: `die` with `refusing to modify`.
2. Same for `protect-fork-tags` in exactly the form `tag|active|RepositoryRole:5:always|creation,deletion,update|pr:-||refs:~ALL/|strict:-|`, to `agent-fence-tags`.
3. After both fence rulesets match their templates, and only without `--main-gate`: for a ruleset named `protect-main` or `main` whose include is `~DEFAULT_BRANCH`, print its normalised form, ask `delete ruleset '<name>' on <repo>? [y/N]`, and on yes `gh api -X DELETE "repos/$repo/rulesets/$id"`.

Without `--migrate`, a `protect-fork` in the old shape is reported (`warn` naming `--migrate`) and `ensure_ruleset agent-fence` then creates the new fence beside it; this is harmless (the stricter of the two applies) but the warning must say the agent is still limited to `fix/` and `feature/` until migrated.

`confirm`: reads one line from stdin only when `[ -t 0 ]`; the test seam `AGENT_NEW_CONFIRM=y|n` overrides. Not a terminal and no seam: returns no, after `warn "not a terminal: <name> on <repo> was NOT deleted; re-run --migrate at a terminal"`.

- [ ] **Step 1: Write failing tests**, section `== fence: migrate ==`; the stub records `PUT` and `DELETE` calls:
  - old-shape `protect-fork` + `--migrate`: one PUT to its id whose body names `agent-fence`; no POST of `agent-fence`;
  - old-shape `protect-fork-tags` + `--migrate`: PUT naming `agent-fence-tags`;
  - `protect-fork` with a third exclude entry + `--migrate`: refused, no PUT;
  - old-shape `protect-fork` without `--migrate`: warning mentions `--migrate`; no PUT;
  - `protect-main` present, `--migrate`, `AGENT_NEW_CONFIRM=y`: one DELETE of its id, and it comes after the fence calls in the gh log;
  - same with `AGENT_NEW_CONFIRM=n`: no DELETE, exit 0;
  - same with no seam and stdin not a terminal: no DELETE, warning `NOT deleted`, exit 0;
  - `--migrate --main-gate`: no DELETE;
  - ruleset named `main`: treated the same as `protect-main`;
  - `--migrate` when the fence cannot be created (list fails): no DELETE.
- [ ] **Step 2: Run.** Expected: new checks FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both suites. Expected: `ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-new): --migrate renames the hand-made fence and retires the main gate`.

### Task 4: Several repos in one run

**Files:**
- Modify: `bin/agent-new` (dispatch at the bottom, `usage`)
- Test: `tests/launcher/test-agent-new.sh`

**Interfaces:**
- Produces: `agent-new protect <owner>/<repo>...`. Each repo runs `cmd_protect` in a subshell so a `die` ends only that repo. After the last: one line per repo, `protect: ok <repo>` or `protect: FAILED <repo>`; exit 1 if any failed. An argument without `/` fails the whole run before anything is done (today's `protect wants <owner>/<repo>`). `op_ready` runs once, before the loop, when `--vault` is given.

- [ ] **Step 1: Write failing tests**, section `== fence: several repos ==`. The stub fails the ruleset list only for a repo named in state file `fail-repo`:
  - three repos, the second failing: exit non-zero; gh log shows fence POSTs for the first and third; output has `protect: ok` for those two and `protect: FAILED` for the second;
  - three repos all fine: exit 0, three `protect: ok` lines;
  - `protect a/b notarepo`: refused before any gh call for `a/b`;
  - one repo still works and prints one `protect: ok` line.
- [ ] **Step 2: Run.** Expected: new checks FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both suites. Expected: `ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-new): protect takes several repos`.

### Task 5: `verify` proves the fence

**Files:**
- Modify: `bin/agent-new` (`cmd_verify`)
- Test: `tests/launcher/test-agent-new.sh`

**Interfaces:**
- Consumes: `RUN_IN`, `expect_refusal`, `WORK_BRANCH`, `MAIN_GATE`.
- Produces: `verify_fence` and `verify_main_gate` (today's five steps, unchanged), chosen inside `cmd_verify`: `--main-gate` runs `verify_main_gate`, otherwise `verify_fence`. Both set-up paths (temp clone, container worktree) are kept, but they start from the repo's default branch, read once with `RUN_IN 'gh repo view --json defaultBranchRef --jq .defaultBranchRef.name'`, not from a literal `main`.

`verify_fence`, as the machine user, with `$def` the default branch:
1. `expect_refusal "push to $def"` on `git push origin HEAD:$def` with an empty commit on top of `origin/$def`.
2. `expect_refusal "branch outside the free names"` on `git push origin HEAD:refs/heads/verify-fence-not-free`.
3. `expect_refusal "create a tag"` on `git push origin HEAD:refs/tags/verify-fence-tag`.
4. Push the same commit as `chore/verify-fence` (must succeed), open a PR into `$def`, and `expect_refusal "merge a PR into $def"` on `gh pr merge --squash`; then close that PR.
5. When `allen-dev` exists on the remote: a second empty commit on `origin/allen-dev` pushed as `chore/verify-fence-dev`, a PR into `allen-dev`, wait for checks with today's retry loop, `gh pr merge --squash --delete-branch` must succeed. A direct push to `allen-dev` is not tested: no rule forbids it; only the agent's instructions do. When `allen-dev` is missing: `say` that the working-branch check was skipped.
6. Delete `chore/verify-fence` on the remote. End with `say "FENCE VERIFIED on $VTARGET"`.

Refusal pattern for steps 1 to 4: `GH013|repository rule|rule violations|protected`. Step 4's exact GitHub wording is not known; the first live run (rollout, not this plan) records it.

- [ ] **Step 1: Write failing tests**, section `== fence: verify ==`, extending the docker/gh/git stubs the existing verify tests use (state `gate` stays for the main gate; add `fence` meaning the refusals above happen):
  - fence on, default branch `master`: passes; log shows the push to `HEAD:master`, never `HEAD:main`;
  - fence on, `allen-dev` present: the PR into `allen-dev` is merged with `--squash --delete-branch`;
  - `allen-dev` missing: passes and says the working-branch check was skipped;
  - fence off (pushes succeed): dies with `GATE NOT BINDING` at the first step;
  - refusal with an unrelated message (`non-fast-forward`): dies with `not for the expected reason`;
  - `--main-gate`: runs today's five steps (existing tests, now passing the flag);
  - `agent-new project` end to end still reaches the checklist (its internal verify uses the fence).
- [ ] **Step 2: Run.** Expected: new checks FAIL.
- [ ] **Step 3: Implement.** Keep the trap-based cleanup for both set-up paths; add the new remote branch names to what is cleaned up.
- [ ] **Step 4: Run** both suites. Expected: `ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-new): verify proves the fence`.

### Task 6: Builder instructions

**Files:**
- Create: `project-template/instructions/builder.md`
- Modify: `bin/agent-up` (`write_research`, the builder branch of the overlay and of the instructions copy)
- Test: `tests/launcher/test-agent-up.sh`

**Interfaces:**
- Produces: for every builder, `.generated/agent-instructions.md` (mode 644) = `builder.md`, followed by a blank line and `builder-research.md` when research is on; mounted read-only at `/etc/claude-code/CLAUDE.md` and `/home/agent/.codex/AGENTS.md` whether or not research is on. The research profile's file and mounts are unchanged.

`builder.md` content, in the plain style of the two existing instruction files, under a heading `# How to work in this repository`:
- Work on a branch named `<prefix>/<short-name>`, started from the current `allen-dev`. Allowed prefixes: the twelve, listed. Any other name is rejected by the repository.
- One change per pull request. Open it against `allen-dev` and squash-merge it yourself. Where the repository has checks, merge only when they are green.
- Never push to `allen-dev` directly and never rewrite its history.
- Never open a pull request to any other branch unless the owner asks, and never merge one.
- Never open a pull request on a repository the owner does not own. To send work upstream: push an `upstream/<topic>` branch cut from the upstream branch, carrying only that change, and give the owner the link `https://github.com/<upstream-owner>/<repo>/compare/<base>...<owner>:<branch>?expand=1&title=<url-encoded>&body=<url-encoded>`.
- Never delete a branch whose pull request is not merged without asking the owner. Decide by the pull request's state, not `git branch --merged`.
- If the repository has no `allen-dev`, push the branch, open the pull request against the default branch and wait for the owner.

- [ ] **Step 1: Write failing tests** next to the existing instruction-file checks (around the `agent-instructions.md` assertions): a builder without research has `agent-instructions.md` equal to `builder.md`, mode 644, and its rendered compose mounts it read-only at both targets; a builder with research has `builder.md` then `builder-research.md`; the research profile's file still equals `research.md`; `builder.md` names all twelve prefixes and `allen-dev` and contains no `feat/` and no e-mail address. Update the two existing assertions that a research-off builder has no instructions file and an `agent: {}` overlay.
- [ ] **Step 2: Run** `bash tests/launcher/test-agent-up.sh`. Expected: new checks FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both suites. Expected: `ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-up): every builder is told the branch workflow`.

### Task 7: Runbooks and spec note

**Files:**
- Modify: `docs/runbooks/machine-user-and-rulesets.md`, `docs/runbooks/new-project.md`, `project-template/README.md`, `docs/specs/2026-11-21-agent-dev-branch-design.md`, `docs/specs/2026-10-15-agent-new-design.md` (append an amendment section pointing at the new spec)

- [ ] **Step 1: Rewrite `machine-user-and-rulesets.md`** around the fence: what the two rulesets do and why; the twelve prefixes; `allen-dev` on owned repos and on forks (mirrors, `upstream/` branches, the link, the sync merge); auto-delete; `agent-new protect` with `--migrate`, `--main-gate`, `--no-working-branch`, several repos; `agent-new verify`; the manual UI steps for someone doing it by hand. Keep sections 1, 3 and 7 (account, token, first publish). State where the main gate still applies (`agent-containers`, with `--main-gate`) and why.
- [ ] **Step 2: Add the rollout order** to the same runbook: first `protect` and `verify` on one repo that has no `protect-main`, to prove the fence alone stops a merge into the default branch; only then `--migrate` elsewhere, one repo at a time, `verify` after each.
- [ ] **Step 3: Update** `new-project.md` and `project-template/README.md` where they describe the ruleset, the checks and the verification PR.
- [ ] **Step 4: In the spec**, replace the two statements that `protect-main` is never removed "on `agent-containers`" with the `--main-gate` flag, and note that the project template still ships `CODEOWNERS`.
- [ ] **Step 5: Run** both suites and `shellcheck bin/agent-new bin/agent-up`. Expected: `ALL PASSED`, no findings.
- [ ] **Step 6: Commit** `docs: runbooks for the fence and allen-dev`.
