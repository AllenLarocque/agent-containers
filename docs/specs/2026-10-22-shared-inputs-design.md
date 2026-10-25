# Shared inputs: one copy of each large input file for all SpaDES projects (design spec)

**Status:** PARKED 2026-10-25 (not approved for building; see §10) · **Date:** 2026-10-22, reworked 2026-10-24 · **Owner:** Allen Larocque

**Context.** SpaDES workflows in different projects often use the same input files (rasters,
shapefiles, archives), and some are large: LandR, scfm and fireSense modules all need the same
data. Today each builder container sees only its own project folder, so each project downloads and
keeps its own copy, and the host disk (the C: SSD, which holds the WSL and Docker disk images) is
filling up. SpaDES normally avoids this with one shared data folder on the machine
(`reproducible.inputPaths`, e.g. `"~/data"`, as in SpaDES.project's `setupProject()` docs). This
spec makes that standard setup work across our containers, without any change to how a project's
`global.R` is written.

## 1. Intent

One host folder holds one copy of every original input file that `prepInputs()` downloads, plus
each project's own inputs folder, all on **one mount** so `reproducible` can hard-link between
them. Every SpaDES builder that has the feature on uses it automatically. A project's `global.R`
stays the minimal, standard one colleagues on ordinary single-machine setups would write.

## 2. Decisions the owner made

1. **Every project can add files** (2026-10-22). The folder is read-write in every builder that has
   it; the owner accepts the loss of isolation (one project's agent can change or delete files
   another project uses).
2. **Optional, on by default** (2026-10-22). One `project.conf` setting per project. The
   bioinformatics project turns it off.
3. **The owner does the clean-up** (2026-10-22). No automatic eviction, quotas or reference
   counting; the launcher only reports what is safe to delete (§4.6).
4. **The research container never gets the folder** (2026-10-22).
5. **Standard SpaDES layout, made to work across containers** (2026-10-24, "option B"): a shared
   folder for originals plus a per-project inputs folder, linked, instead of every project using the
   shared folder as its `inputPath` directly (that version let derived files from different
   projects collide under the same name).
6. **Invisible to `global.R`** (2026-10-24, "option 2"): the container supplies the settings; the
   project's `global.R` stays standard and shareable. The owner accepts the cost: a `global.R` that
   sets `inputPath` or `reproducible.inputPaths` itself silently bypasses the feature (duplicate
   copies, not errors), so agents are told not to (§4.5).
7. **Cross-project visibility is accepted** (2026-10-25). Hard links need one mount and all
   containers run as uid 1000, so every project with the feature on can read and write all of
   `/inputs`, including other projects' folders and anything any project downloaded (a file fetched
   with credentials, e.g. restricted data from Google Drive, is linked into `shared/` too). The
   owner accepts this: projects may have restricted inputs, and the alternative (more projects per
   container) would share even more. A group of projects that must not see another group's inputs
   uses a different `SHARED_INPUTS_DIR`; a project whose restricted inputs must not spread at all
   turns the feature off.
8. **Drive:** the folder's location is a setting. It starts wherever the owner puts it; moving it to
   the 8 TB HDD later is a copy plus a path change (§4.1). The HDD setup itself is out of scope.

## 3. What `reproducible` and SpaDES.project do (read from the source, not yet tested)

Sources read: `PredictiveEcology/reproducible` `main` at `be02fa4` (2026-08-30, `Version: 3.2.1`)
and `PredictiveEcology/SpaDES.project` `main` at `8623d93` (2026-09-11). The releases projects
install via `setupProject()` may be older; §7 re-checks these on them.

1. **Hard links fail across mount points.** `reproducible` puts files in place with
   `hardLinkOrCopy()` = `linkOrCopy(symlink = FALSE)`. Across two mounts (`EXDEV`), even of the same
   host disk, it falls back to a full copy. So the shared folder, the project's inputs folder and
   the download scratch folder must all be inside **one** bind mount. Two separate binds (e.g. one at
   `/inputs`, another at `/workspace/inputs`) would duplicate every file.
2. **The shared-folder flow.** With `reproducible.inputPaths` set (renamed
   `reproducible.destinationPathShared` in 3.2.1; the old name is still read, `R/helpers.R`),
   `prepInputs()` looks there first and links a found file into `destinationPath`; a new download
   goes to `destinationPath` and is then linked into the shared folder
   (`copyFromDPtoReproducibleIPs()`, `pp_link_to_destination()` in `R/preProcess.R`). Setting the
   old name works with old and new releases.
