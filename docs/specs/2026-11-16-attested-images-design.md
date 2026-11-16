# Attested images: drop the digests PR

Date: 2026-11-16. Status: draft for owner approval.

## Intent

Every merge that changes the images is followed by a second pull request,
`chore: image digests <tag>`, opened by the `publish` workflow. The owner has to approve and merge
it before `agent-up update` can move projects to the new images. In the last 40 pull requests, 17
were these. The owner wants that click gone.

The digests PR exists for a reason (PR #70, closed 2026-11-02; amendment 2026-11-01 in
`2026-10-17-update-flow-design.md`). The agent's token can start `publish` on a branch other than
`main`, or re-run an old run. Such a run executes that branch's `scripts/build-publish.sh` with
`packages: write`, so it can push any image and move the `latest` tag. Merging `digests.md` was the
step where a person decided which images projects get.

That person cannot check a table of hashes. What the merge really asserts is "these images came
from a `publish` run on `main`". GitHub can assert that itself, signed, and the launcher can check
it. This design replaces the click with that check.

## Goals

- No digests PR, no `digests.md`, nothing for the owner to merge after an image change.
- A project is only ever pinned to an image that the `publish` workflow built from reviewed `main`.
  A run on any other branch cannot produce an image that passes.
- An old image cannot be put back: only the newest successful `publish` run on `main`, built from
  the newest image-affecting commit, passes.
- Projects stay pinned by digest in `compose.yaml`, as today.

## Non-goals

- Changing the merge gate on `main`, the machine user, or the token's scopes.
- Verifying images at `agent-up up`. Verification happens when a digest is chosen (`update`,
  `agent-new`); `up` keeps trusting the pinned digest in `compose.yaml`, as today.
- Re-pinning existing projects. Their current digests stay valid until the next `update`.
- Signing or verifying anything other than the four `spades-*` images.

## Anti-goals

- A flag or environment variable that skips verification. Tests stub `gh` on `PATH` instead.
- A "continue anyway" prompt when verification fails or the images are stale. A person pressing
  `c` out of habit would undo the whole design.
- Falling back to an unverified `latest` when GitHub or the registry cannot be reached.

## Approaches considered

1. **Signed build provenance, checked by the launcher (chosen).** Described below. Closes the hole
   that sank PR #70 with a check instead of a click.
2. **Let Actions merge the digests PR** by adding it as a bypass actor on `main`. Rejected: a
   publish run started by the agent on its own branch executes branch-controlled scripts with that
   same Actions token, so this would give the agent a route to push to `main`.
3. **Keep the PR, open fewer** (publish only on request). Rejected: still a click, and images lag
   `main`.

The owner picked 1 on 2026-11-16.

## Spike result (2026-11-16)

Run on the owner's host with `gh` 2.103.3 against a public attested image
(`ghcr.io/astral-sh/uv:latest`):

| Check | Result |
|---|---|
| verify with the right `--signer-workflow` and `--source-ref refs/heads/main` | passes |
| same, with `--source-ref refs/heads/not-this` | fails: `expected SourceRepositoryRef to be refs/heads/not-this, got refs/heads/main` |
| wrong `--signer-workflow` | fails |
| verify by digest (`oci://…@sha256:…`) | passes |
| `--format json` exposes the source commit (`sourceRepositoryDigest`) and trigger | yes |
| without a `gh` login (also with `--bundle-from-oci`) | refused: `gh auth login` required |

So the check needs a logged-in `gh` on the host. Not tested: an attestation produced by this repo's
own workflow. That is the first thing the build must prove (see Acceptance).

## Design

### Publish side

`publish.yml` (triggers unchanged: push to `main` on the image paths, Monday schedule, manual):

1. Build and push the four images under the dated tag, smoke-test each by digest. As today.
2. **New:** attest each image with `actions/attest-build-provenance` (subject = the image name on
   ghcr.io and its manifest digest, the same digest the smoke test pulled).
3. Promote `latest` to those digests and check it. As today, but **after** step 2, so `latest`
   never points at an image without an attestation.

`scripts/build-publish.sh` currently does 1 and 3 in one go and writes `digests.md`. It has to be
split so the workflow can attest in between, and it hands the four digests to the workflow instead
of rendering a file. How it is split is the builder's choice, within one hard rule:

