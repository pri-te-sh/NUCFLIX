// AI Cloud Functions tests against the emulators (OLLAMA_API_KEY=mock). Run with `npm run test:functions`.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, rmSync, writeFileSync } from 'node:fs';
import { deleteApp, initializeApp } from 'firebase/app';
import { connectAuthEmulator, createUserWithEmailAndPassword, getAuth, signInAnonymously } from 'firebase/auth';
import { connectFirestoreEmulator, doc, getDoc, getFirestore, serverTimestamp, setDoc } from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';
import { startFakeTmdb } from './fake-tmdb.js';

const config = { projectId: 'demo-nucflix', apiKey: 'demo-key', authDomain: 'demo-nucflix.firebaseapp.com' };
const framesFile = new URL('../functions/.mock-frames.json', import.meta.url);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1]).toString('base64');

// emulators:exec sets the first two; FUNCTIONS_PORT is for runs with another firebase.json (--config).
const AUTH_HOST = process.env.FIREBASE_AUTH_EMULATOR_HOST || '127.0.0.1:9099';
const FIRESTORE_HOST = process.env.FIRESTORE_EMULATOR_HOST || '127.0.0.1:8181';
const FUNCTIONS_PORT = Number(process.env.FUNCTIONS_PORT || 5001);

function client(name) {
  const app = initializeApp(config, name);
  const auth = getAuth(app);
  connectAuthEmulator(auth, `http://${AUTH_HOST}`, { disableWarnings: true });
  const db = getFirestore(app);
  connectFirestoreEmulator(db, '127.0.0.1', Number(FIRESTORE_HOST.split(':')[1]));
  const fns = getFunctions(app, 'us-central1');
  connectFunctionsEmulator(fns, '127.0.0.1', FUNCTIONS_PORT);
  return { app, auth, db, call: (n, data) => httpsCallable(fns, n, { timeout: 120000 })(data).then(r => r.data) };
}

const rejects = (p, code) => assert.rejects(p, e => e.code === `functions/${code}`);

let owner, tvPaired, tvStranger, signedOut, ownerUid, tmdb;

before(async () => {
  tmdb = await startFakeTmdb(5199); // TMDB_API / TMDB_IMG in the test:functions script
  owner = client('owner');
  tvPaired = client('tv1');
  tvStranger = client('tv2');
  signedOut = client('nobody');
  ownerUid = (await createUserWithEmailAndPassword(owner.auth, `owner${Date.now()}@nucflix.test`, 'testpass123')).user.uid;
  await setDoc(doc(owner.db, `users/${ownerUid}`), { name: 'Owner' });
  await setDoc(doc(owner.db, `users/${ownerUid}/lines/L1`), { name: 'Line', serverURL: 'http://p.example', username: 'u', password: 'p' });
  const tvUid = (await signInAnonymously(tvPaired.auth)).user.uid;
  await signInAnonymously(tvStranger.auth);
  await setDoc(doc(owner.db, `users/${ownerUid}/members/${tvUid}`), { name: 'Living Room', platform: 'firetv', pairedAt: serverTimestamp() });
});

after(async () => {
  rmSync(framesFile, { force: true });
  tmdb.close();
  await Promise.all([owner, tvPaired, tvStranger, signedOut].map(c => deleteApp(c.app)));
});

describe('frameCheck', () => {
  it('owner and paired TV get a label with confidence', async () => {
    rmSync(framesFile, { force: true });
    const a = await owner.call('frameCheck', { task: 'credits', images: [JPEG] });
    assert.equal(a.label, 'programme');
    writeFileSync(framesFile, JSON.stringify({ credits: 'end_credits', live: 'black' }));
    const b = await tvPaired.call('frameCheck', { task: 'credits', images: [JPEG], ownerUid, title: 'Show S1E1' });
    assert.equal(b.label, 'end_credits');
    assert.ok(b.confidence > 0.5 && b.probabilities.end_credits > 0.9);
    writeFileSync(framesFile, JSON.stringify({ intro: 'intro', live: 'black' }));
    const compared = await tvPaired.call('frameCheck', { task: 'intro', images: [JPEG, JPEG], ownerUid, title: 'Show S1E1' });
    assert.equal(compared.label, 'intro'); // frame + a reference scene from the same episode
    const live = await tvPaired.call('frameCheck', { task: 'live', images: [JPEG, JPEG], ownerUid });
    assert.equal(live.label, 'black');
  });

  it('refuses signed-out users, unpaired TVs and bad input', async () => {
    await rejects(signedOut.call('frameCheck', { task: 'credits', images: [JPEG] }), 'unauthenticated');
    await rejects(tvStranger.call('frameCheck', { task: 'credits', images: [JPEG], ownerUid }), 'permission-denied');
    await rejects(owner.call('frameCheck', { task: 'credits', images: ['aGVsbG8='] }), 'invalid-argument');
    await rejects(owner.call('frameCheck', { task: 'nope', images: [JPEG] }), 'invalid-argument');
    await rejects(owner.call('frameCheck', { task: 'introRef', images: [JPEG] }), 'invalid-argument');
    await rejects(owner.call('frameCheck', { task: 'live', images: [JPEG, JPEG, JPEG] }), 'invalid-argument');
  });
});

