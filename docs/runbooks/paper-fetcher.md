# Runbook: the paper fetcher

**Human procedure.** The research agent never performs these steps. Design:
[paper-fetcher-design](../specs/2026-11-16-paper-fetcher-design.md).

The fetcher is one shared container. It holds a real, sandboxed Chromium and a small script. It has
no agent, no tokens and no 1Password. The research bot writes a list of DOIs; the fetcher visits
each paper's page, saves the PDF when the publisher allows it, and writes a status line back. Papers
behind a bot check or your library login wait for you.

Commands assume `~/GitHub/agent-containers/bin` is on your `PATH`. The config lives in
`~/.config/agent-containers/fetcher/` (`project.conf`, `compose.yaml`, `fetcher-seccomp.json`).

## One-time setup

1. **Create the config.**

   ```bash
   agent-up init --profile fetcher
   ```

   It takes `RESEARCH_DIR` from the research container's config if there is one (otherwise
   `~/agent-research`).

2. **Edit `~/.config/agent-containers/fetcher/project.conf`.**
   - `FETCH_VIEW_PORT=<port>`: a free port from 1024 to 65535, no leading zero, different from every
     project's `T3_PORT`, `RSTUDIO_PORT` and `FETCH_VIEW_PORT`. It opens the browser view on your
     machine only (`127.0.0.1`). Empty means no view, so no check or login can be done.
   - `LIBRARY_LINK_PREFIX=<prefix>`: optional; leave it empty to use no library route. To find it,
     open the library link you already use. It starts with `go.openathens.net`. Copy the part up to
     and including `?url=`; drop everything after it. The launcher accepts exactly this shape, in
     lower case, with no quotes:

     ```
     https://go.openathens.net/redirector/<your-institution>?url=
     ```

     It names your institution, so it stays in this file and the generated engine config.
     `agent-up` never prints it; it only says `set` or `unset`.
   - The caps are optional (see "Caps").

3. **Start the research container once**, so that each papers folder is its own mount there:

   ```bash
   agent-up up research
   ```

   *Why: the research container could otherwise replace a `papers` folder with a link to any folder
   on the host, and the fetcher's next automatic restart would mount that. As a mount, the folder
   cannot be renamed or replaced from inside.* Do this before the fetcher's first start, and again
   after you add a project.

4. **Pin the image**, then **start the fetcher**:

   ```bash
   agent-up update fetcher
   agent-up up fetcher
   ```

   `up` creates the missing papers folders (`_general/papers` and each project's
   `downloads/papers`) and prints the viewer address. A project added later reaches the fetcher at
   its next `agent-up up fetcher`, after `agent-up up research`.

`agent-up status fetcher` shows the settings (the library route as `set` or `unset`, the caps, the
viewer) and the size of each papers folder.

## Daily use

The fetcher works through requests on its own. You are needed when papers wait on you.

| Command | What it does and prints |
|---|---|
| `agent-up fetch status` | Whether the fetcher is paused, the last page request's answer, and per project the count of each status code, `check waiting:` (publisher hosts) and `login waiting:` (`yes`/`no`). Then `viewer: <address>`. |
| `agent-up fetch view` | Pauses the fetcher (it finishes the paper in flight, then leaves the browser alone) and prints `view: http://127.0.0.1:<port>/vnc.html`, where the password is, and a reminder to check the address bar. The pause ends at `fetch retry`, or 30 minutes after your last `fetch` command. |
| `agent-up fetch check <host>` | Opens the page of the first paper waiting on a check at `<host>` (take `<host>` from `fetch status`). Tick the check in the view, then run `fetch retry <host>`. It keeps the page up only if it landed on `<host>`; otherwise it blanks the tab and says `the waiting paper's page did not land on <host> (the publisher may have moved it): nothing left open`. |
| `agent-up fetch login` | Opens the library sign-in. In the view, check the address bar shows the OpenAthens host, then **type** your password and approve Duo. Run `fetch retry login` when done. It keeps the page up only if it landed on a configured login host (OpenAthens or Duo); otherwise it blanks the tab and says `the library link did not land on a library sign-in page (not an OpenAthens or Duo host): nothing left open`. If you are already signed in it says `the library link went straight through to the publisher: you are already signed in. Nothing left open; run: agent-up fetch retry login`. |
| `agent-up fetch retry [<host>\|login]` | Ends the pause and retries the papers waiting on `<host>`, on the login, or (no argument) every waiting paper in this run. Prints `retry check <host> requested; pause ended`, `retry login requested; pause ended` or `retry all waiting papers requested; pause ended`. |