3. **A symlinked `inputs/` still hard-links.** `prepInputs()` normalises `destinationPath` with
   `normPath()` → `normalizePath()`, which resolves symlinks, so `/workspace/inputs` →
   `/inputs/projects/<project>` is on the same mount as `/inputs/shared`. (The kernel would resolve
   it for `link()` anyway.)
4. **Options set before R loads `reproducible` are kept.** Its `.onLoad` only sets options that
   are not already set (`R/zzz.R`). SpaDES.project carries `reproducible.inputPaths` over unchanged
   (`fastOptions()` uses `getOption("reproducible.inputPaths")`); `setupProject()` writes
   `spades.inputPath` into the project's `.Rprofile` only when it is not the default.
5. **Downloads go to a scratch folder first.** `preProcess()` downloads into `tempdir2()` under
   `reproducible.tempPath` (default: under the container's `/tmp`), then `hardLinkOrCopy()` puts it
   at the final name. With the default, that is a cross-mount **copy under the final name** (another
   project can see a half-written file) and the download also sits in the container's own `/tmp`.
   With `reproducible.tempPath` inside the same mount, the final step is a hard link: the file
   appears complete in one step.
6. **No lock around downloads** (`filelock` is used only for the cache repository). Two projects
   fetching the same missing file at once both download it. What happens when the second tries to
   link into `shared/` where the file now exists is not established from the source; §7 tests it.
   Expected worst case: one failed run, re-run succeeds.
7. **`CHECKSUMS.txt` is rewritten without a lock** (`writeChecksumsTable()`, `R/checksums.R`). Two
   runs finishing at once can lose each other's lines; the next run re-checksums or re-downloads.
   No damage to data files.
8. **Hard links share content.** A file edited in place (rather than replaced) changes for every
   project linked to it. `reproducible` writes new files rather than editing; whether any module or
   package opens an input for update (e.g. a GeoPackage) is checked in §7.

## 4. Container side (agent-containers)

### 4.1 Settings in `project.conf` and the host folder

```
# Shared SpaDES inputs: 0 = off, 1 = on (default). On mounts SHARED_INPUTS_DIR read-write at /inputs
# and makes inputs/ a link into it (project-template/README.md "Shared inputs").
SHARED_INPUTS=1
SHARED_INPUTS_DIR=$HOME/spades-inputs
```

- `agent-up init` (builder profile) writes both lines with these values.
- **Missing `SHARED_INPUTS` counts as on**, so existing builders get it at their next `agent-up up`.
  The owner sets `SHARED_INPUTS=0` in the bioinformatics `project.conf` **before** that (rollout
  note in the README and the PR). Any value other than `0`/`1` is refused by `up`/`config`;
  `stop`/`down` never refuse.
- Missing `SHARED_INPUTS_DIR` = `$HOME/spades-inputs`; it must be an absolute path. Several
  projects may name the same folder (that is the point); different folders are allowed.
- Research profile: never mounted; an explicit `SHARED_INPUTS=1` there is refused;
  `init --profile research` does not write the keys.
- Both keys go in the `unset` list at the end of `bin/agent-up`.

Layout, created by `agent-up up` (`mkdir -p`, with a message):

```
$SHARED_INPUTS_DIR/
  shared/              one copy of every downloaded original (reproducible.inputPaths)
  projects/<project>/  the project's inputs: hard links into shared/, plus derived files
  .tmp/<project>/      download scratch (reproducible.tempPath)
```

The containers run as `1000:1000`; the folder must be writable by that uid on the host.

**Moving it (e.g. to the HDD):** stop the projects that use it, copy the whole tree with a copy that
preserves hard links (`cp -a` or `rsync -aH` of the top folder in one go), change
`SHARED_INPUTS_DIR`, `agent-up up`. All links are inside the tree, so they survive. Documented in
the README; no launcher command.

### 4.2 Mount and environment

A new generated overlay, `.generated/shared-inputs.yaml`, in the `COMPOSE=(...)` list:

- On: bind `SHARED_INPUTS_DIR` → `/inputs` (read-write, **one** bind, §3.1), plus `environment:`
  `SPADES_INPUTS_SHARED: /inputs/shared` and `SPADES_INPUTS_TMP: /inputs/.tmp/<project>`.
- Off (or research profile): `agent: {}`, like the other overlays.

### 4.3 R settings (image)

The base image's site R profile (`$(R RHOME)/etc/Rprofile.site`, appended to whatever the image
already has) gets a guarded block that does nothing unless the overlay set the variables, and never
overrides a value already set:

