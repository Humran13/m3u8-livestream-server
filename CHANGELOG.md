# Changelog

All notable changes to this project are documented in this file.

## [1.0.0] - Unreleased

### Added
- Interactive and non-interactive `install.sh` for Ubuntu 20.04/22.04/24.04/26.04.
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
