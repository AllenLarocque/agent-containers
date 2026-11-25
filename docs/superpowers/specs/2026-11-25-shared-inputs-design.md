# Shared inputs: one download folder per container, and a weekly host job that links duplicates and lists old files (design)

**Status:** draft for owner approval · **Date:** 2026-11-25 · **Supersedes:** the parked
`docs/specs/2026-10-22-shared-inputs-design.md` (branch `docs/shared-inputs-design`, never merged).
Its §3 (what `reproducible` does) is still the reference for the package's behaviour; this
document only re-states what it relies on.

## 1. Intent and why

SpaDES input files (rasters, shapefiles, archives) are large and the same files turn up in several
projects, and in several folders of one project. On 2026-11-25 the input folders of the SpaDES
projects held 115 GB, of which 65 GB were byte-identical extra copies (about 37 GB the same file in
different projects, 28 GB copies inside one project). The owner wants that disk back, and wants it to
stay back: the integration work about to start pulls the same data into more places. It also needs
every project to use **the same downloaded file**, so results are comparable.

All SpaDES projects now live in one builder container (`PROJECT_DIR` holds several project folders,
mounted at `/workspace`), on one filesystem. That removes most of what made the parked design heavy
(a separate mount, overlap checks between projects' folders).

Two parts, both built now:

- **Part A, the host job** (`bin/agent-inputs`): weekly, it replaces byte-identical files in the
  configured input folders with hard links to one copy, and writes a report that lists files nobody
  has read in a long time. It never deletes anything.
- **Part B, the shared download folder:** in a container with the setting on, every R session's
  `reproducible` downloads go through one folder, `/workspace/inputs-shared`, so a file is downloaded
  once and every project links to the same copy. `global.R` stays standard.

## 2. Decisions the owner made (2026-11-25)

1. **Disk space is the main goal; it is an ongoing problem**, so a one-off pass is not enough.
2. **Both parts now.** The image is being rebuilt anyway, stopping all projects together later is hard,
   and the integration step needs the same data in every project.
3. **Part A is a small Python script of our own** (engine "A"), not util-linux `hardlink` plus a
   wrapper, so that scanning never updates files' last-read times (§3.3).
4. **Old files are only listed.** Deletions are discussed with the owner in chat once they accumulate.
   The job never deletes, moves or edits file contents.
5. **`global.R` stays standard** (carried over from the parked design): the container supplies the
   setting. Projects whose `global.R` sets the shared-folder option themselves keep their own copies
   until they are brought into the common project structure; that edit is done in those repositories,
   not in this work.
6. **Replicate-run scripts** that set their own input folder per run are left alone; how replicate runs
   should work (likely SpaDES.experiment) is a separate discussion. Part A still links their duplicates.
7. **The research container never takes part**, in either part (carried over).

## 3. Part A: `bin/agent-inputs` (host)

### 3.1 What it scans

A config file, `~/.config/agent-containers/inputs.conf` (owner-maintained, `0600`, outside every
mounted folder): first a line `project = <name>` naming the one builder project whose `PROJECT_DIR`
holds the shared container's projects (today `spades_pe`; the other SpaDES containers are not part of
this), then one folder per line, relative to that `PROJECT_DIR`, `#` comments. Example: `inputs-shared`
and each project's own input folders. *(Builder's call, recorded: one container only, so every path
in the report is one the agent there can reach; other containers can be added later with their own
config.)* The script refuses to run when:

- a listed folder does not exist, is a symlink, is outside that `PROJECT_DIR`, or is not on the same
  filesystem (`st_dev`) as the first one (hard links cannot cross filesystems);
- a listed folder overlaps the research folder (`RESEARCH_DIR` of any project config) or any config
  directory under `~/.config/agent-containers`. Research downloads are kept out deliberately: a hard
  link would let a builder's in-place edit reach a file the research container reads, and the reverse.

It walks each folder recursively without following symlinks, and skips `.git` directories. It never
touches files outside the listed folders.

