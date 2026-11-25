# Shared Inputs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A weekly host job (`bin/agent-inputs`) that hard-links identical input files (read-only) and
lists old ones, plus a per-container shared download folder that `reproducible` uses automatically.

**Architecture:** Part A is one standard-library Python script on the host, driven by
`~/.config/agent-containers/inputs.conf` (one section per builder container, linking within a group),
keeping its state in `~/.local/state/agent-containers/inputs.json` and publishing a report into the
container's shared folder; a systemd user timer runs it weekly. Part B is a `SHARED_INPUTS` setting in
`project.conf` that makes `agent-up` add two environment variables (a generated compose overlay),
create `<PROJECT_DIR>/inputs-shared/.tmp`, and append an instructions file; a guarded block in the
base image's `Rprofile.site` turns the variables into `reproducible` options.

**Tech Stack:** bash (`bin/agent-up`, tests), Python 3.10 standard library (`/usr/bin/python3` on the
host), Docker image (rocker/r-ver base), systemd user units, GitHub Actions CI.

**Spec:** `docs/superpowers/specs/2026-11-25-shared-inputs-design.md` (approved 2026-11-25).

## Global Constraints

- Part A never deletes, moves or changes the content of any file; it only replaces a path with a hard
  link to an identical inode, removes write bits, and sets `atime`.
- Candidates: regular files `>= 1 MiB` (1048576 bytes), `mtime` older than 24 hours, owned by the
  running user; never through a symlink; `.git` directories skipped.
- Every file read uses `O_NOATIME`; if that open fails, the file is skipped and listed, never read
  another way. `--dry-run` changes nothing on disk except publishing the report.
- All filesystem operations relative to directory file descriptors, `follow_symlinks=False` /
  `O_NOFOLLOW`; re-check `(st_dev, st_ino)` immediately before replacing a path.
- Linked inodes: `chmod a-w`; `atime` = latest of the group; `mtime` unchanged.
- Old-file threshold default 180 days (`--days N`).
- Report published to `<PROJECT_DIR>/<report folder>/REPORT.md`, container paths (`/workspace/...`),
  no host home path; host state only in `~/.local/state/agent-containers/inputs.json`.
- Research-profile and non-builder sections refused; folders overlapping any `RESEARCH_DIR`
  (default `~/agent-research`) or `~/.config/agent-containers` refused.
- `SHARED_INPUTS`: `init` writes `0` for builders, missing = off, only `0`/`1` accepted by `up`/`config`,
  `stop`/`down`/`status` never refuse, research with `1` refused.
- Container variables: `SPADES_INPUTS_SHARED=/workspace/inputs-shared`,
  `SPADES_INPUTS_TMP=/workspace/inputs-shared/.tmp`. No new mount.
- **Plan ruling on spec §4.3 (option names):** the site profile sets **only the old name**
  `reproducible.inputPaths` (plus `reproducible.tempPath`), and only when neither
  `reproducible.inputPaths` nor `reproducible.destinationPathShared` is set. Why: in `reproducible`
  3.2.1 `.getDestinationPathShared()` returns the new name first, so setting the new name would beat
  a script that sets the old name later (a replicate script in the SpaDES projects does exactly that,
  and spec decision 6 leaves it alone). With only the old name, a script setting either name wins.
  Cost: `reproducible` prints its deprecation note for `inputPaths` once per session.
- Host-paths, private project names and weak points stay out of this public repo (known limits are in
  the private repo already).

## Review Focus

1. A path replaced by a symlink (or a directory swapped) between scan and link must be skipped, never
   followed. Test in Task 1 (`race: symlink swapped in before replace`).
2. A file that changes between hashing and linking (size/mtime/inode differ) must not be linked. Test
   in Task 1 (`changed during scan is skipped`).
3. A second run after a first full run must be a no-op that still writes the report, with totals not
   double-counted. Test in Task 1 (`second scan links nothing, totals stable`).
4. `inputs.conf` with a section whose project has no config dir, or a folder written with `..`, must
   refuse with a message naming the line. Test in Task 1 (`config refusals`).
5. `agent-up status` on a host with no `inputs.conf` or no state file prints nothing extra and still
   exits 0. Test in Task 2.

---

### Task 1: `bin/agent-inputs scan`: config, linking, report

