// Manual live check of the AI functions against the REAL Ollama models (costs a few cents per run).
// Start the emulators WITHOUT functions/.secret.local so the key comes from Secret Manager, then:
//   node test/live-ai.mjs <folder with credits.jpg intro.jpg news.jpg scene.jpg scene2.jpg black.jpg>
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { initializeApp } from 'firebase/app';
import { connectAuthEmulator, createUserWithEmailAndPassword, getAuth } from 'firebase/auth';
import { connectFirestoreEmulator, doc, getFirestore, setDoc } from 'firebase/firestore';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';

const dir = process.argv[2];
const img = name => readFileSync(join(dir, name)).toString('base64');
const app = initializeApp({ projectId: 'nucflix-ad6e1', apiKey: 'demo-key', authDomain: 'nucflix-ad6e1.firebaseapp.com' });
const auth = getAuth(app);
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
const db = getFirestore(app);
connectFirestoreEmulator(db, '127.0.0.1', 8181);
const fns = getFunctions(app, 'us-central1');
connectFunctionsEmulator(fns, '127.0.0.1', 5001);

async function call(name, data) {
  const t = Date.now();
  try {
    const r = (await httpsCallable(fns, name, { timeout: 60000 })(data)).data;
    return { ms: Date.now() - t, r };
  } catch (e) {
    return { ms: Date.now() - t, error: `${e.code}: ${e.message}` };
  }
}
const short = r => r.error || `${r.r.label} conf=${r.r.confidence?.toFixed(2)} ` +
  Object.entries(r.r.probabilities || {}).map(([k, v]) => `${k}=${v.toFixed(2)}`).join(' ');

const uid = (await createUserWithEmailAndPassword(auth, `live${Date.now()}@nucflix.test`, `t-${Date.now()}`)).user.uid;
await setDoc(doc(db, `users/${uid}`), { name: 'Live test' });
await setDoc(doc(db, `users/${uid}/lines/L1`), { name: 'Line', serverURL: 'http://p.example', username: 'u', password: 'p' });

console.log('\n== frameCheck: credits task');
for (const f of ['credits.jpg', 'news.jpg', 'scene.jpg', 'black.jpg']) {
  const r = await call('frameCheck', { task: 'credits', images: [img(f)], title: 'The Hollow Creek S1E4' });
  console.log(`${f.padEnd(12)} ${String(r.ms).padStart(5)}ms  ${short(r)}`);
}
console.log('\n== frameCheck: intro task');
for (const f of ['intro.jpg', 'news.jpg', 'credits.jpg']) {
  const r = await call('frameCheck', { task: 'intro', images: [img(f)], title: 'The Hollow Creek S1E4' });
  console.log(`${f.padEnd(12)} ${String(r.ms).padStart(5)}ms  ${short(r)}`);
}
console.log('\n== frameCheck: live task (two frames ~3 s apart)');
for (const [a, b] of [['news.jpg', 'scene2.jpg'], ['black.jpg', 'black.jpg'], ['news.jpg', 'news.jpg']]) {
  const r = await call('frameCheck', { task: 'live', images: [img(a), img(b)], title: 'UK | Sky News HD' });
  console.log(`${(a + '+' + b).padEnd(22)} ${String(r.ms).padStart(5)}ms  ${short(r)}`);
}

console.log('\n== classifyCategories');
const names = [
  ['live', 'UK | BBC NEWS'], ['live', 'EN - CARTOON NETWORK'], ['movie', 'IN | HINDI MOVIES 2023'], ['live', 'XXX | ADULT 24/7'],
  ['series', 'AR | MBC DRAMA'], ['live', 'EN - DISNEY JUNIOR'], ['live', 'TR | SPOR'], ['movie', 'EN | HORROR MOVIES'],
  ['movie', '4K | DOCUMENTARIES'], ['movie', 'PUNJABI COMEDY'], ['live', 'ES | LALIGA'], ['series', 'US | NETFLIX ORIGINALS'],
  ['live', 'Adult Swim'], ['movie', 'KIDS | PIXAR COLLECTION'], ['live', 'TAMIL | SUN TV'], ['live', 'FR | CANAL+ SPORT']
];
const c = await call('classifyCategories', { lineId: 'L1', categories: names.map(([kind, name], i) => ({ id: String(i), name, kind })) });
console.log(`${c.ms}ms`);
if (c.error) console.log(c.error);
else names.forEach(([kind, name], i) => {
  const t = c.r.tags[`${kind}:${i}`];
  console.log(`${name.padEnd(26)} kids=${t.kids.toFixed(2)} adult=${t.adult.toFixed(2)} lang=${t.lang} genre=${t.genre}`);
});

console.log('\n== smartSearch');
for (const q of ['funny hindi movies from the 2010s', 'scary films from the 80s', 'cricket channels in hindi',
  'cartoons for my kids', 'latest spanish football', 'something like breaking bad', 'tamil action movies with rajinikanth']) {
  const r = await call('smartSearch', { query: q });
  console.log(`${q.padEnd(40)} ${String(r.ms).padStart(5)}ms  ${r.error || JSON.stringify(r.r)}`);
}
process.exit(0);
