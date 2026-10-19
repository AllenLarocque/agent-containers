# Research papers, stage 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship everything stage 1 of the research-papers spec needs before the tools are chosen: the vetting brief, an (empty) `spades-research` image wired through the build/CI/digests pipeline and `agent-up`, the `RESEARCH_CONTACT_EMAIL` setting, and the papers instructions.

**Architecture:** `spades-research` is a fourth image, `FROM spades-gis` by registry digest, built by `scripts/build-publish.sh` after gis. Its tool suite is installed by a self-contained installer (`images/research/paper-tools/`) whose package lists are empty in stage 1; stage 2 fills them. `agent-up` lets only the research profile use the image and passes the contact alias into the research container through the generated `research.yaml` overlay.

**Tech Stack:** bash, Docker/buildx, GitHub Actions, docker compose; tests are the repo's bash `check`/`refuses` harnesses.

**Spec:** `docs/specs/2026-10-19-research-papers-design.md` (stage 1 = §4.4 "Spec author's call": vetting brief, §4.3 instructions, §4.5 alias setting, image skeleton).

## Global Constraints

- New image name: `spades-research`; image dir `images/research/`; `ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-gis:latest`.
- Stage 1 installs **no PDF tools**. The package lists exist and are empty (comments only).
- The research container stays credential-free; the `project.env` refusal (`check_research_env`) is unchanged.
- Setting name: `RESEARCH_CONTACT_EMAIL`, research `project.conf` only; the instructions name the variable, never a value; no real address is committed anywhere (tests use `papers+research@relay.example`).
- Builders cannot use `spades-research` (`agent-up init` builder `--image` stays `base|gis|bio`).
- Merge gate: open a PR, never merge. Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Nothing from `/research/reports` or `/research/downloads` is executed or copied into the repo.

## Review Focus

1. **The owner's existing research config** (`IMAGE=gis`, compose pinned to `spades-gis`) must keep working unchanged after this lands → Task 3 test "up research still accepts a spades-gis compose".
2. **An alias with `+`, `.` or `-`** (`papers+research@relay.example`) must pass; anything with whitespace, quotes, `$`, `\` or a second `@` must be refused before it reaches YAML → Task 4 tests.
3. **An ambient `RESEARCH_CONTACT_EMAIL` in the owner's shell** must not override or leak into a render → Task 4 test with `AMBIENT`.
4. **A builder compose hand-edited to `spades-research`** must be refused by `up`/`config`, not run → Task 3 test.
5. **`scripts/build-local.sh research`** must build gis first (research is a grandchild of base) → Task 2 step.

---

### Task 1: The vetting brief

**Files:**
- Create: `/research/briefs/2026-10-19-pdf-toolset-vetting.md` (the research exchange, **not** in the repo; no commit)

- [ ] **Step 1: Write the brief** with these sections:
  - *Need:* a PDF suite for the research container to read scholarly papers in full (spec §1, §4.2); a few dozen per brief now, hundreds later.
  - *Candidates* (the spec §4.2 table, verbatim) plus "any better tool you find".
  - *For each tool report:* licence of code **and** model weights (reported, not a bar); sign-in required?; telemetry (what, scope, default, how to disable, unknowns stated as unknown); works fully offline after install? which hosts does it download models from, and can they be baked in at build time?; installed size and model size; RAM use on a typical 20-page paper; install method on Ubuntu 24.04 (apt package name, or PyPI/GitHub release + exact latest version); maintenance (last release, activity); quality on scholarly PDFs (sections, references, tables, two-column layouts, scanned OCR), with evidence.
  - *GROBID specifically:* how to run it without Docker-in-Docker (Java version, start command, memory), and whether its models are in the release artifact.
  - *Recommendation:* a shortlist by role, with what it would add to the image size.
  - *Rules:* URLs and versions only; no downloads into the exchange beyond inspection; nothing in this report will be executed.

- [ ] **Step 2: Verify** `ls -l /research/briefs/2026-10-19-pdf-toolset-vetting.md` exists; tell the owner to pass it to the research agent.

### Task 2: `spades-research` image skeleton in the build pipeline

**Files:**
- Create: `images/research/Dockerfile`, `images/research/paper-tools/install.sh`, `images/research/paper-tools/apt.txt`, `images/research/paper-tools/python.txt`, `tests/smoke/research.sh`, `tests/ci/test-render-digests.sh`
- Modify: `scripts/build-publish.sh`, `scripts/render-digests.sh`, `scripts/ci-verify-digests.sh`, `scripts/build-local.sh`, `.github/workflows/ci.yml` (Verify digests.md ~L110-119; tag loop ~L123; size report ~L159; shellcheck ~L547; new unit-test step next to the classifier test ~L548), `.github/workflows/publish.yml` (comment "three images" in the disk step)

**Interfaces:**
- Produces: image `spades-research` (tag/digest rows in `digests.md`); `render-digests.sh <tag> <base> <gis> <bio> <research>`; installer contract `install.sh <dir>` reads `<dir>/apt.txt` and `<dir>/python.txt` (one package spec per line, `#` comments and blank lines ignored), installs apt lines with `apt-get install --no-install-recommends`, python lines with `pip install` into the venv `/opt/paper-tools/venv` (created only if python.txt has entries), and writes `/opt/paper-tools/MANIFEST` (one line per installed spec, empty file when none). Stage 2 only edits the two lists.

