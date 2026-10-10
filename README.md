# agent-containers

Layered, pinned dev-container images and a per-project template for AI-assisted
SpaDES work.

```
spades-base   OS, fixed-UID user, agent CLIs, egress firewall, R + Require/SpaDES.project,
 │            GDAL/GEOS/PROJ (every SpaDES module needs terra)
 ├─ spades-gis   NetCDF/HDF5, GDAL CLI
 └─ spades-bio   mafft, cutadapt, fasttree, conda envs (PICRUSt2, scikit-learn)
```

Projects don't build images: each one references an image **by digest** from its own
`compose.yaml`, which lives with its allowlist and 1Password references in the owner's
`~/.config/agent-containers/<project>/`, outside the agent-writable project folder. Start and
manage containers with `bin/agent-up` (see `project-template/README.md`).

Status: **Phase 1 in progress** (PR #3). See `docs/specs/2026-10-03-agent-containers-design.md`.

