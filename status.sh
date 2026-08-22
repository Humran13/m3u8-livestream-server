#!/usr/bin/env bash
# status.sh - quick non-interactive status/diagnostics report.
#
# Usage:
#   sudo ./status.sh
#   sudo m3u8-status   (after install.sh has run)

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
# shellcheck source=lib/osdetect.sh
source "${M3U8_SCRIPT_DIR}/lib/osdetect.sh"
# shellcheck source=lib/nginx.sh
source "${M3U8_SCRIPT_DIR}/lib/nginx.sh"
# shellcheck source=lib/ssl.sh
source "${M3U8_SCRIPT_DIR}/lib/ssl.sh"
# shellcheck source=lib/firewall.sh
source "${M3U8_SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/diagnostics.sh
source "${M3U8_SCRIPT_DIR}/lib/diagnostics.sh"

require_root "$@"
detect_os

print_banner "M3U8 LIVESTREAM SERVER - STATUS"
printf 'OS: %s\n' "${OS_PRETTY_NAME:-unknown}"
printf 'Hostname: %s\n' "$(hostname)"

if [ ! -f "$M3U8_SERVER_CONF" ]; then
    log_warn "No installation found at $M3U8_CONFIG_DIR. Run install.sh first."
    exit 1
fi

printf 'Domain: %s\n' "$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo unknown)"
printf 'Nginx running: %s\n' "$(nginx_is_running 2>/dev/null && echo yes || echo no)"
printf '\n'
print_banner "DIAGNOSTICS"
run_diagnostics
