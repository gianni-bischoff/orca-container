# orca-container

Headless [Orca](https://www.onorca.dev) server in Docker (`orca serve`) with the
[Pi coding agent](https://pi.dev) preinstalled, joining your NetBird network as
its own peer, and a GitHub Actions pipeline that builds and publishes the image
to GHCR on every new tag.

## What's inside

- Orca AppImage (extracted, `/opt/orca/app`) serving headless on port 6768
- Pi coding agent (`@earendil-works/pi-coding-agent`) on `PATH`
- NetBird client as an optional agent peer (`NETBIRD_ENABLED=1`)
- Non-root runtime user (`orca`), Chromium sandbox intact
- Persistence via named volumes: Orca state, workspaces, NetBird identity

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Rocky 9 minimal base + Xvfb/Electron libs + Node + Pi + NetBird + Orca |
| `docker-compose.yml` | Stack with volumes, caps, `/dev/net/tun`, port 6768 |
| `docker-entrypoint.sh` | Starts the NetBird daemon (root), then `orca serve` as `orca` |
| `env.example` | Template; copy to `.env` (gitignored) and fill in your setup key |
| `.github/workflows/build.yml` | Build on new tag → multi-arch → push to GHCR |

## Usage

```bash
cp env.example .env
$EDITOR .env                       # set NETBIRD_SETUP_KEY etc.
docker compose up -d --build
docker compose logs orca           # copy the Pairing URL into your Orca client
docker exec -it orca-server netbird status
```

Upgrades: bump `ORCA_VERSION` in `.env` or pull a new image tag; both keep the
named volumes (home, workspaces, NetBird identity) intact.

## Image

```bash
docker pull ghcr.io/gianni-bischoff/orca-container:latest
```

Tags mirror the repo tag (`latest`, `1.4.218`, `1.4`, `v1.4.218`) — the pipeline
builds against the matching Orca release when the tag names one.

## Security notes

- The NetBird setup key (`NETBIRD_SETUP_KEY`) is a credential: keep it in
  `.env` only. It is passed to the daemon via file, never argv.
- The container needs `NET_ADMIN` + `SYS_ADMIN` + `SYS_RESOURCE` caps and
  `/dev/net/tun` to join the WireGuard overlay.
- Remote Orca Servers are beta: keep clients on a private network path
  (NetBird, Tailscale, LAN) and do not expose port 6768 publicly.
- Orca pairing URLs grant runtime access — treat them like passwords.