# M3U8 Livestream Server

Turn a fresh Ubuntu VPS into a self-hosted livestreaming server in one
command, then manage it day-to-day with a single interactive tool.

```text
OBS / Encoder → RTMP → Nginx + RTMP module → HLS → .m3u8 URL → Browser / VLC / IPTV player
```

## Overview

This project installs and configures Nginx with the RTMP module on your own
Ubuntu VPS. Encoders (OBS Studio, FFmpeg, Streamlabs, or any RTMP-compatible
software) publish to a single RTMP endpoint; Nginx converts the incoming
stream to HLS (`.m3u8` + `.ts` segments) and serves it over HTTP/HTTPS. A
lightweight built-in web player (using [hls.js](https://github.com/video-dev/hls.js))
lets anyone watch in a browser, and the same `.m3u8` URL works directly in
VLC, ffplay, or any IPTV player.

Everything is managed through one command, `sudo m3u8-manager`, so you never
need to hand-edit Nginx configuration to add, remove, or rotate keys for a
channel.

## Features

- One-command setup (`sudo ./install.sh`), interactive by default
- Non-interactive/scriptable install via flags or environment variables
- Multiple stream/channel management, no manual Nginx editing required
- Cryptographically random, unique stream keys (never predictable defaults)
- Interactive `m3u8-manager` administration menu (24 functions)
- Reliable HLS output with sane defaults (segment length, cleanup, CORS)
- Lightweight `hls.js` web player with native-HLS fallback and auto-retry
- Let's Encrypt / Certbot SSL support with DNS pre-checks
- Optional, confirmation-gated UFW firewall configuration
- Read-only server diagnostics (PASS/WARNING/FAIL report)
- Configuration backup and restore
- Conservative, confirmation-heavy uninstaller that only removes what this
  project created

## Requirements

- **Supported OS**: Ubuntu 18.04, 20.04, 22.04, 24.04, or 26.04 LTS (other
  distributions and unsupported Ubuntu versions are detected and rejected
  before anything is changed). "Supported" means the installer targets and
  actively accounts for that release; see [Support matrix](#support-matrix)
  below for which releases have actually been verified on a real VPS.
- **A domain name** pointed at your VPS's public IP (required for SSL;
  recommended even for HTTP-only use)
- **VPS resources**: 1 vCPU / 1 GB RAM minimum for a single low-bitrate
  stream; more CPU and RAM if you expect several simultaneous channels or
  higher bitrates
- **Storage**: enough free space for your HLS segment window - a few hundred
  MB is typically enough for the default settings, more for longer playlists
  or higher bitrates
- **Ports**: 22 (or your custom SSH port), 80, 443, and 1935 reachable from
  the internet (see [Firewall](#firewall))

## Installation

Clone the repository and run the installer as root:

```bash
git clone https://github.com/USERNAME/REPOSITORY.git
cd REPOSITORY
sudo ./install.sh
```

> Replace `USERNAME/REPOSITORY` with wherever you host this project. This
> README intentionally does not invent a real GitHub URL.

Once published, a one-line install will also work:

```bash
curl -fsSL https://raw.githubusercontent.com/USERNAME/REPOSITORY/main/install.sh | sudo bash
```

The installer will ask for:

- Your domain name
- An administrator email (used for Let's Encrypt renewal notices)
- The RTMP application name (default: `live`)
- Whether to enable HTTPS
- Whether to configure the firewall
- Your first channel's name and stream key preference

Sensible defaults are provided for everything - press Enter to accept them.

### Non-interactive install

```bash
sudo ./install.sh \
  --domain stream.example.com \
  --email admin@example.com \
  --rtmp-app live \
  --channel main \
  --stream-key auto \
  --ssl yes \
  --firewall no \
  --yes
```

Run `./install.sh --help` for the full list of flags and equivalent
environment variables.

## OBS Configuration

After installation, `m3u8-manager` prints these values for any channel
(menu option **6. Show OBS Settings**). In OBS: **Settings → Stream**:

```text
Service:
Custom

Server:
rtmp://stream.example.com/live

Stream Key:
<your channel's stream key>
```

## The Manager: `sudo m3u8-manager`

This is the primary day-to-day administration tool, installed to
`/usr/local/bin/m3u8-manager`:

```bash
sudo m3u8-manager
```

| # | Function | Description |
|---|---|---|
| 1 | Server Status | OS, Nginx, ports, HLS, SSL, firewall, disk at a glance |
| 2 | Add Stream / Channel | Create a channel with a manual or generated key |
| 3 | Remove Stream / Channel | Confirmed removal, optional HLS file cleanup |
| 4 | List Streams / Channels | Table of all channels and live/offline state |
| 5 | Show Stream Details | Full detail view; key shown only on request |
| 6 | Show OBS Settings | Copy-paste-ready OBS "Custom" service settings |
| 7 | Show M3U8 URL | The playback URL, plus whether it currently exists |
| 8 | Show Web Player URL | The browser player URL for a channel |
| 9 | Regenerate Stream Key | Rotates a key after explicit confirmation |
| 10 | Enable Stream | Re-enable a disabled channel |
| 11 | Disable Stream | Suspend ingest/playback without deleting the channel |
| 12 | Test Nginx Configuration | Read-only `nginx -t` |
| 13 | Reload Nginx | Test-then-reload; never reloads an invalid config |
| 14 | Restart Nginx | Confirmed restart, with a post-restart status check |
| 15 | View Logs | Nginx error/access logs, or the systemd journal |
| 16 | Check HLS Segments | Per-channel live/offline state and segment counts |
| 17 | SSL Management | Status, certificate details, renew, dry-run, configure |
| 18 | Firewall Status | Read-only UFW status; never changes rules by itself |
| 19 | Backup Configuration | Timestamped tarball of project config |
| 20 | Restore Configuration | Restore from a backup, with a safety backup first |
| 21 | Installation Summary | One-screen overview of the whole install |
| 22 | Server Diagnostics | PASS/WARNING/FAIL health report |
| 23 | Project Information | Version, paths, supported OS list |
| 24 | Uninstall Server | Hands off to `uninstall.sh` after confirmation |

## Adding a Stream

`m3u8-manager` → **2. Add Stream / Channel**, or non-interactively via the
library functions in `lib/streams.sh`. No Nginx restart is required - a
safe, validated reload happens automatically.

## Removing a Stream

`m3u8-manager` → **3. Remove Stream / Channel**. You will be shown exactly
what is being removed and asked to confirm before anything is deleted; HLS
file cleanup is a separate, optional confirmation.

## M3U8 URLs

An `.m3u8` file is an HLS playlist - a plain-text index of the small video
segments that make up a livestream. Once a channel's encoder is publishing,
its playlist is available at:

```text
https://stream.example.com/hls/<stream-key>.m3u8
```

This URL can be opened directly in VLC, ffplay, most IPTV apps, or embedded
in any HLS-capable player.

## Web Player

Visit `https://stream.example.com/` to see the built-in player. With a
single channel configured, it loads automatically; with multiple channels,
you'll see a picker. Each channel also has a direct URL:

```text
https://stream.example.com/watch/<channel-name>
```

## VLC Testing

**Media → Open Network Stream**, paste the `.m3u8` URL from `m3u8-manager`,
and click Play.

## FFmpeg / ffplay Testing

```bash
ffplay "https://stream.example.com/hls/<stream-key>.m3u8"
```

To simulate a publisher without OBS:

```bash
ffmpeg -re -i sample.mp4 -c copy -f flv "rtmp://stream.example.com/live/<stream-key>"
```

## SSL

HTTPS is provided via Certbot and Let's Encrypt. The installer checks that
your domain's DNS appears to point at the server's public IP before
requesting a certificate, and warns (with a chance to abort) if it does not.
Renewal is handled by Certbot's own systemd timer/cron job; check status any
time from `m3u8-manager` → **17. SSL Management**.

## Firewall

UFW configuration is entirely optional and never applied without an explicit
confirmation that lists exactly what will be opened. Ports potentially
involved:

```text
22 (or your detected SSH port)   SSH
80                                HTTP
443                               HTTPS (if SSL is enabled)
1935                              RTMP
```

The installer detects your actual configured SSH port before opening
anything, specifically to avoid locking you out.

## Backup / Restore

`m3u8-manager` → **19. Backup Configuration** creates a timestamped tarball
of `/etc/m3u8-server` and the generated Nginx files (not the HLS media
itself). **20. Restore Configuration** lists available backups, takes a
fresh safety backup of the current state first, restores the selected one,
and only reloads Nginx if the restored configuration passes validation.

## Uninstall

```bash
sudo ./uninstall.sh
```

or via `m3u8-manager` → **24. Uninstall Server**. The uninstaller only
removes what this project created (its Nginx config, manager command,
generated files) and asks separately before deleting HLS media, SSL
certificates, backups, firewall rules, or the underlying packages
(nginx/certbot/ffmpeg) - none of which are removed by default.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md) for common problems,
including OBS connection issues, 404s on the M3U8 URL, missing HLS segments,
SSL issuance failures, and firewall problems.

## Project Structure

```text
install.sh          Interactive/non-interactive installer
uninstall.sh         Conservative uninstaller
status.sh            Non-interactive status/diagnostics report
m3u8-manager         Interactive administration menu
config/nginx/        Nginx configuration templates (rendered at install time)
lib/                 Shared Bash libraries (common, streams, nginx, ssl, firewall, diagnostics)
web/                 Static web player (hls.js, no framework)
docs/                Troubleshooting guide
```

## Roadmap (not in v1)

This project intentionally keeps v1 focused on installing, configuring,
accepting RTMP, generating HLS, and managing channels reliably. Ideas for
later versions include adaptive bitrate transcoding, DVR/recording, stream
statistics, tokenized playback, SRT/WHIP ingest, Docker packaging, and a web
administration API. None of these are implemented yet.

## Support matrix

"Installer target" means the code actively detects and accounts for that
release (package availability checks, version-aware Nginx config
generation, etc.). "Real VPS tested" means an actual install has been run
end-to-end on that release and confirmed working - these are tracked
separately on purpose, and a release is never marked tested just because
the installer contains logic for it.

| Ubuntu | Installer target | Real VPS tested |
| ------ | ----------------- | ---------------- |
| 18.04  | Yes                | No                |
| 20.04  | Yes                | No                |
| 22.04  | Yes                | No                |
| 24.04  | Yes                | In progress - see below |
| 26.04  | Yes                | No                |

## Testing status

The Bash scripts in this repository have been statically reviewed and
syntax-checked (`bash -n`), and the generated Nginx configuration has been
reviewed for correctness against the Nginx and nginx-rtmp-module
documentation.

A real install has been attempted on **Ubuntu 24.04.4 LTS (x86_64, Nginx
1.24.0)**. That attempt surfaced two real bugs, both now fixed:

1. The generated SSL configuration used the standalone `http2 on;`
   directive, which does not exist before Nginx 1.25.1 - Nginx 1.24.0
   rejected it with `unknown directive "http2"`. The installer now detects
   the actual installed Nginx version and generates the HTTP/2 syntax that
   version supports, rather than assuming one syntax for all releases.
2. Firewall setup crashed with `ufw: command not found` even though the
   installer had already attempted to install it - a stale dpkg record
   (package present in the dpkg database but not actually installed, e.g.
   `deinstall ok config-files`) made the installer believe `ufw` was
   already there. Package-presence checks across the whole project now
   verify actual command availability, not just dpkg database state, and a
   firewall setup failure no longer aborts the rest of the installation.

The installer was also made safe to rerun against a partially-completed
install left in that exact state (Nginx/RTMP/HTTP working, certificate
issued, SSL config broken, firewall never configured) - rerunning
`install.sh` now repairs the SSL config, reuses the existing certificate
without requesting a new one, installs `ufw` if it's genuinely missing, and
leaves any already-created channel and its stream key untouched.

**This has not yet been confirmed as a full, clean end-to-end pass** (fresh
VPS, OBS publishing, HLS playback, VLC, web player, second channel,
disable/enable, key rotation, backup/restore, uninstall). Ubuntu
18.04/20.04/22.04/26.04 have received no real VPS testing at all - only
static review and the version-detection logic described above, which is
specifically designed not to assume a fixed Nginx/package version per
release. Please report any issues you hit during real-world deployment.
