# spades-bio: amplicon bioinformatics on top of base. Spec §3.3.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-base:latest
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.description="spades-bio: spades-base plus mafft/cutadapt/fasttree and locked conda envs (PICRUSt2, scikit-learn)"
USER root
# libglpk-dev and libmagick++-dev are already in base; not reinstalled here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      cutadapt fasttree mafft \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# Miniforge + LOCKED envs. Python for reticulate is baked here; modules must state the
# interpreter explicitly (reticulate otherwise silently binds a bare uv Python). Spec §3.4.
# Each env is created from an explicit lock (conda-locks/<env>.txt: exact URLs + #md5, linux-64 only), so
# no solver runs and every build installs the same packages; a fresh solve once broke picrust2 (PR #15).
# Re-lock with scripts/relock-bio-conda.sh (images/bio/README.md).
ENV CONDA_DIR=/opt/conda
# sha256 of the 26.7.2-0 installer (release asset Miniforge3-26.7.2-0-Linux-x86_64.sh.sha256); a mismatch fails the build.
ARG MINIFORGE_SHA256=281b0ac7d550802efc81af633225a5e6116d29ae72f3ab4eae7168c3931a4c05
# Drift check: after install, `conda list --explicit --md5` must equal the lock's package lines
# (order-insensitive), else the build fails.
COPY conda-locks/ /tmp/conda-locks/
RUN set -e; curl -fsSL "https://github.com/conda-forge/miniforge/releases/download/26.7.2-0/Miniforge3-26.7.2-0-Linux-x86_64.sh" -o /tmp/mf.sh; \
    echo "${MINIFORGE_SHA256}  /tmp/mf.sh" | sha256sum -c -; \
    bash /tmp/mf.sh -b -p "$CONDA_DIR"; rm /tmp/mf.sh; \
    for e in picrust2 sklearn; do \
      "$CONDA_DIR/bin/conda" create -y -n "$e" --file "/tmp/conda-locks/$e.txt"; \
      "$CONDA_DIR/bin/conda" list -n "$e" --explicit --md5 > "$CONDA_DIR/envs/$e/spec.txt"; \
      echo "=== $e spec ==="; cat "$CONDA_DIR/envs/$e/spec.txt"; \
      grep -v '^[#@]' "/tmp/conda-locks/$e.txt" | sort > /tmp/lock.sorted; \
      grep -v '^[#@]' "$CONDA_DIR/envs/$e/spec.txt" | sort > /tmp/installed.sorted; \
      test -s /tmp/lock.sorted; \
      if ! diff /tmp/lock.sorted /tmp/installed.sorted; then \
        echo "ERROR: conda env '$e' drifted from images/bio/conda-locks/$e.txt (diff above: < lock, > installed)" >&2; exit 1; \
      fi; \
      echo "OK: conda env '$e' matches its lock ($(wc -l < /tmp/lock.sorted) packages)"; \
    done; \
    rm -rf /tmp/conda-locks /tmp/lock.sorted /tmp/installed.sorted; "$CONDA_DIR/bin/conda" clean -afy; chmod -R a+rX "$CONDA_DIR"
USER agent
