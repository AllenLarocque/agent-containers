# T3 publish-only + Tailscale access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reach any number of agent containers from the T3 phone/desktop apps without consuming T3
Connect's 3 managed Cloudflare tunnels: notifications through T3's relay (publish-only link), the
connection itself over Tailscale (phone) or localhost (desktop on the host PC).

**Architecture:** `T3_CONNECT` gains a third value, `publish`, which the firewall treats as "t3.codes
only, no tunnel edge". `agent-up` prints the per-project Tailscale Serve command and the app addresses,
waits for the T3 server before minting a pairing token, and gives the shared research container a
persistent general folder.

**Tech Stack:** bash (`bin/agent-up`, `images/base/init-firewall.sh`), docker compose overlays, bash
test scripts (`tests/launcher/test-agent-up.sh` runs locally with stubs; `tests/firewall/*` run in CI).

**Spec:** approved in chat 2026-10-11 (small change, no separate design doc). Trial evidence and the
T3 source research: memory note `pickup-agent-containers-2026-10-10.md` ("Task 1 research DONE",
"Trial progress"). Summary of what the owner approved:
1. `T3_CONNECT=0|1|publish`; `publish` = firewall opens `t3.codes` only (no argotunnel.com / 7844);
   existing `1` configs keep working unchanged.
2. `agent-up up` and `agent-up pair` print the `tailscale serve --bg --https=<port> <T3_PORT>` command
   and the app addresses. Port = `8443 + (T3_PORT − 3774)`, per-project override in project.conf.
   Tailnet host name in ONE shared agent-up settings file; placeholder when unset.
3. `agent-up pair` waits (bounded) for the T3 server instead of failing right after `up`.
4. Research container: `~/agent-research/_general` mounted rw at `/research/_general`, created by
   agent-up, and the default T3 folder for research.
5. README + tests updated. `pair` prints TWO app addresses: `http://localhost:<T3_PORT>` (desktop app on
   the host PC, verified in the trial) and `https://<tailnet-host>:<port>` (phone, Tailscale on).

## Global Constraints

- Agents never merge; one branch, one PR; the owner merges (`merge-gate-human`).
- The machine user cannot push `.github/workflows/**`: CI wiring is a patch the owner applies (Task 1).
- Never enable Tailscale Funnel; every printed `tailscale serve` command is tailnet-only (`--bg --https=`).
- The firewall's existing behaviour for `T3_CONNECT=0` and `=1` must stay byte-identical (CI snapshots).
- Firewall switch files keep the exact-value pattern: anything but an exact known value aborts before any change.
- `agent-up` reads only `~/.config/agent-containers/` (`$CFG_ROOT`) and its seeds, never the project folder.
- stop/down/status never validate config values (existing pattern: only up/config/pair validate).
- Match existing style: comment density and wording of `bin/agent-up`, `check`/`refuses` helpers in tests.
- Run `bash tests/launcher/test-agent-up.sh` after every agent-up change; it must end `LAUNCHER: ALL PASSED`.

## Review Focus

1. An OLD image (before this PR) given `T3_CONNECT=publish` must fail closed with a clear error, not
   open anything; the README must say publish needs an image from the new digests → Task 2 README step.
