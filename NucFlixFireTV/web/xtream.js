// ============================================================================
// NucFlix for Fire TV — Xtream Codes API, Formatter, Search Index & Recommender
// Ported 1:1 from the NucFlix iOS app (XtreamModels, FlexibleDecodable, RecommendationEngine)
// ============================================================================

const XtreamTextFormatter = (() => {
  const cache = new Map();
  const prefixSeparators = [' | ', '| ', ' - ', ': '];
  const trailingJunk = new Set(['|', '-', '/', '•', '◉', ' ']);

  function replaceUnicodeTags(str) {
    return str
      .replace(/\u2074\u1d37/g, '')
      .replace(/\u00b3\u2078\u2074\u2070\u1d3e/g, '')
      .replace(/\u1d30\u1d52\u02e1\u1d47\u02b8/g, '')
      .replace(/\u2c7d\u1da6\u02e2\u1da6\u1d52\u207f/g, '')
      .replace(/\u1d3f\u1d2c\u1d42/g, '')
      .replace(/\u1d34\u1d30/g, '')
      .replace(/\u25c9/g, '')
      .replace(/\s{2,}/g, ' ')
      .trim();
  }

  function format(raw) {
    const input = String(raw || '').trim();
    if (!input) {
      return { cleanTitle: 'Untitled', prefixTag: null, badges: [], isSectionDivider: false };
    }
    if (cache.has(input)) return cache.get(input);
    if (cache.size > 40000) cache.clear();

    let text = input;
    const hashCount = (text.match(/[#*=]/g) || []).length;
    const isDivider = hashCount >= 4 || text.startsWith('###') || text.endsWith('###');
    if (isDivider) {
      const stripped = replaceUnicodeTags(text.replace(/[#*=]/g, '')).trim();
      const res = {
        cleanTitle: stripped || 'Featured Section',
        prefixTag: null,
        badges: [],
        isSectionDivider: true
      };
      cache.set(input, res);
      return res;
    }

    const badges = [];
    const upper = text.toUpperCase();
    if (text.includes('\u2074\u1d37') || upper.includes('4K') || upper.includes('UHD') || text.includes('\u00b3\u2078\u2074\u2070')) {
      badges.push('4K');
    }
    if (text.includes('\u1d30\u1d52\u02e1\u1d47\u02b8') || upper.includes('DOLBY')) {
      badges.push('DOLBY');
    }
    if (text.includes('\u1d3f\u1d2c\u1d42') || upper.includes(' RAW')) {
      badges.push('RAW');
    }
    if (text.includes('\u1d34\u1d30') || upper.endsWith(' HD') || upper.includes(' HD ') || upper.includes('FHD')) {
      if (!badges.includes('4K')) badges.push('HD');
    }
    if (upper.includes('HEVC')) {
      badges.push('HEVC');
    }

    text = replaceUnicodeTags(text);

    let prefixTag = null;
    for (const sep of prefixSeparators) {
      const idx = text.indexOf(sep);
      if (idx > 0) {
        const candidate = text.slice(0, idx).trim();
        if (candidate.length >= 2 && candidate.length <= 12) {
          prefixTag = candidate.replace(/\|/g, '').trim();
          text = text.slice(idx + sep.length).trim();
          break;
        }
      }
    }

    if (text.endsWith(')')) {
      text = text.replace(/(\s*\([A-Za-z0-9\-\s]{2,14}\))+$/, '').trim();
    }
    while (text.length > 0 && trailingJunk.has(text[text.length - 1])) {
      text = text.slice(0, -1);
    }

    const res = {
      cleanTitle: text || input,
      prefixTag,
      badges,
      isSectionDivider: false
    };
    cache.set(input, res);
    return res;
  }

  return { format };
})();

function decodeBase64OrSelf(raw) {
  if (!raw || typeof raw !== 'string') return '';
  const trimmed = raw.trim();
  if (!trimmed || trimmed.includes(' ') || trimmed.length < 4) return trimmed;
  try {
    const bin = atob(trimmed);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const decoded = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    return decoded || trimmed;
  } catch (e) {
    return trimmed;
  }
}

function fastNormalize(text) {
  return String(text || '')
    .toLowerCase()
    .replace(/['’]/g, '')
    .replace(/[^a-z0-9\u00c0-\u024f]+/g, ' ')
    .trim();
}

// ============================================================================
// Credentials & Stream URL Builders
// ============================================================================

const XtreamCredentials = {
  normalizeBaseURL(serverURL) {
    let raw = String(serverURL || '').trim();
    if (!raw) return '';
    if (!/^https?:\/\//i.test(raw)) raw = 'http://' + raw;
    raw = raw.replace(/\/player_api\.php.*$/i, '').replace(/\/get\.php.*$/i, '');
    while (raw.endsWith('/')) raw = raw.slice(0, -1);
    return raw;
  },

  encodeSeg(val) {
    return encodeURIComponent(String(val || '').trim());
  },

  liveStreamURL(creds, streamId, format = 'm3u8') {
    const base = this.normalizeBaseURL(creds.serverURL);
    const u = this.encodeSeg(creds.username);
    const p = this.encodeSeg(creds.password);
    if (format === 'm3u8_root') return `${base}/${u}/${p}/${streamId}.m3u8`;
    if (format === 'ts') return `${base}/live/${u}/${p}/${streamId}.ts`;
    return `${base}/live/${u}/${p}/${streamId}.m3u8`;
  },

  vodStreamURL(creds, streamId, ext = 'mp4') {
    const base = this.normalizeBaseURL(creds.serverURL);
    const u = this.encodeSeg(creds.username);
    const p = this.encodeSeg(creds.password);
    const cleanExt = (ext && String(ext).trim()) ? String(ext).trim() : 'mp4';
    return `${base}/movie/${u}/${p}/${streamId}.${cleanExt}`;
  },

  seriesEpisodeURL(creds, episodeId, ext = 'mp4') {
    const base = this.normalizeBaseURL(creds.serverURL);
    const u = this.encodeSeg(creds.username);
    const p = this.encodeSeg(creds.password);
    const cleanExt = (ext && String(ext).trim()) ? String(ext).trim() : 'mp4';
    return `${base}/series/${u}/${p}/${episodeId}.${cleanExt}`;
  }
};

// ============================================================================
// Xtream API Service (Proxied via Java XtreamProxy for HTTP & HTTPS support)
// ============================================================================

// Maps a large list ~12 ms at a time, yielding between slices so the UI keeps responding while tens of
// thousands of catalog entries are cleaned up.
async function mapInSlices(list, fn) {
  const out = new Array(list.length);
  let i = 0;
  while (i < list.length) {
    const end = performance.now() + 12;
    while (i < list.length && performance.now() < end) { out[i] = fn(list[i]); i++; }
    if (i < list.length) await new Promise(r => setTimeout(r, 0));
  }
  return out;
}

const XtreamAPI = {
  buildPlayerApiUrl(creds, action = null, extraParams = {}) {
    const base = XtreamCredentials.normalizeBaseURL(creds.serverURL);
    if (!base) throw new Error('Invalid server URL.');
    const params = new URLSearchParams();
    params.set('username', creds.username);
    params.set('password', creds.password);
    if (action) params.set('action', action);
    for (const [k, v] of Object.entries(extraParams)) {
      if (v != null && v !== '') params.set(k, String(v));
    }
    return `${base}/player_api.php?${params.toString()}`;
  },

  async request(targetUrl) {
    const proxyUrl = `/api/xtream?url=${encodeURIComponent(targetUrl)}`;
    const resp = await fetch(proxyUrl);
    const data = await resp.json();
    if (data && data.ok === false && data.error) {
      throw new Error(data.error);
    }
    return data;
  },

  async authenticate(creds) {
    const url = this.buildPlayerApiUrl(creds);
    const data = await this.request(url);
    if (!data || !data.user_info) {
      throw new Error('Authentication failed: server did not return account info.');
    }
    const ui = data.user_info;
    const status = String(ui.status || '').toLowerCase();
    if (status === 'expired' || status === 'disabled') {
      throw new Error(`This subscription is ${ui.status}. Renew your line with your IPTV provider.`);
    }
    const isAuth = Number(ui.auth) === 1 || status === 'active';
    if (!isAuth) {
      throw new Error(`Authentication failed: ${ui.message || ui.status || 'Invalid credentials.'}`);
    }
    return data;
  },

  async fetchLiveCategories(creds) {
    try {
      const list = await this.request(this.buildPlayerApiUrl(creds, 'get_live_categories'));
      return Array.isArray(list) ? list.map(enrichCategory) : [];
    } catch (e) { return []; }
  },

  async fetchLiveStreams(creds, categoryId = null) {
    try {
      const extra = categoryId ? { category_id: categoryId } : {};
      const list = await this.request(this.buildPlayerApiUrl(creds, 'get_live_streams', extra));
      return Array.isArray(list) ? mapInSlices(list, enrichLiveStream) : [];
    } catch (e) { return []; }
  },

  async fetchShortEPG(creds, streamId, limit = 10) {
    try {
      const url = this.buildPlayerApiUrl(creds, 'get_short_epg', { stream_id: streamId, limit });
      const res = await this.request(url);
      const list = res && Array.isArray(res.epg_listings) ? res.epg_listings : [];
      return list.map(enrichEPGItem);
    } catch (e) { return []; }
  },

  async fetchVODCategories(creds) {
    try {
      const list = await this.request(this.buildPlayerApiUrl(creds, 'get_vod_categories'));
      return Array.isArray(list) ? list.map(enrichCategory) : [];
    } catch (e) { return []; }
  },

  async fetchVODStreams(creds, categoryId = null) {
    try {
      const extra = categoryId ? { category_id: categoryId } : {};
      const list = await this.request(this.buildPlayerApiUrl(creds, 'get_vod_streams', extra));
      return Array.isArray(list) ? mapInSlices(list, enrichMovie) : [];
    } catch (e) { return []; }
  },

  async fetchVODInfo(creds, vodId) {
    try {
      return await this.request(this.buildPlayerApiUrl(creds, 'get_vod_info', { vod_id: vodId }));
    } catch (e) { return null; }
  },

  async fetchSeriesCategories(creds) {
    try {
      const list = await this.request(this.buildPlayerApiUrl(creds, 'get_series_categories'));
      return Array.isArray(list) ? list.map(enrichCategory) : [];
    } catch (e) { return []; }
  },

  async fetchSeries(creds, categoryId = null) {
    try {
      const extra = categoryId ? { category_id: categoryId } : {};
      const list = await this.request(this.buildPlayerApiUrl(creds, 'get_series', extra));
      return Array.isArray(list) ? mapInSlices(list, enrichSeries) : [];
    } catch (e) { return []; }
  },

  async fetchSeriesInfo(creds, seriesId) {
    try {
      const raw = await this.request(this.buildPlayerApiUrl(creds, 'get_series_info', { series_id: seriesId }));
      return normalizeSeriesInfo(raw);
    } catch (e) {
      return { seasons: [], info: null, episodesBySeason: {}, sortedSeasonNumbers: [] };
    }
  }
};

// Model Normalizers
function enrichCategory(c) {
  const id = String(c.category_id ?? c.id ?? '0');
  const rawName = String(c.category_name ?? c.name ?? 'Uncategorized');
  const fmt = XtreamTextFormatter.format(rawName);
  return {
    id,
    categoryId: id,
    categoryName: rawName,
    cleanName: fmt.cleanTitle,
    prefixBadge: fmt.prefixTag,
    qualityBadges: fmt.badges
  };
}

function enrichLiveStream(s) {
  const id = Number(s.stream_id ?? s.id ?? 0);
  const rawName = String(s.name ?? 'Channel');
  const fmt = XtreamTextFormatter.format(rawName);
  return {
    id,
    streamId: id,
    num: Number(s.num ?? 1),
    name: rawName,
    cleanName: fmt.cleanTitle,
    prefixBadge: fmt.prefixTag,
    qualityBadges: fmt.badges,
    isSectionDivider: fmt.isSectionDivider,
    streamIcon: s.stream_icon || s.streamIcon || '',
    categoryId: String(s.category_id ?? s.categoryId ?? ''),
    isAdult: String(s.is_adult ?? '0') === '1'
  };
}

function enrichMovie(m) {
  const id = Number(m.stream_id ?? m.id ?? 0);
  const rawName = String(m.name ?? 'Movie');
  const fmt = XtreamTextFormatter.format(rawName);
  let ratingStr = String(m.rating ?? '').trim();
  if (!ratingStr || ratingStr === '0' || ratingStr === '0.0') {
    const r5 = Number(m.rating_5based ?? 0);
    ratingStr = r5 > 0 ? (r5 * 2).toFixed(1) : '';
  }
  return {
    id,
    streamId: id,
    num: Number(m.num ?? 1),
    name: rawName,
    cleanName: fmt.cleanTitle,
    prefixBadge: fmt.prefixTag,
    qualityBadges: fmt.badges,
    streamIcon: m.stream_icon || m.streamIcon || '',
    rating: ratingStr,
    added: String(m.added ?? '0'),
    categoryId: String(m.category_id ?? m.categoryId ?? ''),
    containerExtension: m.container_extension || m.containerExtension || 'mp4',
    isAdult: String(m.is_adult ?? '0') === '1'
  };
}

function enrichSeries(s) {
  const id = Number(s.series_id ?? s.id ?? 0);
  const rawName = String(s.name ?? 'Series');
  const fmt = XtreamTextFormatter.format(rawName);
  let ratingStr = String(s.rating ?? '').trim();
  if (!ratingStr || ratingStr === '0' || ratingStr === '0.0') {
    const r5 = Number(s.rating_5based ?? 0);
    ratingStr = r5 > 0 ? (r5 * 2).toFixed(1) : '';
  }
  const backdrops = Array.isArray(s.backdrop_path)
    ? s.backdrop_path
    : (typeof s.backdrop_path === 'string' && s.backdrop_path ? [s.backdrop_path] : []);
  return {
    id,
    seriesId: id,
    num: Number(s.num ?? 1),
    name: rawName,
    cleanName: fmt.cleanTitle,
    prefixBadge: fmt.prefixTag,
    qualityBadges: fmt.badges,
    cover: s.cover || backdrops[0] || '',
    backdrop: backdrops[0] || s.cover || '',
    plot: s.plot || '',
    cast: s.cast || '',
    director: s.director || '',
    genre: s.genre || '',
    releaseDate: String(s.releaseDate ?? s.release_date ?? ''),
    lastModified: String(s.last_modified ?? '0'),
    rating: ratingStr,
    categoryId: String(s.category_id ?? s.categoryId ?? '')
  };
}

function enrichEPGItem(e) {
  const startTs = Number(e.start_timestamp ?? 0);
  const stopTs = Number(e.stop_timestamp ?? 0);
  const now = Math.floor(Date.now() / 1000);
  const isNow = startTs <= now && stopTs > now;
  const progress = stopTs > startTs ? Math.min(1, Math.max(0, (now - startTs) / (stopTs - startTs))) : 0;
  let timeRange = '';
  if (startTs > 0 && stopTs > 0) {
    const fmt = ts => new Date(ts * 1000).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    timeRange = `${fmt(startTs)} – ${fmt(stopTs)}`;
  }
  return {
    id: `${e.id || ''}-${startTs}`,
    title: decodeBase64OrSelf(e.title || 'Program'),
    description: decodeBase64OrSelf(e.description || ''),
    startTimestamp: startTs,
    stopTimestamp: stopTs,
    isNowPlaying: isNow,
    progress,
    formattedTimeRange: timeRange
  };
}

function normalizeSeriesInfo(raw) {
  if (!raw) return { seasons: [], info: null, episodesBySeason: {}, sortedSeasonNumbers: [] };
  const episodesBySeason = {};
  if (raw.episodes && typeof raw.episodes === 'object') {
    if (Array.isArray(raw.episodes)) {
      raw.episodes.forEach((list, idx) => {
        if (Array.isArray(list) && list.length > 0) {
          const sNum = Number(list[0].season || (idx + 1));
          episodesBySeason[sNum] = list.map(ep => normalizeEpisode(ep, sNum)).sort((a, b) => a.episodeNum - b.episodeNum);
        }
      });
    } else {
      for (const [k, list] of Object.entries(raw.episodes)) {
        if (Array.isArray(list)) {
          const sNum = Number(k) || 1;
          episodesBySeason[sNum] = list.map(ep => normalizeEpisode(ep, sNum)).sort((a, b) => a.episodeNum - b.episodeNum);
        }
      }
    }
  }
  const sortedSeasonNumbers = Object.keys(episodesBySeason).map(Number).sort((a, b) => a - b);
  return {
    seasons: Array.isArray(raw.seasons) ? raw.seasons : [],
    info: raw.info || null,
    episodesBySeason,
    sortedSeasonNumbers
  };
}

function normalizeEpisode(ep, fallbackSeason) {
  const epNum = Number(ep.episode_num ?? ep.episodeNum ?? 1);
  const rawTitle = String(ep.title ?? `Episode ${epNum}`);
  return {
    id: String(ep.id ?? `${fallbackSeason}-${epNum}`),
    episodeId: String(ep.id ?? `${fallbackSeason}-${epNum}`),
    episodeNum: epNum,
    title: rawTitle,
    cleanTitle: XtreamTextFormatter.format(rawTitle).cleanTitle,
    season: Number(ep.season ?? fallbackSeason),
    containerExtension: ep.container_extension || ep.containerExtension || 'mp4',
    movieImage: ep.info?.movie_image || '',
    plot: ep.info?.plot || '',
    duration: ep.info?.duration || ''
  };
}

// ============================================================================
// Sub-Millisecond Inverted Prefix Catalog Search Index
// ============================================================================

class CatalogSearchIndex {
  constructor() {
    this.items = [];
    this.normalizedTitles = [];
    this.prefixMap3 = new Map();
    this.prefixMap2 = new Map();
  }

  // Indexing ~80k titles takes ~1.7 s on a Fire TV Stick, so it runs in small slices after start-up;
  // a search before it's done just finishes the remainder on the spot.
  buildAsync(items, delayMs = 6000) {
    this.reset(items);
    const run = () => {
      if (this.ready) return;
      const end = performance.now() + 12;
      while (this.next < this.items.length && performance.now() < end) this.add(this.next++);
      if (this.next < this.items.length) setTimeout(run, 30);
      else this.ready = true;
    };
    setTimeout(run, delayMs);
  }

  reset(items) {
    this.items = items || [];
    this.normalizedTitles = new Array(this.items.length);
    this.prefixMap3.clear();
    this.prefixMap2.clear();
    this.next = 0;
    this.ready = false;
  }

  finish() {
    while (this.next < this.items.length) this.add(this.next++);
    this.ready = true;
  }

  add(idx) {
    const norm = fastNormalize(this.items[idx].name || this.items[idx].cleanName || '');
    this.normalizedTitles[idx] = norm;
    const seen3 = new Set();
    const seen2 = new Set();
    const words = norm.split(' ');
    for (let w = 0; w < words.length; w++) {
      const word = words[w];
      if (word.length >= 3) {
        const p3 = word.slice(0, 3);
        if (!seen3.has(p3)) {
          seen3.add(p3);
          let arr = this.prefixMap3.get(p3);
          if (!arr) { arr = []; this.prefixMap3.set(p3, arr); }
          arr.push(idx);
        }
      }
      if (word.length >= 2) {
        const p2 = word.slice(0, 2);
        if (!seen2.has(p2)) {
          seen2.add(p2);
          let arr = this.prefixMap2.get(p2);
          if (!arr) { arr = []; this.prefixMap2.set(p2, arr); }
          arr.push(idx);
        }
      }
    }
  }

  search(rawQuery, limit = 80, showAdult = false) {
    if (!this.ready) this.finish();
    const normQ = fastNormalize(rawQuery);
    if (!normQ || !this.items.length) return [];
    const tokens = normQ.split(' ').filter(Boolean);
    if (!tokens.length) return [];

    let bestList = null;
    for (const tok of tokens) {
      let list = null;
      if (tok.length >= 3) list = this.prefixMap3.get(tok.slice(0, 3));
      else if (tok.length === 2) list = this.prefixMap2.get(tok);
      if (list && (!bestList || list.length < bestList.length)) {
        bestList = list;
      }
    }

    const exact = [];
    const others = [];
    const visited = new Set();

    const checkIdx = idx => {
      const item = this.items[idx];
      if (!item || item.isSectionDivider) return;
      if (!showAdult && item.isAdult) return;
      const t = this.normalizedTitles[idx];
      for (const tok of tokens) {
        if (!t.includes(tok)) return;
      }
      if (t === normQ || t.startsWith(normQ) || t.includes(' ' + normQ)) {
        exact.push(item);
      } else {
        others.push(item);
      }
    };

    if (bestList) {
      for (let i = 0; i < bestList.length; i++) {
        const idx = bestList[i];
        visited.add(idx);
        checkIdx(idx);
        if (exact.length + others.length >= limit * 2) break;
      }
    }

    if (exact.length + others.length < Math.min(limit, 24)) {
      for (let idx = 0; idx < this.normalizedTitles.length; idx++) {
        if (!visited.has(idx)) {
          checkIdx(idx);
          if (exact.length + others.length >= limit) break;
        }
      }
    }

    return exact.concat(others).slice(0, limit);
  }
}

// ============================================================================
// On-Device Recommendation Engine (Ported from RecommendationEngine.swift)
// ============================================================================

const RecommendationEngine = (() => {
  const stopWords = new Set([
    'the', 'a', 'an', 'of', 'and', 'in', 'on', 'to', 'for', 'with', 'part', 'season', 'movie',
    'hd', 'fhd', 'uhd', '4k', '1080p', '720p', 'hevc', 'multi', 'sub', 'dub'
  ]);

  function keywords(title) {
    return fastNormalize(title)
      .split(' ')
      .filter(w => w.length >= 3 && !stopWords.has(w) && isNaN(Number(w)));
  }

  function genres(raw) {
    if (!raw) return [];
    return String(raw)
      .replace(/[\/&]/g, ',')
      .split(',')
      .map(s => s.trim())
      .filter(s => s.length > 0 && s.length < 24);
  }

  function timeOfDayTitle() {
    const hr = new Date().getHours();
    if (hr >= 5 && hr < 12) return 'Your Morning Picks';
    if (hr >= 12 && hr < 17) return 'Top Picks for You';
    if (hr >= 17 && hr < 22) return "Tonight's Picks for You";
    return 'Late-Night Picks for You';
  }

  function buildFeed({ events, movies, series, vodCategoryNames, watchHistory }) {
    const nowMs = Date.now();
    const catAff = {};
    const genreAff = {};
    const wordAff = {};
    let totalWeight = 0;

    for (const ev of (events || [])) {
      if (ev.content === 'live') continue;
      const ageDays = Math.max(0, (nowMs - (ev.date || nowMs)) / 86400000);
      const w = (ev.weight || 2.0) * Math.pow(0.5, ageDays / 21);
      totalWeight += w;
      if (ev.categoryID) {
        const k = `${ev.content}:${ev.categoryID}`;
        catAff[k] = (catAff[k] || 0) + w;
      }
      for (const g of (ev.genres || [])) genreAff[g] = (genreAff[g] || 0) + w;
      for (const kw of keywords(ev.title || '')) wordAff[kw] = (wordAff[kw] || 0) + w * 0.5;
    }

    const isPersonalized = totalWeight > 2.0;
    const consumedMovies = new Set();
    const consumedSeries = new Set();
    for (const h of (watchHistory || [])) {
      if (h.contentType === 'movie' && h.streamID) consumedMovies.add(Number(h.streamID));
      if (h.seriesID) consumedSeries.add(Number(h.seriesID));
    }

    const scoreMovie = m => {
      const c = catAff[`movie:${m.categoryId}`] || 0;
      const r = (parseFloat(m.rating) || 7.5) / 10;
      let kwBoost = 0;
      for (const w of keywords(m.cleanName)) kwBoost = Math.max(kwBoost, wordAff[w] || 0);
      return c * 2.5 + kwBoost + r;
    };

    const scoreSeries = s => {
      const c = catAff[`series:${s.categoryId}`] || 0;
      const r = (parseFloat(s.rating) || 8.0) / 10;
      let gBoost = 0;
      for (const g of genres(s.genre)) gBoost += (genreAff[g] || 0);
      return c * 2.5 + gBoost + r;
    };

    const rankedMovies = (movies || [])
      .filter(m => !consumedMovies.has(m.streamId))
      .slice(0, 600)
      .map(m => ({ kind: 'movie', data: m, id: `movie-${m.streamId}`, score: scoreMovie(m) }))
      .sort((a, b) => b.score - a.score);

    const rankedSeries = (series || [])
      .filter(s => !consumedSeries.has(s.seriesId))
      .slice(0, 500)
      .map(s => ({ kind: 'series', data: s, id: `series-${s.seriesId}`, score: scoreSeries(s) }))
      .sort((a, b) => b.score - a.score);

    const blended = rankedMovies.slice(0, 120).concat(rankedSeries.slice(0, 120))
      .sort((a, b) => b.score - a.score);

    const used = new Set();
    const heroPicks = [];
    const lastWatched = (events || []).slice().reverse().find(e => e.content !== 'live' && e.kind !== 'detailView');

    for (const item of blended) {
      if (heroPicks.length >= 6) break;
      used.add(item.id);
      const idx = heroPicks.length;
      let reason = idx === 0 ? 'New on NucFlix' : 'Trending Now';
      if (isPersonalized) {
        if (idx === 0) reason = '#1 Pick for You';
        else if (idx === 1 && lastWatched) reason = `Because you watched ${XtreamTextFormatter.format(lastWatched.title).cleanTitle}`;
        else reason = 'Recommended for You';
      }
      const tags = [];
      if (item.kind === 'movie') {
        tags.push('Film');
        const catName = vodCategoryNames[item.data.categoryId];
        if (catName) tags.push(catName);
        if (item.data.rating) tags.push(`★ ${item.data.rating}`);
        if (item.data.qualityBadges && item.data.qualityBadges[0]) tags.push(item.data.qualityBadges[0]);
        else tags.push('HD');
      } else {
        tags.push('Series');
        const gs = genres(item.data.genre);
        tags.push(...gs.slice(0, 2));
        if (item.data.rating) tags.push(`★ ${item.data.rating}`);
      }
      heroPicks.push({ item, reason, tags: tags.slice(0, 4) });
    }

    const rails = [];

    // 1. Top Picks / Popular on NucFlix
    const topPicks = blended.filter(x => !used.has(x.id)).slice(0, 18);
    if (topPicks.length > 0) {
      topPicks.slice(0, 6).forEach(x => used.add(x.id));
      rails.push({
        id: 'top-picks',
        title: isPersonalized ? timeOfDayTitle() : 'Popular on NucFlix',
        style: 'poster',
        items: topPicks
      });
    }

    // 2. "Because you watched <Title>"
    if (lastWatched) {
      const anchorWords = new Set(keywords(lastWatched.title));
      const candidates = blended.filter(x => !used.has(x.id)).map(x => {
        const w = keywords(x.data.cleanName);
        let overlap = 0;
        for (const k of w) if (anchorWords.has(k)) overlap += 2;
        if (String(x.data.categoryId) === String(lastWatched.categoryID)) overlap += 1.5;
        return { item: x, sim: overlap + x.score * 0.2 };
      }).sort((a, b) => b.sim - a.sim).map(x => x.item).slice(0, 16);

      if (candidates.length >= 3) {
        rails.push({
          id: 'because-watched',
          title: `Because you watched ${XtreamTextFormatter.format(lastWatched.title).cleanTitle}`,
          style: 'poster',
          items: candidates
        });
      }
    }

    // 3. Top 10 Series Today (with Giant Outlined Rank Numbers 1-10!)
    const top10Series = rankedSeries.slice(0, 10);
    if (top10Series.length > 0) {
      rails.push({
        id: 'top10-series',
        title: 'Top 10 Shows for You Today',
        style: 'top10',
        items: top10Series
      });
    }

    // 4. New on NucFlix
    const freshMovies = (movies || []).slice().sort((a, b) => Number(b.added || 0) - Number(a.added || 0))
      .slice(0, 18).map(m => ({ kind: 'movie', data: m, id: `movie-${m.streamId}` }));
    if (freshMovies.length > 0) {
      rails.push({
        id: 'new-nucflix',
        title: 'New on NucFlix',
        style: 'poster',
        items: freshMovies
      });
    }

    // 5. Critically Acclaimed
    const acclaimed = blended.filter(x => parseFloat(x.data.rating || '0') >= 8.0).slice(0, 18);
    if (acclaimed.length >= 3) {
      rails.push({
        id: 'acclaimed',
        title: 'Critically Acclaimed',
        style: 'poster',
        items: acclaimed
      });
    }

    return { heroPicks, rails, isPersonalized };
  }

  return { buildFeed, genres };
})();
