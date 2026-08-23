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

# Detected once and cached here. Never assume this from the Ubuntu release -
# different releases (and backports on the same release) ship different
# Nginx versions, and Nginx's own feature syntax is what actually matters.
NGINX_VERSION=""

# Populates NGINX_VERSION from the real installed binary (never assumed
# from the Ubuntu release). Safe to call repeatedly; only re-parses if not
# already known this run.
detect_nginx_version() {
    [ -n "$NGINX_VERSION" ] && return 0
    command_exists nginx || return 1
    NGINX_VERSION="$(nginx -v 2>&1 | grep -oE 'nginx/[0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d/ -f2)"
    [ -n "$NGINX_VERSION" ]
}

# Nginx moved HTTP/2 from a `listen ... http2;` parameter to a standalone
# `http2 on;` directive in 1.25.1. Using the new directive against an older
# Nginx fails validation outright with "unknown directive \"http2\"" - this
# is the exact bug seen on a real Ubuntu 24.04 install shipping Nginx
# 1.24.0. Always branch on the actually-detected version, never on the
# Ubuntu release.
nginx_supports_standalone_http2() {
    detect_nginx_version || return 1
    version_ge "$NGINX_VERSION" "1.25.1"
}

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
    ensure_command nginx nginx \
        || die "The nginx package could not be installed, or its binary is still missing after installation. Detected: ${OS_PRETTY_NAME:-unknown} (${OS_ARCH:-unknown})."

    if package_available libnginx-mod-rtmp; then
        apt_install libnginx-mod-rtmp
        package_installed libnginx-mod-rtmp \
            || die "The libnginx-mod-rtmp package failed to install. Detected: ${OS_PRETTY_NAME:-unknown} (${OS_ARCH:-unknown})."
    else
        die "The libnginx-mod-rtmp package is not available for this Ubuntu release (${OS_PRETTY_NAME:-unknown}). Cannot continue without RTMP support."
    fi

    ensure_command openssl openssl \
        || die "OpenSSL could not be installed. Detected: ${OS_PRETTY_NAME:-unknown} (${OS_ARCH:-unknown})."

    detect_nginx_version && log_info "Detected Nginx version: $NGINX_VERSION" \
        || log_warn "Could not determine the installed Nginx version; will assume legacy HTTP/2 syntax."
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
        local http2_listen_suffix http2_directive_line
        if nginx_supports_standalone_http2; then
            http2_listen_suffix=""
            http2_directive_line="http2 on;"
        else
            http2_listen_suffix=" http2"
            http2_directive_line=""
        fi
        render_template "${M3U8_PROJECT_ROOT}/config/nginx/http-ssl.conf.template" \
            "$M3U8_NGINX_SITE_FILE" 644 \
            "DOMAIN=${domain}" \
            "AUTH_PORT=${M3U8_AUTH_PORT}" \
            "WEB_ROOT=${M3U8_WEB_ROOT}" \
            "CHANNELS_JSON=${M3U8_CHANNELS_JSON}" \
            "HLS_DIR=${M3U8_HLS_DIR}" \
            "STREAMKEYS_MAP=${M3U8_STREAMKEYS_MAP}" \
            "SSL_CERT=${cert_path}" \
            "SSL_KEY=${key_path}" \
            "HTTP2_LISTEN_SUFFIX=${http2_listen_suffix}" \
            "HTTP2_DIRECTIVE_LINE=${http2_directive_line}"
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

# activate_site_config <domain> <want_ssl> <cert_path> <key_path>
# The single place that decides what actually gets activated: generates the
# best available candidate (SSL if requested and a certificate is on disk,
# otherwise HTTP-only), validates it with `nginx -t`, and only ever leaves
# a *validated* candidate on disk. If the SSL candidate fails validation
# (e.g. an Nginx-version/syntax mismatch), this automatically regenerates
# and validates the HTTP-only candidate instead - a working HTTP server
# must never be sacrificed to a broken SSL config. Nginx itself is not
# reloaded here; the caller reloads once activation succeeds. Prints
# "true" or "false" for the SSL state that was actually activated (which
# the caller should persist via conf_set), and returns non-zero only if
# even the HTTP-only candidate fails validation.
activate_site_config() {
    local domain="$1" want_ssl="$2" cert_path="$3" key_path="$4" output backup_site=""

    # Snapshot whatever site config is currently on disk (if any) so it can
    # be restored if every candidate below fails validation - the file this
    # function writes to is the one Nginx actually reloads from, so it must
    # never be left in a state worse than what was there before this call.
    if [ -f "$M3U8_NGINX_SITE_FILE" ]; then
        backup_site="$(mktemp "${M3U8_NGINX_SITE_FILE}.previous.XXXXXX")"
        cp -a "$M3U8_NGINX_SITE_FILE" "$backup_site"
    fi

    if [ "$want_ssl" = "true" ] && [ -n "$cert_path" ] && [ -f "$cert_path" ] && [ -f "$key_path" ]; then
        write_http_conf "$domain" "true" "$cert_path" "$key_path"
        if output="$(test_nginx)"; then
            [ -n "$backup_site" ] && rm -f "$backup_site"
            printf 'true'
            return 0
        fi
        log_error "Generated SSL configuration failed Nginx validation (installed Nginx: ${NGINX_VERSION:-unknown})."
        printf '%s\n' "$output" >&2
        log_error "Falling back to HTTP-only configuration. The existing certificate for $domain is untouched and will be reused automatically once this is fixed."
    fi

    write_http_conf "$domain" "false" "" ""
    if output="$(test_nginx)"; then
        [ -n "$backup_site" ] && rm -f "$backup_site"
        printf 'false'
        return 0
    fi

    log_error "Generated HTTP configuration also failed Nginx validation."
    printf '%s\n' "$output" >&2
    if [ -n "$backup_site" ]; then
        mv -f "$backup_site" "$M3U8_NGINX_SITE_FILE"
        log_error "Restored the previous working site configuration; it has not been reloaded (still the same file Nginx already has loaded)."
    else
        log_error "No previous site configuration existed to restore. The invalid candidate is left on disk at $M3U8_NGINX_SITE_FILE for inspection; Nginx has NOT been reloaded with it."
    fi
    printf 'false'
    return 1
}

