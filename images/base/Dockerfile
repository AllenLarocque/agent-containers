# spades-base: everything every SpaDES agent container needs. See docs/specs/2026-10-03-agent-containers-design.md §3.1.
FROM rocker/r-ver:4.5.3@sha256:c3f39b365d1077fe24f8e9ab2742e352b6d3950897f51af1624a5bb5550c21c0

LABEL org.opencontainers.image.source="https://github.com/AllenLarocque/agent-containers" \
      org.opencontainers.image.description="spades-base: SpaDES agent container base (R, geospatial libs, egress firewall; Claude Code installs at container start)"

ARG TZ=America/Los_Angeles
ARG UV_VERSION=0.12.19
# sha256 of uv-x86_64-unknown-linux-gnu.tar.gz, from the release asset ...tar.gz.sha256 (a mismatch fails the build).
ARG UV_SHA256=23bf5552d220e0842b65c862097b2ebaeba0064b74eda5e565e77fd25969d8c8
ARG PE_AI_COMMIT=e7ae689751316dfe742f31b32d0d659accd0cc41
ENV TZ="$TZ" DEBIAN_FRONTEND=noninteractive

# OS + agent tooling. tmux: detached long runs. exiftool: photo metadata (field data).
RUN apt-get update && apt-get install -y --no-install-recommends \
      less git procps sudo fzf zsh man-db unzip gnupg2 gh iptables ipset dnsmasq iproute2 conntrack libcap2-bin \
      dnsutils aggregate jq nano vim curl wget ca-certificates tmux libimage-exiftool-perl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node 22 (Claude Code requires engines.node >=22).
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

# Non-root user, fixed UID/GID 1000 (matches the WSL user for bind-mount ownership).
# EVERY named-volume mount point must exist here, agent-owned: a fresh volume copies the image dir's
# ownership, and a missing dir becomes root-owned (2026-10-07: ~/.claude was missing; plugins and
# settings could not be written). The CI 'fresh named volumes' step checks each one.
RUN groupadd --gid 1000 agent && useradd --uid 1000 --gid 1000 --create-home --shell /bin/zsh agent \
    && mkdir -p /workspace /etc/firewall/allowlist.d /usr/local/share/npm-global /opt/claude-code \
    && mkdir -p /home/agent/.local/share/R /home/agent/.cache/R/Require /home/agent/.npm /home/agent/.claude \
    && chown -R agent:agent /workspace /usr/local/share/npm-global /opt/claude-code /home/agent/.local /home/agent/.cache /home/agent/.npm /home/agent/.claude

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
RUN chmod 0755 /usr/local/bin/agent-init.sh

# Claude Code is NOT in the image (it is proprietary; the images are public). The image carries only
# the pinned, integrity-locked spec; install-claude-code.sh installs it at container start into the
# container's own layer (/opt/claude-code/<lockfile hash>), from the shared, verified npm cache.
# To bump: see images/base/claude-code/package.json.
COPY claude-code/package.json claude-code/package-lock.json /usr/local/lib/agent/claude-code/
COPY install-claude-code.sh /usr/local/bin/install-claude-code
COPY claude-wrapper.sh /usr/local/bin/claude
RUN sha256sum /usr/local/lib/agent/claude-code/package-lock.json | cut -c1-16 \
      > /usr/local/lib/agent/claude-code/CLAUDE_CODE_ID \
    && chmod 0755 /usr/local/bin/install-claude-code /usr/local/bin/claude

USER agent
# A .zshrc stops zsh's first-run wizard; interactivecomments lets pasted `cmd  # note` lines work.
RUN printf '# agent-containers\nsetopt interactivecomments\n' > /home/agent/.zshrc
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
# The pinned version is the only version: upgrades go through the lockfile and a rebuild.
ENV DISABLE_AUTOUPDATER=1
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/usr/local/share/npm-global/bin:$PATH SHELL=/bin/zsh EDITOR=nano
WORKDIR /workspace
CMD ["sleep", "infinity"]
