#!/usr/bin/env bash
# install.sh - M3U8 Livestream Server installer.
#
# Usage:
#   sudo bash install.sh                     interactive install (recommended)
#   sudo ./install.sh --domain example.com --email admin@example.com [options]
#
# Run with --help for the full list of non-interactive options.

set -Eeuo pipefail

M3U8_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M3U8_PROJECT_ROOT="$M3U8_SCRIPT_DIR"
# shellcheck source=lib/common.sh
source "${M3U8_SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/osdetect.sh
source "${M3U8_SCRIPT_DIR}/lib/osdetect.sh"
# shellcheck source=lib/nginx.sh
source "${M3U8_SCRIPT_DIR}/lib/nginx.sh"
# shellcheck source=lib/streams.sh
source "${M3U8_SCRIPT_DIR}/lib/streams.sh"
# shellcheck source=lib/ssl.sh
source "${M3U8_SCRIPT_DIR}/lib/ssl.sh"
# shellcheck source=lib/firewall.sh
source "${M3U8_SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/relay.sh
source "${M3U8_SCRIPT_DIR}/lib/relay.sh"
# shellcheck source=lib/diagnostics.sh
source "${M3U8_SCRIPT_DIR}/lib/diagnostics.sh"
# shellcheck source=lib/selftest.sh
source "${M3U8_SCRIPT_DIR}/lib/selftest.sh"

trap 'log_error "Installation aborted (line $LINENO). No further changes will be made."' ERR

# ---------------------------------------------------------------------------
# CLI options / non-interactive mode
# ---------------------------------------------------------------------------
OPT_DOMAIN="${M3U8_DOMAIN:-}"
OPT_EMAIL="${M3U8_EMAIL:-}"
OPT_RTMP_APP="${M3U8_RTMP_APP:-}"
OPT_CHANNEL="${M3U8_CHANNEL:-}"
OPT_STREAM_KEY="${M3U8_STREAM_KEY:-}"
OPT_SSL="${M3U8_SSL:-}"
OPT_FIREWALL="${M3U8_FIREWALL:-}"
OPT_HLS_FRAGMENT="${M3U8_HLS_FRAGMENT:-4}"
OPT_HLS_PLAYLIST_LENGTH="${M3U8_HLS_PLAYLIST_LENGTH:-30}"
OPT_NONINTERACTIVE=0

print_help() {
    cat <<'EOF'
M3U8 Livestream Server installer

Interactive mode (default):
  sudo bash install.sh

Non-interactive mode:
  sudo ./install.sh --domain stream.example.com --email admin@example.com \
      [--rtmp-app live] [--channel main] [--stream-key <hex>|auto] \
      [--ssl yes|no] [--firewall yes|no] \
      [--hls-fragment 4] [--hls-playlist-length 30] [--yes]

Options:
  --domain <name>              Domain name pointing at this server (required for --yes)
  --email <address>            Administrator email, used for Let's Encrypt (required for --yes)
  --rtmp-app <name>             RTMP application name (default: live)
  --channel <name>              Name of the first channel to create (default: main)
  --stream-key <hex|auto>        Stream key for the first channel (default: auto)
  --ssl <yes|no>                 Enable HTTPS via Let's Encrypt (default: yes)
  --firewall <yes|no>            Configure UFW (default: ask/no)
  --hls-fragment <seconds>       HLS segment duration (default: 4)
  --hls-playlist-length <secs>   HLS playlist length (default: 30)
  --yes                          Run fully non-interactively using the above options
  -h, --help                     Show this help text

Environment variables M3U8_DOMAIN, M3U8_EMAIL, M3U8_RTMP_APP, M3U8_CHANNEL,
M3U8_STREAM_KEY, M3U8_SSL, M3U8_FIREWALL are equivalent to the flags above.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --domain) OPT_DOMAIN="$2"; shift 2 ;;
        --email) OPT_EMAIL="$2"; shift 2 ;;
        --rtmp-app) OPT_RTMP_APP="$2"; shift 2 ;;
        --channel) OPT_CHANNEL="$2"; shift 2 ;;
        --stream-key) OPT_STREAM_KEY="$2"; shift 2 ;;
        --ssl) OPT_SSL="$2"; shift 2 ;;
        --firewall) OPT_FIREWALL="$2"; shift 2 ;;
        --hls-fragment) OPT_HLS_FRAGMENT="$2"; shift 2 ;;
        --hls-playlist-length) OPT_HLS_PLAYLIST_LENGTH="$2"; shift 2 ;;
        --yes) OPT_NONINTERACTIVE=1; shift ;;
        -h|--help) print_help; exit 0 ;;
        *) die "Unknown option: $1 (see --help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