describe('classifyCategories', () => {
  it('tags categories and saves them for the household', async () => {
    const { tags } = await tvPaired.call('classifyCategories', {
      ownerUid, lineId: 'L1',
      categories: [
        { id: '1', name: 'EN - Kids Cartoons', kind: 'live' },
        { id: '2', name: 'IN - Hindi Comedy', kind: 'movie' },
        { id: '3', name: 'XXX Adult 18+', kind: 'live' }
      ]
    });
    assert.ok(tags['live:1'].kids > 0.5 && tags['live:1'].lang === 'en');
    assert.ok(tags['movie:2'].kids < 0.5 && tags['movie:2'].lang === 'hi' && tags['movie:2'].genre === 'comedy');
    assert.ok(tags['live:3'].adult > 0.5);
    const saved = (await getDoc(doc(owner.db, `users/${ownerUid}/lineTags/L1`))).data();
    assert.deepEqual(Object.keys(saved.cats).sort(), ['live:1', 'live:3', 'movie:2']);
  });

  it('refuses unknown lines and oversized batches', async () => {
    await rejects(owner.call('classifyCategories', { lineId: 'nope', categories: [{ id: '1', name: 'x', kind: 'live' }] }), 'not-found');
    const many = Array.from({ length: 17 }, (_, i) => ({ id: String(i), name: `Cat ${i}`, kind: 'movie' }));
    await rejects(owner.call('classifyCategories', { lineId: 'L1', categories: many }), 'invalid-argument');
  });
});

describe('kidsTitles', () => {
  it('scores titles for kids and saves them for the household', async () => {
    const { scores } = await tvPaired.call('kidsTitles', {
      ownerUid, lineId: 'L1',
      items: [
        { kind: 'series', id: 11, title: 'Peppa Pig' },
        { kind: 'movie', id: 12, title: 'Deadpool (2016)' },
        { kind: 'live', id: 13, title: 'XXX Hot TV' }
      ]
    });
    assert.ok(scores['series:11'] >= 0.6);
    assert.ok(scores['movie:12'] < 0.6 && scores['live:13'] < 0.6);
    // Shards by id % 8: 11 -> 3, 12 -> 4, 13 -> 5.
    for (const [shard, key] of [[3, 'series:11'], [4, 'movie:12'], [5, 'live:13']]) {
      const saved = (await getDoc(doc(owner.db, `users/${ownerUid}/kidsTitles/L1_${shard}`))).data();
      assert.deepEqual(Object.keys(saved.titles), [key]);
    }
  });

  it('refuses bad titles, unknown lines and oversized batches', async () => {
    await rejects(owner.call('kidsTitles', { lineId: 'nope', items: [{ kind: 'movie', id: 1, title: 'x' }] }), 'not-found');
    await rejects(owner.call('kidsTitles', { lineId: 'L1', items: [{ kind: 'movie', id: 'abc', title: 'x' }] }), 'invalid-argument');
    const many = Array.from({ length: 41 }, (_, i) => ({ kind: 'movie', id: i, title: `Movie ${i}` }));
    await rejects(owner.call('kidsTitles', { lineId: 'L1', items: many }), 'invalid-argument');
  });
});

describe('smartSearch', () => {
  it('turns a request into filters', async () => {
    const f = await owner.call('smartSearch', { query: 'funny Hindi movies from the 2010s' });
    assert.equal(f.kind, 'movie');
    assert.deepEqual(f.genres, ['comedy']);
    assert.deepEqual(f.languages, ['hi']);
    assert.equal(f.yearFrom, 2010);
    assert.equal(f.yearTo, 2019);
  });

  it('refuses empty queries', async () => {
    await rejects(owner.call('smartSearch', { query: 'x' }), 'invalid-argument');
  });
});

