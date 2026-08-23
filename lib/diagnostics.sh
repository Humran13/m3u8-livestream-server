#!/usr/bin/env bash
# lib/diagnostics.sh - read-only health checks. Nothing in this file ever
# changes system state; it only reports PASS/WARNING/FAIL so it is always
# safe to run.

if [ -n "${M3U8_DIAGNOSTICS_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_DIAGNOSTICS_LOADED=1

_diag_pass() { printf '[PASS]    %s\n' "$1"; }
_diag_warn() { printf '[WARNING] %s\n' "$1"; }
_diag_fail() { printf '[FAIL]    %s\n' "$1"; }

port_listening() {
    local port="$1"
    if command_exists ss; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[.:]${port}\$"
    elif command_exists netstat; then
        netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE "[.:]${port}\$"
    else
        return 2
    fi
}

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

    if systemctl is-active --quiet nginx; then
        _diag_pass "Nginx service is running."
    else
        _diag_fail "Nginx service is not running. Run: sudo systemctl status nginx"
    fi

    if output="$(nginx -t 2>&1)"; then
        _diag_pass "Nginx configuration is valid."
    else
        _diag_fail "Nginx configuration test failed."
        printf '%s\n' "$output" | sed 's/^/          /'
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
        if [ -w "$M3U8_HLS_DIR" ]; then
            _diag_pass "HLS directory exists and is writable: $M3U8_HLS_DIR"
        else
            _diag_fail "HLS directory exists but is not writable: $M3U8_HLS_DIR"
        fi
        if find "$M3U8_HLS_DIR" -maxdepth 1 -name '*.m3u8' -print -quit 2>/dev/null | grep -q .; then
            _diag_pass "At least one HLS playlist is currently present (a stream may be live)."
        else
            _diag_warn "No HLS playlists present right now (no stream is currently live)."
        fi
    else
        _diag_fail "HLS directory does not exist: $M3U8_HLS_DIR"
    fi

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
}
