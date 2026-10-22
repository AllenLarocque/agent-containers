# Research papers, stage 2a (PDF tools: text, repair, OCR, GROBID) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `spades-research` ships the owner-approved stage 2a tools: poppler-utils, qpdf, Tesseract + OCRmyPDF and GROBID (CRF only). It also gets a `grobid` wrapper for the bot, and a smoke test that runs each tool on a real paper with the network off.

**Architecture:**
- **apt and PyPI tools:** installed by the existing installer, `images/research/paper-tools/install.sh`, from `apt.txt` and `python.txt`. Python tools go into a `uv` venv; the image has no `ensurepip`, so `python3 -m venv` fails.
- **GROBID:** copied from its official image, pinned by digest, in a multi-stage `COPY --from`. A second script, `install-grobid.sh`, configures it, and the `grobid` wrapper runs it as an on-demand localhost service.
- **Verification:** the research smoke test runs inside `scripts/build-publish.sh` with `--network none`. CI is the only place it can run: this builder has no docker and cannot reach Docker Hub or PyPI.

**Tech Stack:** bash, Docker/buildx (multi-stage), uv, curl, poppler/qpdf/tesseract, OCRmyPDF 17, GROBID 0.9.1 on OpenJDK 21.

**Spec:** `docs/specs/2026-10-19-research-papers-design.md`, stage 2 (§4.1, §4.2, §6.1). The tool choice comes from the vetting report (untrusted data; nothing copied from it). The owner approved it on 2026-10-21 and split stage 2 in two: 2a here, Docling in 2b.

## Global Constraints

- **The approved 2a tools, exactly:**
  - apt: `poppler-utils`, `qpdf`, `tesseract-ocr`, `tesseract-ocr-eng`, `tesseract-ocr-osd`, `openjdk-21-jre-headless`;
  - PyPI: `ocrmypdf==17.13.0`;
  - GROBID: `grobid/grobid:0.9.1-crf@sha256:<digest the owner confirmed>` (see "Before execution").
