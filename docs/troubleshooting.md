# Troubleshooting

Run `sudo m3u8-manager` → **22. Server Diagnostics** (or `sudo m3u8-status`)
first for almost every issue below - it checks most of these conditions
automatically and tells you PASS/WARNING/FAIL for each.

## The installer stopped partway through / crashed with an error

`install.sh` is designed to be safe to run again. Just re-run:

```bash
sudo ./install.sh
```

It detects what already succeeded (Nginx installed, certificate issued,
channel already created, etc.) and only does what's still needed - it will
not create a duplicate channel, will not request a duplicate SSL
certificate, and will not touch an existing channel's stream key. If the
first run got Nginx and HLS working but failed later (for example, at
firewall setup), that earlier work is preserved and the rerun picks up
where it left off.

## OBS cannot connect

- Confirm the **Server** field is exactly `rtmp://your-domain/live` (or your
  configured RTMP application name), with no stream key appended.
- Confirm the stream key matches exactly what `m3u8-manager` → **6. Show OBS
  Settings** shows for that channel.
- Check RTMP port 1935 is open: `m3u8-manager` → **18. Firewall Status**, or
  `sudo ss -tln | grep 1935`.

## Connection refused

- Nginx may not be running: `m3u8-manager` → **1. Server Status**, or
  `sudo systemctl status nginx`.
- The firewall may be blocking port 1935. See "Firewall blocks RTMP" below.

## Wrong stream key

- The RTMP `on_publish` check rejects unknown or disabled stream keys with a
  connection failure from OBS almost immediately after connecting. Verify the
  key with `m3u8-manager` → **5. Show Stream Details** (choose "yes" to
  reveal the key) or **6. Show OBS Settings**.
- If the channel was recently disabled (`m3u8-manager` → **11**), re-enable
  it with **10. Enable Stream**.

## M3U8 URL returns 404

- The playlist file is only created once OBS is actively publishing. Start
  your stream, wait a few seconds, then reload.
- Confirm the URL matches `m3u8-manager` → **7. Show M3U8 URL** exactly,
  including the stream key.
- Check `16. Check HLS Segments` to see whether the channel is producing
  segments at all.

## M3U8 exists but video does not play

- Test the URL directly in VLC or with `ffplay` (see the main README) to
  rule out a player-specific issue.
- Check the browser console for mixed-content or CORS errors (see "HTTPS
  mixed-content problem" below).
- Confirm the encoder is actually sending video+audio (some encoders take a
  few seconds to produce the first keyframe; nginx-rtmp waits for a keyframe
  before starting HLS output).

## HLS segments are not being generated

- Run `m3u8-manager` → **16. Check HLS Segments**. If the HLS directory is
  not writable by `www-data`, HLS output will silently fail.
- Confirm the HLS directory exists and has correct ownership:
  `sudo ls -ld /var/www/m3u8-server/hls` (should be owned by `www-data`).
- Check `sudo journalctl -u nginx -n 100` for RTMP-related errors.

## Player loads but stream stays "offline"

- This means the web page loaded, but no HLS playlist exists yet for that
  channel - the encoder is not currently publishing. Start OBS and wait a
  few seconds; the player retries automatically.

## Domain points to the wrong IP

- Run `m3u8-manager` → **22. Server Diagnostics**, which checks whether your
  domain's DNS currently resolves to this server's public IP.
- DNS changes can take time to propagate. Re-check with
  `dig +short your-domain` or `nslookup your-domain` from another machine.

## SSL certificate issuance fails

- The most common cause is DNS not yet pointing at this server - fix DNS
  first, then retry from `m3u8-manager` → **17. SSL Management** → **5.
  Configure SSL if missing**.
- Make sure port 80 is reachable from the public internet (Let's Encrypt's
  HTTP-01 challenge requires it); check your firewall and any cloud
  provider security groups.

## Firewall blocks RTMP

- If you enabled UFW through this project, port 1935 should already be
  open. Verify with `m3u8-manager` → **18. Firewall Status**.
- If you manage the firewall yourself (or your VPS provider has a separate
  network firewall/security group), make sure TCP port 1935 is allowed
  inbound.

## Firewall blocks HTTP/HTTPS

- Verify ports 80 and 443 are open with `m3u8-manager` → **18. Firewall
  Status**. Remember to also check any cloud-provider-level firewall
  (security groups, etc.) in addition to UFW.

## Nginx configuration test fails

- Run `m3u8-manager` → **12. Test Nginx Configuration** to see the exact
  error. The previous, working configuration is never replaced until a new
  one passes this test, so your server stays online while you fix it.

## Nginx will not restart

- Check `sudo systemctl status nginx` and `sudo journalctl -u nginx -n 50`
  for the underlying error. A common cause is another process already bound
  to port 80 or 443.

## Permission denied

- Most project files under `/etc/m3u8-server` are intentionally readable
  only by root, since they include stream keys. Use `sudo` for all
  management commands.

## Disk full

- HLS segments accumulate on disk while a stream is live. Check usage with
  `m3u8-manager` → **1. Server Status** or `df -h`. Segment cleanup is
  enabled by default (`hls_cleanup on`), but a very long stream or a very
  full disk elsewhere can still exhaust space.

## VLC cannot open the stream

- Use **Media → Open Network Stream** and paste the exact M3U8 URL from
  `m3u8-manager` → **7. Show M3U8 URL**.
- If the channel is offline, VLC will fail to open the stream - the file
  does not exist until the encoder is publishing.

## HTTPS mixed-content problem

- If your site is served over HTTPS but the M3U8/HLS URL was copied before
  SSL was enabled (i.e., still starts with `http://`), browsers will block
  it as mixed content. Re-fetch the URL from `m3u8-manager` (it always
  reflects the current SSL state) and use the `https://` version.

## Stream works locally but not publicly

- Confirm your domain's DNS actually points at this server's public IP
  (see "Domain points to the wrong IP" above).
- Confirm your VPS provider's network firewall/security group (separate
  from UFW) allows inbound traffic on 80, 443 and 1935.
