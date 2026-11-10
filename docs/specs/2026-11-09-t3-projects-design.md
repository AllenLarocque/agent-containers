# T3 projects: the container adds its own (design spec)

**Status:** implemented on `feat/t3-projects` · **Date:** 2026-11-09 · **Owner:** Allen Larocque

**Context.** Adding a project in the T3 app means finding the folder in a picker that starts in
`/home/agent`. That was unreliable, and on 2026-11-09 the live containers showed the result:

- `research`: the only live T3 project was at `/workspace`, which is not mounted there (wiped at
  every `agent-up up`), with 46 threads. The intended `/research/_general` project had been removed
  on 2026-10-13 and `--auto-bootstrap-project-from-cwd` did not add it back.
- `spades_pe`: 12 project rows for 5 repos (7 removed duplicates), one titled "FIIS" but rooted at
  `/workspace/simpleHarvestPlanning`, and removed ones at `/home/agent/...`.
- `spades_cimp`, `spades_bioinformatics`, `agent-containers-dev`: one project at `/workspace`, fine.

## 1. The four things called "project"

| Thing | What it is | What it decides |
|---|---|---|
| Container (`agent-up` project) | the sandbox: one mounted folder, one allowlist, one set of secrets, one image | what the agent can reach |
| T3 project | a row in T3's database: a title and a folder inside the container | where a new thread's agent starts |
| Claude / Codex workspace | the folder the CLI was started in (the T3 project's folder) | which `CLAUDE.md` / `AGENTS.md` load, where history is filed |
| Repo | a git repository | branches, diffs, PRs |

A T3 project isolates nothing: every thread in a container shares its firewall, secrets and files.
One container may hold several related repos (`spades_pe`); that is a supported layout.

## 2. Rule: which folders are T3 projects

| Container | T3 projects |
|---|---|
| research (`T3_PROJECT_DIR` set) | that folder (`/research/_general`) |
| `/workspace` is a git repo | `/workspace` |
| `/workspace` is a folder of git repos | each repo directly inside it (not symlinks, not hidden folders) |
| neither | `/workspace` |

No list in `project.conf`: the folders are found at each start, so a new repo dropped into the
project folder becomes a T3 project at the next `agent-up up` (or `agent-t3 start` in the container).

## 3. Behaviour

- **`agent-t3 start`** (every container start, and safe to re-run): after the server answers, runs
  `t3 project add <folder>` for each folder of §2. T3 refuses a second live project for the same
  folder (`ProjectAlreadyExistsError`), which is treated as "already there". Any other failure is one
  `WARN` line; the container still starts. `--auto-bootstrap-project-from-cwd` is dropped: one owner.
- **Titles.** `/workspace` and the research folder get the container's hostname; a sub-repo gets
  T3's default, its folder name. Existing projects keep the title they have.
- **`agent-t3 projects`** (read-only; `agent-up status` prints its output): one line per live T3
  project; `OUTSIDE <folder>` for a project that is not under `/workspace` (research: `/research`),
  `MISSING` for a folder of §2 that is not a project yet. T3 0.1.7 has no `project list`, so
  `t3-projects.js` reads T3's state database read-only; if that fails it says "could not read".
- **Nothing is removed automatically.** Removing a project deletes its threads; the owner does it
  (`t3 project remove --force <folder>`, or in the app).

## 4. Verified (2026-11-09, T3 0.1.7)

Against a throwaway server and data directory: `add` (running server and no server), a second `add`
of the same folder (refused), a missing folder (refused), `rename`, `remove`, `add` again after
`remove` (new project, the removed row stays). Not verified: that an open T3 app shows a project
added from the command line without a reload.

## 5. Not in scope

Renaming host folders, splitting `spades_pe`, a shared `CLAUDE.md` for a folder of repos, and
moving threads between projects (T3 has no command for it).