require_root "$@"

detect_os
if ! is_supported_os; then
    report_unsupported_os
    exit 1
fi

ensure_dir "$M3U8_CONFIG_DIR" 750 root:root
print_banner "M3U8 LIVESTREAM SERVER - INSTALLER"
printf 'Detected: %s (%s, %s)\n' "$OS_PRETTY_NAME" "${OS_CODENAME:-unknown codename}" "$OS_ARCH"
printf 'Kernel: %s\n' "${OS_KERNEL:-unknown}"
printf 'Project root: %s\n\n' "$M3U8_PROJECT_ROOT"

ALREADY_INSTALLED=0
if [ -f "$M3U8_SERVER_CONF" ]; then
    ALREADY_INSTALLED=1
    log_info "An existing installation was detected. Settings will be reused where possible; press Enter to keep a shown default."
fi

# Whether a first channel needs to be created is decided by whether one
# already exists, NOT by whether server.conf exists. A previous run can
# legitimately have written server.conf and then failed before ever
# reaching add_stream (exactly what happened during the real Ubuntu 24.04
# test, which aborted at the firewall step) - gating on ALREADY_INSTALLED
# alone would then skip channel creation forever on every future rerun.
HAS_EXISTING_CHANNELS=0
if [ -n "$(list_stream_names 2>/dev/null || true)" ]; then
    HAS_EXISTING_CHANNELS=1
    log_info "Existing channel(s) detected; their stream keys will not be touched."
fi

# ---------------------------------------------------------------------------
# Gather configuration (interactive unless --yes was given)
# ---------------------------------------------------------------------------
existing_domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"
existing_email="$(conf_get "$M3U8_SERVER_CONF" ADMIN_EMAIL 2>/dev/null || echo "")"
existing_rtmp_app="$(conf_get "$M3U8_SERVER_CONF" RTMP_APP 2>/dev/null || echo "")"
existing_ssl="$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED 2>/dev/null || echo "")"

if [ "$OPT_NONINTERACTIVE" -eq 1 ]; then
    DOMAIN="$OPT_DOMAIN"
    EMAIL="$OPT_EMAIL"
    RTMP_APP="${OPT_RTMP_APP:-${existing_rtmp_app:-$M3U8_RTMP_APP_DEFAULT}}"
    SSL_CHOICE="${OPT_SSL:-${existing_ssl:-yes}}"
    FIREWALL_CHOICE="${OPT_FIREWALL:-no}"
    CHANNEL_NAME="${OPT_CHANNEL:-main}"
    STREAM_KEY_CHOICE="${OPT_STREAM_KEY:-auto}"
    [ -n "$DOMAIN" ] || die "--domain is required with --yes"
    [ -n "$EMAIL" ] || die "--email is required with --yes"
