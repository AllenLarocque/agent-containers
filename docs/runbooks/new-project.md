# Runbook: set up a new SpaDES project

**Human procedure.** The agent must never perform these steps (they involve host secrets and repo
permissions).

**Prerequisites on the host:**
- Linux or WSL2 (GNU coreutils);
- Docker;
- the 1Password CLI (`op`);
- the GitHub CLI (`gh`), logged in with `gh auth login` (any account that can read the public
  repo): `agent-up update` and `agent-new` use it to verify the image they pin;
- a clone of this repo at `~/GitHub/agent-containers`. The commands below assume
  `~/GitHub/agent-containers/bin` is on your `PATH`; otherwise type the full path.

`<project>` is the project folder name, lowercased to `[a-z0-9_-]`. The container is
`<project>-agent-1`.

**Automated:** `agent-new project <folder>` performs steps 1–2, 4, 7 and 8 below and runs the 1Password sequence of step 3 with you (it pauses for `op signin` only when you are not signed in). Steps 5 (the project's allowlist) and 6 (the `spades.ai` clone) stay yours — the script only reminds you at the end, and `agent-up up` refuses to run without the clone. The research container is started without the token; if it has no config yet the script warns and tells you to run `agent-up init --profile research` then `agent-up up research`. The steps below remain the reference (and the fallback when the script can't).

`agent-new` needs the machine user's GitHub login once, in the shared `~/.config/agent-containers/agent-up.conf` (next to `TAILSCALE_HOST`), or `--machine-user <user>` on each run:

```
MACHINE_USER=<machine-user-login>
```

## Steps

1. **Create the project's config** (outside the project folder):

   ```bash
   agent-up init ~/GitHub/<project>                # GIS / fire projects (spades-gis)
   agent-up init ~/GitHub/<project> --image bio    # amplicon projects (spades-bio; adds the bio domains)
   ```

   - The project folder must be an agent-only clone, never your agent-containers clone or a
     folder containing `~/.config/agent-containers`: `agent-up up` refuses those.
   - This creates `~/.config/agent-containers/<project>/` (`compose.yaml`, `project.env`,
     `allowlist`, `project.conf`).
   - It also creates `~/agent-memory` the first time.
   - It adds `.github/CODEOWNERS`, `.github/workflows/gitleaks.yml` and `.gitignore` to the
     project wherever they're missing.

2. **Set the image digest.** Run `agent-up update <project>`. It replaces the placeholder
   (`REPLACE_WITH_DIGEST`) in `~/.config/agent-containers/<project>/compose.yaml` with the digest
   `latest` points to, but only after checking that `publish` built it on `main`. If `publish` has
   not finished yet, it says so and changes nothing: run it again after the run is green.
   `agent-up up` refuses to run until it's a real digest.
3. **Run the vault runbook** (when storing the GitHub token with `read -rs`, run that line ON ITS OWN: pasted together with the next line, `read` swallows that line as the "token"): [1password-project-vault.md](1password-project-vault.md) (vault,
   service account, host token). `project.env` already names the vault `agent-<project>`.
4. **Machine user, "set up" half (before `agent-up up`):**
   [machine-user-and-rulesets.md](machine-user-and-rulesets.md) steps 2 to 4.
   - In the project repo: replace `@OWNER` in `.github/CODEOWNERS`, then commit it together with
     `.github/workflows/gitleaks.yml` and `.gitignore`.
   - Push the project's `.github/` changes first and let CI run once: GitHub only offers a check for the ruleset after it has run. Then add `gitleaks` (and `build-test`, once the project has CI) as required checks, and re-run the gate verification (step 8) so the checks are covered.
5. **Project domains:** add the extra domains the project needs to
   `~/.config/agent-containers/<project>/allowlist`.
   - One domain per line; a domain also matches its subdomains.
   - Anything not listed is blocked and doesn't even resolve.
   - Only ports 22, 80 and 443 are open, and only to listed hosts. **SSH to your own servers
     (cloud VM, NAS) needs their domain here too.**
   - Plain-FTP uploads (ENA Webin, NCBI SRA) are a separate opt-in: `FTP_HOSTS` in `project.conf`
     opens tcp 21 to those hosts only (bio projects get it commented out). See
     `project-template/README.md` "FTP uploads (sequence archives)".
