# spades-bio

`spades-base` plus mafft, cutadapt and fasttree (apt), and two conda envs under `/opt/conda/envs`:

| env | what | interpreter |
|-----|------|-------------|
| `picrust2` | PICRUSt2 2.5.2 (bioconda) | `/opt/conda/envs/picrust2/bin/python` |
| `sklearn` | Python 3.12, scikit-learn 1.9.0, numpy, scipy, joblib, biopython | `/opt/conda/envs/sklearn/bin/python` |

## Conda envs are locked

Each env is installed from an explicit lock, `conda-locks/<env>.txt`: one exact package URL per line
with its `#md5`. `conda create --file` installs exactly those packages, with no solver, and checks
each download against its md5. The build then compares `conda list --explicit --md5` with the lock and
fails on any difference. The installed list is also kept in the image as `/opt/conda/envs/<env>/spec.txt`.

Why: before the locks, each build re-solved `picrust2=2.5.2` and could pick different dependencies.
One such solve (PR #15) broke `picrust2_pipeline.py -h`. The current locks come from
`ghcr.io/allenlarocque/spades-bio@sha256:14ef14c95c157202f070c8c132061ec0d361dbd42575f13c1a08695bf0d7137f`,
an image that passed the publish smoke test.

The locks are **linux-64 only**. An arm64 build would need its own locks.

### Re-locking

You need docker. Run either:

```sh
# Copy the envs from an image that passed the bio smoke test (the lock is what was tested):
scripts/relock-bio-conda.sh from-image ghcr.io/allenlarocque/spades-bio@sha256:<digest>

# Or move versions: edit SPECS in the script, then re-solve with that image's conda:
scripts/relock-bio-conda.sh solve            # default image: ghcr.io/allenlarocque/spades-bio:latest
```

Then review `git diff images/bio/conda-locks` and open a PR. The full CI build-test builds the image
from the new locks and runs `tests/smoke/bio.sh`. A fresh `solve` is untested until that run passes.

Without local docker, run the same script on a GitHub runner (for example in a `workflow_dispatch`
job) and commit its output.

### Network

All lock URLs are on `conda.anaconda.org` (conda-forge and bioconda channels). The image is built on
GitHub runners, where the egress firewall does not apply. The firewall (`images/base/init-firewall.sh`)
only runs in agent containers, so the host only needs allowlisting there if you use conda at runtime.
`project-template/config/allowlist.bio-example` already lists it.
