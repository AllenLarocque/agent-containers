# spades-fetcher: the paper fetcher. spades-base plus a headed Chromium (Playwright), a virtual display and
# the fetch engine. No agent: the entry point never runs agent-init, T3 or any agent CLI (base's files are
# inherited, never started). Spec: docs/specs/2026-11-16-paper-fetcher-design.md ("B. A fetcher container").
# Built FROM spades-base by registry digest (scripts/build-publish.sh), like gis and bio.
#
# Chromium's sandbox stays ON. It needs user namespaces, which Docker's default seccomp profile blocks:
# the container runs with project-template/config/fetcher-seccomp.json (Docker's default plus clone,
# setns, unshare). Nothing in this image turns the sandbox off.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-base:latest
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.description="spades-fetcher: spades-base plus a sandboxed headed Chromium (Playwright) and the paper fetch engine; no agent"
USER root

# The display and the owner's view (the viewer is started only when /etc/fetcher/view-password exists).
# apt unpinned, as everywhere in this repo: the weekly rebuild takes security patches.
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb x11vnc novnc websockify \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The engine's dependencies: exactly the committed lockfile (integrity-checked by npm), production only,
# no install scripts. The Playwright version pinned in package.json is the only version.
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
COPY engine/package.json engine/package-lock.json /opt/fetcher/
RUN cd /opt/fetcher && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && npm cache clean --force && rm -rf /root/.npm \
    && chmod -R a+rX,go-w /opt/fetcher

# Playwright's Chromium for that version, with its system libraries (apt, unpinned like the rest), and no
# headless shell (the fetcher runs headed). Playwright does not verify what it downloads, so the build
# does: CHROMIUM_TREE_SHA256 is the sha256 of the sorted `sha256sum` list of every file and symlink in the
# installed browser directory (Playwright's own marker files excluded). A mismatch fails the build and
# prints the value it got. To bump: change playwright in engine/package.json and package-lock.json, build,
# cross-check the new value against the same directory in Microsoft's mcr.microsoft.com/playwright:v<version>-noble
# image (run the find | sha256sum below over /ms-playwright/chromium-<revision>), set it here.
# 1.65.1 / Chromium 1255: the value below; it matched the playwright:v1.65.1-noble image
# (sha256:1507cbfc550a63a6b7396791ca4f00df17beb56342d2447b3f106c306f525579) on 2026-11-16.
# Playwright also fetches its ffmpeg (video recording, unused here): removed, not shipped.
ARG CHROMIUM_TREE_SHA256=9bb0ea4790158429d7414115ba9711671304b58f6bccd06973395665d4cb1dd3
RUN cd /opt/fetcher \
    && node node_modules/playwright/cli.js install --with-deps --no-shell chromium \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /root/.cache "$PLAYWRIGHT_BROWSERS_PATH"/ffmpeg-* \
    && rev=$(node -p 'require("./node_modules/playwright-core/browsers.json").browsers.find((b) => b.name === "chromium").revision') \
    && dir="$PLAYWRIGHT_BROWSERS_PATH/chromium-$rev" \
    && test -x "$dir/chrome-linux64/chrome" \
    && got=$(cd "$dir" && { find . -type f ! -name INSTALLATION_COMPLETE ! -name DEPENDENCIES_VALIDATED -print0 \
                              | LC_ALL=C sort -z | xargs -0 sha256sum; \
                            find . -type l -printf '%p -> %l\n' | LC_ALL=C sort; } | sha256sum | cut -d' ' -f1) \
    && { [ "$got" = "$CHROMIUM_TREE_SHA256" ] \
         || { echo "Chromium $rev tree sha256 is $got, expected $CHROMIUM_TREE_SHA256"; exit 1; }; } \
    && extra=$(find "$PLAYWRIGHT_BROWSERS_PATH" -mindepth 1 -maxdepth 1 ! -name "chromium-$rev" ! -name .links) \
    && { [ -z "$extra" ] || { echo "unexpected browser downloads: $extra"; exit 1; }; } \
    && chmod -R a+rX "$PLAYWRIGHT_BROWSERS_PATH"

# The engine itself (root-owned: the agent user cannot change it). No tests in the image. The engine and the
# entry point must not carry a sandbox opt-out (Playwright's own library does: it is what chromiumSandbox:
# false would add, which the engine never passes).
COPY engine/fetcher.mjs /opt/fetcher/fetcher.mjs
COPY engine/lib/ /opt/fetcher/lib/
COPY fetcher-entrypoint.sh /usr/local/bin/fetcher-entrypoint
COPY fetcherctl /usr/local/bin/fetcherctl
COPY fetcher-view /usr/local/bin/fetcher-view
# (Modes are set here and in the npm layer, not with a chmod -R over /opt/fetcher, which would copy
# node_modules into another layer.)
RUN chmod 0755 /usr/local/bin/fetcher-entrypoint /usr/local/bin/fetcherctl /usr/local/bin/fetcher-view \
    && chmod 0644 /opt/fetcher/fetcher.mjs && chmod -R a+rX,go-w /opt/fetcher/lib \
    && ! grep -rIl -e '--no-sandbox' -e FETCHER_TEST_SANDBOX /opt/fetcher/fetcher.mjs /opt/fetcher/lib \
           /usr/local/bin/fetcher-entrypoint /usr/local/bin/fetcherctl /usr/local/bin/fetcher-view

# Paths the engine uses (fetcher.mjs DEFAULTS). The profile volume mounts at /home/agent/.fetcher: it must
# exist agent-owned here, or a fresh volume comes up root-owned. /etc/fetcher holds the read-only config mount.
RUN install -d -o agent -g agent -m 0700 /home/agent/.fetcher /home/agent/.fetcher/profile /home/agent/.fetcher/state \
         /run/fetcher /tmp/fetcher-dl \
    && install -d -o agent -g agent -m 0755 /papers \
    && install -d -o root -g root -m 0755 /etc/fetcher

USER agent
ENV DISPLAY=:99
WORKDIR /home/agent
# Replaces base's CMD (agent-entrypoint, which starts agent-init and T3). Base sets no ENTRYPOINT.
CMD ["/usr/local/bin/fetcher-entrypoint"]