2. Two projects whose computed Tailscale ports collide (an override equal to another's default) →
   `up`/`pair` refuse with both project names → Task 3 test.
3. `_general` must not be listed or warned about as a "skipped" project folder by `exchange_projects`,
   and must be refused if it is a symlink → Task 5 tests.
4. `pair` against a stopped container must fail fast with the existing "is '<name>' running?" hint, not
   wait the full timeout → Task 4 test.
5. `TAILSCALE_HOST` in the shared file containing junk (spaces, a scheme, a path) → refused, never
   printed into a command → Task 3 test.

---

### Task 1: Firewall `publish` mode

**Files:**
- Modify: `images/base/init-firewall.sh` (header comment ~lines 36-40; switch parse ~84-92; t3.codes ~148-150; status echo ~160-167; verification ~464-468)
- Modify: `tests/firewall/test-firewall.sh` (`EXPECT_T3_CONNECT` handling ~lines 7, 15, 56-60, 130-141)
- Modify: `tests/firewall/test-t3-connect.sh` (MODE)
- Create: `docs/superpowers/plans/2026-10-11-ci-publish-mode.patch` (workflow patch for the owner)

**Interfaces:**
- Produces: switch file `/etc/firewall/t3-connect` may hold exactly `T3_CONNECT=0`, `T3_CONNECT=1` or
  `T3_CONNECT=publish`. Internal var `T3_CONNECT` ∈ {0,1,publish}. Task 2 writes `T3_CONNECT=publish`.

- [ ] **Step 1: Extend the tests.** In `test-firewall.sh`, accept `EXPECT_T3_CONNECT=publish`: assert
  dnsmasq conf has a `server=/t3.codes/` line, there is NO `t3-tunnel` ipset, NO `argotunnel.com` line
  in the dnsmasq conf, and NO `--dport 7844` rule (iptables -S OUTPUT). In `test-t3-connect.sh`, accept
  `MODE=publish`: `t3.codes` (e.g. `relay.t3.codes`) resolves to an A record, and every tunnel-edge
  check behaves exactly as `MODE=off` (edge 7844 rejected here, argotunnel SRV does not resolve).
- [ ] **Step 2: Implement** in `init-firewall.sh`: parse `T3_CONNECT=publish`; error text becomes
  `must hold exactly T3_CONNECT=0, T3_CONNECT=1 or T3_CONNECT=publish`; add `t3.codes` to RAW_DOMAINS
  for `1` AND `publish`; everything tunnel-related (ipset, server=/argotunnel, 7844 rules, SRV probes,
  the "on but missing" verification) stays keyed on exactly `1`; the "off but a 7844 rule is present"
  check applies to `0` and `publish`. Status line for publish:
  `T3 Connect: publish-only (t3.codes allowlisted; no tunnel edge)` (research variant:
  `T3 Connect: publish-only (research: open egress already covers t3.codes)`). Update the header
  comment block to describe the three values.
- [ ] **Step 3: Static checks.** `bash -n images/base/init-firewall.sh tests/firewall/test-firewall.sh tests/firewall/test-t3-connect.sh` → no output.
  Confirm by reading the diff that the `0` and `1` paths emit the same rules as before.
- [ ] **Step 4: Write the CI patch** for the owner: a unified diff against `.github/workflows/ci.yml` adding a
  `fwpub` step modelled on the existing `fwt3` step (~lines 218-240): switch file `T3_CONNECT=publish`,
  run `test-firewall.sh` with `EXPECT_T3_CONNECT=publish`, `test-agent-egress.sh`, and
  `test-t3-connect.sh` with `MODE=publish`. Save to `docs/superpowers/plans/2026-10-11-ci-publish-mode.patch`.
  Verify it applies: `git apply --check docs/superpowers/plans/2026-10-11-ci-publish-mode.patch`.
- [ ] **Step 5: Commit** `feat(firewall): T3_CONNECT=publish opens t3.codes only (no tunnel edge)`.

### Task 2: agent-up `T3_CONNECT=publish`

**Files:**
- Modify: `bin/agent-up` (`check_t3_connect` ~242-247, `write_t3_connect` ~427-450, init conf comments ~96-98 and ~176-177, `cmd_up` message ~608-610)
- Modify: `tests/launcher/test-agent-up.sh` (T3 Connect section ~289-335; render section ~604-616)
- Modify: `project-template/README.md` ("T3 Connect (opt-in)" section)

**Interfaces:**
- Consumes: Task 1's switch-file value `T3_CONNECT=publish`.
- Produces: `t3_connect <cfg>` returns `0|1|publish` (validated); helper `t3_connect_on <cfg>` → true for `1` or `publish`.

- [ ] **Step 1: Failing tests:**
  - `up with T3_CONNECT=publish` succeeds; `.generated/t3-connect` contains exactly `T3_CONNECT=publish`;
    `.generated/t3-connect.yaml` has env `T3_CONNECT: "publish"`, the read-only switch mount, and NO `TUNNEL_EDGE_IP_VERSION`.
  - `up` refuses `T3_CONNECT=Publish`, `T3_CONNECT=2`, `T3_CONNECT=on` with
    `must be 0 \(off\), 1 \(managed tunnel\) or publish \(publish-only\)` (update the existing loop's regex).
  - `up` output for publish contains `T3 Connect: publish-only` and the first-time hint
    `t3 connect link --publish-only`.
  - research profile with `T3_CONNECT=publish` → `up research` succeeds.
  - render (CI, real compose): publish = T3_CONNECT=0 render plus the switch mount and env `T3_CONNECT=publish` only.
- [ ] **Step 2: Run** `bash tests/launcher/test-agent-up.sh` → the new checks FAIL.
- [ ] **Step 3: Implement.** Validation accepts `0|1|publish`; the switch file is written for `1` and
  `publish` (any other value: no file, as now). `TUNNEL_EDGE_IP_VERSION` only for `1`. `cmd_up` prints
  for publish: `agent-up: T3 Connect: publish-only (first time: agent-up shell $name; t3 connect --headless; t3 connect link --publish-only; t3 connect publish; then agent-up up $name)`.
  The init template comment becomes: `# T3 Connect: 0 = off, 1 = managed tunnel (T3's relay + Cloudflare; at most 3 per T3 account), publish = notifications only, connect over Tailscale (README "Phone and desktop apps").`
- [ ] **Step 4: README.** In "T3 Connect (opt-in)": the three values; publish-only is the recommended
  mode (no tunnel limit, no public hostname); **an image older than this PR refuses
  `T3_CONNECT=publish` and the container fails closed — pin a digest from digests.md after the PR's
  publish run first; until then `T3_CONNECT=1` plus a publish-only link also works**; migrating a
  project from a managed tunnel: `t3 connect unlink` (5 s timeout warning harmless; "Revoked the
  relay-side environment record" = slot freed; if the app still counts it: Account → T3 Connect →
  Deregister), `t3 connect link --publish-only`, `t3 connect publish`, `agent-up up`. The app shows
  the environment as "activity publishing only"; it errors until a direct route is added (Task 3 section).
- [ ] **Step 5: Run** the launcher tests → `LAUNCHER: ALL PASSED`.
- [ ] **Step 6: Commit** `feat(agent-up): T3_CONNECT=publish (publish-only link, no managed tunnel)`.

### Task 3: Tailscale addresses printed by `up` and `pair`

**Files:**
- Modify: `bin/agent-up` (new helpers near `t3_host` ~373; `cmd_up` ~606-613; `cmd_pair` ~635-648; `check_project_env` reserved list ~381; the `unset` list ~697-699; `usage`)
- Modify: `tests/launcher/test-agent-up.sh` (pair section ~272-286; new section)
- Modify: `project-template/README.md` (replace the "Phone ... without T3 Connect" bullet in "T3 Code" with a new section "Phone and desktop apps (Tailscale)")

**Interfaces:**
- Produces:
  - shared settings file `$CFG_ROOT/agent-up.conf` (KEY=VALUE, read with `conf_get`), key
    `TAILSCALE_HOST` (e.g. `<machine>.<tailnet>.ts.net`). Missing file/key = unset.
  - per-project key `TAILSCALE_HTTPS_PORT` in project.conf (optional override).
  - `tailscale_host` → prints the validated host or nothing. Valid = `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$`; anything else dies:
    `TAILSCALE_HOST='…' in $CFG_ROOT/agent-up.conf: must be a bare host name like machine.tailnet.ts.net`.
  - `ts_port <cfg>` → `TAILSCALE_HTTPS_PORT` if set, else `$((8443 + T3_PORT - 3774))`; validated 1-65535 (443 allowed).
  - `check_ts_port <cfg>` → dies if another project's effective `ts_port` equals this one's, naming both projects.
  - `ts_url <cfg>` → `https://<host>` when port is 443, else `https://<host>:<port>`; `<tailnet-host>` placeholder when unset.

- [ ] **Step 1: Failing tests** (T3_PORT=3773 project `demo-proj`, a second project as needed):
  - no agent-up.conf: `pair` prints `  desktop app on this PC: http://localhost:3773` and
    `  phone (Tailscale on):   https://<tailnet-host>:8442`, a line `  pairing code: fakeTok_123`, and
    `set TAILSCALE_HOST in $CFG_ROOT/agent-up.conf` hint; the existing browser-link lines stay.
  - with `TAILSCALE_HOST=box.tail1.ts.net`: phone line `https://box.tail1.ts.net:8442`.
  - with `TAILSCALE_HTTPS_PORT=443`: phone line `https://box.tail1.ts.net` (no `:443`).
  - `up` prints `agent-up: Tailscale (once, Windows PowerShell): tailscale serve --bg --https=8442 3773`.
  - a project with T3_PORT=3775 and no override → `--https=8444 3775`.
  - collision: second project's `TAILSCALE_HTTPS_PORT` equal to first's computed port →
    `refuses ... 'TAILSCALE_HTTPS_PORT.*also used by demo-proj'` for `up` and `pair`.
  - junk host (`https://x.ts.net`, `a b`, `x.ts.net/p`) → `refuses` with `TAILSCALE_HOST=`; the junk is never in a `tailscale serve` line.
  - `TAILSCALE_HTTPS_PORT=0` / `70000` / `abc` → refused by `up`.
  - `stop`/`down`/`status` work with a junk TAILSCALE_HTTPS_PORT.
  - `project.env` defining `TAILSCALE_HTTPS_PORT=op://x/y` is refused as a reserved key.
- [ ] **Step 2: Run** → new checks FAIL.
- [ ] **Step 3: Implement** the helpers and output. `up` validates (`check_ts_port` + host) before compose;
  `pair` validates too. Add `TAILSCALE_HTTPS_PORT` to `check_project_env`'s reserved pattern and the
  final `unset` list (also `TAILSCALE_HOST`).
- [ ] **Step 4: README section "Phone and desktop apps (Tailscale)":** one-time `agent-up.conf`
  (`TAILSCALE_HOST=<machine>.<tailnet>.ts.net`, from `tailscale status` / the admin console); per
  project: run the printed `tailscale serve` command in PowerShell once (first time ever: enable Serve
  + HTTPS certificates; `tailscale serve status` must say `(tailnet only)`; **never Funnel**); `agent-up pair`; in
  each app: Add environment → host + pairing code (desktop: the localhost address; phone: the ts.net
  address, Tailscale on). Retiring a project: `tailscale serve --https=<port> off`. Note the mapping
  survives reboots (owner's existing 443/8443 mappings persisted). Existing projects created before
  the formula keep their mapping via `TAILSCALE_HTTPS_PORT` (e.g. the bio project: 443).
- [ ] **Step 5: Run** the launcher tests → `LAUNCHER: ALL PASSED`.
- [ ] **Step 6: Commit** `feat(agent-up): print the Tailscale Serve command and app addresses`.

### Task 4: `pair` waits for the T3 server

**Files:**
- Modify: `bin/agent-up` (`cmd_pair`)
- Modify: `tests/launcher/test-agent-up.sh` (docker stub ~45-53; pair section)
- Modify: `project-template/README.md` (T3 Code section: drop any "wait before pairing" advice if present)

**Interfaces:**
- Produces: env `AGENT_UP_PAIR_WAIT` (seconds, default 60; tests set it small). `pair` polls every 2 s.

- [ ] **Step 1: Failing tests.** Teach the docker stub two knobs via env files in `$T`: `PAIR_FAILS=N`
  (the first N `agent-t3 pair` calls exit 1) and `RUNNING=0` (`docker inspect -f {{.State.Running}} …` prints `false`; default prints `true`). Tests:
  - `PAIR_FAILS=2`, `AGENT_UP_PAIR_WAIT=10` → `pair` succeeds, prints the token, and logs 3 pair attempts.
  - `PAIR_FAILS=99`, `AGENT_UP_PAIR_WAIT=3` → refuses with `T3 server in 'demo-proj' did not answer within 3 s`.
  - `RUNNING=0` → refuses at once with `is 'demo-proj' running\? agent-up status demo-proj` and makes no `agent-t3 pair` call.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** In `cmd_pair`: `docker inspect -f '{{.State.Running}}' "$name-agent-1"`
  must print `true`, else the existing die message. Then loop `agent-t3 pair` until it succeeds or
  `AGENT_UP_PAIR_WAIT` elapses (validate it is a positive integer; else default 60), printing
  `agent-up: waiting for the T3 server in '$name'...` once.
- [ ] **Step 4: Run** the launcher tests → `LAUNCHER: ALL PASSED`.
- [ ] **Step 5: Commit** `feat(agent-up): pair waits for the T3 server to come up`.

### Task 5: Research `/research/_general`

**Files:**
- Modify: `bin/agent-up` (`make_exchange` ~295-309, `exchange_projects` ~282-294, `write_research` research branch ~468-484, `cmd_shell` ~629-634, `init_research` final message)
- Modify: `project-template/instructions/research.md` ("Where things are")
- Modify: `tests/launcher/test-agent-up.sh` (research section ~430-567; render section)
- Modify: `project-template/README.md` ("Research container")

**Interfaces:**
- Produces: host dir `$RESEARCH_DIR/_general` (real dir, created by `up research`); container mount
  `/research/_general` rw; research `.generated/research.yaml` also sets `working_dir: /research/_general`
  and env `T3_PROJECT_DIR: /research/_general` (overrides the owner's compose; no compose.yaml edit needed).

- [ ] **Step 1: Failing tests:**
  - `up research` creates `$H/agent-research/_general` and prints `agent-up: created …/_general` the first time.
  - `.generated/research.yaml` binds `<rd>/_general` → `/research/_general` without `read_only`, and sets
    `T3_PROJECT_DIR: /research/_general` and `working_dir: /research/_general`.
  - `_general` as a symlink → `up research` refuses with `_general is a symlink`.
  - `up research` output never contains `skipped '.*_general'`; the `research projects:` line does not list `_general`.
  - a builder's RESEARCH=1 render is unchanged (no `_general` mount).
  - `shell research` execs with `-w /research/_general`.
  - render (CI): research mounts include target `/research/_general`, env `T3_PROJECT_DIR=/research/_general`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `exchange_projects` silently skips `_general`. Creation reuses the
  symlink-refusing pattern of `exchange_dirs`.
- [ ] **Step 4: Instructions + README.** research.md: `/research/_general/` — general research not tied
  to a project (persists, visible to the owner at `~/agent-research/_general`); "Nothing else under
  `/research` persists" stays true otherwise. README "Research container": the persistence table from
  the chat (exchange folders, `_general`, `~/.t3` incl. scratch threads; everything else wiped on every
  `agent-up up`) and: create T3 projects in research only under `/research/_general` or
  `/research/<project>`; a T3 project at any other path breaks after the next `up` (remove it in T3:
  right-click → Remove).
- [ ] **Step 5: Run** the launcher tests → `LAUNCHER: ALL PASSED`.
- [ ] **Step 6: Commit** `feat(research): persistent /research/_general as the default T3 folder`.

### After all tasks (controller, not a subagent task)

- Push the branch, open ONE PR (body: summary, the CI patch the owner must apply to the branch, the
  post-merge steps: new digests → pin → per-project `T3_CONNECT=publish`). Link the PR via `link_pull_request`.
- Post-merge with the owner: pair bio (T3_PORT 3773, `TAILSCALE_HTTPS_PORT=443`), cimp (3774 → 8443),
  agent-containers-dev (3776 → 8445); remove research's duplicate `T3_CONNECT` line.
