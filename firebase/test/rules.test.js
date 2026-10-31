// Firestore rules tests. Run with `npm test` (starts the Firestore emulator, then node --test).
import { after, before, beforeEach, describe, it } from 'node:test';
import { readFileSync } from 'node:fs';
import { assertFails, assertSucceeds, initializeTestEnvironment } from '@firebase/rules-unit-testing';
import {
  Timestamp, collection, deleteDoc, doc, getDoc, getDocs, serverTimestamp, setDoc, updateDoc, writeBatch
} from 'firebase/firestore';

let env;

before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-nucflix',
    firestore: { rules: readFileSync('firestore.rules', 'utf8'), host: '127.0.0.1', port: 8181 }
  });
});
after(() => env.cleanup());
beforeEach(() => env.clearFirestore());

// Phones sign in with Google/email; TVs sign in anonymously.
const phone = (uid = 'owner') => env.authenticatedContext(uid, { firebase: { sign_in_provider: 'google.com' } }).firestore();
const tv = (uid = 'tv1') => env.authenticatedContext(uid, { firebase: { sign_in_provider: 'anonymous' } }).firestore();
const nobody = () => env.unauthenticatedContext().firestore();

const seed = fn => env.withSecurityRulesDisabled(ctx => fn(ctx.firestore()));
const minutes = n => Timestamp.fromMillis(Date.now() + n * 60_000);

const LINE = { name: 'Main line', serverURL: 'http://provider.example:8080', username: 'user1', password: 'secret' };
const PROFILE = { name: 'Pritesh', avatar: 'red', kids: false, prefs: { autoplayNext: true } };
const progress = (extra = {}) => ({
  lineId: 'L1', kind: 'movie', streamId: 2209159, title: 'Verity', position: 302, duration: 7200,
  updatedAt: serverTimestamp(), device: 'Living Room TV', ...extra
});
const favorite = (extra = {}) => ({ lineId: 'L1', kind: 'movie', id: 2209159, title: 'Verity', addedAt: serverTimestamp(), ...extra });

async function pairedHousehold() {
  await seed(async db => {
    await setDoc(doc(db, 'users/owner'), { name: 'Pritesh' });
    await setDoc(doc(db, 'users/owner/lines/L1'), LINE);
    await setDoc(doc(db, 'users/owner/profiles/p1'), PROFILE);
    await setDoc(doc(db, 'users/owner/members/tv1'), { name: 'Living Room TV', platform: 'firetv' });
  });
}

describe('household account', () => {
  it('owner creates and reads their account', async () => {
    await assertSucceeds(setDoc(doc(phone(), 'users/owner'), { name: 'Pritesh', createdAt: serverTimestamp() }));
    await assertSucceeds(getDoc(doc(phone(), 'users/owner')));
  });

  it('other accounts, TVs and signed-out users cannot touch it', async () => {
    await seed(db => setDoc(doc(db, 'users/owner'), { name: 'Pritesh' }));
    await assertFails(getDoc(doc(phone('intruder'), 'users/owner')));
    await assertFails(setDoc(doc(phone('intruder'), 'users/owner'), { name: 'x' }));
    await assertFails(getDoc(doc(tv(), 'users/owner')));
    await assertFails(getDoc(doc(nobody(), 'users/owner')));
  });

  it('an anonymous TV cannot create a household of its own', async () => {
    await assertFails(setDoc(doc(tv(), 'users/tv1'), { name: 'TV' }));
    await assertFails(setDoc(doc(tv(), 'users/tv1/lines/L1'), LINE));
  });

  it('rejects unknown fields on the account', async () => {
    await assertFails(setDoc(doc(phone(), 'users/owner'), { name: 'Pritesh', admin: true }));
  });
});

