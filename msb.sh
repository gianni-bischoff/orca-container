#!/usr/bin/env bash
# Thin wrapper around `msb` that loads .env first, because sandbox.yaml uses
# ${NAME} substitution and msb does not read .env files itself.
#
# Usage:
#   ./msb.sh create            # create + boot the sandbox (first start)
#   ./msb.sh attach            # run the default workload (entrypoint) via msb run
#   ./msb.sh logs              # sandbox logs (pairing URL, orca, netbird)
#   ./msb.sh netbird           # netbird status inside the sandbox
#   ./msb.sh stop | start | remove
set -euo pipefail
cd "$(dirname "$0")"

command -v msb >/dev/null 2>&1 || { echo "msb not found - install from https://install.microsandbox.dev" >&2; exit 1; }
[ -f .env ] || { echo ".env missing - copy env.example to .env first" >&2; exit 1; }

set -a
. ./.env
set +a
export PATH="$HOME/.local/bin:$PATH"

NAME=orca-server
IMAGE="${MSB_IMAGE:-ghcr.io/gianni-bischoff/orca-container:latest}"

case "${1:-help}" in
  create)
    msb create --conf sandbox.yaml --name "$NAME"
    echo "sandbox created; start the workload with: ./msb.sh attach"
    ;;
  attach)
    # msb run attaches to the sandbox and runs the configured workload
    # (our entrypoint). Ctrl+C detaches the CLI; run with SIGKILL safety.
    msb run --conf sandbox.yaml --name "$NAME"
    ;;
  logs)      msb logs "$NAME" ;;
  netbird)   msb exec "$NAME" -- netbird status ;;
  orca-log)  msb logs "$NAME" 2>/dev/null | grep -E "entrypoint|Orca|Bound|Pairing|netbird" ;;
  stop)      msb stop "$NAME" ;;
  start)     msb start "$NAME" ;;
  status)    msb status "$NAME" ;;
  remove)    msb remove "$NAME" --force ;;
  shell)     msb exec "$NAME" -- bash -l ;;
  *)
    cat <<EOF
Usage: ./msb.sh <command>
  create    create sandbox (persistent mounts under ./data)
  attach    boot + run entrypoint (foreground)
  start     start previously created sandbox
  stop      stop sandbox
  logs      show logs
  netbird   netbird status inside the sandbox
  status    sandbox status
  shell     shell into the sandbox
  remove    remove sandbox (data in ./data is kept)
EOF
    ;;
esac