```r
local({
  shared <- Sys.getenv("SPADES_INPUTS_SHARED")
  if (nzchar(shared) && is.null(getOption("reproducible.inputPaths")) &&
      is.null(getOption("reproducible.destinationPathShared")))
    options(reproducible.inputPaths = shared)
  tmp <- Sys.getenv("SPADES_INPUTS_TMP")
  if (nzchar(tmp) && is.null(getOption("reproducible.tempPath")))
    options(reproducible.tempPath = tmp)
})
```

- Applies to `Rscript`, interactive R and RStudio Server sessions (`rsession-agent` already passes
  the container environment to R sessions). `R --vanilla` skips it; that is acceptable.
- Root-owned in the image, like the RStudio configuration; the agent cannot change it.
- Image change → new image and digests through the normal release flow.

### 4.4 The project's `inputs/` link (launcher, on the host, at `up`)

`PROJECT_DIR/inputs` (i.e. `/workspace/inputs`, the `setupProject()` default `inputPath`):

| State | Action |
|---|---|
| missing | create symlink → `/inputs/projects/<project>` (dangles on the host; valid in the container) |
| already that symlink | nothing |
| a symlink elsewhere | warn, leave it |
| a real folder | warn ("this project keeps its own copies"), leave it, point to the README migration steps |

- The launcher **never moves or deletes project data.** Migration of an existing `inputs/` (move its
  contents into `projects/<project>/`, then let `up` create the link) is a manual, documented step.
- **Git:** if `PROJECT_DIR` is a git repo, `up` adds `/inputs` to `.git/info/exclude` (local, never
  committed) when not already there, so the link is never committed and colleagues' clones are
  unaffected. A `.gitignore` line `inputs/` (trailing slash) does *not* match a symlink; the
  exclude line is what covers it.
- With the feature off: no link is created, an existing correct link is left (harmless; it dangles)
  and `up` says so.

### 4.5 Overlap checks and agent instructions

**Overlaps:** `SHARED_INPUTS_DIR` must not overlap (contain, equal or sit inside) the config root,
the agent-containers clone, `RESEARCH_DIR`, or any builder's `PROJECT_DIR`, `SPADES_AI_DIR` or
`AGENT_MEMORY_DIR`. The existing `RESEARCH_DIR` check also checks it against every builder's
`SHARED_INPUTS_DIR`.

**Instructions:** `agent-instructions.md` is **assembled**: a new `instructions/builder-shared-inputs.md`
when shared inputs is on, followed by `builder-research.md` when research is on; mounted whenever at
least one is on. The research profile is unchanged. `builder-shared-inputs.md` says, in the
existing style:

- `/inputs` is shared with the owner's other SpaDES projects. `inputs/` links into it; the container
  sets `reproducible.inputPaths` and `reproducible.tempPath`.
- In `global.R`, leave `inputPath` and `reproducible.inputPaths` / `destinationPathShared` /
  `tempPath` at their defaults; setting them silently brings back duplicate copies.
- Files get into `/inputs` only through `prepInputs(url = <original source>)`.
- Never edit, overwrite, rename or delete anything in `/inputs/shared` or another project's folder;
  never `overwrite = TRUE` for files there; never open an input for in-place update. If a file
  there looks wrong, tell the owner.
- Never copy anything from `/research` into `/inputs`.
- Everything downloaded is visible to the owner's other projects. If an input is restricted
  (licensed, private, fetched with credentials), tell the owner before fetching it.
- The owner deletes files when the disk is full; a later run downloads them again. Expected, not an
  error.

### 4.6 `agent-up status`

