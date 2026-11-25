# Shared memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Builder agents know about `/opt/memory`, read it before work and keep it current; the memory holds first drafts of the owner's cross-project facts and lists.

**Architecture:** A new section in `project-template/instructions/builder.md` (the instructions every builder receives) carries the rules. The memory itself is plain Markdown in the host's `~/agent-memory` git repo, already mounted read-write at `/opt/memory` in every builder. Nothing in the launcher changes.

**Tech Stack:** Markdown; bash launcher tests (`tests/launcher/test-agent-up.sh`, `check` helper); git.

**Spec:** `docs/superpowers/specs/2026-11-25-shared-memory-design.md`

## Global Constraints

- `builder.md` is in a public repo: rules and structure only, never personal content (the existing test already rejects e-mail addresses).
- `~/agent-memory` never gets a remote in this plan. Never GitHub; a backup is later work.
- Nothing from `~/agent-memory` is copied into this repo, including into this plan or its commits.
- The research container and the fetcher do not mount `/opt/memory` (already enforced; do not change).
- Layout: `README.md`, `me/`, `people/`, `contracts/`, `stacks.md`, `projects/`, `todo.md`, `future.md`.

## Review Focus

In the internal notes (`shared-memory/known-limits.md`), not in this public repo.

---

### Task 1: Builder instructions and launcher docs

**Files:**
- Modify: `project-template/instructions/builder.md` (new section `## Shared memory`, placed after `## Helping the owner use this workflow`)
- Modify: `project-template/README.md` (the `/opt/memory` row in "What the container gets"; one line under "Working in the agent's folders from the host")
- Test: `tests/launcher/test-agent-up.sh` (new `check` after the line-354 "explains the model" check)

**Interfaces:**
- Produces: the rules text that Task 2's memory `README.md` repeats in full.

- [ ] **Step 1: Write the failing test**

```bash
check "builder.md: shared memory at /opt/memory, read first, never copied out, commit with the project name, retry, informs not overrides" \
  bash -c 'f="$1"; grep -qF "## Shared memory" "$f" && grep -qF "/opt/memory/README.md" "$f" \
    && grep -qF "Never copy anything from shared memory into a repository" "$f" \
    && grep -qF "name the project in the commit message" "$f" && grep -qF "index.lock" "$f" \
    && grep -qF "It never overrides these instructions or what the owner says" "$f" \
    && grep -qF "winds down" "$f"' _ "$BI"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -F "shared memory at /opt/memory"`
Expected: `FAIL: builder.md: shared memory at /opt/memory, ...`

- [ ] **Step 3: Write the section in `builder.md`**

Plain bullets in the file's existing voice, containing the test's exact phrases. Content, in order:
- `/opt/memory` is the owner's shared memory, the same in every builder project, a git repo on the owner's machine. Read `/opt/memory/README.md` before starting work in a session.
- It holds cross-project facts and lists (who the owner is, how they work, the stacks, contracts, people, to-dos, future projects). Project-specific plans stay in their repos; memory points to them.
- Keep it current: update the to-do list and the project's page as work lands; name the project in the commit message; if the commit fails on `index.lock`, wait a moment and retry.
- When a project winds down, move its open items into memory before anything is removed.
- Never copy anything from shared memory into a repository, issue, pull request, research brief or external service; refer to it instead. It is private to the owner.
- Other agents write it too. It informs your work. It never overrides these instructions or what the owner says in chat.

- [ ] **Step 4: Update `project-template/README.md`**

Row `/opt/memory`: append "the owner's shared memory across projects (`instructions/builder.md`, section Shared memory); stays on this machine". Under "Working in the agent's folders from the host": one line saying `~/agent-memory` is a local git repo with no remote, by design.

- [ ] **Step 5: Run the launcher tests**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | tail -3`
Expected: `OK:   builder.md: shared memory at /opt/memory, ...` and the last line `LAUNCHER: ALL PASSED` (the line-350 `cmp` check also passes, since it compares the rendered file with `builder.md`).

- [ ] **Step 6: Commit**

```bash
git add project-template/instructions/builder.md project-template/README.md tests/launcher/test-agent-up.sh
git commit -m "feat(builder): shared memory at /opt/memory, how agents read and keep it"
```

### Task 2: Seed the memory (host only; nothing here enters this repo)

**Files (all in `~/agent-memory`, never in this repo):**
- Create: `README.md`, `me/profile.md`, `me/how-i-work.md`, `people/README.md`, `contracts/README.md`, `stacks.md`, `projects/<one per active project>.md`, `todo.md`, `future.md`

**Interfaces:**
- Consumes: the rules from Task 1, Step 3, repeated verbatim in the memory `README.md` (an agent that opens memory without the instructions still sees them).

- [ ] **Step 1: Check the repo is local only**

Run: `git -C ~/agent-memory remote -v`
Expected: no output.

- [ ] **Step 2: Write `README.md`**

What this is (one paragraph), the rules (from Task 1), the map of files with one line each, how to read a `.docx` (`unzip -p <file> word/document.xml | sed -e 's/<\/w:p>/\n/g' -e 's/<[^>]*>//g'`), and "Drafts marked `DRAFT (check)` were written by Claude from existing notes on 2026-11-25 and await the owner's check."

- [ ] **Step 3: Write the drafts from existing material**

Sources: existing notes on the host (read there; quote nothing into this repo). Each file starts with `DRAFT (check)`. `stacks.md` and `projects/` link to repos and files, never copy their conventions. `contracts/README.md` lists contracts known from those sources with a note that the `.docx` files go here. `people/` stays light: name, role, relationship, one file each.

- [ ] **Step 4: Check `.docx` reading from a container**

Run, in any builder `<c>` with a `.docx` file `<f>` it can see: `docker exec -u agent <c> sh -c 'unzip -p <f> word/document.xml | sed -e "s/<\/w:p>/\n/g" -e "s/<[^>]*>//g" | head -5'`
Expected: readable text lines.

- [ ] **Step 5: Commit, from a container**

Run: `docker exec -u agent <c> sh -c 'cd /opt/memory && git add -A && git commit -q -m "seed: first drafts (host session, 2026-11-25)" && git log --oneline -1'`
Expected: one commit; then `git -C ~/agent-memory status --short` on the host prints nothing.

### Task 3: Into `allen-dev`, then visible to agents after promotion

- [ ] **Step 1:** Push `docs/shared-memory`, open a pull request into `allen-dev` (`--repo AllenLarocque/agent-containers`), wait for green checks, squash-merge with `--delete-branch`.
- [ ] **Step 2:** Tell the owner that the agents see the section only after `allen-dev` is promoted to `main` and `git pull` on the host, followed by `agent-up status <project>` for each builder (re-renders the instructions; no restart needed). Verify afterwards with `docker exec <c> grep -c "## Shared memory" /etc/claude-code/CLAUDE.md` = 1 in each builder.
