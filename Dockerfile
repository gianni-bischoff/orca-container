# syntax=docker/dockerfile:1
###############################################################################
# Orca headless server + Pi coding agent + NetBird agent peer
#
# Contents:
#   - Orca (stablyai/orca) Linux AppImage, extracted to /opt/orca/app
#     (extracted on purpose: Docker containers usually have no /dev/fuse,
#      and the Orca docs recommend --appimage-extract for containers)
#   - Node.js LTS (>= 22.19, what Pi requires) preinstalled
#   - Pi coding agent (@earendil-works/pi-coding-agent) preinstalled
#   - Xvfb + the Electron/Chromium runtime libraries Orca needs headless
#   - NetBird client (optional agent peer; enable via NETBIRD_ENABLED=1)
#
# Persistence is entirely via volumes at runtime (see docker-compose.yml):
#   - orca_home       -> /home/orca        Orca config/state + agent CLI creds
#   - orca_workspaces -> /data/workspaces  git repos and all worktrees
#   - netbird_state   -> /var/lib/netbird  WireGuard keys = peer identity
#
# Build:  docker build -t orca-server .
# Run:    docker compose up -d
###############################################################################

########
# Args
########
# "latest", or pin a release tag, e.g. ORCA_VERSION=v1.4.218
ARG ORCA_VERSION=latest
# Pi requires Node >= 22.19.0
ARG NODE_VERSION=22.23.3
ARG PI_PACKAGE=@earendil-works/pi-coding-agent
ARG NETBIRD_VERSION=0.79.0


###############################################################################
# Base: Rocky 9 minimal + runtime libs for the Orca/Electron AppImage
###############################################################################
FROM rockylinux:9-minimal AS base

# Xvfb: Orca starts its own virtual display when no DISPLAY is set.
# The rest of the list covers everything Electron/Chromium dlopen's at startup
# (same set as the official headless docs, using EL9 package names).
# If you ever see GL/GPU-related crashes, also add:
#   mesa-dri-drivers mesa-libGL mesa-libEGL
RUN set -eux; \
    microdnf -y install epel-release || true; \
    microdnf -y install xvfb 2>/dev/null || microdnf -y install xorg-x11-server-Xvfb; \
    microdnf -y install \
      curl git git-lfs tar xz gzip ca-certificates \
      which findutils hostname procps-ng shadow-utils util-linux \
      fuse fuse-libs \
      gtk3 nss atk at-spi2-core cups-libs libdrm libxkbcommon \
      libXcomposite libXdamage libXfixes libXrandr libXcursor \
      libXScrnSaver libXtst libxshmfence alsa-lib mesa-libgbm \
      pango cairo fontconfig dejavu-sans-fonts; \
    microdnf clean all; \
    rm -rf /var/cache/dnf /var/cache/yum


###############################################################################
# Node.js: install from upstream tarball so NODE_VERSION is a plain build arg
###############################################################################
FROM base AS node

ARG TARGETARCH
ARG NODE_VERSION

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
      | tar -xJ --strip-components=1 -C /usr/local; \
    node --version && npm --version


###############################################################################
# Pi: official install command (globally, on PATH for the orca user too)
###############################################################################
FROM node AS pi

ARG PI_PACKAGE

RUN set -eux; \
    npm config set update-notifier false --global; \
    npm install -g --ignore-scripts "${PI_PACKAGE}"; \
    npm cache clean --force 2>/dev/null || true; \
    pi --version

ENV NPM_CONFIG_UPDATE_NOTIFIER=false


###############################################################################
# NetBird: client binary + the runtime deps the official image installs
###############################################################################
FROM pi AS netbird

ARG TARGETARCH
ARG NETBIRD_VERSION

