# Sourced by the watchdog. Persist only counters/timers and fixed reason codes, never secrets.
clock_now() {
    cut -d. -f1 /proc/uptime
}

fatal() {
    emit_log "FATAL: $1"
    exit 1
}

save_state() {
    printf '%s\n' "1 $boot_id $phase $reason $outage_since $failure_since $missing_since $port_miss_count $recovery_seen_at $vpn_attempts $container_attempted $cooldown_until $settle_until $last_error" \
        > "$STATE_DIR/recovery.tmp" && mv "$STATE_DIR/recovery.tmp" "$STATE_DIR/recovery.state" || \
        fatal "Cannot persist recovery state; refusing further restarts. Check STATE_DIR permissions and free space."
}

reset_episode() {
    phase=recovering
    reason=starting
    outage_since=0
    failure_since=0
    missing_since=0
    port_miss_count=0
    recovery_seen_at=0
    vpn_attempts=0
    container_attempted=0
    settle_until=0
    last_error=none
    # Keep cooldown_until across recovery and manual reset to prevent rapid flapping.
}

load_state() {
    local version stored_boot extra value
    read -r boot_id < /proc/sys/kernel/random/boot_id
    now=$(clock_now)
    cooldown_until=0
    reset_episode
    if [ -f "$STATE_DIR/recovery.state" ]; then
        read -r version stored_boot phase reason outage_since failure_since missing_since port_miss_count recovery_seen_at \
            vpn_attempts container_attempted cooldown_until settle_until last_error extra < "$STATE_DIR/recovery.state" || \
            fatal "Unreadable recovery state; restore it or explicitly reset the state volume."
        [ "$version" = 1 ] && [ -z "$extra" ] || fatal "Unsupported recovery state format."
        case "$phase" in healthy|recovering|unrecoverable) ;; *) fatal "Invalid persisted recovery phase." ;; esac
        case "$reason:$last_error" in *[!a-z_:]*|'':*) fatal "Invalid persisted reason code." ;; esac
        [ -n "$reason" ] && [ -n "$last_error" ] || fatal "Missing persisted reason code."
        for value in "$outage_since" "$failure_since" "$missing_since" "$port_miss_count" "$recovery_seen_at" \
            "$vpn_attempts" "$container_attempted" "$cooldown_until" "$settle_until"; do
            case "$value" in ''|*[!0-9]*|0[0-9]*) fatal "Invalid persisted recovery counter." ;; esac
            [ "${#value}" -le 12 ] || fatal "Persisted recovery counter too large."
        done
        [ "$container_attempted" -le 1 ] || fatal "Invalid container recovery counter."
        if [ "$stored_boot" != "$boot_id" ]; then
            # Monotonic timestamps cannot cross host boots; retain the budget/latch and wait afresh.
            [ "$outage_since" -eq 0 ] || outage_since=$now
            [ "$failure_since" -eq 0 ] || failure_since=$now
            [ "$missing_since" -eq 0 ] || missing_since=$now
            [ "$recovery_seen_at" -eq 0 ] || recovery_seen_at=$now
            [ "$cooldown_until" -eq 0 ] || cooldown_until=$((now + RESTART_COOLDOWN))
            [ "$settle_until" -eq 0 ] || settle_until=$((now + GLUETUN_RECOVERY_GRACE))
        fi
    fi
    # Even a previously healthy process must confirm both APIs again after starting.
    if [ "$phase" = healthy ]; then
        phase=recovering
        reason=starting
    fi
    save_state
}

publish_health() {
    printf '%s\n' "$(clock_now) $phase $reason $vpn_attempts $container_attempted" \
        > "$HEALTH_STATUS_FILE.tmp" && mv "$HEALTH_STATUS_FILE.tmp" "$HEALTH_STATUS_FILE" || \
        fatal "Cannot publish watchdog health."
}

begin_outage() {
    [ "$outage_since" -ne 0 ] || outage_since=$now
    if [ "$phase" != unrecoverable ]; then
        phase=recovering
        reason=$1
    fi
}

unrecoverable() {
    [ "$phase" != unrecoverable ] || return 0
    phase=unrecoverable
    reason=$1
    # Persist before logging: process restarts must never resend the same terminal alert.
    save_state
    emit_log "ERROR UNRECOVERABLE: $reason; automatic restarts disabled; monitoring and port sync continue."
}

