# Paper Discovery (paper-search-mcp) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the research agent more legal places to find papers by adding the maintained `paper-search-mcp` server to the research image, with its Sci-Hub tool unusable, plus an optional CORE API key the owner sets at install.

**Architecture:** The package is installed by the existing paper-tools installer from a pinned commit and registered as an MCP server only in the research container, with a deny rule for the Sci-Hub tool. `agent-up` passes an optional `CORE_API_KEY` from the research `project.conf`, following the `RESEARCH_CONTACT_EMAIL` pattern.

**Tech Stack:** Python package in the paper-tools venv (uv), Claude Code MCP configuration (`images/base/configure-claude-settings.js`, `agent-init.sh`), bash (`agent-up`).

**Spec:** `docs/specs/2026-11-16-paper-fetcher-design.md`, change A.

## Global Constraints

- Upstream: https://github.com/openags/paper-search-mcp, pinned to one commit SHA (it has no tagged releases), installed as shipped: no patching of its source at build time.
- Sci-Hub stays off: the Sci-Hub download tool is denied by name in the research agent's Claude settings, `use_scihub` is never set, and a smoke test fails if the tool is callable by the agent. Codex in the research container gets the same server only if the same denial can be enforced there; otherwise it is not registered for Codex (say which in the report).
- Its Google Scholar source is left as shipped; nothing is done to get around Scholar refusing automated queries.
- The server is registered in the research container only (the one whose `/etc/firewall/profile` says `PROFILE=research`), never in builders.
- The only settings passed: the Unpaywall (and, if the package has one, OpenAlex) email from `RESEARCH_CONTACT_EMAIL`, and the CORE key when set. No other keys.
- `CORE_API_KEY`: optional line in the research `project.conf`; shape `^[A-Za-z0-9]{16,64}$`; refused in any non-research config; never printed by `agent-up` (`status` and `config` show `set`/`unset`); never written under `/research`.
- The research bot still may not install tools itself; downloads land in the existing `downloads/papers/` layout with `metadata.md`.
- Host scripts use no `jq`/`python`. Lint through Docker as elsewhere. Branch `feat/paper-discovery` from `main`; one PR. This plan does not touch `.github/workflows/`.

## Review Focus

1. The pinned package gains or renames a Sci-Hub tool in a later bump: the smoke test must key on behaviour (any tool whose name or description mentions Sci-Hub is denied), not on one hard-coded name.
2. `RESEARCH_CONTACT_EMAIL` unset: the server still starts; Unpaywall-backed tools fail politely; nothing else breaks.
3. `CORE_API_KEY` set to something with shell or YAML metacharacters: refused before it reaches the compose file; the refusal does not echo the value.
4. The MCP server fails to start (a broken pin): the research container still comes up and the agent is told the tool is unavailable; `agent-init` does not abort.

---

### Task 1: Install and register the server in the research image

**Files:**
- Modify: `images/research/paper-tools/python.txt` (one pinned line), `images/research/paper-tools/README.md` (usage card: what the server is for, that Sci-Hub is off, how downloads must be stored), `images/base/agent-init.sh` and/or `images/base/configure-claude-settings.js` (register for research only; deny rule), `tests/smoke/research.sh`, `tests/smoke/research-offline.sh`
- Possibly modify: `images/base/configure-codex-config.js` (see Global Constraints)

**Interfaces:**
- Produces: in the research container, an MCP server named `paper-search` available to Claude Code; a `permissions.deny` entry for its Sci-Hub tool(s); `/opt/paper-tools/MANIFEST` gains the pinned spec.