# Builds the candidate map body (one "KEY 1;" line per enabled channel) on
# stdout. Only enabled channels with a key resolve to "1"; everything else
# (disabled, unknown, no key at all) falls through to the map's
# "default 0". Defensive filtering here (valid character set, no
# duplicates) protects against a hand-edited or restored-from-an-old-
# backup stream file, even though normal code paths never produce such a
# file in the first place.
_build_streamkeys_map_body() {
    local file key enabled
    # Bash associative array to detect duplicate keys across channels.
    local -A seen=()
    [ -d "$M3U8_STREAMS_DIR" ] || return 0
    for file in "$M3U8_STREAMS_DIR"/*.conf; do
        [ -e "$file" ] || continue
        enabled="$(conf_get "$file" ENABLED || echo "false")"
        [ "$enabled" = "true" ] || continue
        key="$(conf_get "$file" STREAM_KEY || echo "")"
        [ -n "$key" ] || continue
        if ! is_valid_stream_key "$key"; then
            log_warn "Skipping channel '$(basename "$file" .conf)': its stored stream key contains characters that are no longer considered safe for the Nginx map."
            continue
        fi
        if [ -n "${seen[$key]:-}" ]; then
            log_warn "Skipping channel '$(basename "$file" .conf)': its stream key duplicates channel '${seen[$key]}'. Regenerate one of their keys."
            continue
        fi
        seen[$key]="$(basename "$file" .conf)"
        printf '    %s 1;\n' "$key"
    done
}

# Regenerates the stream-key allow list transactionally: the candidate is
# written to the real path (Nginx can only validate a `map { include ...; }`
# target that exists at the exact configured path), immediately tested with
# `nginx -t`, and rolled back to the previous working map if that test
# fails - so a bad candidate is never left as the live on-disk map. Nginx
# itself is not reloaded here (the caller does that once the whole site is
# confirmed valid); this only guarantees the file on disk is always usable.
# Returns 0 if the new map is active, 1 if it was rejected and the previous
# map (or no map) was restored instead.
regenerate_streamkeys_map() {
    local tmp previous_backup="" had_previous=0 output
    ensure_dir "$(dirname "$M3U8_STREAMKEYS_MAP")" 750 root:root

    tmp="$(mktemp "${M3U8_STREAMKEYS_MAP}.candidate.XXXXXX")"
    _build_streamkeys_map_body >"$tmp"
    chmod 600 "$tmp"

    if [ -f "$M3U8_STREAMKEYS_MAP" ]; then
        had_previous=1
        previous_backup="$(mktemp "${M3U8_STREAMKEYS_MAP}.previous.XXXXXX")"
        cp -a "$M3U8_STREAMKEYS_MAP" "$previous_backup"
    fi

    mv -f "$tmp" "$M3U8_STREAMKEYS_MAP"
    chmod 600 "$M3U8_STREAMKEYS_MAP"
    chown root:root "$M3U8_STREAMKEYS_MAP" 2>/dev/null || true

    if output="$(test_nginx)"; then
        [ -n "$previous_backup" ] && rm -f "$previous_backup"
        return 0
    fi

    log_error "The regenerated stream-key configuration failed Nginx validation:"
    printf '%s\n' "$output" >&2
    if [ "$had_previous" -eq 1 ]; then
        mv -f "$previous_backup" "$M3U8_STREAMKEYS_MAP"
        chmod 600 "$M3U8_STREAMKEYS_MAP"
        chown root:root "$M3U8_STREAMKEYS_MAP" 2>/dev/null || true
        log_error "Restored the previous stream-key configuration."
    else
        rm -f "$M3U8_STREAMKEYS_MAP"
        : >"$M3U8_STREAMKEYS_MAP"
        chmod 600 "$M3U8_STREAMKEYS_MAP"
        log_error "No previous stream-key configuration existed; left an empty (deny-all) map in place instead of the invalid candidate."
    fi
    return 1
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
