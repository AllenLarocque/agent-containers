# Google Drive read-only service account — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** let every builder container read Google Drive inputs with `prepInputs()` through a
read-only Google service account the owner controls, (a workshop guide for the same mechanism is postponed).

**Architecture:** no new R code. reproducible (development, ≥ 3.2.1.9085, on r-universe) already
tries, in order: a loaded token → `gargle_oauth_email` → a service-account JSON whose PATH is in
env `GOOGLEDRIVE_AUTH` (or `GARGLE_SERVICE_ACCOUNT`) → anonymous; it never prompts. `agent-up`
gains one generated compose override, `.generated/google-drive.yaml`, that bind-mounts the owner's
key read-only and sets `GOOGLEDRIVE_AUTH`. Docs explain the Google-side setup.

**Tech Stack:** bash (`bin/agent-up`), Docker Compose overrides, the existing launcher test harness
(`tests/launcher/test-agent-up.sh`), GitHub Actions (`.github/workflows/ci.yml`), Markdown.

**Spec:** the design agreed in chat on 2026-11-04 (no separate spec file); its decisions are the
Global Constraints below. Prior step: PR #78 (Drive hosts in the base allowlist; anonymous
`prepInputs()` proven in CI).

## Global Constraints

- Key locations on the HOST (first match wins): `$CFG_ROOT/<project>/google-drive-sa.json`
  (per-project override), else `$CFG_ROOT/.shared/google-drive-sa.json` (all builders).
  `.shared` is a dot-dir so `"$CFG_ROOT"/*/` project globs never see it.
- Container side: bind, `read_only: true`, target `/run/secrets/google-drive-sa.json`; env
  `GOOGLEDRIVE_AUTH=/run/secrets/google-drive-sa.json`. Never the key's CONTENT in an env var,
  a log line or an error message.
- Builders only. `PROFILE=research` never gets it (the research container holds no secrets).
- Per-project opt-out in `project.conf`: `GOOGLE_DRIVE=0`. Any other value or unset = on when a
  key exists. `GOOGLE_DRIVE` is added to the `project.conf` key set agent-up knows.
- `GOOGLEDRIVE_AUTH` and `GARGLE_SERVICE_ACCOUNT` become RESERVED names in `project.env`
  (the reserved-key regex in `check_project_env`, `bin/agent-up` ~line 513).
- Validation (agent-up `up`, before compose): the file must contain
  `"type": "service_account"` (whitespace-tolerant) and a `client_email`; mode must deny group and
  other (`0600` or `0400`) — else `die` naming the file, never its content. If the file's owner uid
  ≠ 1000, `warn` that the agent (uid 1000) may not be able to read it.
- `up` prints one line: `Google Drive: service account <client_email> (<shared|project> key, read-only mount)`.
  The client email is not a secret.
- Off/absent/research → the file holds exactly `services:\n  agent: {}` after its `#` header,
  like `rstudio.yaml` / `ftp.yaml`.
- Plain-English docs, owner's style: short sentences, no jargon left unexplained.

## Review Focus

1. Key file present but a symlink to somewhere else (owner keeps keys in a vault dir): resolve it,
   validate the target, mount the target; a dangling symlink must `die`, not mount nothing silently.
2. Key exists but the project is `research` with an old `.generated/google-drive.yaml` from a
   previous builder life: regenerate to `agent: {}` (never leave a stale mount).
3. Owner removes the key after a previous `up`: next `up` renders `agent: {}` (no dangling bind
   that makes compose fail).
4. A path with spaces in `AGENT_CONTAINERS_CONFIG`: the bind source must be quoted (`yaml_str`).
5. An OAuth *client* secret pasted by mistake (`{"installed": {...}}`): refused with a message
   saying it needs a service-account key, and pointing to the runbook.

Each of these has a render test in Task 1.

---

### Task 1: `write_google_drive` in agent-up + render tests

**Files:**
- Modify: `bin/agent-up` (new `write_google_drive`; `compose_cmd` and `prepare` at ~lines 738-743;
  reserved-key regex ~line 513; the `up` summary output)