**The folders are writable by the container's agent, and the job runs on the host with the owner's
full access.** So the job must not be steerable by what the agent puts there: every operation works
relative to an open directory handle (`openat`/`linkat`/`renameat` style, `O_NOFOLLOW`, `os.*` with
`dir_fd` and `follow_symlinks=False`), re-checks that a file is still the same inode before replacing
it, and never follows a symlink anywhere. A path swapped for a symlink mid-scan is skipped, not followed.

### 3.2 Linking duplicates

- **Candidates:** regular files of at least 1 MiB, not modified in the last 24 hours (a download or a
  run may still be writing them), owned by the user running the script.
- **Same content:** group by size, then by SHA-256 of the full content, then confirm with a byte-for-byte
  comparison before linking. Files that are already the same inode count once.
- **Linking:** for each group, keep the inode with the most links (ties: oldest `mtime`), and replace
  each other path atomically: create a hard link to the kept inode under a temporary name in the
  same directory, then `rename()` it over the path. A failure leaves the original file in place.
- **Read-only** (owner decision, 2026-11-25): every inode the job links has its write permission
  bits removed (`chmod a-w`). A program that tries to rewrite a linked file in place (as GDAL may do
  for an existing GeoTIFF) then fails with "permission denied" instead of silently changing every
  project's copy. Replacing the file with a new one (write elsewhere, rename over) and deleting it
  still work, because the folder stays writable. If this breaks runs, the owner revisits it.
- **Times:** after linking, the kept inode's last-read time (`atime`) is set to the latest `atime` of
  the group, with its `mtime` unchanged, so "last read" means "last read through any of its paths".
- **Dry run:** `agent-inputs scan --dry-run` prints what it would link and how much it would free,
  and changes nothing (not even times). `scan` without it does the linking.

### 3.3 Never touching last-read times

The old-files list (§3.4) depends on `atime`. This disk is mounted `relatime`, so a read updates
`atime` at most once a day, which is fine for months-scale reporting. The script opens every file it
reads with `O_NOATIME` (allowed because the user owns the files). If that fails for a file, it skips
the file and says so in the report; it never falls back to a normal read.

### 3.4 The report

The job's own state (running totals, last run) lives on the host only, in
`~/.local/state/agent-containers/inputs.json`; `agent-up status` reads that, never a file the agent
can write. *(Builder's call, recorded.)* Every `scan` run (dry or not) **publishes** a copy of the
report to `<PROJECT_DIR>/inputs-shared/REPORT.md` so the agent can read it in chat, written to a temp
name and renamed into place through a directory handle, never following a symlink. Contents:

1. Run time, dry run or not, folders scanned, total size on disk (each inode counted once), space freed
   by this run and in total so far.
2. **Not read in 180 days:** one entry per inode, largest first: size, last-read date, every path
   (relative to its listed folder). The threshold is a command-line option, default 180 days.
3. **In the shared folder but linked from nowhere else:** files under `inputs-shared/` whose link
   count is 1, i.e. no project folder links them any more. Deleting these frees space; deleting a file
   that other paths still link frees nothing, and the report says so in one line.
4. Files skipped (`O_NOATIME` refused, unreadable, changed during the scan), with the reason.

Paths in the report are container paths (`/workspace/...`), so the agent can act on them, and contain
no host home path.

### 3.5 Schedule

`agent-inputs install-timer` writes a systemd **user** service and timer (`OnCalendar=weekly`,
`Persistent=true` so a run missed while the machine was off happens at next boot) and enables it;
`agent-inputs remove-timer` disables and removes them. The service runs `agent-inputs scan`.
systemd runs as PID 1 in this WSL installation (checked 2026-11-25). The README tells the owner how to
see the last run (`systemctl --user status agent-inputs.timer`, the report file).

### 3.6 `agent-up status`

If `inputs.conf` exists, `status` prints one line from the host state file: last run date, total size,
space freed so far, and the number and size of files not read in 180 days. Nothing if the file is
missing.

## 4. Part B: the shared download folder (container)

### 4.1 Setting

`project.conf` gets:

```
# Shared download folder for SpaDES inputs: 0 = off, 1 = on. On, every R session's reproducible
# downloads go through /workspace/inputs-shared (project-template/README.md "Shared inputs").
SHARED_INPUTS=0
```

- `agent-up init` writes it as `0` for builders; the owner turns it on where several projects share a
  container. **Missing counts as off**, so no existing project changes until the owner sets `1`.
- Values other than `0`/`1` are refused by `up`/`config`; `stop`/`down` never refuse (same pattern as
  `RESEARCH` and `RSTUDIO`). The research profile refuses `SHARED_INPUTS=1`.
- `SHARED_INPUTS` joins the reserved-key list and the `unset` list in `bin/agent-up`.
- `agent-up up` with it on creates `<PROJECT_DIR>/inputs-shared/` and `<PROJECT_DIR>/inputs-shared/.tmp/`
  on the host if missing (`mkdir -p`, with a message). Inside one mount, so links work.

### 4.2 Overlay

A generated `.generated/shared-inputs.yaml` in the builder `COMPOSE=(...)` list. On: `environment:`
`SPADES_INPUTS_SHARED: /workspace/inputs-shared` and `SPADES_INPUTS_TMP: /workspace/inputs-shared/.tmp`.
Off, or research: `agent: {}`. No new mount.

### 4.3 Image: the R site profile

The base image appends a guarded block to R's site profile (`$(R RHOME)/etc/Rprofile.site`, keeping
the rocker content), root-owned:

