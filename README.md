# gluetun-qbt-watchdog

A lightweight Docker container that keeps [Gluetun](https://github.com/qdm12/gluetun) VPN port forwarding and [qBittorrent](https://github.com/qbittorrent/qBittorrent) in sync — automatically.

## The Problem

If you're running Gluetun with ProtonVPN (especially WireGuard) for port forwarding, you've probably hit this: every few hours, the NAT-PMP port renewal fails silently. Gluetun revokes the port, gets stuck at `[port forwarding] starting`, and your torrents stop working. The VPN tunnel stays healthy, so Docker thinks everything is fine — but port forwarding is dead.

This is a [well-known issue](https://github.com/qdm12/gluetun/issues/1891) affecting many users. Common workarounds like `VPN_PORT_FORWARDING_UP_COMMAND`, healthchecks, and autoheal containers each solve part of the problem but create new failure modes (race conditions, zombie processes, broken network namespaces).

**Related issues:**
- [qdm12/gluetun#1891](https://github.com/qdm12/gluetun/issues/1891) — Port forwarding stops, stuck in restart loop
- [qdm12/gluetun#1749](https://github.com/qdm12/gluetun/issues/1749) — NAT-PMP doesn't recover after internal VPN restart
- [qdm12/gluetun#1882](https://github.com/qdm12/gluetun/issues/1882) — Port connection lost after 10-15 minutes
- [qdm12/gluetun#2679](https://github.com/qdm12/gluetun/issues/2679) — Port forwarding connection refused
- [qdm12/gluetun#3196](https://github.com/qdm12/gluetun/issues/3196) — Port changing every minute with WireGuard
- [qdm12/gluetun#3079](https://github.com/qdm12/gluetun/issues/3079) — Timeout on port forwarding with both WireGuard and OpenVPN
- [qdm12/gluetun#2528](https://github.com/qdm12/gluetun/issues/2528) — WireGuard port forwarding fails while OpenVPN works

## The Solution

One container that replaces all the band-aids. Every N seconds it:

1. **Checks** Gluetun's forwarded port via the HTTP control API
2. **Recovers** if the port is missing — first by restarting the VPN internally (no container restart, so qBittorrent keeps its network), then by restarting containers as a last resort
3. **Syncs** the port to qBittorrent if there's a mismatch
4. **Logs** a heartbeat every N cycles so you know it's alive

```
2026-03-19 09:29:04 WARNING: Port mismatch: gluetun=47830, qbt=34987. Fixing...
2026-03-19 09:29:07 Port synced successfully: 47830
2026-03-19 09:34:14 OK: gluetun=47830, qbt=47830
2026-03-19 09:39:21 OK: gluetun=47830, qbt=47830
2026-03-19 15:01:45 WARNING: No forwarded port from gluetun. Attempting VPN restart...
2026-03-19 15:02:03 New port after recovery: 52194
2026-03-19 15:02:06 WARNING: Port mismatch: gluetun=52194, qbt=47830. Fixing...
2026-03-19 15:02:09 Port synced successfully: 52194
```

## What You Can Remove

If you're currently using any of these workarounds, you can remove them:

- `VPN_PORT_FORWARDING_UP_COMMAND` / `VPN_PORT_FORWARDING_DOWN_COMMAND` on Gluetun
- Docker healthchecks on Gluetun / qBittorrent
- `willfarrell/autoheal` or similar auto-restart containers
- Cron jobs that check port files or restart containers

## Quick Start

### 1. Generate a Gluetun API key

```bash
docker run --rm qmcgaw/gluetun genkey
```

### 2. Create your `.env` file

```bash
cp .env.example .env
```

Edit `.env` with your values:

```env
# Gluetun control server API key (generated above)
GLUETUN_API_KEY=YourGeneratedKeyHere

# qBittorrent Web UI credentials
QBT_USER=admin
QBT_PASS=yourpassword
```

### 3. Create the watchdog directory

Place the `Dockerfile` and `gluetun-qbt-watchdog.sh` in a directory next to your `docker-compose.yml`:

```
your-stack/
├── docker-compose.yml
├── .env
└── gluetun-qbt-watchdog/
    ├── Dockerfile
    └── gluetun-qbt-watchdog.sh
```

### 4. Configure Gluetun's control server

Add this to your Gluetun service environment in `docker-compose.yml`:

```yaml
environment:
  # ... your existing gluetun env vars ...
  - HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE={"auth":"apikey","apikey":"${GLUETUN_API_KEY}"}
```

> **Note:** You do NOT need `VPN_PORT_FORWARDING_UP_COMMAND` or `VPN_PORT_FORWARDING_DOWN_COMMAND`. The watchdog handles everything.

### 5. Add the watchdog to your compose file

```yaml
gluetun-qbt-watchdog:
  build: ./gluetun-qbt-watchdog
  container_name: gluetun-qbt-watchdog
  restart: unless-stopped
  networks:
    - vpn-net          # same network as gluetun, NOT network_mode: service:gluetun
  depends_on:
    - gluetun
    - qbittorrent
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock   # only used for last-resort container restarts
  environment:
    - GLUETUN_API=http://gluetun:8000
    - GLUETUN_API_KEY=${GLUETUN_API_KEY}
    - GLUETUN_CONTAINER_NAME=gluetun
    - QBT_API=http://gluetun:8075
    - QBT_USER=${QBT_USER}
    - QBT_PASS=${QBT_PASS}
    - QBT_CONTAINER_NAME=qbittorrent
    - CHECK_INTERVAL=60
    - HEARTBEAT_EVERY=10
    - TZ=Europe/Amsterdam
```

### 6. Start it

```bash
docker compose up -d --build
```

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `GLUETUN_API` | `http://gluetun:8000` | Gluetun HTTP control server URL |
| `GLUETUN_API_KEY` | *(required)* | API key for Gluetun control server |
| `GLUETUN_CONTAINER_NAME` | `gluetun` | Docker container name to restart for Gluetun recovery |
| `QBT_API` | `http://gluetun:8075` | qBittorrent Web UI URL |
| `QBT_USER` | `admin` | qBittorrent username |
| `QBT_PASS` | *(required)* | qBittorrent password |
| `QBT_CONTAINER_NAME` | `qbittorrent` | Docker container name to restart for qBittorrent recovery |
| `CHECK_INTERVAL` | `60` | Seconds between checks |
| `HEARTBEAT_EVERY` | `10` | Log an "OK" message every N checks |
| `MAX_RESTART_WAIT` | `120` | Max seconds to wait for port after container restart |

> **Tip:** `CHECK_INTERVAL=60` with `HEARTBEAT_EVERY=10` gives you an "OK" log every 10 minutes. Adjust to your preference.

## How It Works

The watchdog runs on a **separate Docker network** (not `network_mode: service:gluetun`). This is critical — if it shared Gluetun's network namespace, it would lose connectivity when Gluetun restarts.

### Recovery escalation

```
Port missing?
  │
  ├─→ Step 1: Restart VPN via Gluetun API (PUT /v1/vpn/status)
  │           This restarts the VPN tunnel WITHOUT restarting the container.
  │           qBittorrent and other containers keep their network.
  │
  ├─→ Step 2: If still no port after 15s — full container restart
  │           docker restart $GLUETUN_CONTAINER_NAME $QBT_CONTAINER_NAME $ADDITIONAL_RESTART
  │           This is the nuclear option, only used when the API restart fails.
  │
  └─→ Step 3: If still no port after MAX_RESTART_WAIT — give up, retry next cycle
```

### Port sync

Every cycle, the watchdog compares Gluetun's forwarded port with qBittorrent's `listen_port`. If they differ, it updates qBittorrent via the Web API. This catches:

- Ports that changed during a VPN reconnect
- qBittorrent restarts that reset the port to 0
- Any other drift between the two

## Requirements

- **Gluetun** with `VPN_PORT_FORWARDING=on` and HTTP control server enabled (port 8000, default)
- **qBittorrent** with Web UI enabled
- Docker socket access (for last-resort container restarts)
- Both containers on a shared Docker network (the watchdog accesses qBittorrent through Gluetun's published port)

## Network Architecture

```
┌─────────────────────────────────────────────────────┐
│ vpn-net (Docker bridge network)                     │
│                                                     │
│  ┌───────────┐   ┌──────────────┐   ┌────────────┐  │
│  │ gluetun   │   │ qbittorrent  │   │ watchdog   │  │
│  │ :8000 API │   │ :8080 WebUI  │   │            │  │
│  │ :8080 ←── ┼───┤ (shares net) │   │ curl → API │  │
│  └───────────┘   └──────────────┘   └────────────┘  │
│       │              network_mode:                  │
│       │              service:gluetun                │
└───────┼─────────────────────────────────────────────┘
        │
   VPN tunnel → ProtonVPN → NAT-PMP port forwarding
```

qBittorrent uses `network_mode: "service:gluetun"` so it shares Gluetun's network namespace. The watchdog is on `vpn-net` independently — it talks to both via their published ports/DNS names.

## Password Special Characters

If your qBittorrent password contains special characters (`%`, `&`, `+`, etc.), the script handles this using `curl --data-urlencode`. No manual escaping needed — just put the raw password in your `.env` file:

```env
QBT_PASS=my%weird&password
```

## qBittorrent Password Recovery

If the watchdog cannot log in to qBittorrent with `QBT_PASS`, it will try to recover automatically:

1. Read the temporary password from the qBittorrent container logs
2. Log in with that temporary password
3. Update qBittorrent's Web UI password to the `QBT_PASS` value from your `.env`
4. Retry the normal login and continue the sync loop

This is especially helpful on first startup with `linuxserver/qbittorrent`, where qBittorrent may generate a one-time temporary password before you've set your own.

Because of this recovery path, the watchdog needs access to the Docker socket not only for last-resort container restarts, but also to read qBittorrent logs during password recovery.

If recovery fails, the watchdog logs a warning and skips that cycle instead of changing anything blindly.

## Adapting for Other Torrent Clients

The script is written for qBittorrent but the pattern works for any torrent client with a web API. You'd need to modify the `qbt_login`, `get_qbt_port`, and `set_qbt_port` functions. PRs welcome.

## Tested With

- Gluetun `latest` (v3.40+)
- ProtonVPN (WireGuard)
- qBittorrent (linuxserver/qbittorrent)
- TrueNAS SCALE + Docker
- Alpine 3.20 base image

## License

MIT — do whatever you want with it.
