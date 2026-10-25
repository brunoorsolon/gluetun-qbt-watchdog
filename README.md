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
5. Exposes `/healthz` for strict port availability and `/readyz` for actionable Uptime Kuma alerts. Exhausted recovery produces one `ERROR UNRECOVERABLE` event per outage, not a stream of alerts.

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
    - WATCHDOG_API_KEY=${WATCHDOG_API_KEY:-}
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
image: ghcr.io/brunoorsolon/gluetun-qbt-watchdog:2.1.0
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
| `HEALTH_PORT` | `8081` | HTTP port for monitoring and the optional manual VPN restart endpoint. Match any Docker port mapping to this container port. |
| `WATCHDOG_API_KEY` | empty (control disabled) | Dedicated 64-character hexadecimal key for `POST /vpn/restart`, sent as `X-API-Key`. Generate independently of the Gluetun and qBittorrent keys. |
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

With defaults and no additional Gluetun health delays, the approximate timeline from the first missing port is: first VPN restart at 5 minutes, second at 20 minutes, one Gluetun-container restart at 35 minutes, then a terminal alert at 40 minutes. The strict `/healthz` endpoint already returns 503 during recovery. Use `/readyz` with 200 and 202 accepted to alert only when recovery is terminal or watchdog checks are unavailable.

**A Gluetun container restart still interrupts every app sharing its network namespace.** It can also leave dependent apps needing manual network recovery; this watchdog deliberately will not restart them. Set `RESTART_GLUETUN_CONTAINER=false` if that trade-off is unacceptable. A missing forwarded port is not a VPN leak detector.

### Persistent state and manual reset

Mount `watchdog-state:/state` (or your own persistent directory). Counters, cooldowns, and the terminal alert latch survive watchdog restarts/recreation. State contains no credentials and is never evaluated as shell code. Unwritable or invalid state makes the watchdog exit rather than restart Gluetun with a fresh budget; Kuma sees the endpoint disappear. For non-root execution, the mounted directory must be writable by the configured UID.

Timers use Linux boot-time uptime rather than wall-clock time. After a host reboot, the budget/latch are retained and active waits start afresh because timestamps from different boots cannot be compared. Health observations cannot eliminate races with Gluetun's internal recovery between checks.

After investigating an outage, explicitly rearm recovery without discarding the cooldown:

```bash
docker exec gluetun-qbt-watchdog touch /state/reset-request
```

Use your configured `STATE_DIR` if different. The next polling cycle consumes the request and starts a fresh missing-port window. Restarting the watchdog alone does **not** reset the budget. Do not delete the state volume as part of routine upgrades.

### Manually restart only the VPN

The optional `POST /vpn/restart` endpoint uses Gluetun's VPN stop/start API. It never restarts a container and also works with `DOCKER_ENABLED=false`. Leave `WATCHDOG_API_KEY` empty to disable it (404); monitoring remains available without authentication.

1. Generate a dedicated random key locally:

   ```bash
   python3 -c 'import secrets; print(secrets.token_hex(32))'
   ```

2. Store the result as `WATCHDOG_API_KEY` in your private `.env` and recreate the watchdog with the environment mapping shown above. A nonempty key must contain exactly 64 hexadecimal characters; invalid configuration fails startup without printing the key. Keep the key out of Git, logs, and shared Compose output.

3. From a client shell, enter the same key and send an empty POST. This host example requires the optional loopback port mapping:

   ```bash
   read -r -s -p 'Watchdog API key: ' WATCHDOG_API_KEY; printf '\n'
   printf 'X-API-Key: %s\n' "$WATCHDOG_API_KEY" |
     curl --fail-with-body --silent --show-error --request POST \
       --header @- http://127.0.0.1:8081/vpn/restart
   ```

   From a client on `vpn-net`, use `http://gluetun-qbt-watchdog:8081/vpn/restart` instead. The header is passed on stdin rather than putting the key in curl's command-line arguments.

| Response | Meaning |
|---|---|
| `202` with `{"status":"queued"}` | One VPN restart was queued, not completed. |
| `409` with `{"status":"already_pending"}` | A request is already queued; no additional request was added. |
| `401` / `404` | Missing or incorrect key / control disabled or unknown route. |
| `400` / `503` | Nonempty or unsupported request body / stale or unavailable watchdog status, or unwritable queue. |

The main watchdog loop processes the request on a polling cycle, after any existing `RESTART_COOLDOWN` and post-restart grace expire. With defaults, polling adds up to about 60 seconds plus API-operation time; a current cooldown can add up to 15 minutes. Startup also has a 30-second delay. There is one pending request slot in `STATE_DIR`; it survives watchdog recreation. After a request is consumed, another can be queued, but it still must wait for the persisted cooldown. Removing the key disables processing of pending requests too; remove `vpn-restart-request` from your configured state directory if you want to cancel one.

Manual requests work even when the port is healthy or automatic recovery is latched off. They neither consume nor replenish the automatic attempt budget and do not clear the terminal latch; only confirmed recovery or the separate manual reset does that. Stop failures still get a start request. Watchdog logs the attempt and any API errors without logging the key; use `/healthz` and `/readyz` to observe subsequent recovery. A queued response does not guarantee execution if watchdog crashes while consuming the request.

