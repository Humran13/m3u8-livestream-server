#!/usr/bin/env bash
# lib/common.sh - shared constants, logging, validation and helper functions
# for the M3U8 Livestream Server project. Sourced by install.sh, uninstall.sh,
# status.sh, m3u8-manager and the other lib/*.sh files. Never executed directly.

if [ -n "${M3U8_COMMON_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_COMMON_LOADED=1

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Project-wide paths and constants. Keep every other script pointed at these
# instead of hard-coding paths, so the on-disk layout only lives in one place.
# ---------------------------------------------------------------------------
M3U8_PROJECT_NAME="M3U8 Livestream Server"
M3U8_INSTALL_DIR="/opt/m3u8-server"
M3U8_CONFIG_DIR="/etc/m3u8-server"
M3U8_STREAMS_DIR="${M3U8_CONFIG_DIR}/streams"
M3U8_BACKUP_DIR="${M3U8_CONFIG_DIR}/backups"
M3U8_NGINX_GEN_DIR="${M3U8_CONFIG_DIR}/nginx"
M3U8_SERVER_CONF="${M3U8_CONFIG_DIR}/server.conf"
M3U8_STREAMKEYS_MAP="${M3U8_NGINX_GEN_DIR}/streamkeys.map"
M3U8_LOG_FILE="${M3U8_CONFIG_DIR}/install.log"

M3U8_WEB_ROOT="/var/www/m3u8-server"
M3U8_HLS_DIR="${M3U8_WEB_ROOT}/hls"
M3U8_CHANNELS_JSON="${M3U8_WEB_ROOT}/channels.generated.json"

M3U8_NGINX_CONF="/etc/nginx/nginx.conf"
M3U8_NGINX_RTMP_D="/etc/nginx/rtmp.d"
M3U8_NGINX_RTMP_CONF="${M3U8_NGINX_RTMP_D}/m3u8-server.conf"
M3U8_NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
M3U8_NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
M3U8_NGINX_SITE_NAME="m3u8-server.conf"
M3U8_NGINX_SITE_FILE="${M3U8_NGINX_SITES_AVAILABLE}/${M3U8_NGINX_SITE_NAME}"
M3U8_NGINX_SITE_LINK="${M3U8_NGINX_SITES_ENABLED}/${M3U8_NGINX_SITE_NAME}"

M3U8_AUTH_PORT="8899"
M3U8_RTMP_PORT="1935"
M3U8_RTMP_APP_DEFAULT="live"

M3U8_MANAGER_LINK="/usr/local/bin/m3u8-manager"
M3U8_STATUS_LINK="/usr/local/bin/m3u8-status"

M3U8_SUPPORTED_UBUNTU=("20.04" "22.04" "24.04" "26.04")

# Resolve the directory this project's scripts are running from, whether that
# is the git checkout (pre-install / dev usage) or the installed copy under
# M3U8_INSTALL_DIR. Every script that sources common.sh should set
# M3U8_SCRIPT_DIR *before* sourcing so PROJECT_ROOT can be derived here.
if [ -z "${M3U8_PROJECT_ROOT:-}" ]; then
    M3U8_PROJECT_ROOT="$(cd "${M3U8_SCRIPT_DIR:-.}/.." && pwd)"
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_m3u8_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_m3u8_log_line() {
    local level="$1"; shift
    local line="[${level}] $*"
    # Always to stderr: log/status output must never be captured by a
    # caller doing name="$(some_function ...)" to get a real return value.
    printf '%s\n' "$line" >&2
    if [ -w "$(dirname "$M3U8_LOG_FILE")" ] 2>/dev/null || [ -f "$M3U8_LOG_FILE" ] 2>/dev/null; then
        printf '%s %s\n' "$(_m3u8_ts)" "$line" >>"$M3U8_LOG_FILE" 2>/dev/null || true
    fi
}

log_info()  { _m3u8_log_line "INFO" "$*"; }
log_ok()    { _m3u8_log_line "OK" "$*"; }
log_warn()  { _m3u8_log_line "WARNING" "$*"; }
log_error() { _m3u8_log_line "ERROR" "$*"; }

die() {
    log_error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# Privilege / environment checks
# ---------------------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This command must be run as root. Try: sudo $0 $*"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Interactive helpers
# ---------------------------------------------------------------------------
# ask <prompt> <default>
# Prints the default inline and returns the trimmed user answer, or the
# default if the user just presses Enter. Never used for secrets.
ask() {
    local prompt="$1" default="${2:-}" answer
    if [ -n "$default" ]; then
        read -r -p "$prompt [$default]: " answer </dev/tty || answer=""
    else
        read -r -p "$prompt: " answer </dev/tty || answer=""
    fi
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    if [ -z "$answer" ]; then
        printf '%s' "$default"
    else
        printf '%s' "$answer"
    fi
}

# confirm <prompt> [default: y|n]
# Returns 0 for yes, 1 for no.
confirm() {
    local prompt="$1" default="${2:-n}" answer suffix
    if [ "$default" = "y" ]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
    read -r -p "$prompt $suffix: " answer </dev/tty || answer=""
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    if [ -z "$answer" ]; then answer="$default"; fi
    [ "$answer" = "y" ] || [ "$answer" = "yes" ]
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
# A domain must look like a real DNS hostname before we hand it to certbot.
is_valid_domain() {
    local domain="$1"
    [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_valid_email() {
    local email="$1"
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]
}

# Channel/stream names double as filenames and URL path segments, so they are
# restricted to a conservative safe set. Reserved words are blocked because
# they collide with real routes served by the generated nginx config.
is_valid_channel_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{1,31}$ ]] || return 1
    case "$name" in
        hls|watch|channels.generated.json|api|admin|auth|live|index|index.html) return 1 ;;
    esac
    return 0
}

