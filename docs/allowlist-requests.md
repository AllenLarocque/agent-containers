# Allowlist requests

A running list of hosts an agent hit and was blocked on, or that are expected soon. The owner
decides each one. Agents propose here (by PR); they never edit an allowlist.

**Where an approved host goes:**
- **base:** `images/base/allowlist.d/00-base.txt` (every container; needs a PR + image rebuild).
- **project:** `~/.config/agent-containers/<project>/allowlist` on the owner's host (then `agent-up up`).
- **FTP:** `FTP_HOSTS` in that project's `project.conf` (tcp 21 only; see the template README).

**Rules:**
- Name the exact host. Use a base domain only when every subdomain is acceptable, since an entry
  covers all its subdomains.
- Never list a shared multi-tenant suffix (`blob.core.windows.net`, `s3.amazonaws.com`,
  `storage.googleapis.com`, `r2.dev`, …). Anyone can create a bucket there, so it is an open way out.
- Give the WHOLE redirect chain (e.g. DOI → landing page → file host).

| Host | Needed for | Where | Status |
|---|---|---|---|
| `results-receiver.actions.githubusercontent.com` | `gh run view --log` (GitHub Actions results service) | base | added (this PR) |
| `productionresultssa10.blob.core.windows.net` | GitHub Actions log download (redirect target) | base | added (this PR) |
| `productionresultssa<N>.blob.core.windows.net`, other N | the same; GitHub shards logs across numbered accounts | base | **add each when hit**; the range is unknown, don't guess |
| `mcp-proxy.anthropic.com` | Claude.ai MCP connectors in Claude Code (the "Claude Docs" connector failed with EAI_AGAIN, 2026-10-11) | base | **owner to decide**: it only matters if you want claude.ai connectors inside containers |
| `webin2.ebi.ac.uk` | ENA read upload (spades_bioinformatics) | FTP | after the FTP_HOSTS PR (#38) merges |