- Modify: `tests/launcher/test-agent-up.sh` — add `-f $CFG/.generated/google-drive.yaml` to EVERY
  hard-coded compose `-f` list (lines ~254, ~639, ~979, ~1062, ~1068; grep `restart.yaml`), then the
  new render tests near the rstudio/ftp render tests (~lines 276-700).

**Interfaces:**
- Produces: `google_drive_key <cfgdir>` → prints the resolved key path or nothing;
  `write_google_drive <cfgdir>` → writes `<cfgdir>/.generated/google-drive.yaml`;
  compose file order: `... ftp.yaml google-drive.yaml hostname.yaml restart.yaml`.

- [ ] **Step 1: Write the failing render tests** (use the file's `check`/`refuses` helpers and a
  fixture key `{"type": "service_account", "client_email": "ci@x.iam.gserviceaccount.com", "private_key": "FAKE"}`):
  - `google-drive: no key -> agent: {}`
  - `google-drive: shared key -> ro bind to /run/secrets/google-drive-sa.json + GOOGLEDRIVE_AUTH`
    (grep the yaml for `read_only: true`, the target, and `GOOGLEDRIVE_AUTH: /run/secrets/google-drive-sa.json`;
    and `au config` JSON shows the env var)
  - `google-drive: project key beats shared key` (bind source = the project file)
  - `google-drive: GOOGLE_DRIVE=0 -> agent: {}`
  - `google-drive: research profile -> agent: {}` (even with a shared key; Review Focus 2)
  - `google-drive: key removed after up -> agent: {}` (Review Focus 3)
  - `google-drive: symlinked key -> target mounted; dangling symlink refused` (Review Focus 1)
  - `google-drive: config root with a space -> source quoted` (Review Focus 4)
  - refuses `google-drive: OAuth client JSON` matching `service-account key` (Review Focus 5)
  - refuses `google-drive: mode 0644` matching `chmod 600`
  - refuses `project.env defines GOOGLEDRIVE_AUTH` matching `reserved`
  - `up prints the service-account email, never private_key` (grep output for the email; `! grep FAKE`)