describe('xray', () => {
  const frame = name => readFileSync(new URL(`./fixtures/xray/${name}`, import.meta.url)).toString('base64');
  const names = list => list.map(p => p.name).sort();

  it('finds the people on screen in a movie frame by their faces', async () => {
    const r = await tvPaired.call('xray', { ownerUid, kind: 'movie', title: 'Charade', year: '1963', position: 3600.5, image: frame('scene-matthau-hepburn.jpg') });
    assert.equal(r.found, true);
    assert.deepEqual(r.title, { type: 'movie', id: 4808, name: 'Charade', year: '1963', overview: 'Romance and suspense in Paris.', trivia: false });
    assert.equal(r.faces, 2);
    assert.deepEqual(names(r.scene), ['Audrey Hepburn', 'Walter Matthau']);
    assert.equal(r.scene.find(p => p.name === 'Walter Matthau').character, 'Hamilton Bartholomew');
    assert.equal(r.cast.length, 5);
    assert.equal(r.cast[0].photo, 'http://127.0.0.1:5199/img/w185/grant.jpg');
    assert.equal(r.cast[3].photo, ''); // Ned Glass has no photo
    const single = await owner.call('xray', { kind: 'movie', title: 'Charade (1963)', position: 120, image: frame('scene-marin.jpg') });
    assert.deepEqual(names(single.scene), ['Jacques Marin']);
  });

  it('looks a scene up once, and photos once per person', async () => {
    const photos = () => tmdb.calls.filter(c => c.startsWith('/img/h632/')).length;
    const before = photos();
    const again = await owner.call('xray', { kind: 'movie', title: 'Charade', year: '1963', position: 3605, image: frame('scene-marin.jpg') });
    assert.deepEqual(names(again.scene), ['Audrey Hepburn', 'Walter Matthau']); // same 10-second stretch: cached answer
    await owner.call('xray', { kind: 'movie', title: 'Charade', year: '1963', position: 1800, image: frame('scene-marin.jpg') });
    assert.equal(photos(), before); // embeddings came from the cache
  });

  it('falls back to the full cast without a frame', async () => {
    const r = await owner.call('xray', { kind: 'movie', title: 'Charade', year: '1963', position: 5000 });
    assert.equal(r.scene, null);
    assert.equal(r.cast.length, 5);
  });

  it('uses the episode\'s own cast, guest stars included', async () => {
    const r = await owner.call('xray', { kind: 'episode', title: 'The Paris Files', season: 1, episode: 2, position: 10, image: frame('scene-marin.jpg') });
    assert.deepEqual(names(r.cast), ['Audrey Hepburn', 'Cary Grant', 'Jacques Marin']);
    assert.deepEqual(names(r.scene), ['Jacques Marin']);
    const other = await owner.call('xray', { kind: 'episode', title: 'The Paris Files', season: 1, episode: 3, position: 10 });
    assert.deepEqual(names(other.cast), ['Audrey Hepburn', 'Cary Grant']); // no episode credits: the show's cast
    assert.equal(other.cast.find(p => p.name === 'Cary Grant').character, 'Peter Joshua');
  });

  it('reports unknown titles', async () => {
    const r = await owner.call('xray', { kind: 'movie', title: 'Nothing Like This', position: 1 });
    assert.deepEqual(r, { found: false });
  });

  it('gives a person\'s bio and other titles, without talk shows', async () => {
    const p = await owner.call('xray', { action: 'person', personId: 24501 });
    assert.equal(p.name, 'Jacques Marin');
    assert.equal(p.place, 'Paris, France');
    assert.deepEqual(p.credits.map(c => c.title), ['Charade', 'The Train']);
    assert.equal(p.credits[0].poster, 'http://127.0.0.1:5199/img/w185/c.jpg');
    await rejects(owner.call('xray', { action: 'person', personId: 'x' }), 'invalid-argument');
  });

  it('has no trivia without a Wikipedia article', async () => {
    assert.deepEqual(await owner.call('xray', { action: 'trivia', type: 'movie', id: 4808 }), { facts: [] });
  });

  it('is for the household only', async () => {
    await rejects(tvStranger.call('xray', { kind: 'movie', title: 'Charade', position: 1 }), 'permission-denied');
    await rejects(signedOut.call('xray', { kind: 'movie', title: 'Charade', position: 1 }), 'unauthenticated');
    await rejects(owner.call('xray', { kind: 'episode', title: 'The Paris Files', position: 1 }), 'invalid-argument');
  });
});
