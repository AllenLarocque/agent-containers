# spades-base: everything every SpaDES agent container needs. See docs/specs/2026-10-03-agent-containers-design.md §3.1.
FROM rocker/r-ver:4.5.3@sha256:c3f39b365d1077fe24f8e9ab2742e352b6d3950897f51af1624a5bb5550c21c0

LABEL org.opencontainers.image.source="https://github.com/AllenLarocque/agent-containers" \
      org.opencontainers.image.description="spades-base: SpaDES agent container base (R, geospatial libs, egress firewall; Claude Code and Codex install at container start)"

ARG TZ=America/Los_Angeles
ARG UV_VERSION=0.12.19
# sha256 of uv-x86_64-unknown-linux-gnu.tar.gz, from the release asset ...tar.gz.sha256 (a mismatch fails the build).
ARG UV_SHA256=23bf5552d220e0842b65c862097b2ebaeba0064b74eda5e565e77fd25969d8c8
ARG PE_AI_COMMIT=e7ae689751316dfe742f31b32d0d659accd0cc41
# T3 Code server (MIT; spec §13.1), pinned: sha256 of t3-<ver>-linux-x64.tar.gz from the release's SHA256SUMS.
ARG T3_VERSION=0.0.45
ARG T3_SHA256=10505ae74bc6a43cfab0fde0bf06a0e0d6862f74030591be994a640d48a0d6bd
# RStudio Server, open-source edition (AGPLv3; spec §13.3), pinned: the current stable release (published
# 2026-09-11). Posit publishes no checksum file for server .debs: this sha256 is from the first download,
# whose embedded dpkg-sig signature verified against Posit's code-signing key
# 8B65 E5A1 07BB EFE3 BA99  C597 51C0 B5BB 19F9 2D60 (posit.co/code-signing).
ARG RSTUDIO_VERSION=2026.09.0+174
ARG RSTUDIO_SHA256=168bc577ef2f68abab1ad2ed684e830da1d244618b25b69fd20448e60716c5ba
ENV TZ="$TZ" DEBIAN_FRONTEND=noninteractive

# OS + agent tooling. tmux: detached long runs. exiftool: photo metadata (field data).
RUN apt-get update && apt-get install -y --no-install-recommends \
      less git procps sudo fzf zsh man-db unzip gnupg2 gh iptables ipset dnsmasq iproute2 conntrack libcap2-bin \
      dnsutils aggregate jq nano vim curl wget ca-certificates tmux libimage-exiftool-perl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node 22 (Claude Code requires engines.node >=22; Codex >=16).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Geospatial system libraries IN BASE: every SpaDES module depends on terra.
# ⚠️ Ubuntu's own GDAL only — P3M binary R packages are built against it; never add the ubuntugis PPA.
# libmagick++-dev and libglpk-dev are runtime deps of P3M binaries (magick via SpaDES.project, igraph), so they live in base.
# libglpk-dev: the igraph P3M binary (SpaDES.core dep) links libglpk.so.40.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgdal-dev gdal-bin libgeos-dev libproj-dev libudunits2-dev libsqlite3-dev \
      libcurl4-openssl-dev libssl-dev libxml2-dev \
      libfontconfig1-dev libharfbuzz-dev libfribidi-dev libfreetype6-dev \
      libpng-dev libtiff5-dev libjpeg-dev cmake libmagick++-dev \
      libglpk-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# RStudio Server, pinned and verified (a mismatch fails the build). Installed here, STARTED only where the
