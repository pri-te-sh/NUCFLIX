// Deterministic stand-ins for Ollama, used only in the local emulator (OLLAMA_API_KEY=mock).
// Frame answers come from functions/.mock-frames.json ({"credits": "end_credits", "intro": "intro",
// "live": "black"}), re-read on every call so a test can flip them while an app is running.

import { existsSync, readFileSync } from 'node:fs';

const framesFile = new URL('./.mock-frames.json', import.meta.url);

function frameAnswer(state) {
  const task = /end credits/i.test(state) ? 'credits' : /opening title/i.test(state) ? 'intro' : 'live';
  let wanted = {};
  try { if (existsSync(framesFile)) wanted = JSON.parse(readFileSync(framesFile, 'utf8')); } catch (e) { wanted = {}; }
  return wanted[task] || (task === 'live' ? 'ok' : 'programme');
}

const LANG_PREFIX = {
  en: 'en', uk: 'en', us: 'en', gb: 'en', ca: 'en', au: 'en', in: 'hi', hi: 'hi', ta: 'ta', te: 'te', ml: 'ml',
  mr: 'mr', bn: 'bn', pk: 'ur', ar: 'ar', es: 'es', fr: 'fr', de: 'de', it: 'it', pt: 'pt', br: 'pt', tr: 'tr', ru: 'ru'
};

const GENRE_WORDS = [
  ['kids', /kid|cartoon|junior|animation|anime|disney/i], ['sports', /sport|cricket|football|soccer|nba|nfl|f1|ufc|tennis/i],
  ['news', /news/i], ['comedy', /comedy|funny|sitcom/i], ['horror', /horror/i], ['action', /action|adventure/i],
  ['documentary', /docu|discovery|nat ?geo|history/i], ['music', /music|mtv/i], ['religious', /relig|devotion|bhakti/i],
  ['adult', /adult|xxx|18\+/i], ['romance', /romance|romantic/i], ['thriller', /thriller|mystery/i], ['drama', /drama/i]
];

function categoryAnswers(body) {
  const answers = {};
  const names = Object.fromEntries(
    body.state.split('\n').map(l => l.match(/^(\d+)\. \[\w+\] (.*)$/)).filter(Boolean).map(m => [m[1], m[2]])
  );
  for (const [key, q] of Object.entries(body.questions)) {
    const [kind, i] = key.split('_');
    const name = names[i] || '';
    if (kind === 'kids') answers[key] = { type: 'noul', noul: /kid|cartoon|junior|family|disney|anime/i.test(name) ? 0.93 : 0.07 };
    else if (kind === 'adult') answers[key] = { type: 'noul', noul: /adult|xxx|18\+/i.test(name) ? 0.97 : 0.02 };
    else if (kind === 'lang') {
      const prefix = (name.match(/^([A-Za-z]{2,3})\b/) || [])[1]?.toLowerCase();
      answers[key] = { type: 'choice', choice: LANG_PREFIX[prefix] || 'other', confidence: 0.8 };
    } else if (kind === 'genre') {
      answers[key] = { type: 'choice', choice: (GENRE_WORDS.find(([, re]) => re.test(name)) || ['mixed'])[0], confidence: 0.7 };
    } else answers[key] = { type: q.type };
  }
  return answers;
}

export function mockDecision(body) {
  if (body.questions.screen) {
    const choice = frameAnswer(body.state);
    const probabilities = Object.fromEntries(Object.keys(body.questions.screen.criteria).map(k => [k, k === choice ? 0.94 : 0.02]));
    return { model: 'mock', answers: { screen: { type: 'choice', choice, probabilities, confidence: 0.9 } } };
  }
  return { model: 'mock', answers: categoryAnswers(body) };
}

export function mockChat(messages) {
  const q = messages[messages.length - 1].content.toLowerCase();
  const years = (q.match(/\b(19|20)\d{2}\b/g) || []).map(Number);
  const decade = q.match(/\b(19|20)(\d)0s\b/);
  const genres = GENRE_WORDS.filter(([, re]) => re.test(q)).map(([g]) => g);
  const languages = [['hi', /hindi|bollywood/], ['en', /english/], ['ta', /tamil/], ['te', /telugu/], ['es', /spanish/]]
    .filter(([, re]) => re.test(q)).map(([l]) => l);
  const kind = /\bshows?\b|series/.test(q) ? 'series' : /movies?|films?/.test(q) ? 'movie' : /channel|live/.test(q) ? 'live' : 'any';
  const stop = /\b(movies?|films?|shows?|series|channels?|live|funny|comedy|hindi|english|tamil|telugu|spanish|from|the|with|in|and|of|a|an|some|recent|new|latest|\d{4}s?|19\d0s|20\d0s|action|horror|kids|sports|news|drama|romance|thriller|documentary|music)\b/g;
  const keywords = q.replace(stop, ' ').split(/\s+/).filter(w => w.length > 2).slice(0, 4);
  return JSON.stringify({
    kind, keywords, genres, languages,
    yearFrom: decade ? Number(decade[1] + decade[2] + '0') : (years[0] ?? null),
    yearTo: decade ? Number(decade[1] + decade[2] + '9') : (years[1] ?? years[0] ?? null),
    sort: /recent|new|latest/.test(q) ? 'newest' : 'relevance'
  });
}
