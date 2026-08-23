#!/usr/bin/env bash
# lib/relay.sh - Phase B: 24/7 source relay/repackaging. Pulls an existing
# source (local file, remote HLS, RTMP/RTMPS, RTSP, HTTP media) and
# republishes it as this server's own HLS output, stream-copied by default
# (no re-encoding) and supervised by a systemd template unit running as an
# unprivileged user. Entirely additive: never touches the RTMP-publish
# auth path in lib/nginx.sh or lib/streams.sh.

if [ -n "${M3U8_RELAY_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_RELAY_LOADED=1

relay_file() {
    printf '%s/%s.conf' "$M3U8_RELAYS_DIR" "$1"
}

relay_exists() {
    [ -f "$(relay_file "$1")" ]
}

list_relay_names() {
    local file
    [ -d "$M3U8_RELAYS_DIR" ] || return 0
    for file in "$M3U8_RELAYS_DIR"/*.conf; do
        [ -e "$file" ] || continue
        basename "$file" .conf
    done
}

get_relay_field() {
    conf_get "$(relay_file "$1")" "$2"
}

# Masks credentials/tokens in a source URL for display: keeps the scheme
# and host, replaces userinfo and query string with a fixed placeholder.
# Never used for the value actually handed to FFmpeg.
redact_source_url() {
    local url="$1" scheme_host rest
    if [[ "$url" == *'://'* ]]; then
        scheme_host="${url%%'://'*}://"
        rest="${url#*'://'}"
        rest="${rest%%[/?]*}"
        rest="${rest##*@}"
        printf '%s%s/********' "$scheme_host" "$rest"
    else
        printf '%s' "$url" | sed -E 's#(://)?[^/]*$#[REDACTED]#'
    fi
}

# cache_remote_media <url> <name>
# Downloads a remote static media file into the managed media directory
# once, so a looped relay reads a stable local copy instead of repeatedly
# re-fetching (and hammering) the remote server. Bounded by a generous but
# finite timeout - never hangs the caller forever. Prints the local path
# on success.
cache_remote_media() {
    local url="$1" name="$2" dest ext
    # root:relay-group/750 (relay reads via the group bit, cannot write) -
    # matches the ownership model set up in install_relay_runtime.
    ensure_dir "$M3U8_MEDIA_DIR" 750 "root:${M3U8_RELAY_USER}"
    ext="${url##*.}"
    ext="${ext%%\?*}"
    case "$ext" in
        [Mm][Pp]4|[Mm][Kk][Vv]|[Mm][Oo][Vv]|[Tt][Ss]|[Ww][Ee][Bb][Mm]) : ;;
        *) ext="mp4" ;;
    esac
    dest="${M3U8_MEDIA_DIR}/${name}.${ext}"
    log_info "Downloading source media to $dest (this may take a while for large files)..."
    if ! curl -fL --max-time 1800 --retry 2 -o "$dest" "$url"; then
        rm -f "$dest"
        return 1
    fi
    # root:relay-group/640 - the relay user can read (group bit), but
    # cannot write/modify its own source file at runtime.
    chown "root:${M3U8_RELAY_USER}" "$dest" 2>/dev/null || true
    chmod 640 "$dest"
    printf '%s' "$dest"
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------
# Creates the dedicated, unprivileged relay system account if it doesn't
# already exist. A system account (no login shell, no home directory) -
# deliberately NOT www-data, so the Nginx worker identity has no path to
# reading relay secrets.
ensure_relay_user() {
    id -u "$M3U8_RELAY_USER" >/dev/null 2>&1 && return 0
    useradd --system --no-create-home --shell /usr/sbin/nologin \
        --comment "M3U8 Livestream Server relay runner" "$M3U8_RELAY_USER"
    log_ok "Created system user '$M3U8_RELAY_USER' for relay processes."
}

# Installs everything the relay subsystem needs. Idempotent: safe on every
# install/rerun, never touches an existing relay's config.
install_relay_runtime() {
    ensure_command ffmpeg ffmpeg \
        || { log_error "FFmpeg could not be installed; relay mode will not be available."; return 1; }
    ensure_command ffprobe ffmpeg \
        || log_warn "ffprobe is unavailable even though ffmpeg installed; source detection will be limited."
    ensure_command setpriv util-linux \
        || { log_error "setpriv (util-linux) is unavailable; the relay runner cannot safely drop privileges, relay mode will not be available."; return 1; }

    ensure_relay_user

    # Persistent relay config is root:root/700/600 - deliberately NOT
    # owned by the relay user. Only root (the manager) and the runner's
    # own root-context bootstrap (see lib/relay-runner.sh) ever read it.
    ensure_dir "$M3U8_RELAYS_DIR" 700 root:root

    # HLS output is meant to be public, so it's owned by the unprivileged
    # relay user directly (it writes it at runtime, Nginx reads it).
    ensure_dir "$M3U8_RELAY_HLS_DIR" 755 "${M3U8_RELAY_USER}:${M3U8_RELAY_USER}"

    # Media is imported/cached content, not a secret, but the relay
    # process only ever needs to READ it - only root (via the manager's
    # import/cache flow) writes here. root:relay-group/750 gives the
    # relay user read access via the group bit without write access.
    ensure_dir "$M3U8_MEDIA_DIR" 750 "root:${M3U8_RELAY_USER}"

    local restrict_suidsgid_line="" systemd_ver
    systemd_ver="$(detect_systemd_version 2>/dev/null || echo 0)"
    if [ -n "$systemd_ver" ] && [ "$systemd_ver" -ge 242 ] 2>/dev/null; then
        restrict_suidsgid_line="RestrictSUIDSGID=true"
    fi

    render_template "${M3U8_PROJECT_ROOT}/config/systemd/m3u8-relay@.service.template" \
        "$M3U8_RELAY_SYSTEMD_TEMPLATE" 644 \
        "RELAY_USER=${M3U8_RELAY_USER}" \
        "RELAY_RUNNER=${M3U8_RELAY_RUNNER}" \
        "RELAY_HLS_ROOT=${M3U8_RELAY_HLS_DIR}" \
        "RESTRICT_SUIDSGID_LINE=${restrict_suidsgid_line}"

    # Install the runner atomically and with explicit, verified ownership:
    # write to a temp file in the SAME directory (so the final mv is an
    # atomic rename, never a truncate-in-place), set root:root/700 BEFORE
    # it becomes reachable at its real path, then swap it in. There is no
    # window where the path systemd will later exec as root is writable
    # by an unprivileged user.
    mkdir -p "$(dirname "$M3U8_RELAY_RUNNER")"
    local runner_tmp
    runner_tmp="$(mktemp "$(dirname "$M3U8_RELAY_RUNNER")/.relay-runner.XXXXXX")"
    cp "${M3U8_PROJECT_ROOT}/lib/relay-runner.sh" "$runner_tmp"
    chown root:root "$runner_tmp"
    chmod 700 "$runner_tmp"
    mv -f "$runner_tmp" "$M3U8_RELAY_RUNNER"

    systemctl daemon-reload 2>/dev/null || true

    # Explicit privilege-boundary verification - do not merely assume the
    # steps above worked. If any of these are wrong, refuse to mark the
    # relay subsystem ready rather than silently continue.
    local verify_ok=1
    if [ "$(stat -c '%U:%G' "$M3U8_RELAY_RUNNER" 2>/dev/null)" != "root:root" ]; then
        log_error "Relay runner ($M3U8_RELAY_RUNNER) is not root:root owned."
        verify_ok=0
    fi
    if [ "$(stat -c '%a' "$M3U8_RELAY_RUNNER" 2>/dev/null)" != "700" ]; then
        log_error "Relay runner ($M3U8_RELAY_RUNNER) has unexpected permissions (expected 700)."
        verify_ok=0
    fi
    if [ "$(stat -c '%U:%G' "$M3U8_RELAY_SYSTEMD_TEMPLATE" 2>/dev/null)" != "root:root" ]; then
        log_error "Relay systemd unit ($M3U8_RELAY_SYSTEMD_TEMPLATE) is not root:root owned."
        verify_ok=0
    fi
    if [ "$(stat -c '%U:%G' "$M3U8_RELAYS_DIR" 2>/dev/null)" != "root:root" ]; then
        log_error "Relay config directory ($M3U8_RELAYS_DIR) is not root:root owned."
        verify_ok=0
    fi
    if [ "$(stat -c '%a' "$M3U8_RELAYS_DIR" 2>/dev/null)" != "700" ]; then
        log_error "Relay config directory ($M3U8_RELAYS_DIR) has unexpected permissions (expected 700)."
        verify_ok=0
    fi
    if [ "$verify_ok" -eq 0 ]; then
        log_error "Relay privilege-boundary verification failed; relay subsystem will not be marked ready."
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Source inspection (ffprobe)
# ---------------------------------------------------------------------------
RELAY_PROBE_VIDEO_CODEC=""
RELAY_PROBE_WIDTH=""
RELAY_PROBE_HEIGHT=""
RELAY_PROBE_FPS=""
RELAY_PROBE_VBITRATE=""
RELAY_PROBE_AUDIO_CODEC=""
RELAY_PROBE_CHANNELS=""
RELAY_PROBE_SAMPLE_RATE=""
RELAY_PROBE_DURATION=""

# probe_relay_source <source_type> <url> [rtsp_transport]
# Populates the RELAY_PROBE_* globals. Bounded by a wall-clock timeout so a
# dead/slow source can never hang the caller. Returns 1 only if neither a
# video nor an audio stream could be detected at all.
probe_relay_source() {
    local source_type="$1" url="$2" rtsp_transport="${3:-tcp}"
    local extra_args=() vline aline dline probe_timeout=10

    [ "$source_type" = "rtsp" ] && extra_args=(-rtsp_transport "$rtsp_transport")

    RELAY_PROBE_VIDEO_CODEC=""; RELAY_PROBE_WIDTH=""; RELAY_PROBE_HEIGHT=""
    RELAY_PROBE_FPS=""; RELAY_PROBE_VBITRATE=""
    RELAY_PROBE_AUDIO_CODEC=""; RELAY_PROBE_CHANNELS=""; RELAY_PROBE_SAMPLE_RATE=""
    RELAY_PROBE_DURATION=""

    command_exists ffprobe || return 1

    vline="$(timeout "$probe_timeout" ffprobe -v error "${extra_args[@]}" \
        -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,bit_rate \
        -of csv=p=0 "$url" 2>/dev/null)" || true
    aline="$(timeout "$probe_timeout" ffprobe -v error "${extra_args[@]}" \
        -select_streams a:0 -show_entries stream=codec_name,channels,sample_rate \
        -of csv=p=0 "$url" 2>/dev/null)" || true
    dline="$(timeout "$probe_timeout" ffprobe -v error "${extra_args[@]}" \
        -show_entries format=duration -of csv=p=0 "$url" 2>/dev/null)" || true

    if [ -z "$vline" ] && [ -z "$aline" ]; then
        return 1
    fi

    if [ -n "$vline" ]; then
        IFS=',' read -r RELAY_PROBE_VIDEO_CODEC RELAY_PROBE_WIDTH RELAY_PROBE_HEIGHT RELAY_PROBE_FPS RELAY_PROBE_VBITRATE <<<"$vline"
    fi
    if [ -n "$aline" ]; then
        IFS=',' read -r RELAY_PROBE_AUDIO_CODEC RELAY_PROBE_CHANNELS RELAY_PROBE_SAMPLE_RATE <<<"$aline"
    fi
    if [ -n "$dline" ] && [ "$dline" != "N/A" ]; then
        RELAY_PROBE_DURATION="$dline"
    fi
    return 0
}

# True if the most recently probed source can go straight to HLS without
# re-encoding: H.264 video (if any) + AAC/MP3 audio (if any) is the safe,
# broadly browser/hls.js-compatible baseline.
relay_stream_copy_compatible() {
    local v_ok=1 a_ok=1
    if [ -n "$RELAY_PROBE_VIDEO_CODEC" ]; then
        case "$RELAY_PROBE_VIDEO_CODEC" in h264) v_ok=1 ;; *) v_ok=0 ;; esac
    fi
    if [ -n "$RELAY_PROBE_AUDIO_CODEC" ]; then
        case "$RELAY_PROBE_AUDIO_CODEC" in aac|mp3) a_ok=1 ;; *) a_ok=0 ;; esac
    fi
    [ "$v_ok" -eq 1 ] && [ "$a_ok" -eq 1 ]
}

print_relay_probe_summary() {
    printf 'Source detected\n\n'
    if [ -n "$RELAY_PROBE_VIDEO_CODEC" ]; then
        printf 'Video: %s\n' "$RELAY_PROBE_VIDEO_CODEC"
        [ -n "$RELAY_PROBE_WIDTH" ] && printf 'Resolution: %sx%s\n' "$RELAY_PROBE_WIDTH" "$RELAY_PROBE_HEIGHT"
        [ -n "$RELAY_PROBE_FPS" ] && printf 'Frame rate: %s\n' "$RELAY_PROBE_FPS"
        [ -n "$RELAY_PROBE_VBITRATE" ] && [ "$RELAY_PROBE_VBITRATE" != "N/A" ] && \
            printf 'Video bitrate: ~%s kbps\n' "$((RELAY_PROBE_VBITRATE / 1000))"
    else
        printf 'Video: none detected\n'
    fi
    if [ -n "$RELAY_PROBE_AUDIO_CODEC" ]; then
        printf 'Audio: %s' "$RELAY_PROBE_AUDIO_CODEC"
        [ -n "$RELAY_PROBE_SAMPLE_RATE" ] && printf ' (%s Hz' "$RELAY_PROBE_SAMPLE_RATE"
        [ -n "$RELAY_PROBE_CHANNELS" ] && printf ', %sch' "$RELAY_PROBE_CHANNELS"
        [ -n "$RELAY_PROBE_SAMPLE_RATE" ] && printf ')'
        printf '\n'
    else
        printf 'Audio: none detected\n'
    fi
    if [ -n "$RELAY_PROBE_DURATION" ]; then
        printf 'Duration: %s seconds (finite source)\n' "$RELAY_PROBE_DURATION"
    else
        printf 'Duration: live/unbounded\n'
    fi
    if relay_stream_copy_compatible; then
        printf '\nStream Copy: YES (no re-encoding needed)\n'
    else
        printf '\nStream Copy: NOT compatible - Compatibility Transcode required for browser/HLS playback.\n'
    fi
}

# ---------------------------------------------------------------------------
# CRUD
# ---------------------------------------------------------------------------
add_relay() {
    local name="$1" display="$2" source_type="$3" url="$4" mode="$5" \
        loop="$6" autostart="$7" rtsp_transport="${8:-tcp}"

    is_valid_relay_name "$name" || die "Invalid relay name: $name"
    relay_exists "$name" && die "A relay named '$name' already exists."
    if command_exists stream_exists && stream_exists "$name" 2>/dev/null; then
        die "A publish channel named '$name' already exists; relay and channel names share one namespace."
    fi
    is_valid_relay_source_type "$source_type" || die "Invalid relay source type: $source_type"
    is_valid_relay_mode "$mode" || die "Invalid relay mode: $mode"
    is_valid_relay_source_url "$url" || die "Source URL/path looks invalid or unsafe."
    is_valid_rtsp_transport "$rtsp_transport" || die "Invalid RTSP transport: $rtsp_transport"

    # root:root - deliberately never chowned to the relay user. This file
    # can hold source-URL credentials/tokens; only root (this manager) and
    # the runner's brief root-context bootstrap ever read it.
    ensure_dir "$M3U8_RELAYS_DIR" 700 root:root
    {
        printf 'NAME="%s"\n' "$name"
        printf 'DISPLAY_NAME="%s"\n' "${display:-$name}"
        printf 'SOURCE_TYPE="%s"\n' "$source_type"
        printf 'SOURCE_URL="%s"\n' "$url"
        printf 'MODE="%s"\n' "$mode"
        printf 'LOOP="%s"\n' "$loop"
        printf 'RTSP_TRANSPORT="%s"\n' "$rtsp_transport"
        printf 'AUTOSTART="%s"\n' "$autostart"
        printf 'ENABLED="true"\n'
        printf 'CREATED_AT="%s"\n' "$(date -Iseconds)"
    } | atomic_write "$(relay_file "$name")" 600
    log_ok "Relay '$name' created."

    systemctl daemon-reload 2>/dev/null || true
    if [ "$autostart" = "true" ]; then
        systemctl enable "m3u8-relay@${name}.service" >/dev/null 2>&1 || true
    fi
    sync_relay_manifest || true
}

# remove_relay <name> <purge_hls>
remove_relay() {
    local name="$1" purge_hls="${2:-false}" out_dir
    relay_exists "$name" || die "No relay named '$name' exists."

    systemctl stop "m3u8-relay@${name}.service" 2>/dev/null || true
    systemctl disable "m3u8-relay@${name}.service" 2>/dev/null || true

    rm -f "$(relay_file "$name")"
    log_ok "Relay '$name' removed."

    if [ "$purge_hls" = "true" ]; then
        out_dir="${M3U8_RELAY_HLS_DIR}/${name}"
        # Never delete without first proving the path is exactly the
        # expected per-relay subdirectory of the relay HLS root - never a
        # shared root, never something derived unsafely.
        case "$out_dir" in
            "${M3U8_RELAY_HLS_DIR}/"*)
                if [ -n "$name" ] && [ -d "$out_dir" ]; then
                    rm -rf -- "$out_dir"
                    log_info "HLS output for '$name' deleted."
                fi
                ;;
            *)
                log_error "Refused to delete unexpected path: $out_dir"
                ;;
        esac
    fi
    sync_relay_manifest || true
}

set_relay_enabled() {
    local name="$1" enabled="$2"
    relay_exists "$name" || die "No relay named '$name' exists."
    conf_set "$(relay_file "$name")" ENABLED "$enabled"
    chmod 600 "$(relay_file "$name")"
    if [ "$enabled" = "true" ]; then
        systemctl start "m3u8-relay@${name}.service" 2>&1 || log_warn "Relay '$name' enabled but failed to start; check the logs."
    else
        systemctl stop "m3u8-relay@${name}.service" 2>/dev/null || true
    fi
    sync_relay_manifest || true
}

enable_relay()  { set_relay_enabled "$1" "true"; }
disable_relay() { set_relay_enabled "$1" "false"; }

set_relay_source() {
    local name="$1" url="$2"
    relay_exists "$name" || die "No relay named '$name' exists."
    is_valid_relay_source_url "$url" || die "Source URL/path looks invalid or unsafe."
    conf_set "$(relay_file "$name")" SOURCE_URL "$url"
    chmod 600 "$(relay_file "$name")"
    log_ok "Source updated for relay '$name'. Restart it for the change to take effect."
}

start_relay()   { systemctl start "m3u8-relay@${1}.service"; }
stop_relay()    { systemctl stop "m3u8-relay@${1}.service"; }
restart_relay() {
    # Clear this relay's own previous HLS output before restarting, so a
    # stopped/failed relay's stale playlist never gets served as if it
    # were current. Only ever the exact per-relay subdirectory.
    local name="$1" out_dir="${M3U8_RELAY_HLS_DIR}/${1}"
    case "$out_dir" in
        "${M3U8_RELAY_HLS_DIR}/"*)
            [ -d "$out_dir" ] && rm -f "${out_dir}"/*.ts "${out_dir}"/index.m3u8 2>/dev/null || true
            ;;
    esac
    systemctl restart "m3u8-relay@${name}.service"
}

# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------
# Prints one of: DISABLED STOPPED STARTING OFFLINE STALE HEALTHY UNKNOWN
relay_health() {
    local name="$1" playlist mtime now age threshold
    relay_exists "$name" || { printf 'UNKNOWN'; return 1; }

    if [ "$(get_relay_field "$name" ENABLED)" != "true" ]; then
        printf 'DISABLED'; return 0
    fi

    if ! systemctl is-active --quiet "m3u8-relay@${name}.service"; then
        printf 'STOPPED'; return 0
    fi

    playlist="${M3U8_RELAY_HLS_DIR}/${name}/index.m3u8"
    if [ ! -f "$playlist" ]; then
        printf 'STARTING'; return 0
    fi

    mtime="$(stat -c %Y "$playlist" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$((now - mtime))
    threshold=$((M3U8_RELAY_HLS_SEGMENT_SECONDS * 4))
    if [ "$age" -gt "$threshold" ]; then
        printf 'STALE'
    else
        printf 'HEALTHY'
    fi
}

# relay_ffmpeg_identity_check <name>
# Verifies the REAL, currently-running process's UID - not what the
# systemd unit or config say should happen, but what the kernel actually
# has running. Resolves the service's MainPID (which, thanks to the
# runner's exec-only chain with no forking, IS the FFmpeg process itself
# once running) and inspects its actual owning user via /proc.
# Prints "PASS (m3u8-relay)" / "FAIL (<unexpected-user>)" / "UNKNOWN".
relay_ffmpeg_identity_check() {
    local name="$1" main_pid actual_user
    main_pid="$(systemctl show "m3u8-relay@${name}.service" -p MainPID --value 2>/dev/null || echo "0")"
    if [ -z "$main_pid" ] || [ "$main_pid" = "0" ]; then
        printf 'UNKNOWN (service not running)'
        return 1
    fi
    actual_user="$(ps -o user= -p "$main_pid" 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$actual_user" ]; then
        printf 'UNKNOWN (process not found)'
        return 1
    fi
    if [ "$actual_user" = "$M3U8_RELAY_USER" ]; then
        printf 'PASS (%s)' "$actual_user"
        return 0
    fi
    printf 'FAIL (running as %s, expected %s)' "$actual_user" "$M3U8_RELAY_USER"
    return 1
}

print_relay_status() {
    local name="$1" health domain scheme
    health="$(relay_health "$name")"
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"
    scheme="http"; [ "$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED 2>/dev/null || echo false)" = "true" ] && scheme="https"

    printf 'Relay: %s\n\n' "$name"
    printf 'Status: %s\n' "$health"
    if [ "$health" = "HEALTHY" ] || [ "$health" = "STALE" ] || [ "$health" = "STARTING" ]; then
        printf 'FFmpeg process identity: %s\n' "$(relay_ffmpeg_identity_check "$name")"
    fi
    printf 'Source type: %s\n' "$(get_relay_field "$name" SOURCE_TYPE)"
    printf 'Source: %s\n' "$(redact_source_url "$(get_relay_field "$name" SOURCE_URL)")"
    printf 'Mode: %s\n' "$(get_relay_field "$name" MODE)"
    printf 'Loop: %s\n' "$(get_relay_field "$name" LOOP)"
    printf 'Autostart at boot: %s\n' "$(get_relay_field "$name" AUTOSTART)"
    if [ -n "$domain" ]; then
        printf '\nM3U8:\n%s://%s/hls/relay/%s/index.m3u8\n' "$scheme" "$domain" "$name"
    fi
}

# ---------------------------------------------------------------------------
# Bandwidth estimator
# ---------------------------------------------------------------------------
# estimate_relay_bandwidth <bitrate_mbps> <viewers>
estimate_relay_bandwidth() {
    local bitrate="$1" viewers="$2" total monthly_gb
    total="$(awk -v b="$bitrate" -v v="$viewers" 'BEGIN{printf "%.1f", b*v}')"
    monthly_gb="$(awk -v b="$bitrate" 'BEGIN{printf "%.0f", (b*1000000/8)*86400*30/1000000000}')"

    printf 'Source bitrate: %s Mbps\n\n' "$bitrate"
    printf 'Incoming (from source): ~%s Mbps\n\n' "$bitrate"
    printf '%-12s %s\n' "Viewers" "Approx. outgoing"
    local n
    for n in 1 5 10 25 50 100 "$viewers"; do
        [ "$n" -gt 0 ] 2>/dev/null || continue
        printf '%-12s ~%s Mbps\n' "$n" "$(awk -v b="$bitrate" -v v="$n" 'BEGIN{printf "%.1f", b*v}')"
    done | sort -u -k1,1n
    printf '\nAt %s viewers, ~%s Mbps outgoing; approx. %s GB/month for the SOURCE alone if run 24/7 continuously (viewer traffic is additional and scales with concurrent viewers x uptime).\n' \
        "$viewers" "$total" "$monthly_gb"
    printf '\nA CDN or reverse-proxy cache in front of this server changes this model significantly (most viewer traffic would be served from the CDN edge, not this VPS).\n'
}

# ---------------------------------------------------------------------------
# Public manifest integration (additive - never touches how RTMP-publish
# channels are represented in lib/nginx.sh's sync_channels_json)
# ---------------------------------------------------------------------------
# Regenerates the relay portion of the public manifest at
# M3U8_RELAY_CHANNELS_JSON, a SEPARATE file from the RTMP-publish
# channels.generated.json (different subsystem, different trust model -
# relay source URLs must never end up in anything public). The web player
# merges both files client-side.
sync_relay_manifest() {
    local name domain scheme enabled display health first=1
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"
    scheme="http"; [ "$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED 2>/dev/null || echo false)" = "true" ] && scheme="https"
    ensure_dir "$M3U8_WEB_ROOT" 755 www-data:www-data

    {
        printf '[\n'
        for name in $(list_relay_names); do
            enabled="$(get_relay_field "$name" ENABLED)"
            [ "$enabled" = "true" ] || continue
            display="$(get_relay_field "$name" DISPLAY_NAME)"
            health="$(relay_health "$name")"
            [ "$first" -eq 1 ] || printf ',\n'
            first=0
            printf '  {"name": "%s", "displayName": "%s", "type": "relay", "status": "%s", "hlsUrl": "%s://%s/hls/relay/%s/index.m3u8", "playerUrl": "%s://%s/watch/%s"}' \
                "$name" "$display" "$health" "$scheme" "$domain" "$name" "$scheme" "$domain" "$name"
        done
        printf '\n]\n'
    } | atomic_write "$M3U8_RELAY_CHANNELS_JSON" 644
    chown www-data:www-data "$M3U8_RELAY_CHANNELS_JSON" 2>/dev/null || true
}
