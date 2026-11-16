# Attested Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove `digests.md` and the digests PR; `agent-up update` and `agent-new` pin the digest `latest` points to only after checking a GitHub build attestation that says `publish.yml` built it from `main`, from the newest source, in the newest run.

**Architecture:** `publish.yml` builds, attests, then promotes `latest`. A new script, `scripts/verify-image.sh`, is the single place that turns an image name into a trusted digest (registry lookup, `gh attestation verify`, then four checks against the clone and GitHub). `agent-up update` and `agent-new` call it and nothing else. All GitHub calls go through `gh`; the registry lookup uses `curl`.

**Tech Stack:** Bash, Docker Buildx, GitHub Actions (`actions/attest-build-provenance@v4`), `gh` (>= 2.49, host has 2.103.3), `curl`.

**Spec:** `docs/specs/2026-11-16-attested-images-design.md`

## Global Constraints

- No flag or environment variable skips verification. Tests stub `gh` and `curl` on `PATH` and run the launcher from a throwaway clone whose `origin` is a local bare repo.
- No "continue anyway" prompt. A failed image means that project is skipped with a reason, other projects still update, exit non-zero.
- No fallback to an unverified `latest`.
- In `build-publish.sh`, no digest is read from a tag before `latest` is promoted. Digests come from `--metadata-file` (`containerimage.digest`).
- `latest` is promoted only after all four images are attested.
- The publish build uses no shared layer cache (no `BUILD_CACHE` in `publish.yml`).
- Host scripts use no `jq` or `python` (the host has neither by contract); use `gh … --jq` and shell. CI scripts may use `jq`.
- Exact verify flags: `-R AllenLarocque/agent-containers --signer-workflow AllenLarocque/agent-containers/.github/workflows/publish.yml --source-ref refs/heads/main --deny-self-hosted-runners`.
- Image names: `ghcr.io/allenlarocque/spades-<x>` (lower-case owner).
- Actions are pinned by major tag, like the others in this repo: `actions/attest-build-provenance@v4`.
- Run from the owner's host session: the agent's token cannot push `.github/workflows/`. Branch `feat/attested-images` from `main` (after `feat/op-signin-check` has merged; if it has not, branch from it). One PR.
- Reference only, do not merge: branch `origin/feat/digests-from-registry` (PR #70) has the registry lookup and most removals, written against an older `main`. Take the three files Task 1 names; for everything else read its diff (`git diff main...origin/feat/digests-from-registry -- <path>`) and redo the edit on current code.

## Review Focus

1. One digest has several attestations (a re-run produced the same digest): the image passes if any one attestation satisfies every check; it is not rejected because the first listed one is older.
2. The attested commit is not in the clone (shallow clone, or fetch brought nothing): the message says the clone is not current, never "not built by publish on main".
3. `gh` is logged in but GitHub is unreachable or rate-limited: the message says unreachable and to retry, not "not built by publish on main".
4. A `publish` run for the newest image change is still running: the stale message says so and links the runs page.
5. A project pinned to an image outside `ghcr.io/allenlarocque/spades-*`, or to one image name this repo does not publish: skipped with a reason; no lookup is attempted for it; other projects update.

---

### Task 1: `scripts/verify-image.sh`

**Files:**
- Create: `scripts/registry-digest.sh`, `tests/ci/test-registry-digest.sh`, `tests/launcher/stubs/curl` (all three taken verbatim from `origin/feat/digests-from-registry`)
- Create: `scripts/verify-image.sh`, `tests/launcher/stubs/gh`, `tests/ci/test-verify-image.sh`
- Modify: `.github/workflows/ci.yml` is NOT touched here (Task 3 wires the new tests in)

**Interfaces:**
- Produces: `scripts/verify-image.sh <image-name> <clone-dir>`
  - `<image-name>` is `spades-<x>`; `<clone-dir>` is a git clone of this repo.
  - Success: prints `sha256:<64 hex>` (the digest `latest` points to) on stdout, exit 0.
  - Failure: nothing on stdout, one message on stderr starting `verify-image: <image>: `, and an exit code:

    | Code | Meaning | Message must contain |
    |---|---|---|
    | 2 | bad arguments | `usage` |
    | 10 | `gh` missing or not logged in | `gh auth login` |
    | 11 | registry or GitHub unreachable | `could not reach`, `nothing was changed` |
    | 12 | no attestation / wrong workflow / wrong branch | `was NOT built by publish on main`, `do not use it`, the runs URL |
    | 13 | attestation is for another image | `points at a different image` |
    | 14 | stale | `not published yet`, the runs URL, and `a publish run is in progress` when one is |
    | 15 | not the newest build | `points at an older build`, `run publish on main` |
    | 16 | clone not current | `could not bring origin/main up to date` |

  - Runs URL: `https://github.com/AllenLarocque/agent-containers/actions/workflows/publish.yml`.
  - `PUBLISH_PATHS=(images scripts/build-publish.sh .github/workflows/publish.yml)` is defined once near the top of the script (Task 3 adds the test that keeps it equal to `publish.yml`'s `paths`).
- Produces (test stubs):
  - `tests/launcher/stubs/curl`: fake ghcr.io, driven by `$REG_TABLE` (lines `<image> <tag> <digest>`), as its header comment describes.
  - `tests/launcher/stubs/gh`: driven by files named in the environment:
    - `gh auth status`: exit 1 if `$GH_NOAUTH` is set, else 0.
    - `gh attestation verify oci://ghcr.io/allenlarocque/<img>@<digest> …`: exit 1 with `HTTP 503` on stderr if `$GH_DOWN` is set; fail (exit 1, stderr `no attestations found`) unless the arguments include all four Global Constraints flags with their exact values; otherwise print every line of `$GH_ATTEST` whose first two fields are `<img> <digest>`, minus those two fields, and exit 1 if there were none. `$GH_ATTEST` lines: `<img> <digest> <subject-name> <subject-sha256-hex> <source-sha> <run-id> <attempt>`.
    - `gh api …/actions/workflows/publish.yml/runs … status=success …`: print the contents of `$GH_LATEST_RUN` (`<run-id> <attempt>`); exit 1 if `$GH_DOWN`.
    - `gh api … status=in_progress …` (and `queued`): print `$GH_RUNNING` if set (a count), else `0`.
    - log every call to `$GH_LOG`.

- [ ] **Step 1: Bring over the three files**

```bash
git checkout origin/feat/digests-from-registry -- scripts/registry-digest.sh tests/ci/test-registry-digest.sh tests/launcher/stubs/curl
bash tests/ci/test-registry-digest.sh
```
Expected: 18 `OK`, no `FAIL`.

- [ ] **Step 2: Write `tests/launcher/stubs/gh`** to the interface above.

- [ ] **Step 3: Write the failing tests** in `tests/ci/test-verify-image.sh`, using the `check` / `refuses` helpers copied from `tests/ci/test-registry-digest.sh`. Fixture: a bare repo `$T/origin.git` and a clone `$T/clone` with `main` holding four commits, in order: `C1` touches `images/base/Dockerfile`; `C2` touches `README.md`; `C3` touches `scripts/build-publish.sh`; `C4` touches `README.md`. A side branch commit `X` not on `main`. A commit `C5` (touches `README.md`) pushed to the bare repo from a second clone, so `$T/clone` does not have it until it fetches. `D=sha256:` + 64 `d`; `N=ghcr.io/allenlarocque/spades-gis`. `vi(){ PATH="$T/bin:$PATH" REG_TABLE=… GH_ATTEST=… GH_LATEST_RUN=… "$ROOT/scripts/verify-image.sh" "$@"; }` with both stubs copied into `$T/bin`.

  One case per row; "attest" is the `$GH_ATTEST` line for `spades-gis $D` (subject, source, run), "latest" is `$GH_LATEST_RUN`:

  | Test name | Setup | Assert |
  |---|---|---|
  | pass | attest `$N d…d C3 77 1`; latest `77 1` | exit 0, stdout exactly `$D` |
  | pass: source is a later commit | source `C4` | exit 0 |
  | pass: source only reachable after fetch | source `C5`, latest matches | exit 0 (the script fetched `origin main`) |
  | stale | source `C2` (before `C3`) | exit 14, message contains `not published yet` |
  | stale, a run in progress | as above, `GH_RUNNING=1` | exit 14, message contains `a publish run is in progress` |
  | not on main | source `X` | exit 16 if `X` is unknown to the clone, else 12; assert the message does NOT contain `not published yet` |
  | not the newest build | source `C3`, run `70 1`, latest `77 1` | exit 15 |
  | newest run, older attempt | run `77 1`, latest `77 2` | exit 15 |
  | another image | subject name `ghcr.io/allenlarocque/spades-base` | exit 13 |
  | subject digest differs | subject hex 64 `e` | exit 13 |
  | no attestation | empty `$GH_ATTEST` | exit 12, message contains `was NOT built by publish on main` and the runs URL |
  | several attestations, one good (Review Focus 1) | two lines: first run `70 1`, second run `77 1`; latest `77 1` | exit 0 |
  | commit not in clone (Review Focus 2) | source = 40 `a` | exit 16, message contains `could not bring origin/main up to date`, not `NOT built` |
  | fetch fails | `git -C "$T/clone" remote set-url origin "$T/nope.git"` | exit 16 |
  | GitHub down (Review Focus 3) | `GH_DOWN=1` | exit 11, message contains `could not reach`, not `NOT built` |
  | registry down | `REG_TABLE` has no line for the image | exit 11 |
  | not logged in | `GH_NOAUTH=1` | exit 10, message contains `gh auth login` |
  | gh missing | PATH with the curl stub but no `gh` | exit 10 |
  | bad image name | `verify-image.sh 'spades-gis;id' "$T/clone"` | exit 2 |
  | every failure | each failing case above | stdout empty |
  | exact flags | the pass case | `$GH_LOG` shows the four Global Constraints flags and `oci://ghcr.io/allenlarocque/spades-gis@$D` (by digest, not `:latest`) |

- [ ] **Step 4: Run; all must fail**

Run: `bash tests/ci/test-verify-image.sh`
Expected: every line `FAIL` (script does not exist).

- [ ] **Step 5: Implement `scripts/verify-image.sh`.** `set -euo pipefail`. Order of work, which fixes which code wins when several things are wrong:
  1. Validate arguments (`^spades-[a-z]+$`, clone is a git work tree) -> 2.
  2. `command -v gh` and `gh auth status` -> 10.
  3. `GIT_TERMINAL_PROMPT=0 git -C "$clone" fetch -q origin main` -> 16 on failure. Use `FETCH_HEAD` as "origin/main" from here on.
  4. `scripts/registry-digest.sh "$img"` (sibling of this script) -> 11 on failure.
  5. Latest successful run: `gh api -X GET "repos/AllenLarocque/agent-containers/actions/workflows/publish.yml/runs" -f branch=main -f status=success -f per_page=1 --jq '.workflow_runs[0] | "\(.id) \(.run_attempt)"'` -> 11 on failure or empty.
  6. `gh attestation verify "oci://ghcr.io/allenlarocque/$img@$digest"` with the Global Constraints flags plus `--format json --jq` and this expression, one line per attestation:

     ```
     .[] | .verificationResult | "\(.statement.subject[0].name) \(.statement.subject[0].digest.sha256) \(.signature.certificate.sourceRepositoryDigest) \(.signature.certificate.runInvocationURI | capture("/runs/(?<r>[0-9]+)/attempts/(?<a>[0-9]+)") | "\(.r) \(.a)")"
     ```

     On failure: if its stderr matches `HTTP 5|HTTP 429|rate limit|dial tcp|timeout|no such host` -> 11; otherwise -> 12.
  7. For each line, evaluate in this order and remember the first failing code for that line: subject name and digest (13); source commit exists in the clone (`git cat-file -e "$sha^{commit}"`, else 16); `git merge-base --is-ancestor "$sha" FETCH_HEAD` (else 12); `newest=$(git -C "$clone" log -1 --format=%H FETCH_HEAD -- "${PUBLISH_PATHS[@]}")` and `git merge-base --is-ancestor "$newest" "$sha"` (else 14); run id and attempt equal step 5's (else 15). If any line passes all five, print the digest and exit 0. Otherwise exit with the failing code of the line that got furthest (highest position in that order), so one stray attestation does not hide the real reason.
  8. For code 14 only, ask `gh api … -f status=in_progress` and `queued` for a count and add `a publish run is in progress` when non-zero (a failed lookup adds nothing).

- [ ] **Step 6: Run**

Run: `bash tests/ci/test-verify-image.sh 2>&1 | grep -c "^FAIL"; shellcheck scripts/verify-image.sh scripts/registry-digest.sh tests/launcher/stubs/gh tests/launcher/stubs/curl`
Expected: `0`, and shellcheck clean.

- [ ] **Step 7: Commit**

```bash
git add scripts/registry-digest.sh scripts/verify-image.sh tests/ci/test-registry-digest.sh tests/ci/test-verify-image.sh tests/launcher/stubs
git commit -m "feat: verify-image.sh turns an image name into a digest attested by publish on main"
```

### Task 2: `build-publish.sh` in two phases, digests from the build

**Files:**
- Modify: `scripts/build-publish.sh`
- Delete: `scripts/render-digests.sh`, `tests/ci/test-render-digests.sh`
- Test: `tests/ci/test-build-publish-static.sh` (new)

**Interfaces:**
- Produces:
  - `scripts/build-publish.sh build <registry-prefix> <tag> <digests-file>`: builds and pushes the four images under `<tag>`, smoke-tests each by digest, writes `<digests-file>` with exactly four lines, in this order: `spades-base sha256:<hex>`, `spades-gis …`, `spades-bio …`, `spades-research …`. Does not touch `latest`.
  - `scripts/build-publish.sh promote <registry-prefix> <digests-file>`: for each line, `imagetools create -t <prefix>/<name>:latest <prefix>/<name>@<digest>`, then reads `latest` back and fails if it differs.
  - `BUILD_CACHE=gha` keeps working for `build` (CI uses it).

- [ ] **Step 1: Write the failing static test** `tests/ci/test-build-publish-static.sh`:

```bash
check "no digest is read from a tag in the build phase" \
  bash -c '! awk "/^promote\\(\\)/{p=1} !p" "$1" | grep -nE "imagetools inspect[^|]*:\\\$?\\{?tag"' _ "$ROOT/scripts/build-publish.sh"
check "every build takes its digest from --metadata-file" \
  bash -c '[ "$(grep -c -- "--metadata-file" "$1")" -ge 1 ] && grep -q "containerimage.digest" "$1"' _ "$ROOT/scripts/build-publish.sh"
check "digests.md and render-digests are gone" \
  bash -c '! grep -qE "render-digests|digests\.md" "$1" && [ ! -e "$2/scripts/render-digests.sh" ]' _ "$ROOT/scripts/build-publish.sh" "$ROOT"
refuses "unknown phase prints usage" 'usage' "$ROOT/scripts/build-publish.sh" nope
refuses "promote refuses a malformed digests file" 'bad digests file' bash -c 'printf "spades-base nope\n" > "$1/d"; "$2/scripts/build-publish.sh" promote localhost:5000/x "$1/d"' _ "$T" "$ROOT"
```
  (The first check assumes the promote phase is a function named `promote()`; keep that name.)

- [ ] **Step 2: Run; expect FAIL** — `bash tests/ci/test-build-publish-static.sh`

- [ ] **Step 3: Restructure the script.** `build()` adds `--metadata-file "$tmp/$img.json"` and returns the digest via `jq -r '."containerimage.digest"'`, validated against `^sha256:[0-9a-f]{64}$`; delete `digest_of` from the build phase. Children keep `--build-arg BASE_IMAGE=$registry/spades-base@$base_digest` (and research from gis), now fed by the metadata digest. Smoke tests are unchanged (already by digest). `promote()` validates every line of the file (`bad digests file` on anything else, before touching the registry), then promotes and reads back. Update the header comment. Delete `render-digests.sh` and its test.

- [ ] **Step 4: Run the static test, then the real thing against a local registry** (needs Docker; takes as long as a CI build)

```bash
bash tests/ci/test-build-publish-static.sh
docker run -d --rm -p 5000:5000 --name reg registry:2
scripts/build-publish.sh build localhost:5000/allenlarocque 2000.01.01-dryrun /tmp/digests.txt
scripts/build-publish.sh promote localhost:5000/allenlarocque /tmp/digests.txt
for i in base gis bio research; do [ "$(docker buildx imagetools inspect localhost:5000/allenlarocque/spades-$i:latest --format '{{json .Manifest.Digest}}' | tr -d '"')" = "$(awk -v n=spades-$i '$1==n{print $2}' /tmp/digests.txt)" ] && echo "OK $i"; done
docker stop reg
```
Expected: static test all `OK`; four `OK <image>` lines. If the local build is impractical on this machine, say so in the PR and rely on CI's `build-test`, which runs the same two commands (Task 3).

- [ ] **Step 5: Commit**

```bash
git add -A scripts tests/ci
git commit -m "feat(publish): build and promote are separate phases; digests come from the build, never a tag"
```

### Task 3: Workflows and CI modes

**Files:**
- Modify: `.github/workflows/publish.yml`, `.github/workflows/ci.yml`, `scripts/ci-classify.sh`, `tests/ci/test-classify.sh`
- Delete: `digests.md`, `scripts/ci-verify-digests.sh`
- Test: `tests/ci/test-publish-paths.sh` (new)

**Interfaces:**
- Consumes: Task 2's two phases and digests-file format; Task 1's `PUBLISH_PATHS`.
- Produces: after a `publish` run on `main`, each `ghcr.io/allenlarocque/spades-<x>` digest in the digests file has a provenance attestation, and `latest` points at it.

- [ ] **Step 1: Write the failing path-drift test** `tests/ci/test-publish-paths.sh`: extract the `paths:` list from `publish.yml`, strip a trailing `/**`, sort; extract `PUBLISH_PATHS=(…)` from `scripts/verify-image.sh`, sort; `check "publish.yml paths == verify-image.sh PUBLISH_PATHS" diff …`. It fails now because `publish.yml` still lists `scripts/render-digests.sh`.

- [ ] **Step 2: `publish.yml`.**
  - `paths: ["images/**", "scripts/build-publish.sh", ".github/workflows/publish.yml"]`.
  - `permissions:` exactly `contents: read`, `packages: write`, `id-token: write`, `attestations: write`.
  - Job-level `if: github.ref == 'refs/heads/main'`.
  - Steps after login: `build` phase (id `build`, writes `digests.txt`, then appends `base=…`, `gis=…`, `bio=…`, `research=…` to `$GITHUB_OUTPUT`); four `actions/attest-build-provenance@v4` steps, each with `subject-name: ghcr.io/allenlarocque/spades-<x>` and `subject-digest: ${{ steps.build.outputs.<x> }}`; then the `promote` phase.
  - Remove the create-pull-request step, the "Run CI on the digests PR branch" step, the `tag`-dependent PR fields, and the schedule comment about "no digests PR"; the Monday run now does everything a push run does. Update the cron comment to say so.

- [ ] **Step 3: `ci.yml`, `ci-classify.sh`.** Remove the `digests` mode everywhere (classifier, the mode `case`, the verify step, the header comment). In the `full` path, replace the single `build-publish.sh … /tmp/digests.md` call with `build` then `promote` against the local registry, and replace "Verify digests.md" with: `/tmp/digests.txt` has exactly four lines matching `^spades-(base|gis|bio|research) sha256:[0-9a-f]{64}$` in that order. In the `lint` job (or wherever `tests/ci/*.sh` run today; follow the existing pattern) add `test-registry-digest.sh`, `test-verify-image.sh`, `test-build-publish-static.sh`, `test-publish-paths.sh` and drop `test-render-digests.sh`. Update `tests/ci/test-classify.sh`: the cases that expected `digests` now expect `full` (a `digests.md`-only change no longer exists; use the PR #70 diff of this test as the reference).

- [ ] **Step 4: Delete** `digests.md` and `scripts/ci-verify-digests.sh`; `grep -rn "digests.md\|ci-verify-digests\|render-digests" .github scripts tests/ci` must print nothing.

- [ ] **Step 5: Run**

Run: `actionlint .github/workflows/*.yml && for t in tests/ci/test-*.sh; do bash "$t" | grep -c "^FAIL"; done`
Expected: actionlint silent; every count `0`.

- [ ] **Step 6: Commit**

```bash
git add -A .github scripts tests/ci digests.md
git commit -m "feat(publish): attest every image, then promote latest; no digests PR"
```

### Task 4: `agent-up update` pins through `verify-image.sh`

**Files:**
- Modify: `bin/agent-up` (`digest_for` line 1052, `update_guard` 1082-1101 messages, `update_pending_pr` 1102-1131, `cmd_update` 1132-1163, usage line 26, `check_digest` message line 510, init text lines 159 and 205)
- Test: `tests/launcher/test-agent-up.sh` (the update section from line 1561 to the end)

**Interfaces:**
- Consumes: `scripts/verify-image.sh <image-name> <clone-dir>` and its exit codes (Task 1); stubs `tests/launcher/stubs/{gh,curl}`.
- Produces: `image_digest()` in `bin/agent-up`: `$1` image name -> sets `IMG_DIGEST` (empty on failure) and `IMG_WHY` (the script's stderr with the `verify-image: <image>: ` prefix removed); caches per image name for the run, successes and failures alike, so each image is looked up once.
- Removed: `digest_for`, `update_pending_pr`, `AGENT_UP_DIGESTS`, `AGENT_UP_PULLS_URL`, `AGENT_UP_RUNS_URL`.

- [ ] **Step 1: Rebuild the update tests' fixture.** Replace the `digests.md` heredoc and `AGENT_UP_DIGESTS` with a throwaway clone: `$T/uclone` holding a copy of `bin/`, `scripts/` and `project-template/`, committed on `main` (the commit touches `scripts/build-publish.sh`, so it is its own newest publish-path commit; record it as `USHA`), with `origin` a local bare repo that has the same commit. Put both stubs on `PATH`. `REG_TABLE` maps `spades-gis latest sha256:$GISD` and `spades-base latest sha256:$BASED`; `GH_ATTEST` has a passing line for each (`source=$USHA`, run `77 1`); `GH_LATEST_RUN` is `77 1`. `au` for this section runs `$T/uclone/bin/agent-up`. `uenv` keeps `AGENT_UP_SKIP_GIT_CHECK=1` (skips only the on-`main` check and fast-forward).

- [ ] **Step 2: Change and add tests** (the existing update tests keep their assertions unless listed):

  | Test | Assert |
  |---|---|
  | existing "exit 0 when all three updated" and the digest-rewritten checks | still pass against the new fixture |
  | image line outside `ghcr.io/allenlarocque/spades-*` (was "not in digests.md") (Review Focus 5) | row `SKIP (image ghcr.io/x/custom is not published by this repo)`, non-zero, compose unchanged, `$CURL_LOG` has no line for it |
  | one image fails, the other updates | `GH_ATTEST` without the `spades-gis` line: alpha and beta rows `NOT UPDATED (` + the code-12 text, research row `updated`, exit non-zero, alpha's compose unchanged, no `compose … -p alpha up` in `$DLOG` |
  | each image is looked up once | after `update --all` with two gis projects, `$CURL_LOG` has exactly one `spades-gis latest` line |
  | stale | attest source = a commit before `USHA` (make a second commit touching `images/` and push it to the bare origin): rows say `not published yet`; no prompt is printed (output has no `[q]uit`) |
  | stale with a run in progress (Review Focus 4) | `GH_RUNNING=1`: row contains `a publish run is in progress` |
  | not the newest build | `GH_LATEST_RUN` = `78 1`: rows contain `points at an older build` |
  | not logged in | `GH_NOAUTH=1`: every non-current row carries the `gh auth login` text, exit non-zero, nothing changed |
  | a failure never prompts | for each failing case above, run with stdin from `/dev/null` and assert it returns (no `read`) and prints no `[c]ontinue` |
  | `AGENT_UP_SKIP_GIT_CHECK=1` does not skip verification | with the var set and an empty `GH_ATTEST`: still `NOT UPDATED` |
  | already current | compose digest equals `latest` and passes: row `current` (existing test, new fixture) |

  Delete every test of `update_pending_pr` (the `pulls*.json` / `runs*.json` cases, lines ~1762-1857) and the `AGENT_UP_PULLS_URL` / `AGENT_UP_RUNS_URL` exports. In the `update_guard` tests, replace the message `is not on main: digests.md is not current` with the new wording from Step 4.

- [ ] **Step 3: Run; expect the changed and new checks to FAIL**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -E "^FAIL" | head -30`

- [ ] **Step 4: Implement.** In `cmd_update`: drop the `digests` local, the `[ -f "$digests" ]` check and the `update_pending_pr` call; replace the `digest_for` branch with: image line must match `^ghcr\.io/allenlarocque/spades-[a-z]+$` (else the SKIP row above), then `image_digest "$name_img"`; empty `IMG_DIGEST` -> `res="NOT UPDATED ($IMG_WHY)"; rc=1`. Everything after that (current / Google Drive / not running / busy / token / `up`) is unchanged and uses `new="$IMG_DIGEST"`. `image_digest` calls `"$HERE/../scripts/verify-image.sh" "$1" "$(cd "$HERE/.." && pwd)"` with stdin from `/dev/null`. `update_guard`: same logic; messages say `the launcher and the images must match` instead of `digests.md is not current`; the failed-fetch branch keeps its warning (verify-image.sh does its own fetch and refuses if that fails). Delete `digest_for` and `update_pending_pr`. Usage line 26: `pull main, then move projects to the newest images published from main (verified; asks before restarting a busy one)`. `check_digest` and the two init texts: replace "Copy one from agent-containers/digests.md" with "Set it with: agent-up update <project>".

- [ ] **Step 5: Run the whole file**

Run: `bash tests/launcher/test-agent-up.sh 2>&1 | grep -cE "^FAIL"`
Expected: `0`

- [ ] **Step 6: Commit**

```bash
git add bin/agent-up tests/launcher/test-agent-up.sh
git commit -m "feat(agent-up): update pins the image publish attested from main; no digests.md, no digests PR check"
```

### Task 5: `agent-new` and the template

**Files:**
- Modify: `bin/agent-new` (line 11 `DIGESTS`, lines 79-87 the pin step), `project-template/config/compose.yaml`, `project-template/config/compose.research.yaml`, `bin/agent-up` (wherever `init` writes or checks the placeholder: `grep -n REPLACE_WITH_DIGEST bin/agent-up`)
- Test: `tests/launcher/test-agent-new.sh`, `tests/launcher/test-agent-up.sh` (init tests that mention the placeholder)

**Interfaces:**
- Consumes: `scripts/verify-image.sh` (Task 1).
- Produces: template placeholder `REPLACE_WITH_DIGEST`; the old `REPLACE_WITH_DIGEST_FROM_digests.md` is still recognised when pinning an existing config.

- [ ] **Step 1: Tests.** In `test-agent-new.sh` put the two stubs on `PATH`, point the script at a throwaway clone as in Task 4 Step 1 (agent-new resolves its clone from its own location, so run a copy inside the throwaway clone), drop `AGENT_NEW_DIGESTS`, and assert: a fresh project is pinned to the digest in `REG_TABLE`; a config still holding the old placeholder is pinned too; with an empty `GH_ATTEST` the pin step dies with the code-12 text and `compose.yaml` still holds the placeholder; `already pinned` still skips without calling the stubs (`$CURL_LOG` empty). Update the init tests in `test-agent-up.sh` for the new placeholder.

- [ ] **Step 2: Run; expect FAIL** — `bash tests/launcher/test-agent-new.sh 2>&1 | grep -E "^FAIL" | head`

- [ ] **Step 3: Implement.** The pin step calls `verify-image.sh "$img" "<clone>"`; on a non-zero exit it dies with the script's message; on success it substitutes the digest for either placeholder (keep the existing fallback `sed` that rewrites the `@…` suffix). Remove `DIGESTS`/`AGENT_NEW_DIGESTS`. Rename the placeholder in both template compose files and their comments.

- [ ] **Step 4: Run both launcher files**

Run: `bash tests/launcher/test-agent-new.sh 2>&1 | grep -cE "^FAIL"; bash tests/launcher/test-agent-up.sh 2>&1 | grep -cE "^FAIL"`
Expected: `0` and `0`

- [ ] **Step 5: Commit**

```bash
git add bin project-template tests/launcher
git commit -m "feat(agent-new): pin a new project through the same attestation check"
```

### Task 6: Docs, PR, and the owner's acceptance run

**Files:**
- Modify: `README.md`, `project-template/README.md`, `docs/runbooks/new-project.md`, `docs/runbooks/machine-user-and-rulesets.md`, `docs/agents/update-agent.md`, `docs/specs/2026-10-03-agent-containers-design.md`, `docs/specs/2026-10-17-update-flow-design.md`

- [ ] **Step 1: Docs.** `grep -rn "digests.md\|digests PR\|chore/digests" README.md project-template docs/runbooks docs/agents` and rewrite each hit to the new flow (merge the image change, wait for `publish`, run `agent-up update`). In `machine-user-and-rulesets.md`: drop decision 3 and step 2.3's `agent-containers` exception (the setting is now OFF everywhere); rewrite step 7 to "first publish: make each package public" without the digests PR items; add that the host needs `gh auth login`. Add an amendment headed `## Amendment 2026-11-16: attested images replace the digests PR` to both specs, each a short paragraph linking the new design and stating what it supersedes (in the update-flow spec: the 2026-11-01 amendment's digests PR check). Leave `docs/superpowers/plans/` history untouched.

- [ ] **Step 2: Full local check**

Run: `shellcheck bin/* scripts/*.sh tests/ci/*.sh tests/launcher/*.sh tests/launcher/stubs/*; actionlint .github/workflows/*.yml; for t in tests/ci/test-*.sh tests/launcher/test-*.sh; do echo "$t $(bash "$t" 2>&1 | grep -c '^FAIL')"; done`
Expected: no new shellcheck findings against `main`; every test file reports `0`.

- [ ] **Step 3: Commit, push, open the PR**

```bash
git add -A docs README.md project-template/README.md
git commit -m "docs: attested images replace digests.md and the digests PR"
git push -u origin feat/attested-images
gh pr create --title "Attested images: drop digests.md and the digests PR" --body-file <body>
```
PR body: why; what changed; test counts; **not checked before merge**: a real attestation from this repo's workflow (it can only run on `main`), and the four drills below. Wait for `build-test`, `lint` and `gitleaks` to go green. Do not merge; the owner merges.

- [ ] **Step 4: After the owner merges — acceptance (owner present; these touch the live registry, confirm before each)**

  1. Watch the `publish` run the merge triggers. Expected: four attest steps green, no PR opened.
  2. For each of the four images: `d=$(scripts/registry-digest.sh spades-<x>)`, then `gh attestation verify oci://ghcr.io/allenlarocque/spades-<x>@$d` with the Global Constraints flags. Expected: exit 0.
  3. `agent-up update --all`. Expected: projects move to the new digests, no prompt about digests.
  4. `agent-new` on a scratch project name pins through the check (or run its pin step against an existing scratch config), then remove the scratch project.
  5. Drill, wrong branch: `gh workflow run publish.yml --ref <a branch cut before this change>`; when it finishes, `agent-up update --all`. Expected: every project refused with `was NOT built by publish on main`, no `compose.yaml` changed. (That old workflow also opens a `chore/digests-*` PR: close it and delete its branch.) Then `gh workflow run publish.yml --ref main` and confirm `update` passes again.
  6. Drill, wrong image: `docker buildx imagetools create -t ghcr.io/allenlarocque/spades-bio:latest ghcr.io/allenlarocque/spades-base@<base digest>`; `agent-up update <a bio project>`. Expected: refused with `points at a different image`. Restore with `publish` on `main`.
  7. Drill, older build: point `spades-gis:latest` at the previous attested gis digest (from the prior run's log). Expected: `points at an older build`. Restore with `publish` on `main`.
  8. If any drill passes when it should refuse: stop, revert the PR, and report.

- [ ] **Step 5: Owner clean-up (GitHub UI / owner's `gh`)**: turn OFF Settings -> Actions -> General -> "Allow GitHub Actions to create and approve pull requests" on `agent-containers`; close any open `chore/digests-*` PR and delete the branch `chore/digests-2026.11.10-0524870`; close or delete `feat/digests-from-registry`.