describe('Xtream lines', () => {
  it('owner manages lines; validates shape', async () => {
    await assertSucceeds(setDoc(doc(phone(), 'users/owner/lines/L1'), LINE));
    await assertFails(setDoc(doc(phone(), 'users/owner/lines/L2'), { ...LINE, serverURL: '' }));
    await assertFails(setDoc(doc(phone(), 'users/owner/lines/L3'), { ...LINE, extra: 1 }));
    await assertSucceeds(deleteDoc(doc(phone(), 'users/owner/lines/L1')));
  });

  it('a paired TV can read lines but never write them', async () => {
    await pairedHousehold();
    await assertSucceeds(getDoc(doc(tv(), 'users/owner/lines/L1')));
    await assertSucceeds(getDocs(collection(tv(), 'users/owner/lines')));
    await assertFails(setDoc(doc(tv(), 'users/owner/lines/L1'), LINE));
    await assertFails(deleteDoc(doc(tv(), 'users/owner/lines/L1')));
  });

  it('unpaired TVs and other accounts cannot read lines', async () => {
    await pairedHousehold();
    await assertFails(getDoc(doc(tv('tv2'), 'users/owner/lines/L1')));
    await assertFails(getDocs(collection(phone('intruder'), 'users/owner/lines')));
  });
});