is_valid_rtmp_app_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{1,31}$ ]]
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------
# Generates a 48-character lowercase hex stream key from the kernel CSPRNG.
# Hex-only output is intentionally safe to embed in nginx config, filenames,
# and URL paths without further escaping.
generate_stream_key() {
    if command_exists openssl; then
        openssl rand -hex 24
    else
        head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------
# Creates a timestamped backup copy of a file if it exists. Prints the backup
# path (or nothing if there was no source file to back up).
backup_file() {
    local src="$1" dest
    [ -e "$src" ] || return 0
    dest="${src}.bak.$(date '+%Y%m%d%H%M%S')"
    cp -a "$src" "$dest"
    printf '%s' "$dest"
}

# Writes content to a file atomically: write to a temp file in the same
# directory, then rename over the destination. Avoids leaving a half-written
# config file behind if the process is interrupted mid-write.
atomic_write() {
    local dest="$1" mode="${2:-644}" tmp
    tmp="$(mktemp "${dest}.tmp.XXXXXX")"
    cat >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$dest"
}

ensure_dir() {
    local dir="$1" mode="${2:-755}" owner="${3:-}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
    fi
    chmod "$mode" "$dir"
    if [ -n "$owner" ]; then
        chown "$owner" "$dir"
    fi
}

# ---------------------------------------------------------------------------
# Key/value config file helpers (used for server.conf and streams/*.conf)
# ---------------------------------------------------------------------------
# Reads a single KEY=value from a simple config file without sourcing it
# (sourcing arbitrary files would let a corrupted config file execute code).
conf_get() {
    local file="$1" key="$2" line
    [ -f "$file" ] || return 1
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1)" || true
    [ -n "$line" ] || return 1
    line="${line#"${key}="}"
    line="${line%$'\r'}"
    if [[ "$line" == \"*\" ]]; then
        line="${line#\"}"
        line="${line%\"}"
    fi
    printf '%s' "$line"
}

# Sets KEY="value" in a simple config file, creating the file or the key if
# needed, and rewriting the value in place if the key already exists.
conf_set() {
    local file="$1" key="$2" value="$3" tmp escaped dir
    escaped="${value//\"/\\\"}"
    dir="$(dirname "$file")"
    # Only create the directory if missing; never reset the mode of an
    # existing one (it may intentionally be 700/750 to protect stream keys).
    [ -d "$dir" ] || mkdir -p "$dir"
    if [ -f "$file" ] && grep -qE "^${key}=" "$file"; then
        tmp="$(mktemp "${file}.tmp.XXXXXX")"
        awk -v k="$key" -v v="${key}=\"${escaped}\"" \
            'BEGIN{FS="="} $1==k{print v; next} {print}' "$file" >"$tmp"
        mv -f "$tmp" "$file"
    else
        printf '%s="%s"\n' "$key" "$escaped" >>"$file"
    fi
}

# ---------------------------------------------------------------------------
# Package management
# ---------------------------------------------------------------------------
APT_UPDATED=0

apt_update_once() {
    if [ "$APT_UPDATED" -eq 0 ]; then
        log_info "Updating package metadata (apt-get update)..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        APT_UPDATED=1
    fi
}

# apt_install <pkg> [pkg...]
# Installs only packages that are not already present.
apt_install() {
    local pkgs=() pkg
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            pkgs+=("$pkg")
        fi
    done
    if [ "${#pkgs[@]}" -eq 0 ]; then
        return 0
    fi
    apt_update_once
    log_info "Installing packages: ${pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
}

package_available() {
    apt_update_once
    apt-cache show "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
public_ip() {
    curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
        || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
        || true
}

print_banner() {
    local title="$1"
    printf '========================================\n'
    printf '%s\n' "$title"
    printf '========================================\n'
}
