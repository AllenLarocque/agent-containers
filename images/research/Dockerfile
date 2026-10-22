# spades-research: spades-gis plus the PDF suite for the research container. Spec §4.1
# (docs/specs/2026-10-19-research-papers-design.md). The PDF tools are installed by
# paper-tools/install.sh from two plain lists (apt.txt, python.txt); other builders reuse the
# installer by copying paper-tools/ into their own build context.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-gis:latest
# GROBID 0.9.1, CRF models only, pinned by tag AND digest (owner-confirmed 2026-10-22 from Docker Hub).
ARG GROBID_IMAGE=grobid/grobid:0.9.1-crf@sha256:223957791ac2bbe48609dcc58a689b16b60baeae13a8734ef440ae6bfb38f4cd
FROM ${GROBID_IMAGE} AS grobid

FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.description="spades-research: spades-gis plus the PDF suite for the research container"
USER root
# Another builder that wants GROBID copies three lines: the `FROM ${GROBID_IMAGE} AS grobid` stage
# (with its global ARG), the `COPY --from=grobid` below, and the `RUN ... install-grobid.sh` (with its
# ARG). It needs paper-tools/ in its context and openjdk-21-jre-headless (paper-tools/apt.txt).
COPY paper-tools/ /opt/paper-tools/src/
COPY --from=grobid /opt/grobid /opt/paper-tools/grobid
RUN /opt/paper-tools/src/install.sh /opt/paper-tools/src
# install-grobid.sh appends to the MANIFEST that install.sh writes, so it runs after it.
ARG GROBID_IMAGE
RUN /opt/paper-tools/src/install-grobid.sh "$GROBID_IMAGE"
USER agent
