// Watches the audio and video on this page and reports the main one. Reports only
// playback state and the title, never page content, and only for media that has
// actually been heard, so muted autoplay stays out of it.
(() => {
  if (window.__dynamicIslandMedia) return;
  window.__dynamicIslandMedia = true;

  const CHECK_MS = 2000;
  const POSITION_SYNC_MS = 10000;
  const heard = new WeakSet();
  let port = null;
  let current = null;
  let lastSent = "";
  let lastSentAt = 0;
  let checker = null;

  const isPlaying = el => !el.paused && !el.ended;
  const area = el => el.clientWidth * el.clientHeight;

  function candidates() {
    return [...document.querySelectorAll("video, audio")].filter(el => {
      if (!el.currentSrc && !el.srcObject) return false;
      // A background tab can be "playing" before it has loaded anything.
      if (isPlaying(el) && !el.muted && el.volume > 0 && el.readyState >= 2) heard.add(el);
      return heard.has(el);
    });
  }

  function pick() {
    const found = candidates();
    const playing = found.filter(isPlaying).sort((a, b) => area(b) - area(a));
    if (playing.length) return playing[0];
    return found.includes(current) ? current : found[found.length - 1] || null;
  }

  function describe(el) {
    const meta = navigator.mediaSession && navigator.mediaSession.metadata;
    const site = location.hostname.replace(/^www\./, "");
    const artwork = meta && meta.artwork.length ? meta.artwork[meta.artwork.length - 1].src : "";
    // A live stream reports an infinite or absurdly long duration.
    const duration = Number.isFinite(el.duration) && el.duration < 1e7 ? el.duration : 0;
    return {
      playing: isPlaying(el),
      title: (meta && meta.title) || document.title || site,
      artist: (meta && meta.artist) || site,
      art: artwork,
      duration: duration,
      position: el.currentTime,
      rate: el.playbackRate,
      canSeek: duration > 0 && el.seekable.length > 0,
    };
  }

  function report() {
    if (!port) return;
    current = pick();
    const state = current ? describe(current) : null;
    const key = JSON.stringify(state && { ...state, position: 0 });
    const now = Date.now();
    if (key === lastSent && now - lastSentAt < POSITION_SYNC_MS) return;
    lastSent = key;
    lastSentAt = now;
    port.postMessage({ state });
  }

  function reportNow() {
    lastSent = "";
    report();
  }

  function onMediaEvent() {
    if (!checker) checker = setInterval(report, CHECK_MS);
    reportNow();
  }

  function onCommand(message) {
    if (!current) return;
    if (message.command === "play" || (message.command === "toggle" && current.paused))
      current.play().catch(() => {});
    else if (message.command === "pause" || message.command === "toggle")
      current.pause();
    else if (message.command === "seek")
      current.currentTime = message.position;
  }

  function connect() {
    port = chrome.runtime.connect();
    port.onMessage.addListener(onCommand);
    port.onDisconnect.addListener(() => {
      port = null;
      // The id is gone once the extension was removed or reloaded: this copy is finished.
      if (chrome.runtime && chrome.runtime.id) setTimeout(connect, 1000);
      else clearInterval(checker);
    });
    lastSent = "";
    report();
  }

  // Media events don't bubble, but they can be seen on their way down.
  for (const name of ["play", "playing", "pause", "ended", "seeked", "durationchange", "ratechange", "volumechange", "emptied"])
    window.addEventListener(name, onMediaEvent, true);

  connect();
  if (document.querySelector("video, audio")) onMediaEvent();
})();
