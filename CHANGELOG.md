# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Hardened (Phase B relay - privileged-bootstrap review)
- Relay runner is now installed atomically (`root:root`/700, temp file +
  rename in the same directory, never a truncate-in-place) with explicit
  post-install ownership/mode verification - `install_relay_runtime`
  refuses to mark the relay subsystem ready if any check fails.
- `relay-runner.sh` now fails closed, before touching any config, if
  `setpriv` or the `m3u8-relay` account is missing at runtime (not just
  checked once at install time), and re-validates its output path is
  provably inside the relay HLS root at the privileged boundary rather
  than trusting earlier validation.
- Managed media directory (`/var/lib/m3u8-server/media`) tightened to
  `root:m3u8-relay`/750 (was `m3u8-relay:m3u8-relay`/755) - the relay
  process can read cached/imported media via the group bit but can no
  longer write there; only root (via the manager's cache/import flow)
  writes new media.
- Systemd unit gained `PrivateDevices`, `ProtectKernelTunables`,
  `ProtectKernelModules`, `ProtectControlGroups`, `LockPersonality`
  unconditionally (all supported since systemd 232/235, older than every
  targeted release), plus `RestrictSUIDSGID` conditionally generated only
  when the installed systemd is 242+, so older-but-supported Ubuntu
  releases never receive a directive their systemd predates.
- New `relay_ffmpeg_identity_check`: inspects the *actual* kernel-reported
  UID of the relay's main process (via its `MainPID`) rather than trusting
  configuration or "service active" alone - surfaced in relay status, the
  manager's health-check menu, and the relay self-test, which now fails
  if FFmpeg is not confirmed running as `m3u8-relay`.
- Local-file relay sources are now probed for read access *as the actual
  `m3u8-relay` user* (via `setpriv ... test -r`) before FFmpeg starts,
  producing a clear error instead of a delayed, more cryptic FFmpeg
  failure - without ever auto-adjusting permissions.

### Added (Phase B - 24/7 source relay)
- New relay subsystem (`lib/relay.sh`, `lib/relay-runner.sh`): pulls a
  local file, remote HLS, RTMP/RTMPS, RTSP, or HTTP media source and
  republishes it as this server's own HLS output, stream-copied by
  default (`-c:v copy -c:a copy`, no re-encoding) - entirely separate
  from, and running alongside, the RTMP-publish channel path.
- Each relay is supervised by a systemd template unit
  (`m3u8-relay@<name>.service`, `config/systemd/m3u8-relay@.service.template`)
  with `Restart=on-failure` and a rate-limited restart policy. FFmpeg
  runs as a new dedicated system account (`m3u8-relay`) - never
  `www-data` and never root - via a root-controlled bootstrap: the
  runner starts as root (only to read the root-restricted relay config),
  then permanently drops to `m3u8-relay` with `setpriv` before FFmpeg
  (the process that actually talks to the network) ever starts. FFmpeg
  is invoked via a real Bash argument array in the runner - never a
  shell string built from a source URL.
- `m3u8-manager` → **27. Relay Management**: add/list/status/start/stop/
  restart/edit relay, change source, test a source before saving
  (ffprobe-based codec/resolution/bitrate summary with a stream-copy
  compatibility verdict), view/follow logs, remove, per-relay health
  check (HEALTHY/STALE/OFFLINE/STARTING/STOPPED/DISABLED - a running
  service whose HLS output has stopped updating is reported STALE, not
  healthy), bandwidth estimator, and an end-to-end relay self-test.
- Relay source URLs (which may contain credentials/tokens) are stored in
  `root:root`/700/600 config - deliberately not readable by `www-data`
  or any other unrelated service identity - redacted in all manager
  output, and never written to the public manifest
  (`relays.generated.json`, a file entirely separate from the
  RTMP-publish `channels.generated.json`).
- Relay config uses the same safe `KEY="value"` format as everything else
  in the project (never shell-sourced), validated before ever reaching an
  FFmpeg argument list.
- `install.sh` now installs FFmpeg unconditionally (previously optional),
  provisions the relay runner/systemd template/config and media
  directories, and offers an interactive relay self-test alongside the
  existing RTMP self-test, reporting "Relay subsystem: PASS" only if that
  test actually passes.
- Web player now merges `relays.generated.json` alongside
  `channels.generated.json` and shows a non-healthy relay's status inline
  in the channel picker.
- `uninstall.sh` now stops/disables all relay service instances and
  removes the relay systemd template as part of its existing conservative,
  confirmation-gated cleanup.

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
