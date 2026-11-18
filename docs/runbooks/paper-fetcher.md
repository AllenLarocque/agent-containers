# Runbook: the paper fetcher

**Human procedure.** The research agent never performs these steps. Design:
[paper-fetcher-design](../specs/2026-11-16-paper-fetcher-design.md).

The fetcher is one shared container. It holds a real, sandboxed Chromium (two separate browser
profiles: one for ordinary visits, one only for the library) and a small script. It has no agent,
no tokens and no 1Password. The research bot writes a list of DOIs; the fetcher visits
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

   This briefly stops the research container (if it is running) while its papers folders are
   checked, created and mounted, then starts it again and checks that each papers folder it sees
   is the very folder on your disk. If that check fails it stops the container again and says why.
   *Why: the research container could otherwise replace a `papers` folder with a link to any folder
   on the host, and the fetcher's next automatic restart would mount that. As a mount, the folder
   cannot be renamed or replaced from inside; stopping it first means nothing it runs can swap a
   folder while the mounts are made.* Do this before the fetcher's first start, and again after you
   add a project.

4. **Pin the image**, then **start the fetcher**:

   ```bash
   agent-up update fetcher
   agent-up up fetcher
   ```

   `up` creates the missing papers folders (`_general/papers` and each project's
   `downloads/papers`), starts the fetcher, checks that each `/papers/<project>` it sees is the very
   folder on your disk (otherwise it stops the fetcher and says why), and prints the viewer address.
   A project added later reaches the fetcher at its next `agent-up up fetcher`, after
   `agent-up up research`.

`agent-up status fetcher` shows the settings (the library route as `set` or `unset`, the caps, the
viewer) and the size of each papers folder.

## Daily use

The fetcher works through requests on its own. You are needed when papers wait on you.