else
    while :; do
        DOMAIN="$(ask "Domain name for this server" "${OPT_DOMAIN:-$existing_domain}")"
        is_valid_domain "$DOMAIN" && break
        log_error "'$DOMAIN' does not look like a valid domain name. Example: stream.example.com"
    done
    while :; do
        EMAIL="$(ask "Administrator email (used for Let's Encrypt renewal notices)" "${OPT_EMAIL:-$existing_email}")"
        is_valid_email "$EMAIL" && break
        log_error "'$EMAIL' does not look like a valid email address."
    done
    while :; do
        RTMP_APP="$(ask "RTMP application name" "${OPT_RTMP_APP:-${existing_rtmp_app:-$M3U8_RTMP_APP_DEFAULT}}")"
        is_valid_rtmp_app_name "$RTMP_APP" && break
        log_error "RTMP application name must be lowercase letters, digits, - or _ (2-32 chars)."
    done

    if confirm "Enable HTTPS with a free Let's Encrypt certificate?" "y"; then
        SSL_CHOICE="yes"
    else
        SSL_CHOICE="no"
    fi

    if confirm "Configure the UFW firewall for this server now?" "n"; then
        FIREWALL_CHOICE="yes"
    else
        FIREWALL_CHOICE="no"
    fi

    if [ "$HAS_EXISTING_CHANNELS" -eq 0 ]; then
        while :; do
            CHANNEL_NAME="$(ask "Name for your first stream/channel" "main")"
            is_valid_channel_name "$CHANNEL_NAME" && break
            log_error "Channel names must be lowercase letters, digits, - or _ (2-32 chars), and not a reserved word."
        done
        if confirm "Automatically generate a secure stream key for '$CHANNEL_NAME'?" "y"; then
            STREAM_KEY_CHOICE="auto"
        else
            while :; do
                STREAM_KEY_CHOICE="$(ask "Enter a stream key (8-128 chars: letters, digits, - or _)" "")"
                is_valid_stream_key "$STREAM_KEY_CHOICE" && break
                log_error "Stream key must be 8-128 characters using only letters, digits, - or _."
            done
        fi
    fi
fi

SSL_ENABLED="false"
[ "$SSL_CHOICE" = "yes" ] && SSL_ENABLED="true"

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
ensure_base_prerequisites
install_nginx_rtmp
ensure_rtmp_include

ensure_dir "$M3U8_CONFIG_DIR" 750 root:root
ensure_dir "$M3U8_STREAMS_DIR" 700 root:root
ensure_dir "$M3U8_NGINX_GEN_DIR" 750 root:root
ensure_dir "$M3U8_HLS_DIR" 755 www-data:www-data
ensure_dir "$M3U8_WEB_ROOT" 755 www-data:www-data

log_info "Copying web player files to $M3U8_WEB_ROOT"
cp -a "${M3U8_PROJECT_ROOT}/web/." "${M3U8_WEB_ROOT}/"
chown -R www-data:www-data "$M3U8_WEB_ROOT"
find "$M3U8_WEB_ROOT" -maxdepth 1 -type d -exec chmod 755 {} \;

conf_set "$M3U8_SERVER_CONF" DOMAIN "$DOMAIN"
conf_set "$M3U8_SERVER_CONF" ADMIN_EMAIL "$EMAIL"
conf_set "$M3U8_SERVER_CONF" RTMP_APP "$RTMP_APP"
conf_set "$M3U8_SERVER_CONF" SSL_ENABLED "$SSL_ENABLED"
conf_set "$M3U8_SERVER_CONF" HLS_FRAGMENT "$OPT_HLS_FRAGMENT"
conf_set "$M3U8_SERVER_CONF" HLS_PLAYLIST_LENGTH "$OPT_HLS_PLAYLIST_LENGTH"
if [ "$ALREADY_INSTALLED" -eq 0 ]; then
    conf_set "$M3U8_SERVER_CONF" INSTALL_DATE "$(date -Iseconds)"
    # Never overridden on a rerun - if an administrator switched this to
    # "off" for diagnostics, reinstalling must not silently re-secure (or
    # re-expose) it out from under them.
    conf_set "$M3U8_SERVER_CONF" AUTH_MODE "$M3U8_AUTH_MODE_DEFAULT"
fi
conf_set "$M3U8_SERVER_CONF" VERSION "$(cat "${M3U8_PROJECT_ROOT}/VERSION" 2>/dev/null || echo "dev")"
chmod 640 "$M3U8_SERVER_CONF"

write_rtmp_conf "$RTMP_APP" "${OPT_HLS_FRAGMENT}s" "${OPT_HLS_PLAYLIST_LENGTH}s"

# Bring the site up over HTTP first (or straight to SSL, if a certificate
# for this domain already exists from a previous run - e.g. recovering
# from a run that got a certificate but then failed later, as happened in
# the real Ubuntu 24.04 test). activate_site_config never leaves an
# invalid candidate active: it validates before touching anything, and
# falls back to HTTP-only automatically if the SSL candidate doesn't pass.
CERT_PATH=""
KEY_PATH=""
if [ "$SSL_ENABLED" = "true" ] && certificate_exists "$DOMAIN"; then
    log_info "Reusing existing Let's Encrypt certificate for $DOMAIN (no new certificate will be requested)."
    CERT_PATH="$(cert_path_for "$DOMAIN")"
    KEY_PATH="$(key_path_for "$DOMAIN")"
fi

log_info "Generating and validating the Nginx site configuration..."
SSL_ENABLED="$(activate_site_config "$DOMAIN" "$SSL_ENABLED" "$CERT_PATH" "$KEY_PATH")" \
    || die "Neither the SSL nor the HTTP Nginx configuration could be validated. See output above. The previous working configuration (if any) was not touched."
conf_set "$M3U8_SERVER_CONF" SSL_ENABLED "$SSL_ENABLED"
regenerate_streamkeys_map || true

systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx
log_ok "Nginx is configured and running."

# If SSL was requested but there's still no certificate, try to obtain one
# now and re-activate the site config with it. A failure here (DNS not
# ready, certbot unavailable, rate limits, etc.) must not take down the
# HTTP service that is already running.
if [ "$SSL_ENABLED" = "false" ] && [ "$SSL_CHOICE" = "yes" ] && ! certificate_exists "$DOMAIN"; then
    if install_certbot && obtain_certificate "$DOMAIN" "$EMAIL"; then
        SSL_ENABLED="$(activate_site_config "$DOMAIN" "true" "$(cert_path_for "$DOMAIN")" "$(key_path_for "$DOMAIN")")"
        conf_set "$M3U8_SERVER_CONF" SSL_ENABLED "$SSL_ENABLED"
        regenerate_streamkeys_map || true
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
        if [ "$SSL_ENABLED" = "true" ]; then
            log_ok "SSL enabled for $DOMAIN."
        else
            log_warn "SSL could not be enabled; continuing on HTTP only."
        fi
    else
        log_warn "Could not obtain an SSL certificate; continuing on HTTP only. Retry later from m3u8-manager's SSL Management menu."
    fi
fi

if [ "$FIREWALL_CHOICE" = "yes" ]; then
    ssh_ports_display="$(detect_ssh_ports | tr '\n' ',' | sed 's/,$//')"
    log_warn "About to configure UFW. This will allow: SSH (${ssh_ports_display}/tcp), HTTP (80/tcp)$( [ "$SSL_ENABLED" = "true" ] && printf ', HTTPS (443/tcp)' ) and RTMP (${M3U8_RTMP_PORT}/tcp)."
    if [ "$OPT_NONINTERACTIVE" -eq 1 ] || confirm "Proceed?" "y"; then
        # A firewall problem (e.g. ufw missing/uninstallable) must not
        # abort an otherwise-successful install - this is exactly what
        # happened during the real Ubuntu 24.04 test.
        setup_firewall "$SSL_ENABLED" \
            || log_error "Firewall setup did not complete. Continuing with the rest of the installation; you can retry from m3u8-manager."
    else
        log_info "Firewall setup skipped."
    fi
fi

if [ "$HAS_EXISTING_CHANNELS" -eq 0 ]; then
    if stream_exists "$CHANNEL_NAME"; then
        # A previous run got far enough to create this channel but failed
        # later (e.g. at the firewall step); do not touch its key.
        log_info "Channel '$CHANNEL_NAME' already exists; leaving its stream key unchanged."
    else
        if [ "$STREAM_KEY_CHOICE" = "auto" ] || [ -z "$STREAM_KEY_CHOICE" ]; then
            FIRST_KEY="$(generate_stream_key)"
        else
            FIRST_KEY="$STREAM_KEY_CHOICE"
        fi
        add_stream "$CHANNEL_NAME" "$CHANNEL_NAME" "$FIRST_KEY" "true"
    fi
fi
sync_channels_json "$DOMAIN" "$SSL_ENABLED"

# ---------------------------------------------------------------------------
# Install the manager + status command launchers
# ---------------------------------------------------------------------------
log_info "Installing project files to $M3U8_INSTALL_DIR"
mkdir -p "$M3U8_INSTALL_DIR"
cp -a "${M3U8_PROJECT_ROOT}/lib" "${M3U8_PROJECT_ROOT}/config" "${M3U8_PROJECT_ROOT}/m3u8-manager" \
    "${M3U8_PROJECT_ROOT}/status.sh" "${M3U8_PROJECT_ROOT}/uninstall.sh" "${M3U8_PROJECT_ROOT}/VERSION" \
    "$M3U8_INSTALL_DIR/"
chmod +x "$M3U8_INSTALL_DIR/m3u8-manager" "$M3U8_INSTALL_DIR/status.sh" "$M3U8_INSTALL_DIR/uninstall.sh"

ln -sf "$M3U8_INSTALL_DIR/m3u8-manager" "$M3U8_MANAGER_LINK"
ln -sf "$M3U8_INSTALL_DIR/status.sh" "$M3U8_STATUS_LINK"
log_ok "Installed commands: m3u8-manager, m3u8-status"

# ---------------------------------------------------------------------------
# Relay subsystem (Phase B) - additive, never touches the RTMP-publish
# path above. A relay failure here is not fatal to the rest of the
# install; OBS publishing must keep working even if FFmpeg is somehow
# unavailable.
# ---------------------------------------------------------------------------
RELAY_SUBSYSTEM_READY=1
if install_relay_runtime; then
    log_ok "Relay subsystem installed."
else
    RELAY_SUBSYSTEM_READY=0
    log_warn "Relay subsystem could not be fully installed; relay features will be unavailable. RTMP publish/HLS is unaffected."
fi

# ---------------------------------------------------------------------------
# Verify before declaring success - a package finishing "install" is not
# the same as the server actually working.
# ---------------------------------------------------------------------------
printf '\n'
print_banner "VERIFYING INSTALLATION"
INSTALL_HEALTHY=1
test_nginx >/dev/null 2>&1 && _diag_pass "Nginx configuration is valid" || { _diag_fail "Nginx configuration is valid"; INSTALL_HEALTHY=0; }
nginx_is_running && _diag_pass "Nginx service is running" || { _diag_fail "Nginx service is running"; INSTALL_HEALTHY=0; }
port_listening "$M3U8_RTMP_PORT" && _diag_pass "RTMP port ${M3U8_RTMP_PORT} is listening" || { _diag_fail "RTMP port ${M3U8_RTMP_PORT} is listening"; INSTALL_HEALTHY=0; }
test_auth_endpoint || INSTALL_HEALTHY=0
test_hls_directory_writable || INSTALL_HEALTHY=0
if [ "$SSL_ENABLED" = "true" ]; then
    port_listening 443 && _diag_pass "HTTPS port 443 is listening" || _diag_warn "HTTPS port 443 is not listening"
fi
if [ "$FIREWALL_CHOICE" = "yes" ]; then
    if ufw_installed && ufw_is_active; then _diag_pass "UFW firewall is active"; else _diag_warn "Firewall was requested but is not active - see the firewall messages above"; fi
fi

RELAY_HEALTHY=0
if [ "$OPT_NONINTERACTIVE" -eq 0 ]; then
    printf '\n'
    if confirm "Run a full end-to-end RTMP -> HLS self-test now? (publishes a ~14s synthetic test stream to a temporary channel, then removes it)" "y"; then
        printf '\n'
        run_e2e_streaming_test || INSTALL_HEALTHY=0
    fi

    if [ "$RELAY_SUBSYSTEM_READY" -eq 1 ]; then
        printf '\n'
        if confirm "Run the relay subsystem self-test now? (generates a tiny local test clip and relays it through a temporary channel, then removes it)" "y"; then
            printf '\n'
            run_relay_e2e_test && RELAY_HEALTHY=1
        fi
    fi
else
    log_info "Skipping the interactive self-tests in non-interactive mode. Run them later: sudo m3u8-manager -> options 26/28."
fi

# ---------------------------------------------------------------------------
# Completion screen
# ---------------------------------------------------------------------------
SCHEME="http"; [ "$SSL_ENABLED" = "true" ] && SCHEME="https"
printf '\n'
if [ "$INSTALL_HEALTHY" -eq 1 ]; then
    print_banner "M3U8 LIVESTREAM SERVER INSTALLED"
else
    print_banner "INSTALLATION COMPLETED WITH ERRORS"
    log_warn "One or more verification checks above failed. Review them before relying on this server - run 'sudo m3u8-manager' -> Server Diagnostics for details."
fi
printf 'Domain:\n%s\n\n' "$DOMAIN"
printf 'WEB PLAYER:\n%s://%s/\n\n' "$SCHEME" "$DOMAIN"
if [ "$HAS_EXISTING_CHANNELS" -eq 0 ]; then
    printf 'OBS SETTINGS\n\n'
    print_obs_settings "$CHANNEL_NAME"
    printf '\n\nM3U8 URL:\n%s\n\n' "$(hls_url_for "$CHANNEL_NAME")"
else
    printf 'Existing channel(s) were left unchanged. Use "sudo m3u8-manager" -> Show OBS Settings for their details.\n\n'
fi
if [ "$RELAY_SUBSYSTEM_READY" -eq 1 ]; then
    if [ "$RELAY_HEALTHY" -eq 1 ]; then
        printf 'Relay subsystem: PASS (self-test succeeded)\n\n'
    else
        printf 'Relay subsystem: installed, not yet verified - run "sudo m3u8-manager" -> Relay Management -> Run Relay Self-Test\n\n'
    fi
else
    printf 'Relay subsystem: NOT AVAILABLE (see warnings above)\n\n'
fi
printf 'MANAGE SERVER:\n\nsudo m3u8-manager\n\n'
printf 'CHECK STATUS:\n\nsudo m3u8-manager\nor\nsudo m3u8-status\n\n'
printf '========================================\n'
