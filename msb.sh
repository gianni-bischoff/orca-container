#!/usr/bin/env bash
# Thin wrapper around `msb` that loads .env first, because sandbox.yaml uses
# ${NAME} substitution and msb does not read .env files itself.
#
# Usage:
#   ./msb.sh up        # start Orca+NetBird in the background (detached)
#   ./msb.sh logs      # pairing URL + readiness
#   ./msb.sh netbird   # netbird status inside the sandbox
#   ./msb.sh stop      # stop the VM (data in ./data survives)
#   ./msb.sh start     # boot + run detached again (same as up)
#   ./msb.sh remove    # delete the sandbox definition (data in ./data kept)
set -euo pipefail
cd "$(dirname "$0")"

command -v msb >/dev/null 2>&1 || { echo "msb not found - install from https://install.microsandbox.dev" >&2; exit 1; }
[ -f .env ] || { echo ".env missing - copy env.example to .env first" >&2; exit 1; }

set -a
. ./.env
set +a
export PATH="$HOME/.local/bin:$PATH"

NAME=orca-server

case "${1:-help}" in
  up|start|run)
    # --detach runs the configured entrypoint in the background. On an
    # existing sandbox the creation flags are ignored and the stored config
    # is reused; the workload always starts (unlike plain `msb start`,
    # which boots an idle VM without the entrypoint).
    msb run --conf sandbox.yaml --name "$NAME" --detach
    echo
    echo "started: ./msb.sh logs   (pairing URL, readiness)"
    echo "status:  ./msb.sh netbird"
    ;;
  logs)      msb logs "$NAME" ;;
  log)       msb logs "$NAME" 2>/dev/null | grep -E "\[entrypoint\]|Orca server ready|Bound|Advertised|Pairing URL|ERRO|FATL" | tail -12 ;;
  netbird)   msb exec "$NAME" -- netbird status ;;
  status)    msb status "$NAME" ;;
  shell)     msb exec "$NAME" -- bash -l ;;
  stop)      msb stop "$NAME" ;;
  remove)    msb remove "$NAME" --force ;;
  *)
    cat <<EOF
Usage: ./msb.sh <command>
  up        start Orca + NetBird in the background (detached)  <-- main command
  logs      full sandbox logs
  log       filtered logs (pairing URL, readiness, errors)
  netbird   netbird status inside the microVM
  status    sandbox status
  shell     shell into the microVM
  stop      stop the microVM (data in ./data is kept)
  remove    remove the sandbox (data in ./data is kept)
EOF
    ;;
esac