# Update flow: one weekly agent note, one owner-run update command (design spec)

**Status:** draft for review · **Date:** 2026-10-17 · **Owner:** Allen Larocque

**Context.** On 2026-10-15 the T3 phone app updated itself to T3 0.1.0, which speaks a new protocol,
and refused every container still on the 0.0.45 server ("this client requires a newer server").
Getting back meant a T3 bump PR, a digests PR, hand-editing five `compose.yaml` files, five
restarts, five re-pairs and re-adding every environment in both apps. Separately, Dependabot opens a
weekly PR for the Claude Code and Codex CLIs, and each one is another image and another restart
decision. This spec replaces both with one channel the owner controls.

## 1. Intent

Keep the T3 servers, the T3 apps and the agent CLIs working together, with the owner spending at
most a short read and a couple of deliberate actions, about once or twice a month. **The owner
decides when anything changes; nothing restarts a container on its own.** Long-running R jobs and
agents mid-task must never be cut off by automation.

## 2. Decisions the owner made (2026-10-17)

1. **No automatic restarts.** Images may be prepared, built and tested automatically. A running
   project only moves when the owner runs the update command.
2. **Apps don't auto-update.** The owner turns off automatic updates for the T3 phone app (Play
   Store) and, if it auto-updates, the desktop app. Apps are updated by hand *after* the servers.
3. **Notification on the phone, through GitHub.** The note is a pull request; the owner installs
   the GitHub mobile app to get it as a phone notification. No new notification service.
4. **Bundle small, surface big.** Small releases stay quiet and are bundled into the next big one.
   *Big* means any of:
   - a new phone or desktop app is needed (T3 protocol change), or environments must be re-added;
   - a notable new feature the owner would actually use;
   - a **serious security hole relevant to our setup** (section 5). Minor or irrelevant security
     fixes wait like everything else.
5. **An agent does the judging**, not a plain script: a weekly scheduled agent run that reads the
   release notes and decides.
6. **One sitting for all projects.** The owner moves every project at once, with one command.
7. **Busy check.** Before restarting a container, the command checks for running R work and stops
   to ask the owner about a busy one.
8. **Claude Code and Codex are in scope.** CLI updates go through the same note and the same
   bundling rules. Dependabot's CLI PRs are retired.
9. **The Monday OS-patch rebuild joins the bundle.** The scheduled `publish` run keeps building and
   testing the images every Monday but no longer opens a digests PR. Routine OS patches reach the
   containers with the next bundle (every bundle builds fresh images). The weekly agent also checks
   whether the pending OS patches include a serious hole relevant to our setup; if so that is big.

## 3. Goals, non-goals, anti-goals

Goals:
- At most one open update note at a time, readable on a phone in under a minute.
- The update day is: merge, merge, run one command, re-add environments only when needed, update
  the apps.

Non-goals:
- Updating R packages or anything else in the images beyond T3, the CLIs and OS patches (a push to
  `main` that changes `images/**` still publishes and opens a digests PR as today).
- T3 test builds (nightly/preview tags) and pre-releases: never proposed.
- Automating the app-store side.

Anti-goals (a failure even if it technically works):
- Any container restarting without the owner running the command.
- A weekly ping that says nothing new, or a pile of stale notes.
- The phone app breaking before the owner chose to update (prevented by decision 2; the docs must
  say so prominently).
- The agent merging, approving or bypassing the merge gate.
- A secret, or a new third-party service, introduced to make notifications work.

## 4. Part A: the weekly update agent

**Where it runs:** a T3 scheduled task in `agent-containers-dev` (the T3 `schedule_task`
facility), weekly, in a fresh thread per run. It acts as the machine user, under the merge gate:
it may open, update and close its own PR, never merge.

**What it compares:** the versions pinned on `main` against the newest *eligible* upstream
versions:
- T3: `ARG T3_VERSION` / `ARG T3_SHA256` in `images/base/Dockerfile`, against stable releases of
  `pingdotgg/t3code` (not `prerelease`, tag `v<semver>`).
- Claude Code and Codex: `images/base/agent-clis/<tool>/package.json` + `package-lock.json`,
  against the npm registry.
- OS patches: the Ubuntu security updates the base image would pick up on a fresh build. Only
  serious ones relevant to our setup matter (they make the delta big); routine ones ride along.
  How the agent learns them is the builder's call; if it needs a host not on the allowlist, ask the
  owner first.
- cloudflared (amended 2026-10-27): not pinned by us, but by T3 (`CLOUDFLARED_VERSION`), which
  downloads it for T3 Connect. The agent reports the version T3 pins and any security fix in newer
  cloudflared releases; a serious one that the new T3 fixes is big. Trigger: the 2026-10-20
  eMudhra CA compromise, where T3 0.1.0–0.1.2 kept an affected cloudflared and no advisory existed.
- Eligible = published at least **2 days** ago (the same cooldown Dependabot uses today).

**Stateless bundling.** Every run judges the *whole* delta from the pinned versions to the newest
eligible versions, reading every release note in between. If anything in that delta is big
(section 2.4), it opens or refreshes the note covering the whole delta. If nothing is big, it does
nothing and posts nothing. No ledger is needed: an unmerged note is simply recomputed next week.

