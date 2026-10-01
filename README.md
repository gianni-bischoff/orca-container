# orca-container

Headless [Orca](https://www.onorca.dev) server (`orca serve`) with the
[Pi coding agent](https://pi.dev) preinstalled, joining your NetBird network as
its own peer. Published as an OCI image and run as either a Docker Compose
stack or a [microsandbox](https://microsandbox.dev) microVM.

## What's inside

- Orca from the official RPM (`/opt/Orca`, `orca-ide` on `PATH`)
- Pi coding agent (`@earendil-works/pi-coding-agent`) on `PATH`
- NetBird client as an optional agent peer (`NETBIRD_ENABLED=1`)
- Non-root runtime user (`orca`), Chromium sandbox intact
- Persistence: Orca state, workspaces, NetBird peer identity

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Rocky 9 minimal + Orca RPM + Node + Pi + NetBird |
| `docker-compose.yml` | Docker variant: volumes, caps, `/dev/net/tun`, port 6768 |
| `sandbox.yaml` | microsandbox (msb) variant: same image as a microVM |
| `msb.sh` | Wrapper: loads `.env`, creates/attaches/logs the `orca-server` sandbox |
| `docker-entrypoint.sh` | Starts the NetBird daemon (root), then `orca serve` as `orca` |
| `env.example` | Template; copy to `.env` (gitignored) and fill in your setup key |
| `.github/workflows/build.yml` | Build on new tag → amd64 → push to GHCR |

### Persistence (both variants)

| Data | Docker (named volume) | microsandbox (bind mount in gitignored `data/`) |
| --- | --- | --- |
| Orca state / agent creds | `orca_home` | `./data/orca-home` → `/home/orca` |
| Repos & worktrees | `orca_workspaces` | `./data/workspaces` → `/data/workspaces` |
| NetBird peer identity | `netbird_state` | `./data/netbird-state` → `/var/lib/netbird` |

## Docker Compose usage

```bash
cp env.example .env && $EDITOR .env     # set NETBIRD_SETUP_KEY
docker compose up -d --build
docker compose logs orca                # pairing URL
docker exec -it orca-server netbird status
```

## microsandbox (microVM) usage

Requires `msb` (https://install.microsandbox.dev) and KVM.

```bash
cp env.example .env && $EDITOR .env
./msb.sh create                 # registers the sandbox (persistent mounts)
./msb.sh attach                 # boots + runs the entrypoint (foreground)
# other window / after Ctrl+C:
./msb.sh logs                   # pairing URL + readiness
./msb.sh netbird                # peer status inside the sandbox
./msb.sh shell                  # shell into the microVM
./msb.sh stop | start | remove  # data in ./data survives all of these
```

The sandbox needs `${ORCA_PAIRING_ADDRESS}`, `${NETBIRD_SETUP_KEY}` and
`${NETBIRD_MANAGEMENT_URL}` in the shell — `msb.sh` sources `.env` for you.
Peer identity lives in `./data/netbird-state`, so after first registration
the sandbox reconnects without the setup key being consumed again (a
single-use key is only needed once per identity).

## Image

```bash
docker pull ghcr.io/gianni-bischoff/orca-container:latest
```

Tags mirror the repo tag (`latest`, `1.0.0`, `1.0`, `v1.0.0`) — the pipeline
builds against the matching Orca release when the tag names one
(repo tag `v1.2.3` → Orca RPM `1.2.3`).

## Security notes

- The NetBird setup key (`NETBIRD_SETUP_KEY`) is a credential: keep it in
  `.env` only. It is passed to the daemon via file, never argv.
- `./data/` holds agent credentials and WireGuard keys — it is gitignored
  and must never be committed or shared.
- The compose stack needs `NET_ADMIN` + `SYS_ADMIN` + `SYS_RESOURCE` caps
  and `/dev/net/tun`. The microsandbox variant isolates networking in the
  microVM instead (policy `public`); NetBird runs userspace there if the
  guest kernel lacks WireGuard.
- Keep clients on a private path (NetBird, Tailscale, LAN) and do not
  expose port 6768 publicly.
- Orca pairing URLs grant runtime access — treat them like passwords.