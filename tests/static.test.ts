import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { CACHE_REVALIDATE, findPublicDir, flutterStatic, publicFile } from '../src/server/static.js';

// A stand-in for app/build/web, with a secret next to it that must never be served.
const root = mkdtempSync(path.join(os.tmpdir(), 'ao-flutter-'));
const web = path.join(root, 'web');
for (const f of [
  'index.html',
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.js',
  'main.dart.mjs',
  'main.dart.wasm',
  'main.dart.js_1.part.js',
  'flutter_service_worker.js',
  'version.json',
  'manifest.json',
  'favicon.svg',
  'icons/Icon-192.png',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.wasm',
  'assets/AssetManifest.bin',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/shaders/ink_sparkle.frag',
  'extra.txt',
]) {
  mkdirSync(path.dirname(path.join(web, f)), { recursive: true });
  writeFileSync(path.join(web, f), f);
}
writeFileSync(path.join(root, 'secret.txt'), 'nope');
test.after(() => rmSync(root, { recursive: true, force: true }));

const out = (p: string, signedIn = false) => flutterStatic(web, p, signedIn);
const served = (p: string, signedIn = false) => {
  const a = out(p, signedIn);
  assert.equal(a.kind, 'file', `${p} should be served, got ${JSON.stringify(a)}`);
  return a.kind === 'file' ? path.relative(web, a.file) : '';
};

test('signed out: /login, /join and /claim boot the app', () => {
  for (const p of ['/login', '/login.html', '/join', '/join.html', '/claim', '/claim.html']) assert.equal(served(p), 'index.html');
});

test('signed out: the files the app boots from are served, and revalidated', () => {
  for (const p of [
    '/index.html',
    '/flutter_bootstrap.js',
    '/flutter.js',
    '/main.dart.js',
    '/main.dart.mjs',
    '/main.dart.wasm',
    '/main.dart.js_1.part.js',
    '/flutter_service_worker.js',
    '/version.json',
    '/manifest.json',
    '/favicon.svg',
    '/icons/Icon-192.png',
    '/canvaskit/canvaskit.wasm',
    '/canvaskit/chromium/canvaskit.wasm',
    '/assets/AssetManifest.bin',
    '/assets/fonts/MaterialIcons-Regular.otf',
    '/assets/shaders/ink_sparkle.frag',
  ]) {
    assert.equal(served(p), p.slice(1));
    const a = out(p);
    assert.equal(a.kind === 'file' && a.cache, CACHE_REVALIDATE);
  }
});

test('signed out: a missing boot file is a 404, not the login redirect', () => {
  assert.deepEqual(out('/canvaskit/skwasm.wasm'), { kind: 'notFound' });
  assert.deepEqual(out('/assets/nope.png'), { kind: 'notFound' });
});

test('signed out: / and everything else goes to /login', () => {
  for (const p of ['/', '/office', '/extra.txt', '/api', '/ws']) assert.deepEqual(out(p), { kind: 'redirect', location: '/login' });
});

test('path traversal never leaves the bundle, nor borrows a public prefix', () => {
  for (const signedIn of [false, true]) {
    for (const p of ['/../secret.txt', '/assets/../../secret.txt', '/canvaskit/../../../secret.txt', '/../../../../etc/passwd', '/assets/..%2f..%2fsecret.txt']) {
      const a = out(p, signedIn);
      assert.ok(a.kind !== 'file' || a.file.startsWith(web + path.sep), `${p} escaped: ${JSON.stringify(a)}`);
      assert.ok(a.kind !== 'file' || !a.file.endsWith('secret.txt'));
    }
  }
  // /assets/../extra.txt is /extra.txt, which needs a session.
  assert.deepEqual(out('/assets/../extra.txt'), { kind: 'redirect', location: '/login' });
  assert.equal(publicFile(web, '/../secret.txt'), undefined);
  assert.equal(publicFile(web, '/index.html\0.png'), undefined);
  assert.equal(publicFile(web, '/canvaskit'), undefined, 'a folder is not a file');
});

test('signed in: files, then the SPA fallback for routes, 404 for missing files', () => {
  assert.equal(served('/', true), 'index.html');
  assert.equal(served('/extra.txt', true), 'extra.txt');
  assert.equal(served('/login', true), 'index.html');
  assert.equal(served('/office', true), 'index.html');
  assert.equal(served('/floors/acme/repo', true), 'index.html');
  assert.deepEqual(out('/missing.js', true), { kind: 'notFound' });
  assert.deepEqual(out('/api', true), { kind: 'notFound' });
  assert.deepEqual(out('/ws', true), { kind: 'notFound' });
});

test('findPublicDir: the override wins, and a missing bundle says how to build it', () => {
  assert.equal(findPublicDir('/nowhere', web), web);
  assert.throws(() => findPublicDir('/nowhere', path.join(root, 'none')), /build:client/);
  const dist = path.join(root, 'dist');
  mkdirSync(path.join(dist, 'flutter'), { recursive: true });
  writeFileSync(path.join(dist, 'flutter', 'index.html'), '');
  // Compiled, the server runs from dist/server/server.
  assert.equal(findPublicDir(path.join(dist, 'server', 'server'), ''), path.join(dist, 'flutter'));
});