- **Not installed, ever:** Ghostscript (`gs`), PyMuPDF, `unpaper`, `grobid-client-python`, Docling (that's 2b). The smoke test asserts that `gs` is absent.
- **Pins:** apt stays unpinned (the weekly rebuild picks up security patches). PyPI is pinned `name==x.y.z`. GROBID is pinned by tag **and** digest.
- **Runs offline:** nothing is downloaded at runtime. GROBID consolidation (Crossref) is always sent as `0`.
- **GROBID limits, set in the image:**
  - `concurrency: 2`;
  - pdfalto `memoryLimitMb: 2048`;
  - JVM `-Xmx4g`, which `GROBID_JAVA_OPTS` overrides;
  - port `8070`, on localhost only.
- **Non-root:** every tool runs as `agent`. GROBID's runtime state (pidfile, log) lives under `${XDG_STATE_HOME:-$HOME/.local/state}/grobid`, never in `/opt`.
- **Untrusted inputs:** the bot runs these tools on untrusted PDFs. No tool output is ever eval'd.
- **No workflow edits:** do not touch `.github/workflows/*`. The token has no `workflow` scope; if a change seems to need one, stop and ask the owner.
- **Runner disk:** if the build runs out of disk, stop and bring the owner options (spec §4.1). Do not drop tools or work around it.
- **Merge gate:** one PR, `feat/paper-tools-2a` → `main`. Open it **ready, not draft**, because a draft skips the image build. Never merge. Every commit ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Nothing from `/research/reports` or `/research/downloads` is executed or copied into the repo.

## Before execution (owner, on the host)

The GROBID digest must come from Docker Hub itself, not from the report. The owner runs:

```bash
docker buildx imagetools inspect grobid/grobid:0.9.1-crf | head -4
```

The owner pastes back the `Digest:` line (the multi-arch index digest). Task 2 pins exactly that value.

## Review Focus

1. **A scanned PDF sent straight to GROBID.** The bot should get a one-line hint ("no text layer: run `ocrmypdf --output-type pdf` first") and exit 2, not a raw HTTP 500 body. Task 2 test: "grobid on image-only PDF".
2. **A paper file name with spaces, `;` or `,`.** curl's `-F input=@…` breaks on `;` and `,`, and real downloaded titles contain them. Task 2 test: "grobid on a hostile file name".
3. **`grobid start` when it is already running, or after a crash left a stale pidfile.** Either way there must be one JVM, not two, and no error. Task 2 test: "start is idempotent".
4. **Network off.** Nothing may reach out at runtime: tesseract data, GROBID consolidation, uv. The research smoke runs under `--network none` (Task 1).
5. **The installer's comment stripping.** `name==1.0  # why` and `pkg @ https://…#sha256=…` must both survive. Only `#` at line start or after whitespace starts a comment. Task 1 test: "MANIFEST lists exactly the specs".

---

### Task 1: Installer (uv venv, comment parsing, MANIFEST), apt/PyPI tools, and an offline smoke on a real paper

**Files:**
- Modify: `images/research/paper-tools/install.sh`
- Modify: `images/research/paper-tools/apt.txt`, `images/research/paper-tools/python.txt`
- Modify: `scripts/build-publish.sh` (the smoke loop: research runs with `--network none`)
- Create: `tests/fixtures/pdf/rcpp-jss-2011.pdf`, copied from `/usr/local/lib/R/site-library/Rcpp/doc/Rcpp-jss-2011.pdf`
- Create: `tests/fixtures/pdf/README.md`, giving the source, the citation (Eddelbuettel & François 2011, *JSS* 40(8), doi:10.18637/jss.v040.i08) and the licence (JSS articles: CC BY 3.0; shipped in Rcpp, GPL ≥ 2)
- Modify: `tests/smoke/research.sh`
- Modify: `docs/specs/2026-10-19-research-papers-design.md`: set the status line to "stage 1 done 2026-10-19; stage 2a in progress", and add a short "Approved tools (owner, 2026-10-21)" paragraph under §4.2 listing the 2a and 2b picks, the rejects in one line, and the 2a/2b split.

**Interfaces:**
- **Produces:**
  - `/opt/paper-tools/MANIFEST`:
    - `apt: <pkg> <installed version>` per apt spec (version from `dpkg-query -W -f='${Version}'`);
    - `pip: <spec>` per python spec;
    - the GROBID line is added in Task 2.
  - `/opt/paper-tools/python.freeze`: the full resolved set, from `uv pip freeze`.
  - `/opt/paper-tools/venv`.
  - `/usr/local/bin/<name>` symlinks into `venv/bin/<name>`, for each python spec whose package name has a matching console script (here: `ocrmypdf`).
- **Consumes, in the smoke test:** `/tests/fixtures/pdf/rcpp-jss-2011.pdf`. `tests/` is already mounted at `/tests`.

- [ ] **Step 1: Write the failing smoke checks** in `tests/smoke/research.sh`. Use the existing `check` helper, a scratch dir `w=$(mktemp -d)`, and `S=/tests/fixtures/pdf/rcpp-jss-2011.pdf`.
  - `MANIFEST lists exactly the specs`: the `apt:` package names equal the 6 approved packages, in order; the `pip:` lines equal exactly `pip: ocrmypdf==17.13.0`.
  - `no Ghostscript`: `! command -v gs`.
  - `ocrmypdf on PATH, venv python 3.12`: `ocrmypdf --version` prints `17.13.0`; `/opt/paper-tools/venv/bin/python -V` matches `3.12`.
  - `pdfinfo`: pages ≥ 10.
  - `pdftotext`: `pdftotext -layout "$S" -` contains `Seamless R and C++ Integration`.
  - `pdfimages -list`: exits 0.
  - `qpdf --check`: exits 0.
  - `qpdf repairs a truncated copy`: `head -c -300 "$S" > broken.pdf`. Then `qpdf broken.pdf fixed.pdf` exits 0 or 3 (3 = warnings), and `pdftotext fixed.pdf -` still contains `Seamless`.
  - `OCR of a scanned page`:
    1. `pdftoppm -r 200 -f 1 -l 1 -png "$S" p`.
    2. Make an image-only PDF from the PNG: `ocrmypdf --image-dpi 200 --tesseract-timeout 0`, or `img2pdf` if the venv provides it.
    3. Assert `pdftotext` of it has fewer than 20 non-space characters.
    4. `ocrmypdf --output-type pdf --sidecar scan.txt scan.pdf scan-ocr.pdf` exits 0, and `scan.txt` contains `Seamless` (case-insensitive).
    5. Keep `scan.pdf` and `scan-ocr.pdf` in `$w` for Task 2.
  - The existing MANIFEST-readable check stays.

- [ ] **Step 2: Verify that they fail.** The lists are still empty, so the MANIFEST and tool checks must fail. There is no docker here, so check it by reading the script. Run `bash -n tests/smoke/research.sh` and `shellcheck -S warning tests/smoke/research.sh`; both must be clean.

- [ ] **Step 3: Implement.**
  - **`install.sh`:**
    - A comment starts at `#` at line start or after whitespace: strip `[[:space:]]#.*` and `^#.*`, never a bare `#`. Update the header comment to say so.
    - Python: `uv venv --python /usr/bin/python3 "$out/venv"`, then `UV_NO_CACHE=1 uv pip install --python "$out/venv/bin/python" "${py_pkgs[@]}"`.
    - Write `python.freeze`.
    - The symlink rule above: the package name is the spec up to the first of `=<>!~[ @;`.
    - MANIFEST lines as in Interfaces.
  - **The lists:** fill them with the Global Constraints values, one per line, each with a short trailing `# why` comment. This also exercises the comment fix.
  - **`build-publish.sh`:** in the smoke loop, add `--network none` for `research` only, with a comment citing spec §6.1.
  - **Fixtures:** copy the fixture PDF, and write its `README.md`.
  - **Spec:** make the spec edits listed under Files.

- [ ] **Step 4: Verify in CI.**
  1. Run `shellcheck -S warning images/research/paper-tools/*.sh scripts/build-publish.sh tests/smoke/research.sh`; it must be clean.
  2. Commit, then push `feat/paper-tools-2a` and open the PR as **ready**. Title: `feat(images): spades-research stage 2a — poppler, qpdf, Tesseract/OCRmyPDF, GROBID`. Body: the tool table, sizes to be filled from the CI "image sizes" notice, and "do not merge until Task 3".
  3. Link the PR with `link_pull_request`.
  4. Watch `build-test`. Expected: `SMOKE research: ALL PASSED`, with every check above as an `OK:` line in the log.
  5. Record the research image size from the `image sizes` notice.
  6. If the build fails, read the log with `gh run view --log-failed` and fix it. Do not weaken an assertion to make it pass.

- [ ] **Step 5: Commit.** Use one commit per fix if CI needs iterations.

```bash
git add images/research/paper-tools scripts/build-publish.sh tests/fixtures/pdf tests/smoke/research.sh docs/specs/2026-10-19-research-papers-design.md
git commit -m "feat(images): paper tools 2a — poppler, qpdf, tesseract, ocrmypdf (uv venv); offline smoke on a real paper"
```

### Task 2: GROBID (multi-stage copy, config, `grobid` wrapper) with smoke

**Files:**
- Modify: `images/research/Dockerfile`:
  - a global `ARG GROBID_IMAGE=grobid/grobid:0.9.1-crf@sha256:<owner-confirmed>` before the first `FROM`, then `FROM ${GROBID_IMAGE} AS grobid`;
  - `COPY --from=grobid /opt/grobid /opt/paper-tools/grobid` **before** the install `RUN`;
  - `RUN /opt/paper-tools/src/install-grobid.sh "$GROBID_IMAGE"`, with `ARG GROBID_IMAGE` re-declared after `FROM`;
  - a comment saying which three lines a builder image would copy (graceful growth).
- Create: `images/research/paper-tools/install-grobid.sh`
- Create: `images/research/paper-tools/bin/grobid`, the wrapper; `install-grobid.sh` installs it to `/usr/local/bin/grobid`.
- Modify: `tests/smoke/research.sh`

**Interfaces:**
- **Consumes:** `/opt/paper-tools/MANIFEST` from Task 1 (append only); `scan.pdf` and `scan-ocr.pdf` from Task 1's smoke checks (same `$w`).
- **Produces:**
  - `install-grobid.sh <image-ref>`:
    - fails the build unless `/opt/paper-tools/grobid/grobid-service/bin/grobid-service` and `grobid-home/config/grobid.yaml` exist;
    - sets `concurrency: 2` and pdfalto `memoryLimitMb: 2048` in `grobid.yaml`, anchored edits, and **fails** if either key is not found, or if the result doesn't hold the new values;
    - deletes the non-`lin-64` pdfalto/lib architecture dirs if present;
    - makes `grobid-home/tmp` writable (`chmod -R a+rwX`);
    - appends `grobid: <image-ref> (CRF only, consolidation off)` to MANIFEST.
  - `grobid` CLI. Exit codes: 0 ok, 1 error, 2 "input has no text layer".
    - `grobid start`: idempotent.
      - If `GET http://127.0.0.1:8070/api/isalive` is OK, exit 0.
      - Otherwise drop a stale pidfile and launch `./grobid-service/bin/grobid-service` from `/opt/paper-tools/grobid` with nohup, in the background.
      - The launch env is `JAVA_OPTS=${GROBID_JAVA_OPTS:--Xmx4g}`, `GROBID_SERVICE_OPTS='--add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/sun.nio.ch=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED'` and `LD_LIBRARY_PATH=grobid-home/lib/lin-64`.
      - Write the pidfile and log under the state dir.
      - Wait up to `${GROBID_START_TIMEOUT:-180}` s for isalive. On timeout, print the last 40 log lines and exit 1.
    - `grobid stop`: kill the pidfile's process (TERM, then KILL after 20 s), remove the pidfile, exit 0 if it is not running.
    - `grobid status`: exit 0 if alive, otherwise 1.
    - `grobid fulltext <in.pdf> <out.tei.xml>` (and `grobid header <in.pdf> <out.tei.xml>`):
      - starts the service if needed;
      - symlinks the input into a private temp dir as `in.pdf` (this handles hostile names);
      - POSTs `/api/processFulltextDocument` (or `processHeaderDocument`) with `consolidateHeader=0`, `consolidateCitations=0`, `consolidateFunders=0`;
      - on HTTP 200, writes `out` atomically (temp file, then `mv`);
      - if the body mentions `NO_BLOCKS`, prints the ocrmypdf hint and exits 2;
      - on any other non-200, prints the status and the first 5 lines of the body and exits 1.
    - `grobid --help` or no arguments: usage, exit 0 for `--help`, 1 otherwise.

- [ ] **Step 1: Write the failing smoke checks.** Add them after Task 1's checks, using `S` and `w`.
  - `grobid installed`:
    - MANIFEST has a line matching `^grobid: grobid/grobid:0\.9\.1-crf@sha256:[0-9a-f]{64} `;
    - `grobid.yaml` has `concurrency: 2` and `memoryLimitMb: 2048`;
    - `java -version` reports 21.
  - `start is idempotent`: `grobid start` twice, both exit 0; `pgrep -cx java` = 1 (not `pgrep -f`: the check's own `bash -c` command line would match). Then kill -9 the JVM, run `grobid start` again: exit 0, `pgrep -cx java` = 1.
  - `grobid fulltext`:
    - `grobid fulltext "$S" "$w/a.tei.xml"` exits 0;
    - the main title (`<title level="a" type="main">`) contains `Rcpp`;
    - there are at least 10 `<biblStruct`;
    - there are at least 3 `<head` (sections).
  - `grobid on a hostile file name`: copy `$S` to `"$w/A paper; v2, final.pdf"`; `fulltext` exits 0 and the TEI title contains `Rcpp`.
  - `grobid on image-only PDF`: `grobid fulltext "$w/scan.pdf" "$w/s.tei.xml"` exits 2, its stderr mentions `ocrmypdf`, and `s.tei.xml` is not created.
  - `scan → OCR → GROBID`: `grobid fulltext "$w/scan-ocr.pdf" "$w/so.tei.xml"` exits 0, and the title contains `Rcpp`.
  - `grobid stop`: exits 0; afterwards `grobid status` exits 1.
  - **Peak memory, INFO only, no threshold:**
    - before `stop`, print `INFO: grobid JVM peak RSS: <VmHWM from /proc/<pid>/status>`;
    - for ocrmypdf, wrap Task 1's OCR command in `/opt/paper-tools/venv/bin/python -I -c` with `subprocess.run` plus `resource.getrusage(RUSAGE_CHILDREN).ru_maxrss`, and print `INFO: ocrmypdf peak RSS: … KiB`. Inline in the smoke test; don't add a helper file.

- [ ] **Step 2: Verify that they fail.** Lint the smoke script with `bash -n` and `shellcheck` (clean). The GROBID checks can't pass until Step 3.

- [ ] **Step 3: Implement** the Dockerfile lines, `install-grobid.sh` and `bin/grobid` to the Interfaces above. `bin/grobid` takes `GROBID_HOME_DIR`, default `/opt/paper-tools/grobid`, so the smoke test can't silently test another copy. Use `curl -sS -o "$tmp" -w '%{http_code}'`, and parse nothing from the body except the `NO_BLOCKS` grep.

- [ ] **Step 4: Verify in CI.**
  1. Run `shellcheck -S warning images/research/paper-tools/*.sh images/research/paper-tools/bin/grobid tests/smoke/research.sh`; it must be clean.
  2. Push.
  3. Expected: `SMOKE research: ALL PASSED`, with both INFO memory lines in the log.
  4. Record the new image size.
  5. If GROBID writes somewhere unwritable (for example `logs/` under its home), fix it in `install-grobid.sh` (make that one dir writable, or point it to the state dir). Don't run as root.
  6. CI shellchecks only `images/research/paper-tools/*.sh`, so `bin/grobid` is not covered there; say so in the PR body.

- [ ] **Step 5: Commit.**

```bash
git add images/research/Dockerfile images/research/paper-tools tests/smoke/research.sh
git commit -m "feat(images): GROBID 0.9.1 CRF in spades-research (digest-pinned COPY --from), grobid wrapper, offline smoke"
```

### Task 3: How the bot uses the tools

**Files:**
- Create: `images/research/paper-tools/README.md`. `install.sh` copies it to `/opt/paper-tools/README.md`. A short usage card:
  - which tool for what: `pdfinfo`, `pdftotext -layout`, `pdfimages`, `qpdf` to repair or decrypt, `ocrmypdf --output-type pdf --sidecar` for scans (never `pdfa`), and `grobid fulltext|header|start|stop`;
  - the order for a paper: `pdftotext` → if there is no text layer, `ocrmypdf` → `grobid fulltext` for sections and references;
  - memory: GROBID holds ~4–5 GB while running; `grobid stop` when done with a batch;
  - one line: no tables tool yet (Docling arrives in 2b; use the built-in PDF reader for tables).
- Modify: `project-template/instructions/research.md`, the "PDF tools" bullet: point to `/opt/paper-tools/README.md` for how to use them. Keep the existing "never install tools yourself" rule unchanged.
- Modify: `tests/smoke/research.sh`: `README readable by agent, names every MANIFEST tool`. The README mentions each of `pdftotext`, `qpdf`, `tesseract`, `ocrmypdf` and `grobid`.
- Modify: `docs/specs/2026-10-19-research-papers-design.md`: under the 2a paragraph, add the measured image size and peak-memory figures from CI (Tasks 1–2).

**Interfaces:**
- **Consumes:** the `grobid` subcommands (Task 2) and MANIFEST (Task 1).

- [ ] **Step 1:** Write the failing smoke check above. Lint it.
- [ ] **Step 2:** Write the README and the `install.sh` copy line, the `research.md` pointer, and the spec figures.
- [ ] **Step 3:** Push. Expected: CI is green, with `SMOKE research: ALL PASSED`.
- [ ] **Step 4:** Commit:

```bash
git add images/research/paper-tools tests/smoke/research.sh project-template/instructions/research.md docs/specs/2026-10-19-research-papers-design.md
git commit -m "docs(research): paper-tools usage card in the image; instructions point to it"
```

- [ ] **Step 5:** Update the PR body: final image size, memory figures, and the follow-ups below. Hand the PR to the owner and do not merge. After the owner merges, publish opens the digests PR. Then the research container is moved with `agent-up update research`; the image name is the same, so a digest bump suffices.

---

## Follow-ups (not in 2a)

- **2b:** Docling (CPU torch, layout + TableFormer models baked in, `HF_HUB_OFFLINE=1`). It gets its own plan, after 2a's measured size and the runner's free disk are known.
- **Weekly update flow:** report new `ocrmypdf` and GROBID releases from `scripts/update-candidates.sh` (GitHub releases via `gh api`), with the bump left to the owner. A GROBID bump needs a Docker Hub digest, which the update agent cannot reach.
- **A Python lock with hashes:** `uv pip compile --generate-hashes`. It needs PyPI access, so the owner runs it on the host. `python.freeze` records the resolved set until then.
- **Launcher minors (separate PR):** `check_image_profile` regex gaps; the builder refusal misses `export`-prefixed lines; CRLF gives a generic message; `agent-up busy` could print `IDLE`.
- **Acceptance (spec §6.3):** the fire brief, run once with Claude Code and once with Codex, after 2a is live, or after 2b if tables matter for it.