| Command | What it does and prints |
|---|---|
| `agent-up fetch status` | Whether the fetcher is paused, the last page request's answer (or what became of that page since: `signed-in-or-left login`, `left-host check <host>`), and per project the count of each status code, `ignored=<n>` (request files beyond the 50 per project the fetcher reads), `check waiting:` (publisher hosts) and `login waiting:` (`yes`/`no`). Then `viewer: <address>`. |
| `agent-up fetch view` | Pauses the fetcher (it finishes the paper in flight, then leaves the browser alone) and prints `view: http://127.0.0.1:<port>/vnc.html`, where the password is, and a reminder to check the address bar. The pause ends at `fetch retry`, or 30 minutes after your last `fetch` command. |
| `agent-up fetch check <host>` | Opens, in the ordinary (direct) browser, the page of the first paper waiting on a check at `<host>` (take `<host>` from `fetch status`). Tick the check in the view, then run `fetch retry <host>`. **A check page never needs your library password.** It keeps the page up only if it landed on `<host>`; otherwise it blanks the tab and says `the waiting paper's page did not land on <host> (the publisher may have moved it): nothing left open`. While it is up the page is locked to `<host>`: if it goes to any other host, the tab is blanked and `fetch status` shows `last page request: left-host check <host>`. |
| `agent-up fetch login` | Opens the library sign-in in the separate library browser (the ordinary browser's window is moved out of the view meanwhile). **Type your library password only on a page whose address bar shows your library's sign-in host** (`login.openathens.net`, or the Duo page), then approve Duo. The page is locked to the sign-in hosts: the moment it goes anywhere else (your sign-in finished and the library sends you on to the publisher, or anything else) the tab is blanked before that page loads, and `fetch status` shows `last page request: signed-in-or-left login`. Then run `fetch retry login`. So in login mode you never look at a page that is not a sign-in page. If the library link does not reach a sign-in page at all it says `the library link did not land on a library sign-in page (not an OpenAthens or Duo host): nothing left open`; if you are already signed in, the link goes straight on to the publisher, the tab is blanked and it says `the sign-in page went on to a page that is not a library sign-in host (you are signed in, or the page left): the tab was blanked. If you are signed in, run: agent-up fetch retry login`. |
| `agent-up fetch retry [<host>\|login]` | Ends the pause and retries the papers waiting on `<host>`, on the login, or (no argument) every waiting paper in this run. Prints `retry check <host> requested; pause ended`, `retry login requested; pause ended` or `retry all waiting papers requested; pause ended`. |

Other replies: `no paper is waiting on a check at <host> in this run: nothing opened`, `no paper is
waiting on the library login in this run: nothing opened`, `no library prefix is configured
(LIBRARY_LINK_PREFIX): nothing opened`, and `the page did not respond in time: the browser was
restarted and nothing was left open` (a page that stops answering is never left in front of you).

**The view.** The address is `http://127.0.0.1:<FETCH_VIEW_PORT>/vnc.html`. The password is eight
characters, in `~/.config/agent-containers/fetcher/.generated/view-password` (delete the file and
run `agent-up up fetcher` to get a new one). Clipboard sharing is off: **type** your library
password, paste does not work. The browser's address bar is visible. Check it before you type
anything. You see one browser window: the ordinary one, or (during a library visit or your
sign-in) the library one, with the other moved out of the view. Between papers the browser sits on
a blank page. Any extra tab or popup a page opens is closed at once, and only the download the
fetcher itself asked for is kept.

A "run" is the life of the fetcher's in-memory state: it ends at a restart, at the change of UTC day,
or when you retry. Within a run each paper gets one attempt and one login page stops all
library-routed visits. A host that showed a bot check is loaded that once and then not again (not
as a paper's first address, not through a redirect, not when a page moves itself there) until you
run `fetch retry <host>` (or `fetch retry`), or the run ends.

## Status codes

The research bot reads these in `downloads/papers/_fetch/status/<name>.tsv`. Each line has the DOI
(or `line:<n>`), the code, the publisher host name (`-` if none), the date and the library route
(`yes`/`no`). Every field has a fixed format. The host name is the one field that comes from the
network: whoever runs the site chooses it, within lower-case letters, digits, `.` and `-`, at most
100 characters (40 per label; a longer one is written as `-`). No page title, text, URL or file
name is ever copied into these files, `metadata.md` or the fetcher's log.

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
| `not-available:timeout` | The page or download timed out, or the page stopped answering (it is cut off by a hard deadline per visit and the browser is restarted). Final. | As above. |
| `bad-request` | A request line (shown as `line:<n>`) was not a DOI. Final. | The bot fixes it in a new file. |

Request rules, enforced by the fetcher: DOIs only (no URLs), at most 200 lines per file, file names
`[A-Za-z0-9._-]` ending `.txt`, at most 50 request files per project (the first 50 by name; the
rest are left alone and counted as `ignored` in `fetch status`). Projects take turns: one paper from
each project, then the next round.

## Caps

Set in `~/.config/agent-containers/fetcher/project.conf` (positive whole numbers, at most 9 digits;
unset means the default), then run `agent-up up fetcher`:

| Key | Default | Limits |
|---|---|---|
| `FETCH_PER_HOST` | 10 | papers per publisher host per day |
| `FETCH_PER_DAY` | 100 | papers per day, all hosts |
| `FETCH_LIBRARY_PER_DAY` | 20 | library-routed papers per day |

The fetcher is slow on purpose. Fixed in the engine, not in `project.conf`: at least 90 s between
papers and 5 minutes between papers from one publisher's site (all its host names together), each
wait lengthened by a random amount up to half as much again; an owner command (`fetch check`,
`login`, `retry`) is served within a second or two even while a paper waits its turn. Also fixed: `doi.org` lookups paced and capped at 300 a day, PDFs capped at 100 MiB each, and a hard
limit on each browser visit (`PAPER_DEADLINE_MS`: by default the navigation, settle and download
timeouts plus 30 s, about 2.5 minutes). The per-host cap and gap count every host a visit reaches
(a redirect's landing host too, not only the paper's first address). Changing those means changing
the image (`RESOLVER_PER_DAY`, `GAP_MS`, `HOST_GAP_MS`, `MAX_PDF_BYTES`, `PAPER_DEADLINE_MS` in
`images/fetcher/engine/lib/config.mjs`).

## When `agent-up` refuses

| Message (start) | Do |
|---|---|
| `the research container was started before paper folders were protected (or before a project existed): not its own mount there:...` | `agent-up up research`, then `agent-up up fetcher`. |
| `stopped research-agent-1 again: what it mounted is not what agent-up checked: ...` or `stopped fetcher-agent-1 again: ...` | A papers folder changed between the checks and Docker's mount (or is not its own mount). Make each papers folder named a real folder (no link), then run the `agent-up up` it names. |
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

The browser has two profiles in the `fetcher-profile` volume (mounted at `/home/agent/.fetcher` in
the container): `profile-library` is used only for your sign-in and for library-routed visits, and
`profile-direct` holds the ordinary publisher cookies, including any bot-check clearance. A page
visited directly never runs in the library profile. A page reached through the library route does
run there, beside the session (see Risks).

To end only the library session:

```bash
agent-up fetch view        # pause: the paper in flight finishes. If a sign-in page is still up, wait for it to go blank or run `agent-up fetch retry` and start again
docker exec -u agent fetcher-agent-1 rm -rf /home/agent/.fetcher/profile-library
agent-up fetch retry       # end the pause
```

To forget everything (both profiles and the pacing counts, so the daily caps start from zero too):

```bash
agent-up down fetcher
docker volume rm fetcher-profile
agent-up up fetcher
```

Either signs you out of the library. The next `agent-up fetch login` starts again. Do it when the
session may have been exposed, or when you stop using the library route.

## Risks

- **The saved session is a credential.** Whoever can read the `fetcher-profile` volume can act as you
  at the library until it expires. It sits in Docker's storage on your host. No other container may
  mount it (the launcher refuses), but anyone with Docker access on the host can read it.
- **Bulk downloading is watched.** Publishers and libraries look for it. The caps lower the risk and
  do not remove it. The alumni terms of your library were not checked. Read them before you use the
  library route.
- **A real browser on the open internet.** A hostile page could attack Chromium. It runs inside a
  container with no other secrets and no project code, behind the research firewall (public
  addresses only). The engine also refuses, in both browsers and at all times, any request to a
  loopback, private or link-local address, `localhost` or `*.internal` (redirect hops included for the
  tab's own page; not for redirect hops inside a cross-site frame or a worker), and WebSockets to them; it keeps one tab, closes every popup, keeps only
  the download it asked for, answers dialogs, and cuts off a page that stops answering. Limits: the
  WebSocket guard is Playwright's in-page script shim (a page's worker is not covered); a name that
  resolves to a loopback address (DNS rebinding) is not caught by name; the container's own
  loopback is not behind the firewall. The viewer's VNC password remains the last guard on
  loopback.
- **The seccomp trade.** Chromium's own sandbox stays on, and it needs user namespaces. The profile
  is Docker's default plus one rule allowing `clone`, `setns` and `unshare`. Compared with Docker's
  default, a process that had already broken out of Chromium's sandbox could create its own user and
  network namespaces inside the container, which exposes more kernel networking code to it. It does
  not bypass the container's firewall, and mount, `bpf` and similar calls stay blocked.
- **The research container and the papers folders.** The research bot can write in the papers
  folders (that is how it makes requests and reads results), so it can write a request or a status
  file for any project it serves. The fetcher treats those as untrusted: it re-checks every request
  line and every status line and never follows links. The bot cannot rename or replace a papers
  folder, because each is its own mount in its container. It cannot read the fetcher's session, its
  config or its browser profile. It can influence what the session is used for: see the next point. Fetched PDFs are untrusted input, like any download.
- **Library-routed pages run beside the session.** When a paper has no free PDF, its publisher page
  is opened through your library link in the library browser. That page cannot read the library's
  sign-in cookies (the browser's same-origin rules; not separately tested here), but while it is
  open it can send the tab to other public sites, including other addresses behind your library
  link, and load frames, all as you. A request for a DOI whose landing page someone hostile controls
  (the research bot can be tricked into writing one) therefore gets a page running as your library
  identity until the per-visit time limit. The caps and the one-tab rule bound it; locking that tab
  to the library and the one publisher is a planned follow-up. If you would rather not carry this,
  leave `LIBRARY_LINK_PREFIX` empty: the library route is then never used.
- **Sign-in hosts are a fixed list.** The sign-in tab may only be on OpenAthens, Duo and your library
  link's own host. If your sign-in passes through another host (a university page), the tab goes
  blank partway and the library route cannot be used until a setting for extra hosts is added.
- **Pinned browser.** Playwright (in `images/fetcher/engine/package.json`) and the Chromium download
  (a hash in `images/fetcher/Dockerfile`) are pinned and must be bumped together by hand. The weekly
  update agent does not cover them yet.
