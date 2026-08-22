#!/usr/bin/env bash
# lib/nginx.sh - installs nginx + the RTMP module, and generates/tests/
# reloads the project's isolated nginx configuration. Sourced after
# common.sh. Never touches unrelated sites or the main nginx.conf beyond a
# single idempotent include line required for the RTMP module.

if [ -n "${M3U8_NGINX_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_NGINX_LOADED=1

M3U8_RTMP_INCLUDE_MARKER="# m3u8-server: load RTMP module configuration"
M3U8_RTMP_INCLUDE_LINE="include ${M3U8_NGINX_RTMP_D}/*.conf;"

# render_template <template_file> <dest_file> <mode> "KEY=value" ...
# Simple __KEY__ substitution using bash string replacement, so paths and
# URLs containing '/' never break a sed delimiter.
render_template() {
    local template="$1" dest="$2" mode="$3"; shift 3
    local content pair key value
    content="$(cat "$template")"
    for pair in "$@"; do
        key="${pair%%=*}"
        value="${pair#*=}"
        content="${content//__${key}__/${value}}"
    done
    printf '%s\n' "$content" | atomic_write "$dest" "$mode"
}

install_nginx_rtmp() {
    log_info "Installing nginx and the RTMP module..."
    apt_install nginx
    if package_available libnginx-mod-rtmp; then
        apt_install libnginx-mod-rtmp
    else
        die "The libnginx-mod-rtmp package is not available for this Ubuntu release. Cannot continue without RTMP support."
    fi
    apt_install openssl
}

# Adds the single include line the RTMP module needs at the top level of
# nginx.conf, if it is not already present. Idempotent: safe to call on
# every install run.
ensure_rtmp_include() {
    ensure_dir "$M3U8_NGINX_RTMP_D" 755 root:root
    if grep -qF "$M3U8_RTMP_INCLUDE_LINE" "$M3U8_NGINX_CONF" 2>/dev/null; then
        return 0
    fi
    log_info "Adding RTMP module include to $M3U8_NGINX_CONF"
    backup_file "$M3U8_NGINX_CONF" >/dev/null
    {
        cat "$M3U8_NGINX_CONF"
        printf '\n%s\n%s\n' "$M3U8_RTMP_INCLUDE_MARKER" "$M3U8_RTMP_INCLUDE_LINE"
    } | atomic_write "$M3U8_NGINX_CONF" 644
}

write_rtmp_conf() {
    local rtmp_app="$1" hls_fragment="$2" hls_playlist_length="$3"
    render_template "${M3U8_PROJECT_ROOT}/config/nginx/rtmp.conf.template" \
        "$M3U8_NGINX_RTMP_CONF" 644 \
        "RTMP_PORT=${M3U8_RTMP_PORT}" \
        "RTMP_APP=${rtmp_app}" \
        "AUTH_PORT=${M3U8_AUTH_PORT}" \
        "HLS_DIR=${M3U8_HLS_DIR}" \
        "HLS_FRAGMENT=${hls_fragment}" \
        "HLS_PLAYLIST_LENGTH=${hls_playlist_length}"
}

# Writes the HTTP-side site config. Picks the plain-HTTP or SSL template
# depending on whether a certificate already exists for the domain.
write_http_conf() {
    local domain="$1" ssl_enabled="$2" cert_path="$3" key_path="$4"
    ensure_dir "$M3U8_NGINX_SITES_AVAILABLE" 755 root:root
    ensure_dir "$M3U8_NGINX_SITES_ENABLED" 755 root:root
    ensure_dir "$(dirname "$M3U8_STREAMKEYS_MAP")" 750 root:root

    if [ ! -f "$M3U8_STREAMKEYS_MAP" ]; then
        : >"$M3U8_STREAMKEYS_MAP"
        chmod 600 "$M3U8_STREAMKEYS_MAP"
    fi

    if [ "$ssl_enabled" = "true" ]; then
        render_template "${M3U8_PROJECT_ROOT}/config/nginx/http-ssl.conf.template" \
            "$M3U8_NGINX_SITE_FILE" 644 \
            "DOMAIN=${domain}" \
            "AUTH_PORT=${M3U8_AUTH_PORT}" \
            "WEB_ROOT=${M3U8_WEB_ROOT}" \
            "CHANNELS_JSON=${M3U8_CHANNELS_JSON}" \
            "HLS_DIR=${M3U8_HLS_DIR}" \
            "STREAMKEYS_MAP=${M3U8_STREAMKEYS_MAP}" \
            "SSL_CERT=${cert_path}" \
            "SSL_KEY=${key_path}"
    else
        render_template "${M3U8_PROJECT_ROOT}/config/nginx/http.conf.template" \
            "$M3U8_NGINX_SITE_FILE" 644 \
            "DOMAIN=${domain}" \
            "AUTH_PORT=${M3U8_AUTH_PORT}" \
            "WEB_ROOT=${M3U8_WEB_ROOT}" \
            "CHANNELS_JSON=${M3U8_CHANNELS_JSON}" \
            "HLS_DIR=${M3U8_HLS_DIR}" \
            "STREAMKEYS_MAP=${M3U8_STREAMKEYS_MAP}"
    fi

    if [ ! -L "$M3U8_NGINX_SITE_LINK" ]; then
        ln -sf "$M3U8_NGINX_SITE_FILE" "$M3U8_NGINX_SITE_LINK"
    fi
}

# Regenerates the stream-key allow list from every stream record on disk.
# Only enabled channels resolve to "1"; everything else (disabled, unknown,
# no key at all) falls through to the map's "default 0".
regenerate_streamkeys_map() {
    local tmp file name key enabled
    ensure_dir "$(dirname "$M3U8_STREAMKEYS_MAP")" 750 root:root
    tmp="$(mktemp)"
    if [ -d "$M3U8_STREAMS_DIR" ]; then
        for file in "$M3U8_STREAMS_DIR"/*.conf; do
            [ -e "$file" ] || continue
            enabled="$(conf_get "$file" ENABLED || echo "false")"
            key="$(conf_get "$file" STREAM_KEY || echo "")"
            if [ "$enabled" = "true" ] && [ -n "$key" ]; then
                printf '    %s 1;\n' "$key" >>"$tmp"
            fi
        done
    fi
    mv -f "$tmp" "$M3U8_STREAMKEYS_MAP"
    chmod 600 "$M3U8_STREAMKEYS_MAP"
    chown root:root "$M3U8_STREAMKEYS_MAP" 2>/dev/null || true
}

# Regenerates the public channel manifest consumed by the web player. Only
# exposes what is already implied by a shareable HLS URL: no raw key field,
# no data about disabled channels.
sync_channels_json() {
    local domain="$1" ssl_enabled="$2" scheme file name display key enabled first=1
    scheme="http"
    [ "$ssl_enabled" = "true" ] && scheme="https"
    ensure_dir "$M3U8_WEB_ROOT" 755 www-data:www-data

    {
        printf '[\n'
        if [ -d "$M3U8_STREAMS_DIR" ]; then
            for file in "$M3U8_STREAMS_DIR"/*.conf; do
                [ -e "$file" ] || continue
                enabled="$(conf_get "$file" ENABLED || echo "false")"
                [ "$enabled" = "true" ] || continue
                name="$(conf_get "$file" NAME || echo "")"
                display="$(conf_get "$file" DISPLAY_NAME || echo "$name")"
                key="$(conf_get "$file" STREAM_KEY || echo "")"
                [ -n "$name" ] && [ -n "$key" ] || continue
                [ "$first" -eq 1 ] || printf ',\n'
                first=0
                printf '  {"name": "%s", "displayName": "%s", "hlsUrl": "%s://%s/hls/%s.m3u8", "playerUrl": "%s://%s/watch/%s"}' \
                    "$name" "$display" "$scheme" "$domain" "$key" "$scheme" "$domain" "$name"
            done
        fi
        printf '\n]\n'
    } | atomic_write "$M3U8_CHANNELS_JSON" 644
    chown www-data:www-data "$M3U8_CHANNELS_JSON" 2>/dev/null || true
}

test_nginx() {
    nginx -t 2>&1
}

# Tests the config first and only reloads if it is valid. On failure, the
# currently-running configuration is left untouched.
reload_nginx() {
    local output
    if output="$(test_nginx)"; then
        systemctl reload nginx
        log_ok "Nginx configuration reloaded."
        return 0
    else
        log_error "Nginx configuration test failed. Nginx has NOT been reloaded."
        printf '%s\n' "$output" >&2
        log_error "The previous working configuration is still active."
        log_error "Generated files are at: $M3U8_NGINX_SITE_FILE and $M3U8_NGINX_RTMP_CONF"
        return 1
    fi
}

restart_nginx() {
    local output
    if output="$(test_nginx)"; then
        systemctl restart nginx
        log_ok "Nginx restarted."
        return 0
    else
        log_error "Nginx configuration test failed. Nginx has NOT been restarted."
        printf '%s\n' "$output" >&2
        return 1
    fi
}

nginx_is_running() {
    systemctl is-active --quiet nginx
}