For each distinct `SHARED_INPUTS_DIR` in use: total size; size of `.tmp` (leftovers from interrupted
downloads, safe to delete when no project is downloading); and the size of files in `shared/` with a
link count of 1, i.e. no project links them any more. Only deleting those frees space; deleting a
file from `shared/` alone frees nothing while a project still links it. (Exact wording and whether
to list the files: builder's call.)

### 4.7 Docs

- `project-template/README.md`: new section "Shared inputs" (what it is, on by default, turning it
  off, the bioinformatics rollout note, isolation trade-off, `global.R` stays standard, clean-up and
  the link-count rule, `.tmp`, migrating an existing `inputs/`, moving the folder to another drive);
  mentions in "What the container gets (builder profile)", "Settings worth knowing" and "Known
  residual risks" (cross-project write access; in-place edits reach every project; a `global.R`
  that sets the paths bypasses the feature).
- The main design spec (2026-10-03) is not rewritten; this spec is the reference.

## 5. Project side

Nothing. Modules use the normal `prepInputs(url = ..., destinationPath = inputPath(sim))`; `global.R`
uses `setupProject()` with the default `inputPath`. Outside our containers the same files give the
standard per-project `inputs/` (and whatever `reproducible.inputPaths` the colleague has set).

**Scope:** container side, image block, docs and runbook. Existing projects' `inputs/` folders are
not migrated by this work; the owner migrates them by the README steps when they choose.

## 6. Non-goals and anti-goals

- **Non-goals:** automatic clean-up or quotas; locking or patching `reproducible`; sharing the
  `Cache` between projects; read-only mode; setting up the HDD (a separate piece of work); fixing
  agents' large working data in `/tmp` (separate; seen in the bioinformatics container, 2026-10-23).
- **Anti-goals:** anything that makes a module or `global.R` depend on `/inputs`; anything that lets
  the research container, or files from `/research`, reach the folder; a second bind mount for
  `inputs/` (it would silently copy, §3.1); the launcher moving or deleting project data.

## 7. Tests

**Launcher (`tests/launcher/test-agent-up.sh`, in CI):**

- `init` writes both keys for builders, neither for research.
- Rendered compose: on → one bind to `/inputs` rw + both variables; `0` → none; key missing → on;
  research → never, explicit `SHARED_INPUTS=1` refused.
- Invalid value refused by `up`/`config`, accepted by `stop`/`down`.
- Overlap refusals (§4.5), including `RESEARCH_DIR` against `SHARED_INPUTS_DIR`.
- Instructions assembled correctly for the four on/off combinations.
- `up` creates the layout; each `inputs/` state in §4.4 gives the stated action, and a real folder's
  contents are untouched; `.git/info/exclude` gets `/inputs` once (idempotent), and nothing when
  there is no repo.
- `status`: link-count-1 size from a fixture tree with linked and unlinked files.

**Image smoke test:** with the two variables set, a fresh R has both options; with an option already
set (e.g. via `R_PROFILE_USER` fixture), it is not overridden; without the variables, neither is set.

**In real builders (manual; runbook `docs/runbooks/shared-inputs-check.md`, run by the owner, results
recorded in the PR):** on the `reproducible` release `setupProject()` installs, and on `main` if
they differ, using a small public file on an allowlisted host:

1. Project A `prepInputs()` downloads it: one inode shared by `shared/` and `projects/A/` (link
   count 2). Project B runs the same call: no download, link count 3, one copy on disk.
2. During a larger download nothing appears at the final name until complete; scratch is under
   `.tmp/<project>`.
3. A and B fetch the same missing file at once: record what happens (§3.6) and that a re-run
   recovers.
4. Both finish at once: does `CHECKSUMS.txt` lose lines (§3.7), and does the next run recover.
5. RStudio session (RSTUDIO=1): `getOption("reproducible.inputPaths")` is `/inputs/shared`.
6. Same file name, different content (two URLs) in A and B: what each project ends up using.
7. A short run of a typical LandR / scfm setup: does any input file's link count drop or content
   change in place (§3.8).
8. The research container has no `/inputs`; the bioinformatics container (off) has none either.

If a result contradicts §3, stop and bring it to the owner before changing the design. Agents cannot
run Docker on the host, so the launcher PR stays a draft until the owner has recorded the results.

## 8. Left to the builder

- Exact wording of instructions, README and messages; comment style in `project.conf`.
- Shape of the overlay writer, the link step and instruction assembly.
- Whether the link name/location should be a setting for projects whose `projectPath` is not
  `/workspace` (default: fixed `inputs`, documented).
