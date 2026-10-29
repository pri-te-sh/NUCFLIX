'use strict';
// ============================================================================
// NucFlix "smart" helpers: frames for the AI checks, category tagging and smart-search filters.
// The AI itself runs in Cloud Functions (Ollama Cloud: Clef decisions, Gemma 4) via Cloud.ai(); nothing
// here ever blocks playback — every call can fail and the app carries on as before.
// ============================================================================
const Smart = (() => {
  const native = window.NucFlixNative || null;
  const pending = new Map();
  let seq = 0;
  let disabled = false; // set when the household is out of AI budget or the service is down

  /** The frame on screen as { b64, black }, or null. JPEG ~512 px wide. */
  function frame(width = 512) {
    if (native && native.captureFrame) {
      return new Promise(resolve => {
        const id = ++seq;
        pending.set(id, resolve);
        setTimeout(() => { if (pending.delete(id)) resolve(null); }, 4000);
        native.captureFrame(id, width);
      });
    }
    // Desktop preview: draw the fallback <video> (or a plain grey frame when there's no picture).
    const v = document.getElementById('fallback-video');
    const c = document.createElement('canvas');
    c.width = width;
    c.height = Math.round(width * 9 / 16);
    const g = c.getContext('2d');
    g.fillStyle = '#333';
    g.fillRect(0, 0, c.width, c.height);
    try { if (v && v.videoWidth) g.drawImage(v, 0, 0, c.width, c.height); } catch (e) { /* tainted */ }
    return Promise.resolve({ b64: c.toDataURL('image/jpeg', 0.72).split(',')[1], black: false });
  }

  function onFrame(id, b64, black) {
    const resolve = pending.get(id);
    if (!resolve) return;
    pending.delete(id);
    resolve(b64 ? { b64, black } : null);
  }

  async function call(name, data) {
    if (disabled) return null;
    try {
      return await Cloud.ai(name, data);
    } catch (e) {
      const code = String((e && e.code) || '');
      if (/resource-exhausted|permission-denied|unauthenticated/.test(code)) disabled = true;
      console.warn('ai', name, code || e);
      return null;
    }
  }

  /** Clef's verdict on one or two frames: { label, confidence, probabilities } or null. */
  const recent = []; // last verdicts, for debugging on the TV (chrome://inspect on --debug builds)
  async function frameCheck(task, images, title) {
    const r = await call('frameCheck', { task, images, title: title ? String(title).slice(0, 200) : undefined });
    recent.push({ at: new Date().toISOString(), task, label: r && r.label, p: r && r.probabilities });
    if (recent.length > 60) recent.shift();
    return r;
  }

  // ---------------------------------------------------------------- live channel alternatives

  const QUALITY = /\b(uhd|fhd|hd|sd|4k|8k|hevc|h265|backup|bk|raw|vip|plus|\d{3,4}p|50fps|60fps)\b/gi;
  const channelKey = name => String(name || '').toLowerCase()
    .replace(/^[a-z]{2,3}\s*[|:\-]\s*/, '').replace(QUALITY, ' ').replace(/[^a-z0-9]+/g, ' ').trim();

  /** Other channels that look like the same station (other quality or source), best first. */
  function alternatives(channel, live) {
    const key = channelKey(channel.cleanName || channel.name);
    if (!key) return [];
    return live.filter(c => c.streamId !== channel.streamId && channelKey(c.cleanName || c.name) === key).slice(0, 5);
  }

  // ---------------------------------------------------------------- category tags

  const Tags = {
    lineId: null,
    map: {},
    running: false,
    onChange: null,

    /** Follows the line's tags and fills in categories that don't have any yet (in the background). */
    start(lineId, raw, onChange) {
      this.lineId = lineId;
      this.onChange = onChange;
      Cloud.watchLineTags(lineId, map => {
        if (this.lineId !== lineId) return;
        this.map = map;
        if (this.onChange) this.onChange(map);
        this.fill(lineId, raw);
      });
    },

    get(kind, categoryId) { return this.map[`${kind}:${categoryId}`] || null; },

    async fill(lineId, raw) {
      if (this.running || disabled) return;
      const todo = [];
      const add = (kind, list) => (list || []).forEach(c => {
        if (c.categoryId != null && c.categoryName && !this.map[`${kind}:${c.categoryId}`]) {
          todo.push({ id: String(c.categoryId), name: String(c.categoryName).slice(0, 120), kind });
        }
      });
      add('live', raw.liveCats); add('movie', raw.vodCats); add('series', raw.seriesCats);
      if (!todo.length) return;
      this.running = true;
      try {
        for (let i = 0; i < todo.length && this.lineId === lineId && !disabled; i += 16) {
          const res = await call('classifyCategories', { lineId, categories: todo.slice(i, i + 16) });
          if (!res) break;
          Object.assign(this.map, Object.fromEntries(Object.entries(res.tags || {})));
          await new Promise(r => setTimeout(r, 1500)); // gentle: one batch every couple of seconds
        }
      } finally {
        this.running = false;
      }
    }
  };

  // ---------------------------------------------------------------- smart search

  const searchCache = new Map();

  /** Natural-language request -> filters (null when it reads like a plain title search or AI is off). */
  async function searchFilters(query) {
    const q = String(query || '').trim().toLowerCase();
    if (q.split(/\s+/).length < 3) return null;
    if (searchCache.has(q)) return searchCache.get(q);
    const f = await call('smartSearch', { query: q });
    if (f) searchCache.set(q, f);
    return f;
  }

  const yearOf = d => {
    const m = String(d.name || '').match(/\((19|20)\d{2}\)|\b(19|20)\d{2}\b/);
    return m ? Number(m[0].replace(/\D/g, '')) : null;
  };

  /**
   * Applies smart-search filters to the catalog. Category tags supply language + genre; years come from
   * the title ("Movie (2016)"). Returns [{ kind, data }], best matches first.
   */
  function applyFilters(f, cat) {
    const kinds = f.kind === 'any' ? ['movie', 'series', 'live'] : [f.kind];
    const lists = { movie: cat.movies, series: cat.series, live: cat.live };
    const words = (f.keywords || []).map(w => w.toLowerCase());
    const out = [];
    for (const kind of kinds) {
      for (const d of lists[kind] || []) {
        const tag = Tags.get(kind, d.categoryId);
        if (f.languages.length && !(tag && f.languages.includes(tag.lang))) continue;
        if (f.genres.length && !(tag && f.genres.includes(tag.genre)) && !words.length) continue;
        const year = yearOf(d);
        if (f.yearFrom && (!year || year < f.yearFrom)) continue;
        if (f.yearTo && (!year || year > f.yearTo)) continue;
        const name = String(d.cleanName || d.name || '').toLowerCase();
        const hits = words.filter(w => name.includes(w)).length;
        if (words.length && !hits && !(f.genres.length && tag && f.genres.includes(tag.genre))) continue;
        const genreHit = tag && f.genres.includes(tag.genre) ? 1 : 0;
        out.push({ kind, data: d, score: hits * 3 + genreHit * 2 + (Number(d.rating) || 0) / 10, year, added: Number(d.added || 0) });
      }
    }
    if (f.sort === 'newest') out.sort((a, b) => (b.year || 0) - (a.year || 0) || b.added - a.added);
    else if (f.sort === 'rating') out.sort((a, b) => (Number(b.data.rating) || 0) - (Number(a.data.rating) || 0));
    else out.sort((a, b) => b.score - a.score || b.added - a.added);
    return out.slice(0, 60).map(({ kind, data }) => ({ kind, data }));
  }

  /** "Hindi comedy movies, 2010–2019" */
  function describe(f) {
    const names = { en: 'English', hi: 'Hindi', ta: 'Tamil', te: 'Telugu', ml: 'Malayalam', es: 'Spanish', ar: 'Arabic', fr: 'French' };
    const parts = [
      f.languages.map(l => names[l] || l.toUpperCase()).join('/'),
      f.genres.join('/'),
      { movie: 'movies', series: 'shows', live: 'channels', any: 'titles' }[f.kind] || 'titles'
    ].filter(Boolean).join(' ');
    const years = f.yearFrom && f.yearTo && f.yearFrom !== f.yearTo ? `${f.yearFrom}–${f.yearTo}` : (f.yearFrom || f.yearTo || '');
    const words = f.keywords.length ? ` matching “${f.keywords.join(' ')}”` : '';
    return parts.charAt(0).toUpperCase() + parts.slice(1) + (years ? `, ${years}` : '') + words;
  }

  return { frame, onFrame, frameCheck, alternatives, Tags, searchFilters, applyFilters, describe, recent, get disabled() { return disabled; } };
})();
