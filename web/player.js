/* player.js - lightweight HLS playback for the M3U8 Livestream Server.
 * Uses hls.js where needed, falls back to native HLS support (Safari/iOS),
 * and retries automatically when a channel is temporarily offline.
 */
(function () {
  "use strict";

  var video = document.getElementById("video");
  var overlay = document.getElementById("overlay");
  var overlayMessage = document.getElementById("overlay-message");
  var retryBtn = document.getElementById("retry-btn");
  var titleEl = document.getElementById("channel-title");
  var listSection = document.getElementById("channel-list-section");
  var listEl = document.getElementById("channel-list");

  var hls = null;
  var retryTimer = null;
  var retryDelayMs = 4000;

  function showOverlay(message, showRetry) {
    overlayMessage.textContent = message;
    overlay.classList.remove("hidden");
    retryBtn.classList.toggle("hidden", !showRetry);
  }

  function hideOverlay() {
    overlay.classList.add("hidden");
  }

  function channelNameFromPath() {
    var match = window.location.pathname.match(/^\/watch\/([a-z0-9_-]+)\/?$/i);
    return match ? match[1] : null;
  }

  function fetchChannels() {
    return fetch("/channels.generated.json", { cache: "no-store" })
      .then(function (res) {
        if (!res.ok) throw new Error("channels.generated.json returned " + res.status);
        return res.json();
      })
      .catch(function () {
        return [];
      });
  }

  function renderChannelList(channels) {
    listEl.innerHTML = "";
    channels.forEach(function (ch) {
      var li = document.createElement("li");
      var a = document.createElement("a");
      a.href = "/watch/" + encodeURIComponent(ch.name);
      a.textContent = ch.displayName || ch.name;
      li.appendChild(a);
      listEl.appendChild(li);
    });
    listSection.classList.remove("hidden");
  }

  function scheduleRetry(hlsUrl) {
    if (retryTimer) return;
    showOverlay("Stream is offline. Retrying...", false);
    retryTimer = setTimeout(function () {
      retryTimer = null;
      loadStream(hlsUrl);
    }, retryDelayMs);
  }

  function attachRetryButton(hlsUrl) {
    retryBtn.onclick = function () {
      if (retryTimer) {
        clearTimeout(retryTimer);
        retryTimer = null;
      }
      loadStream(hlsUrl);
    };
  }

  function loadStream(hlsUrl) {
    hideOverlay();
    attachRetryButton(hlsUrl);

    if (video.canPlayType("application/vnd.apple.mpegurl")) {
      video.src = hlsUrl;
      video.addEventListener("error", function onErr() {
        video.removeEventListener("error", onErr);
        scheduleRetry(hlsUrl);
      }, { once: true });
      video.play().catch(function () {});
      return;
    }

    if (window.Hls && window.Hls.isSupported()) {
      if (hls) {
        hls.destroy();
      }
      hls = new window.Hls({ liveSyncDurationCount: 3 });
      hls.loadSource(hlsUrl);
      hls.attachMedia(video);
      hls.on(window.Hls.Events.MANIFEST_PARSED, function () {
        hideOverlay();
        video.play().catch(function () {});
      });
      hls.on(window.Hls.Events.ERROR, function (_event, data) {
        if (!data.fatal) return;
        switch (data.type) {
          case window.Hls.ErrorTypes.NETWORK_ERROR:
            scheduleRetry(hlsUrl);
            break;
          case window.Hls.ErrorTypes.MEDIA_ERROR:
            hls.recoverMediaError();
            break;
          default:
            scheduleRetry(hlsUrl);
            break;
        }
      });
      return;
    }

    showOverlay("This browser does not support HLS playback.", false);
  }

  function init() {
    var name = channelNameFromPath();

    fetchChannels().then(function (channels) {
      if (!Array.isArray(channels) || channels.length === 0) {
        showOverlay("No live channels are currently configured.", false);
        return;
      }

      if (!name) {
        if (channels.length === 1) {
          name = channels[0].name;
        } else {
          showOverlay("Choose a channel below.", false);
          renderChannelList(channels);
          return;
        }
      }

      var channel = channels.filter(function (c) { return c.name === name; })[0];
      if (!channel) {
        showOverlay("Channel '" + name + "' was not found or is offline.", false);
        renderChannelList(channels);
        return;
      }

      titleEl.textContent = channel.displayName || channel.name;
      document.title = (channel.displayName || channel.name) + " - Livestream";
      loadStream(channel.hlsUrl);
    });
  }

  init();
})();
