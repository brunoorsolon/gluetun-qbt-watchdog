#!/bin/sh
# gluetun-qbt-watchdog
# Single script that keeps gluetun port forwarding and qBittorrent in sync.

GLUETUN_CONTAINER_NAME="${GLUETUN_CONTAINER_NAME:-gluetun}"
GLUETUN_API="${GLUETUN_API:-http://gluetun:8000}"
GLUETUN_API_KEY="${GLUETUN_API_KEY:-}"
QBT_API="${QBT_API:-http://gluetun:8075}"
QBT_USER="${QBT_USER:-admin}"
QBT_PASS="${QBT_PASS:-}"
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-qbittorrent}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
HEARTBEAT_CYCLE_FREQUENCY="${HEARTBEAT_CYCLE_FREQUENCY:-10}"
MAX_RESTART_WAIT="${MAX_RESTART_WAIT:-30}"
QBT_COOKIE="/tmp/qbt_cookies.txt"
ADDITIONAL_RESTART="${ADDITIONAL_RESTART:-''}"

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
# Login helper that can try either the configured password or a temporary one recovered from logs.
qbt_login_with_password() {
    local password="$1"
    local result=$(curl -sf -c "$QBT_COOKIE" \
        --data-urlencode "username=$QBT_USER" --data-urlencode "password=$password" \
        "$QBT_API/api/v2/auth/login")
    [ "$result" = "Ok." ]
}

qbt_login() {
    qbt_login_with_password "$QBT_PASS"
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

# Updates the Web UI password to the configured QBT_PASS value.
set_qbt_password() {
    local escaped_password=$(printf '%s' "$QBT_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -sf -b "$QBT_COOKIE" \
        --data-urlencode "json={\"web_ui_password\":\"$escaped_password\"}" \
        "$QBT_API/api/v2/app/setPreferences" > /dev/null
}

# Reads the temporary password that qBittorrent prints to container logs.
get_qbt_init_password() {
    docker logs --tail 200 "$QBT_CONTAINER_NAME" 2>&1 | \
        sed -n 's/.*A temporary password is provided for this session: //p' | \
        tail -1 | tr -d '\r'
}

# If the configured password fails, use the temporary password from logs and replace it.
recover_qbt_password() {
    if [ -z "$QBT_PASS" ]; then
        log "ERROR: QBT_PASS is empty, cannot recover qBittorrent login."
        return 1
    fi

    log "WARNING: qBittorrent login failed with configured password. Checking container logs for the temporary password..."
    local init_password=$(get_qbt_init_password)
    if [ -z "$init_password" ]; then
        log "ERROR: Could not extract qBittorrent temporary password from container logs."
        return 1
    fi

    if ! qbt_login_with_password "$init_password"; then
        log "ERROR: Temporary qBittorrent password from container logs ($init_password) did not work."
        return 1
    fi

    log "Updating qBittorrent Web UI password from temporary password to configured QBT_PASS."
    if ! set_qbt_password; then
        log "ERROR: Failed to update qBittorrent Web UI password."
        return 1
    fi

    sleep 2

    if qbt_login; then
        log "qBittorrent Web UI password updated successfully."
        return 0
    fi

    log "ERROR: Updated qBittorrent password, but login with configured QBT_PASS still failed."
    return 1
}

# ---- Recovery helpers ----
restart_via_docker() {
    log "Restarting containers via Docker: $GLUETUN_CONTAINER_NAME $QBT_CONTAINER_NAME"
    docker restart "$GLUETUN_CONTAINER_NAME"
    sleep 10
    docker restart "$QBT_CONTAINER_NAME" "$ADDITIONAL_RESTART" 2>/dev/null
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
        if ! recover_qbt_password; then
            log "WARNING: Can't login to qBittorrent. Skipping this cycle."
            sleep "$CHECK_INTERVAL"
            continue
        fi
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