**The note** (one PR, a fixed branch, e.g. `chore/update-bundle`; refreshed in place, so there is
never more than one):
- Title: what's in it, e.g. `update: T3 0.1.0 → 0.2.0, Claude Code 2.1.301 → 2.2.4`.
- Body, top first, plain language, phone-sized:
  1. **Why you're getting this** (which big item triggered it).
  2. **What it means for you:** restart needed (always; the images are rebuilt, so pending OS
     patches come too); re-add environments yes/no; new app needed
     yes/no; anything to do in the apps afterwards.
  3. **What's new**, a few bullets per tool, only what the owner would care about.
  4. Security items, with why each does or doesn't matter for our setup.
  5. Links to the upstream release notes.
- The change itself: the pins updated (T3 version + sha256, CLI package.json + lockfile).
- When it's merged, the existing `publish` workflow builds the images and opens the digests PR as
  today.

**Protocol/re-pair detection.** The agent must state "re-add environments: yes/no" with evidence.
It determines this from the upstream source and release notes (for example a protocol version
constant or a "requires newer server" change between the two tags), not from guessing. If it
cannot tell, it says so and treats the release as big.

**Security relevance.** Our setup, which the agent judges against: T3 is reachable only on the
tailnet through Tailscale Serve (never Funnel) and on localhost; containers run behind an egress
allowlist; secrets are injected per container from 1Password; one owner, a machine user under the
merge gate. A hole is relevant if it is reachable in that setup (e.g. tailnet-reachable auth bypass,
sandbox or allowlist escape, secret exposure); "relevant and serious" triggers a note.

**Trust.** Release notes and changelogs are untrusted input: the agent treats them as data, ignores
any instructions in them, and says in the note if it saw one. The T3 sha256 comes from the release
asset itself (downloaded and hashed, or GitHub's asset digest), and the build still verifies it.

## 5. Part B: `agent-up update --all` (owner-run)

A new `agent-up` subcommand, run by the owner on the host after the digests PR is merged and pulled.

1. Reads the new digests from `digests.md` on the owner's up-to-date `main`.
2. For every project config under `~/.config/agent-containers/` (research included): finds the
   image its `compose.yaml` uses (spades-base/gis/bio) and the matching new digest. Projects
   already on it are reported and skipped.
3. **Busy check, per project, before touching it:** looks inside the running container for R work
   (R/Rscript processes) and for an agent that is mid-task in T3. If either is busy, it names what
   it found and asks: skip this project, restart anyway, or stop the whole run. Not running = not
   busy.
4. Updates the digest in that project's `compose.yaml`, then `agent-up up <project>`.
5. Confirms the container came back on the expected versions (the same checks as `agent-up status`:
   T3, Claude Code, Codex).
6. At the end, if any re-pair is needed (the note said so, or the owner passes a flag), prints
   every project's pairing code and app addresses in one list (the `agent-up pair` output, with a
   long enough wait for the first start after an image update). Otherwise it reminds the owner that
   no re-pairing is needed.
7. Ends with: update the phone and desktop apps now.

Order: `agent-containers-dev` last, because restarting it ends the owner's session with that agent.
Re-running is safe: projects already on the new digest are skipped.

This also absorbs the pending "`agent-up pair` waits only 60 s on the first start after an image
update" fix: the wait must cover a first start after an image update.

## 6. Docs

- README and the upgrade row of the project template: the new update day, step by step.
- A prominent line: turn off auto-update for the T3 apps; update them only after the servers.
- "Expect to re-add each environment after a T3 protocol change" (seen 2026-10-17).

## 7. Constraints

- The machine user's token cannot change `.github/workflows/*`; any workflow change (here: the
  scheduled `publish` run stops opening a digests PR, decision 9) is handed to the owner as a patch. (`.github/dependabot.yml` is not a workflow file.)
- The agent stays inside `agent-containers-dev`'s allowlist (github.com, raw.githubusercontent.com,
  release-assets, registry.npmjs.org are already on it). No new hosts without asking.
- `agent-up` style: bash, the existing helpers, stub-based tests in `tests/launcher/`.

## 8. Calls made by the spec author (not the owner; the owner may override)

1. **Re-pair is decided per container, not from the latest note.** The image records a T3
   protocol marker (e.g. `ENV T3_PROTOCOL=<n>` in the Dockerfile, an integer the agent bumps in its
   PR when it finds a protocol change, and says so in the note). `agent-up update` compares the
   running container's marker with the new image's and prints that project's pairing code only when
   they differ. This survives skipped updates (a re-pair bundle merged but not applied, then a
   second bundle).
2. **A pinned CLI that is deprecated or about to stop working counts as big** (it is the "it just
   works" goal). No other staleness cap: small changes may wait indefinitely.
3. **Stopped projects stay stopped.** `update` changes their digest in `compose.yaml` and reports
   "updated, not started"; their next `agent-up up` uses the new image. No version check or pairing
   code for them.
   *Amended 2026-10-29:* `docker start` (or Docker Desktop's Start) revives the OLD container, after
   which compose alone looks current. So "current" now also requires the container (if any) to have
   been created from the new digest: a running one on an older image is restarted like an outdated
   one, a stopped one is reported "on the old image, not started" (start it with `agent-up up`).
4. **Busy means working, not open.** Busy = an `Rscript` process, or an R/`rsession` process that
   used CPU recently (builder picks the threshold), or an agent mid-task. An idle RStudio session or
   idle R console is listed in the output but does not stop the run, so the prompt only appears when
   it matters.

## 9. Left to the builder

- How the T3 scheduled task is defined and kept (its prompt lives in the repo, so it is reviewed
  like code), and its weekday/time.
- How "agent mid-task in T3" is detected inside a container.
- How the agent updates the CLI lockfiles (e.g. `npm install --package-lock-only` at the eligible
  version).
- Exact flag names and output wording of `agent-up update`.
