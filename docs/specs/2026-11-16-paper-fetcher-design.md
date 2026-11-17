# Paper fetcher

Date: 2026-11-16. Status: approved by the owner 2026-11-16 ("Otherwise go"), with CORE and BASE set up at install. First of several iterations on the research
bot; a survey of other research-agent tooling comes before the next one (Zotero).

## Intent

The research bot cannot get many papers it has correctly found. In its 2026-11-14 report
(`spades_bioinformatics`, "denoising singletons") 26 papers ended up "not obtained":

| Why | Papers |
|---|---|
| Free to read or open access, but the publisher refused an automated download (HTTP 403) | about 12 |
| Closed access, no free copy found | about 11 |
| A repository copy exists but the repository failed | about 3 |

The bot did not give up early: it tried the publisher and then repositories before recording a
failure. Google Scholar refused it outright (bot check).

The owner wants those papers fetched without doing it by hand, wants to use their university
(alumni) access for the paywalled ones, and does **not** want a bot fetching or browsing on the
host. They prefer maintained, packaged tools over home-built ones where that is safe.

## What the owner said

- "I don't want a bot fetching or browsing on the host." Credentials in a container are acceptable.
- Alumni access: a link beginning `go.openathens.net`, a password via OpenAthens, occasionally a
  Duo second step. It works through a browser only (no VPN). It gets about half of the paywalled
  papers they try; "most are available for free on Google Scholar".
- Ticking an occasional "verify you are human" box: "I'd prefer not to but it would be acceptable."
- Sci-Hub and other shadow libraries stay off. A tool that happens to include a Sci-Hub option is
  not ruled out for that reason; block the option.
- Wants polite slow-downs and timeouts.

## Trial (2026-11-16)

A throwaway container with a real (windowed, not headless) Chromium, no login, one attempt per
paper, 25 s between papers, no stealth plug-ins, no challenge solving. Input: the 13
free-but-blocked papers from that report.

| Publisher | Papers | Result |
|---|---|---|
| Wiley | 6 | 6 saved |
| MDPI | 1 | saved |
| ScienceDirect | 2 | Cloudflare "Verify you are human" |
| Cell Press, ASM, Oxford, Taylor & Francis | 1 each | bot check ("Just a moment…" / challenge page) |

7 of 13 recovered with nothing from the owner. The PDF link was found through the
`citation_pdf_url` meta tag (the tag publishers add for Google Scholar) or a `/doi/pdf/` link, and
downloaded by navigating the same browser to it. Not tested: whether a person ticking the box once
lets later downloads from that publisher through; anything with a login.

The trial script is the starting point for the engine:
`/tmp/claude-1000/-home-allen-GitHub-agent-containers/e8578f05-2ef9-415b-831d-488bac9cfbcb/scratchpad/fetch-spike/spike.mjs`
(scratch; copy what is useful, it is not kept). One trap found: `xvfb-run` hangs as PID 1 in a
container; start `Xvfb` directly.

## Goals

- Papers that are free but refuse scripts are fetched with no action from the owner wherever the
  publisher allows a real browser (Wiley and MDPI today).
- Papers behind a human check or the owner's library login wait in a short queue; one visit by the
  owner to the fetcher's browser clears them. A run never stops because of them.
- The research bot hands over a list and reads the results; it never sees the library session.
- The owner's password is never stored anywhere. Only the browser session is kept.
- The research bot finds more legal copies before asking for a fetch (more discovery sources).

## Non-goals

- Zotero in or out, tagging, semantic search (next iteration, after the survey).
- A writing bot, report generation, Obsidian.
- Fetching anything that is not a paper (data sets keep their own rules).
- Search. The fetcher takes DOIs (or direct paper URLs); finding papers stays with the research bot.

## Anti-goals

- The fetcher solving, clicking through or otherwise defeating a bot check itself. A challenge is
  set aside for the owner.