Other replies: `no paper is waiting on a check at <host> in this run: nothing opened`, `no paper is
waiting on the library login in this run: nothing opened`, `no library prefix is configured
(LIBRARY_LINK_PREFIX): nothing opened`.

**The view.** The address is `http://127.0.0.1:<FETCH_VIEW_PORT>/vnc.html`. The password is eight
characters, in `~/.config/agent-containers/fetcher/.generated/view-password` (delete the file and
run `agent-up up fetcher` to get a new one). Clipboard sharing is off: **type** your library
password, paste does not work. The browser's address bar is visible. Check it before you type
anything. Between papers the browser sits on a blank page.

A "run" is the life of the fetcher's in-memory state: it ends at a restart, at the change of UTC day,
or when you retry. Within a run each paper gets one attempt, one bot check on a host stops that host,
and one login page stops all library-routed visits.

## Status codes

The research bot reads these in `downloads/papers/_fetch/status/<name>.tsv`. Each line has the DOI
(or `line:<n>`), the code, the publisher host name (`-` if none), the date and the library route
(`yes`/`no`). Nothing from a web page is ever copied into these files or into `metadata.md`.

| Code | Meaning | What you do |
|---|---|---|
| `saved` | PDF and `metadata.md` are in the paper's folder. | Nothing. |
| `needs-owner:check` | The publisher showed a bot check. | `fetch check <host>`, tick it, `fetch retry <host>`. |
| `needs-owner:login` | The paper needs the library login. | `fetch login`, sign in, `fetch retry login`. |
| `skipped:host-challenged` | The host showed a bot check on another paper this run. Not attempted. | Clear the check; the paper is retried. |
| `skipped:host-cap` | The per-host daily cap was reached. Tried again on a later day. | Nothing, or raise the cap. |
| `skipped:daily-cap` | The daily cap (or the `doi.org` lookup cap) was reached. Tried again later. | Nothing, or raise the cap. |
| `skipped:library-cap` | The library-route daily cap was reached. Tried again later. | Nothing, or raise the cap. |
| `not-available:doi-not-found` | The DOI does not resolve. Final. | Nothing. |
| `not-available:no-pdf-link` | No usable PDF link on the page. Final. | Get it by hand if you need it. |
| `not-available:not-a-pdf` | The link did not give a PDF. Final. | As above. |
| `not-available:http-error` | The publisher returned an error. Final. | As above. |
| `not-available:timeout` | The page or download timed out. Final. | As above. |
| `bad-request` | A request line (shown as `line:<n>`) was not a DOI. Final. | The bot fixes it in a new file. |

Request rules, enforced by the fetcher: DOIs only (no URLs), at most 200 lines per file, file names
`[A-Za-z0-9._-]` ending `.txt`.

## Caps

Set in `~/.config/agent-containers/fetcher/project.conf` (positive whole numbers, at most 9 digits;
unset means the default), then run `agent-up up fetcher`:

| Key | Default | Limits |
|---|---|---|
| `FETCH_PER_HOST` | 30 | papers per publisher host per day |
| `FETCH_PER_DAY` | 100 | papers per day, all hosts |
| `FETCH_LIBRARY_PER_DAY` | 20 | library-routed papers per day |

Fixed in the engine, not in `project.conf`: at least 25 s between papers, 60 s between papers from
one host, `doi.org` lookups paced and capped at 300 a day, and PDFs capped at 100 MiB each. Changing
those means changing the image (`RESOLVER_PER_DAY`, `GAP_MS`, `HOST_GAP_MS`, `MAX_PDF_BYTES` in
`images/fetcher/engine/lib/config.mjs`).

## When `agent-up` refuses

