// A tiny stand-in for the TMDB API and image server, for the X-Ray emulator tests. The functions emulator is
// pointed at it with TMDB_API / TMDB_IMG (see the test:functions script). One film (Charade, 1963) and one
// show whose episode S1E2 has a guest star; cast photos are frames from the film (test/fixtures/xray).
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';

const fixture = name => readFileSync(new URL(`./fixtures/xray/${name}`, import.meta.url));
const person = (id, name, character, photo) => ({ id, name, character, profile_path: photo ? `/${photo}.jpg` : null });
const GRANT = person(2638, 'Cary Grant', 'Peter Joshua', 'grant');
const HEPBURN = person(1932, 'Audrey Hepburn', 'Regina Lampert', 'hepburn');
const MATTHAU = person(6837, 'Walter Matthau', 'Hamilton Bartholomew', 'matthau');
const MARIN = person(24501, 'Jacques Marin', 'Insp. Edouard Grandpierre', 'marin');
const GLASS = person(13786, 'Ned Glass', 'Leopold W. Gideon', null);

const routes = {
  '/3/search/movie': q => ({ results: /charade/i.test(q.get('query')) && (!q.get('year') || q.get('year') === '1963') ? [{ id: 4808 }] : [] }),
  '/3/movie/4808': () => ({
    title: 'Charade', release_date: '1963-12-05', overview: 'Romance and suspense in Paris.',
    credits: { cast: [GRANT, HEPBURN, MATTHAU, GLASS, MARIN] }, external_ids: { wikidata_id: null }
  }),
  '/3/search/tv': q => ({ results: /paris files/i.test(q.get('query')) ? [{ id: 900 }] : [] }),
  '/3/tv/900': () => ({
    name: 'The Paris Files', first_air_date: '1964-01-01', overview: 'A test show.', external_ids: {},
    aggregate_credits: { cast: [{ ...GRANT, roles: [{ character: 'Peter Joshua' }] }, { ...HEPBURN, roles: [{ character: 'Regina Lampert' }] }] }
  }),
  '/3/tv/900/season/1/episode/2/credits': () => ({ cast: [GRANT, HEPBURN], guest_stars: [MARIN] }),
  '/3/person/24501': () => ({
    id: 24501, name: 'Jacques Marin', biography: 'French actor.', birthday: '1919-09-09', deathday: '2001-10-10',
    place_of_birth: 'Paris, France', profile_path: '/marin.jpg',
    combined_credits: { cast: [
      { id: 4808, media_type: 'movie', title: 'Charade', release_date: '1963-12-05', character: 'Grandpierre', vote_count: 900, poster_path: '/c.jpg' },
      { id: 1, media_type: 'tv', name: 'Talk Tonight', first_air_date: '1970-01-01', character: 'Self', vote_count: 5000, genre_ids: [10767] },
      { id: 961, media_type: 'movie', title: 'The Train', release_date: '1964-09-24', character: 'Jacques', vote_count: 300, poster_path: '/t.jpg' }
    ] }
  })
};

export function startFakeTmdb(port) {
  const calls = [];
  const server = createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    calls.push(url.pathname);
    const img = url.pathname.match(/^\/img\/\w+\/(\w+\.jpg)$/);
    if (img) {
      try { res.writeHead(200, { 'Content-Type': 'image/jpeg' }).end(fixture(img[1])); } catch (e) { res.writeHead(404).end(); }
      return;
    }
    const route = routes[url.pathname];
    if (!route) return res.writeHead(404).end('{}');
    if (url.searchParams.get('api_key') !== 'mock') return res.writeHead(401).end('{}');
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(route(url.searchParams)));
  });
  return new Promise(resolve => server.listen(port, '127.0.0.1', () => resolve({ calls, close: () => server.close() })));
}