**Files:**
- Create: `bin/agent-inputs` (executable, `#!/usr/bin/python3`, standard library only)
- Create: `tests/inputs/test-agent-inputs.sh`
- Modify: `.github/workflows/ci.yml` (run the new test in the `draft` and `full` paths, next to
  `test-agent-new.sh`)

**Interfaces:**
- Produces: CLI `agent-inputs scan [--dry-run] [--days N]`; exit 0 on success, 2 on a config refusal
  (message on stderr names the file and line). Reads `$HOME/.config/agent-containers/inputs.conf` and
  each section's `$HOME/.config/agent-containers/<section>/project.conf` (`PROJECT_DIR`, `PROFILE`,
  `RESEARCH_DIR`). Writes state JSON `$HOME/.local/state/agent-containers/inputs.json`:
  `{"sections": {"<name>": {"last_run": ISO8601, "dry_run": bool, "total_bytes": int,
  "freed_bytes_run": int, "freed_bytes_total": int, "old_count": int, "old_bytes": int}}}`.
  Task 2 reads exactly these keys.
- Config grammar: `[name]` starts a section; `key = value` lines for `group`, `report`; any other
  non-blank, non-`#` line is a folder relative to `PROJECT_DIR` (no leading `/`, no `..` component).
  Text after `#` is a comment.

