#!/bin/sh
# gluetun-qbt-watchdog
# Single script that keeps gluetun port forwarding and qBittorrent in sync.

GLUETUN_CONTAINER_NAME="${GLUETUN_CONTAINER_NAME:-gluetun}"
GLUETUN_API="${GLUETUN_API:-http://gluetun:8000}"
GLUETUN_API_KEY="${GLUETUN_API_KEY:-}"
QBT_API="${QBT_API:-http://gluetun:8080}"
QBT_API_KEY="${QBT_API_KEY:-}"
QBT_AUTH_MODE="${QBT_AUTH_MODE:-auto}"
QBT_USER="${QBT_USER:-admin}"
QBT_PASS="${QBT_PASS:-}"
QBT_CONTAINER_NAME="${QBT_CONTAINER_NAME:-qbittorrent}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
PORT_MISS_THRESHOLD="${PORT_MISS_THRESHOLD:-3}"
MISSING_PORT_GRACE="${MISSING_PORT_GRACE:-300}"
GLUETUN_RECOVERY_GRACE="${GLUETUN_RECOVERY_GRACE:-300}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-900}"
MAX_VPN_RESTARTS="${MAX_VPN_RESTARTS:-2}"
RESTART_GLUETUN_CONTAINER="${RESTART_GLUETUN_CONTAINER:-true}"
STATE_DIR="${STATE_DIR:-/state}"
HEALTH_PORT="${HEALTH_PORT:-8081}"
HEALTH_STATUS_FILE="${HEALTH_STATUS_FILE:-/tmp/watchdog-health-status}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
export HEALTH_PORT
HEARTBEAT_CYCLE_FREQUENCY="${HEARTBEAT_CYCLE_FREQUENCY:-10}"
QBT_COOKIE="${QBT_COOKIE:-/tmp/qbt_cookies.txt}"
QBT_LOGIN_RESPONSE="${QBT_LOGIN_RESPONSE:-/tmp/qbt_login_response.txt}"

emit_log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1"
}

log() {
    # Once latched, only an actual recovery or manual reset may produce another event.
    [ "${phase:-}" = unrecoverable ] || emit_log "$1"
}

# ---- Gluetun helpers ----
get_gluetun_port() {
    local response status port
    if ! response=$(curl -s --connect-timeout 5 --max-time 10 \
        -H "X-API-Key: $GLUETUN_API_KEY" -w '|%{http_code}' \
        "$GLUETUN_API/v1/portforward"); then
        log "WARNING: Gluetun API transport error or timeout; port is unknown." >&2
        return 1
    fi
    status=${response##*|}
    if [ "$status" != "200" ]; then
        log "WARNING: Gluetun API HTTP $status; port is unknown (401/403 indicate authentication failure)." >&2
        case "$status" in 401|403) return 2 ;; esac
        return 1
    fi
    # Accept only the complete expected response, not a port embedded in an error body.
    port=$(printf '%s' "${response%|*}" | tr '\r\n' '  ' | \
        sed -n 's/^[[:space:]]*{[[:space:]]*"port"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*}[[:space:]]*$/\1/p')
    case "$port" in
        ''|0[0-9]*) ;;
        *)
            if [ "${#port}" -le 5 ] && [ "$port" -le 65535 ]; then
                printf '%s\n' "$port"
                return 0
            fi
            ;;
    esac
    log "WARNING: Invalid Gluetun port response; port is unknown." >&2
    return 3
}

restart_vpn() {
    local failed=0
    log "Restarting VPN via gluetun API..."
    if ! curl -sf --connect-timeout 5 --max-time 10 -X PUT -H "X-API-Key: $GLUETUN_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"status":"stopped"}' \
        "$GLUETUN_API/v1/vpn/status" > /dev/null; then
        log "WARNING: Gluetun VPN stop API call failed."
        failed=1
    fi
    sleep 5
    # A lost stop response may still mean the VPN stopped; always try to start it.
    if ! curl -sf --connect-timeout 5 --max-time 10 -X PUT -H "X-API-Key: $GLUETUN_API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"status":"running"}' \
        "$GLUETUN_API/v1/vpn/status" > /dev/null; then
        log "WARNING: Gluetun VPN start API call failed."
        failed=1
    fi
    return "$failed"
}

# ---- qBittorrent helpers ----
validate_qbt_auth_mode() {
    case "$QBT_AUTH_MODE" in
        auto|apikey|password) return 0 ;;
        *)
            log "ERROR: Invalid QBT_AUTH_MODE '$QBT_AUTH_MODE'. Use auto, apikey, or password."
            return 1
            ;;
    esac
}

qbt_uses_api_key() {
    [ "$QBT_AUTH_MODE" = "apikey" ] || \
        { [ "$QBT_AUTH_MODE" = "auto" ] && [ -n "$QBT_API_KEY" ]; }
}