- Any shadow library, in the fetcher or reachable as a tool by the research bot.
- An AI in the container that holds the session. Nothing there reads a page and decides what to do.
- Hammering: retry loops against a refusing site, parallel downloads from one publisher, or bulk
  volumes through the library login. Publishers watch for this and libraries suspend accounts.
- The library session, or the browser profile, being readable by the research container or any
  builder.

## Approaches considered

1. **Discovery only.** Add a maintained search tool to the research container. More legal sources,
   small change. Does not touch publisher blocks or paywalls.
2. **Discovery plus a separate fetcher container (chosen by the owner, 2026-11-16).** Below.
3. **Give the research bot a browser and the session.** One container, most flexible. Rejected:
   the owner's login, open internet and an AI reading untrusted pages would sit in one place, which
   the main design already calls its riskiest profile.

Fetching on the host (through the owner's own browser or Zotero) was ruled out by the owner.

## Design

### Two changes

**A. Research container: more discovery.** Add `paper-search-mcp`
(https://github.com/openags/paper-search-mcp; MIT, actively maintained, about twenty sources
including CORE, BASE, Semantic Scholar, OpenAIRE) to the research image, pinned like the other
paper tools, wired as an MCP server for the research agent.
- Sci-Hub stays off: its `download_scihub` tool is denied in the agent's settings and `use_scihub`
  is never set. The package itself is used as shipped (no patching of upstream at build time, so
  version bumps stay simple). A smoke test fails if the Sci-Hub tool becomes callable by the agent.
- It needs an email for Unpaywall; reuse `RESEARCH_CONTACT_EMAIL` under that variable's existing
  rule.
- Its Google Scholar source is left as shipped. Scholar refuses most automated queries; that is
  expected and not worked around.
- Pinned like the other paper tools, through the same update flow.
- CORE and BASE, done by the owner at setup (owner, 2026-11-16): a free CORE API key, and
  registering the host's public IP with BASE (BASE returns nothing to unregistered addresses).
  - The CORE key is the research container's first credential. It is a free discovery key with
    nothing behind it but a rate limit, so it follows the `RESEARCH_CONTACT_EMAIL` pattern, not
    1Password: an optional `CORE_API_KEY` line in the research `project.conf`, validated for
    shape, passed to the container as the variable `paper-search-mcp` reads, never printed by
    `agent-up` (status and config output show only "set" or "unset"). `research.md` says the key
    goes to CORE's API only. The main design's "no credentials" statement for the research
    container gets a dated amendment naming this one exception.
  - BASE registration is a runbook step; a home connection's address can change, and the runbook
    says to re-register when BASE starts returning nothing.
  - Both are optional: without them those two sources are skipped or thin, and nothing else breaks.
- The research agent's handoff note of 2026-11-16 in `~/agent-research/_general/` is out of date
  (owner, 2026-11-16) and is not an input to this design.
- MCP servers and agent settings are wired in `images/base/configure-claude-settings.js` and
  `images/base/agent-init.sh`, not only the Dockerfile.
- Whether its own PDF download tools are allowed, or only its search tools, is a builder choice;
  either way downloads land in the existing `downloads/papers/` layout with the existing
  `metadata.md`.

**B. A fetcher container.** A new, shared, always-on container, one per host like the research
container, with its own profile in `agent-up`.

What it is:
- A real Chromium run with a display inside the container (not headless), driven by a small
  script on Playwright. No AI, no agent CLI, no Claude or Codex login, no GitHub token, no
  1Password.
- The browser profile (cookies, including the OpenAthens session and any bot-check clearance)
  lives in a named volume that only this container mounts.
- Open public internet, as the research container has, through the same firewall the research
  profile uses (private and link-local ranges denied). A tight publisher allowlist was considered
  and dropped: publisher pages load from dozens of other hosts, including the bot-check services,
  and would break constantly. The compensating controls are the ones above.
- Chromium's own sandbox stays on (Playwright documents a seccomp profile for running it as a
  non-root user in Docker). `--no-sandbox` is not acceptable for a browser that visits arbitrary
  publisher pages while holding a session.