- [ ] **Step 1: Write the failing test** `tests/inputs/test-agent-inputs.sh`, same `check`/`refuses`
  helpers as `tests/launcher/test-agent-up.sh`, fake `HOME` in a temp dir with two fake builder
  configs (`p1`, `p2`, `PROFILE=builder`) and one research config. Fixture files made with
  `head -c` of random data (2 MiB), `touch -m -d '3 days ago'` and `touch -a -d '400 days ago'` unless
  the case says otherwise. Checks (labels are the test names):
  - `identical files in two folders become one inode, read-only` (same `stat -c %i`, link count 2,
    `stat -c %A` has no `w`)
  - `different content, files under 1 MiB, files modified today and symlinks are left alone`
  - `dry run changes no inode, mtime or atime and writes the report`
  - `scan does not change atime of files it read` (non-duplicate same-size pair with different content)
  - `kept inode gets the group's latest atime and keeps its mtime`
  - `old-files section lists an old inode once with all its /workspace paths`
  - `shared-folder section lists a link-count-1 file and not a linked one`
  - `two sections in different groups never share an inode; same group do, and each report names the
    other container without its paths`
  - `second scan links nothing, totals stable`
  - `changed during scan is skipped` (test hook: env `AGENT_INPUTS_TEST_HOOK=before-replace:<cmd>`
    runs `<cmd>` via `subprocess` just before each replace; here it appends a byte to the file)
  - `race: symlink swapped in before replace` (hook replaces the target path with a symlink to a file
    outside the folders; that outside file is unchanged and the path is still a symlink afterwards)
  - `interrupted link leaves the original intact` (hook `before-rename:exit` makes the process exit
    after creating the temp link; original path still has its original inode, no temp file remains
    after the next scan)
  - `config refusals`: research section, unknown section, missing folder, folder with `..`, absolute
    folder, folder overlapping `RESEARCH_DIR`, folder on another filesystem (skip with `SKIP:` unless
    `/dev/shm` is a different `st_dev` than the temp dir)
  - `unreadable file is skipped and listed with its reason` (a duplicate candidate `chmod 000`; it
    keeps its inode and appears in the report's skipped section)
  - `report has no host home path` (`grep -F "$HOME"` finds nothing in `REPORT.md`)
  - `report published through a symlinked REPORT.md does not write outside` (pre-create `REPORT.md`
    as a symlink to an outside file; after scan the outside file is unchanged)

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/inputs/test-agent-inputs.sh`
Expected: FAIL lines (no `bin/agent-inputs`), non-zero exit.

- [ ] **Step 3: Implement `bin/agent-inputs`**

Functions (names fixed so later tasks and reviewers can find them):
`load_config(home: Path) -> list[Section]` (dataclass: `name, group, project_dir, folders, report`);
`walk(section) -> Iterator[FileRef]` (`FileRef`: `section, folder, rel, dev, ino, size, mtime, atime, nlink`,
walking with `os.scandir` on dir fds opened `O_RDONLY|O_DIRECTORY|O_NOFOLLOW`);
`hash_file(dir_fd, name) -> str | None` (SHA-256, `O_RDONLY|O_NOFOLLOW|O_NOATIME`, `None` on failure);
`same_bytes(a, b) -> bool` (byte compare, same open flags);
`link_group(refs, dry_run) -> int` (bytes freed; keep inode with most links, ties oldest mtime; for
each other path: hook, `os.link(kept, tmp, src_dir_fd=, dst_dir_fd=, follow_symlinks=False)`,
re-`lstat` target and compare `(dev, ino, size, mtime)` with the scan, then
`os.rename(tmp, name, src_dir_fd=, dst_dir_fd=)`; on any mismatch unlink tmp and skip; afterwards
`os.fchmod` (remove `0o222`) and `os.utime(fd, (max_atime, kept_mtime))` on an fd of the kept inode);
`write_report(section, data, project_dir) -> None` (write `REPORT.md.tmp` with `O_CREAT|O_EXCL|O_NOFOLLOW`
in the report dir fd, unlinking a stale temp first, then `os.rename` over `REPORT.md`; a `REPORT.md`
symlink is replaced, never followed);
`save_state(state) -> None` (atomic write in the state dir, created `0700`).
Temp link names start with `.agent-inputs-tmp-`; a scan first removes leftover ones it finds.
Group by size, then hash, then confirm with `same_bytes` against the kept candidate.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/inputs/test-agent-inputs.sh`
Expected: every line `OK:` (or the one `SKIP:`), exit 0. Also `shellcheck -S warning tests/inputs/test-agent-inputs.sh` clean.

- [ ] **Step 5: Wire CI and commit**

Add `bash tests/inputs/test-agent-inputs.sh` as a step in both the `draft` and `full` paths of
`build-test` in `.github/workflows/ci.yml`.

```bash
git add bin/agent-inputs tests/inputs/test-agent-inputs.sh .github/workflows/ci.yml
git commit -m "feat(agent-inputs): weekly-ready scan that links identical inputs read-only and lists old files"
```

### Task 2: timer, status line, `agent-up status`, README Part A

**Files:**
- Modify: `bin/agent-inputs` (subcommands `install-timer`, `remove-timer`, `status-line <section>`)
- Modify: `bin/agent-up` (`cmd_status`: one line when `inputs.conf` exists)
- Modify: `tests/inputs/test-agent-inputs.sh`, `tests/launcher/test-agent-up.sh`
- Modify: `project-template/README.md` (new section "Shared inputs", Part A half; placed before
  "## Lifecycle")

**Interfaces:**
- Consumes: state JSON keys from Task 1.
- Produces: `agent-inputs status-line <section>` prints one line
  `Shared inputs: last run <YYYY-MM-DD>, <total> on disk, <freed> freed so far, <n> files (<size>) not read in 180 days`
  (sizes human-readable, GiB with one decimal), or nothing and exit 0 if there is no state for that
  section or no `inputs.conf`. `install-timer` writes `~/.config/systemd/user/agent-inputs.service`
  (`ExecStart=/usr/bin/python3 <absolute path of this script> scan`, `Nice=19`,
  `IOSchedulingClass=idle`) and `agent-inputs.timer` (`OnCalendar=weekly`, `Persistent=true`), then
  runs `systemctl --user daemon-reload` and `systemctl --user enable --now agent-inputs.timer`;
  `remove-timer` disables and deletes both.

- [ ] **Step 1: Write the failing tests**
  - In `test-agent-inputs.sh`, with a stub `systemctl` on `PATH` that logs its arguments:
    `install-timer writes both units with Persistent=true and enables the timer`,
    `remove-timer disables and deletes them`,
    `status-line prints the documented line after a scan`,
    `status-line prints nothing without state or inputs.conf`.
  - In `test-agent-up.sh` (status section, using the existing docker stub):
    `status prints the shared-inputs line when inputs.conf and state exist` and
    `status prints no shared-inputs line and exits 0 without inputs.conf`.

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/inputs/test-agent-inputs.sh; bash tests/launcher/test-agent-up.sh 2>&1 | grep -E '^FAIL' `
Expected: the new labels FAIL.

- [ ] **Step 3: Implement** the three subcommands; in `cmd_status`, for a builder config, if
  `$HOME/.config/agent-containers/inputs.conf` exists run
  `"$HERE/agent-inputs" status-line "<project>" || true` (never fail status).

- [ ] **Step 4: Write the README Part A section**: what the job does and never does; writing
  `inputs.conf` (the spec §3.1 example, with placeholder folder names); `agent-inputs scan --dry-run`,
  then `scan`, then `install-timer`; reading `REPORT.md`; seeing the last run
  (`systemctl --user status agent-inputs.timer`); freeing space means deleting every path of a file;
  read-only links and what "permission denied" means; why research folders are excluded; linking
  across containers by giving sections the same `group`.

- [ ] **Step 5: Run all tests, verify they pass**

Run: `bash tests/inputs/test-agent-inputs.sh && bash tests/launcher/test-agent-up.sh`
Expected: exit 0 for both (render checks may `SKIP` locally without `docker compose`).

- [ ] **Step 6: Commit**

```bash
git add bin/agent-inputs bin/agent-up tests/inputs/test-agent-inputs.sh tests/launcher/test-agent-up.sh project-template/README.md
git commit -m "feat(agent-inputs): weekly timer, status line in agent-up status, README"
```

### Task 3: `SHARED_INPUTS` in the launcher

**Files:**
- Modify: `bin/agent-up` (init heredoc; `shared_inputs_on`, `check_shared_inputs`,
  `write_shared_inputs`, `shared_inputs_dirs`; `prepare()`; builder `COMPOSE=(...)`; reserved-key regex
  at the `reserved=` line; final `unset` list; `cmd_up`/`cmd_config` call `check_shared_inputs`)
- Modify: `project-template/config/compose.yaml` header comment (one line on the overlay)
- Modify: `tests/launcher/test-agent-up.sh`

**Interfaces:**
- Produces: `shared_inputs_on <cfgdir>` (true only for `PROFILE=builder` and exactly `SHARED_INPUTS=1`);
  `.generated/shared-inputs.yaml`. Task 4 uses `shared_inputs_on` for instruction assembly.

- [ ] **Step 1: Write the failing tests** (mirror the `RSTUDIO` checks):
  - `project.conf: SHARED_INPUTS=0 (opt-in)` for a builder `init`; research `init` has no `SHARED_INPUTS` line.
  - `SHARED_INPUTS=0: the shared-inputs overlay adds nothing` (`services:\n  agent: {}`).
  - `rendered: SHARED_INPUTS=1 sets SPADES_INPUTS_SHARED and SPADES_INPUTS_TMP and adds no volume`
    (compare `docker compose config` volume list with and without).
  - `config without SHARED_INPUTS renders it off`.
  - `SHARED_INPUTS=` (empty) renders off. For `v` in `2 yes on`: `up refuses SHARED_INPUTS='$v'` matching `SHARED_INPUTS='$v'.*must be 0 \(off\) or 1 \(on\)`,
    `config refuses`, `stop/down/status work`.
  - `research with SHARED_INPUTS=1 is refused` matching `SHARED_INPUTS.*research`.
  - `up with SHARED_INPUTS=1 creates inputs-shared/.tmp under PROJECT_DIR` and
    `up refuses when inputs-shared is a symlink`.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E '^FAIL' | grep -i shared`
Expected: the new labels listed.

- [ ] **Step 3: Implement.** Init heredoc lines after the `RSTUDIO_PORT` line, exact text from spec
  §4.1 (builders only; the research `init` path does not write it). `check_shared_inputs` follows
  `check_research`/`check_rstudio`. Folder creation in `cmd_up` only (not `config`), refusing when
  `$PROJECT_DIR/inputs-shared` or its `.tmp` exists and is a symlink or not a directory; message
  `created <path>` when made. Overlay writer follows `write_rstudio`'s shape, header
  `# GENERATED by agent-up from SHARED_INPUTS in project.conf. Do not edit.`

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/launcher/test-agent-up.sh`
Expected: exit 0; `shellcheck -S warning bin/agent-up` clean.

- [ ] **Step 5: Commit**

```bash
git add bin/agent-up project-template/config/compose.yaml tests/launcher/test-agent-up.sh
git commit -m "feat(agent-up): SHARED_INPUTS setting: shared download folder variables and folder"
```

### Task 4: agent instructions and README Part B

**Files:**
- Create: `project-template/instructions/builder-shared-inputs.md`
- Modify: `bin/agent-up` (instruction assembly at the `builder-research.md` line: `builder.md`, then
  `builder-shared-inputs.md` when `shared_inputs_on`, then `builder-research.md` when `research_on`)
- Modify: `project-template/README.md` (Part B half of "Shared inputs"; `SHARED_INPUTS` in
  "Settings worth knowing"; a line in "What the container gets (builder profile)")
- Modify: `tests/launcher/test-agent-up.sh`

**Interfaces:**
- Consumes: `shared_inputs_on` (Task 3).

- [ ] **Step 1: Write the failing tests:**
  - `instructions: four combinations of SHARED_INPUTS and RESEARCH assemble in order builder,
    shared-inputs, research` (check presence/absence and order of the three files' first headings).
  - `builder-shared-inputs.md: the rules` grepping these exact phrases (Step 3 must contain them):
    `/workspace/inputs-shared`, `Leave \`inputPath\``, `never by hand`,
    `never open a file there for in-place update`, `permission denied`,
    `Never make such a file writable again`, `delete every path the report lists`,
    `Never copy anything from \`/research\``.

- [ ] **Step 2: Run to verify they fail**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E '^FAIL'`
Expected: the two new labels.

- [ ] **Step 3: Write `builder-shared-inputs.md`** (heading `## Shared inputs`) with the six bullets of
  spec §4.4 in the style of `builder-research.md`, keeping each phrase above on one line. Add the
  assembly change and the README text (turning it on for one container, the one restart, that
  `global.R` stays standard and a project setting the option itself keeps its own folder, the
  manual check from spec §6 "Manual, by the owner").

- [ ] **Step 4: Run to verify they pass**

Run: `bash tests/launcher/test-agent-up.sh`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add project-template/instructions/builder-shared-inputs.md bin/agent-up project-template/README.md tests/launcher/test-agent-up.sh
git commit -m "feat(instructions): shared-inputs rules for builders with SHARED_INPUTS=1"
```

### Task 5: image: guarded `Rprofile.site` block

**Files:**
- Modify: `images/base/Dockerfile` (after the R bootstrap `RUN`: append the block to
  `"$(R RHOME)/etc/Rprofile.site"`, root-owned `0644`)
- Modify: `tests/smoke/base.sh`

**Interfaces:** none.

- [ ] **Step 1: Write the failing smoke checks** in `tests/smoke/base.sh`:
  - `Rprofile.site: shared variables set reproducible.inputPaths and tempPath`
    (`SPADES_INPUTS_SHARED=/x SPADES_INPUTS_TMP=/y Rscript -e 'stopifnot(identical(getOption("reproducible.inputPaths"), "/x"), identical(getOption("reproducible.tempPath"), "/y"), is.null(getOption("reproducible.destinationPathShared")))'`)
  - `Rprofile.site: without the variables nothing is set`
  - `Rprofile.site: a user profile's own value wins` (`R_PROFILE_USER` pointing at a temp file that
    sets `reproducible.inputPaths = "/mine"`; result `/mine`)
  - `Rprofile.site: keeps rocker's content` (the file still contains `options(repos`)
  - `Rprofile.site: root-owned, not writable by agent`

