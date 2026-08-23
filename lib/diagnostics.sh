#!/usr/bin/env bash
# lib/diagnostics.sh - read-only health checks. Nothing in this file ever
# changes system state; it only reports PASS/WARNING/FAIL so it is always
# safe to run.

if [ -n "${M3U8_DIAGNOSTICS_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_DIAGNOSTICS_LOADED=1


run_diagnostics() {
    local domain ssl_enabled output stream_count disk_avail pkg dns_status

    if detect_os 2>/dev/null && [ -n "${OS_PRETTY_NAME:-}" ]; then
        _diag_pass "OS: ${OS_PRETTY_NAME} (${OS_CODENAME:-unknown codename}, ${OS_ARCH:-unknown arch})"
    fi
    if detect_nginx_version; then
        _diag_pass "Nginx version: $NGINX_VERSION"
    else
        _diag_warn "Could not determine the installed Nginx version."
    fi

    local nginx_running=0 nginx_config_valid=0
    if systemctl is-active --quiet nginx; then
        nginx_running=1
        _diag_pass "Nginx service is running."
    else
        _diag_fail "Nginx service is not running. Run: sudo systemctl status nginx"
    fi

    if output="$(nginx -t 2>&1)"; then
        nginx_config_valid=1
        _diag_pass "Nginx configuration on disk is valid."
    else
        _diag_fail "Nginx configuration on disk is invalid."
        printf '%s\n' "$output" | sed 's/^/          /'
    fi

    # This combination is the dangerous one this project has hit for
    # real: Nginx is still serving traffic from whatever it last loaded
    # successfully, but the config on disk cannot be reloaded or survive a
    # restart until it's fixed. Never let "systemctl is-active" alone
    # stand in for "everything is fine."
    if [ "$nginx_running" -eq 1 ] && [ "$nginx_config_valid" -eq 0 ]; then
        _diag_fail "Nginx is running, but the configuration currently on disk is invalid. Changes will not take effect, and a restart or reboot will bring Nginx down until this is fixed."
    fi

    if port_listening "$M3U8_RTMP_PORT"; then
        _diag_pass "RTMP port ${M3U8_RTMP_PORT} is listening."
    else
        _diag_fail "RTMP port ${M3U8_RTMP_PORT} is not listening. Check the RTMP application in nginx."
    fi

    if port_listening 80; then
        _diag_pass "HTTP port 80 is listening."
    else
        _diag_warn "HTTP port 80 is not listening."
    fi

    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"
    ssl_enabled="$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED 2>/dev/null || echo "false")"

    if [ "$ssl_enabled" = "true" ]; then
        if port_listening 443; then
            _diag_pass "HTTPS port 443 is listening."
        else
            _diag_warn "SSL is enabled but port 443 is not listening."
        fi
        if [ -n "$domain" ] && certificate_exists "$domain"; then
            _diag_pass "SSL certificate found for $domain."
        else
            _diag_fail "SSL is enabled but no certificate was found for $domain."
        fi
    else
        _diag_warn "SSL is not enabled. The server is HTTP-only."
    fi

    if [ -n "$domain" ]; then
        set +e
        dns_points_here "$domain"
        dns_status=$?
        set -e
        case "$dns_status" in
            0) _diag_pass "DNS for $domain points at this server's public IP." ;;
            1) _diag_warn "DNS for $domain does not currently point at this server's public IP." ;;
            *) _diag_warn "Could not verify DNS for $domain." ;;
        esac
    fi

    if [ -d "$M3U8_HLS_DIR" ]; then
        # Checks the real Nginx worker user can write here, not just that
        # the directory exists - see lib/selftest.sh.
        test_hls_directory_writable
        if find "$M3U8_HLS_DIR" -maxdepth 1 -name '*.m3u8' -print -quit 2>/dev/null | grep -q .; then
            _diag_pass "At least one HLS playlist is currently present (a stream may be live)."
        else
            _diag_warn "No HLS playlists present right now (no stream is currently live)."
        fi
    else
        _diag_fail "HLS directory does not exist: $M3U8_HLS_DIR"
    fi

    if [ "$nginx_config_valid" -eq 1 ] && grep -qE '^\s*rtmp\s*\{' "$M3U8_NGINX_RTMP_CONF" 2>/dev/null; then
        _diag_pass "RTMP module configuration is present and loaded."
    else
        _diag_warn "Could not confirm the RTMP module configuration is loaded."
    fi

    test_auth_endpoint

    stream_count=0
    if [ -d "$M3U8_STREAMS_DIR" ]; then
        stream_count="$(find "$M3U8_STREAMS_DIR" -maxdepth 1 -name '*.conf' 2>/dev/null | wc -l | tr -d ' ')"
    fi
    if [ "$stream_count" -gt 0 ]; then
        _diag_pass "$stream_count channel(s) configured."
    else
        _diag_warn "No channels are configured yet. Use m3u8-manager to add one."
    fi

    disk_avail="$(df -h "$M3U8_WEB_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$disk_avail" ]; then
        _diag_pass "Disk space available on HLS volume: $disk_avail"
    fi

    for pkg in nginx libnginx-mod-rtmp certbot ffmpeg; do
        if package_installed "$pkg"; then
            _diag_pass "Package installed: $pkg"
        else
            _diag_warn "Package not installed: $pkg"
        fi
    done

    if ufw_installed; then
        if ufw_is_active; then
            _diag_pass "UFW firewall is active."
        else
            _diag_warn "UFW is installed but not active."
        fi
    else
        _diag_warn "UFW is not installed."
    fi

    # --- Relay subsystem (Phase B) ---------------------------------------
    if command_exists ffprobe; then
        _diag_pass "ffprobe available (relay source detection)."
    else
        _diag_warn "ffprobe not available; relay source detection will be limited."
    fi
    if command_exists setpriv; then
        _diag_pass "setpriv available (required for the relay runner to drop privileges)."
    else
        _diag_fail "setpriv not available; relay mode cannot safely start."
    fi
    if id -u "$M3U8_RELAY_USER" >/dev/null 2>&1; then
        _diag_pass "Dedicated relay system user ('$M3U8_RELAY_USER') exists."
    else
        _diag_warn "Dedicated relay system user ('$M3U8_RELAY_USER') not found."
    fi
    if [ -d "$M3U8_RELAYS_DIR" ]; then
        local relays_owner relays_mode
        relays_owner="$(stat -c '%U:%G' "$M3U8_RELAYS_DIR" 2>/dev/null || echo "")"
        relays_mode="$(stat -c '%a' "$M3U8_RELAYS_DIR" 2>/dev/null || echo "")"
        if [ "$relays_owner" = "root:root" ] && [ "$relays_mode" = "700" ]; then
            _diag_pass "Relay config directory is root:root/700 (secrets not exposed to www-data or m3u8-relay)."
        else
            _diag_fail "Relay config directory is ${relays_owner:-unknown}/${relays_mode:-unknown}, expected root:root/700 - relay source URLs may be exposed to an unrelated identity."
        fi
    else
        _diag_warn "Relay config directory not found ($M3U8_RELAYS_DIR)."
    fi
    if [ -f "$M3U8_RELAY_RUNNER" ]; then
        local runner_owner runner_mode
        runner_owner="$(stat -c '%U:%G' "$M3U8_RELAY_RUNNER" 2>/dev/null || echo "")"
        runner_mode="$(stat -c '%a' "$M3U8_RELAY_RUNNER" 2>/dev/null || echo "")"
        if [ "$runner_owner" = "root:root" ] && [ "$runner_mode" = "700" ]; then
            _diag_pass "Relay runner is root:root/700 (not writable by m3u8-relay or www-data)."
        else
            _diag_fail "Relay runner is ${runner_owner:-unknown}/${runner_mode:-unknown}, expected root:root/700 - the script systemd runs as root could potentially be modified by an unprivileged identity."
        fi
    else
        _diag_warn "Relay runner not found ($M3U8_RELAY_RUNNER)."
    fi
    if [ -f "$M3U8_RELAY_SYSTEMD_TEMPLATE" ]; then
        local unit_owner
        unit_owner="$(stat -c '%U:%G' "$M3U8_RELAY_SYSTEMD_TEMPLATE" 2>/dev/null || echo "")"
        if [ "$unit_owner" = "root:root" ]; then
            _diag_pass "Relay systemd unit installed (root:root)."
        else
            _diag_fail "Relay systemd unit is owned by '$unit_owner', expected root:root."
        fi
    else
        _diag_warn "Relay systemd template not found ($M3U8_RELAY_SYSTEMD_TEMPLATE)."
    fi

    local relay_count=0 relay_healthy=0 relay_failed=0 relay_stale=0 rname rstate
    for rname in $(list_relay_names 2>/dev/null || true); do
        relay_count=$((relay_count + 1))
        rstate="$(relay_health "$rname")"
        case "$rstate" in
            HEALTHY) relay_healthy=$((relay_healthy + 1)) ;;
            STALE) relay_stale=$((relay_stale + 1)) ;;
            STOPPED|OFFLINE) relay_failed=$((relay_failed + 1)) ;;
        esac
    done
    if [ "$relay_count" -gt 0 ]; then
        _diag_pass "$relay_count relay(s) configured ($relay_healthy healthy, $relay_stale stale, $relay_failed stopped/offline)."
        [ "$relay_stale" -gt 0 ] && _diag_warn "$relay_stale relay(s) reporting STALE output - HLS is not updating even though the service is running."
        [ "$relay_failed" -gt 0 ] && _diag_warn "$relay_failed relay(s) are stopped/offline."
    else
        _diag_warn "No relays configured yet."
    fi
}
