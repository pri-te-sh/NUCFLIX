// AI Cloud Functions tests against the emulators (OLLAMA_API_KEY=mock). Run with `npm run test:functions`.
import { after, before, describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { rmSync, writeFileSync } from 'node:fs';
import { deleteApp, initializeApp } from 'firebase/app';
import { connectAuthEmulator, createUserWithEmailAndPassword, getAuth, signInAnonymously } from 'firebase/auth';
import { connectFirestoreEmulator, doc, getDoc, getFirestore, serverTimestamp, setDoc } from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';

const config = { projectId: 'demo-nucflix', apiKey: 'demo-key', authDomain: 'demo-nucflix.firebaseapp.com' };
const framesFile = new URL('../functions/.mock-frames.json', import.meta.url);
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1]).toString('base64');

function client(name) {
  const app = initializeApp(config, name);
  const auth = getAuth(app);
  connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
  const db = getFirestore(app);
  connectFirestoreEmulator(db, '127.0.0.1', 8181);
  const fns = getFunctions(app, 'us-central1');
  connectFunctionsEmulator(fns, '127.0.0.1', 5001);
  return { app, auth, db, call: (n, data) => httpsCallable(fns, n)(data).then(r => r.data) };
}

const rejects = (p, code) => assert.rejects(p, e => e.code === `functions/${code}`);

let owner, tvPaired, tvStranger, signedOut, ownerUid;

before(async () => {
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
    const saved = (await getDoc(doc(owner.db, `users/${ownerUid}/kidsTitles/L1`))).data();
    assert.deepEqual(Object.keys(saved.titles).sort(), ['live:13', 'movie:12', 'series:11']);
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
