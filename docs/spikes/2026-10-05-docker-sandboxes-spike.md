# Spike: can Docker Sandboxes (`sbx`) host our SpaDES agents?

**Status: ON HOLD — not adopted (2026-10-06). Work in progress; revisit later.** Only S0 was run.
See the [decision log](#decision-log-2026-10-06) at the end. The stages below are kept so the
spike can be resumed, or adapted to an open-source runtime.
**Date written:** 2026-10-05. **sbx version at writing:** v0.47.0 (proprietary, Docker Inc.).
**Time budget:** about 2–3 h, most of it image builds and the memory test.

## Why this spike

Redesign A (external launcher, config in `~/.config`, attach instead of reopen, agent-only clone)
re-implements by hand what `sbx` ships:
- a microVM per sandbox;
- a host-side egress proxy;
- credential injection, where the token never enters the VM;
- clone mode;
- `sbxenv.yaml` kept outside the workspace;
- "ask the human" network approvals.

Before reworking `feat/phase1`, find out whether `sbx` can carry our *workload*: heavy R, big
files, setupProject, and our images. That workload is the part a generic coding-agent sandbox may
not handle.

Threat model (decided 2026-10-04): builder agents must be protected against **1 accidents** and
**3 credential theft**. Research agents (open internet) must also be protected against **2 prompt
injection** and **4 cross-project contamination**.

## Decision this spike feeds

| Outcome | Then |
|---|---|
| Stages 1–6 pass | Adopt `sbx` as the runtime. Keep our images as templates and our allowlists as per-sandbox policy. Retire compose, the in-container firewall and the launcher. Re-plan Phase 1. |
| Memory (S4) or I/O (S5) fails | Keep our Docker stack. Borrow Claude Code's sandbox credential `mask` for threat 3. |
| Image (S2) or R (S3) fails but is fixable | Size the fix, then decide. |

## Ground rules

- **Use no real credentials with write power.** Proxy injection stops an agent *reading* a token,
  but not *using* it. S6 uses a **read-only fine-grained PAT** for one test repo. Never use your
  own `gh auth token`.
- Use a **throwaway test repo**, not `spades_bioinformatics`.
- Paste each stage's output back into the Claude session. Claude fills in the results table.
- If anything needs a workaround, **stop and discuss it first**.

## How to use this runbook

Every code block is **safe to paste whole**. Its first line is a comment saying **where** to
paste it:

| Label | Where |
|---|---|
| `# WSL` | your WSL (Ubuntu) terminal |
| `# PowerShell` | a Windows PowerShell window |
| `# SANDBOX` | a shell *inside* the sandbox, opened by the block before it |

A block that ends in an interactive command (a sign-in, a prompt, an agent session) has that
command as its **last line**, so it can't swallow the lines after it. Do the interaction, then go
on to the next block.

---

## S0 — Set your variables, check the host (5 min)

```bash
# WSL — check the host
lsb_release -ds; uname -r
ls -l /dev/kvm 2>&1 || true
free -g | head -2; nproc
echo "WSL distro: $WSL_DISTRO_NAME   WSL user: $USER"
```

Note the **distro** and **user** it prints. Then set them **once per PowerShell window** (do this
again in any new window):

```powershell
# PowerShell — EDIT the two values first, then paste
$Distro = "Ubuntu"
$WslUser = "allen"
$Spike = "\\wsl.localhost\$Distro\home\$WslUser\sbx-spike"
$Tar   = "\\wsl.localhost\$Distro\home\$WslUser\spades-gis-spike.tar"
(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform | Select-Object State
```

**Pass:** State is `Enabled`. If not, in an **admin** PowerShell run
`Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All`, then reboot.

## S1 — Install, sign in, hello world (15 min)

```powershell
# PowerShell — install
winget install -h Docker.sbx
```

**Close that PowerShell window and open a new one**, so `sbx` is on the PATH. Re-run the S0
variables block, then:

```powershell
# PowerShell — sign in (opens a browser)
sbx version
sbx login
```

```powershell
# PowerShell — lock the network down by default
sbx policy init deny-all
sbx policy ls
```

```bash
# WSL — scratch git repo
mkdir -p ~/sbx-spike && cd ~/sbx-spike
git init -q && echo hi > README.md && git add . && git commit -qm init && git log --oneline
```

```powershell
# PowerShell — start Claude in a sandbox (interactive, last line)
sbx run --name hello claude $Spike
```

Inside Claude:
- type `/login` and sign in with your subscription;
- then ask: *"run `pwd`, `uname -a`, `cat /etc/os-release`, and `curl -sI https://example.com`"*.

`example.com` should be blocked or raise an approval prompt in `sbx`. **Deny it.** Exit Claude.

```powershell
# PowerShell — what the Claude kit opened by itself
sbx policy ls hello --source kit --type network --wide
```

**Pass:** Claude is signed in, and `example.com` is blocked.
**Record:** the `pwd` (where your folder appears inside), and the kit rules.

## S2 — Our image as the template (30–60 min, mostly the build)

```bash
# WSL — build our images from feat/phase1 (clones agent-containers if you don't have it)
cd ~ && [ -d agent-containers ] || git clone https://github.com/AllenLarocque/agent-containers.git
cd ~/agent-containers && git fetch -q && git switch feat/phase1 && git pull -q
docker buildx build --load -t spades-base:spike images/base
docker build --build-arg BASE_IMAGE=spades-base:spike -t spades-gis:spike images/gis
docker image save spades-gis:spike -o ~/spades-gis-spike.tar
ls -lh ~/spades-gis-spike.tar
cp -r tests/acceptance/minimal-project ~/sbx-spike/
```

```powershell
# PowerShell — load it into sbx and start Claude in it (interactive, last line)
Measure-Command { sbx template load $Tar } | Select-Object TotalSeconds
sbx template ls
sbx run --template spades-gis:spike --name gis claude $Spike
```

Inside Claude, ask: *"run `claude plugin list`, `ls -la ~/.claude`, `R --version`, and
`Rscript -e 'library(terra); print(packageVersion("terra"))'`"*. Then exit.

Our image already has what `sbx` needs: the `agent` user (UID 1000, `/home/agent`), bash, git and
curl. Our firewall does **not** run here, and shouldn't: the `sbx` proxy replaces it.

**Pass:** Claude starts in our image, and R and terra work.
**Record:**
- load time and tar size;
- the plugin list. Our image sets `CLAUDE_CONFIG_DIR`, and `sbx` recreates the agent config, so
  did our plugins survive?

## S3 — setupProject through the proxy (20 min)

```powershell
# PowerShell — allow our R hosts for THIS sandbox only, then open a shell in it
sbx policy allow network --sandbox gis "cloud.r-project.org,packagemanager.posit.co,p3m.dev,rspm-sync.rstudio.com,predictiveecology.r-universe.dev,bioc.r-universe.dev,r2.ropensci.org,bioconductor.org,github.com,codeload.github.com,raw.githubusercontent.com,objects.githubusercontent.com,release-assets.githubusercontent.com"
sbx policy check network --sandbox gis packagemanager.posit.co
sbx exec -it gis bash
```

```bash
# SANDBOX — run the SpaDES acceptance test (starts in your sbx-spike folder)
cd minimal-project && time Rscript global.R
exit
```

**Pass:** `ACCEPTANCE: PASSED`.
**Record:**
- elapsed time (CI took 49 s for 37 packages);
- every host that came up for approval. Each one is a missing allowlist entry, or a sign that R is
  ignoring the proxy.

**If it fails on the proxy:** do **not** set R options or env vars to get around it. Paste the
error.

## S4 — Memory: can one sandbox get ~97 GB, and is it released? (30 min)

```powershell
# PowerShell — fresh sandbox with a 100 GB ceiling
sbx rm --force gis
sbx create --template spades-gis:spike --name mem --memory 100g claude $Spike
sbx inspect mem --json
```

1. **Idle.** Leave it idle for a minute. In Task Manager → Performance → Memory, note "In use",
   and on the Details tab note the sandbox VM process's memory. Is the 100 GB **reserved** already?

```powershell
# PowerShell — open a shell in the sandbox
sbx exec -it mem bash
```

```bash
# SANDBOX — allocate ~80 GB for 60 s (watch Task Manager meanwhile)
free -g
Rscript -e 'x <- numeric(1e10); print(gc()); Sys.sleep(60)'
free -g
exit
```

2. **Load:** did the allocation succeed? What was the peak "In use" in Task Manager?
3. **Release:** after R exits, does "In use" drop back down?
4. **Coexistence:** WSL has its own memory cap, so what's left with both running?

**Pass:**
- The 80 GB allocation succeeds.
- Idle memory isn't permanently reserved, or if it is, you find that acceptable.

**Record:**
- the numbers from steps 1–4;
- whether `free -g` inside shows the 100 GB limit.

## S5 — Large-file I/O through the workspace mount (20 min)

```powershell
# PowerShell — open a shell in the sandbox
sbx exec -it mem bash
```

```bash
# SANDBOX — timings on the mounted workspace
time dd if=/dev/zero of=big.bin bs=1M count=10240 conv=fsync
time cat big.bin > /dev/null
time (mkdir -p many && for i in $(seq 1 20000); do echo $i > many/f$i; done)
time ls -l many | wc -l
rm -rf big.bin many
exit
```

```bash
# WSL — the same timings natively, for comparison
cd ~/sbx-spike
time dd if=/dev/zero of=big.bin bs=1M count=10240 conv=fsync
time cat big.bin > /dev/null
time (mkdir -p many && for i in $(seq 1 20000); do echo $i > many/f$i; done)
time ls -l many | wc -l
rm -rf big.bin many
```

**Pass:** within about 2× of native WSL for the big file, and not pathological for the 20k small
files.
**If it's slow:** we'll discuss trying Linux `sbx` inside WSL for this stage.

## S6 — Credentials: the token never enters the VM (15 min)

On GitHub, create a **fine-grained PAT**: one test repo, **read-only** contents and metadata, and
a 1-day expiry.

```powershell
# PowerShell — store it for this sandbox (prompts for the token, last line)
sbx secret set github --sandbox mem
```

```powershell
# PowerShell — open a shell in the sandbox
sbx exec -it mem bash
```

```bash
# SANDBOX — EDIT the repo name first. Expect a sentinel, never the real token
env | grep -i -E 'token|gh_' || echo "no token env vars"
gh auth status
gh repo view AllenLarocque/REPLACE-test-repo --json name
exit
```

**Pass:**
- `gh repo view` works.
- Only a placeholder such as `proxy-managed` appears, never the `github_pat_...` value.

## S7 — VS Code, clone mode, read-only mount (20 min)

```powershell
# PowerShell — enable SSH to sandboxes, then test it (interactive, last line)
sbx setup ssh
ssh mem.sbx
```

1. **VS Code:**
   - Run *Remote-SSH: Connect to Host…* and enter `mem.sbx`.
   - Open the workspace folder.
   - Do the terminal and R work?

```powershell
# PowerShell — clone mode: the agent works on a private clone (interactive, last line)
sbx create --clone --template spades-gis:spike --name clone claude $Spike
sbx run --name clone
```

2. **Clone mode:** ask Claude to *"add a line to README.md and commit it"*. Then exit, and:

```bash
# WSL — fetch the agent's commit; your working tree should be untouched
cd ~/sbx-spike && git status --short && git fetch sandbox-clone && git log --oneline --all -5
```

3. **Read-only mount (= spades.ai and shared memory):**

```powershell
# PowerShell — EDIT the spades.ai path; mount it read-only as an extra workspace
sbx create --template spades-gis:spike --name ro claude $Spike "\\wsl.localhost\$Distro\home\$WslUser\GitHub\spades.ai:ro"
sbx exec -it ro bash
```

```bash
# SANDBOX — reading should work, writing should fail
RO=$(find / -maxdepth 7 -type d -name spades.ai 2>/dev/null | head -1); echo "mounted at: $RO"
ls "$RO" | head
touch "$RO/WRITE_TEST" && echo "WRITE SUCCEEDED (bad)" || echo "write refused (good)"
exit
```

4. **Optional:** connect T3 Code over SSH to `mem.sbx`. Docker documents this. It needs `make`,
   `g++` and `python3` in the image.

## Clean up

```powershell
# PowerShell — remove everything the spike created
sbx rm --force hello mem clone ro
sbx template rm spades-gis:spike
sbx secret rm github --all-sandboxes
```

Then revoke the spike PAT on GitHub.

---

## Results (filled in from the session)

| Stage | Pass? | Key numbers / notes |
|---|---|---|
| S0 host | | |
| S1 install + hello | | |
| S2 our image as template | | |
| S3 setupProject via proxy | | |
| S4 memory | | |
| S5 large-file I/O | | |
| S6 credential injection | | |
| S7 VS Code / clone / ro mount | | |

**Open questions this spike does not answer, for later:**
- Proprietary licence and Docker-account dependency: acceptable for the team?
- `sbxenv.yaml` is still experimental. Is it stable enough to replace our per-project compose?
- How far does pre-1.0 churn reach: CLI flags, kit schema v3?

---

## Decision log (2026-10-06)

### S0 result (the only stage run)

| Item | Value |
|---|---|
| Windows | 127.8 GB RAM; HypervisorPlatform **Enabled** |
| WSL | Ubuntu **22.04.4** (Linux `sbx` needs 24.04+); kernel 5.15.153.1; WSL sees **117 GB**, 24 CPUs; `/dev/kvm` present |
| Implication | Windows `sbx` runs **beside** WSL and competes for the same RAM, so S4 would need a `.wslconfig` cap. If Linux-in-WSL is ever needed, install Ubuntu-24.04 **side by side** rather than upgrading the working distro. |

### Why sbx is on hold

The user's objection: *"The entire point is to be secure. Trading off one threat vector for a
proprietary lock in with spyware attached is troublesome."*

- **Proprietary:** the binary is free, including for commercial use, but there's no public source,
  so the security boundary can't be audited.
- **Account lock-in:** sign-in to a Docker account is mandatory, even for local sandboxes.
  - Users report re-login every few days, and the browser login breaks headless and scripted use
    (HN, Aug 2026).
  - [sbx-releases#5](https://github.com/docker/sbx-releases/issues/5): "require login, breaking
    air-gapped usage", closed.
- **Telemetry on by default.** For each `sbx` subcommand it records: the command, success or
  failure, duration, and Docker username.
  - It does not record shell commands, sandbox activity, prompts or code.
  - The docs don't say whether arguments (paths, names) are included.
  - Opt out with `SBX_NO_TELEMETRY=1`.
- **Calibration, recorded honestly:** Claude Code is also proprietary and sends data to
  Anthropic. That trust is already chosen. The objection is to adding a *second* vendor at the
  most sensitive layer, the sandbox boundary.

What sbx got right, and is worth reproducing with open tools: the egress proxy outside the box;
credentials injected by the proxy so they never enter the VM; "ask the human" approvals for
blocked hosts; and per-project config kept outside the workspace.

### Open-source routes to watch

| Need | Candidate | Status |
|---|---|---|
| Stronger isolation for our existing compose stack | **gVisor** (`runsc`, Apache-2.0): a one-line Docker runtime change | Mature; not yet checked on WSL2 |
| MicroVMs, especially for research agents | **microsandbox** (Apache-2.0, about 8.6k stars, Linux/KVM and Windows/WHP; secrets never enter the VM) | **Beta**; revisit when stable |
| Token never visible to the agent (threat 3) | Claude Code sandbox credential `mask` inside our container | Uses a dependency we already trust |

### Next

Return to the agent-containers Docker stack: finish the lighter redesign A on `feat/phase1`,
writing the threat model and the builder/research profiles into the spec first.