observe_failure() {
    begin_outage "$1"
    [ "$failure_since" -ne 0 ] || failure_since=$now
    if [ $((now - failure_since)) -ge "$MISSING_PORT_GRACE" ] && [ "$now" -ge "$settle_until" ]; then
        unrecoverable "$1"
    fi
}

mark_healthy() {
    local recovered=$outage_since
    reset_episode
    phase=healthy
    reason=ports_synced
    save_state
    if [ "$recovered" -ne 0 ]; then
        emit_log "INFO RECOVERED: Gluetun port $GLUETUN_PORT is confirmed and qBittorrent matches; recovery budget rearmed."
    fi
}

handle_missing_port() {
    local health output
    begin_outage port_missing
    failure_since=0
    [ "$missing_since" -ne 0 ] || missing_since=$now
    port_miss_count=$((port_miss_count + 1))
    [ "$phase" != unrecoverable ] || return 0

    health=$(timeout 10 docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}unknown{{end}}' \
        "$GLUETUN_CONTAINER_NAME" 2>/dev/null) || health=unknown
    case "$health" in 'running healthy'|'running unhealthy'|'running starting'|'restarting unhealthy') ;; *) health=unknown ;; esac
    log "INFO: Port missing for $((now - missing_since))s ($port_miss_count/$PORT_MISS_THRESHOLD checks); API=ok, container/health=$health; VPN attempts=$vpn_attempts/$MAX_VPN_RESTARTS."
    if [ "$health" != 'running healthy' ] && [ "$recovery_seen_at" -eq 0 ]; then
        recovery_seen_at=$now
    fi

    if [ "$port_miss_count" -lt "$PORT_MISS_THRESHOLD" ] || [ $((now - missing_since)) -lt "$MISSING_PORT_GRACE" ]; then
        log "INFO: Recovery deferred: missing-port count or grace threshold not reached."
    elif [ "$now" -lt "$settle_until" ]; then
        log "INFO: Recovery deferred: post-restart grace has $((settle_until - now))s remaining."
    elif [ "$vpn_attempts" -ge "$MAX_VPN_RESTARTS" ] && \
        { [ "$container_attempted" -eq 1 ] || [ "$RESTART_GLUETUN_CONTAINER" = false ]; }; then
        if [ "$last_error" = none ]; then
            unrecoverable port_missing_after_recovery
        else
            unrecoverable "$last_error"
        fi
    elif [ "$recovery_seen_at" -ne 0 ] && [ $((now - recovery_seen_at)) -lt "$GLUETUN_RECOVERY_GRACE" ]; then
        log "INFO: Recovery deferred: allowing Gluetun's own recovery window to finish."
    elif [ "$now" -lt "$cooldown_until" ]; then
        log "INFO: Recovery deferred: restart cooldown has $((cooldown_until - now))s remaining."
    else
        # Reserve the attempt and timers before side effects so a crash cannot replenish the budget.
        cooldown_until=$((now + RESTART_COOLDOWN))
        settle_until=$((now + GLUETUN_RECOVERY_GRACE))
        last_error=none
        if [ "$vpn_attempts" -lt "$MAX_VPN_RESTARTS" ]; then
            vpn_attempts=$((vpn_attempts + 1))
            save_state
            if ! restart_vpn; then
                last_error=vpn_restart_api_failed
            fi
        else
            container_attempted=1
            save_state
            log "INFO: VPN attempts exhausted; restarting only Gluetun container $GLUETUN_CONTAINER_NAME."
            if ! output=$(timeout 90 docker restart --time 10 "$GLUETUN_CONTAINER_NAME" 2>&1); then
                case "$output" in
                    *'permission denied'*) last_error=docker_permission_denied ;;
                    *) last_error=gluetun_container_restart_failed ;;
                esac
                log "WARNING: Gluetun container restart failed; the attempt is consumed."
            fi
        fi
        now=$(clock_now)
        cooldown_until=$((now + RESTART_COOLDOWN))
        settle_until=$((now + GLUETUN_RECOVERY_GRACE))
        save_state
    fi
}
