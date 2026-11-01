// NucFlix AI features. The apps never see the Ollama API key: they call these household-only functions,
// which call Ollama Cloud — Clef (decision model, reads images) for yes/no and multiple-choice judgements,
// Gemma 4 for turning a spoken-style search into catalog filters.
//
// Callers: the household owner's phone (Google/email account) or a paired TV (anonymous; passes ownerUid,
// and must be in users/{ownerUid}/members). Every call counts against a per-household daily limit.
//
// Local emulator: put OLLAMA_API_KEY=mock in functions/.secret.local to get deterministic fake answers
// (see mock.js) instead of calling Ollama.

import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { defineSecret } from 'firebase-functions/params';
import { logger } from 'firebase-functions';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { createHash } from 'node:crypto';
import { mockChat, mockDecision } from './mock.js';

initializeApp();
const db = getFirestore();

const OLLAMA_API_KEY = defineSecret('OLLAMA_API_KEY');
const OLLAMA = 'https://ollama.com';
const DECISION_MODEL = 'clef';
const CHAT_MODEL = 'gemma4:31b';
const DAILY_LIMIT = 4000;

const options = { secrets: [OLLAMA_API_KEY], region: 'us-central1', memory: '256MiB', timeoutSeconds: 60, maxInstances: 5 };

export const LANGUAGES = {
  en: 'English', hi: 'Hindi', ta: 'Tamil', te: 'Telugu', ml: 'Malayalam', kn: 'Kannada', mr: 'Marathi',
  bn: 'Bengali', gu: 'Gujarati', pa: 'Punjabi', ur: 'Urdu', ar: 'Arabic', es: 'Spanish', fr: 'French',
  de: 'German', it: 'Italian', pt: 'Portuguese', tr: 'Turkish', ru: 'Russian', zh: 'Chinese', ja: 'Japanese',
  ko: 'Korean', nl: 'Dutch', multi: 'Several languages or international', other: 'Another language, or unclear'
};

export const GENRES = {
  action: 'Action or adventure', comedy: 'Comedy', drama: 'Drama', thriller: 'Thriller or mystery',
  horror: 'Horror', romance: 'Romance', scifi: 'Science fiction or fantasy', kids: 'Kids or animation',
  documentary: 'Documentary or factual', crime: 'Crime', family: 'Family', sports: 'Sports', news: 'News',
  music: 'Music', reality: 'Reality or entertainment shows', religious: 'Religious or devotional',
  adult: 'Adult (18+)', mixed: 'Mixed, or not a genre (a streaming service, a country, "New releases"...)'
};

// ------------------------------------------------------------------ helpers

// Pairings and lines that were found to exist, remembered per instance for a few minutes: a TV makes many calls in
// a row (credits checks, title batches) and each used to re-read the same documents. An unpaired TV can keep using
// the AI (not the household's data) for at most this long.
const SEEN_FOR = 5 * 60 * 1000;
const seen = new Map();

async function exists(path) {
  const at = seen.get(path);
  if (at && Date.now() - at < SEEN_FOR) return true;
  if (!(await db.doc(path).get()).exists) return false;
  if (seen.size > 1000) seen.clear();
  seen.set(path, Date.now());
  return true;
}

/** Returns the household (owner uid) the caller belongs to, or throws. */
async function household(request) {
  const auth = request.auth;
  if (!auth) throw new HttpsError('unauthenticated', 'Sign in to NucFlix first.');
  if (auth.token.firebase?.sign_in_provider !== 'anonymous') return auth.uid;
  const owner = String(request.data?.ownerUid || '');
  if (!/^[\w-]{1,128}$/.test(owner)) throw new HttpsError('permission-denied', 'This TV is not paired.');
  if (!(await exists(`users/${owner}/members/${auth.uid}`))) throw new HttpsError('permission-denied', 'This TV is not paired.');
  return owner;
}

/** Counts `calls` against the household's daily allowance. */
async function spend(owner, calls) {
  const day = new Date().toISOString().slice(0, 10);
  const ref = db.doc(`aiUsage/${owner}`);
  await db.runTransaction(async t => {
    const d = (await t.get(ref)).data() || {};
    const used = d.day === day ? (d.calls || 0) : 0;
    if (used + calls > DAILY_LIMIT) throw new HttpsError('resource-exhausted', 'Daily AI limit reached.');
    t.set(ref, { day, calls: used + calls, updatedAt: FieldValue.serverTimestamp() });
  });
}

const useMock = () => OLLAMA_API_KEY.value() === 'mock';