**Security and traffic impact:** the key authorizes a disruptive VPN stop/start, not a container restart. HTTP does not encrypt it: keep this port on a trusted Docker network or loopback, and use an authenticated TLS reverse proxy for remote access. Do not publish the port to the internet or enable request-header logging on the proxy. Restarting the VPN briefly interrupts traffic through Gluetun. Automatic recovery policy is unchanged and may later use its configured container fallback; set `RESTART_GLUETUN_CONTAINER=false` to prohibit that globally.

### Uptime Kuma and Dozzle/Gotify

Configure two HTTP monitors in Kuma on the shared Docker network:

| Monitor | URL | Accepted status codes | Notifications |
|---|---|---|---|
| VPN port availability | `http://gluetun-qbt-watchdog:8081/healthz` | **200 only** | **Off**; shows every interruption |
| VPN needs attention | `http://gluetun-qbt-watchdog:8081/readyz` | **200 and 202 only** | **On**; reports terminal recovery or watchdog failure |

| Watchdog state | `/healthz` | `/readyz` |
|---|---|---|
| Healthy: both APIs checked and ports match | 200 | 200 |
| Recovering: startup, grace/cooldown wait, recovery attempt, or a failure still within its grace period | 503 | 202 |
| Unrecoverable: automatic recovery latched off | 503 | 503 |
| Checks stale, or status missing/invalid | 503 | 503 |

Both routes return the same JSON status, reason, and attempt counters. A 202 response distinguishes recovery at the API level, but an accepted 202 appears **Up (green)** in Kuma, not permanently yellow. Recovery can remain quiet throughout a long cooldown even while incoming connectivity is impaired. `unrecoverable` means automatic restart attempts are disabled; monitoring and port-sync attempts continue, and confirmed recovery clears the latch.

- **Disable notifications on the containing group** so the silent availability monitor cannot trigger a group alert. Enable notifications on any other children whose failures still need to alert. The group can still display degradation.
- Poll at your preferred interval (for example 60 seconds). Kuma's retries delay alerts for 503 and connection failures alike; do not use a very large retry count to suppress recovery warnings. Disable repeated/resend notifications if you want only down/up transitions. Validate the actual notification behavior with a controlled outage.
- If checks stop updating, both endpoints return 503 after `max(180, 3 × CHECK_INTERVAL)` seconds, including when the last state was recovering. If the watchdog or its HTTP server dies, both endpoints are unreachable; the main process also exits when it detects the server has died.
- Both monitoring endpoints are read-only, contain no secrets, and do not log every request. The separate manual VPN control route is disabled unless `WATCHDOG_API_KEY` is configured. Keep them on a trusted monitoring network; do not expose them publicly. Host-side Kuma can use the optional loopback port mapping; remote Kuma needs an explicitly allowed LAN address/port instead.
- **Do not use either endpoint to trigger autoheal/container restarts.** They report status, not a command to replenish the recovery budget.

#### Count restart attempts and command failures

Scope these Dozzle rules to the watchdog container. The same event codes cover VPN API restarts and the optional full Gluetun-container restart:

| What to monitor | Dozzle condition |
| --- | --- |
| Every restart attempt | `message contains "RESTART_ATTEMPT:"` |
| Every failed restart command | `message contains "RESTART_FAILED:"` |

Each attempt emits one `RESTART_ATTEMPT:` line immediately before the restart command. A VPN attempt consists of both stop and start API calls and counts once, not twice. If either or both API calls fail, the attempt emits one `RESTART_FAILED:` line after the start call. A failed Docker restart also emits one `RESTART_FAILED:` line. Failure lines include a fixed `reason=` code; raw Docker error output is not logged.

Both events include `target=vpn` or `target=container`. To count only full Gluetun-container restart attempts, use `message contains "RESTART_ATTEMPT: target=container;"`; for only those failures, use `message contains "RESTART_FAILED: target=container;"`. Do not add failure counts to attempt counts: a failed attempt produces both events.

These events report attempts and command errors, not confirmed VPN/port recovery. A command can succeed while the port stays missing; keep the terminal alert below for that case. Log counts are best-effort, not a durable restart counter: process crashes and external log retention or delivery can lose events. Existing cooldowns, budgets, and the terminal latch are unchanged.

#### Alert when recovery is exhausted

Replace the existing Dozzle rule (`message contains "Still no port" || message contains "permission denied"`) with this condition, scoped to the watchdog container:

```text
message contains "UNRECOVERABLE"
```

Only entry into the terminal state emits that marker. Continuing failures, changing reasons, monitoring endpoint requests, and watchdog restarts do not resend it. Explicit manual VPN requests still log their attempts and API failures while latched. Docker permission errors are captured rather than repeatedly printed; a failed container-recovery attempt eventually produces `ERROR UNRECOVERABLE: docker_permission_denied; ...`. Other reason codes distinguish missing ports, API access, qBittorrent authentication/preferences, port-update failure, and restart API failures.

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
      WATCHDOG_API_KEY: "${WATCHDOG_API_KEY:-}"
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
