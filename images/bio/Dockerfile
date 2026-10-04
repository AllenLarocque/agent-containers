# spades-bio: amplicon bioinformatics on top of base. Spec §3.3.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-base:latest
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.description="spades-bio: spades-base plus mafft/cutadapt/fasttree and pinned conda envs (PICRUSt2, scikit-learn)"
USER root
# libglpk-dev and libmagick++-dev are already in base; not reinstalled here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      cutadapt fasttree mafft \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# Miniforge + PINNED envs. Python for reticulate is baked here; modules must state the
# interpreter explicitly (reticulate otherwise silently binds a bare uv Python). Spec §3.4.
ENV CONDA_DIR=/opt/conda
RUN curl -fsSL "https://github.com/conda-forge/miniforge/releases/download/26.7.2-0/Miniforge3-Linux-x86_64.sh" -o /tmp/mf.sh \
    && bash /tmp/mf.sh -b -p "$CONDA_DIR" && rm /tmp/mf.sh \
    && "$CONDA_DIR/bin/conda" create -y -n picrust2 -c conda-forge -c bioconda picrust2=2.5.2 \
    && "$CONDA_DIR/bin/conda" create -y -n sklearn -c conda-forge python=3.12 scikit-learn=1.9.0 joblib numpy scipy biopython \
    && "$CONDA_DIR/bin/conda" clean -afy && chmod -R a+rX "$CONDA_DIR"
USER agent
