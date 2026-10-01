# syntax=docker/dockerfile:1
###############################################################################
# Orca headless server + Pi coding agent + NetBird agent peer
#
# Contents:
#   - Orca (stablyai/orca) from the official RPM into /opt/Orca
#     (the RPM postinstall links /usr/bin/orca-ide; deps incl. Xvfb are
#      declared by the RPM and resolved by microdnf)
#   - Node.js LTS (>= 22.19, what Pi requires) preinstalled
#   - Pi coding agent (@earendil-works/pi-coding-agent) preinstalled
#   - NetBird client (optional agent peer; enable via NETBIRD_ENABLED=1)
#
# Persistence is entirely via volumes at runtime (see docker-compose.yml):
#   - orca_home       -> /home/orca        Orca config/state + agent CLI creds
#   - orca_workspaces -> /data/workspaces  git repos and all worktrees
#   - netbird_state   -> /var/lib/netbird  WireGuard keys = peer identity
#
# Build:  docker build -t orca-server .
# Run:    docker compose up -d
#
# Note: ORCA_VERSION uses the Orca release version WITHOUT the "v" prefix
# (e.g. ORCA_VERSION=1.4.218 -> asset orca-ide-1.4.218.x86_64.rpm).
###############################################################################

########
# Args
########
# "latest" resolves the newest stablyai/orca release via the GitHub API at
# build time; or pin explicitly, e.g. ORCA_VERSION=1.4.218
ARG ORCA_VERSION=latest
# Pi requires Node >= 22.19.0
ARG NODE_VERSION=22.23.3
ARG PI_PACKAGE=@earendil-works/pi-coding-agent
ARG NETBIRD_VERSION=0.79.0


###############################################################################
# Stage orca: Rocky minimal + RPM runtime deps + Orca IDE
###############################################################################
FROM rockylinux:9-minimal AS orca

ARG TARGETARCH
ARG ORCA_VERSION

# Runtime libraries: everything the Orca RPM declares as dependencies
# (microdnf resolves them), plus tooling the rest of the image needs.
# xdotool/xclip live in EPEL -> enable it first.
RUN set -eux; \
    microdnf -y install epel-release || microdnf -y install \
      https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm; \
    microdnf -y install \
      gtk3 nss at-spi2-core libXScrnSaver libnotify \
      python3 python3-gobject xdotool xclip xdg-utils \
      xorg-x11-server-Xvfb \
      git git-lfs curl ca-certificates tar gzip xz which \
      hostname procps-ng shadow-utils util-linux findutils \
      iptables-nft iproute; \
    microdnf clean all; rm -rf /var/cache/dnf /var/cache/yum

# Resolve the release version, download the matching RPM, install it.
# The postinstall scriptlet creates /usr/bin/orca-ide; --nosignature because
# the RPM ships unsigned and microdnf has no --nogpgcheck.
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) RPM_ARCH=x86_64 ;; \
      arm64) RPM_ARCH=aarch64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "${ORCA_VERSION}" = "latest" ]; then \
      ORCA_VER="$(curl -fsSL --retry 3 \
        https://api.github.com/repos/stablyai/orca/releases/latest \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
        | sed 's/^v//')"; \
      test -n "${ORCA_VER}"; \
    else \
      ORCA_VER="${ORCA_VERSION#v}"; \
    fi; \
    echo "Installing Orca version ${ORCA_VER}"; \
    curl -fL --retry 3 \
      "https://github.com/stablyai/orca/releases/download/v${ORCA_VER}/orca-ide-${ORCA_VER}.${RPM_ARCH}.rpm" \
      -o /tmp/orca-ide.rpm; \
    ls -lh /tmp/orca-ide.rpm; \
    rpm -ivh --nosignature /tmp/orca-ide.rpm; \
    rm -f /tmp/orca-ide.rpm; \
    test -x /opt/Orca/resources/bin/orca-ide; \
    test -x /usr/bin/orca-ide; \
    /usr/bin/orca-ide --version | head -n1


###############################################################################
# Stage node: Node.js LTS tarball (NODE_VERSION is a plain build arg)
###############################################################################
FROM orca AS node

ARG NODE_VERSION

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) NODE_ARCH=x64 ;; \
      arm64) NODE_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
      | tar -xJ --strip-components=1 -C /usr/local; \
    node --version && npm --version


###############################################################################
# Stage pi: official npm install command (global, on PATH for orca user too)
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
# Stage netbird: client binary + its runtime deps
###############################################################################
FROM pi AS netbird

ARG TARGETARCH
ARG NETBIRD_VERSION

RUN set -eux; \
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
# Stage runtime: non-root user, entrypoint, persistence layout
###############################################################################
FROM netbird AS runtime

ARG TARGETARCH

RUN set -eux; \
    mkdir -p /data/workspaces /var/log/netbird; \
    groupadd --gid 1000 orca; \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash \
         --home-dir /home/orca orca; \
    chown -R orca:orca /data/workspaces; \
    # Pre-create XDG dirs as orca so nothing ever creates them root-owned
    install -d -o orca -g orca -m 700 \
      /home/orca/.config /home/orca/.cache /home/orca/.local

# LIBGL_ALWAYS_SOFTWARE=1: no GPU in a container, force software rendering.
# DISPLAY is NOT set - Orca starts its own Xvfb on :99 when none exists.
ENV HOME=/home/orca \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_PREFIX=/usr/local \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:$PATH \
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