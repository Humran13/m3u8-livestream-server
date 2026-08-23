#!/usr/bin/env bash
# lib/relay-runner.sh - executed by systemd (m3u8-relay@<name>.service).
#
# This script deliberately STARTS AS ROOT (the systemd unit sets no
# User=/Group=) so it can read this relay's config from a root:root/700/600
# file that may contain source-URL credentials/tokens - deliberately not
# readable by www-data or any other unrelated service identity. That root
# context is brief and purely local (read one file, prepare one output
# directory): it never touches the network. Immediately after building the
# FFmpeg argument list, this execs into `setpriv`, which permanently drops
# to the unprivileged m3u8-relay account before FFmpeg - the process that
# actually talks to the network - ever starts. This is a root-controlled
# launcher, not a root-running relay process; FFmpeg itself never runs as
# root, and once setpriv has switched users there is no path back to root
# (NoNewPrivileges is also set at the systemd-unit level).
#
# Config is read safely via conf_get (never sourced - a config file is
# just data, even though it contains a user-supplied source URL). FFmpeg
# is invoked as a real Bash argument array, never a shell string.
#
# Usage: relay-runner.sh <relay-name>
# Not meant to be run interactively - use m3u8-manager's Relay Management
# menu, which starts/stops this via systemctl.

set -Eeuo pipefail