- [ ] **Step 2: Verify they fail.** Agents cannot run Docker on the host and the dev container has no
  Docker: run `bash -n tests/smoke/base.sh` and `shellcheck -S warning tests/smoke/base.sh`, and record
  in the ledger that RED/GREEN for this task is proven by CI (the PR's `build-test` runs
  `tests/smoke/base.sh` against the built image). If a local Docker is available, run
  `scripts/build-local.sh` and expect the new labels to FAIL before Step 3.

- [ ] **Step 3: Implement** the block: spec §4.3's code with the plan ruling applied (set only
  `reproducible.inputPaths`, guarded by both names being `NULL`; `tempPath` guarded by `NULL`),
  wrapped in `local({ ... })`, preceded by a comment pointing to the spec.

- [ ] **Step 4: Verify** in CI (`build-test` green with the five labels `OK:`), or locally with
  `scripts/build-local.sh` if Docker is available.

- [ ] **Step 5: Commit**

```bash
git add images/base/Dockerfile tests/smoke/base.sh
git commit -m "feat(image): Rprofile.site points reproducible at the shared inputs folder when the launcher asks"
```

## After the tasks

- Open one PR into `allen-dev` (`feature/shared-inputs`, rebased from this docs branch), CI green,
  squash-merge. The image publishes from `main` after the owner promotes.
- Rollout is the owner's, spec §4.5: promote, `agent-up update`, `SHARED_INPUTS=1` for `spades_pe`,
  `agent-up up spades_pe`, write `inputs.conf`, `agent-inputs scan --dry-run`, review, `scan`,
  `install-timer`.