| Message (start) | Do |
|---|---|
| `the research container was started before paper folders were protected (or before a project existed): not its own mount there:...` | `agent-up up research`, then `agent-up up fetcher`. |
| `the research container uses RESEARCH_DIR=... but the fetcher's config (...) has RESEARCH_DIR=...: the two must match.` | Set `RESEARCH_DIR` in the fetcher's `project.conf` to the research container's. |
| `.../fetcher-seccomp.json differs from the profile this launcher ships (...): it is stale or edited. Refresh it: cp ...` | Run the `cp` it prints, then `agent-up up fetcher`. |
| `.../fetcher-seccomp.json is missing (Chromium's sandbox needs it). Copy it from this clone: cp ...` | Run the `cp` it prints. |
| `.../compose.yaml differs from the seed (...) other than the image digest: the fetcher runs exactly the seed` | `cp` the seed over it as the message says, then `agent-up update fetcher`. Changes to the seed go through a pull request. |
| `LIBRARY_LINK_PREFIX in ...: must be empty (off) or exactly https://go.openathens.net/redirector/<institution>?url= ...` | Fix the value (see step 2). |
| `FETCH_VIEW_PORT='...' in ...: empty (viewer off) or a free port 1024-65535 ...` or `... is also used by <project> (<key>): pick another` | Choose a free port. |
| `<KEY>='...' in ...: must be a positive whole number (at most 9 digits), or unset for the fetcher's default` | Fix the cap. |
| `.../view-password must be one line of 8 printable characters, no spaces (delete it to generate a new one)` | Delete the file; `agent-up up fetcher` makes a new one. |
| `<path> is a symlink: papers folders are mounted only as real folders` | Replace the link with a folder (or remove it). |
| `container(s) <names> mount the volume fetcher-profile (the fetcher's library session): only fetcher-agent-1 may.` | Fix those compose files, then `docker rm <names>`. |
| `<project>/compose.yaml names the volume fetcher-profile`, `... names the fetcher's config dir`, `... uses volumes_from or names fetcher-agent-1`, or `compose would mount or read <path>, which overlaps the fetcher's config dir` | Remove that line from the other project's compose file. No other container may see the session or the config. |
| `... this Docker Compose does not offer that flag ...` | Install a newer Docker Compose. Every project's `up` needs one with `config --no-env-resolution`. |
| `the fetcher's view is off: set FETCH_VIEW_PORT in ... then agent-up up fetcher` | Set the port. |
| `no view password yet: run agent-up up fetcher first` | Run it. |
| `no library route: set LIBRARY_LINK_PREFIX in ... then agent-up up fetcher` | Set the prefix. |
| `the fetcher is not running (agent-up up fetcher)` | Start it. |
| `agent-up update fetcher` fails with `If this repo has not yet published this image with attestations (first publish after the change, or a new image), wait for the publish run to finish.` | The fifth image (`spades-fetcher`) has no attested build yet. Wait for the `publish` run after the change merges to `main`, then retry. |

`agent-up update` restarts the fetcher without asking if it is busy. The paper in flight is retried,
and the browser session survives in the `fetcher-profile` volume.

## Ending the library session

To sign out and forget the browser's cookies (the library session and any bot-check clearance):

```bash
agent-up down fetcher
docker volume rm fetcher-profile
agent-up up fetcher
```

This signs you out. The next `agent-up fetch login` starts again. The same volume holds the
fetcher's pacing counts, so the daily caps start from zero too. Do it when the session may have
been exposed, or when you stop using the library route.

## Risks

- **The saved session is a credential.** Whoever can read the `fetcher-profile` volume can act as you
  at the library until it expires. It sits in Docker's storage on your host. No other container may
  mount it (the launcher refuses), but anyone with Docker access on the host can read it.
- **Bulk downloading is watched.** Publishers and libraries look for it. The caps lower the risk and
  do not remove it. The alumni terms of your library were not checked. Read them before you use the
  library route.
- **A real browser on the open internet.** A hostile page could attack Chromium. It runs inside a
  container with no other secrets and no project code, behind the research firewall (public
  addresses only).
- **The seccomp trade.** Chromium's own sandbox stays on, and it needs user namespaces. The profile
  is Docker's default plus one rule allowing `clone`, `setns` and `unshare`. Compared with Docker's
  default, a process that had already broken out of Chromium's sandbox could create its own user and
  network namespaces inside the container, which exposes more kernel networking code to it. It does
  not bypass the container's firewall, and mount, `bpf` and similar calls stay blocked.
- **The research container and the papers folders.** The research bot can write in the papers
  folders (that is how it makes requests and reads results), so it can write a request or a status
  file for any project it serves. The fetcher treats those as untrusted: it re-checks every request
  line and every status line and never follows links. The bot cannot rename or replace a papers
  folder, because each is its own mount in its container. It cannot reach the fetcher's session, its
  config or its browser. Fetched PDFs are untrusted input, like any download.
- **Pinned browser.** Playwright (in `images/fetcher/engine/package.json`) and the Chromium download
  (a hash in `images/fetcher/Dockerfile`) are pinned and must be bumped together by hand. The weekly
  update agent does not cover them yet.