**Digests come from the build, never from a tag.** Today the script learns each digest by reading
the dated tag back from the registry (`digest_of "$registry/spades-$img:$tag"`). The tag is
predictable and a branch run has `packages: write`, so a branch run could overwrite the tag between
the `main` run's push and its read-back, and get its own image smoke-tested, attested as `main` and
promoted (and baked into the children through `BASE_IMAGE=…@$base_digest`). So each digest is taken
from the build's own output (`--metadata-file` or `--iidfile`), and everything after that (child
`BASE_IMAGE`, smoke test, attestation, `latest`) uses that digest. A digest is content-addressed, so
nothing another run pushes can change what it names. The existing "`latest` equals the digest"
read-back stays as a sanity check only. (Found by the design review, 2026-11-16; read from the
code, not exercised.)

Removed from `publish.yml`: the create-pull-request step and the step that dispatches CI on the PR
branch. Permissions become `contents: read`, `packages: write`, `id-token: write`,
`attestations: write` (`pull-requests: write`, `actions: write` and `contents: write` go).

The job gets `if: github.ref == 'refs/heads/main'`. This is tidiness, not the control: branches cut
before this change keep the old file. The control is the launcher's check.

**The Monday rebuild now promotes `latest`** and attests like any other run (owner's call to
confirm; it follows from dropping the PR). OS patches reach a project at its next
`agent-up update`, instead of waiting for the next bundle.

Publish builds without a shared layer cache (base is `--no-cache`; the runner is fresh), so a
branch run cannot plant layers for a `main` run to reuse. Keep it that way: do not add a registry
or Actions cache to the publish build.

### Launcher side: choosing a digest

One shared routine, used by `agent-up update` and `agent-new`, replaces every read of `digests.md`.
For an image name `spades-<x>`:

1. Ask ghcr.io, anonymously, which digest `latest` points to. PR #70's
   `scripts/registry-digest.sh` (branch `feat/digests-from-registry`) does exactly this and can be
   reused.
2. Verify that digest:

   ```
   gh attestation verify oci://ghcr.io/allenlarocque/spades-<x>@sha256:<digest> \
     -R AllenLarocque/agent-containers \
     --signer-workflow AllenLarocque/agent-containers/.github/workflows/publish.yml \
     --source-ref refs/heads/main \
     --deny-self-hosted-runners --format json
   ```

3. Check the attestation is for this image: the statement's subject name is exactly
   `ghcr.io/allenlarocque/spades-<x>` and its digest is the one from step 1. Verification matches
   on digest, so without this a branch run could copy the attested `spades-base` manifest into
   `spades-bio` and a bio project would be pinned to base.
4. Read the source commit from the result and check it against the clone's `origin/main`:
   - it is an ancestor of (or equal to) `origin/main`; and
   - it contains the newest commit on `origin/main` that touches a path in `publish.yml`'s `paths`
     filter. This is the freshness rule. It rejects a re-run of an old run (rollback to older
     source), and it rejects `latest` while a publish for the newest image change has not finished.
5. Check it is the newest build. Ask GitHub (anonymous API) for the latest successful `publish` run
   on `main`; the attestation's run (`runInvocationURI`: run id and attempt) must be that run.
   Every digest ever attested from `main` stays valid forever, and step 4 only compares source
   commits, so without this a branch run could point `latest` back at an earlier Monday rebuild of
   the same source and silently undo OS patches.
6. Only then return the digest for pinning.

Both commit checks need a current `origin/main`, so the routine fetches it first, for `update` and
`agent-new` alike. If the fetch fails, or the source commit is not in the clone at all, there is no
digest and the message says the clone could not be brought up to date (not "not built from main").

Any failure in 1 to 5 means no digest: the project is skipped with a reason, the other projects
still update, and the command exits non-zero. Messages say which step failed and what to do:

| Failure | Message tells the owner |
|---|---|
| `gh` missing or not logged in | run `gh auth login` on the host |
| registry or GitHub unreachable | try again; nothing was changed |
| no attestation, wrong workflow, wrong branch | the image `latest` points to was **not** built by `publish` on `main`; do not use it; link to the publish runs |
| attestation is for another image (step 3) | `latest` for this image points at a different image; do not use it |
| stale (step 4) | images for the newest `main` are not published yet; link to the publish runs (say so if one is running) |
| not the newest build (step 5) | `latest` points at an older build; run `publish` on `main` to restore it |
| clone not current (fetch failed, commit unknown) | fix the clone or the network, then run again |

