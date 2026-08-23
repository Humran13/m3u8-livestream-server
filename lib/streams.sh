#!/usr/bin/env bash
# lib/streams.sh - channel/stream CRUD backed by /etc/m3u8-server/streams/*.conf.
# Every mutating function here re-syncs the nginx stream-key map and the
# public channel manifest, then does a safe (test-before-reload) nginx
# reload, so callers never have to touch nginx directly.

if [ -n "${M3U8_STREAMS_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_STREAMS_LOADED=1

stream_file() {
    printf '%s/%s.conf' "$M3U8_STREAMS_DIR" "$1"
}

stream_exists() {
    [ -f "$(stream_file "$1")" ]
}

# Returns 0 if the given stream key is already assigned to any existing
# channel. A manually-entered key that collides with another channel's key
# would otherwise produce a duplicate Nginx map entry, which fails
# `nginx -t` outright - reject it up front instead.
key_in_use() {
    local key="$1" file existing
    [ -d "$M3U8_STREAMS_DIR" ] || return 1
    for file in "$M3U8_STREAMS_DIR"/*.conf; do
        [ -e "$file" ] || continue
        existing="$(conf_get "$file" STREAM_KEY || echo "")"
        [ -n "$existing" ] && [ "$existing" = "$key" ] && return 0
    done
    return 1
}

# Applies pending metadata changes to nginx: regenerate the map + manifest,
# validate, and reload only if valid. regenerate_streamkeys_map is itself
# transactional (it restores the previous working map on failure), so a
# failure here never leaves an invalid map active - but it does mean the
# metadata change that was just saved has NOT taken effect in the live
# configuration, which is surfaced clearly here rather than silently
# reported as success.
apply_stream_changes() {
    local domain ssl_enabled
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN || echo "")"
    ssl_enabled="$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED || echo "false")"
    if ! regenerate_streamkeys_map; then
        log_error "The channel change was saved, but could NOT be applied to the live Nginx configuration (see above). Nginx continues running with its previous, still-working configuration."
    fi
    [ -n "$domain" ] && sync_channels_json "$domain" "$ssl_enabled"
    reload_nginx
}

list_stream_names() {
    local file
    [ -d "$M3U8_STREAMS_DIR" ] || return 0
    for file in "$M3U8_STREAMS_DIR"/*.conf; do
        [ -e "$file" ] || continue
        basename "$file" .conf
    done
}

add_stream() {
    local name="$1" display_name="$2" key="$3" enabled="${4:-true}"
    is_valid_channel_name "$name" || die "Invalid channel name: $name"
    stream_exists "$name" && die "A channel named '$name' already exists."
    is_valid_stream_key "$key" || die "Stream key must be 8-128 characters using only letters, digits, - or _."
    key_in_use "$key" && die "That stream key is already assigned to another channel. Choose a different key or use automatic generation."

    ensure_dir "$M3U8_STREAMS_DIR" 700 root:root
    {
        printf 'NAME="%s"\n' "$name"
        printf 'DISPLAY_NAME="%s"\n' "${display_name:-$name}"
        printf 'STREAM_KEY="%s"\n' "$key"
        printf 'ENABLED="%s"\n' "$enabled"
        printf 'CREATED_AT="%s"\n' "$(date -Iseconds)"
    } | atomic_write "$(stream_file "$name")" 600
    log_ok "Channel '$name' created."
    apply_stream_changes || true
}

remove_stream() {
    local name="$1" purge_hls="${2:-false}" file
    file="$(stream_file "$name")"
    stream_exists "$name" || die "No channel named '$name' exists."
    local key
    key="$(conf_get "$file" STREAM_KEY || echo "")"
    rm -f "$file"
    log_ok "Channel '$name' removed."
    if [ "$purge_hls" = "true" ] && [ -n "$key" ]; then
        rm -f "${M3U8_HLS_DIR:?}/${key}."*.ts "${M3U8_HLS_DIR:?}/${key}.m3u8" 2>/dev/null || true
        log_info "HLS files for '$name' deleted."
    fi
    apply_stream_changes || true
}

set_stream_enabled() {
    local name="$1" enabled="$2" file
    file="$(stream_file "$name")"
    stream_exists "$name" || die "No channel named '$name' exists."
    conf_set "$file" ENABLED "$enabled"
    chmod 600 "$file"
    apply_stream_changes || true
}

enable_stream()  { set_stream_enabled "$1" "true"; }
disable_stream() { set_stream_enabled "$1" "false"; }

regenerate_stream_key() {
    local name="$1" file new_key
    file="$(stream_file "$name")"
    stream_exists "$name" || die "No channel named '$name' exists."
    new_key="$(generate_stream_key)"
    conf_set "$file" STREAM_KEY "$new_key"
    chmod 600 "$file"
    apply_stream_changes || true
    printf '%s' "$new_key"
}

get_stream_field() {
    conf_get "$(stream_file "$1")" "$2"
}

print_stream_summary_line() {
    local name="$1" enabled display hls_state playlist
    enabled="$(get_stream_field "$name" ENABLED)"
    display="$(get_stream_field "$name" DISPLAY_NAME)"
    local key
    key="$(get_stream_field "$name" STREAM_KEY)"
    playlist="${M3U8_HLS_DIR}/${key}.m3u8"
    if [ -f "$playlist" ]; then hls_state="live"; else hls_state="offline"; fi
    printf '%-20s %-24s %-10s %s\n' "$name" "$display" "$enabled" "$hls_state"
}

# Prints the exact OBS "Custom" service settings for one channel.
print_obs_settings() {
    local name="$1" domain rtmp_app key
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN)"
    rtmp_app="$(conf_get "$M3U8_SERVER_CONF" RTMP_APP)"
    key="$(get_stream_field "$name" STREAM_KEY)"
    printf 'Service:\nCustom\n\n'
    printf 'Server:\nrtmp://%s/%s\n\n' "$domain" "$rtmp_app"
    printf 'Stream Key:\n%s\n' "$key"
}

hls_url_for() {
    local name="$1" domain ssl_enabled scheme key
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN)"
    ssl_enabled="$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED || echo "false")"
    scheme="http"; [ "$ssl_enabled" = "true" ] && scheme="https"
    key="$(get_stream_field "$name" STREAM_KEY)"
    printf '%s://%s/hls/%s.m3u8' "$scheme" "$domain" "$key"
}

player_url_for() {
    local name="$1" domain ssl_enabled scheme
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN)"
    ssl_enabled="$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED || echo "false")"
    scheme="http"; [ "$ssl_enabled" = "true" ] && scheme="https"
    printf '%s://%s/watch/%s' "$scheme" "$domain" "$name"
}
