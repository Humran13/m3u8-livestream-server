# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Fixed
- Generated Nginx configuration now sets `map_hash_bucket_size 256;`
  before the stream-key allow-list `map` block (in both the HTTP and SSL
  site templates). Without it, `nginx -t` fails with "could not build
  map_hash, you should increase map_hash_bucket_size" once a project-
  generated 48-character stream key is present - confirmed on a real
  Ubuntu 24.04.4 LTS / Nginx 1.24.0 install.
- Every operation that regenerates the stream-key map (add/remove/enable/
  disable/regenerate-key/restore/installer) is now transactional: the
  candidate map is validated with `nginx -t` immediately after being
  written, and automatically rolled back to the previous working map if
  it fails - the invalid candidate is never left as the live on-disk
  file. `m3u8-manager`'s Restore Configuration now also auto-rolls-back
  the entire site/RTMP config to its pre-restore safety backup if the
  restored files themselves fail validation.
- `m3u8-manager` Server Status and Server Diagnostics now report Nginx
  service state and Nginx configuration validity as two separate results,
  including an explicit warning for the specific dangerous combination of
  "process running" + "config on disk invalid" (previously only the
  service state was surfaced in Server Status).

### Added
- `is_valid_stream_key` validation (8-128 characters, `A-Za-z0-9_-` only)
  applied to every manually-entered stream key, in both `install.sh` and
  `m3u8-manager`, plus a `key_in_use` check rejecting a manual key that
  collides with another channel's key (which would otherwise produce a
  duplicate, `nginx -t`-failing map entry). Automatically generated keys
  are unaffected and remain 48 characters.

- SSL configuration generation now detects the actually-installed Nginx
  version and emits the HTTP/2 syntax that version supports, instead of
  always using the standalone `http2 on;` directive (only valid on Nginx
  1.25.1+). Fixes `nginx -t` failing with `unknown directive "http2"` on
  Nginx 1.24.0, as confirmed on a real Ubuntu 24.04.4 LTS install.
- Package-installed checks across the project (`apt_install` and friends)
  now verify dpkg's actual `Status` field instead of trusting a bare
  `dpkg -s` exit code, which can be 0 for a package that is present in the
  dpkg database but not actually installed (e.g. `deinstall ok
  config-files`). This was the root cause of a confirmed `ufw: command not
  found` crash during firewall setup on a real Ubuntu 24.04 install, even
  though the installer had already attempted `apt_install ufw`.
- A firewall setup failure no longer aborts the rest of the installation.
- Rerunning `install.sh` against a partially-completed install (e.g. one
  that got a certificate but failed later, or crashed before creating its
  first channel) now correctly repairs the SSL configuration, reuses the
  existing certificate instead of requesting a new one, and leaves any
  already-created channel and its stream key untouched.

### Added
- Ubuntu 18.04 LTS as an additional installer target.
- Centralized Nginx-version detection (`detect_nginx_version`,
  `nginx_supports_standalone_http2`) and a single transactional
  `activate_site_config` function that generates, validates, and only
  ever activates a Nginx site config that passes `nginx -t` - falling back
  to HTTP-only automatically if an SSL candidate fails validation.
  Ubuntu version and Nginx version are treated as independent axes; a
  release is never assumed to ship a specific Nginx version.
  Used by both `install.sh` and `m3u8-manager`'s SSL menu.
- `package_installed` / `ensure_command` helpers in `lib/common.sh` for
  reliable "is this actually usable" checks, replacing ad hoc `dpkg -s`
  checks project-wide.
- OS codename and kernel version added to OS detection and diagnostics
  output (`/etc/os-release`'s `VERSION_CODENAME`, `uname -r`).
- Interactive and non-interactive `install.sh` for Ubuntu 18.04/20.04/22.04/24.04/26.04.
- Nginx + RTMP module configuration with HLS output, isolated from the
  system's existing nginx configuration.
- Multi-channel stream management backed by `/etc/m3u8-server`.
- Secure, randomly generated stream keys with a per-channel enable/disable
  gate enforced at the nginx RTMP layer.
- `m3u8-manager` interactive administration menu (status, channel CRUD, OBS
  settings, SSL, firewall, logs, HLS diagnostics, backup/restore, uninstall).
- `status.sh` / `m3u8-status` for quick non-interactive health checks.
- Lightweight `hls.js`-based web player with multi-channel support.
- Let's Encrypt / Certbot integration with DNS pre-checks.
- Optional, confirmation-gated UFW firewall setup.
- Conservative `uninstall.sh` that removes only what this project created.