# owner set RSTUDIO=1 (agent-rstudio, as the agent; never root). Posit's jammy build is its noble build too.
# EARLY in base (right after the system libraries, before anything that changes often): the ~1.3 GB layer
# stays cached across base edits and is one shared layer under gis and bio.
# NOT rocker's install_rstudio.sh: it adds s6, a `rstudio` user (collides with uid 1000) and a system git
# credential helper. The package's postinst may start the server once, which mints a secure-cookie-key and
# a database: the images are public, so that state is deleted (ours lives in /var/lib/rstudio-agent,
# created per container).
# GitHub Copilot's bundled language server (~0.84 GB) is DELETED in this same layer (owner decision
# 2026-10-10: size; Copilot is also off in rsession.conf + rstudio-prefs.json). It must be this RUN: a
# later layer would hide the files but still ship their bytes. The build fails if the directory is not
# where we expect (a version bump that moves it must be looked at), or if any Copilot file is left in bin/.
# Quarto stays: it carries the pandoc RStudio uses to knit R Markdown (bin/quarto/bin/tools).
RUN deb="rstudio-server-$(echo "$RSTUDIO_VERSION" | tr + -)-amd64.deb" \
    && curl -fsSL "https://download2.rstudio.org/server/jammy/amd64/$deb" -o "/tmp/$deb" \
    && echo "${RSTUDIO_SHA256}  /tmp/$deb" | sha256sum -c - \
    && apt-get update && apt-get install -y --no-install-recommends "/tmp/$deb" \
    && apt-get clean && rm -rf /var/lib/apt/lists/* "/tmp/$deb" \
    && rm -rf /var/lib/rstudio-server/secure-cookie-key /var/lib/rstudio-server/session-rpc-key \
              /var/lib/rstudio-server/rstudio-os.sqlite* /var/run/rstudio-server /var/log/rstudio \
    && copilot=/usr/lib/rstudio-server/bin/copilot-language-server-js \
    && { [ -d "$copilot" ] || { echo "Copilot language server not at $copilot: check this RStudio version's layout"; exit 1; }; } \
    && rm -rf "$copilot" \
    && left="$(find /usr/lib/rstudio-server/bin -maxdepth 2 -iname '*copilot*')" \
    && { [ -z "$left" ] || { echo "Copilot files left after removal: $left"; exit 1; }; } \
    && { find /usr/lib/rstudio-server/bin/quarto -name pandoc -type f -perm -u+x | grep -q . \
         || { echo "no pandoc under RStudio's Quarto: R Markdown knitting would break"; exit 1; }; } \
    && mkdir -p /etc/R

# R bootstrap ONLY: enough to run setupProject(). Everything else is provisioned per project
# by setupProject(standAlone = TRUE), which hides the site library anyway.
RUN Rscript -e " \
  options(repos = c(PredictiveEcology = 'https://predictiveecology.r-universe.dev', \
                    CRAN = 'https://packagemanager.posit.co/cran/__linux__/noble/latest')); \
  install.packages(c('Require', 'SpaDES.project'), Ncpus = parallel::detectCores()); \
  stopifnot(all(c('Require', 'SpaDES.project') %in% rownames(installed.packages())))"

# uv, pinned (light Python tooling; reticulate::py_require()).
RUN curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz" -o /tmp/uv.tgz \
    && echo "${UV_SHA256}  /tmp/uv.tgz" | sha256sum -c - \
    && tar xzf /tmp/uv.tgz -C /tmp && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv \
    && rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu

# T3 Code, pinned and verified (a mismatch fails the build). Root-owned: the agent cannot swap it.
RUN curl -fsSL "https://github.com/pingdotgg/t3code/releases/download/v${T3_VERSION}/t3-${T3_VERSION}-linux-x64.tar.gz" -o /tmp/t3.tgz \
    && echo "${T3_SHA256}  /tmp/t3.tgz" | sha256sum -c - \
    && mkdir -p /opt/t3 && tar xzf /tmp/t3.tgz -C /opt/t3 && rm /tmp/t3.tgz \
    && ln -s "/opt/t3/t3-${T3_VERSION}-linux-x64/t3" /usr/local/bin/t3

# RStudio configuration (rserver.conf, rsession.conf, rstudio-prefs.json, ...): small and edited often, so
# copied late, never invalidating the install layer above.
COPY rstudio/ /etc/rstudio/

# Non-root user, fixed UID/GID 1000 (matches the WSL user for bind-mount ownership).
# EVERY named-volume mount point must exist here, agent-owned: a fresh volume copies the image dir's
# ownership, and a missing dir becomes root-owned (2026-10-07: ~/.claude was missing; plugins and
# settings could not be written). The CI 'fresh named volumes' step checks each one.
RUN groupadd --gid 1000 agent && useradd --uid 1000 --gid 1000 --create-home --shell /bin/zsh agent \
    && mkdir -p /workspace /etc/firewall/allowlist.d /usr/local/share/npm-global \
    && mkdir -p /home/agent/.local/share/R /home/agent/.local/share/rstudio /home/agent/.cache/R/Require /home/agent/.npm /home/agent/.claude /home/agent/.codex /home/agent/.t3 \
    && install -d -o agent -g agent -m 0700 /var/lib/rstudio-agent \
    && chown -R agent:agent /workspace /usr/local/share/npm-global /home/agent/.local /home/agent/.cache /home/agent/.npm /home/agent/.claude /home/agent/.codex /home/agent/.t3

# Firewall: init script + base allowlist (*.txt in allowlist.d; the project file is mounted read-only
# from the owner's host). sudo ONLY for the firewall script. dnsmasq runs as its own unprivileged
# system user: the firewall lets ONLY that uid reach the upstream resolver.
RUN getent passwd dnsmasq >/dev/null \
    || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin dnsmasq
COPY init-firewall.sh /usr/local/bin/init-firewall.sh
COPY allowlist.d/ /etc/firewall/allowlist.d/
RUN chmod 0755 /usr/local/bin/init-firewall.sh \
    && echo "agent ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/agent-firewall \
    && chmod 0440 /etc/sudoers.d/agent-firewall

# PredictiveEcology/AI at the pinned commit: reading copy AND plugin marketplace source.
RUN git clone --quiet https://github.com/PredictiveEcology/AI.git /opt/reference/pe-ai \
    && git -C /opt/reference/pe-ai checkout --quiet "${PE_AI_COMMIT}" \
    && chown -R agent:agent /opt/reference
COPY agent-init.sh /usr/local/bin/agent-init.sh
COPY configure-claude-settings.js /usr/local/lib/agent/configure-claude-settings.js
COPY configure-codex-config.js /usr/local/lib/agent/configure-codex-config.js
COPY agent-entrypoint.sh /usr/local/bin/agent-entrypoint
COPY agent-t3.sh /usr/local/bin/agent-t3
COPY agent-rstudio.sh /usr/local/bin/agent-rstudio
COPY rstudio-auth.sh /usr/local/lib/agent/rstudio-auth
COPY rsession-agent.sh /usr/local/lib/agent/rsession-agent
RUN chmod 0755 /usr/local/bin/agent-init.sh /usr/local/bin/agent-entrypoint /usr/local/bin/agent-t3 /usr/local/bin/agent-rstudio \
      /usr/local/lib/agent/rstudio-auth /usr/local/lib/agent/rsession-agent \
    && chmod 0644 /etc/rstudio/rserver.conf /etc/rstudio/rsession.conf /etc/rstudio/agent-database.conf /etc/rstudio/file-locks \
         /etc/rstudio/rstudio-prefs.json

# Agent CLIs (Claude Code, Codex) are NOT in the image: the images are public and never redistribute
# vendor agent binaries (Claude Code is proprietary). The image carries only each tool's pinned,
# integrity-locked spec (agent-clis/<tool>: package.json, package-lock.json, install.conf);
# install-agent-cli installs it at container start into the container's own layer
# (/opt/<tool>/<lockfile hash>), from the shared, verified npm cache. To bump: see agent-clis/<tool>/package.json.
# To ADD an agent CLI: add agent-clis/<tool>/ (and its config step in agent-init.sh, its home volume in
# the compose seed + a dir below if it keeps state); this loop gives it /opt/<tool>, install-<tool>, its BIN.
COPY agent-clis/ /usr/local/lib/agent/clis/
COPY install-agent-cli.sh /usr/local/bin/install-agent-cli
COPY agent-cli-wrapper.sh /usr/local/lib/agent/agent-cli-wrapper
RUN chmod 0755 /usr/local/bin/install-agent-cli /usr/local/lib/agent/agent-cli-wrapper \
    && set -e && for d in /usr/local/lib/agent/clis/*/; do \
         t=$(basename "$d"); bin=$(sed -n 's/^BIN=//p' "$d/install.conf"); \
         [ -n "$bin" ] && [ -f "$d/package-lock.json" ] || { echo "incomplete agent CLI spec: $d"; exit 1; }; \
         sha256sum "$d/package-lock.json" | cut -c1-16 > "$d/INSTALL_ID"; \
         install -d -o agent -g agent "/opt/$t"; \
         ln -s install-agent-cli "/usr/local/bin/install-$t"; \
         ln -s /usr/local/lib/agent/agent-cli-wrapper "/usr/local/bin/$bin"; \
       done

USER agent
# A .zshrc stops zsh's first-run wizard; interactivecomments lets pasted `cmd  # note` lines work.
RUN printf '# agent-containers\nsetopt interactivecomments\n' > /home/agent/.zshrc
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude CODEX_HOME=/home/agent/.codex
# The pinned version is the only version: upgrades go through the lockfile and a rebuild.
# (Codex: check_for_update_on_startup = false, written by configure-codex-config.js.)
ENV DISABLE_AUTOUPDATER=1
# T3 Code product telemetry off (its PostHog host is not allowlisted either).
ENV T3CODE_TELEMETRY_ENABLED=false
# RStudio Server: the update check is desktop-only in its source; set anyway.
ENV RSTUDIO_DISABLE_CHECK_FOR_UPDATES=1
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/usr/local/share/npm-global/bin:$PATH SHELL=/bin/zsh EDITOR=nano
WORKDIR /workspace
EXPOSE 3773 8787
CMD ["/usr/local/bin/agent-entrypoint"]
