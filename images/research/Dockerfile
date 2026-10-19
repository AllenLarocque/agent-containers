# spades-research: spades-gis plus the PDF suite for the research container. Spec §4.1
# (docs/specs/2026-10-19-research-papers-design.md). The PDF tools are installed by
# paper-tools/install.sh from two plain lists (apt.txt, python.txt); other builders reuse the
# installer by copying paper-tools/ into their own build context.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-gis:latest
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.description="spades-research: spades-gis plus the PDF suite for the research container"
USER root
COPY paper-tools/ /opt/paper-tools/src/
RUN /opt/paper-tools/src/install.sh /opt/paper-tools/src
USER agent