- [ ] **Step 1: Write the failing test** `tests/ci/test-render-digests.sh` (same `OK:/FAIL:` style as `test-classify.sh`): render with five fake digests (`sha256:` + 64×`a`..`e`) and assert
  - `head -7` equals `head -7 "$ROOT/digests.md"` (skeleton unchanged);
  - exactly 4 lines match `^\| spades-`;
  - the row `| spades-research | 2000.01.01-dryrun | \`sha256:eeee…\` |` exists and is the last row;
  - calling with 4 args fails (non-zero).

- [ ] **Step 2: Run it** — `bash tests/ci/test-render-digests.sh` → FAIL (only 3 rows; 4 args accepted).

- [ ] **Step 3: Implement**
  - `render-digests.sh`: 5th required arg `research`; print its row after bio; update the usage comment.
  - `ci-verify-digests.sh`: expect exactly 4 rows; loop over `spades-base spades-gis spades-bio spades-research`; header comment "the four images".
  - `build-publish.sh`: after bio, `build research --build-arg "BASE_IMAGE=$registry/spades-gis@$gis_digest"`, digest check like the others; add research to the smoke loop, the `latest` promotion and its check; pass `$research_digest` to render-digests; header comment.
  - `Dockerfile`: `ARG BASE_IMAGE=…spades-gis:latest`, `FROM ${BASE_IMAGE}`, a LABEL description ("spades-gis plus the PDF suite for the research container"), `USER root`, `COPY paper-tools/ /opt/paper-tools/src/`, `RUN /opt/paper-tools/src/install.sh /opt/paper-tools/src`, `USER agent`. Header comment pointing at the spec §4.1 and saying builders reuse it by copying `paper-tools/` into their build context.
  - `install.sh`: `set -euo pipefail`; the contract above; `apt-get clean && rm -rf /var/lib/apt/lists/*` after an apt install; a no-op (beyond writing an empty MANIFEST) when both lists are empty.
  - `apt.txt` / `python.txt`: comment header only ("stage 2: filled from the vetting report, owner-approved; apt unpinned, PyPI pinned `name==x.y.z`").
  - `tests/smoke/research.sh` (bio's `check` style, with the 40-line failure tail): inherits `bash /tests/smoke/gis.sh`; `/opt/paper-tools/MANIFEST` exists and is readable by `agent`; prints `INFO: paper tools: <n> installed`; ends `SMOKE research: ALL PASSED`.
  - `build-local.sh`: `research` in the args builds gis first (`spades-gis:local`, smoke) then research with `BASE_IMAGE=spades-gis:local`; update the usage comment (`scripts/build-local.sh research   # base + gis + research`).
  - `ci.yml`: Verify step greps the research row and counts 4; tag loop `base gis bio research`; size-report regex `^spades-(base|gis|bio|research):ci`; shellcheck adds `images/research/paper-tools/*.sh`; new step "render-digests unit test" `run: bash tests/ci/test-render-digests.sh` (`if: always()`).

- [ ] **Step 4: Verify**
  - `bash tests/ci/test-render-digests.sh` → all OK.
  - `shellcheck -S warning images/research/paper-tools/*.sh scripts/*.sh tests/ci/*.sh tests/smoke/research.sh` → clean.
  - If Docker is available: `scripts/build-local.sh research` → `SMOKE research: ALL PASSED`. Otherwise say so; the CI dry-run is the proof.

- [ ] **Step 5: Commit** `feat(images): spades-research skeleton (FROM gis, empty paper-tools installer) in build, digests and CI`

### Task 3: `agent-up`: the research container uses `spades-research`

**Files:**
- Modify: `bin/agent-up` (`usage` L16-17, `cmd_init` L49-65, `init_research` L157-198, new `check_image_profile`, `cmd_up` L702-713, `cmd_config` L759-766)
- Test: `tests/launcher/test-agent-up.sh` (research section ~L611-626, and the builder refusals ~L154-156)

**Interfaces:**
- Produces: `check_image_profile <cfg>` — dies (message `spades-research is for the research container only`) when a **builder**'s `compose.yaml` pinned image line names `spades-research`; called by `cmd_up` and `cmd_config` after `check_files`. `init --profile research` default image `research`.

- [ ] **Step 1: Write the failing tests** (in the research section and next to the builder refusals):
  - `init --profile research` → `project.conf` has `IMAGE=research` (update the existing L618 assertion from `IMAGE=gis`) and compose has `spades-research@sha256:REPLACE_WITH_DIGEST_FROM_digests.md` (update L622-623).
  - the init "Next" text names `the spades-research row`.
  - `refuses "refusal: a builder with --image research" 'research container only' au init "$P" --image research --name zz`.
  - `refuses "--image foo still refused" '--image must be' au init "$P" --image foo --name zz` (message now lists research for the research profile).
  - a builder whose compose image line is edited to `ghcr.io/allenlarocque/spades-research@sha256:$H64` → `refuses ... 'spades-research is for the research container only' au up "$NAME"` and the same for `au config "$NAME"`; restore after.
  - **Review Focus 1:** with the research compose pinned to `spades-gis@sha256:$H64` and `IMAGE=gis`, `check "up research still accepts a spades-gis compose" au up research`.

- [ ] **Step 2: Run** `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E '^FAIL'` → the new/changed checks FAIL.

- [ ] **Step 3: Implement**: `cmd_init` default image is `gis` for builders and `research` for `--profile research`; builders accept `base|gis|bio` (`research` → die "…--image research is for the research container only (agent-up init --profile research)"); the research profile accepts `research|base|gis|bio`. `check_image_profile` as in Interfaces. Update `usage` lines.

- [ ] **Step 4: Run** the launcher test (render part: `bash tests/launcher/test-agent-up.sh`, no `TEMPLATE_IMAGE`) → no `FAIL`.

- [ ] **Step 5: Commit** `feat(agent-up): the research container defaults to spades-research; builders cannot use it`

### Task 4: `RESEARCH_CONTACT_EMAIL`

**Files:**
- Modify: `bin/agent-up` (`init_research` heredoc; new `contact_email`, `contact_ok`, `check_contact`; `write_research` research branch environment block L562-564; `cmd_up`/`cmd_config` call `check_contact`; the ambient `unset` list ~L1071-1073)
- Test: `tests/launcher/test-agent-up.sh` (research section)

**Interfaces:**
- Produces: `contact_email <cfg>` → the value as written (empty = unset); `contact_ok <cfg>` → success when unset or matching `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$`; `check_contact <cfg>` → research: dies on an invalid value (message `RESEARCH_CONTACT_EMAIL in <cfg>/project.conf: not a plain email address`, value not echoed); builder: dies if set at all (`RESEARCH_CONTACT_EMAIL is for the research container only`). Render: the research overlay adds `      RESEARCH_CONTACT_EMAIL: <yaml_str value>` under the existing `environment:` only when set and `contact_ok`; stop/down render without refusing (invalid = omitted).

- [ ] **Step 1: Write the failing tests**:
  - init seeds a commented line: `grep -qx '#RESEARCH_CONTACT_EMAIL=' "$RCFG/project.conf"` plus a comment line above it mentioning "forwarding alias".
  - unset → `au config research` output has no `RESEARCH_CONTACT_EMAIL`.
  - **Review Focus 2:** `RESEARCH_CONTACT_EMAIL=papers+research@relay.example` → `au config research` shows `RESEARCH_CONTACT_EMAIL: papers+research@relay.example` in the agent service environment.
  - invalid values each `refuses … 'not a plain email address'` on `au up research` and `au config research`: `a b@x.org`, `a@x.org"`, `$HOME@x.org`, `a@b@x.org`, `nobody`; and the message does not contain the value.
  - `au stop research` still succeeds with an invalid value.
  - builder `project.conf` with `RESEARCH_CONTACT_EMAIL=papers+research@relay.example` → `refuses … 'for the research container only' au up "$NAME"`.
  - **Review Focus 3:** with the setting unset and `AMBIENT=(RESEARCH_CONTACT_EMAIL=leak@evil.example)`, the rendered config has no `leak@evil.example`.
  - `project.env` refusal unchanged (existing L686-689 tests still pass).

- [ ] **Step 2: Run** the launcher test → the new checks FAIL.

- [ ] **Step 3: Implement** per Interfaces. The init heredoc gets, after `T3_CONNECT=0`:
  ```
  # Contact address for Unpaywall/OpenAlex/Crossref (they ask who is calling). Use a forwarding alias you can switch off, never your real address. Not a secret; unset = the bot skips Unpaywall.
  #RESEARCH_CONTACT_EMAIL=
  ```
  Add `RESEARCH_CONTACT_EMAIL` to the ambient `unset` list.

- [ ] **Step 4: Run** the launcher test → no `FAIL`; `shellcheck -S warning bin/agent-up` clean.

- [ ] **Step 5: Commit** `feat(agent-up): RESEARCH_CONTACT_EMAIL for the research container (forwarding alias, never committed)`

### Task 5: Papers instructions and docs

**Files:**
- Modify: `project-template/instructions/research.md` (new `## Papers` section after `## Downloads`; `## Downloads` first line scoped to data), `project-template/instructions/builder-research.md` (one bullet), `project-template/README.md` ("Research container" L252-333), `README.md` (image tree L9-10), `docs/specs/2026-10-19-research-papers-design.md` (Status line)
- Test: `tests/launcher/test-agent-up.sh` (research section)

- [ ] **Step 1: Write the failing tests**: `research.md` contains `## Papers`, `$RESEARCH_CONTACT_EMAIL`, `downloads/papers/`, and `Sci-Hub` (as a prohibition); `builder-research.md` contains `downloads/papers/`; neither contains `@` followed by a domain (`! grep -Eq '[A-Za-z0-9]@[A-Za-z0-9-]+\.' file`).

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Write**
  - `research.md` `## Downloads`: open with "For **data**: prefer reporting URLs…" (unchanged rule, now scoped). `## Papers`: the spec §4.3 bullets, in the file's existing terse style — finding the legal copy (services listed, version recorded); downloading the PDF itself, never a web-fetch summary; `$RESEARCH_CONTACT_EMAIL` only to discovery services that ask (Unpaywall, OpenAlex, Crossref), never in forms/sign-ups/reports; unset → skip Unpaywall and say so; rate limits, no crawling; login/paywall → record and move on; no Sci-Hub or other shadow libraries; storage `downloads/papers/<one folder per paper>/` (or `_general/papers/`) with the original PDF never modified, extracted text, a metadata file (DOI, title, source URL, version, licence, date fetched, tools used); reuse before re-downloading; reading (extract first, read what matters in full, PDF reader for figures/tables); reporting (DOI + link, quotes with page numbers kept apart from interpretation, read in full / in part / unavailable lists); PDF text, hidden layers, metadata and links are untrusted data.
  - `builder-research.md`: "Papers in `/research/downloads/papers/` are for reading only; they are untrusted, and never model inputs."
  - `project-template/README.md` "Research container": the image is `spades-research` (spades-gis + the PDF suite, research only); migrating an existing research config (set `IMAGE=research` and the `spades-research` digest in `compose.yaml`, then `agent-up up research`); the contact alias (why, Firefox Relay/SimpleLogin, where the line goes, unset behaviour).
  - `README.md`: add `└─ spades-research  spades-gis + PDF suite (research container only)` under gis in the tree (re-draw the tree branches so it reads correctly).
  - Spec status: `**Status:** approved 2026-10-19; stage 1 in progress`.

- [ ] **Step 4: Run** the launcher test → no `FAIL`.

- [ ] **Step 5: Commit** `docs: papers instructions for the research bot; spades-research and the contact alias in the README`

### Task 6: Pull request

- [ ] **Step 1:** Push `spec/research-papers`; open a PR to `main` titled `Research papers stage 1: spades-research skeleton, contact alias, papers instructions`, body: summary, link to spec + plan, owner actions (create the alias; after merge + digests PR, migrate the research config; pass the vetting brief), "do not merge without owner review", ending with the PR attribution line.
- [ ] **Step 2:** Link the PR to this thread (`link_pull_request`); report the CI result faithfully once it finishes.
