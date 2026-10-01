#!/usr/bin/env bash
#
# Entrypoint for the Orca headless server container.
#
# 1. (optional) Start the NetBird daemon and register/connect this container
#    as an "agent peer" on the NetBird network (needs caps NET_ADMIN,
#    SYS_ADMIN, SYS_RESOURCE and /dev/net/tun - see docker-compose.yml).
# 2. exec the Orca server (`orca serve`) as the non-root `orca` user.
#
# Extra args are forwarded to `orca serve`, e.g.:
#   docker run ... orca-server --json
#
# Both processes are supervised here; SIGTERM/SIGINT (docker stop, forwarded
# by tini/init) stops Orca first, then the NetBird daemon.
set -uo pipefail

log()  { echo "[entrypoint] $*"; }
warn() { echo "[entrypoint] $*" >&2; }

ORCA_PORT="${ORCA_PORT:-6768}"
ORCA_ARGS=(serve --port "$ORCA_PORT")
[ -n "${ORCA_PAIRING_ADDRESS:-}" ] && ORCA_ARGS+=(--pairing-address "$ORCA_PAIRING_ADDRESS")
[ "${ORCA_MOBILE_PAIRING:-0}" = "1" ] && ORCA_ARGS+=(--mobile-pairing)

NETBIRD_PID=""
ORCA_PID=""

shutdown() {
  log "shutting down..."
  [ -n "$ORCA_PID" ]    && kill -TERM "$ORCA_PID"    2>/dev/null
  [ -n "$NETBIRD_PID" ] && kill -TERM "$NETBIRD_PID" 2>/dev/null
  wait 2>/dev/null
  exit 0
}
trap shutdown TERM INT

###############################################################################
# NetBird agent peer
###############################################################################
nb_status_connected() {
  netbird status 2>/dev/null | grep -q "Management: Connected"
}

netbird_start() {
  command -v netbird >/dev/null 2>&1 || { warn "netbird binary not found"; return 1; }

  # Persistent state (WireGuard keys, config, peer identity) lives in the
  # netbird_state volume -> the peer keeps its NetBird IP/FQDN across restarts.
  # Persistent state (WireGuard keys, config, peer identity) lives in the
  # netbird_state volume -> the peer keeps its NetBird IP/FQDN across restarts.
  # HOME is redirected so the root daemon never creates root-owned dirs
  # (e.g. ~/.config) inside the orca user's home - that broke the Orca
  # Electron "userData" preflight (could not write ~/.config).
  HOME=/var/lib/netbird netbird service run &
  NETBIRD_PID=$!

  # Wait until the daemon answers on its unix socket (same idea as the
  # official netbird container entrypoint).
  local waited=0
  while ! netbird status --check live >/dev/null 2>&1; do
    kill -0 "$NETBIRD_PID" 2>/dev/null || { warn "netbird daemon exited"; return 1; }
    waited=$((waited + 1))
    [ "$waited" -ge 30 ] && { warn "netbird daemon not live after 30s"; return 1; }
    sleep 1
  done

  if [ -n "${NETBIRD_SETUP_KEY:-}" ]; then
    # Pass the setup key via file instead of argv so it never shows up in
    # `ps` output inside the container. The file is removed only after the
    # registration attempts are done.
    local key_file=/run/netbird-setup-key
    (umask 077 && printf '%s' "$NETBIRD_SETUP_KEY" > "$key_file")
    local up_args=(up --setup-key-file "$key_file")

    # Register against YOUR management server, not the default api.netbird.io
    [ -n "${NETBIRD_MANAGEMENT_URL:-}" ] && up_args+=(--management-url "${NETBIRD_MANAGEMENT_URL}")
    [ -n "${NETBIRD_PEER_NAME:-}" ] && up_args+=(-n "${NETBIRD_PEER_NAME}")
    [ "${NETBIRD_DISABLE_DNS:-0}" = "1" ] && up_args+=(--disable-dns)
    [ -n "${NETBIRD_EXTRA_UP_FLAGS:-}" ] && up_args+=(${NETBIRD_EXTRA_UP_FLAGS})

    local attempt
    for attempt in 1 2 3; do
      # shellcheck disable=SC2086
      if netbird "${up_args[@]}"; then
        log "netbird: registered/connected ($(nb_status_connected && echo ok || echo 'see netbird status'))"
        rm -f "$key_file"
        return 0
      fi
      warn "netbird up failed (attempt ${attempt}/3)"
      sleep 5
    done
    rm -f "$key_file"
    return 1
  elif nb_status_connected; then
    # No key env in this run, but the daemon auto-connected with the config
    # persisted in /var/lib/netbird -> same peer identity as before.
    log "netbird: connected with persisted config"
    return 0
  else
    warn "NETBIRD_SETUP_KEY is not set and no persisted NetBird config exists - skipping registration"
    return 1
  fi
}

if [ "${NETBIRD_ENABLED:-0}" = "1" ]; then
  # Heal any root-owned dirs a previous bug left inside the orca home
  # (Electron refuses to start if it cannot write its userData = ~/.config).
  chown -R orca:orca /home/orca/.config /home/orca/.cache /home/orca/.local 2>/dev/null || true
  log "netbird: daemon enabled (management: ${NETBIRD_MANAGEMENT_URL:-https://netbird.wildblood.dev})"
  netbird_start || warn "netbird not connected - continuing with Orca only"
else
  log "netbird disabled (set NETBIRD_ENABLED=1 to register this peer)"
fi

###############################################################################
# Orca server
###############################################################################
# RPM installs the Electron binary at /opt/Orca/orca-ide and links the
# launcher to /usr/bin/orca-ide; headless start is documented as
# `orca-ide serve ...`.
ORCA_BIN="${ORCA_BIN:-/usr/bin/orca-ide}"
log "starting orca: ${ORCA_BIN} ${ORCA_ARGS[*]}${*:+ $*}"
runuser -u orca -- \
  env HOME=/home/orca \
      PATH="$PATH" \
      TERM="${TERM:-xterm-256color}" \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      LIBGL_ALWAYS_SOFTWARE=1 \
      NPM_CONFIG_UPDATE_NOTIFIER=false \
      "${ORCA_BIN}" "${ORCA_ARGS[@]}" "$@" &
ORCA_PID=$!

wait "$ORCA_PID"
rc=$?
log "orca exited with code $rc"
[ -n "$NETBIRD_PID" ] && kill -TERM "$NETBIRD_PID" 2>/dev/null
exit "$rc"