qbt_auth_description() {
    if qbt_uses_api_key; then
        echo "api key"
    else
        echo "username/password"
    fi
}

qbt_curl() {
    if qbt_uses_api_key; then
        curl -sf --connect-timeout 5 --max-time 10 -H "Authorization: Bearer $QBT_API_KEY" "$@"
    else
        curl -sf --connect-timeout 5 --max-time 10 -b "$QBT_COOKIE" "$@"
    fi
}

qbt_check_api_key() {
    if [ -z "$QBT_API_KEY" ]; then
        log "WARNING: QBT_AUTH_MODE=apikey requires QBT_API_KEY."
        return 1
    fi

    local status
    status=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $QBT_API_KEY" \
        "$QBT_API/api/v2/app/webapiVersion")

    case "$status" in
        200) return 0 ;;
        401|403) log "WARNING: qBittorrent API key was rejected." ;;
        404) log "WARNING: qBittorrent WebAPI endpoint not found; API-key auth requires qBittorrent 5.2.0 / WebAPI 2.14.1+." ;;
        000) log "WARNING: qBittorrent WebAPI is unreachable." ;;
        *) log "WARNING: qBittorrent API-key probe failed with HTTP $status." ;;
    esac
    return 1
}

# Login helper that can try either the configured password or a temporary one recovered from logs.
qbt_login_with_password() {
    local password="$1"
    local status
    local result

    status=$(curl -s --connect-timeout 5 --max-time 10 -o "$QBT_LOGIN_RESPONSE" -w '%{http_code}' -c "$QBT_COOKIE" \
        --data-urlencode "username=$QBT_USER" --data-urlencode "password=$password" \
        "$QBT_API/api/v2/auth/login")
    result=$(tr -d '\r' < "$QBT_LOGIN_RESPONSE")

    if [ "$status" = "204" ]; then
        return 0
    fi

    if [ "$status" = "200" ] && [ "$result" = "Ok." ]; then
        return 0
    fi

    case "$status" in
        401) log "WARNING: qBittorrent login failed: invalid credentials." ;;
        000) log "WARNING: qBittorrent WebAPI is unreachable." ;;
        *) log "WARNING: qBittorrent login failed with HTTP $status." ;;
    esac
    return 1
}

qbt_login() {
    qbt_login_with_password "$QBT_PASS"
}

qbt_authenticate() {
    if qbt_uses_api_key; then
        qbt_check_api_key
        return $?
    fi

    if qbt_login; then
        return 0
    fi

    recover_qbt_password
}

get_qbt_port() {
    local response
    response=$(qbt_curl "$QBT_API/api/v2/app/preferences") || return 1
    printf '%s' "$response" | \
        grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' | head -1 | grep -o '[0-9]*'
}

set_qbt_port() {
    qbt_curl \
        --data-urlencode "json={\"listen_port\":$1,\"random_port\":false,\"upnp\":false}" \
        "$QBT_API/api/v2/app/setPreferences" > /dev/null
}

# Updates the Web UI password to the configured QBT_PASS value.
set_qbt_password() {
    local escaped_password
    escaped_password=$(printf '%s' "$QBT_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')
    curl -sf --connect-timeout 5 --max-time 10 -b "$QBT_COOKIE" \
        --data-urlencode "json={\"web_ui_password\":\"$escaped_password\"}" \
        "$QBT_API/api/v2/app/setPreferences" > /dev/null
}

# Reads the temporary password that qBittorrent prints to container logs.
get_qbt_init_password() {
    timeout 10 docker logs --tail 200 "$QBT_CONTAINER_NAME" 2>/dev/null | \
        sed -n 's/.*A temporary password is provided for this session: //p' | \
        tail -1 | tr -d '\r'
}

# If the configured password fails, use the temporary password from logs and replace it.
recover_qbt_password() {
    if [ -z "$QBT_PASS" ]; then
        log "WARNING: QBT_PASS is empty, cannot recover qBittorrent login."
        return 1
    fi

    log "WARNING: qBittorrent login failed with configured password. Checking container logs for the temporary password..."
    local init_password
    init_password=$(get_qbt_init_password)
    if [ -z "$init_password" ]; then
        log "WARNING: Could not extract qBittorrent temporary password from container logs."
        return 1
    fi

    if ! qbt_login_with_password "$init_password"; then
        log "WARNING: Temporary qBittorrent password from container logs did not work."
        return 1
    fi

    log "Updating qBittorrent Web UI password from temporary password to configured QBT_PASS."
    if ! set_qbt_password; then
        log "WARNING: Failed to update qBittorrent Web UI password."
        return 1
    fi

    sleep 2

    if qbt_login; then
        log "qBittorrent Web UI password updated successfully."
        return 0
    fi

    log "WARNING: Updated qBittorrent password, but login with configured QBT_PASS still failed."
    return 1
}

# ---- Recovery state and monitoring ----
# shellcheck source-path=SCRIPTDIR
# shellcheck source=recovery.sh
. "$SCRIPT_DIR/recovery.sh"

check_ports() {
    if GLUETUN_PORT=$(get_gluetun_port); then
        :
    else
        case "$?" in
            2) observe_failure gluetun_auth_failed ;;
            3) observe_failure gluetun_response_invalid ;;
            *) observe_failure gluetun_api_unavailable ;;
        esac
        log "INFO: Recovery deferred: API unreadable; missing-port count/history retained."
        return
    fi

    now=$(clock_now)
    if [ "$GLUETUN_PORT" = 0 ]; then
        handle_missing_port
        return
    fi

    missing_since=0
    port_miss_count=0
    if ! qbt_authenticate; then
        observe_failure qbittorrent_auth_failed
        return
    fi
    QBT_PORT=$(get_qbt_port)
    if [ -z "$QBT_PORT" ]; then
        observe_failure qbittorrent_preferences_unavailable
        return
    fi
    if [ "$QBT_PORT" != "$GLUETUN_PORT" ]; then
        log "INFO: Port mismatch: gluetun=$GLUETUN_PORT, qbt=$QBT_PORT. Updating qBittorrent."
        if ! set_qbt_port "$GLUETUN_PORT"; then
            observe_failure qbittorrent_port_update_failed
            return
        fi
        sleep 2
        QBT_PORT=$(get_qbt_port)
        if [ "$QBT_PORT" != "$GLUETUN_PORT" ]; then
            observe_failure qbittorrent_port_mismatch
            return
        fi
        log "INFO: Port synced successfully: $GLUETUN_PORT"
    fi
    mark_healthy
    if [ $((cycle_count % HEARTBEAT_CYCLE_FREQUENCY)) -eq 0 ]; then
        log "INFO: OK: gluetun=$GLUETUN_PORT, qbt=$QBT_PORT"
    fi
}

