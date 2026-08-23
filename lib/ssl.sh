#!/usr/bin/env bash
# lib/ssl.sh - Let's Encrypt / Certbot integration. Never requests a
# certificate without first giving the administrator a chance to see why it
# might fail (DNS not pointing at this server yet, etc.).

if [ -n "${M3U8_SSL_LOADED:-}" ]; then
    return 0 2>/dev/null || exit 0
fi
M3U8_SSL_LOADED=1

# Installs certbot via the distro package manager only - never falls back
# to Snap just because one Ubuntu release happens to package it
# differently, and never bypasses package-signature verification. Reports
# clearly (via return status) if certbot genuinely isn't available for
# this release rather than assuming it always is.
install_certbot() {
    if ! package_available certbot; then
        log_error "The certbot package is not available for this Ubuntu release (${OS_PRETTY_NAME:-unknown}). SSL cannot be configured automatically."
        return 1
    fi
    ensure_command certbot certbot python3-certbot-nginx \
        || { log_error "certbot could not be installed, or its binary is still missing after installation."; return 1; }
}

cert_path_for() {
    printf '/etc/letsencrypt/live/%s/fullchain.pem' "$1"
}

key_path_for() {
    printf '/etc/letsencrypt/live/%s/privkey.pem' "$1"
}

certificate_exists() {
    [ -f "$(cert_path_for "$1")" ] && [ -f "$(key_path_for "$1")" ]
}

# Best-effort check that DNS for the domain currently resolves to this
# server's public IP. Never blocks certificate issuance by itself - it only
# informs the administrator, since DNS tools are not always available or
# reliable inside every VPS network.
dns_points_here() {
    local domain="$1" server_ip resolved
    server_ip="$(public_ip)"
    [ -n "$server_ip" ] || return 2
    if command_exists getent; then
        resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}')"
    elif command_exists host; then
        resolved="$(host -t A "$domain" 2>/dev/null | awk '/has address/{print $NF; exit}')"
    else
        return 2
    fi
    [ -n "$resolved" ] || return 1
    [ "$resolved" = "$server_ip" ]
}

# Requests (or reuses) a certificate for the domain using the webroot
# challenge against the project's own web root, so it works whether or not
# the site is already fully configured in nginx.
obtain_certificate() {
    local domain="$1" email="$2" dns_check_status

    if certificate_exists "$domain"; then
        log_info "A certificate for $domain already exists; skipping issuance."
        return 0
    fi

    set +e
    dns_points_here "$domain"
    dns_check_status=$?
    set -e

    if [ "$dns_check_status" -eq 1 ]; then
        log_warn "DNS for $domain does not currently appear to point at this server's public IP."
        log_warn "Certificate issuance will likely fail until DNS is corrected."
        if ! confirm "Continue with certificate issuance anyway?" "n"; then
            log_info "Skipping SSL certificate issuance. Re-run SSL setup from m3u8-manager once DNS is fixed."
            return 1
        fi
    elif [ "$dns_check_status" -eq 2 ]; then
        log_warn "Could not verify DNS automatically; continuing."
    fi

    ensure_dir "${M3U8_WEB_ROOT}/.well-known/acme-challenge" 755 www-data:www-data

    log_info "Requesting a Let's Encrypt certificate for $domain..."
    if certbot certonly --webroot -w "$M3U8_WEB_ROOT" \
        -d "$domain" --email "$email" --agree-tos --non-interactive; then
        log_ok "Certificate issued for $domain."
        return 0
    else
        log_error "Certificate issuance failed. The server will continue running over HTTP."
        return 1
    fi
}

renew_certificate() {
    certbot renew
}

test_certificate_renewal() {
    certbot renew --dry-run
}

ssl_status_report() {
    local domain="$1"
    if certificate_exists "$domain"; then
        printf 'Certificate: present for %s\n' "$domain"
        openssl x509 -in "$(cert_path_for "$domain")" -noout -enddate 2>/dev/null || true
    else
        printf 'Certificate: none found for %s\n' "$domain"
    fi
    if systemctl list-timers 2>/dev/null | grep -q certbot; then
        printf 'Automatic renewal: enabled (systemd timer)\n'
    elif [ -f /etc/cron.d/certbot ]; then
        printf 'Automatic renewal: enabled (cron)\n'
    else
        printf 'Automatic renewal: not detected\n'
    fi
}