```r
local({
  shared <- Sys.getenv("SPADES_INPUTS_SHARED")
  if (nzchar(shared) && is.null(getOption("reproducible.destinationPathShared")) &&
      is.null(getOption("reproducible.inputPaths")))
    options(reproducible.destinationPathShared = shared, reproducible.inputPaths = shared)
  tmp <- Sys.getenv("SPADES_INPUTS_TMP")
  if (nzchar(tmp) && is.null(getOption("reproducible.tempPath")))
    options(reproducible.tempPath = tmp)
})
```

- Both option names are set: the new name for `reproducible` 3.2.1+, the old one for older releases a
  project may install. (The builder checks whether setting both triggers the deprecation message on
  3.2.1 and, if it does, sets only what each release reads, e.g. by checking the installed version
  without loading the package.)
- It does nothing without the variables, so other containers on the same image are unaffected.
- Modules that read the shared-folder option to keep one copy of a large file they compute (seen in
  the SpaDES projects: a factorial-table module and an ecozone module) will write those files to the
  shared folder once the option is on. That is intended: it is the same saving. *(Builder's call,
  recorded.)* The report's "linked from nowhere else" section covers them like downloads.
- It never overrides a value already set. A script or `setupProject(options = ...)` that sets the
  option later wins; that is how the projects in decision 5 keep their own folder for now.
- Applies to `Rscript`, interactive R and RStudio sessions (`rsession-agent` passes the container
  environment on). `R --vanilla` skips it; acceptable.
- `reproducible.tempPath` inside the same mount turns the final "put the download in place" step into
  a link, so a half-downloaded file never appears under its final name (parked spec §3.5).

### 4.4 Agent instructions

When `SHARED_INPUTS=1`, `agent-instructions.md` is assembled from `builder.md`, then a new
`instructions/builder-shared-inputs.md`, then `builder-research.md` when research is on. It says, in
the existing style:

- `/workspace/inputs-shared` holds one copy of every downloaded input for all projects in this
  container; the container points `reproducible` at it.
- Leave `inputPath` and the `reproducible` shared-folder and temp-path options at their defaults in
  `global.R`; setting them brings back duplicate copies.
- Files get there only through `reproducible` and module code that uses the shared-folder option (some
  modules deliberately keep one copy of a large computed table there), never by hand. Never edit, overwrite, rename or
  delete anything in it, never open a file there for in-place update; if a file looks wrong, tell the
  owner.
