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
printf 'Detected: %s (%s)\n' "$OS_PRETTY_NAME" "$OS_ARCH"
printf 'Project root: %s\n\n' "$M3U8_PROJECT_ROOT"

ALREADY_INSTALLED=0
if [ -f "$M3U8_SERVER_CONF" ]; then
    ALREADY_INSTALLED=1
    log_info "An existing installation was detected. Settings will be reused where possible; press Enter to keep a shown default."
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

    if [ "$ALREADY_INSTALLED" -eq 0 ]; then
        while :; do
            CHANNEL_NAME="$(ask "Name for your first stream/channel" "main")"
            is_valid_channel_name "$CHANNEL_NAME" && break
            log_error "Channel names must be lowercase letters, digits, - or _ (2-32 chars), and not a reserved word."
        done
        if confirm "Automatically generate a secure stream key for '$CHANNEL_NAME'?" "y"; then
            STREAM_KEY_CHOICE="auto"
        else
            STREAM_KEY_CHOICE="$(ask "Enter a stream key (letters/digits/-/_ only)" "")"
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
fi
conf_set "$M3U8_SERVER_CONF" VERSION "$(cat "${M3U8_PROJECT_ROOT}/VERSION" 2>/dev/null || echo "dev")"
chmod 640 "$M3U8_SERVER_CONF"

write_rtmp_conf "$RTMP_APP" "${OPT_HLS_FRAGMENT}s" "${OPT_HLS_PLAYLIST_LENGTH}s"

# HTTP config first (SSL config needs a working HTTP site for the ACME
# webroot challenge if a certificate does not exist yet).
CERT_PATH=""
KEY_PATH=""
if [ "$SSL_ENABLED" = "true" ] && certificate_exists "$DOMAIN"; then
    CERT_PATH="$(cert_path_for "$DOMAIN")"
    KEY_PATH="$(key_path_for "$DOMAIN")"
    write_http_conf "$DOMAIN" "true" "$CERT_PATH" "$KEY_PATH"
else
    write_http_conf "$DOMAIN" "false" "" ""
fi
regenerate_streamkeys_map

log_info "Testing nginx configuration..."
if ! test_nginx; then
    die "Generated nginx configuration is invalid. See output above. No service was reloaded."
fi
systemctl enable nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx
log_ok "Nginx is configured and running."

if [ "$SSL_ENABLED" = "true" ] && ! certificate_exists "$DOMAIN"; then
    install_certbot
    if obtain_certificate "$DOMAIN" "$EMAIL"; then
        CERT_PATH="$(cert_path_for "$DOMAIN")"
        KEY_PATH="$(key_path_for "$DOMAIN")"
        write_http_conf "$DOMAIN" "true" "$CERT_PATH" "$KEY_PATH"
        if test_nginx; then
            systemctl reload nginx
        else
            log_error "SSL configuration failed validation; continuing on HTTP only."
            write_http_conf "$DOMAIN" "false" "" ""
            systemctl reload nginx
            SSL_ENABLED="false"
            conf_set "$M3U8_SERVER_CONF" SSL_ENABLED "false"
        fi
    else
        SSL_ENABLED="false"
        conf_set "$M3U8_SERVER_CONF" SSL_ENABLED "false"
    fi
fi

if [ "$FIREWALL_CHOICE" = "yes" ]; then
    ssh_ports_display="$(detect_ssh_ports | tr '\n' ',' | sed 's/,$//')"
    log_warn "About to configure UFW. This will allow: SSH (${ssh_ports_display}/tcp), HTTP (80/tcp)$( [ "$SSL_ENABLED" = "true" ] && printf ', HTTPS (443/tcp)' ) and RTMP (${M3U8_RTMP_PORT}/tcp)."
    if [ "$OPT_NONINTERACTIVE" -eq 1 ] || confirm "Proceed?" "y"; then
        setup_firewall "$SSL_ENABLED"
    else
        log_info "Firewall setup skipped."
    fi
fi

if [ "$ALREADY_INSTALLED" -eq 0 ]; then
    if [ "$STREAM_KEY_CHOICE" = "auto" ] || [ -z "$STREAM_KEY_CHOICE" ]; then
        FIRST_KEY="$(generate_stream_key)"
    else
        FIRST_KEY="$STREAM_KEY_CHOICE"
    fi
    add_stream "$CHANNEL_NAME" "$CHANNEL_NAME" "$FIRST_KEY" "true"
else
    sync_channels_json "$DOMAIN" "$SSL_ENABLED"
fi

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
# Completion screen
# ---------------------------------------------------------------------------
SCHEME="http"; [ "$SSL_ENABLED" = "true" ] && SCHEME="https"
printf '\n'
print_banner "M3U8 LIVESTREAM SERVER INSTALLED"
printf 'Domain:\n%s\n\n' "$DOMAIN"
printf 'WEB PLAYER:\n%s://%s/\n\n' "$SCHEME" "$DOMAIN"
if [ "$ALREADY_INSTALLED" -eq 0 ]; then
    printf 'OBS SETTINGS\n\n'
    print_obs_settings "$CHANNEL_NAME"
    printf '\n\nM3U8 URL:\n%s\n\n' "$(hls_url_for "$CHANNEL_NAME")"
fi
printf 'MANAGE SERVER:\n\nsudo m3u8-manager\n\n'
printf 'CHECK STATUS:\n\nsudo m3u8-manager\nor\nsudo m3u8-status\n\n'
printf '========================================\n'
