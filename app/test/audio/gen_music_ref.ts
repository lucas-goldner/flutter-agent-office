// Regenerates music_ref.json from the TS client's music.ts, which the Dart tests compare against:
//   npx tsx app/test/audio/gen_music_ref.ts > app/test/audio/music_ref.json   (from the repo root)
// music.ts keeps its helpers private, so this exports them in a temporary copy first.
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const ts = readFileSync('src/client/music.ts', 'utf8').replace(/^(function (melodyFor|hash|mulberry|section)|const TUNES)/gm, 'export $1');
const file = join(mkdtempSync(join(tmpdir(), 'music-')), 'music.ts');
writeFileSync(file, ts);
const { TunePlayer, TUNES, melodyFor, hash, mulberry, section } = await import(file);
const V = ['kick', 'snare', 'hat', 'bass', 'key', 'lead'];
const r = (x: number) => Number(x.toPrecision(12));
const mock: any = new Proxy(function () {}, {
  get: (_t, p) => (p === 'sampleRate' ? 100 : p === 'currentTime' ? (mock as any).__now ?? 0 : p === 'state' ? 'running' : p === 'getChannelData' ? () => new Float32Array(1000) : p === '__now' ? now : mock),
  apply: () => mock,
  set: (_t, p, v) => { if (p === '__now') now = v; return true; },
});
let now = 0;
const out: any = { hash: [], mulberry: {}, tunes: {} };
for (const [a, b] of [[0, 0], [1, 2], [7, 64], [12345, 67], [-5, 3], [100000, 11], [2 ** 31 + 5, 99]]) out.hash.push([a, b, hash(a, b)]);
for (const s of [0, 1, 7, 21]) { const r = mulberry(s); out.mulberry[s] = Array.from({ length: 10 }, () => r()); }
out.section = Array.from({ length: 40 }, (_, b) => section(b));
for (const id of Object.keys(TUNES)) {
  const p: any = new TunePlayer(mock, mock, id);
  const ev: any[] = [];
  let k0 = 0;
  const rec = (voice: string) => (when: number, a?: number, b?: number, c?: number) => {
    const e: any = { k: k0, voice, delay: when };
    if (voice === 'kick' || voice === 'snare' || voice === 'hat') e.vel = a;
    else if (voice === 'bass' || voice === 'lead') { e.midi = a; e.len = b; e.vel = 1; }
    else { e.midi = a; e.len = b; e.vel = c; }
    ev.push(e);
  };
  for (const v of ['kick', 'snare', 'hat', 'bass', 'key', 'lead']) p[v] = rec(v);
  for (let k = 0; k < 32 * 16 + 20; k++) { k0 = k; p.play(k, 0); }
  const beats = [0, 0.1, 0.33, 1.7, 5, 13.2, 20.5, 60.1, 81.3, 100].map((a) => [a, p.beat(a)]);
  // The clock: tick at several moments, with a jump.
  const q: any = new TunePlayer(mock, mock, id);
  const due: any[] = [];
  q.play = (k: number, when: number) => due.push([k, when]);
  const ticks = [[0, 3], [0.15, 3.15], [0.3, 3.31], [0.45, 3.46], [5, 20], [5.15, 20.15]];
  for (const [at, n] of ticks) { now = n; due.push(['tick', at, n]); q.tick(at); }
  out.tunes[id] = { melody: melodyFor((TUNES as any)[id]), events: ev, beats, due, step: p.step };
}
for (const t of Object.values<any>(out.tunes)) {
  t.events = t.events.map((e: any) => [e.k, V.indexOf(e.voice), r(e.delay), e.midi ?? 0, r(e.len ?? 0), r(e.vel)]);
  t.due = t.due.map((x: any) => (x[0] === 'tick' ? x : [x[0], r(x[1])]));
}
console.log(JSON.stringify(out));
