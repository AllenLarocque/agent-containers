# Runbook: set up a new SpaDES project

**Human procedure.** The agent must never perform these steps (they involve host secrets and repo
permissions).

**Prerequisites on the host:**
- Docker;
- the 1Password CLI (`op`);
- a clone of this repo at `~/GitHub/agent-containers`. The commands below assume
  `~/GitHub/agent-containers/bin` is on your `PATH`; otherwise type the full path.

`<project>` is the project folder name, lowercased to `[a-z0-9_-]`. The container is
`<project>-agent-1`.

## Steps

1. **Create the project's config** (outside the project folder):

   ```bash
   agent-up init ~/GitHub/<project>                # GIS / fire projects (spades-gis)
   agent-up init ~/GitHub/<project> --image bio    # amplicon projects (spades-bio; adds the bio domains)
   ```

   - This creates `~/.config/agent-containers/<project>/` (`compose.yaml`, `project.env`,
     `allowlist`, `project.conf`).
   - It also creates `~/agent-memory` the first time.
   - It adds `.github/CODEOWNERS`, `.github/workflows/gitleaks.yml` and `.gitignore` to the
     project wherever they're missing.

2. **Set the image digest.** In `~/.config/agent-containers/<project>/compose.yaml`, replace
   `REPLACE_WITH_DIGEST_FROM_digests.md` with the digest from `agent-containers/digests.md` (the
   matching `spades-gis` or `spades-bio` row). `agent-up up` refuses to run until it's a real
   digest.
3. **Run the vault runbook:** [1password-project-vault.md](1password-project-vault.md) (vault,
   service account, host token). `project.env` already names the vault `agent-<project>`.
4. **Machine user, "set up" half (before `agent-up up`):**
   [machine-user-and-rulesets.md](machine-user-and-rulesets.md) steps 2 to 4.
   - In the project repo: replace `@OWNER` in `.github/CODEOWNERS`, then commit it together with
     `.github/workflows/gitleaks.yml` and `.gitignore`.
   - Make **`build-test`** (once CI exists) and **`gitleaks`** required checks in the ruleset.
     They only become selectable after they have run once.
5. **Project domains:** add the extra domains the project needs to
   `~/.config/agent-containers/<project>/allowlist`.
   - One domain per line; a domain also matches its subdomains.
   - Anything not listed is blocked and doesn't even resolve.
   - Only ports 22, 80 and 443 are open, and only to listed hosts. **SSH to your own servers
     (cloud VM, NAS) needs their domain here too.**
6. **Clone `spades.ai`** to `~/GitHub/spades.ai`, or point `SPADES_AI_DIR` in
   `~/.config/agent-containers/<project>/project.conf` at your clone. `agent-up up` stops if it's
   missing.
7. **Check what will run**, then start it:

   ```bash
   agent-up config <project>     # the fully rendered sandbox: mounts, volumes, environment
   agent-up up <project>
   ```

   `agent-up up` needs `OP_SERVICE_ACCOUNT_TOKEN` for **this** project in your shell (see the
   vault runbook).
8. **Machine user, "verify the gate" (after `agent-up up`):** run
   [machine-user-and-rulesets.md](machine-user-and-rulesets.md) step 6 inside the container
   (`agent-up shell <project>`). Don't start real work until it passes.
9. **Attach and work:**
   - VS Code: **Dev Containers: Attach to Running Container…** → `<project>-agent-1`, then open
     `/workspace`.
   - Or use `agent-up shell <project>`.

   Inside the container, run `claude`. Set up R with `setupProject` as usual.

Later changes: edit the files in `~/.config/agent-containers/<project>/`, then `agent-up up <project>`.
Nothing in the project folder configures the container.