- [ ] **Step 2: Run, verify they fail**
  Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E 'google-drive|GOOGLEDRIVE' `
  Expected: the new checks FAIL (no google-drive.yaml yet).

- [ ] **Step 3: Implement** `google_drive_key` and `write_google_drive` following `write_ftp`'s
  shape (mkdir/chmod 700 `.generated`, header comment `# GENERATED by agent-up from the Google Drive
  service-account key (docs/runbooks/google-drive-access.md). Do not edit.`, `bind_yaml` for the
  mount, `yaml_str` for paths). Validation per Global Constraints; resolve symlinks with
  `readlink -f`. Add to `compose_cmd` and `prepare`; add `GOOGLEDRIVE_AUTH|GARGLE_SERVICE_ACCOUNT`
  to the reserved regex; add the summary line to `up`.

- [ ] **Step 4: Run, verify they pass, and the whole render suite still passes**
  Run: `bash tests/launcher/test-agent-up.sh 2>&1 | tail -5` (no `TEMPLATE_IMAGE`: render-only)
  Expected: `0 failed`. Also `shellcheck -S warning bin/agent-up tests/launcher/test-agent-up.sh`: clean.

- [ ] **Step 5: Commit** `feat(agent-up): mount a read-only Google Drive service-account key (GOOGLEDRIVE_AUTH)`

### Task 2: in-container check + optional real-Drive CI job

**Files:**
- Modify: `tests/launcher/test-agent-up.sh` (behavioural section, next to the Drive `resolves` checks ~line 1166)
- Modify: `.github/workflows/ci.yml` (acceptance step ~line 520)
- Modify: `tests/acceptance/minimal-project/global.R`

**Interfaces:**
- Consumes: Task 1's mount and env var.
- Produces: CI secret names `GDRIVE_SA_KEY` (the key JSON) and repo variable `GDRIVE_PRIVATE_TEST_URL`
  (a Drive file shared ONLY with that service account). Both optional.

- [ ] **Step 1: Behavioural checks** (fixture key placed in the test's config root before `up`):
  `GOOGLEDRIVE_AUTH is set in the container` (`docker exec -u agent "$CID" printenv GOOGLEDRIVE_AUTH`
  = `/run/secrets/google-drive-sa.json`); `the key is readable by agent` (`test -r`);
  `the key is read-only` (`! docker exec -u agent "$CID" sh -c 'echo x >> /run/secrets/google-drive-sa.json'`).
- [ ] **Step 2: Acceptance, private rung (skipped when the secret is absent):** in ci.yml, if
  `secrets.GDRIVE_SA_KEY != ''`, write it to a `mktemp` file (mode 600, uid 1000), bind it read-only
  to `/run/secrets/google-drive-sa.json` in the `acc` container and pass `-e GOOGLEDRIVE_AUTH=...`
  and `-e GDRIVE_PRIVATE_TEST_URL`. In global.R, after the anonymous block: if
  `nzchar(Sys.getenv("GDRIVE_PRIVATE_TEST_URL"))`, reset `options(reproducible.gdriveNoAuth = FALSE)`,
  `googledrive::drive_deauth()`, `prepInputs(url = <it>, destinationPath = <new tempdir>, fun = NA)`,
  assert ≥ 1 non-empty file, print `Google Drive (service account): OK`; else print
  `Google Drive (service account): SKIPPED (no GDRIVE_PRIVATE_TEST_URL)`.
  Never echo the secret; `::add-mask::` is automatic for secrets but do not `cat` the file.
- [ ] **Step 3: Verify** locally that the launcher behavioural block is syntactically valid
  (`bash -n`) and shellcheck is clean; the CI run is the real verification (Task 3's PR).
- [ ] **Step 4: Commit** `test: Google Drive service-account mount in-container; optional private-file acceptance`

### Task 3: runbook, README

**Files:**
- Create: `docs/runbooks/google-drive-access.md` (owner, containers)
- Modify: `project-template/README.md` (mounts table ~line 590: new row; "Known residual risks"
  ~line 680: Drive bullet; `project.conf` keys: `GOOGLE_DRIVE=0`)
- Modify: `docs/allowlist-requests.md` (nothing new; no edit unless a host is found missing)

- [ ] **Step 1: Runbook** — sections: *What this gives you* (read-only, only shared folders, no
  personal Drive, revocable); *One-time setup in Google Cloud* with a personal Gmail (create a
  project; enable the Google Drive API; IAM → Service accounts → create, no roles; Keys → Add key →
  JSON); *Put the key in place* (`mkdir -p ~/.config/agent-containers/.shared`, move the file to
  `google-drive-sa.json`, `chmod 600`); *Share data with it* (share each folder with the
  `client_email` as **Viewer**, never Editor); *Apply* (`agent-up up <project>` per project, or
  `agent-up update --all`); *Check it works* (R snippet with `prepInputs(url = ..., fun = NA)`);
  *Per-project key / opt-out*; *Rotate or revoke* (delete the key in the console; new key, same
  path, `agent-up up`); *What it does not protect* (anyone holding the key reads those folders;
  agents can read the key). Mark as "not verified" the claim that a service account cannot upload
  (Google gives service accounts no Drive storage), unless verified during this task.
- [ ] **Step 2: Workshop guide — POSTPONED by the owner (2026-11-04).** Do not write it.
- [ ] **Step 3: README** rows per Files above; link the runbook.
- [ ] **Step 4: Commit** `docs: Google Drive service-account runbook`

---

**After all tasks:** whole-branch review (opus) + independent Codex review, then PR. Owner merges.
Owner actions for the optional CI rung: add secret `GDRIVE_SA_KEY` and variable
`GDRIVE_PRIVATE_TEST_URL` (a small file shared only with the service account).
