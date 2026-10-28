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

/** Returns the household (owner uid) the caller belongs to, or throws. */
async function household(request) {
  const auth = request.auth;
  if (!auth) throw new HttpsError('unauthenticated', 'Sign in to NucFlix first.');
  if (auth.token.firebase?.sign_in_provider !== 'anonymous') return auth.uid;
  const owner = String(request.data?.ownerUid || '');
  if (!/^[\w-]{1,128}$/.test(owner)) throw new HttpsError('permission-denied', 'This TV is not paired.');
  const member = await db.doc(`users/${owner}/members/${auth.uid}`).get();
  if (!member.exists) throw new HttpsError('permission-denied', 'This TV is not paired.');
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
  let task = request.data?.task === 'liveStill' ? null : FRAME_TASKS[request.data?.task];
  let images = request.data?.images;
  if (!task) throw new HttpsError('invalid-argument', 'Unknown task.');
  if (!Array.isArray(images) || images.length < 1 || images.length > 2 || !images.every(checkImage)) {
    throw new HttpsError('invalid-argument', 'Send one or two JPEG/PNG frames.');
  }
  if (task === FRAME_TASKS.live && images.length === 2 && images[0] === images[1]) {
    task = FRAME_TASKS.liveStill; // nothing moved: one frame and a sharper question
    images = [images[0]];
  }
  const title = str(request.data?.title, 200) ? ` Title: ${request.data.title}.` : '';
  await spend(owner, 1);
  const answers = await decide(task.state + title, {
    screen: { type: 'choice', instructions: 'What is on screen?', criteria: task.criteria }
  }, images);
  const a = answers.screen || {};
  return { label: a.choice || null, confidence: a.confidence ?? 0, probabilities: a.probabilities || {} };
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
  if (!(await db.doc(`users/${owner}/lines/${lineId}`).get()).exists) throw new HttpsError('not-found', 'Unknown line.');
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