describe('profiles', () => {
  it('owner creates, renames and deletes profiles', async () => {
    await assertSucceeds(setDoc(doc(phone(), 'users/owner/profiles/p1'), PROFILE));
    await assertSucceeds(updateDoc(doc(phone(), 'users/owner/profiles/p1'), { name: 'Dad' }));
    await assertFails(setDoc(doc(phone(), 'users/owner/profiles/p2'), { ...PROFILE, name: '' }));
    await assertSucceeds(deleteDoc(doc(phone(), 'users/owner/profiles/p1')));
  });

  it('a paired TV may add profiles and change prefs only', async () => {
    await pairedHousehold();
    await assertSucceeds(getDocs(collection(tv(), 'users/owner/profiles')));
    await assertSucceeds(updateDoc(doc(tv(), 'users/owner/profiles/p1'), { prefs: { autoplayNext: false }, updatedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(tv(), 'users/owner/profiles/p1'), { name: 'Hacked' }));
    await assertFails(updateDoc(doc(tv(), 'users/owner/profiles/p1'), { kids: true }));
    await assertSucceeds(setDoc(doc(tv(), 'users/owner/profiles/p9'), { ...PROFILE, name: 'Mom', kids: true }));
    await assertFails(setDoc(doc(tv(), 'users/owner/profiles/p8'), { ...PROFILE, name: '' }));
    await assertFails(setDoc(doc(tv(), 'users/owner/profiles/p7'), { ...PROFILE, admin: true }));
    await assertFails(setDoc(doc(tv('tv2'), 'users/owner/profiles/p6'), PROFILE)); // not paired
    await assertFails(deleteDoc(doc(tv(), 'users/owner/profiles/p1')));
  });
});

describe('watch progress and favorites', () => {
  const P = 'users/owner/profiles/p1/progress/L1:movie:2209159';
  const F = 'users/owner/profiles/p1/favorites/L1:movie:2209159';

  it('phone and paired TV both read and write progress', async () => {
    await pairedHousehold();
    await assertSucceeds(setDoc(doc(phone(), P), progress()));
    await assertSucceeds(setDoc(doc(tv(), P), progress({ position: 900 })));
    await assertSucceeds(getDocs(collection(tv(), 'users/owner/profiles/p1/progress')));
    await assertSucceeds(deleteDoc(doc(tv(), P)));
  });

  it('progress must be well-formed and stamped with server time', async () => {
    await pairedHousehold();
    await assertFails(setDoc(doc(tv(), P), progress({ kind: 'podcast' })));
    await assertFails(setDoc(doc(tv(), P), progress({ position: -5 })));
    await assertFails(setDoc(doc(tv(), P), progress({ updatedAt: Timestamp.fromMillis(Date.now() + 86_400_000) })));
    await assertFails(setDoc(doc(tv(), P), progress({ password: 'x' })));
    await assertFails(setDoc(doc(tv(), P), { ...progress(), lineId: '' }));
  });

  it('outsiders cannot read or write progress', async () => {
    await pairedHousehold();
    await seed(db => setDoc(doc(db, P), { ...progress(), updatedAt: Timestamp.now() }));
    await assertFails(getDoc(doc(tv('tv2'), P)));
    await assertFails(setDoc(doc(phone('intruder'), P), progress()));
  });

  it('favorites follow the same access with their own shape', async () => {
    await pairedHousehold();
    await assertSucceeds(setDoc(doc(tv(), F), favorite()));
    await assertSucceeds(setDoc(doc(phone(), 'users/owner/profiles/p1/favorites/L1:series:77'), favorite({ kind: 'series', id: 77 })));
    await assertSucceeds(setDoc(doc(phone(), F), favorite({ ext: 'mkv', categoryId: '191' })));
    await assertFails(setDoc(doc(phone(), F), favorite({ ext: 'way-too-long-extension' })));
    await assertFails(setDoc(doc(tv(), F), favorite({ kind: 'episode' })));
    await assertFails(setDoc(doc(tv(), F), favorite({ addedAt: Timestamp.fromMillis(0) })));
    await assertFails(getDoc(doc(phone('intruder'), F)));
  });
});

describe('members (paired TVs)', () => {
  it('owner adds and removes TVs', async () => {
    await assertSucceeds(setDoc(doc(phone(), 'users/owner/members/tv1'), { name: 'Living Room TV', platform: 'firetv', pairedAt: serverTimestamp() }));
    await assertSucceeds(deleteDoc(doc(phone(), 'users/owner/members/tv1')));
  });

  it('a TV cannot add itself to a household', async () => {
    await assertFails(setDoc(doc(tv(), 'users/owner/members/tv1'), { name: 'Sneaky TV' }));
  });

  it('a TV can see and remove its own membership only', async () => {
    await pairedHousehold();
    await seed(db => setDoc(doc(db, 'users/owner/members/tv2'), { name: 'Bedroom TV' }));
    await assertSucceeds(getDoc(doc(tv(), 'users/owner/members/tv1')));
    await assertFails(getDoc(doc(tv(), 'users/owner/members/tv2')));
    await assertFails(deleteDoc(doc(tv(), 'users/owner/members/tv2')));
    await assertSucceeds(deleteDoc(doc(tv(), 'users/owner/members/tv1')));
    // Once unpaired the TV loses access to the household.
    await assertFails(getDoc(doc(tv(), 'users/owner/lines/L1')));
  });
});

describe('devices (now playing)', () => {
  const device = (extra = {}) => ({ name: 'Living Room TV', platform: 'firetv', lastSeen: serverTimestamp(), nowPlaying: null, ...extra });

  it('a paired TV writes only its own device doc', async () => {
    await pairedHousehold();
    await assertSucceeds(setDoc(doc(tv(), 'users/owner/devices/tv1'), device({ nowPlaying: { profileId: 'p1', title: 'Verity' } })));
    await assertFails(setDoc(doc(tv(), 'users/owner/devices/iphone'), device({ platform: 'ios' })));
    await assertSucceeds(getDocs(collection(tv(), 'users/owner/devices')));
  });

  it('owner phones can write any device doc; shape is enforced', async () => {
    await assertSucceeds(setDoc(doc(phone(), 'users/owner/devices/iphone-1'), device({ name: 'iPhone', platform: 'ios' })));
    await assertFails(setDoc(doc(phone(), 'users/owner/devices/x'), device({ platform: 'android' })));
    await assertFails(setDoc(doc(phone(), 'users/owner/devices/x'), device({ lastSeen: Timestamp.fromMillis(0) })));
  });

  it('unpaired TVs cannot announce themselves', async () => {
    await assertFails(setDoc(doc(tv('tv2'), 'users/owner/devices/tv2'), device()));
  });
});

describe('TV pairing flow', () => {
  const CODE = 'K7Q2M9XD';
  const pending = (extra = {}) => ({ tvUid: 'tv1', tvName: 'Living Room TV', status: 'pending', createdAt: serverTimestamp(), expiresAt: minutes(10), ...extra });
  const approveBatch = (db, uid = 'owner', tvUid = 'tv1') => {
    const b = writeBatch(db);
    b.set(doc(db, `users/${uid}/members/${tvUid}`), { name: 'Living Room TV', platform: 'firetv', pairedAt: serverTimestamp() });
    b.update(doc(db, `pairing/${CODE}`), { status: 'approved', ownerUid: uid, ownerName: 'Pritesh', approvedAt: serverTimestamp() });
    return b.commit();
  };

  it('happy path: TV creates code, phone approves, TV reads the household', async () => {
    await seed(async db => {
      await setDoc(doc(db, 'users/owner'), { name: 'Pritesh' });
      await setDoc(doc(db, 'users/owner/lines/L1'), LINE);
    });
    await assertSucceeds(setDoc(doc(tv(), `pairing/${CODE}`), pending()));
    await assertSucceeds(getDoc(doc(phone(), `pairing/${CODE}`)));
    await assertSucceeds(approveBatch(phone()));
    const snap = await assertSucceeds(getDoc(doc(tv(), `pairing/${CODE}`)));
    if (snap.data().ownerUid !== 'owner') throw new Error('ownerUid not set');
    await assertSucceeds(getDoc(doc(tv(), 'users/owner/lines/L1')));
    await assertSucceeds(deleteDoc(doc(tv(), `pairing/${CODE}`)));
  });

  it('codes must be well-formed, short-lived and created for yourself', async () => {
    await assertFails(setDoc(doc(tv(), 'pairing/abc'), pending()));
    await assertFails(setDoc(doc(tv(), 'pairing/K7Q2M9XO'), pending())); // O is not in the alphabet
    await assertFails(setDoc(doc(tv(), `pairing/${CODE}`), pending({ tvUid: 'someone-else' })));
    await assertFails(setDoc(doc(tv(), `pairing/${CODE}`), pending({ expiresAt: minutes(60) })));
    await assertFails(setDoc(doc(tv(), `pairing/${CODE}`), pending({ status: 'approved' })));
    await assertFails(setDoc(doc(tv(), `pairing/${CODE}`), pending({ ownerUid: 'owner' })));
    await assertFails(setDoc(doc(nobody(), `pairing/${CODE}`), pending()));
  });

  it('codes cannot be listed, hijacked or overwritten', async () => {
    await assertSucceeds(setDoc(doc(tv(), `pairing/${CODE}`), pending()));
    await assertFails(getDocs(collection(phone(), 'pairing')));
    await assertFails(setDoc(doc(tv('tv2'), `pairing/${CODE}`), pending({ tvUid: 'tv2' })));
    await assertFails(getDoc(doc(nobody(), `pairing/${CODE}`)));
  });

  it('approval needs a real account, the membership, and a live pending code', async () => {
    await assertSucceeds(setDoc(doc(tv(), `pairing/${CODE}`), pending()));
    // Approving without adding the TV as a member.
    await assertFails(updateDoc(doc(phone(), `pairing/${CODE}`), { status: 'approved', ownerUid: 'owner', approvedAt: serverTimestamp() }));
    // An anonymous user (another TV) cannot approve.
    await assertFails(approveBatch(tv('tv2'), 'tv2'));
    // Approving on someone else's behalf.
    await assertFails(updateDoc(doc(phone(), `pairing/${CODE}`), { status: 'approved', ownerUid: 'intruder', approvedAt: serverTimestamp() }));
    // Changing the TV it points at.
    await assertFails(updateDoc(doc(phone(), `pairing/${CODE}`), { tvUid: 'tv9' }));
    await assertSucceeds(approveBatch(phone()));
    // Already approved: a second account cannot take it over.
    await assertFails(approveBatch(phone('intruder'), 'intruder'));
  });

  it('expired codes cannot be approved', async () => {
    await seed(db => setDoc(doc(db, `pairing/${CODE}`), { ...pending(), createdAt: Timestamp.now(), expiresAt: minutes(-1) }));
    await assertFails(approveBatch(phone()));
  });

  it('only the TV or the approving owner can delete a code', async () => {
    await assertSucceeds(setDoc(doc(tv(), `pairing/${CODE}`), pending()));
    await assertFails(deleteDoc(doc(tv('tv2'), `pairing/${CODE}`)));
    await assertFails(deleteDoc(doc(phone('intruder'), `pairing/${CODE}`)));
    await assertSucceeds(approveBatch(phone()));
    await assertSucceeds(deleteDoc(doc(phone(), `pairing/${CODE}`)));
  });
});

describe('AI markers and category tags', () => {
  const marker = (extra = {}) => ({
    lineId: 'L1', kind: 'episode', creditsAt: 1302.5, introStart: 30, introEnd: 85, duration: 1400,
    source: 'ai', updatedAt: serverTimestamp(), ...extra
  });

  it('owner and paired TV save and read markers', async () => {
    await pairedHousehold();
    await assertSucceeds(setDoc(doc(tv(), 'users/owner/markers/L1:episode:142613'), marker()));
    await assertSucceeds(getDoc(doc(phone(), 'users/owner/markers/L1:episode:142613')));
    const { introStart, introEnd, ...movieMarker } = marker({ kind: 'movie' });
    await assertSucceeds(setDoc(doc(phone(), 'users/owner/markers/L1:movie:5'), movieMarker));
  });

  it('markers are validated and closed to outsiders', async () => {
    await pairedHousehold();
    await assertFails(setDoc(doc(tv('tv9'), 'users/owner/markers/L1:episode:1'), marker()));
    await assertFails(getDoc(doc(phone('intruder'), 'users/owner/markers/L1:episode:1')));
    await assertFails(setDoc(doc(tv(), 'users/owner/markers/L1:episode:1'), marker({ kind: 'live' })));
    await assertFails(setDoc(doc(tv(), 'users/owner/markers/L1:episode:1'), marker({ source: 'guess' })));
    await assertFails(setDoc(doc(tv(), 'users/owner/markers/L1:episode:1'), marker({ creditsAt: 'soon' })));
    await assertFails(setDoc(doc(tv(), 'users/owner/markers/L1:episode:1'), marker({ extra: 1 })));
    await assertFails(setDoc(doc(tv(), 'users/owner/markers/L1:episode:1'), marker({ duration: 0 })));
  });

  it('category tags are readable by the household and written only by Cloud Functions', async () => {
    await pairedHousehold();
    await seed(db => setDoc(doc(db, 'users/owner/lineTags/L1'), { cats: { 'live:1': { kids: 0.9, adult: 0, lang: 'en', genre: 'kids' } } }));
    await assertSucceeds(getDoc(doc(tv(), 'users/owner/lineTags/L1')));
    await assertSucceeds(getDoc(doc(phone(), 'users/owner/lineTags/L1')));
    await assertFails(getDoc(doc(phone('intruder'), 'users/owner/lineTags/L1')));
    await assertFails(setDoc(doc(phone(), 'users/owner/lineTags/L1'), { cats: {} }));
    await assertFails(setDoc(doc(tv(), 'users/owner/lineTags/L1'), { cats: {} }));
  });

  it('kids title scores are readable by the household and written only by Cloud Functions', async () => {
    await pairedHousehold();
    await seed(db => setDoc(doc(db, 'users/owner/kidsTitles/L1'), { titles: { 'movie:1': 0.95 } }));
    await assertSucceeds(getDoc(doc(tv(), 'users/owner/kidsTitles/L1')));
    await assertSucceeds(getDoc(doc(phone(), 'users/owner/kidsTitles/L1')));
    await assertFails(getDoc(doc(phone('intruder'), 'users/owner/kidsTitles/L1')));
    await assertFails(setDoc(doc(phone(), 'users/owner/kidsTitles/L1'), { titles: { 'movie:2': 1 } }));
    await assertFails(setDoc(doc(tv(), 'users/owner/kidsTitles/L1'), { titles: { 'movie:2': 1 } }));
  });

  it('usage counters are never visible to apps', async () => {
    await seed(db => setDoc(doc(db, 'aiUsage/owner'), { day: '2026-10-28', calls: 3 }));
    await assertFails(getDoc(doc(phone(), 'aiUsage/owner')));
    await assertFails(setDoc(doc(phone(), 'aiUsage/owner'), { day: '2026-10-28', calls: 0 }));
  });
});