`agent-up update` keeps `update_guard` (clone on `main`, fast-forward, re-exec), because the
launcher and template have to match the images. `update_pending_pr` and its prompt are removed; the
stale case replaces it. `AGENT_UP_SKIP_GIT_CHECK=1` keeps skipping the on-`main` check and the
fast-forward only; it never skips steps 2 to 5 or the fetch they need. `agent-new` does not need
the clone to be on `main`; it only needs `origin/main` fetched.

Known limit of step 5: if someone re-runs an older `publish` run on `main`, that run builds fresh
and promotes `latest`, but it is not the newest run in GitHub's list, so `update` refuses until
`publish` is run again. That is a nuisance, not a wrong image.

`update` still accepts only image lines from `ghcr.io/allenlarocque/spades-*`, looks each image up
once per run, and rewrites the digest in `compose.yaml` as today.

`agent-new` pins through the same routine. The template placeholder becomes `REPLACE_WITH_DIGEST`
(the old `REPLACE_WITH_DIGEST_FROM_digests.md` is still accepted).

The list of publish paths lives in two places (`publish.yml` and the launcher). A test compares
them so they cannot drift.

### Removed

`digests.md`, `scripts/render-digests.sh`, `scripts/ci-verify-digests.sh`, the `digests` mode in
`scripts/ci-classify.sh` and `ci.yml`, their tests, and the open stale branch
`chore/digests-2026.11.10-0524870`. PR #70's branch already contains most of these removals and the
matching doc and test edits; start from it rather than redoing them.

### Docs

README, `docs/runbooks/new-project.md`, `docs/runbooks/machine-user-and-rulesets.md`,
`docs/agents/update-agent.md`, `project-template/README.md`, and dated amendments to
`2026-10-03-agent-containers-design.md` and `2026-10-17-update-flow-design.md`.

Two runbook changes are new, beyond PR #70:
- The host needs `gh` logged in (any account that can read the public repo).
- "Allow GitHub Actions to create and approve pull requests" is no longer needed on
  `agent-containers`. The runbook tells the owner to turn it off, and decision 3 there is dropped.

### Who applies what

Pushes that touch `.github/workflows/` are refused for the agent's token. Either the work is done
from the owner's host session (which can push workflow files), or the agent prepares a patch for
the owner as before. Builder's choice with the owner.

### Transition

Merging the `publish.yml` change triggers `publish` (the file is in its own `paths`), which
produces the first attested images. Until that run finishes, `update` reports "stale" and changes
nothing. Running projects are untouched throughout.

## Constraints

- Bash launcher, no new host dependencies beyond `gh` (already required by `agent-new`) and `curl`.
- Launcher tests run offline: `gh`, `curl` and `git` behaviour is stubbed as in
  `tests/launcher/stubs/`.
- Workflow files pass `actionlint`; the attest action is pinned the same way as the other actions
  in this repo.

## Acceptance

- [ ] After the change merges, `publish` on `main` ends with four attested images and `latest`
      pointing at them; no pull request is opened.
- [ ] `gh attestation verify` with the exact flags above passes for each of the four.
- [ ] A `publish` run dispatched on a non-`main` branch (using a branch that still has the old
      workflow file) moves `latest`; `agent-up update` then refuses every project with the "not
      built by publish on main" message and changes no `compose.yaml`. Re-running publish on `main`
      restores it.
- [ ] A re-run of an older `main` publish run (older source) moves `latest` back; `update` refuses
      with "stale".
- [ ] `latest` re-pointed by hand at an earlier attested build of the same source: `update` refuses
      with "not the newest build".
- [ ] `spades-bio:latest` re-pointed at the attested `spades-base` digest: `update` refuses bio
      with "another image".
- [ ] `build-publish.sh` contains no digest read from a tag before `latest` is promoted.
- [ ] `agent-up update --all` on a clean state pins the new digests with no prompt.
- [ ] `agent-new` pins a fresh project through the same check.
- [ ] Launcher tests cover: pass, no login, unreachable, wrong branch, wrong image name, stale, not
      the newest build, fetch failed, one image failing while others update.

## Left to the builder

- How `build-publish.sh` is split and how digests reach the attest step (one attest step with a
  checksums file, or four).
- Where the shared lookup-and-verify routine lives (`scripts/` vs inside `bin/agent-up`) and how
  `agent-new` calls it.
- Exact message wording and exit codes.
- Whether the freshness rule reads the path list from `publish.yml` at run time or keeps a copy
  guarded by the test.
