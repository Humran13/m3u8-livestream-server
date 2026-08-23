#!/usr/bin/env bash
# lib/firewall.sh - optional UFW helper. Never modifies firewall rules
# without an explicit, informed confirmation from the administrator, and
# always tries to detect the real SSH port first so a mistake here cannot
# lock the administrator out of the VPS.

if [ -n "${M3U8_FIREWALL_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_FIREWALL_LOADED=1

ufw_installed() {
    command_exists ufw
}

ufw_is_active() {
    ufw_installed || return 1
    ufw status 2>/dev/null | grep -qi "^Status: active"
}

# Detects the port(s) sshd is actually listening on, falling back to 22 if
# nothing more specific can be determined. This is what protects the
# administrator from being locked out by a firewall rule that only opens 22
# when SSH has been moved to another port.
detect_ssh_ports() {
    local ports=""
    if command_exists ss; then
        ports="$(ss -tlnp 2>/dev/null | awk '/sshd/{print $4}' | sed 's/.*://')"
    fi
    if [ -z "$ports" ] && [ -f /etc/ssh/sshd_config ]; then
        ports="$(grep -hE '^[[:space:]]*Port[[:space:]]+[0-9]+' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            | awk '{print $2}')"
    fi
    ports="$(printf '%s\n' "$ports" | grep -E '^[0-9]+$' | sort -un)"
    printf '%s' "${ports:-22}"
}

# Convenience wrapper returning a single representative port for display.
detect_ssh_port() {
    detect_ssh_ports | head -n1
}

firewall_status_report() {
    if ! ufw_installed; then
        printf 'UFW: not installed\n'
        return 0
    fi
    printf 'UFW: installed\n'
    if ufw_is_active; then
        printf 'Status: active\n\n'
        ufw status verbose
    else
        printf 'Status: inactive\n'
    fi
}

# Installs UFW and adds the rules this project needs (SSH, HTTP, HTTPS,
# RTMP), preserving any rules that already exist. Requires the caller to
# have already confirmed with the administrator - this function performs no
# confirmation of its own so it can also be used non-interactively when the
# administrator has already agreed via a CLI flag.
setup_firewall() {
    local ssl_enabled="$1" ssh_ports port

    # Do NOT trust dpkg package state alone here (see package_installed in
    # lib/common.sh) - a real Ubuntu 24.04 test had a stale dpkg record for
    # ufw that made a plain `apt_install ufw` believe it was already
    # present, when the actual binary was missing. Verify the real binary,
    # and fail this function gracefully (not the whole installer) if it
    # genuinely cannot be made available.
    if ! ensure_command ufw ufw; then
        log_error "Firewall configuration was requested, but the ufw package could not be installed (or its binary is still missing after installation)."
        log_error "Continuing without firewall changes. Retry later with: sudo apt-get install ufw, then reconfigure from m3u8-manager."
        return 1
    fi

    ssh_ports="$(detect_ssh_ports)"

    while IFS= read -r port; do
        [ -n "$port" ] || continue
        log_info "Allowing SSH on detected port $port"
        ufw allow "${port}/tcp" comment "m3u8-server: SSH"
    done <<<"$ssh_ports"

    log_info "Allowing HTTP (80/tcp)"
    ufw allow 80/tcp comment "m3u8-server: HTTP"

    if [ "$ssl_enabled" = "true" ]; then
        log_info "Allowing HTTPS (443/tcp)"
        ufw allow 443/tcp comment "m3u8-server: HTTPS"
    fi

    log_info "Allowing RTMP (${M3U8_RTMP_PORT}/tcp)"
    ufw allow "${M3U8_RTMP_PORT}/tcp" comment "m3u8-server: RTMP"

    if ! ufw_is_active; then
        ufw --force enable
    fi
    log_ok "Firewall rules applied."
    return 0
}
