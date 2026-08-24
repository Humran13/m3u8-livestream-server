#!/usr/bin/env bash
# lib/selftest.sh - active self-tests that exercise the running server
# instead of only inspecting its configuration: the RTMP publish-auth
# endpoint, HLS directory write access under the real Nginx worker user,
# and a full synthetic OBS-like publish through to HLS playback. Nothing
# here touches a real channel's data; the end-to-end test creates and
# removes its own disposable channel.

if [ -n "${M3U8_SELFTEST_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_SELFTEST_LOADED=1

# Reads Nginx's configured worker user from nginx.conf's top-level `user`
# directive, rather than assuming www-data - some installs/distros use a
# different user, and this diagnostic exists precisely to catch a
# permissions mismatch, so it must not itself assume the answer.
detect_nginx_worker_user() {
    local user
    if [ -f "$M3U8_NGINX_CONF" ]; then
        user="$(grep -E '^[[:space:]]*user[[:space:]]+' "$M3U8_NGINX_CONF" 2>/dev/null \
            | head -n1 | awk '{print $2}' | tr -d ';')"
    fi
    printf '%s' "${user:-www-data}"
}

# Verifies the Nginx worker user can actually write to the HLS directory
# (not just that the directory exists), by creating and removing a
# harmless marker file as that user.
test_hls_directory_writable() {
    local worker_user testfile
    worker_user="$(detect_nginx_worker_user)"

    if [ ! -d "$M3U8_HLS_DIR" ]; then
        _diag_fail "HLS directory does not exist: $M3U8_HLS_DIR"
        return 1
    fi

    testfile="${M3U8_HLS_DIR}/.m3u8-server-write-test-$$"
    if command_exists sudo; then
        if sudo -u "$worker_user" sh -c ": > '$testfile'" 2>/dev/null; then
            rm -f "$testfile"
            _diag_pass "HLS directory is writable by the Nginx worker user ($worker_user)."
            return 0
        fi
        rm -f "$testfile" 2>/dev/null || true
        _diag_fail "HLS directory is NOT writable by the Nginx worker user ($worker_user). Run: sudo chown -R ${worker_user}:${worker_user} $M3U8_HLS_DIR"
        return 1
    fi

    # No sudo available (unusual on Ubuntu) - fall back to an ownership
    # check, which is weaker (doesn't prove writability under that user's
    # actual permissions/ACLs) but better than assuming.
    local owner
    owner="$(stat -c '%U' "$M3U8_HLS_DIR" 2>/dev/null || echo "")"
    if [ "$owner" = "$worker_user" ] && [ -w "$M3U8_HLS_DIR" ]; then
        _diag_pass "HLS directory appears writable (owned by $worker_user); could not verify as that exact user (sudo unavailable)."
        return 0
    fi
    _diag_fail "HLS directory owner is '$owner', expected the Nginx worker user ($worker_user), and sudo is unavailable to verify further."
    return 1
}

# Exercises the local RTMP publish-auth endpoint directly over HTTP - no
# OBS or RTMP connection required. Never logs an actual stream key value.
test_auth_endpoint() {
    local mode base code have_channel=0 real_key="" file

    mode="$(current_auth_mode)"
    base="http://127.0.0.1:${M3U8_AUTH_PORT}/auth"

    if [ "$mode" = "off" ]; then
        _diag_warn "AUTH_MODE is 'off' - every publish is currently accepted unconditionally, regardless of the results below."
    fi

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$base" 2>/dev/null || echo "000")"
    if [ "$code" = "000" ]; then
        _diag_fail "RTMP authentication endpoint (127.0.0.1:${M3U8_AUTH_PORT}) is not reachable."
        return 1
    fi
    _diag_pass "RTMP authentication endpoint is reachable."

    local ok=1
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${base}?name=definitely-not-a-real-key-000000" 2>/dev/null || echo "000")"
    if [ "$mode" = "off" ]; then
        if [ "$code" = "204" ]; then
            _diag_pass "An unknown key is accepted, consistent with AUTH_MODE=off."
        else
            _diag_warn "AUTH_MODE is off but an unknown key got HTTP $code instead of 204."
        fi
    else
        if [ "$code" = "403" ]; then
            _diag_pass "An unknown/invalid stream key is correctly rejected (403)."
        else
            _diag_fail "An unknown/invalid stream key returned HTTP $code, expected 403."
            ok=0
        fi
    fi

    if [ -d "$M3U8_STREAMS_DIR" ]; then
        for file in "$M3U8_STREAMS_DIR"/*.conf; do
            [ -e "$file" ] || continue
            [ "$(conf_get "$file" ENABLED 2>/dev/null || echo false)" = "true" ] || continue
            real_key="$(conf_get "$file" STREAM_KEY 2>/dev/null || echo "")"
            [ -n "$real_key" ] && { have_channel=1; break; }
        done
    fi

    if [ "$have_channel" -eq 0 ]; then
        _diag_warn "No enabled channel exists yet; skipped testing acceptance of a real stream key."
        return "$((1 - ok))"
    fi

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${base}?name=${real_key}" 2>/dev/null || echo "000")"
    if [ "$code" = "204" ]; then
        _diag_pass "An enabled channel's real stream key is accepted (204)."
    else
        _diag_fail "An enabled channel's real stream key returned HTTP $code, expected 204."
        ok=0
    fi
    return "$((1 - ok))"
}

# run_e2e_streaming_test
# Publishes a short synthetic (FFmpeg testsrc/sine) stream to a disposable
# temporary channel, end to end through the real RTMP/auth/HLS pipeline,
# and verifies each stage. Always cleans up the temporary channel and its
# HLS files, even on failure. Never touches any other channel.
_e2e_test_channel=""
_e2e_ffmpeg_pid=""

_e2e_cleanup() {
    # A RETURN trap, once set, stays armed for every subsequent function
    # return in the process - not just the one it was set for. Disarm it
    # immediately so this doesn't silently re-fire (harmlessly, given the
    # guards below, but pointlessly) for the rest of the session.
    trap - RETURN
    if [ -n "$_e2e_ffmpeg_pid" ] && kill -0 "$_e2e_ffmpeg_pid" 2>/dev/null; then
        kill "$_e2e_ffmpeg_pid" 2>/dev/null || true
        wait "$_e2e_ffmpeg_pid" 2>/dev/null || true
    fi
    if [ -n "$_e2e_test_channel" ] && stream_exists "$_e2e_test_channel"; then
        remove_stream "$_e2e_test_channel" "true" >/dev/null 2>&1 || true
    fi
    _e2e_ffmpeg_pid=""
    _e2e_test_channel=""
}

run_e2e_streaming_test() {
    trap _e2e_cleanup RETURN

    local rtmp_app domain test_key playlist i=0 ffmpeg_log output
    local overall_pass=1

    print_banner "END-TO-END STREAMING SELF-TEST"

    if output="$(test_nginx)"; then
        _diag_pass "Nginx configuration"
    else
        _diag_fail "Nginx configuration"
        printf '%s\n' "$output" >&2
        return 1
    fi

    if nginx_is_running; then
        _diag_pass "Nginx service running"
    else
        _diag_fail "Nginx service running"
        return 1
    fi

    if port_listening "$M3U8_RTMP_PORT"; then
        _diag_pass "RTMP listener"
    else
        _diag_fail "RTMP listener"
        return 1
    fi

    if ! ensure_command ffmpeg ffmpeg; then
        _diag_fail "FFmpeg is required for this test and could not be installed."
        return 1
    fi
    _diag_pass "FFmpeg available"

    # --- create a disposable test channel -----------------------------
    while :; do
        _e2e_test_channel="selftest-$(openssl rand -hex 3 2>/dev/null || echo "$RANDOM")"
        stream_exists "$_e2e_test_channel" || break
        i=$((i + 1))
        [ "$i" -lt 20 ] || { _diag_fail "Could not allocate a temporary test channel name."; return 1; }
    done
    test_key="$(generate_stream_key)"
    if ! add_stream "$_e2e_test_channel" "Self-Test (temporary)" "$test_key" "true" 2>/tmp/m3u8-selftest-add.log; then
        _diag_fail "Could not create the temporary test channel."
        cat /tmp/m3u8-selftest-add.log >&2 2>/dev/null || true
        return 1
    fi
    _diag_pass "Temporary test channel created"

    rtmp_app="$(conf_get "$M3U8_SERVER_CONF" RTMP_APP 2>/dev/null || echo "$M3U8_RTMP_APP_DEFAULT")"
    domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"

    if [ "$(current_auth_mode)" = "off" ]; then
        log_warn "AUTH_MODE is 'off' - this test's authentication step is not meaningful right now."
    fi

    # --- publish a short synthetic stream to localhost ------------------
    ffmpeg_log="$(mktemp)"
    ffmpeg -hide_banner -loglevel error -re \
        -f lavfi -i "testsrc=size=640x360:rate=25" \
        -f lavfi -i "sine=frequency=1000:sample_rate=44100" \
        -c:v libx264 -preset veryfast -tune zerolatency -g 25 -keyint_min 25 \
        -c:a aac -b:a 64k -ar 44100 \
        -f flv "rtmp://127.0.0.1:${M3U8_RTMP_PORT}/${rtmp_app}/${test_key}" \
        -t 14 >"$ffmpeg_log" 2>&1 &
    _e2e_ffmpeg_pid=$!

    sleep 1
    if ! kill -0 "$_e2e_ffmpeg_pid" 2>/dev/null; then
        _diag_fail "FFmpeg exited immediately (publish rejected or failed to start). Log follows:"
        cat "$ffmpeg_log" >&2 2>/dev/null || true
        rm -f "$ffmpeg_log"
        return 1
    fi
    _diag_pass "RTMP publish accepted (authentication passed)"

    sleep 7

    playlist="${M3U8_HLS_DIR}/${test_key}.m3u8"
    if [ -f "$playlist" ]; then
        _diag_pass "HLS playlist generated"
    else
        _diag_fail "HLS playlist was not generated at $playlist"
        overall_pass=0
    fi

    if find "$M3U8_HLS_DIR" -maxdepth 1 -name "${test_key}-*.ts" -print -quit 2>/dev/null | grep -q .; then
        _diag_pass "HLS media segments generated"
    else
        _diag_fail "No HLS media segments (.ts) were found for the test stream"
        overall_pass=0
    fi

    if kill -0 "$_e2e_ffmpeg_pid" 2>/dev/null; then
        kill "$_e2e_ffmpeg_pid" 2>/dev/null || true
        wait "$_e2e_ffmpeg_pid" 2>/dev/null || true
    fi
    _e2e_ffmpeg_pid=""
    rm -f "$ffmpeg_log"

    if [ "$overall_pass" -eq 1 ] && [ -n "$domain" ]; then
        local scheme fetch_code
        scheme="http"
        [ "$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED 2>/dev/null || echo false)" = "true" ] && scheme="https"
        fetch_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
            --resolve "${domain}:80:127.0.0.1" --resolve "${domain}:443:127.0.0.1" \
            "${scheme}://${domain}/hls/${test_key}.m3u8" 2>/dev/null || echo "000")"
        if [ "$fetch_code" = "200" ]; then
            _diag_pass "HLS playlist retrievable over HTTP(S) at the public URL"
        else
            _diag_fail "HLS playlist fetch over HTTP(S) returned $fetch_code, expected 200"
            overall_pass=0
        fi

        if command_exists ffprobe; then
            if ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
                -of csv=p=0 "$playlist" >/dev/null 2>&1; then
                _diag_pass "ffprobe confirms the playlist contains a decodable video stream"
            else
                _diag_fail "ffprobe could not read a video stream from the generated playlist"
                overall_pass=0
            fi
        else
            _diag_warn "ffprobe not available; skipped playback validation."
        fi
    elif [ -z "$domain" ]; then
        _diag_warn "No domain configured; skipped the public HTTP fetch and ffprobe checks."
    fi

    printf '\n'
    if [ "$overall_pass" -eq 1 ]; then
        print_banner "END-TO-END STREAMING TEST PASSED"
    else
        print_banner "END-TO-END STREAMING TEST FAILED"
    fi
    [ "$overall_pass" -eq 1 ]
}

# run_relay_e2e_test
# Proves the relay subsystem (Phase B) independently of any external
# source: generates a tiny local synthetic MP4 once (short, low
# resolution - this validates relay/repackaging capability, not encoding
# throughput), creates a disposable local-loop copy-mode relay from it,
# starts it via systemd, and verifies HLS output through to a decodable
# playlist. Always cleans up the temporary relay, its HLS output, and the
# generated test file, even on failure. Never touches any real relay.
_relay_e2e_name=""
_relay_e2e_tmpfile=""

_relay_e2e_cleanup() {
    trap - RETURN
    if [ -n "$_relay_e2e_name" ] && relay_exists "$_relay_e2e_name"; then
        remove_relay "$_relay_e2e_name" "true" >/dev/null 2>&1 || true
    fi
    # Defense in depth: only ever remove the exact, internally generated
    # temp file this run created, and only if it is provably inside the
    # managed media directory - never $M3U8_MEDIA_DIR itself (a bare/
    # trailing-slash value could otherwise match its own "/*" glob) and
    # never anything outside it, no matter what _relay_e2e_tmpfile holds.
    if [ -n "$_relay_e2e_tmpfile" ] && [ -f "$_relay_e2e_tmpfile" ]; then
        case "$_relay_e2e_tmpfile" in
            "${M3U8_MEDIA_DIR}/"?*) rm -f "$_relay_e2e_tmpfile" ;;
        esac
    fi
    _relay_e2e_name=""
    _relay_e2e_tmpfile=""
}

run_relay_e2e_test() {
    trap _relay_e2e_cleanup RETURN

    local i=0 domain scheme playlist overall_pass=1 fetch_code

    print_banner "RELAY END-TO-END SELF-TEST"

    if ! command_exists ffmpeg; then
        _diag_fail "FFmpeg is not available; cannot run the relay self-test."
        return 1
    fi
    _diag_pass "FFmpeg available"

    if [ ! -f "$M3U8_RELAY_SYSTEMD_TEMPLATE" ]; then
        _diag_fail "Relay systemd template not installed ($M3U8_RELAY_SYSTEMD_TEMPLATE missing)."
        return 1
    fi
    _diag_pass "Relay systemd template installed"

    if ! command_exists setpriv; then
        _diag_fail "setpriv is not available; the relay runner cannot drop privileges."
        return 1
    fi
    _diag_pass "setpriv available"

    if ! id -u "$M3U8_RELAY_USER" >/dev/null 2>&1; then
        _diag_fail "Dedicated relay user '$M3U8_RELAY_USER' does not exist."
        return 1
    fi
    _diag_pass "Relay system user exists"

    if [ ! -x "$M3U8_RELAY_RUNNER" ]; then
        _diag_fail "Relay runner not installed or not executable ($M3U8_RELAY_RUNNER)."
        return 1
    fi
    _diag_pass "Relay runner installed"

    # This is the exact check that would have caught the real Ubuntu
    # 24.04 bug: systemd sets up a unit's sandbox/mount namespace
    # (including ReadWritePaths=) BEFORE ExecStart runs, so a missing
    # relay HLS root fails the service immediately with a generic
    # "226/NAMESPACE" - relay-runner.sh never gets a chance to mkdir it,
    # because it never starts. ensure_relay_runtime_dirs repairs this
    # unconditionally (it's idempotent/cheap), so the self-test never
    # fails on this specific, fully-recoverable condition.
    ensure_relay_runtime_dirs
    if [ ! -d "$M3U8_RELAY_HLS_DIR" ]; then
        _diag_fail "Relay HLS root ($M3U8_RELAY_HLS_DIR) could not be created."
        return 1
    fi
    _diag_pass "Relay HLS root ready"

    # --- generate a tiny local test clip (one-time, bounded cost) --------
    # This MUST live under the managed media directory, never host /tmp:
    # the relay systemd unit runs with PrivateTmp=true, so a file created
    # in the manager process's /tmp is invisible inside the relay's own
    # private /tmp namespace - relay-runner.sh would report "local source
    # file does not exist" even though the file is right there from this
    # process's point of view. ensure_relay_runtime_dirs (above) already
    # guarantees $M3U8_MEDIA_DIR exists as root:m3u8-relay/750; re-check
    # explicitly anyway so a failure here produces a clear message instead
    # of a confusing mktemp error.
    if [ ! -d "$M3U8_MEDIA_DIR" ]; then
        _diag_fail "Managed media directory does not exist ($M3U8_MEDIA_DIR)."
        return 1
    fi
    # Template ends in a literal suffix (not X's), so mktemp treats
    # everything after the X run as a fixed suffix - the actual filename
    # is entirely internally generated, never user-controlled.
    _relay_e2e_tmpfile="$(mktemp "${M3U8_MEDIA_DIR}/.selftest-relay-XXXXXXXX.mp4" 2>/dev/null || true)"
    if [ -z "$_relay_e2e_tmpfile" ]; then
        _diag_fail "Could not create a temporary test file in the managed media directory ($M3U8_MEDIA_DIR)."
        return 1
    fi
    if ! ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc=size=320x240:rate=25:duration=5" \
        -f lavfi -i "sine=frequency=800:duration=5" \
        -c:v libx264 -preset veryfast -g 25 -c:a aac \
        -f mp4 -movflags +faststart \
        "$_relay_e2e_tmpfile" >/dev/null 2>&1; then
        _diag_fail "Could not generate the local test clip."
        return 1
    fi
    # root:m3u8-relay/640 - readable by the relay user via the group bit,
    # not writable by it - the same ownership model cache_remote_media()
    # uses for real cached source media. The media directory itself stays
    # root:m3u8-relay/750 (never made writable by m3u8-relay).
    chown "root:${M3U8_RELAY_USER}" "$_relay_e2e_tmpfile" 2>/dev/null || true
    chmod 640 "$_relay_e2e_tmpfile"
    _diag_pass "Local test clip generated in managed media directory"

    if stat -c '%U:%G %a' "$_relay_e2e_tmpfile" >/dev/null 2>&1; then
        _diag_pass "Test clip ownership/mode: $(stat -c '%U:%G %a' "$_relay_e2e_tmpfile")"
    fi

    # Prove the actual unprivileged relay account can read the file before
    # ever asking systemd to start a service that depends on it - same
    # privilege-transition primitive the real relay uses (setpriv, never
    # sudo), run against a fixed, safe command (never eval / a shell
    # string built from input).
    if setpriv --reuid "$M3U8_RELAY_USER" --regid "$M3U8_RELAY_USER" \
        --init-groups --inh-caps=-all --no-new-privs -- \
        test -r "$_relay_e2e_tmpfile"; then
        _diag_pass "Temporary test media readable by $M3U8_RELAY_USER"
    else
        _diag_fail "Temporary test media is NOT readable by $M3U8_RELAY_USER"
        return 1
    fi

    while :; do
        _relay_e2e_name="selftest-relay-$(openssl rand -hex 3 2>/dev/null || echo "$RANDOM")"
        relay_exists "$_relay_e2e_name" || break
        i=$((i + 1))
        [ "$i" -lt 20 ] || { _diag_fail "Could not allocate a temporary relay name."; return 1; }
    done

    if ! add_relay "$_relay_e2e_name" "Self-Test Relay (temporary)" "local" "$_relay_e2e_tmpfile" "copy" "true" "false" "tcp" 2>/tmp/m3u8-relay-selftest-add.log; then
        _diag_fail "Could not create the temporary test relay."
        cat /tmp/m3u8-relay-selftest-add.log >&2 2>/dev/null || true
        return 1
    fi
    _diag_pass "Temporary test relay created"

    if ! start_relay "$_relay_e2e_name" 2>/dev/null; then
        _diag_fail "Relay service failed to start."
        return 1
    fi

    sleep 7

    if systemctl is-active --quiet "m3u8-relay@${_relay_e2e_name}.service"; then
        _diag_pass "Relay service is running"
    else
        _diag_fail "Relay service is not running after start (check: journalctl -u m3u8-relay@${_relay_e2e_name})"
        overall_pass=0
    fi

    # Verifies the REAL kernel-reported UID of the running process, not
    # merely that the service is "active" - this is the same check a real
    # relay's health status uses, exercised here against the disposable
    # test relay so the privilege-drop path itself is proven, not assumed.
    local identity_result
    identity_result="$(relay_ffmpeg_identity_check "$_relay_e2e_name")"
    if [[ "$identity_result" == PASS* ]]; then
        _diag_pass "FFmpeg process identity: $identity_result"
    else
        _diag_fail "FFmpeg process identity: $identity_result"
        overall_pass=0
    fi

    playlist="${M3U8_RELAY_HLS_DIR}/${_relay_e2e_name}/index.m3u8"
    if [ -f "$playlist" ]; then
        _diag_pass "Relay HLS playlist generated"
    else
        _diag_fail "Relay HLS playlist was not generated at $playlist"
        overall_pass=0
    fi

    if find "${M3U8_RELAY_HLS_DIR}/${_relay_e2e_name}" -maxdepth 1 -name '*.ts' -print -quit 2>/dev/null | grep -q .; then
        _diag_pass "Relay HLS media segments generated"
    else
        _diag_fail "No relay HLS media segments (.ts) were found"
        overall_pass=0
    fi

    if [ "$overall_pass" -eq 1 ]; then
        domain="$(conf_get "$M3U8_SERVER_CONF" DOMAIN 2>/dev/null || echo "")"
        if [ -n "$domain" ]; then
            scheme="http"
            [ "$(conf_get "$M3U8_SERVER_CONF" SSL_ENABLED 2>/dev/null || echo false)" = "true" ] && scheme="https"
            fetch_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 \
                --resolve "${domain}:80:127.0.0.1" --resolve "${domain}:443:127.0.0.1" \
                "${scheme}://${domain}/hls/relay/${_relay_e2e_name}/index.m3u8" 2>/dev/null || echo "000")"
            if [ "$fetch_code" = "200" ]; then
                _diag_pass "Relay HLS playlist retrievable over HTTP(S) at the public URL"
            else
                _diag_fail "Relay HLS playlist fetch over HTTP(S) returned $fetch_code, expected 200"
                overall_pass=0
            fi
        else
            _diag_warn "No domain configured; skipped the public HTTP fetch check."
        fi

        if command_exists ffprobe; then
            if ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
                -of csv=p=0 "$playlist" >/dev/null 2>&1; then
                _diag_pass "ffprobe confirms the relay playlist contains a decodable video stream"
            else
                _diag_fail "ffprobe could not read a video stream from the relay playlist"
                overall_pass=0
            fi
        fi
    fi

    printf '\n'
    if [ "$overall_pass" -eq 1 ]; then
        print_banner "RELAY SELF-TEST PASSED"
    else
        print_banner "RELAY SELF-TEST FAILED"
    fi
    [ "$overall_pass" -eq 1 ]
}