- Files in project input folders may be hard links shared with other projects (the weekly job makes
  them, and makes them read-only): never edit an input file in place; write a new file instead. If a
  run fails with "permission denied" on an input file, delete that path and re-run (the file is
  rebuilt or downloaded as a new file), and tell the owner which file and which code tried to rewrite
  it. Never make such a file writable again.
- `inputs-shared/REPORT.md` lists old files; when the owner asks about clean-up, read it. Delete only
  what the owner names in chat, and delete every path the report lists for that file.
- Never copy anything from `/research` into the shared folder or a project's inputs.

### 4.5 Rollout

1. Merge; image published through the normal release flow; `agent-up update` picks up the new digests.
2. Owner sets `SHARED_INPUTS=1` for `spades_pe` only and runs `agent-up up` (one restart). The other
   SpaDES containers keep it off.
3. Owner writes `inputs.conf`, runs `agent-inputs scan --dry-run`, reads the report, then `scan`, then
   `install-timer`.
4. Projects that set the shared-folder option in `global.R` are switched over when they move into the
   common project structure (separate work, decision 5).

## 5. Non-goals and anti-goals

- **Non-goals:** deleting anything automatically; quotas; locking around concurrent downloads;
  patching `reproducible`; sharing the `Cache`; removing extracted copies of archives (zip + its
  extracted files); per-project shared folders across *different* containers; migrating existing
  project input folders into the shared folder (the job's linking already recovers their duplicate
  space).
- **Anti-goals:** anything that makes `global.R` or a module depend on `/workspace/inputs-shared`;
  the research container or research downloads taking part in either part; the job deleting, moving or
  changing the content of any file; a scan that updates last-read times.

## 6. Tests

**Part A** (`tests/inputs/test-agent-inputs.sh`, in CI, on a temporary fixture tree):

- identical files in two folders end up one inode, with no write permission bits; different content, files under 1 MiB, files modified
  in the last 24 hours and symlinks are left alone;
- `--dry-run` changes no inode, `mtime` or `atime`, and writes the report;
- a scan does not change the `atime` of files it read (fixture files given an old `atime` first);
- after linking, the kept inode's `atime` is the group's latest and its `mtime` unchanged;
- the old-files section lists an old-`atime` inode once with all its paths; the shared-folder section
  lists a link-count-1 file and not a linked one;
- refusals: a missing folder, a folder on another filesystem (skipped in CI if no second filesystem
  is available), a folder overlapping a research folder;
- an interrupted link (simulated failure before `rename`) leaves the original file intact.

**Part B, launcher** (`tests/launcher/test-agent-up.sh`): `init` writes `SHARED_INPUTS=0` for builders
and not for research; rendered compose with `1` has both variables and no new mount, with `0` or
missing none; invalid value refused by `up`/`config`, accepted by `stop`/`down`; research with `1`
refused; `up` creates the two folders; instructions assembled correctly for the four on/off
combinations of shared inputs and research.

**Part B, image** (`tests/smoke/base.sh`): with both variables set, a fresh `Rscript` has the
options; a user profile (fixture via `R_PROFILE_USER`) that sets a different value ends with its own
value (a project's own setting wins); without the variables, none is set.

**Manual, by the owner after rollout** (written into the README section, results noted in the PR):
in the SpaDES container, `prepInputs()` of a small public file from project A creates one inode in
`inputs-shared/` and A's inputs; the same call from project B downloads nothing and links the same
inode.

## 7. Left to the builder

- Exact wording of instructions, README, messages and report layout.
- Python structure (one file in `bin/`, standard library only; host Python 3).
- Systemd unit details (names, `Nice=`/`IOSchedulingClass=idle` for a gentle weekly run).
- How `agent-up status` reads `REPORT.json`.

## 8. Docs

`project-template/README.md`: new section "Shared inputs" covering both parts (what each does, turning
Part B on, writing `inputs.conf`, dry run, timer, reading the report, the rule that freeing space means
deleting every path of a file, why research folders are excluded); a row for `SHARED_INPUTS` in the
settings list. Known limits go in the private notes repository, not in this document.