- Mounts: only the papers folders, read-write: each project's `downloads/papers/` and
  `_general/papers/`. Nothing else from the research folder. It cannot see or write `briefs/`,
  `reports/`, or the rest of `_general` (which is a flat folder holding the research bot's own
  notes). The mounts are generated at `agent-up up fetcher`, so a new project is picked up at the
  next `up`; a restart keeps the session, which lives in the profile volume.

What it does:
1. **Takes lists.** The research bot writes a request file into `_fetch/requests/` inside a papers
   folder: one DOI per line and nothing else. DOIs only in this iteration: a line must match a
   strict DOI pattern (`10.<registrant>/<suffix>` from a safe character set, no whitespace, no `@`,
   `?`, `#`, `..` or backslash) or it is rejected with status `bad-request`. Direct URLs are not
   accepted: the request is written by an AI that reads untrusted pages, and a URL would let it
   send the session-holding browser anywhere. Papers without a DOI stay on the report's
   "not obtained" list. The fetcher notices new files.
2. **Fetches politely.** One paper at a time across the whole container. For each: open
   `https://doi.org/<doi>`, wait for redirects to settle, find the PDF link (`citation_pdf_url`,
   then common PDF link shapes), navigate to it, accept only a file that starts `%PDF-`.
   Pacing defaults: at least 25 s between papers, at least 60 s between two papers from the same
   publisher host, at most 30 papers per publisher host per day and 100 per day overall, one attempt
   per paper per run. All adjustable in the fetcher's config; these are the defaults.
3. **Sorts what it could not get.**
   - *Bot check* ("verify you are human", "Just a moment…", access-denied pages): mark the paper
     `needs-owner: check`, and do not visit that publisher host again in this run.
   - *Login or paywall page*: if the library link is configured, retry once through it (below);
     if that lands on an OpenAthens or Duo page, mark `needs-owner: login` and do not try further
     library-routed papers in this run.
   - *No PDF link, HTTP error, not a PDF*: mark `not-available` with the reason and the final URL.
4. **Writes results** where the bot reads them: the PDF in a folder under the same papers folder,
   with a `metadata.md`, and one status line per requested paper under `_fetch/status/`.
   - Everything the fetcher writes is generated from fixed vocabulary and validated values: the
     DOI as requested, a status word, a reason code from a fixed list, the publisher **host name**
     (validated as a host name), the date, `library route: yes|no`. No page title, page text or
     full URL is copied into a status or metadata file: those files are read by AIs, and text from
     a hostile page would be a way to instruct them.
   - The paper's folder name is derived from the DOI by a sanitiser, never taken from the request.
   - Writes never follow symbolic links and are checked to resolve inside the mounted papers
     folder (the research bot can create links there).
   - Chromium downloads to a temporary directory outside the profile volume; a file is moved into
     place only if it starts `%PDF-`. That is a header check, not a safety check: PDFs from the web
     are untrusted input to the research container's PDF tools, as they are today.
5. **Waits for the owner** on the `needs-owner` papers. Retry is keyed on the publisher host (for
   a check) or on the library route (for a login). When the owner has dealt with it in the browser
   view, they tell the fetcher to retry (a file drop or an `agent-up` subcommand: builder's
   choice), and it retries only the waiting papers for that host or route.

