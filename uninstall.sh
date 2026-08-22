#!/usr/bin/env bash
# uninstall.sh - conservative uninstaller for the M3U8 Livestream Server.
#
# Removes only what this project created. Never removes the nginx or
# certbot packages, unrelated sites, unrelated certificates, or unrelated
# firewall rules unless explicitly confirmed for that specific item.
#
# Usage:
#   sudo ./uninstall.sh

set -Eeuo pipefail

_m3u8_source="${BASH_SOURCE[0]}"
while [ -h "$_m3u8_source" ]; do
    _m3u8_dir="$(cd -P "$(dirname "$_m3u8_source")" && pwd)"
    _m3u8_source="$(readlink "$_m3u8_source")"
    [[ "$_m3u8_source" != /* ]] && _m3u8_source="${_m3u8_dir}/${_m3u8_source}"
done
M3U8_SCRIPT_DIR="$(cd -P "$(dirname "$_m3u8_source")" && pwd)"
M3U8_PROJECT_ROOT="$M3U8_SCRIPT_DIR"

# shellcheck source=lib/common.sh
source "${M3U8_SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/nginx.sh
source "${M3U8_SCRIPT_DIR}/lib/nginx.sh"
# shellcheck source=lib/firewall.sh
source "${M3U8_SCRIPT_DIR}/lib/firewall.sh"

require_root "$@"

print_banner "M3U8 LIVESTREAM SERVER - UNINSTALL"
log_warn "This will remove the M3U8 Livestream Server installation from this machine."
log_warn "You will be asked separately before anything destructive happens."
printf '\n'

if [ ! -f "$M3U8_SERVER_CONF" ] && [ ! -d "$M3U8_INSTALL_DIR" ]; then
    log_info "No installation was found (no $M3U8_SERVER_CONF, no $M3U8_INSTALL_DIR). Nothing to do."
    exit 0
fi

if ! confirm "Proceed with uninstalling the M3U8 Livestream Server?" "n"; then
    log_info "Uninstall cancelled."
    exit 0
fi

DOMAIN="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"

# ---------------------------------------------------------------------------
# Step 1: remove the manager/status commands
# ---------------------------------------------------------------------------
if [ -L "$M3U8_MANAGER_LINK" ] || [ -e "$M3U8_MANAGER_LINK" ]; then
    rm -f "$M3U8_MANAGER_LINK"
    log_ok "Removed $M3U8_MANAGER_LINK"
fi
if [ -L "$M3U8_STATUS_LINK" ] || [ -e "$M3U8_STATUS_LINK" ]; then
    rm -f "$M3U8_STATUS_LINK"
    log_ok "Removed $M3U8_STATUS_LINK"
fi

# ---------------------------------------------------------------------------
# Step 2: remove this project's nginx configuration only
# ---------------------------------------------------------------------------
if [ -L "$M3U8_NGINX_SITE_LINK" ]; then
    rm -f "$M3U8_NGINX_SITE_LINK"
fi
if [ -f "$M3U8_NGINX_SITE_FILE" ]; then
    rm -f "$M3U8_NGINX_SITE_FILE"
    log_ok "Removed $M3U8_NGINX_SITE_FILE"
fi
if [ -f "$M3U8_NGINX_RTMP_CONF" ]; then
    rm -f "$M3U8_NGINX_RTMP_CONF"
    log_ok "Removed $M3U8_NGINX_RTMP_CONF"
fi

# Remove only the two lines this project added to nginx.conf, identified by
# the marker comment. The rest of nginx.conf is left untouched.
if [ -f "$M3U8_NGINX_CONF" ] && grep -qF "$M3U8_RTMP_INCLUDE_MARKER" "$M3U8_NGINX_CONF"; then
    backup_file "$M3U8_NGINX_CONF" >/dev/null
    grep -vF -e "$M3U8_RTMP_INCLUDE_MARKER" -e "$M3U8_RTMP_INCLUDE_LINE" "$M3U8_NGINX_CONF" \
        | atomic_write "$M3U8_NGINX_CONF" 644
    log_ok "Removed the RTMP include line from $M3U8_NGINX_CONF (backup kept alongside it)."
fi

if command_exists nginx; then
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        log_ok "Nginx reloaded with this project's configuration removed."
    else
        log_error "Nginx configuration test failed after removing this project's files."
        log_error "Nginx was NOT reloaded. Please inspect $M3U8_NGINX_CONF manually."
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: optional removal of HLS media files
# ---------------------------------------------------------------------------
if [ -d "$M3U8_WEB_ROOT" ]; then
    if confirm "Delete web root and HLS media files at $M3U8_WEB_ROOT?" "n"; then
        rm -rf "${M3U8_WEB_ROOT:?}"
        log_ok "Removed $M3U8_WEB_ROOT"
    else
        log_info "Kept $M3U8_WEB_ROOT"
    fi
fi

# ---------------------------------------------------------------------------
# Step 4: optional removal of SSL certificate for the configured domain
# ---------------------------------------------------------------------------
if [ -n "$DOMAIN" ] && command_exists certbot && [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    if confirm "Delete the Let's Encrypt certificate for ${DOMAIN}? (other domains' certificates are never touched)" "n"; then
        certbot delete --cert-name "$DOMAIN" --non-interactive || log_error "Certificate removal failed; you can retry with: certbot delete --cert-name $DOMAIN"
    else
        log_info "Kept the SSL certificate for $DOMAIN."
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: optional removal of UFW rules added by this project
# ---------------------------------------------------------------------------
if ufw_installed && ufw_is_active; then
    if confirm "Remove the UFW firewall rules this project added (tagged 'm3u8-server:')?" "n"; then
        while :; do
            num="$(ufw status numbered | grep 'm3u8-server:' | grep -oE '^\[[0-9]+\]' | tr -d '[]' | sort -rn | head -n1 || true)"
            [ -n "$num" ] || break
            ufw --force delete "$num" || break
        done
        log_ok "Removed this project's UFW rules. Any other rules were left untouched."
    fi
fi

# ---------------------------------------------------------------------------
# Step 6: configuration, keys, and backups
# ---------------------------------------------------------------------------
if [ -d "$M3U8_CONFIG_DIR" ]; then
    log_warn "$M3U8_CONFIG_DIR contains channel records and stream keys."
    if confirm "Permanently delete $M3U8_CONFIG_DIR (including any backups inside it)?" "n"; then
        rm -rf "${M3U8_CONFIG_DIR:?}"
        log_ok "Removed $M3U8_CONFIG_DIR"
    else
        log_info "Kept $M3U8_CONFIG_DIR"
    fi
fi

# ---------------------------------------------------------------------------
# Step 7: installed project files
# ---------------------------------------------------------------------------
if [ -d "$M3U8_INSTALL_DIR" ]; then
    rm -rf "${M3U8_INSTALL_DIR:?}"
    log_ok "Removed $M3U8_INSTALL_DIR"
fi

# ---------------------------------------------------------------------------
# Step 8: optional package removal (never automatic)
# ---------------------------------------------------------------------------
if confirm "Also remove the nginx, RTMP module, certbot and ffmpeg packages from this system? (Not recommended if you installed them for other purposes)" "n"; then
    DEBIAN_FRONTEND=noninteractive apt-get remove -y nginx libnginx-mod-rtmp certbot python3-certbot-nginx ffmpeg || true
    log_ok "Removed packages."
else
    log_info "Left nginx/certbot/ffmpeg packages installed."
fi

printf '\n'
print_banner "UNINSTALL COMPLETE"
log_info "The M3U8 Livestream Server has been removed from this machine."
