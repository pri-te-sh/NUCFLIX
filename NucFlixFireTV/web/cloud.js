'use strict';
// ============================================================================
// NucFlix cloud (Firebase) for the Fire TV: the TV signs in anonymously, pairs with a household account
// through a short code approved on the iPhone, then reads that household's people profiles and Xtream
// lines and syncs favorites + watch progress (same Firestore documents as the iOS app).
// Firestore runs with its default in-memory cache, so nothing from the account — Xtream logins included —
// is written to the TV's storage. Only non-secret IDs (household, chosen profile/line) are remembered.
// ============================================================================
const Cloud = (() => {
  const K = { owner: 'nucflix.cloud.owner', ownerName: 'nucflix.cloud.ownerName', profile: 'nucflix.cloud.profile', line: 'nucflix.cloud.line' };
  const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // no O/0 or I/1
  const PROGRESS_INTERVAL = 20000;
  // The desktop browser preview talks to the local emulators; the Fire TV app (https://app.local) to Firebase.
  const EMULATOR = /^(localhost|127\.0\.0\.1)$/.test(location.hostname);

  let db = null;
  let auth = null;
  let functions = null;
  let FieldValue = null;
  let Timestamp = null;
  let tvUid = null;
  let owner = null;
  let started = null;
  let householdUnsubs = [];
  let profileUnsubs = [];
  let session = null; // { profileId, lineId }
  let deviceName = 'Fire TV'; // shown on the iPhone next to progress saved here
  const pending = new Map(); // contentKey -> progress doc not yet written
  const lastWrite = new Map();
  let flushTimer = null;

  const ls = {
    get: k => { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: (k, v) => { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) { /* ignore */ } }
  };

  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src;
      s.onload = resolve;
      s.onerror = () => reject(new Error('Could not load ' + src));
      document.head.appendChild(s);
    });
  }

  /** Loads Firebase, signs in (anonymously, persisted) and checks this TV's pairing. */
  function start() {
    if (started) return started;
    started = (async () => {
      for (const f of ['app', 'auth', 'firestore', 'functions']) await loadScript(`vendor/firebase/firebase-${f}-compat.js`);
      firebase.initializeApp(window.NUCFLIX_FIREBASE_CONFIG);
      auth = firebase.auth();
      db = firebase.firestore();
      functions = firebase.app().functions('us-central1');
      if (EMULATOR) {
        auth.useEmulator('http://127.0.0.1:9099', { disableWarnings: true });
        db.useEmulator('127.0.0.1', 8181);
        functions.useEmulator('127.0.0.1', 5001);
      }
      FieldValue = firebase.firestore.FieldValue;
      Timestamp = firebase.firestore.Timestamp;
      const existing = await new Promise(resolve => { const off = auth.onAuthStateChanged(u => { off(); resolve(u); }); });
      tvUid = (existing || (await auth.signInAnonymously()).user).uid;
      owner = ls.get(K.owner);
      if (owner) {
        try {
          if (!(await db.doc(`users/${owner}/members/${tvUid}`).get()).exists) setOwner(null);
        } catch (e) {
          // Offline: keep the pairing and let the listeners sort it out once the network is back.
        }
      }
      return { paired: !!owner };
    })();
    return started;
  }

  function setOwner(uid, name) {
    owner = uid;
    ls.set(K.owner, uid);
    if (name !== undefined || !uid) ls.set(K.ownerName, name || null);
  }

  // ---------------------------------------------------------------- pairing

  function newCode() {
    const bytes = new Uint8Array(8);
    crypto.getRandomValues(bytes);
    return Array.from(bytes, b => CODE_ALPHABET[b % CODE_ALPHABET.length]).join('');
  }

  /** Creates a pairing code (valid 10 minutes) and calls onPaired({ ownerName }) once the phone approves it. */
  async function beginPairing(tvName, onPaired) {
    const code = newCode();
    const ref = db.doc(`pairing/${code}`);
    await ref.set({
      tvUid, tvName, status: 'pending',
      createdAt: FieldValue.serverTimestamp(),
      expiresAt: Timestamp.fromMillis(Date.now() + 10 * 60 * 1000)
    });
    const unsub = ref.onSnapshot(async snap => {
      const d = snap.data();
      if (!d || d.status !== 'approved' || !d.ownerUid) return;
      unsub();
      setOwner(d.ownerUid, d.ownerName || '');
      ref.delete().catch(() => { });
      onPaired({ ownerName: d.ownerName || '' });
    }, () => { });
    return { code, expiresAt: Date.now() + 10 * 60 * 1000, cancel: () => { unsub(); ref.delete().catch(() => { }); } };
  }

  async function unpair() {
    stopSession();
    stopHousehold();
    if (owner) await db.doc(`users/${owner}/members/${tvUid}`).delete().catch(() => { });
    setOwner(null);
    ls.set(K.profile, null);
  }

  // ---------------------------------------------------------------- household (profiles + lines)

  /** Live profiles and lines of the paired household; onUnpaired fires if the phone removes this TV. */
  function watchHousehold({ onProfiles, onLines, onUnpaired }) {
    stopHousehold();
    const base = `users/${owner}`;
    const lost = err => { if (err && err.code === 'permission-denied') onUnpaired(); };
    householdUnsubs.push(db.collection(`${base}/profiles`).onSnapshot(s => {
      onProfiles(s.docs.map(d => Object.assign({ id: d.id }, d.data()))
        .sort((a, b) => (a.order || 0) - (b.order || 0) || String(a.name).localeCompare(b.name)));
    }, lost));
    householdUnsubs.push(db.collection(`${base}/lines`).onSnapshot(s => {
      // Lines stay in memory only (this array); nothing is persisted.
      onLines(s.docs.map(d => ({ id: d.id, name: d.get('name') || 'IPTV', serverURL: d.get('serverURL'), username: d.get('username'), password: d.get('password') || '' }))
        .filter(l => l.serverURL && l.username)
        .sort((a, b) => a.name.localeCompare(b.name)));
    }, lost));
    // Only the server can say the membership is gone: after an unpair + re-pair, the in-memory cache still
    // remembers the old delete and would report "missing" first.
    householdUnsubs.push(db.doc(`${base}/members/${tvUid}`).onSnapshot({ includeMetadataChanges: true }, d => {
      if (!d.exists && !d.metadata.fromCache) onUnpaired();
    }, lost));
  }

  function stopHousehold() {
    householdUnsubs.forEach(u => u());
    householdUnsubs = [];
  }

  // ---------------------------------------------------------------- one profile on one line

  function profileRef() {
    return db.doc(`users/${owner}/profiles/${session.profileId}`);
  }

  /**
   * Streams the profile's favorites and progress for the line (filtered client-side by lineId).
   * Resolves once both have delivered their first answer (or failed), so Home can wait for them.
   */
  function startSession(profileId, lineId, { onFavorites, onProgress }) {
    stopSession();
    session = { profileId, lineId };
    ls.set(K.profile, profileId);
    ls.set(K.line, lineId);
    const ref = profileRef();
    const mine = docs => docs.map(d => Object.assign({ key: d.id }, d.data({ serverTimestamps: 'estimate' })))
      .filter(d => d.lineId === lineId);
    let pending = 2;
    let done;
    const ready = new Promise(resolve => { done = resolve; });
    const once = () => {
      let called = false;
      return () => { if (called) return; called = true; if (--pending === 0) done(); };
    };
    const favLoaded = once(), progLoaded = once();
    profileUnsubs.push(ref.collection('favorites').onSnapshot(s => { onFavorites(mine(s.docs)); favLoaded(); }, favLoaded));
    profileUnsubs.push(ref.collection('progress').orderBy('updatedAt', 'desc').limit(150)
      .onSnapshot(s => { onProgress(mine(s.docs)); progLoaded(); }, progLoaded));
    return ready;
  }

  function stopSession() {
    flush();
    profileUnsubs.forEach(u => u());
    profileUnsubs = [];
    session = null;
  }

  function contentKey(kind, id) { return `${session.lineId}:${kind}:${id}`; }

  /** f: { kind: 'live'|'movie'|'series', id, title, artwork?, ext?, categoryId? } */
  function favoriteDoc(f) {
    const doc = { lineId: session.lineId, kind: f.kind, id: f.id, title: clip(f.title || 'Untitled', 300), addedAt: FieldValue.serverTimestamp() };
    if (f.artwork && f.artwork.length <= 1000) doc.artwork = f.artwork;
    if (f.ext) doc.ext = clip(f.ext, 10);
    if (f.categoryId) doc.categoryId = clip(String(f.categoryId), 40);
    return doc;
  }

  /** p: { kind, id, streamId?, seriesId?, episodeId?, season?, episode?, title, subtitle?, artwork?, ext?, position, duration } */
  function progressDoc(p) {
    const doc = {
      lineId: session.lineId, kind: p.kind, title: clip(p.title || 'Untitled', 300),
      position: Math.max(0, Number(p.position) || 0), duration: Math.max(0, Number(p.duration) || 0),
      updatedAt: FieldValue.serverTimestamp(), device: clip(deviceName, 80)
    };
    for (const f of ['streamId', 'seriesId', 'episodeId', 'season', 'episode']) if (p[f] != null && p[f] !== '' && !Number.isNaN(p[f])) doc[f] = p[f];
    if (p.subtitle) doc.subtitle = clip(p.subtitle, 300);
    if (p.artwork && p.artwork.length <= 1000) doc.artwork = p.artwork;
    if (p.ext) doc.ext = clip(p.ext, 10);
    return doc;
  }

  function setFavorite(on, f) {
    if (!session) return;
    const ref = profileRef().collection('favorites').doc(contentKey(f.kind, f.id));
    if (on) ref.set(favoriteDoc(f)).catch(e => console.warn('favorite', e));
    else ref.delete().catch(() => { });
  }

  function saveProgress(p, immediate = false) {
    if (!session) return;
    const key = contentKey(p.kind, p.id);
    pending.set(key, progressDoc(p));
    if (immediate || Date.now() - (lastWrite.get(key) || 0) >= PROGRESS_INTERVAL) write(key);
    else if (!flushTimer) flushTimer = setTimeout(flush, PROGRESS_INTERVAL);
  }

  function write(key) {
    const doc = pending.get(key);
    if (!doc || !session) return;
    pending.delete(key);
    lastWrite.set(key, Date.now());
    profileRef().collection('progress').doc(key).set(doc).catch(e => console.warn('progress', e));
  }

  /** Writes positions not saved yet (leaving the player, switching profile, app going to background). */
  function flush() {
    clearTimeout(flushTimer);
    flushTimer = null;
    for (const key of Array.from(pending.keys())) write(key);
  }

  function deleteProgress(keys) {
    if (!session || !keys.length) return;
    const batch = db.batch();
    keys.forEach(k => { pending.delete(k); batch.delete(profileRef().collection('progress').doc(k)); });
    batch.commit().catch(() => { });
  }

  /** Paired TVs may only change a profile's prefs (see firestore.rules). */
  function savePrefs(prefs) {
    if (!session) return;
    profileRef().set({ prefs, updatedAt: FieldValue.serverTimestamp() }, { merge: true }).catch(() => { });
  }

  // ---------------------------------------------------------------- AI (Cloud Functions) + its shared data

  /** Calls a household-only AI function (frameCheck, classifyCategories, smartSearch). */
  async function ai(name, data) {
    if (!functions || !owner) throw new Error('Not paired');
    const res = await functions.httpsCallable(name, { timeout: 30000 })(Object.assign({ ownerUid: owner }, data));
    return res.data;
  }

  /** Credits / intro times for a title on the current line ({ creditsAt, introStart, introEnd } or null). */
  async function getMarker(kind, id) {
    if (!session) return null;
    try {
      const d = await db.doc(`users/${owner}/markers/${contentKey(kind, id)}`).get();
      return d.exists ? d.data() : null;
    } catch (e) { return null; }
  }

  function saveMarker(kind, id, fields) {
    if (!session) return;
    const doc = { lineId: session.lineId, kind, source: 'ai', updatedAt: FieldValue.serverTimestamp() };
    for (const k of ['creditsAt', 'introStart', 'introEnd', 'duration']) {
      if (typeof fields[k] === 'number' && isFinite(fields[k])) doc[k] = Math.round(fields[k] * 10) / 10;
    }
    if (!doc.duration) return;
    db.doc(`users/${owner}/markers/${contentKey(kind, id)}`).set(doc, { merge: true }).catch(e => console.warn('marker', e));
  }

  /**
   * Live AI category tags for a line: cb({ 'live:12': { kids, adult, lang, genre }, ... }).
   * Resolves after the first answer has been handed to cb (or the read failed).
   */
  let tagsUnsub = null;
  function watchLineTags(lineId, cb) {
    if (tagsUnsub) tagsUnsub();
    tagsUnsub = null;
    if (!db || !owner || !lineId) return Promise.resolve();
    return new Promise(resolve => {
      tagsUnsub = db.doc(`users/${owner}/lineTags/${lineId}`).onSnapshot(d => {
        cb((d.exists && d.get('cats')) || {});
        resolve();
      }, () => resolve());
    });
  }

  // ---------------------------------------------------------------- now playing
  // users/{owner}/devices/{tvUid}: while this TV streams from the line, phones pause their downloads (lines
  // often allow one connection). lastSeen is refreshed every minute, so a TV that dies stops counting.
  let nowPlaying = null;
  let presenceTimer = null;
  let hiddenNowPlaying = null;

  function writePresence() {
    if (!db || !owner || !tvUid) return;
    db.doc(`users/${owner}/devices/${tvUid}`).set({
      name: clip(deviceName, 80), platform: 'firetv', lastSeen: FieldValue.serverTimestamp(),
      nowPlaying: nowPlaying && session
        ? { lineId: session.lineId, kind: nowPlaying.kind, title: clip(nowPlaying.title || 'Untitled', 200) }
        : null
    }).catch(e => console.warn('presence', e));
  }

  /** np: { kind, title } while the player streams from the line, null once it stops. */
  function setNowPlaying(np) {
    const was = !!nowPlaying;
    nowPlaying = np || null;
    clearInterval(presenceTimer);
    presenceTimer = nowPlaying ? setInterval(writePresence, 60000) : null;
    if (nowPlaying || was) writePresence();
  }

  function clip(s, n) { s = String(s); return s.length > n ? s.slice(0, n) : s; }

  window.addEventListener('pagehide', () => { flush(); setNowPlaying(null); });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      flush();
      hiddenNowPlaying = nowPlaying; // the player stops while NucFlix is in the background
      setNowPlaying(null);
    } else if (hiddenNowPlaying) {
      setNowPlaying(hiddenNowPlaying);
      hiddenNowPlaying = null;
    }
  });

  return {
    start, beginPairing, unpair, watchHousehold, stopHousehold, startSession, stopSession,
    setFavorite, saveProgress, flush, deleteProgress, savePrefs, ai, getMarker, saveMarker, watchLineTags, setNowPlaying,
    get paired() { return !!owner; },
    get ownerName() { return ls.get(K.ownerName) || ''; },
    get lastProfileId() { return ls.get(K.profile); },
    get lastLineId() { return ls.get(K.line); },
    selectLine(id) { ls.set(K.line, id); },
    set deviceName(name) { if (name) deviceName = String(name); }
  };
})();
