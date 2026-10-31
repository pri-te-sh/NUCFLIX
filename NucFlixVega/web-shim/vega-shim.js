// NucFlix on Vega OS: loaded before the shared Fire TV web UI (../NucFlixFireTV/web).
// The Android app served /api/* from Java; here the page is a file:// URL, so those calls go to the
// React Native side over the WebView message channel instead (no CORS or mixed-content limits there).
(function () {
  'use strict';

  const pending = new Map();
  let seq = 0;

  function post(msg) {
    if (window.ReactNativeWebView) window.ReactNativeWebView.postMessage(JSON.stringify(msg));
  }

  function callNative(type, payload) {
    return new Promise(resolve => {
      const id = ++seq;
      pending.set(id, resolve);
      post(Object.assign({ id, type }, payload));
    });
  }

  // React Native answers with injectJavaScript("window.__nucflixReply(id, status, body)").
  window.__nucflixReply = function (id, status, body) {
    const resolve = pending.get(id);
    if (!resolve) return;
    pending.delete(id);
    resolve(new Response(body, { status, headers: { 'Content-Type': 'application/json' } }));
  };

  // Host hooks app.js uses when there's no Android bridge.
  window.NucFlixHost = {
    exitApp: () => post({ type: 'exit' })
  };

  // Same methods as the Android NucFlixBridge (MainActivity.java). Video goes to the native W3C player in
  // NucFlixVega/src/NativePlayer.ts, drawn behind this page; it answers through App.onNativeVideoState.
  const video = op => (...args) => post({ type: 'video', op, args });
  window.NucFlixNative = {
    // Artwork loads directly: the Android /api/img proxy (downsizing) has no Vega counterpart yet.
    directImages: true,
    startVideo: video('start'),
    stopVideo: video('stop'),
    togglePause: video('togglePause'),
    seekTo: video('seekTo'),
    setSpeed: video('setSpeed'),
    setAspectMode: video('setAspectMode'),
    selectTrack: video('selectTrack'),
    beginScrub: video('beginScrub'),
    endScrub: video('endScrub'),
    // No frame grabs from the Vega video surface yet: answer "no picture" so callers don't wait.
    requestThumb: (sec, id) => setTimeout(() => window.App && App.onThumb(id, sec, ''), 0),
    captureFrame: id => setTimeout(() => window.App && App.onFrame(id, '', false), 0),
    playTudum: () => { },
    openInVlc: () => { },
    promptInput: () => { },
    exitApp: () => post({ type: 'exit' })
  };

  const SESSION = JSON.stringify({ deviceModel: 'Fire TV (Vega OS)' });
  const nativeFetch = window.fetch.bind(window);

  window.fetch = function (input, init) {
    const url = typeof input === 'string' ? input : (input && input.url) || '';
    if (url.startsWith('/api/xtream')) {
      const target = new URLSearchParams(url.slice(url.indexOf('?') + 1)).get('url');
      return callNative('xtream', { url: target });
    }
    if (url.startsWith('/api/session')) {
      return Promise.resolve(new Response(SESSION, { status: 200, headers: { 'Content-Type': 'application/json' } }));
    }
    return nativeFetch(input, init);
  };

  // Remote keys that app.js's desktop keymap doesn't know. Anything unmapped is logged so new keys can be added.
  const EXTRA_KEYS = {
    GoBack: 'BACK', BrowserBack: 'BACK',
    MediaPlay: 'PLAY', MediaPause: 'PAUSE',
    MediaFastForward: 'FF', MediaRewind: 'REW',
    ChannelUp: 'CH_UP', ChannelDown: 'CH_DOWN'
  };
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' || e.key === 'Backspace') dbg('page key ' + e.key + ' (BACK)');
    const k = EXTRA_KEYS[e.key];
    if (k && window.App) {
      e.preventDefault();
      e.stopImmediatePropagation();
      window.App.onRemoteKey(k);
    } else if (!/^(Arrow|Enter|Escape|Backspace| )/.test(e.key)) {
      dbg('key ' + e.key + ' code=' + e.keyCode);
    }
  }, true);

  // ------------------------------------------------------------------ On-screen debug panel
  // The TV's logs aren't readable from the dev shell, so recent events are drawn in the corner.
  // Remove (or set DEBUG = false) once playback works.
  const DEBUG = true;
  const lines = [];
  let panel = null;
  function dbg(msg) {
    post({ type: 'log', level: 'info', msg });
    if (!DEBUG) return;
    lines.push(new Date().toISOString().slice(11, 19) + ' ' + msg);
    while (lines.length > 14) lines.shift();
    if (!panel && document.body) {
      panel = document.createElement('pre');
      panel.style.cssText = 'position:fixed;top:8px;right:8px;z-index:99999;max-width:46vw;margin:0;padding:8px 10px;' +
        'background:rgba(0,0,0,.78);color:#7CFC9A;font:13px/1.35 monospace;white-space:pre-wrap;pointer-events:none';
      document.body.appendChild(panel);
    }
    if (panel) panel.textContent = lines.join('\n');
  }
  window.__nucflixDebug = dbg;

  // Shows host + file type only; stream URLs carry the line's username and password.
  function describe(url) {
    try {
      const u = new URL(url);
      const file = u.pathname.split('/').pop() || '';
      return u.protocol + '//' + u.host + ' …' + (file.includes('.') ? file.slice(file.lastIndexOf('.')) : '/' + file.slice(-6));
    } catch (e) { return String(url).slice(0, 40); }
  }

  function probeFormats() {
    const v = document.createElement('video');
    const types = {
      mp4: 'video/mp4; codecs="avc1.64001f,mp4a.40.2"',
      hls: 'application/vnd.apple.mpegurl',
      ts: 'video/mp2t',
      mkv: 'video/x-matroska',
      webm: 'video/webm'
    };
    const can = Object.keys(types).map(k => k + '=' + (v.canPlayType(types[k]) || 'no')).join(' ');
    const MS = window.MediaSource || window.ManagedMediaSource;
    const mse = MS ? ['video/mp4; codecs="avc1.64001f,mp4a.40.2"', 'video/mp2t; codecs="avc1.64001f,mp4a.40.2"', 'audio/mp4; codecs="ac-3"', 'audio/mp4; codecs="ec-3"']
      .map(t => t.split(';')[0].split('/')[1] + (t.includes('ac-3') ? '+ac3' : t.includes('ec-3') ? '+eac3' : '') + '=' + MS.isTypeSupported(t)).join(' ') : 'none';
    dbg('canPlay: ' + can);
    dbg('MSE: ' + mse);
  }

  function watchVideo(v) {
    const MEDIA_ERR = { 1: 'ABORTED', 2: 'NETWORK', 3: 'DECODE', 4: 'SRC_NOT_SUPPORTED' };
    ['loadstart', 'loadedmetadata', 'canplay', 'playing', 'pause', 'waiting', 'stalled', 'suspend', 'emptied', 'ended'].forEach(ev =>
      v.addEventListener(ev, () => dbg('video ' + ev + (ev === 'loadedmetadata' ? ' ' + v.videoWidth + 'x' + v.videoHeight + ' dur=' + Math.round(v.duration) : '') +
        ' rs=' + v.readyState + ' ns=' + v.networkState)));
    v.addEventListener('error', () => {
      const e = v.error;
      dbg('video ERROR ' + (e ? (MEDIA_ERR[e.code] || e.code) + ' ' + (e.message || '') : '?'));
    });
    // If nothing loads within 10 s, stop the video (lines may allow one connection) and ask the
    // server directly from the app side, to tell "server won't answer here" from "WebView can't play it".
    let stallTimer = 0;
    const play = v.play.bind(v);
    v.play = function () {
      const src = v.currentSrc || v.src;
      dbg('play() src=' + describe(src));
      clearTimeout(stallTimer);
      stallTimer = setTimeout(() => {
        if (v.readyState >= 2 || (v.currentSrc || v.src) !== src) return;
        dbg('no data after 10s (rs=' + v.readyState + ') - stopping video, probing server…');
        v.removeAttribute('src');
        v.load();
        post({ type: 'probe', id: 0, url: src });
      }, 10000);
      const p = play();
      if (p && p.catch) p.catch(err => dbg('play() rejected: ' + (err && (err.name + ' ' + err.message))));
      return p;
    };
  }

  document.addEventListener('DOMContentLoaded', () => {
    probeFormats();
    const v = document.getElementById('fallback-video');
    if (v) watchVideo(v);
  });

  window.addEventListener('error', e => dbg('JS error: ' + String(e.message) + ' @' + String(e.filename).split('/').pop() + ':' + e.lineno));
  window.addEventListener('unhandledrejection', e => dbg('unhandled: ' + String(e.reason && (e.reason.message || e.reason))));
})();