RUN set -eux; \
    microdnf -y install iproute iptables-nft; \
    case "${TARGETARCH}" in \
      amd64) NB_ARCH=amd64 ;; \
      arm64) NB_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fL --retry 3 \
      "https://github.com/netbirdio/netbird/releases/download/v${NETBIRD_VERSION}/netbird_${NETBIRD_VERSION}_linux_${NB_ARCH}.tar.gz" \
      -o /tmp/netbird.tgz; \
    mkdir -p /tmp/netbird-extract; \
    tar -xzf /tmp/netbird.tgz -C /tmp/netbird-extract; \
    mv /tmp/netbird-extract/netbird /usr/local/bin/netbird; \
    rm -rf /tmp/netbird.tgz /tmp/netbird-extract; \
    chmod 0755 /usr/local/bin/netbird; \
    netbird version

ENV NB_LOG_FILE="console,/var/log/netbird/client.log" \
    NB_DAEMON_ADDR="unix:///var/run/netbird.sock" \
    NB_ENTRYPOINT_SERVICE_TIMEOUT=30


###############################################################################
# Runtime: Orca AppImage (extracted), non-root user, persistent-layout dirs
###############################################################################
FROM netbird AS runtime

ARG TARGETARCH
ARG ORCA_VERSION

# Download (latest or pinned) and extract once at build time. Running the
# extracted AppRun directly needs no FUSE and keeps `docker logs` clean.
RUN set -eux; \
    mkdir -p /opt/orca /var/log/netbird; \
    case "${TARGETARCH}" in \
      amd64) ORCA_ASSET=orca-linux.AppImage ;; \
      arm64) ORCA_ASSET=orca-linux-arm64.AppImage ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "$ORCA_VERSION" = "latest" ]; then \
      ORCA_URL="https://github.com/stablyai/orca/releases/latest/download/${ORCA_ASSET}"; \
    else \
      ORCA_URL="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/${ORCA_ASSET}"; \
    fi; \
    curl -fL --retry 3 "$ORCA_URL" -o /tmp/orca-linux.AppImage; \
    chmod +x /tmp/orca-linux.AppImage; \
    ls -lh /tmp/orca-linux.AppImage; \
    cd /opt/orca; \
    /tmp/orca-linux.AppImage --appimage-extract >/dev/null; \
    rm /tmp/orca-linux.AppImage; \
    chmod -R a+rX /opt/orca/squashfs-root; \
    mv /opt/orca/squashfs-root /opt/orca/app; \
    test -x /opt/orca/app/AppRun; \
    test -x /opt/orca/app/resources/bin/orca-ide; \
    ln -sfn /opt/orca/app/resources/bin/orca-ide /usr/local/bin/orca-ide; \
    /opt/orca/app/resources/bin/orca-ide --version | head -n1

# Non-root service user. Chromium's sandbox stays enabled; never run as root.
# /data/workspaces is the default workdir: mount your persistent workspace
# volume here so clones/worktrees survive restarts.
RUN groupadd --gid 1000 orca \
    && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash \
         --home-dir /home/orca orca \
    && mkdir -p /data/workspaces \
    && chown -R orca:orca /data/workspaces

# LIBGL_ALWAYS_SOFTWARE=1: no GPU in a container, force software rendering.
# DISPLAY is intentionally NOT set - Orca starts its own Xvfb on :99.
# PATH keeps /usr/local/bin first so the root entrypoint finds netbird and
# the orca user still gets node/npm/pi/orca-ide.
ENV HOME=/home/orca \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_PREFIX=/usr/local \
    PATH=/usr/local/bin:/opt/orca/app/resources/bin:$PATH \
    LIBGL_ALWAYS_SOFTWARE=1 \
    ORCA_PORT=6768

COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

WORKDIR /data/workspaces
EXPOSE 6768

# Readiness: `orca serve` binds ws://0.0.0.0:6768 and then prints its ready
# block; accept any HTTP response on the port as "listening".
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=5 \
  CMD node -e "const h=require('http');const p=+process.env.ORCA_PORT||6768;const r=h.get({host:'127.0.0.1',port:p,path:'/',timeout:3000},()=>process.exit(0));r.on('error',()=>process.exit(1));r.on('timeout',()=>{r.destroy();process.exit(1)})"

# Start as root: the entrypoint runs the NetBird daemon (needs NET_ADMIN and
# /dev/net/tun) and then drops privileges to `orca` for the Orca server.
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]