- [ ] **Step 1: Read the pinned source before writing anything.** Choose the newest commit on the default branch; record its SHA and date. From that commit's source (not the README alone) write down, in the task report: the console-script or module that starts the server; every tool name it registers; which tools download files and where they write by default; the exact environment variable names it reads (Unpaywall email, OpenAlex email, CORE key, download directory, any proxy setting); every place Sci-Hub appears (tool names, parameters). If the source contains anything that contacts a shadow library without the explicit per-call opt-in, stop and report BLOCKED.
- [ ] **Step 2: Failing smoke tests.** In `tests/smoke/research-offline.sh` (no network): the pinned package imports and its server entry point exists; `claude mcp list` (or the settings file `agent-init` writes: follow how existing smoke tests inspect Claude config, e.g. the plugin checks in `tests/smoke/base.sh`) shows `paper-search` after `agent-init` has run with `/etc/firewall/profile` = `PROFILE=research`, and does NOT show it with the builder profile; the settings contain a deny rule covering every tool whose name matches `/sci.?hub/i` in the server's tool list (enumerate the tools from the installed package, then assert each such tool is denied: Review Focus 1); no environment variable or setting enables Sci-Hub by default. Run the smoke script against the current image: the new assertions FAIL.
- [ ] **Step 3: Implement.** Add the pinned spec to `python.txt` in the form the installer accepts (`name @ git+https://github.com/openags/paper-search-mcp@<sha>`; `install.sh` already handles `pkg @ url` lines; check that `uv pip install` can reach git in the build, and if the build has no `git`, use the commit's tarball URL with a `#sha256=` fragment instead). Register the server for the research profile only, with the environment from Step 1 (`RESEARCH_CONTACT_EMAIL` passed through when set; download directory set so files do not land in a default `./downloads`), and add the deny rule(s). A registration failure logs a warning and continues (Review Focus 4).
- [ ] **Step 4: Verify.** Build the research image locally only if `spades-gis` is already present (`docker build --build-arg BASE_IMAGE=… images/research`); otherwise run the changed scripts' unit-level checks and state that CI's `build-test` is the first full build. Run both research smoke scripts where a local image exists; paste the output. Shellcheck clean.
- [ ] **Step 5: Commit** — `feat(research): paper-search-mcp for discovery, pinned; Sci-Hub tool denied`.

### Task 2: `CORE_API_KEY` in the research config

**Files:**
- Modify: `bin/agent-up` (`init_research` seed comment line `#CORE_API_KEY=`, a `core_key`/`check_core_key` pair beside `contact_email`/`check_contact`, `write_research`, the status variable list near line 1286, `cmd_config`)
- Test: `tests/launcher/test-agent-up.sh` (beside the `RESEARCH_CONTACT_EMAIL` tests: `grep -n RESEARCH_CONTACT_EMAIL tests/launcher/test-agent-up.sh`)

**Interfaces:**
- Consumes: the environment variable name for the CORE key from Task 1 Step 1.
- Produces: with `CORE_API_KEY=<key>` in the research `project.conf`, the research container's environment carries that variable; nothing otherwise.

- [ ] **Step 1: Failing tests**, mirroring each existing `RESEARCH_CONTACT_EMAIL` test: unset → not in the rendered compose; a valid key → present in the research container's environment under the name from Task 1; `CORE_API_KEY` in a builder's `project.conf` → refused (`is for the research container only`); values `abc`, `key with space`, `a"b$c`, a 65-character string → refused, and the refusal's text does not contain the value (Review Focus 3); `agent-up status research` and `agent-up config research` output never contains the key (they print `CORE_API_KEY: set`); stop/down still work with an invalid value (as for the email).
- [ ] **Step 2: Run; expect the new checks to FAIL.**
- [ ] **Step 3: Implement** by following the `RESEARCH_CONTACT_EMAIL` code path line for line.
- [ ] **Step 4: Run the whole file** — 0 FAIL. Shellcheck clean.
- [ ] **Step 5: Commit** — `feat(agent-up): optional CORE_API_KEY for the research container (never printed)`.

### Task 3: Instructions, runbook, spec amendment

**Files:**
- Modify: `project-template/instructions/research.md` (Papers section), `docs/runbooks/` (a "discovery sources" section in the research or new-project runbook), `docs/specs/2026-10-03-agent-containers-design.md` (dated amendment), `docs/agents/update-agent.md` (the new pin joins the update bundle)

- [ ] **Step 1: `research.md`.** In "Finding the legal copy": use the `paper-search` tools (name the search tools from Task 1) across its sources before deciding there is no legal free copy; the Sci-Hub tool is denied and must not be attempted by any other route; the CORE key, when present, goes to CORE's API only and never into a report, a form or a file; files obtained through the server's download tools are stored in the existing per-paper folder layout with `metadata.md`. Leave every other rule as it is. If Task 6 of the fetcher plan has already landed, keep its text and add to it.
- [ ] **Step 2: Runbook** (owner steps, done once at setup): get a free CORE API key (where; that it is optional) and put it on the `CORE_API_KEY=` line; register the host's public IP with BASE (where; that a changed home IP needs re-registering; that it is optional); `agent-up up research`. Say what is skipped when either is absent.
- [ ] **Step 3: Spec amendment** `## Amendment 2026-11-16: the research container may hold a CORE discovery key`: three sentences: what the key is, why it is not in 1Password (nothing behind it but a rate limit; follows the contact-email pattern), that it is the single exception to "no credentials" there.
- [ ] **Step 4: Full check** — both launcher suites, every `tests/ci/test-*.sh`, shellcheck. Record exact counts.
- [ ] **Step 5: Commit** — `docs: discovery sources for the research agent; CORE key and BASE registration at setup`. Do not push; the controller opens the PR after the whole-branch review.

### After merge, with the owner

- [ ] `publish` succeeds with the new research image; `agent-up update research`.
- [ ] In the research container: a search through `paper-search` returns results from at least two sources; an attempt to call the Sci-Hub tool is refused by the permission rule.
- [ ] Owner adds the CORE key and registers with BASE; a CORE-backed and a BASE-backed search return results.
- [ ] Re-run the 2026-11-14 "not obtained" list through discovery: record how many of the 11 closed-access papers now have a legal free copy.
