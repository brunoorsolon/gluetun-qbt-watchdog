# gluetun-qbt-watchdog

A lightweight Docker container that keeps [Gluetun](https://github.com/qdm12/gluetun) VPN port forwarding and [qBittorrent](https://github.com/qbittorrent/qBittorrent) in sync automatically.

## The Problem

When Gluetun port forwarding is enabled, NAT-PMP renewal can fail while the VPN tunnel stays up. Docker still sees the container as healthy, but qBittorrent loses its reachable listen port and torrent connectivity degrades.

Common workarounds such as `VPN_PORT_FORWARDING_UP_COMMAND`, Gluetun healthchecks, autoheal containers, or cron scripts each cover only part of the failure mode and can introduce race conditions or container restart problems.

Related Gluetun issues:

- [qdm12/gluetun#1891](https://github.com/qdm12/gluetun/issues/1891) — port forwarding stops, stuck in restart loop
- [qdm12/gluetun#1749](https://github.com/qdm12/gluetun/issues/1749) — NAT-PMP does not recover after internal VPN restart
- [qdm12/gluetun#1882](https://github.com/qdm12/gluetun/issues/1882) — port connection lost after 10-15 minutes
- [qdm12/gluetun#2679](https://github.com/qdm12/gluetun/issues/2679) — port forwarding connection refused
- [qdm12/gluetun#3196](https://github.com/qdm12/gluetun/issues/3196) — port changing every minute with WireGuard
- [qdm12/gluetun#3079](https://github.com/qdm12/gluetun/issues/3079) — timeout on port forwarding with WireGuard and OpenVPN
- [qdm12/gluetun#2528](https://github.com/qdm12/gluetun/issues/2528) — WireGuard port forwarding fails while OpenVPN works

## The Solution

Every cycle, the watchdog:

1. Reads Gluetun's forwarded port from the HTTP control API.
2. Requires a configurable number of confirmed missing-port checks and elapsed grace time before bounded Gluetun-only recovery. qBittorrent and other containers are never restarted or stopped.
3. Authenticates to qBittorrent using either API-key auth or legacy username/password auth.
4. Updates qBittorrent's `listen_port` when it differs from Gluetun's forwarded port.
5. Exposes `/healthz` for Uptime Kuma. Exhausted recovery produces one `ERROR UNRECOVERABLE` event per outage, not a stream of alerts.

Example logs:

```text
2026-03-19 09:29:04 INFO: Port mismatch: gluetun=47830, qbt=34987. Updating qBittorrent.
2026-03-19 09:29:06 INFO: Port synced successfully: 47830
2026-03-19 15:40:10 ERROR UNRECOVERABLE: port_missing_after_recovery; automatic restarts disabled; monitoring and port sync continue.
2026-03-19 16:00:12 INFO RECOVERED: Gluetun port 52194 is confirmed and qBittorrent matches; recovery budget rearmed.
```

## Quick Start

### 1. Generate a Gluetun API key

```bash
docker run --rm qmcgaw/gluetun genkey
```

Configure Gluetun's control server with that key:

```yaml
environment:
  - HTTP_CONTROL_SERVER_AUTH_DEFAULT_ROLE={"auth":"apikey","apikey":"${GLUETUN_API_KEY}"}
```

### 2. Configure qBittorrent authentication

For qBittorrent 5.2.0 / WebAPI 2.14.1+, API-key auth is preferred:

1. Open qBittorrent WebUI.
2. Go to Preferences → WebUI → API Key.
3. Generate an API key.
4. Set `QBT_API_KEY` in `.env`.

If you have not generated an API key yet, or you are using an older qBittorrent version, leave `QBT_API_KEY` empty and use `QBT_USER` / `QBT_PASS` instead.

### 3. Create `.env`

```bash
cp .env.example .env
```

Example:

```env
GLUETUN_API_KEY=YourGeneratedGluetunKeyHere

# Preferred for qBittorrent 5.2.0+
QBT_API_KEY=qbt_yourGeneratedQbitApiKeyHere
QBT_AUTH_MODE=auto

# Legacy fallback / first-start recovery
QBT_USER=admin
QBT_PASS=yourpassword
```

### 4. Add the watchdog service

Use the published GHCR image:

```yaml
gluetun-qbt-watchdog:
  image: ghcr.io/brunoorsolon/gluetun-qbt-watchdog:latest
  container_name: gluetun-qbt-watchdog
  restart: unless-stopped
  networks:
    - vpn-net
  depends_on:
    - gluetun
    - qbittorrent
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    - watchdog-state:/state
  # For Kuma on the host rather than vpn-net, optionally publish on loopback:
  # ports: ["127.0.0.1:8081:8081"]
  environment:
    - DOCKER_ENABLED=${DOCKER_ENABLED:-true}
    - GLUETUN_CONTAINER_NAME=${GLUETUN_CONTAINER_NAME:-gluetun}
    - GLUETUN_API=http://${GLUETUN_CONTAINER_NAME:-gluetun}:${GLUETUN_API_PORT:-8000}
    - GLUETUN_API_KEY=${GLUETUN_API_KEY}
    - QBT_CONTAINER_NAME=${QBT_CONTAINER_NAME:-qbittorrent}
    - QBT_API=http://${GLUETUN_CONTAINER_NAME:-gluetun}:${QBT_WEBUI_PORT:-8080}
    - QBT_API_KEY=${QBT_API_KEY:-}
    - QBT_AUTH_MODE=${QBT_AUTH_MODE:-auto}
    - QBT_USER=${QBT_USER:-admin}
    - QBT_PASS=${QBT_PASS:-}
    - CHECK_INTERVAL=${CHECK_INTERVAL:-60}
    - PORT_MISS_THRESHOLD=${PORT_MISS_THRESHOLD:-3}
    - MISSING_PORT_GRACE=${MISSING_PORT_GRACE:-300}
    - GLUETUN_RECOVERY_GRACE=${GLUETUN_RECOVERY_GRACE:-300}
    - RESTART_COOLDOWN=${RESTART_COOLDOWN:-900}
    - MAX_VPN_RESTARTS=${MAX_VPN_RESTARTS:-2}
    - RESTART_GLUETUN_CONTAINER=${RESTART_GLUETUN_CONTAINER:-true}
    - STATE_DIR=/state
    - HEALTH_BIND=0.0.0.0
    - HEALTH_PORT=${HEALTH_PORT:-8081}
    - HEARTBEAT_CYCLE_FREQUENCY=${HEARTBEAT_CYCLE_FREQUENCY:-10}
```

Declare the named volume at the Compose file's top level:

```yaml
volumes:
  watchdog-state:
```

A complete example is available in [`docker-compose.yml.example`](docker-compose.yml.example). The persistent volume is essential: without it, recreating the watchdog loses its recovery budget and alert latch.

### 5. Pull the image

```bash
docker pull ghcr.io/brunoorsolon/gluetun-qbt-watchdog:latest
```

You can also pin a release tag once releases are published:

```yaml
image: ghcr.io/brunoorsolon/gluetun-qbt-watchdog:1.0.2
```

## Configuration

| Variable | Default | Description |
|---|---:|---|
| `DOCKER_ENABLED` | `true` | Set `false` for HTTP API-only operation: no Docker health inspection, container restart, or temporary-password recovery. Overrides `RESTART_GLUETUN_CONTAINER`; remove the Docker socket mount too. |
| `GLUETUN_CONTAINER_NAME` | `gluetun` | Docker container name for Gluetun; unused in API-only mode. |
| `GLUETUN_API` | `http://gluetun:8000` | Gluetun HTTP control API URL. |
| `GLUETUN_API_KEY` | empty | API key generated by `docker run --rm qmcgaw/gluetun genkey`. |
| `QBT_CONTAINER_NAME` | `qbittorrent` | Docker container name for qBittorrent; unused in API-only mode. |
| `QBT_API` | `http://gluetun:8080` | qBittorrent WebAPI URL. Use the Gluetun service when qBittorrent shares Gluetun's network namespace. |
| `QBT_API_KEY` | empty | qBittorrent 5.2.0+ API key. Preferred when available. |
| `QBT_AUTH_MODE` | `auto` | `auto`, `apikey`, or `password`. |
| `QBT_USER` | `admin` | qBittorrent username for legacy password auth. |
| `QBT_PASS` | empty | qBittorrent password for legacy password auth and first-start recovery. |
| `CHECK_INTERVAL` | `60` | Seconds between sync cycles. |
| `PORT_MISS_THRESHOLD` | `3` | Confirmed missing-port checks required before recovery. API errors neither increment nor reset the count; a valid port clears it. |
| `MISSING_PORT_GRACE` | `300` (5 minutes) | Seconds from the first confirmed missing port before recovery; the miss count must also pass. Also the deadline for persistent API/auth/sync failures to become an alert without restarting anything. |
| `GLUETUN_RECOVERY_GRACE` | `300` (5 minutes) | Seconds allowed for observed Gluetun recovery and after each watchdog restart attempt. Observed unhealthy/unknown health starts one fixed window per outage; it does not slide forward on each check. |
| `RESTART_COOLDOWN` | `900` (15 minutes) | Minimum seconds after a completed restart attempt before another VPN or Gluetun-container restart. Success and manual reset do not clear it. |
| `MAX_VPN_RESTARTS` | `2` | Maximum VPN API stop/start attempts per outage. Failed calls consume an attempt too. |
| `RESTART_GLUETUN_CONTAINER` | `true` | Allow one final Gluetun-only container restart after the VPN budget is exhausted. Set `false` to use API recovery only. |
| `STATE_DIR` | `/state` | Writable persistent directory for recovery counters, deadlines, and the alert latch. Mount a volume here; one watchdog per state volume. |
| `HEALTH_BIND` | `0.0.0.0` | Health server bind address inside the watchdog container. Restrict exposure to your monitoring network. |
| `HEALTH_PORT` | `8081` | HTTP port for `/healthz`. Match any Docker port mapping to this container port. |
| `HEARTBEAT_CYCLE_FREQUENCY` | `10` | Log an OK heartbeat every N successful cycles. |

## qBittorrent Authentication Modes

`QBT_AUTH_MODE=auto` is the recommended default:

- If `QBT_API_KEY` is set, the watchdog uses qBittorrent API-key auth with `Authorization: Bearer <QBT_API_KEY>`.
- If `QBT_API_KEY` is empty, the watchdog falls back to `QBT_USER` / `QBT_PASS` cookie login.

Other modes:

- `QBT_AUTH_MODE=apikey` requires `QBT_API_KEY` and never calls qBittorrent auth endpoints.
- `QBT_AUTH_MODE=password` always uses `QBT_USER` / `QBT_PASS`.

A configured but rejected API key is treated as a configuration error and does not silently fall back to the password. Leave `QBT_API_KEY` empty if you intentionally want password auth.

Password auth supports both legacy qBittorrent login success (`200` with `Ok.`) and qBittorrent 5.2.0 login success (`204 No Content`).

## qBittorrent Password Recovery

In password mode, if the watchdog cannot log in with `QBT_PASS`, it tries to recover automatically:

1. Read the temporary password from qBittorrent container logs.
2. Log in with that temporary password.
3. Update qBittorrent's WebUI password to `QBT_PASS`.
4. Retry normal login and continue the sync loop.

This is useful on first startup with `linuxserver/qbittorrent`, where qBittorrent may generate a temporary password before you set your own.

Password recovery is not used in API-key mode. If you are setting up a new qBittorrent 5.2.0 instance, you can start with password mode, generate an API key in the WebUI, then switch back to `QBT_AUTH_MODE=auto` with `QBT_API_KEY` set.

## Recovery Behavior

1. Keep checking every `CHECK_INTERVAL` seconds (default 60). A valid Gluetun port clears the missing-port timer/count and is synced to qBittorrent on that cycle. A mismatch is fixed through qBittorrent preferences, never by restarting containers.
2. Only a successful JSON API response with a numeric primary `port` of `0` counts as a missing port. Both the legacy `{"port":33061}` format and the current `{"port":33061,"ports":[33061]}` format are supported; the primary `port` is used for qBittorrent. Timeouts, HTTP errors (including authentication failures), malformed responses, and invalid ports preserve earlier missing-port history but never trigger restarts on that cycle. Persistent API or qBittorrent authentication/sync failures become an alert after `MISSING_PORT_GRACE`, not a reason to restart the VPN.
3. Require both `PORT_MISS_THRESHOLD` confirmed misses and `MISSING_PORT_GRACE` elapsed seconds. Five minutes is a trial default, not a proven Proton requirement.
4. Observe Gluetun's Docker health. Starting, unhealthy, restarting, or unknown health gets a fixed `GLUETUN_RECOVERY_GRACE` window. Repeated unhealthy checks do not extend it forever. After the window, a confirmed missing port can still justify recovery; unknown health is not itself evidence of VPN failure.
5. Attempt up to `MAX_VPN_RESTARTS` VPN API stop/start sequences. Each attempt consumes budget before any side effect, even if its API calls fail. A failed stop still gets a start request because the stop response may have been lost. Between attempts, both the post-restart grace and `RESTART_COOLDOWN` must expire. Normal checking and syncing continue throughout those waits.
6. If enabled, permit one final restart of **only Gluetun** after the VPN attempts fail. Allow another recovery grace window; if the port is still missing, latch `unrecoverable`. There are no further automatic restart attempts in that outage. qBittorrent and additional containers are never restarted or stopped.
7. While latched, silently keep checking and trying to sync. A valid forwarded port **and** confirmed matching qBittorrent port produce one `INFO RECOVERED` event and rearm the budget. Merely seeing a valid Gluetun port is insufficient if qBittorrent is still failing. The cooldown survives recovery.

For the simple “times until restart” lever, set `PORT_MISS_THRESHOLD=10` with `CHECK_INTERVAL=60`. Ten confirmed misses span roughly nine minutes from the first miss; increasing that threshold does not slow successful port syncing. Timers are checked on polling cycles, and HTTP/restart operations add their execution time.

With defaults and no additional Gluetun health delays, the approximate timeline from the first missing port is: first VPN restart at 5 minutes, second at 20 minutes, one Gluetun-container restart at 35 minutes, then a terminal alert at 40 minutes. Kuma can alert sooner because `/healthz` is already returning 503 during recovery. Set its retry tolerance accordingly.

**A Gluetun container restart still interrupts every app sharing its network namespace.** It can also leave dependent apps needing manual network recovery; this watchdog deliberately will not restart them. Set `RESTART_GLUETUN_CONTAINER=false` if that trade-off is unacceptable. A missing forwarded port is not a VPN leak detector.

### Persistent state and manual reset

Mount `watchdog-state:/state` (or your own persistent directory). Counters, cooldowns, and the terminal alert latch survive watchdog restarts/recreation. State contains no credentials and is never evaluated as shell code. Unwritable or invalid state makes the watchdog exit rather than restart Gluetun with a fresh budget; Kuma sees the endpoint disappear. For non-root execution, the mounted directory must be writable by the configured UID.

Timers use Linux boot-time uptime rather than wall-clock time. After a host reboot, the budget/latch are retained and active waits start afresh because timestamps from different boots cannot be compared. Health observations cannot eliminate races with Gluetun's internal recovery between checks.

After investigating an outage, explicitly rearm recovery without discarding the cooldown:

```bash
docker exec gluetun-qbt-watchdog touch /state/reset-request
```

Use your configured `STATE_DIR` if different. The next polling cycle consumes the request and starts a fresh missing-port window. Restarting the watchdog alone does **not** reset the budget. Do not delete the state volume as part of routine upgrades.

### Uptime Kuma and Dozzle/Gotify

Configure an HTTP monitor in Kuma:

- URL on the shared Docker network: `http://gluetun-qbt-watchdog:8081/healthz`.
- Accept **200 only**. It means both APIs were checked and the ports match. Startup, recovery, API/auth/sync failures, and the terminal state return **503** with a short JSON reason and attempt counters.
- Poll at your preferred interval (for example 60 seconds), tolerate transient failures using Kuma's retry settings, and disable repeated/resend notifications if you want only down/up transitions. Validate the actual notification behavior with a controlled outage.
- If checks stop updating, the endpoint returns 503 after `max(180, 3 × CHECK_INTERVAL)` seconds. If the watchdog or its HTTP server dies, the endpoint is unreachable; the main process also exits when it detects the server has died.
- The endpoint is read-only, contains no secrets, and does not log every request. It has no reset/control API. Keep it on a trusted monitoring network; do not expose it publicly. Host-side Kuma can use the optional loopback port mapping; remote Kuma needs an explicitly allowed LAN address/port instead.
- **Do not use this endpoint to trigger autoheal/container restarts.** It reports service health, not a command to replenish the recovery budget.

Replace the existing Dozzle rule (`message contains "Still no port" || message contains "permission denied"`) with this condition, scoped to the watchdog container:

```text
message contains "UNRECOVERABLE"
```

Only entry into the terminal state emits that marker. Continuing failures, changing reasons, endpoint requests, and watchdog restarts do not resend it. Docker permission errors are captured rather than repeatedly printed; a failed container-recovery attempt eventually produces `ERROR UNRECOVERABLE: docker_permission_denied; ...`. Other reason codes distinguish missing ports, API access, qBittorrent authentication/preferences, port-update failure, and restart API failures.

The latch is saved **before** the error is logged to favor at-most-once notification: a process crash in that tiny interval can lose the Dozzle event, but the persisted unhealthy state remains visible to Kuma. Successful recovery produces one `INFO RECOVERED` message. This guarantees bounded emission by the watchdog, not delivery/deduplication by the external notification services.

### Upgrading from 1.0.1 to 1.0.2

1. Add the persistent `/state` volume and configure the documented grace/cooldown settings. Keep `PORT_MISS_THRESHOLD` if already configured.
2. Remove `MAX_RESTART_WAIT` and `ADDITIONAL_RESTART`; they are obsolete and ignored with a startup warning. The interim `VPN_RESTART_COOLDOWN` name is also ignored; use `RESTART_COOLDOWN` for all restart attempts.
3. Deploy the new image and change the Dozzle condition together: 1.0.1 does not emit `UNRECOVERABLE`.
4. Add the Kuma monitor and test a transient failure, one terminal alert, silence during continued failure, and recovery notification.

The new image uses Python's standard library for HTTP monitoring and Tini for signal forwarding/reaping; qBittorrent API-key and legacy password/temporary-password recovery remain supported.

## Network Architecture

```text
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

qBittorrent usually uses `network_mode: "service:gluetun"`, so it shares Gluetun's network namespace. The watchdog is on `vpn-net` independently and talks to both services through Gluetun's exposed ports/DNS name.

## API-only Operation

Set `DOCKER_ENABLED=false` when the watchdog should communicate exclusively through HTTP APIs. This mode never invokes Docker, even when a login fails or the VPN restart budget is exhausted. It disables the container fallback regardless of `RESTART_GLUETUN_CONTAINER`. It skips Docker-health observation delays, including observations saved before switching modes; missing-port grace, post-restart grace, cooldowns, attempt budgets, and the terminal latch still apply.

For example, run just the watchdog against existing services without mounting the Docker socket:

```yaml
services:
  gluetun-qbt-watchdog:
    image: ghcr.io/brunoorsolon/gluetun-qbt-watchdog:latest
    restart: unless-stopped
    environment:
      DOCKER_ENABLED: "false"
      GLUETUN_API: "http://192.0.2.10:8000"
      GLUETUN_API_KEY: "${GLUETUN_API_KEY}"
      QBT_API: "http://192.0.2.10:8080"
      QBT_AUTH_MODE: "auto"
      QBT_API_KEY: "${QBT_API_KEY}"
      STATE_DIR: "/state"
    volumes:
      - watchdog-state:/state

volumes:
  watchdog-state:
```

Replace the example addresses with endpoints reachable from the watchdog. Configure trusted network access and API authentication; do not expose these APIs publicly. Set both URLs explicitly: the script defaults to `http://gluetun:8000` and `http://gluetun:8080`, independently of Docker container names. Connect your monitoring network as appropriate for your deployment.

Gluetun port queries and VPN stop/start requests, qBittorrent port syncing, and monitoring remain available. For older qBittorrent versions, replace the API-key settings with `QBT_AUTH_MODE=password`, `QBT_USER`, and a valid `QBT_PASS`. Failed credentials cannot be recovered from container logs in this mode; persistent authentication failures alert without restarting the VPN. There is no automatic switch to API-only mode when Docker access fails in Docker-enabled deployments.

## Docker Socket Access

With the default `DOCKER_ENABLED=true`, the watchdog mounts `/var/run/docker.sock` so it can:

- inspect Gluetun's health before considering VPN recovery
- restart only Gluetun once as the optional final recovery step
- read qBittorrent logs for legacy password recovery

Docker socket access allows container control from inside the watchdog container. Only run this in an environment where you trust the image and Compose configuration.

If you run the watchdog with a non-root `user:`, add the socket's group with `group_add` (find it with `stat -c %g /var/run/docker.sock`), or health inspection and password recovery fail with permission denied. Port syncing and VPN API recovery can still work without socket access, but health cannot be observed and the container fallback/password-log recovery cannot succeed. For intentionally socket-free operation, use `DOCKER_ENABLED=false` and remove the socket mount rather than relying on those failures.

## What You Can Remove

If the watchdog is working for your stack, you generally do not need:

- `VPN_PORT_FORWARDING_UP_COMMAND` / `VPN_PORT_FORWARDING_DOWN_COMMAND` on Gluetun
- Extra qBittorrent healthchecks solely for port-forward recovery (keep Gluetun's healthcheck)
- `willfarrell/autoheal` or similar auto-restart containers for this issue
- cron jobs that check port files or restart containers

## Local Build / Development

The recommended deployment uses GHCR. To build locally instead:

```yaml
gluetun-qbt-watchdog:
  build: ./gluetun-qbt-watchdog
```

The build context contains:

```text
gluetun-qbt-watchdog/
├── Dockerfile
├── gluetun-qbt-watchdog.sh
├── recovery.sh
└── health-server.py
```

Run deterministic recovery, authentication, persistence, and HTTP health checks with Python 3.9+ and `/bin/sh`. They use disposable fixtures and loopback HTTP, not production APIs or Docker:

```bash
python3 -m unittest discover -s tests -v
```

## Publishing / Releases

The GitHub Actions workflow publishes to:

```text
ghcr.io/brunoorsolon/gluetun-qbt-watchdog
```

Publishing behavior:

- Push to `main`: publishes `latest` and the branch tag.
- Push `v*.*.*`: publishes semver tags such as `1.2.3` and `1.2`.
- Manual dispatch: publishes tags derived from the selected ref.

After the first GHCR publish, make the package public in GitHub package settings if unauthenticated pulls should work.

## Requirements

- Gluetun with `VPN_PORT_FORWARDING=on` and HTTP control server enabled.
- qBittorrent with WebUI/WebAPI enabled.
- Docker socket access for health observation, optional Gluetun-container fallback, and legacy password-log recovery.
- A writable persistent state volume, with one watchdog instance per volume.
- Shared Docker network where the watchdog can reach Gluetun and qBittorrent WebAPI.

## Tested With

- Gluetun `latest` (v3.40+)
- ProtonVPN WireGuard port forwarding
- qBittorrent 5.2.0 / WebAPI 2.14.1+ API-key auth
- qBittorrent legacy username/password auth
- qBittorrent linuxserver image
- TrueNAS SCALE + Docker
- Alpine 3.20 base image

## Adapting for Other Torrent Clients

The script is written for qBittorrent, but the pattern works for any torrent client with a web API. You would need to modify the qBittorrent auth, port read, and port write helpers.

## License

MIT — do whatever you want with it.
