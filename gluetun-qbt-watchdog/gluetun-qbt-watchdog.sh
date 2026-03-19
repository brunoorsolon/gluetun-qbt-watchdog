#!/bin/sh
# gluetun-qbt-watchdog
# Single script that keeps gluetun port forwarding and qBittorrent in sync.

GLUETUN_API="${GLUETUN_API:-http://gluetun:8000}"
GLUETUN_API_KEY="${GLUETUN_API_KEY:-}"
QBT_API="${QBT_API:-http://gluetun:8075}"
QBT_USER="${QBT_USER:-admin}"
QBT_PASS="${QBT_PASS:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
HEARTBEAT_CYCLE_FREQUENCY="${HEARTBEAT_CYCLE_FREQUENCY:-10}"
MAX_RESTART_WAIT="${MAX_RESTART_WAIT:-30}"
QBT_COOKIE="/tmp/qbt_cookies.txt"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

# ---- Gluetun helpers ----
get_gluetun_port() {
    curl -sf -H "X-API-Key: $GLUETUN_API_KEY" \
        "$GLUETUN_API/v1/portforward" | grep -o '"port":[0-9]*' | grep -o '[0-9]*'
}

restart_vpn() {
    log "Restarting VPN via gluetun API..."
    curl -sf -X PUT -H "X-API-Key: $GLUETUN_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"status":"stopped"}' \
        "$GLUETUN_API/v1/vpn/status" > /dev/null
    sleep 5
    curl -sf -X PUT -H "X-API-Key: $GLUETUN_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"status":"running"}' \
        "$GLUETUN_API/v1/vpn/status" > /dev/null
}

# ---- qBittorrent helpers ----
qbt_login() {
    local result=$(curl -sf -c "$QBT_COOKIE" \
        --data-urlencode "username=$QBT_USER" --data-urlencode "password=$QBT_PASS" \
        "$QBT_API/api/v2/auth/login")
    [ "$result" = "Ok." ]
}

get_qbt_port() {
    curl -sf -b "$QBT_COOKIE" \
        "$QBT_API/api/v2/app/preferences" | \
        grep -o '"listen_port":[0-9]*' | head -1 | grep -o '[0-9]*'
}

set_qbt_port() {
    curl -sf -b "$QBT_COOKIE" \
        -d "json={\"listen_port\":$1,\"random_port\":false,\"upnp\":false}" \
        "$QBT_API/api/v2/app/setPreferences" > /dev/null
}

# ---- Recovery helpers ----
restart_via_docker() {
    log "Restarting gluetun container via Docker..."
    docker restart gluetun
    sleep 10
    docker restart qbittorrent mousehole 2>/dev/null
}

wait_for_port() {
    local waited=0
    while [ $waited -lt $MAX_RESTART_WAIT ]; do
        local port=$(get_gluetun_port)
        if [ -n "$port" ] && [ "$port" != "0" ]; then
            echo "$port"
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    return 1
}

# ---- Main loop ----
log "Watchdog started. Checking every ${CHECK_INTERVAL}s, heartbeat every ${HEARTBEAT_CYCLE_FREQUENCY} cycles"
log "Gluetun API: $GLUETUN_API"
log "qBittorrent API: $QBT_API"

# Initial delay to let everything start up
sleep 30

cycle_count=0

while true; do
    cycle_count=$((cycle_count + 1))

    # Step 1: Get gluetun's forwarded port
    GLUETUN_PORT=$(get_gluetun_port)

    if [ -z "$GLUETUN_PORT" ] || [ "$GLUETUN_PORT" = "0" ]; then
        log "WARNING: No forwarded port from gluetun. Attempting VPN restart..."
        restart_vpn
        sleep 15
        GLUETUN_PORT=$(get_gluetun_port)

        if [ -z "$GLUETUN_PORT" ] || [ "$GLUETUN_PORT" = "0" ]; then
            log "ERROR: VPN restart didn't help. Restarting containers..."
            restart_via_docker
            GLUETUN_PORT=$(wait_for_port)
            if [ -z "$GLUETUN_PORT" ]; then
                log "ERROR: Still no port after full restart. Will retry next cycle."
                sleep "$CHECK_INTERVAL"
                continue
            fi
        fi
        log "New port after recovery: $GLUETUN_PORT"
    fi

    # Step 2: Login to qBittorrent
    if ! qbt_login; then
        log "WARNING: Can't login to qBittorrent. Skipping this cycle."
        sleep "$CHECK_INTERVAL"
        continue
    fi

    # Step 3: Check if qBittorrent has the right port
    QBT_PORT=$(get_qbt_port)

    if [ -z "$QBT_PORT" ]; then
        log "WARNING: Can't read qBittorrent preferences. Skipping this cycle."
        sleep "$CHECK_INTERVAL"
        continue
    fi

    if [ "$QBT_PORT" != "$GLUETUN_PORT" ]; then
        log "WARNING: Port mismatch: gluetun=$GLUETUN_PORT, qbt=$QBT_PORT. Fixing..."
        set_qbt_port "$GLUETUN_PORT"
        sleep 2
        QBT_PORT=$(get_qbt_port)
        if [ "$QBT_PORT" = "$GLUETUN_PORT" ]; then
            log "Port synced successfully: $GLUETUN_PORT"
        else
            log "ERROR: Failed to set port. qbt still reports $QBT_PORT"
        fi
    elif [ $((cycle_count % HEARTBEAT_CYCLE_FREQUENCY)) -eq 0 ]; then
        log "OK: gluetun=$GLUETUN_PORT, qbt=$QBT_PORT"
    fi

    sleep "$CHECK_INTERVAL"
done
