// Manual check of the frame questions against the REAL models (costs a few cents per run).
// Start the emulators WITHOUT functions/.secret.local (key from Secret Manager), then:
//   node test/frames-ai.mjs <task> <reference.jpg|-> <frame.jpg>...
// Prints each frame's verdict, alone and (with a reference) compared with a normal scene from the same title.
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { initializeApp } from 'firebase/app';
import { connectAuthEmulator, createUserWithEmailAndPassword, getAuth } from 'firebase/auth';
import { connectFunctionsEmulator, getFunctions, httpsCallable } from 'firebase/functions';

const [task, ref, ...frames] = process.argv.slice(2);
const app = initializeApp({ projectId: 'nucflix-ad6e1', apiKey: 'demo-key', authDomain: 'nucflix-ad6e1.firebaseapp.com' });
const auth = getAuth(app);
connectAuthEmulator(auth, 'http://127.0.0.1:9099', { disableWarnings: true });
const fns = getFunctions(app, 'us-central1');
connectFunctionsEmulator(fns, '127.0.0.1', 5001);
await createUserWithEmailAndPassword(auth, `frames${Date.now()}@nucflix.test`, `t-${Date.now()}`);
const img = f => readFileSync(f).toString('base64');
const fmt = r => `${String(r.label).padEnd(14)} ` + Object.entries(r.probabilities).map(([k, v]) => `${k}=${v.toFixed(2)}`).join(' ');
for (const f of frames) {
  const alone = (await httpsCallable(fns, 'frameCheck')({ task, images: [img(f)], title: 'The Big Bang Theory' })).data;
  let line = `${basename(f).padEnd(10)} alone: ${fmt(alone)}`;
  if (ref !== '-') {
    const withRef = (await httpsCallable(fns, 'frameCheck')({ task, images: [img(f), img(ref)], title: 'The Big Bang Theory' })).data;
    line += `\n${''.padEnd(10)} +ref:  ${fmt(withRef)}`;
  }
  console.log(line);
}
process.exit(0);