6. **Clone `spades.ai`** to `~/GitHub/spades.ai`, or point `SPADES_AI_DIR` in
   `~/.config/agent-containers/<project>/project.conf` at your clone. `agent-up up` stops if it's
   missing.
7. **Check what will run**, then start it:

   ```bash
   agent-up config <project>     # the fully rendered sandbox: mounts, volumes, environment
   agent-up up <project>
   ```

   With no `OP_SERVICE_ACCOUNT_TOKEN` set, `agent-up up` checks your 1Password sign-in and reads
   **this** project's token itself (see the vault runbook).
8. **Machine user, "verify the gate" (after `agent-up up`):** run
   [machine-user-and-rulesets.md](machine-user-and-rulesets.md) step 6 inside the container
   (`agent-up shell <project>`). Don't start real work until it passes.
9. **Attach and work:**
   - VS Code: **Dev Containers: Attach to Running Container…** → `<project>-agent-1`, then open
     `/workspace`.
   - Or use `agent-up shell <project>`.
   - Or **T3 Code** in your browser: `agent-up pair <project>` prints a one-time link
     (`http://localhost:<T3_PORT>/…`, valid 10 minutes). Pairing persists across `agent-up up`.
   - Or **RStudio Server** in your browser (opt-in: `RSTUDIO=1` in `project.conf`, then
     `agent-up up <project>`): `agent-up rstudio <project>` prints the address, user and password.
     See `project-template/README.md` "RStudio Server (opt-in)".

   The first time, run `claude` in the container once and log in (subscription). For Codex
   (ChatGPT plan), run `codex login --device-auth` once and open the printed link on the host.
   Both logins persist across `agent-up up`. Set up R with `setupProject` as usual.

Later changes: edit the files in `~/.config/agent-containers/<project>/`, then `agent-up up <project>`.
Nothing in the project folder configures the container.

**Web research for this project** (the shared research container, open internet, no secrets): set
`RESEARCH=1` in the project's `project.conf`, `agent-up up <project>`, then `agent-up up research`.
First time ever: `agent-up init --profile research`. See
[project-template/README.md "Research container"](../../project-template/README.md#research-container).

**Fetching papers the research bot cannot get** (a real browser, your library login if you set one):
see [paper-fetcher.md](paper-fetcher.md). Run `agent-up up research` once after adding a project,
then `agent-up up fetcher`.

## Discovery sources for the research agent

Owner steps, done once at setup. The research agent never does them. The research container has a
`paper-search` server (Claude Code only) that searches many open sources for papers. It works without
any of the steps below. Each step adds one source.

1. **CORE key (optional).** CORE is an open-access aggregator. Without a key its searches are
   rate-limited or refused. To get a free key, go to <https://core.ac.uk/services/api>, register with
   your email address and wait for the key by email. Put it on the `CORE_API_KEY=` line of
   `~/.config/agent-containers/research/project.conf` (the seed has it commented as `#CORE_API_KEY=`;
   remove the `#`). It is 16 to 64 letters and digits, with no quotes. `agent-up status research` and
   `agent-up config research` show only `set` or `unset`, never the value. Builders refuse the line.
2. **BASE registration (optional).** BASE (Bielefeld Academic Search Engine) lets only registered
   callers use its API, so `search_base` returns nothing until BASE knows your public IP address. Ask
   BASE for registration through the contact details on base-search.net, giving your public IP
   address (look it up from the host, not from inside the container) and saying it is for
   non-commercial research use. If your home IP address changes, register the new one.
3. **Apply.** Run `agent-up up research`. The key takes effect at the next `up`.

Skipped steps: no CORE key means CORE searches may be refused or slow; no BASE registration means
`search_base` returns no results. The agent then uses the other sources. The contact alias
(`RESEARCH_CONTACT_EMAIL`, see the README) is what Unpaywall and OpenAlex lookups need.
