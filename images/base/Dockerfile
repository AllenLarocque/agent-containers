# spades-base: everything every SpaDES agent container needs. See docs/specs/2026-10-03-agent-containers-design.md §3.1.
FROM rocker/r-ver:4.5.3@sha256:c3f39b365d1077fe24f8e9ab2742e352b6d3950897f51af1624a5bb5550c21c0

LABEL org.opencontainers.image.source="https://github.com/AllenLarocque/agent-containers" \
      org.opencontainers.image.description="spades-base: SpaDES agent container base (R, geospatial libs, Claude Code, egress firewall)"

ARG TZ=America/Los_Angeles
ARG CLAUDE_CODE_VERSION=2.1.289
ARG UV_VERSION=0.12.19
ARG PE_AI_COMMIT=e7ae689751316dfe742f31b32d0d659accd0cc41
ENV TZ="$TZ" DEBIAN_FRONTEND=noninteractive

# OS + agent tooling. tmux: detached long runs. exiftool: photo metadata (field data).
RUN apt-get update && apt-get install -y --no-install-recommends \
      less git procps sudo fzf zsh man-db unzip gnupg2 gh iptables ipset dnsmasq iproute2 \
      dnsutils aggregate jq nano vim curl wget ca-certificates tmux libimage-exiftool-perl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Node 22 (Claude Code requires engines.node >=22).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Geospatial system libraries IN BASE: every SpaDES module depends on terra.
# ⚠️ Ubuntu's own GDAL only — P3M binary R packages are built against it; never add the ubuntugis PPA.
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
    && tar xzf /tmp/uv.tgz -C /tmp && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv \
    && rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu

# Non-root user, fixed UID/GID 1000 (matches the WSL user for bind-mount ownership).
RUN groupadd --gid 1000 agent && useradd --uid 1000 --gid 1000 --create-home --shell /bin/zsh agent \
    && mkdir -p /workspace /etc/firewall/allowlist.d /usr/local/share/npm-global \
    && chown -R agent:agent /workspace /usr/local/share/npm-global

# Firewall: init script + base allowlist (*.txt in allowlist.d; project files mount alongside). sudo ONLY for the firewall script.
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

USER agent
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=/usr/local/share/npm-global/bin:$PATH SHELL=/bin/zsh EDITOR=nano
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
WORKDIR /workspace
CMD ["sleep", "infinity"]
