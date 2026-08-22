#!/usr/bin/env bash
# lib/osdetect.sh - detects the Linux distribution, Ubuntu version and CPU
# architecture, and decides whether this machine is supported. Sourced after
# common.sh.

if [ -n "${M3U8_OSDETECT_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_OSDETECT_LOADED=1

OS_ID=""
OS_VERSION_ID=""
OS_PRETTY_NAME=""
OS_ARCH=""

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        OS_ID="$(. /etc/os-release && printf '%s' "${ID:-}")"
        OS_VERSION_ID="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
        OS_PRETTY_NAME="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-}")"
    fi
    OS_ARCH="$(uname -m)"
}

# Returns 0 if OS_ID/OS_VERSION_ID are a version this project actively
# supports. New releases can be supported by adding one entry to
# M3U8_SUPPORTED_UBUNTU in lib/common.sh.
is_supported_os() {
    local v
    [ "$OS_ID" = "ubuntu" ] || return 1
    for v in "${M3U8_SUPPORTED_UBUNTU[@]}"; do
        [ "$v" = "$OS_VERSION_ID" ] && return 0
    done
    return 1
}

# Prints a human-readable report and, on an unsupported OS, explains what was
# detected and what is supported without modifying anything on the machine.
report_unsupported_os() {
    print_banner "UNSUPPORTED OPERATING SYSTEM"
    printf 'Detected: %s\n' "${OS_PRETTY_NAME:-unknown}"
    printf 'Distribution ID: %s\n' "${OS_ID:-unknown}"
    printf 'Version: %s\n' "${OS_VERSION_ID:-unknown}"
    printf 'Architecture: %s\n\n' "${OS_ARCH:-unknown}"
    printf 'This installer supports the following Ubuntu releases:\n'
    local v
    for v in "${M3U8_SUPPORTED_UBUNTU[@]}"; do
        printf '  - Ubuntu %s LTS\n' "$v"
    done
    printf '\nNo changes have been made to this system.\n'
}

# Ensures required core prerequisites (curl, ca-certificates, gnupg) exist
# before any package-specific logic runs. Safe to call multiple times.
ensure_base_prerequisites() {
    apt_install curl ca-certificates gnupg lsb-release
}