# ---- Startup ----
validate_qbt_auth_mode || exit 1
for value in "$CHECK_INTERVAL" "$HEARTBEAT_CYCLE_FREQUENCY" "$PORT_MISS_THRESHOLD" "$MISSING_PORT_GRACE" \
    "$GLUETUN_RECOVERY_GRACE" "$RESTART_COOLDOWN" "$MAX_VPN_RESTARTS" "$HEALTH_PORT"; do
    case "$value" in
        ''|*[!0-9]*|0*) fatal "Intervals, thresholds and port must be positive integers without leading zeros." ;;
    esac
    [ "${#value}" -le 9 ] || fatal "Configuration number too large."
done
[ "$HEALTH_PORT" -le 65535 ] || fatal "HEALTH_PORT must be between 1 and 65535."
case "$RESTART_GLUETUN_CONTAINER" in true|false) ;; *) fatal "RESTART_GLUETUN_CONTAINER must be true or false." ;; esac

umask 077
mkdir -p "$STATE_DIR" || fatal "Cannot create STATE_DIR; mount a writable persistent volume."
load_state
publish_health
stale_after=$((CHECK_INTERVAL * 3))
[ "$stale_after" -ge 180 ] || stale_after=180
python3 "$SCRIPT_DIR/health-server.py" "$HEALTH_STATUS_FILE" "$stale_after" &
health_pid=$!
trap 'kill "$health_pid" 2>/dev/null; wait "$health_pid" 2>/dev/null' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
log "INFO: Watchdog started; interval=${CHECK_INTERVAL}s; auth=$(qbt_auth_description); health port=$HEALTH_PORT."
log "INFO: Missing-port threshold=$PORT_MISS_THRESHOLD; grace=${MISSING_PORT_GRACE}s; Gluetun recovery grace=${GLUETUN_RECOVERY_GRACE}s; cooldown=${RESTART_COOLDOWN}s; VPN budget=$MAX_VPN_RESTARTS; container fallback=$RESTART_GLUETUN_CONTAINER."
if [ -n "${MAX_RESTART_WAIT+x}${ADDITIONAL_RESTART+x}${VPN_RESTART_COOLDOWN+x}" ]; then
    log "WARNING: MAX_RESTART_WAIT, ADDITIONAL_RESTART and VPN_RESTART_COOLDOWN are ignored. Only Gluetun may be restarted; use GLUETUN_RECOVERY_GRACE and RESTART_COOLDOWN."
fi

sleep 30
cycle_count=0
while true; do
    kill -0 "$health_pid" 2>/dev/null || fatal "Health server exited; check HEALTH_BIND and HEALTH_PORT."
    now=$(clock_now)
    if [ -f "$STATE_DIR/reset-request" ]; then
        rm "$STATE_DIR/reset-request" || fatal "Cannot consume manual reset request."
        reset_episode
        save_state
        emit_log "INFO: Recovery budget manually reset; existing cooldown retained."
    fi
    cycle_count=$((cycle_count + 1))
    check_ports
    save_state
    publish_health
    sleep "$CHECK_INTERVAL"
done