The library route:
- Config value (owner fills it in; not a secret, but it names their institution so it lives in the
  fetcher's config, not in the repo): the prefix of their `go.openathens.net` redirector link.
  A library-routed fetch is that prefix with the publisher URL appended as the redirector expects.
- Used only for papers the direct visit found paywalled, never for open-access papers.
- Its own, lower cap: at most 20 library-routed papers per day by default.

The owner's view of the browser:
- A web page on the host's loopback only, on a port set in the fetcher's config (the RStudio
  pattern: `127.0.0.1:<port>`, a generated password, nothing listening on other interfaces),
  showing the fetcher's browser so the owner can type their OpenAthens password, approve Duo, or
  tick a check box. noVNC or an equivalent maintained package; builder's choice.
- While the owner is using the view, the script does not drive the browser.
- The owner never types a password into a page a request chose. To sign in, the owner asks the
  fetcher for the login page (an `agent-up` subcommand); the fetcher opens the configured library
  link itself, and the browser's address bar is visible in the view so the owner can see they are
  on the OpenAthens host before typing. For a bot check, the view shows the publisher's own
  landing page as resolved from `doi.org`. Between papers the browser is left on a blank page.
- The view's password is generated and kept in the fetcher's config `.generated/` folder (mode
  600), like the RStudio one; it is not written to logs or to any mounted papers folder. The VNC
  server listens on the container's loopback; only the web viewer listens on the container's
  interface, which Docker publishes to the host's `127.0.0.1` only. The fetcher has its own
  compose network, so no other container can reach it.
- A page that merely looks like a login page cannot stall the queue for long: `needs-owner: login`
  is only set when the browser is on the configured OpenAthens or Duo hosts after a library-routed
  visit, judged by host name, not by page text.

What the research bot is told (`project-template/instructions/research.md`, Papers section):
- "If a page asks for a login or shows a paywall, record that and move on" becomes: record it and
  add the paper to a fetch request, then carry on with the papers already in hand.
- Publisher refused an automated download: same, add it to the fetch request.
- Use the added discovery sources before deciding a paper has no legal free copy.
- How to write a request, where the status appears, what each status means, and that a
  `needs-owner` paper is waiting for the owner and is not a failure to report as "unobtainable".
- "Never use Sci-Hub or any other shadow library" stays. "Respect rate limits. No crawling." stays.
- The report's "not obtained" table keeps its role for what is still missing after a fetch.

### Engine: own script, not a packaged fetcher

Auto Paper Harvester (https://github.com/jxtse/auto-paper-harvester) was the packaged candidate.
Its browser channel drives an already-logged-in Chrome through a browser extension and a Node CLI;
it is young (32 stars, created 2025-10) and its source has not been read. The code that sits next
to the library session should be small enough to read in one sitting, and the trial script already
does the job for the publishers that allow it with almost no per-site logic. Playwright is the
maintained dependency. Read Auto Paper Harvester's source for pacing and page-classification ideas
worth borrowing (its 24-hour cooldown on a challenged host is one), and do not vendor it.

Packaged and maintained is the choice for discovery (change A), where per-source API churn is the
real maintenance cost and no credential is nearby.

### How it fits the existing launcher

Follow the research profile's pattern: a third profile value (`fetcher`) with its own config
folder and `project.conf` (the library link prefix, the view port, the caps), a compose seed in
`project-template/config/`, and a section in the runbooks. `bin/agent-up` rejects profiles other
than builder and research today and has research-only image checks (`check_profile`,
`check_image_profile`, the `--image` list, the `init` pin); each needs the new value.

The image, `spades-fetcher`, is built `FROM spades-base` by registry digest, like gis and bio
(decided while planning, 2026-11-16; an earlier draft said a Playwright base image). Reasons: each
image's build context is its own folder, so the firewall script and the `agent` user can only be
inherited, not copied; and it keeps one chain of base digests. It installs Playwright and its
Chromium on top, pinned. It carries R it does not need; that is accepted. It has its own entry
point: firewall first (mounted profile file `PROFILE=research`, the same open-public-egress rules),
then the display, the viewer and the engine. It never runs `agent-init`, T3 or any agent CLI.
It is published and attested with the others, but adding a fifth image is not automatic. These places name exactly
four images and all change: `scripts/build-publish.sh` (the name list, the digests-file line count
and order, its checks), `.github/workflows/publish.yml` (one attest step per image, and the build
step's outputs), `.github/workflows/ci.yml` (the digests-file check), `tests/ci/test-build-publish-static.sh`
and `tests/ci/test-verify-image.sh`. It needs `tests/smoke/fetcher.sh` and
`tests/smoke/fetcher-offline.sh`. `PUBLISH_PATHS` already covers `images/**`. Until the first
publish that includes it, `agent-up update fetcher` refuses with the "not yet published with
attestations" message; that is expected. The Playwright version and the browser it ships must
match, and the pin joins the update bundle. Watch runner disk: the publish job already frees
space for the existing images.

`check_research_overlaps` and `check_mounts` style checks apply: no builder and not the research
container may mount the fetcher's profile volume or config.

## Constraints

- Shadow libraries: none, anywhere.
- No password, cookie or session value in the repo, in a log, in a status file, or in any folder
  another container mounts.
- The fetcher's status and metadata files never include the library link's institution prefix.
- The research container keeps "no credentials".
- New PDF or browser tooling enters images only through the image build (the existing rule that
  the bot does not install tools itself stays).
- Tests run offline against stubs, as elsewhere in this repo; page classification (PDF link found,
  bot check, login page, paywall, not a PDF) is tested against saved sample pages.

## Risks the owner has accepted or should weigh

- A saved browser session is a credential: whoever can read that volume can act as the owner at
  the library until it expires. It is on the host's Docker storage, like the Claude login volumes.
- Publishers watch library logins for bulk downloading; the caps above reduce that risk and do not
  remove it. The library's own terms for alumni accounts have not been checked.
- A real browser on the open internet can be attacked by a hostile page. It runs in a container
  with no other secrets and no access to project code.
- How long a bot-check clearance lasts, and whether logged-in sessions are challenged less, is
  unknown until tried.

## Acceptance

- [ ] The 13 trial papers, requested by the research bot through the queue: the 7 that worked in
      the trial are saved with `metadata.md`; the other 6 are `needs-owner: check`, each publisher
      visited once.
- [ ] After the owner ticks the check for one publisher in the browser view and asks for a retry,
      that publisher's waiting papers are retried and the outcome recorded (saved, or still
      refused: either is a valid finding).
- [ ] With the library link configured and the owner signed in through the view, one closed-access
      paper the owner knows their access covers is saved, and its metadata says the library route
      was used.
- [ ] Signed out, the same request yields `needs-owner: login` after a single visit, and no
      further library-routed attempts in that run.
- [ ] The research container cannot read the fetcher's profile volume; the fetcher cannot see
      `briefs/`, `reports/`, or anything in `_general` outside `papers/`.
- [ ] A request line that is a URL, or a DOI containing `@`, `?`, `..` or whitespace, gets
      `bad-request` and causes no network request.
- [ ] A status or metadata file never contains text taken from a page: a test page whose title and
      body contain an instruction produces files with none of that text.
- [ ] A symbolic link planted in a papers folder is not followed by a write.
- [ ] The fetcher cannot reach a private or link-local address.
- [ ] In the research container, a call to the Sci-Hub tool is refused, and the smoke test proves it.
- [ ] A request of 40 papers from one publisher stops at the daily cap and says so in the status.
- [ ] The browser view answers on `127.0.0.1` only.

## Left to the builder

- Request and status file names and layout within `_fetch/` (the content rules above are fixed);
  how new requests are noticed (poll or inotify).
- How the owner asks for a retry.
- noVNC versus another maintained viewer; how the script yields the browser to the owner.
- Base image for the fetcher; how it joins the publish and attestation flow.
- Whether `paper-search-mcp`'s download tools are exposed to the research bot or only its search.
- Naming (`fetcher` profile name, config keys, port default).
- The order of work. A sensible first slice: the fetcher without the library route (it already
  recovers Wiley and MDPI), then the browser view and retry, then the library route, then change A.