async function ollama(path, body) {
  const res = await fetch(`${OLLAMA}${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${OLLAMA_API_KEY.value()}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(25000)
  });
  if (!res.ok) {
    logger.warn('ollama error', { path, status: res.status, body: (await res.text()).slice(0, 300) });
    throw new HttpsError('unavailable', `AI service returned ${res.status}.`);
  }
  return res.json();
}

/** Clef decision: { state, images?, questions } -> answers keyed by question name. */
async function decide(state, questions, images) {
  const body = { model: DECISION_MODEL, state, questions, ...(images?.length ? { images } : {}) };
  const out = useMock() ? mockDecision(body) : await ollama('/v1/systemone', body);
  return out.answers || {};
}

async function chat(messages) {
  if (useMock()) return mockChat(messages);
  const out = await ollama('/api/chat', { model: CHAT_MODEL, messages, stream: false });
  return out.message?.content || '';
}

const str = (v, max) => typeof v === 'string' && v.length > 0 && v.length <= max;
const round = n => Math.round(n * 1000) / 1000;

/** Base64 JPEG/PNG/WebP, at most ~1 MB decoded (frames are sent downscaled). */
function checkImage(b64) {
  if (!str(b64, 1_500_000) || !/^[A-Za-z0-9+/=]+$/.test(b64)) return false;
  const head = Buffer.from(b64.slice(0, 16), 'base64');
  return (head[0] === 0xff && head[1] === 0xd8) // JPEG
    || (head[0] === 0x89 && head[1] === 0x50) // PNG
    || head.subarray(8, 12).toString() === 'WEBP';
}

// ------------------------------------------------------------------ frameCheck

const SCENE = 'Normal scene from the programme: people, action, dialogue, scenery or sport, including any on-screen '
  + 'captions, subtitles, news tickers or name graphics';
const FRAME_TASKS = {
  // Near the end of an episode/film: have the end credits started?
  credits: {
    state: 'A frame captured near the end of a TV episode or film, to decide whether the end credits have started.',
    criteria: {
      programme: SCENE,
      end_credits: 'End credits: names of cast and crew, scrolling or on cards, often over black, a still image or a side panel',
      next_preview: 'A "next time on" or "coming up" preview of another episode',
      logo_or_black: 'A studio or channel logo, a black frame, or a fade between scenes'
    }
  },
  // Start of an episode: are we inside the opening titles?
  intro: {
    state: 'A frame captured in the first minutes of a TV episode, to find where the opening title sequence is.',
    criteria: {
      programme: SCENE,
      intro: 'The show\'s own opening title sequence: its stylised title or logo card, or an opening montage with cast '
        + 'credits over theme visuals. Not a news ticker, captions, or a scene with text on it',
      recap: 'A "previously on" recap of earlier episodes',
      logo_or_black: 'A studio or channel logo, a black frame, or a fade between scenes'
    }
  },
  // The intro question with a second image: a normal scene from this episode to compare against. Opening
  // montages rarely look like the show's own sets and cast, which a single frame can't show (on real
  // episodes: 0.2–0.5 alone, 0.86–0.95 compared). Credits are clear on their own; a reference only blurred them.
  introRef: {
    state: 'Image 1 is a frame from the first minutes of a TV episode. Image 2 is a normal scene from the same '
      + 'episode, for reference. Decide whether image 1 is part of the opening title sequence.',
    criteria: {
      programme: 'Image 1 is a scene of the show like image 2: its usual sets, cast and look (captions, a new room '
        + 'or a close-up within the story count too)',
      intro: 'Image 1 looks unlike the show\'s scenes: a stylised opening montage (archival or historical photos, '
        + 'animation, space, graphics, timelines), the show\'s title or logo, or opening credits over theme visuals',
      recap: 'A "previously on" recap of earlier episodes',
      logo_or_black: 'A studio or channel logo, a black frame, or a fade between scenes'
    }
  },
  // Live channel health: two frames ~3 s apart.
  live: {
    state: 'Two frames from a live TV channel, captured about 3 seconds apart, to check the channel is really broadcasting.',
    criteria: {
      ok: 'A normal live broadcast: programme, sport, news or adverts (the two frames may look alike if the shot is static)',
      black: 'A black or blank screen',
      frozen: 'The picture is stuck: the two frames are pixel-for-pixel the same mid-programme',
      offline: 'An error card, "channel unavailable", "no signal", a colour-bar test pattern or a placeholder logo screen'
    }
  },
  // Live channel whose two frames came out byte-identical: stuck, or a screen that is meant to be still?
  liveStill: {
    state: 'Two frames from a live TV channel, captured about 3 seconds apart, came out exactly identical: the picture '
      + 'has not changed at all. Decide whether the channel is stuck.',
    criteria: {
      ok: 'A screen meant to be still: a radio or music station graphic, an information slide, a menu or programme guide',
      black: 'A black or blank screen',
      frozen: 'A programme stopped mid-motion: people, sport, presenters, scenery or action frozen in place',
      offline: 'An error card, "channel unavailable", "no signal", a colour-bar test pattern or a placeholder logo screen'
    }
  }
};

export const frameCheck = onCall(options, async request => {
  const owner = await household(request);
  const name = request.data?.task;
  let task = ['intro', 'credits', 'live'].includes(name) ? FRAME_TASKS[name] : null;
  let images = request.data?.images;
  if (!task) throw new HttpsError('invalid-argument', 'Unknown task.');
  if (!Array.isArray(images) || images.length < 1 || images.length > 2 || !images.every(checkImage)) {
    throw new HttpsError('invalid-argument', 'Send one or two JPEG/PNG frames.');
  }
  if (task === FRAME_TASKS.live && images.length === 2 && images[0] === images[1]) {
    task = FRAME_TASKS.liveStill; // nothing moved: one frame and a sharper question
    images = [images[0]];
  } else if (images.length === 2 && name === 'intro') {
    task = FRAME_TASKS.introRef; // second image = a normal scene from the same episode
  }
  const title = str(request.data?.title, 200) ? ` Title: ${request.data.title}.` : '';
  await spend(owner, 1);
  const answers = await decide(task.state + title, {
    screen: { type: 'choice', instructions: 'What is on screen?', criteria: task.criteria }
  }, images);
  const a = answers.screen || {};
  const probabilities = a.probabilities || {};
  // Verdicts only (never the frame), for tuning the thresholds the apps use.
  logger.info('frameCheck verdict', {
    task: request.data.task, title: request.data?.title, label: a.choice || null,
    confidence: round(a.confidence ?? 0),
    p: Object.fromEntries(Object.entries(probabilities).map(([k, v]) => [k, round(v)])),
    frames: images.length, bytes: images.reduce((n, b) => n + Math.round(b.length * 0.75), 0)
  });
  return { label: a.choice || null, confidence: a.confidence ?? 0, probabilities };
});

// ------------------------------------------------------------------ classifyCategories

const MAX_CATEGORIES = 16; // 4 questions each, 64 per request

export const classifyCategories = onCall(options, async request => {
  const owner = await household(request);
  const lineId = String(request.data?.lineId || '');
  const cats = request.data?.categories;
  if (!/^[\w-]{1,60}$/.test(lineId)) throw new HttpsError('invalid-argument', 'Bad line.');
  if (!Array.isArray(cats) || !cats.length || cats.length > MAX_CATEGORIES
      || !cats.every(c => str(String(c?.id ?? ''), 40) && str(c?.name, 120) && ['live', 'movie', 'series'].includes(c?.kind))) {
    throw new HttpsError('invalid-argument', `Send 1-${MAX_CATEGORIES} categories {id, name, kind}.`);
  }
  if (!(await exists(`users/${owner}/lines/${lineId}`))) throw new HttpsError('not-found', 'Unknown line.');
  await spend(owner, 1);

  const state = 'Categories from an IPTV provider (live channels, movies and series). Names often start with a country '
    + 'or language code (EN, UK, US, IN, HI, AR, FR...) or a service prefix (D+ = Disney+, NF = Netflix, A+ = Apple TV+).\n'
    + cats.map((c, i) => `${i}. [${c.kind}] ${c.name}`).join('\n');
  const questions = {};
  cats.forEach((c, i) => {
    const which = `category ${i} ("${c.name}")`;
    questions[`kids_${i}`] = {
      type: 'noul',
      instructions: `Is ${which} suitable for a child under 12 to browse alone?`,
      criteria: {
        false: 'Adult, violent, horror, crime, news or otherwise mature content, or unclear',
        true: 'Kids, cartoons, family or educational content that suits young children'
      }
    };
    questions[`adult_${i}`] = {
      type: 'noul',
      instructions: `Is ${which} pornographic or sexually explicit (XXX / 18+) content?`,
      criteria: {
        false: 'Not sexually explicit. Mature comedy or animation for grown-ups (e.g. "Adult Swim"), drama, horror and violence are not this',
        true: 'Pornographic, XXX or 18+ sexually explicit content'
      }
    };
    questions[`lang_${i}`] = { type: 'choice', instructions: `Which language is ${which} in?`, criteria: LANGUAGES };
    questions[`genre_${i}`] = { type: 'choice', instructions: `Which genre best describes ${which}?`, criteria: GENRES };
  });
  const answers = await decide(state, questions);

  const tags = {};
  cats.forEach((c, i) => {
    tags[`${c.kind}:${c.id}`] = {
      kids: round(answers[`kids_${i}`]?.noul ?? 0),
      adult: round(answers[`adult_${i}`]?.noul ?? 0),
      lang: answers[`lang_${i}`]?.choice || 'other',
      genre: answers[`genre_${i}`]?.choice || 'mixed'
    };
  });
  await db.doc(`users/${owner}/lineTags/${lineId}`).set({ cats: tags, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  return { tags };
});

// ------------------------------------------------------------------ kidsTitles

const MAX_TITLES = 40;
// Scores are spread over KIDS_SHARDS documents per line, users/{owner}/kidsTitles/{lineId}_{id % KIDS_SHARDS}: a
// batch rewrites (and every listening device re-downloads) one small shard instead of one ever-growing document,
// and the 1 MiB document limit stops mattering. The apps send each batch from a single shard.
export const KIDS_SHARDS = 8;

/**
 * Rates titles for kids profiles: 0-1, how suitable each is for a child under 12 to watch alone. The apps only
 * show a kids profile titles scored at least 0.6, on top of their deterministic rules, so unknown titles stay
 * hidden. Scores are shared by the household's kids profiles (see KIDS_SHARDS).
 */
export const kidsTitles = onCall(options, async request => {
  const owner = await household(request);
  const lineId = String(request.data?.lineId || '');
  const items = request.data?.items;
  if (!/^[\w-]{1,60}$/.test(lineId)) throw new HttpsError('invalid-argument', 'Bad line.');
  if (!Array.isArray(items) || !items.length || items.length > MAX_TITLES
      || !items.every(t => /^\d{1,12}$/.test(String(t?.id ?? '')) && str(t?.title, 160) && ['live', 'movie', 'series'].includes(t?.kind))) {
    throw new HttpsError('invalid-argument', `Send 1-${MAX_TITLES} titles {kind, id, title}.`);
  }
  if (!(await exists(`users/${owner}/lines/${lineId}`))) throw new HttpsError('not-found', 'Unknown line.');
  await spend(owner, 1);

  const state = 'Titles from an IPTV catalog: movies, TV series and live TV channels. Names may carry a country or '
    + 'language prefix (EN, UK, IN...), a year or quality tags (HD, 4K).\n'
    + items.map((t, i) => `${i}. [${t.kind}] ${t.title}`).join('\n');
  const questions = {};
  items.forEach((t, i) => {
    questions[`title_${i}`] = {
      type: 'noul',
      instructions: `Is title ${i} ("${t.title}") suitable for a child under 12 to watch alone?`,
      criteria: {
        false: 'Made for adults or teens: sexual content, strong violence, horror, crude adult humour (e.g. adult animation), '
          + 'mature news or talk, or a title you don\'t recognise',
        true: 'Made for children or the whole family; a typical parent would let a young child watch it'
      }
    };
  });
  const answers = await decide(state, questions);

  const scores = {};
  const shards = {};
  items.forEach((t, i) => {
    const key = `${t.kind}:${t.id}`;
    scores[key] = round(answers[`title_${i}`]?.noul ?? 0);
    const shard = Number(t.id) % KIDS_SHARDS;
    (shards[shard] = shards[shard] || {})[key] = scores[key];
  });
  const batch = db.batch();
  for (const [shard, titles] of Object.entries(shards)) {
    batch.set(db.doc(`users/${owner}/kidsTitles/${lineId}_${shard}`), { titles, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
  }
  await batch.commit();
  return { scores };
});

// ------------------------------------------------------------------ smartSearch

const KINDS = ['movie', 'series', 'live', 'any'];
const SORTS = ['relevance', 'newest', 'rating'];

export const smartSearch = onCall(options, async request => {
  const owner = await household(request);
  const query = String(request.data?.query || '').trim();
  if (query.length < 2 || query.length > 200) throw new HttpsError('invalid-argument', 'Search for 2-200 characters.');
  await spend(owner, 1);

  const system = 'You turn a viewer\'s request into filters for an IPTV catalog search. Reply with ONLY a JSON object:\n'
    + '{"kind":"movie|series|live|any","keywords":["..."],"genres":["..."],"languages":["..."],'
    + '"yearFrom":2010,"yearTo":2019,"sort":"relevance|newest|rating"}\n'
    + `genres: zero or more of ${Object.keys(GENRES).join(', ')}.\n`
    + `languages: zero or more codes of ${Object.keys(LANGUAGES).filter(k => k !== 'multi' && k !== 'other').join(', ')}.\n`
    + 'keywords: title words or people worth matching, lowercase; never genre or language words. '
    + 'Use null for years that aren\'t asked for. "Recent"/"new" means sort newest.';
  const reply = await chat([{ role: 'system', content: system }, { role: 'user', content: query }]);

  let parsed = {};
  try { parsed = JSON.parse((reply.match(/\{[\s\S]*\}/) || ['{}'])[0]); } catch (e) { parsed = {}; }
  const list = (v, allowed, max) => (Array.isArray(v) ? v : [])
    .map(x => String(x).toLowerCase().trim()).filter(x => x && (!allowed || allowed.includes(x))).slice(0, max);
  const year = v => (Number.isInteger(v) && v >= 1900 && v <= 2100 ? v : null);
  return {
    kind: KINDS.includes(parsed.kind) ? parsed.kind : 'any',
    keywords: list(parsed.keywords, null, 6).map(k => k.slice(0, 40)),
    genres: list(parsed.genres, Object.keys(GENRES), 4),
    languages: list(parsed.languages, Object.keys(LANGUAGES), 4),
    yearFrom: year(parsed.yearFrom),
    yearTo: year(parsed.yearTo),
    sort: SORTS.includes(parsed.sort) ? parsed.sort : 'relevance'
  };
});

// ------------------------------------------------------------------ xray

// X-Ray (who is on screen, as on Prime Video). The title's cast comes from TMDB; the people in the current frame
// are found by face matching (faces.js) against the cast's TMDB photos. Vision LLMs were tried for this and named
// the film's stars instead of who was on screen (Gemma 5/16, Clef ~6/16 labelled frames, face matching 16/16), so
// the AI models only write the trivia. Results are cached in functions-only collections shared by all households
// (it is public film data): titles and cast for 30 days, each actor's face embedding, and what was found in each
// 10-second stretch of a title, so a scene is analysed once. Frames themselves are never stored.

const TMDB_API_KEY = defineSecret('TMDB_API_KEY');
// The emulator tests point these at a fake TMDB (see test/functions.test.js).
const TMDB = process.env.TMDB_API || 'https://api.themoviedb.org/3';
const TMDB_IMG = process.env.TMDB_IMG || 'https://image.tmdb.org/t/p';
const WIKI_AGENT = 'NucFlix/1.0 (https://github.com/pri-te-sh/NUCFLIX)';
const XRAY_FRESH = 30 * 86400 * 1000;
const SCENE_SECONDS = 10;
const MATCH_CAST = 30; // a face is compared with the first 30 billed cast members who have a photo
// SFace cosine scores (OpenCV calls 0.363 the same person). On labelled frames, faces of people missing from the
// cast list scored up to 0.31 but then never more than 0.07 above the next actor, so weaker matches need a lead.
const MATCH_SURE = 0.36, MATCH_MIN = 0.25, MATCH_LEAD = 0.08;

const xrayOptions = { ...options, secrets: [OLLAMA_API_KEY, TMDB_API_KEY], memory: '1GiB' };

async function tmdb(path, params = {}) {
  const key = TMDB_API_KEY.value();
  const url = new URL(TMDB + path);
  for (const [k, v] of Object.entries(params)) if (v != null && v !== '') url.searchParams.set(k, String(v));
  const headers = { Accept: 'application/json' };
  if (key.startsWith('eyJ')) headers.Authorization = `Bearer ${key}`; // a v4 read access token
  else url.searchParams.set('api_key', key);
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(10000) });
  if (res.status === 404) return null;
  if (!res.ok) {
    logger.warn('tmdb error', { path, status: res.status });
    throw new HttpsError('unavailable', `TMDB returned ${res.status}.`);
  }
  return res.json();
}

const imageURL = (size, path) => (path ? `${TMDB_IMG}/${size}${path}` : '');
const yearOf = date => (String(date || '').match(/^\d{4}/) || [''])[0];
const fresh = snap => snap.exists && Date.now() - (snap.get('at') || 0) < XRAY_FRESH;
const castMember = c => ({ id: c.id, name: String(c.name || ''), character: String(c.character || ''), photo: c.profile_path || '' });

/** The TMDB movie or show an IPTV title is ({ type, id }), from the provider's TMDB id or a search; null if none. */
async function findTitle(kind, title, year, tmdbId) {
  const type = kind === 'movie' ? 'movie' : 'tv';
  if (tmdbId) return { type, id: Number(tmdbId) };
  const name = title.replace(/\s*[([]?\b(19|20)\d{2}\b[)\]]?\s*$/, '').trim() || title;
  const key = createHash('sha1').update(`${type}|${name.toLowerCase()}|${year || ''}`).digest('hex');
  const ref = db.doc(`xrayLookups/${key}`);
  const snap = await ref.get();
  if (fresh(snap)) return snap.get('id') ? { type, id: snap.get('id') } : null;
  const search = y => tmdb(`/search/${type}`, { query: name, include_adult: 'false', [type === 'movie' ? 'year' : 'first_air_date_year']: y });
  let res = year ? await search(year) : null;
  if (!res?.results?.length) res = await search(null);
  const hit = res?.results?.[0];
  await ref.set({ id: hit ? hit.id : null, at: Date.now() });
  return hit ? { type, id: hit.id } : null;
}

/** A title's details and cast (for an episode: its own cast, guest stars included), cached. */
async function loadTitle(ref, season, episode) {
  const episodeKey = ref.type === 'tv' && season != null && episode != null ? `_s${season}e${episode}` : '';
  const docId = `${ref.type}_${ref.id}${episodeKey}`;
  const doc = db.doc(`xrayTitles/${docId}`);
  const snap = await doc.get();
  if (fresh(snap)) return { docId, ...snap.data() };
  const info = await tmdb(`/${ref.type}/${ref.id}`, {
    append_to_response: ref.type === 'movie' ? 'credits,external_ids' : 'aggregate_credits,external_ids'
  });
  if (!info) return null;
  let cast = [];
  if (ref.type === 'movie') {
    cast = (info.credits?.cast || []).map(castMember);
  } else {
    const ep = episodeKey ? await tmdb(`/tv/${ref.id}/season/${season}/episode/${episode}/credits`).catch(() => null) : null;
    if (ep) cast = [...(ep.cast || []), ...(ep.guest_stars || [])].map(castMember);
    if (!cast.length) {
      cast = (info.aggregate_credits?.cast || []).map(c => castMember({
        ...c, character: (c.roles || []).map(r => r.character).filter(Boolean).slice(0, 2).join(' / ')
      }));
    }
  }
  const ids = new Set();
  const data = {
    type: ref.type, id: ref.id,
    name: String(info.title || info.name || ''),
    year: yearOf(info.release_date || info.first_air_date),
    overview: String(info.overview || '').slice(0, 800),
    wikidata: info.external_ids?.wikidata_id || '',
    cast: cast.filter(c => c.name && !ids.has(c.id) && ids.add(c.id)).slice(0, 60),
    at: Date.now()
  };
  await doc.set(data);
  return { docId, ...data };
}

/** Face embeddings of the first billed cast members, from their TMDB photos (worked out once per photo). */
async function castFaces(cast, facesIn) {
  const people = cast.filter(c => c.photo).slice(0, MATCH_CAST);
  if (!people.length) return new Map();
  const snaps = await db.getAll(...people.map(c => db.doc(`xrayFaces/${c.id}`)));
  const out = new Map();
  const todo = [];
  snaps.forEach((s, i) => {
    const c = people[i];
    if (s.exists && s.get('photo') === c.photo) {
      if (s.get('embedding')) out.set(c.id, s.get('embedding'));
    } else todo.push(c);
  });
  for (let i = 0; i < todo.length; i += 4) {
    await Promise.all(todo.slice(i, i + 4).map(async c => {
      let embedding = null;
      try {
        const res = await fetch(imageURL('h632', c.photo), { signal: AbortSignal.timeout(10000) });
        if (!res.ok) return; // not cached: tried again next time
        const face = (await facesIn(Buffer.from(await res.arrayBuffer())))[0]; // biggest face in the photo
        embedding = face ? face.embedding.map(x => Math.round(x * 1e5) / 1e5) : null;
      } catch (e) {
        logger.warn('xray photo', { person: c.id, error: String(e) });
        return;
      }
      if (embedding) out.set(c.id, embedding);
      await db.doc(`xrayFaces/${c.id}`).set({ photo: c.photo, embedding, at: Date.now() });
    }));
  }
  return out;
}

/** Cast members whose faces are in the frame: [{ id, score }], one face each, best first. */
function matchFaces(faces, refs, similarityOf) {
  const found = [];
  for (const f of faces) {
    const [best, next] = [...refs].map(([id, e]) => ({ id, score: similarityOf(f.embedding, e) })).sort((a, b) => b.score - a.score);
    if (!best) continue;
    const lead = best.score - (next ? next.score : 0);
    if (best.score >= MATCH_SURE || (best.score >= MATCH_MIN && lead >= MATCH_LEAD)) found.push(best);
  }
  const seen = new Set();
  return found.sort((a, b) => b.score - a.score)
    .filter(p => !seen.has(p.id) && seen.add(p.id))
    .map(p => ({ id: p.id, score: round(p.score) }));
}

const intIn = (v, min, max) => Number.isInteger(v) && v >= min && v <= max;

async function xrayScene(owner, d) {
  if (!['movie', 'episode'].includes(d.kind) || !str(d.title, 200)) throw new HttpsError('invalid-argument', 'Send kind and title.');
  if (d.year != null && !/^\d{4}$/.test(String(d.year))) throw new HttpsError('invalid-argument', 'Bad year.');
  if (d.tmdbId != null && !/^\d{1,9}$/.test(String(d.tmdbId))) throw new HttpsError('invalid-argument', 'Bad TMDB id.');
  if (d.kind === 'episode' && !(intIn(d.season, 0, 999) && intIn(d.episode, 0, 9999))) throw new HttpsError('invalid-argument', 'Send season and episode.');
  if (typeof d.position !== 'number' || !(d.position >= 0 && d.position < 1e6)) throw new HttpsError('invalid-argument', 'Bad position.');
  if (d.image != null && !checkImage(d.image)) throw new HttpsError('invalid-argument', 'Send one JPEG/PNG frame.');
  const season = d.kind === 'episode' ? d.season : null, episode = d.kind === 'episode' ? d.episode : null;

  let t = null;
  const ref = await findTitle(d.kind, d.title, d.year, d.tmdbId);
  if (ref) t = await loadTitle(ref, season, episode);
  if (!t && d.tmdbId) { // a provider's TMDB id can be wrong (or for the other type): search instead
    const searched = await findTitle(d.kind, d.title, d.year, null);
    if (searched) t = await loadTitle(searched, season, episode);
  }
  if (!t) return { found: false };

  const sceneRef = db.doc(`xrayScenes/${t.docId}_${Math.floor(d.position / SCENE_SECONDS)}`);
  const snap = await sceneRef.get();
  let scene = fresh(snap) ? snap.data() : null;
  if (!scene && d.image && t.cast.some(c => c.photo)) {
    await spend(owner, 1);
    const { facesIn, similarityOf } = await import('./faces.js'); // onnxruntime loads only where X-Ray runs
    const faces = await facesIn(Buffer.from(d.image, 'base64'));
    const people = faces.length ? matchFaces(faces, await castFaces(t.cast, facesIn), similarityOf) : [];
    scene = { people, faces: faces.length, at: Date.now() };
    await sceneRef.set(scene);
    logger.info('xray scene', { title: t.name, docId: t.docId, position: Math.round(d.position), faces: faces.length, scores: people.map(p => p.score) });
  }
  const byId = new Map(t.cast.map(c => [c.id, c]));
  const person = c => ({ id: c.id, name: c.name, character: c.character, photo: imageURL('w185', c.photo) });
  return {
    found: true,
    title: { type: t.type, id: t.id, name: t.name, year: t.year, overview: t.overview, trivia: !!t.wikidata },
    scene: scene ? scene.people.filter(p => byId.has(p.id)).map(p => ({ ...person(byId.get(p.id)), score: p.score })) : null,
    faces: scene ? scene.faces : 0,
    cast: t.cast.slice(0, 40).map(person)
  };
}

async function xrayPerson(d) {
  const id = String(d.personId ?? '');
  if (!/^\d{1,10}$/.test(id)) throw new HttpsError('invalid-argument', 'Bad person.');
  const ref = db.doc(`xrayPeople/${id}`);
  const snap = await ref.get();
  let p = fresh(snap) ? snap.data() : null;
  if (!p) {
    const info = await tmdb(`/person/${id}`, { append_to_response: 'combined_credits' });
    if (!info) throw new HttpsError('not-found', 'Unknown person.');
    const seen = new Set();
    const credits = (info.combined_credits?.cast || [])
      // Talk shows, news and award shows (appearances "as Self") aren't what a viewer means by other titles.
      .filter(c => !(c.genre_ids || []).some(g => g === 10767 || g === 10763) && !/^(self|himself|herself|themselves)\b/i.test(c.character || ''))
      .sort((a, b) => (b.vote_count || 0) - (a.vote_count || 0))
      .filter(c => !seen.has(`${c.media_type}${c.id}`) && seen.add(`${c.media_type}${c.id}`))
      .slice(0, 12)
      .map(c => ({ title: String(c.title || c.name || ''), year: yearOf(c.release_date || c.first_air_date), character: String(c.character || ''), type: c.media_type, poster: c.poster_path || '' }));
    p = {
      id: info.id, name: String(info.name || ''), bio: String(info.biography || '').slice(0, 1500),
      born: info.birthday || '', died: info.deathday || '', place: String(info.place_of_birth || ''),
      photo: info.profile_path || '', credits, at: Date.now()
    };
    await ref.set(p);
  }
  const { at, ...rest } = p;
  return { ...rest, photo: imageURL('h632', p.photo), credits: p.credits.map(c => ({ ...c, poster: imageURL('w185', c.poster) })) };
}

/** The title's English Wikipedia article, without the plot (trivia must not spoil it), or ''. */
async function wikiArticle(wikidataId) {
  const get = async url => {
    const res = await fetch(url, { headers: { 'User-Agent': WIKI_AGENT }, signal: AbortSignal.timeout(10000) });
    return res.ok ? res.json() : null;
  };
  const entity = await get(`https://www.wikidata.org/wiki/Special:EntityData/${wikidataId}.json`);
  const page = entity?.entities?.[wikidataId]?.sitelinks?.enwiki?.title;
  if (!page) return '';
  const res = await get(`https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&redirects=1&format=json&titles=${encodeURIComponent(page)}`);
  const text = String(Object.values(res?.query?.pages || {})[0]?.extract || '');
  const parts = text.split(/\n==+ *([^=\n]+?) *==+\n/); // [intro, heading, body, heading, body...]
  let out = parts[0];
  for (let i = 1; i < parts.length; i += 2) {
    if (/production|development|pre-production|casting|filming|photography|music|soundtrack|score|writing|design|effects|release|reception|legacy|background|accolades/i.test(parts[i])) {
      out += `\n\n${parts[i]}\n${parts[i + 1] || ''}`;
    }
  }
  return out.slice(0, 14000);
}

async function xrayTrivia(owner, d) {
  if (!['movie', 'tv'].includes(d.type) || !/^\d{1,9}$/.test(String(d.id ?? ''))) throw new HttpsError('invalid-argument', 'Bad title.');
  const ref = db.doc(`xrayTrivia/${d.type}_${d.id}`);
  const snap = await ref.get();
  if (fresh(snap)) return { facts: snap.get('facts') || [] };
  const t = await loadTitle({ type: d.type, id: Number(d.id) });
  let facts = [];
  const article = t?.wikidata ? await wikiArticle(t.wikidata).catch(() => '') : '';
  if (article.length > 400) {
    await spend(owner, 1);
    const system = 'You write X-Ray trivia for a video player, like Prime Video\'s. From the Wikipedia article the user '
      + 'gives, pick up to 5 short, surprising facts about how the title was made: casting, filming, music, production, '
      + 'reception. Use only facts stated in the article. Never reveal the plot or the ending. Each fact is one or two '
      + 'sentences, under 220 characters. Reply with ONLY a JSON array of strings.';
    const reply = await chat([{ role: 'system', content: system }, { role: 'user', content: `Title: ${t.name} (${t.year})\n\n${article}` }]);
    try {
      const list = JSON.parse((reply.match(/\[[\s\S]*\]/) || ['[]'])[0]);
      facts = (Array.isArray(list) ? list : []).filter(f => str(f, 300)).slice(0, 6);
    } catch (e) { facts = []; }
  }
  await ref.set({ facts, at: Date.now() });
  return { facts };
}

/**
 * X-Ray for the player. action 'scene' (default): who is on screen in a movie or episode frame, with the title's
 * cast to fall back on ({ found, title, scene: [...] | null, faces, cast }); 'person': an actor's bio and best-known
 * titles; 'trivia': a few behind-the-scenes facts drawn from the title's Wikipedia article.
 */
export const xray = onCall(xrayOptions, async request => {
  const owner = await household(request);
  const d = request.data || {};
  if (d.action === 'person') return xrayPerson(d);
  if (d.action === 'trivia') return xrayTrivia(owner, d);
  return xrayScene(owner, d);
});
