# Runbook: set up a new SpaDES project

**Human procedure.** The agent must never perform these steps (they involve host secrets and repo permissions).

Prerequisites on the host: Docker, 1Password CLI (`op`), `pre-commit`, and a clone of this repo (`agent-containers`). `<project>` is the project folder name. It becomes the compose project name (lowercased to `[a-z0-9_-]`) and the container name `<project>-agent-1`.

## Steps

1. **Copy the template** into the project root (note the trailing `/.`, which also copies the hidden `.devcontainer/` and `.pre-commit-config.yaml`):

   ```bash
   cp -r agent-containers/project-template/. <project>/
   ```

   This gives you `compose.yaml`, `project.env`, `allowlist.txt`, `up`, `resolve-secrets`, `check-digest`, `.devcontainer/devcontainer.json`, `.pre-commit-config.yaml`, `.gitignore` and `README.md`.
2. **Set the image digest.** In `compose.yaml`, replace `REPLACE_WITH_DIGEST_FROM_digests.md` with a digest copied from `agent-containers/digests.md` (the `spades-gis` row, unless you have a reason to use another image). Check it: `./check-digest` prints `check-digest: OK`. `./up` refuses to run until this passes. *Why: pinning by digest means the container never changes underneath you.*
3. **Set the project name.** In `project.env`, replace `PROJECTNAME` with the project name so the line reads `GH_TOKEN=op://agent-<project>/github-agent/token`. Do not put real secrets in this file: it holds `op://` references only and is committed.
4. **Run the vault runbook:** [1password-project-vault.md](1password-project-vault.md) (vault, service account, host token).
5. **Machine user, "set up" half (before `./up`):** [machine-user-and-rulesets.md](machine-user-and-rulesets.md) steps 2 to 4 (collaborator, CODEOWNERS, Actions-approval setting OFF on project repos, token stored in the vault from step 4, ruleset). The `build-test` check only becomes selectable in the ruleset after CI has run once on the repo, so if the project repo has no CI yet, create the ruleset without it and add the check after the first CI run.
6. **Fill `allowlist.txt`** with the extra domains the project needs beyond the base list (one per line; a domain also matches its subdomains; `#` comments allowed). Anything not listed is blocked by the container firewall. Edit and `./up` again whenever you add one.
7. **Clone `spades.ai`** to `~/GitHub/spades.ai` on the host, or set `SPADES_AI_DIR` to where it is. `./up` stops if the directory does not exist.
8. **Enable the secret scanner** once per clone: `pre-commit install` (gitleaks).
9. **Start it:** `./up`. It checks the digest, resolves secrets into `~/.config/agent-containers/<project>.env` (mode 600), writes the gitignored `.env` (`PROJECT`, `COMPOSE_PROJECT_NAME`), and (re)creates the container. Never run plain `docker compose up`.
10. **Machine user, "verify the gate" (after `./up`):** run [machine-user-and-rulesets.md](machine-user-and-rulesets.md) step 6 from inside the container (attach as in step 11). Do not start real work until it passes.
11. **Attach and work.** Either `docker exec -it -u agent <project>-agent-1 zsh`, or VS Code → "Reopen in Container" (VS Code needs the token in its environment: see the template `README.md`, "VS Code and `OP_SERVICE_ACCOUNT_TOKEN`"; launching it with `code .` from a shell that has the token works). Inside the container run `claude`, then set the project up as usual, for example:

    ```bash
    Rscript -e 'SpaDES.project::setupProject(...)'
    ```

Update later with `./up` (new digest, edited allowlist, changed secret). The full command table is in the template `README.md`.

## Open caveats: check on your first real project

1. **Container name under VS Code.** Confirm "Reopen in Container" names the container `<project>-agent-1` (`docker ps`). If it is named `<folder>_devcontainer-agent-1` instead, the Dev Containers tooling ignored `COMPOSE_PROJECT_NAME`; use `./up` and then "Attach to Running Container" rather than "Reopen in Container", and stop and decide how to proceed.
2. **Allowlist location may change.** Today `allowlist.txt` lives in the project root, which is the agent-writable workspace (the container sees it read-only, but the agent can edit the same file through the workspace mount; an edit takes effect at the next container start). Keeping it outside the workspace is an open security decision, so this location may change and this runbook will be updated if so. Until then, review any change to `allowlist.txt` in `git diff` before running `./up`.