- The small public file for the runbook.

## 9. Later: several projects per container (not designed here)

The owner may move to fewer containers, each holding a group of projects that benefit from seeing
each other (e.g. the SpaDES harvesting, CIMP and fire-change projects), while projects with very
long-running processes (bioinformatics) keep their own. This design should carry over without
rework: the host tree, the single `/inputs` bind, the image block and the `inputs/` links per
project stay the same; only the per-project values (`projects/<project>/`, `.tmp/<project>/`,
`SPADES_INPUTS_TMP`) would become per-project-folder rather than per-container. Keep these as
seams in the launcher code (one function that maps a project to its paths), not hard-wired to
"one project = one container".

## 10. Parked (2026-10-25): why, open findings, and how to pick it up

**Decision.** The owner postponed this work until the problem grows enough to justify the added
complexity ("we don't need to over-engineer now"). For now the owner consolidates the SpaDES
harvesting, fire-change and CIMP projects into **one builder container**, which shares inputs (and
module checkouts) between them without any launcher change. Bioinformatics stays in its own
container (very long-running processes). The owner wants both less disk use and fewer repeated
multi-GB downloads.

**Findings after §1–9 were written (from the `reproducible` source, `main` `be02fa4`; untested):**

1. *Upstream updates a file under the same name.* `reproducible` does not notice: once a file is
   downloaded and its checksum recorded, it is reused. Recent versions trust a `.hash` sidecar and
   skip the remote check unless `options(reproducible.checkRemoteHash = TRUE)`
   (`pp_remote_hash_check()`, `R/preProcess.R`); the remote hash is available only from Google
   Drive (md5) or an HTTP `ETag`. With sharing, the **first project to download a file fixes the
   version for all projects** (consistent across projects, but a new project does not get fresh
   data). Getting the new version means deleting every link to the old file (in `shared/` and each
   project folder). A module whose committed `CHECKSUMS.txt` pins a version fails with
   "did not match expected file (checksums failed)" when upstream changes, shared or not
   (`R/download.R`). Not known from the source: whether a newer download replaces the copy in
   `shared/`; if it does, other projects keep the old version through their own links (two
   different files under one name). Add to the §7 runbook.
2. *Upstream releases under new names (e.g. dated).* Old versions pile up, in `shared/` and in each
   project folder that used them; nothing removes them (true today per project too). The §4.6
   clean-up report (files in `shared/` with link count 1) **misses** them, because the project
   folder still links the old file after the code moved on. A real clean-up needs "delete all links
   to this file" plus a report by last use. More launcher work than §4.6 assumes.
3. *Option C reconsidered:* no container change; each project downloads independently (updates
   behave as today) and a scheduled host job (e.g. `jdupes -L`) hard-links identical files across
   project `inputs/` folders. Saves the same disk for identical files, no cross-project access, no
   change to `global.R` or the image. Costs: repeat downloads, same in-place-edit risk, same care when
   deleting. Simplest fix if disk space were the only goal.

**Disk context measured 2026-10-23 (C: SSD, 2 TB; 8 TB HDD also in the machine).** The Ubuntu WSL
disk image was 437.8 GB (401 GB in use; `~/GitHub/agents/spades_bioinformatics` 287 GB) and
Docker Desktop's 450.6 GB (container layers 261 GB: the bioinformatics container's `/tmp` held
100 GB of agent working data, mostly `/tmp/coi-spike`; old stopped non-agent containers ~128 GB,
`ssh-server` 94 GB; images 125 GB; build cache 80 GB). Parked with this spec: cleaning that up,
compacting the disk images, an HDD "data drive" (an ext4 VHDX on the HDD attached to WSL, holding
shared inputs, a per-project `/scratch` for large agent working data, and optionally bioinformatics
data), and launcher protection against agents filling the container's own `/tmp`.

**Picking it up.** Re-measure first (`df -h /`, `docker system df`, `docker ps -as`, `du` of the
project folders). Revisit the choice between B (§1–9) and C with the findings above, and with how the
consolidated container has worked: inside one container, shared inputs between its projects are
only a convention in `global.R`, and §9 describes how B would carry over. Re-check §3 against the
`reproducible` release current at that time.