_m3u8_source="${BASH_SOURCE[0]}"
while [ -h "$_m3u8_source" ]; do
    _m3u8_dir="$(cd -P "$(dirname "$_m3u8_source")" && pwd)"
    _m3u8_source="$(readlink "$_m3u8_source")"
    [[ "$_m3u8_source" != /* ]] && _m3u8_source="${_m3u8_dir}/${_m3u8_source}"
done
M3U8_SCRIPT_DIR="$(cd -P "$(dirname "$_m3u8_source")" && pwd)"
# Deliberately NOT setting M3U8_PROJECT_ROOT here: this script lives inside
# lib/ itself (unlike install.sh/m3u8-manager/status.sh, which live at the
# project root), so common.sh's own fallback - PROJECT_ROOT = dirname of
# M3U8_SCRIPT_DIR - correctly resolves to the actual project root.

# shellcheck source=lib/common.sh
source "${M3U8_SCRIPT_DIR}/common.sh"

if [ "$(id -u)" -ne 0 ]; then
    echo "relay-runner.sh must start as root (it reads root-only relay config, then drops privileges itself before running FFmpeg - see the comment at the top of this file). Refusing to run as a non-root user." >&2
    exit 1
fi

# Fail closed, loudly, and BEFORE touching any config, if either half of
# the privilege-drop mechanism is missing. There is no fallback path in
# this script that runs FFmpeg without both of these - if either check
# fails, the script exits here and FFmpeg never starts, as root or
# otherwise.
if ! command_exists setpriv; then
    echo "setpriv (util-linux) is not available - refusing to start FFmpeg without a way to drop privileges. Relay '$1' will not run." >&2
    exit 1
fi
if ! id -u "$M3U8_RELAY_USER" >/dev/null 2>&1; then
    echo "the '$M3U8_RELAY_USER' system user does not exist - refusing to start FFmpeg without an unprivileged account to drop into. Relay '$1' will not run." >&2
    exit 1
fi

RELAY_NAME="${1:?relay name required}"
is_valid_relay_name "$RELAY_NAME" || { echo "invalid relay name: $RELAY_NAME" >&2; exit 1; }

RELAY_CONF="${M3U8_RELAYS_DIR}/${RELAY_NAME}.conf"
[ -f "$RELAY_CONF" ] || { echo "no such relay: $RELAY_NAME ($RELAY_CONF not found)" >&2; exit 1; }

SOURCE_TYPE="$(conf_get "$RELAY_CONF" SOURCE_TYPE || echo "")"
SOURCE_URL="$(conf_get "$RELAY_CONF" SOURCE_URL || echo "")"
MODE="$(conf_get "$RELAY_CONF" MODE || echo "copy")"
LOOP="$(conf_get "$RELAY_CONF" LOOP || echo "false")"
RTSP_TRANSPORT="$(conf_get "$RELAY_CONF" RTSP_TRANSPORT || echo "tcp")"
ENABLED="$(conf_get "$RELAY_CONF" ENABLED || echo "false")"

is_valid_relay_source_type "$SOURCE_TYPE" || { echo "invalid SOURCE_TYPE in $RELAY_CONF: $SOURCE_TYPE" >&2; exit 1; }
is_valid_relay_source_url "$SOURCE_URL" || { echo "invalid/unsafe SOURCE_URL in $RELAY_CONF" >&2; exit 1; }
is_valid_relay_mode "$MODE" || MODE="copy"
is_valid_rtsp_transport "$RTSP_TRANSPORT" || RTSP_TRANSPORT="tcp"

if [ "$ENABLED" != "true" ]; then
    echo "relay '$RELAY_NAME' is disabled; exiting without publishing" >&2
    exit 0
fi

OUT_DIR="${M3U8_RELAY_HLS_DIR}/${RELAY_NAME}"
# Re-validate at this privileged boundary rather than trusting that
# RELAY_NAME was validated earlier in this same run: this directory is
# about to be created and chowned as root, so it must provably resolve
# under the relay HLS root and nowhere else, no matter what.
case "$OUT_DIR" in
    "${M3U8_RELAY_HLS_DIR}/"*) ;;
    *)
        echo "refusing to create/chown an output directory outside $M3U8_RELAY_HLS_DIR: $OUT_DIR" >&2
        exit 1
        ;;
esac
mkdir -p "$OUT_DIR"
# Still root here: make sure the unprivileged user can write its own
# output directory once privileges are dropped below.
chown "${M3U8_RELAY_USER}:${M3U8_RELAY_USER}" "$OUT_DIR"

# For a local-file source, check (as the actual target user, via setpriv,
# not as root - root can read almost anything, which would make this
# check meaningless) that the unprivileged process will actually be able
# to open the file, and fail with a clear message now rather than a more
# cryptic FFmpeg error later. This never modifies permissions - if it
# fails, the fix is to move the file into the managed media directory
# (owned so the relay user can read it) or adjust its permissions
# manually, not something this script does automatically.
if [ "$SOURCE_TYPE" = "local" ]; then
    if [ ! -e "$SOURCE_URL" ]; then
        echo "local source file does not exist: $SOURCE_URL" >&2
        exit 1
    fi
    if ! setpriv --reuid "$M3U8_RELAY_USER" --regid "$M3U8_RELAY_USER" --init-groups -- test -r "$SOURCE_URL"; then
        echo "local source file exists but is not readable by user '$M3U8_RELAY_USER': $SOURCE_URL (move it into $M3U8_MEDIA_DIR via the manager's import/cache flow, or adjust its permissions)" >&2
        exit 1
    fi
fi

# --- input arguments, built as a real array - never a shell string ---------
input_args=(-hide_banner -loglevel warning -nostdin)

case "$SOURCE_TYPE" in
    local)
        [ "$LOOP" = "true" ] && input_args+=(-stream_loop -1)
        input_args+=(-re -i "$SOURCE_URL")
        ;;
    http)
        input_args+=(-reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5)
        [ "$LOOP" = "true" ] && input_args+=(-stream_loop -1 -re)
        input_args+=(-i "$SOURCE_URL")
        ;;
    hls)
        # A live remote HLS source already arrives in real time - do not
        # add -re, which would fight its own natural pacing.
        input_args+=(-reconnect 1 -reconnect_at_eof 1 -reconnect_streamed 1 -reconnect_delay_max 5)
        input_args+=(-i "$SOURCE_URL")
        ;;
    rtmp|rtmps)
        # The RTMP demuxer has no -reconnect_* equivalent; reconnection on
        # a dropped RTMP source is handled by systemd's Restart=on-failure
        # restarting this whole runner, not by FFmpeg internally.
        input_args+=(-i "$SOURCE_URL")
        ;;
    rtsp)
        input_args+=(-rtsp_transport "$RTSP_TRANSPORT" -timeout 10000000 -i "$SOURCE_URL")
        ;;
esac

# --- output codec arguments --------------------------------------------
if [ "$MODE" = "copy" ]; then
    output_codec_args=(-c:v copy -c:a copy)
else
    output_codec_args=(-c:v libx264 -preset veryfast -c:a aac -b:a 128k)
fi

# --- HLS muxer arguments -------------------------------------------------
hls_args=(
    -f hls
    -hls_time "$M3U8_RELAY_HLS_SEGMENT_SECONDS"
    -hls_list_size "$M3U8_RELAY_HLS_LIST_SIZE"
    -hls_flags delete_segments+independent_segments
    -hls_segment_filename "${OUT_DIR}/seg-%08d.ts"
    "${OUT_DIR}/index.m3u8"
)

echo "starting relay '$RELAY_NAME': type=$SOURCE_TYPE mode=$MODE loop=$LOOP (dropping to user '$M3U8_RELAY_USER' before FFmpeg starts)" >&2

# Permanent, one-way privilege drop. From this exec onward the running
# process is FFmpeg as $M3U8_RELAY_USER with no path back to root -
# NoNewPrivileges=true at the systemd-unit level (already in effect for
# this whole process tree since before this script started) additionally
# guarantees nothing exec'd from here can regain privilege via a
# setuid/capability-bearing binary. Known residual exposure: FFmpeg's own
# argv (including the source URL) is visible via /proc/<pid>/cmdline to
# root and, per Ubuntu's default /proc mount options, to other local
# users on this VPS - narrowing that further would require either
# verified FFmpeg support for reading -i from a file/fd (not confirmed)
# or a system-wide hidepid= mount change, which is a separate, broader
# hardening decision outside this fix's scope.
exec setpriv --reuid "$M3U8_RELAY_USER" --regid "$M3U8_RELAY_USER" \
    --init-groups --inh-caps=-all --no-new-privs -- \
    ffmpeg "${input_args[@]}" "${output_codec_args[@]}" "${hls_args[@]}"
