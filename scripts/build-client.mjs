// Builds the browser client, the Flutter web app in app/, and copies it to dist/flutter, where a
// packaged office serves it from. Needs the Flutter SDK on PATH. The whiteboard's Excalidraw
// bundle is built first (scripts/build-whiteboard.mjs), into app/web/excalidraw/, so Flutter copies it in.
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const app = path.join(root, 'app');
const wb = spawnSync(process.execPath, [path.join(root, 'scripts', 'build-whiteboard.mjs')], { cwd: root, stdio: 'inherit' });
if (wb.status !== 0) process.exit(wb.status ?? 1);
const r = spawnSync('flutter', ['build', 'web', '--release', '--no-web-resources-cdn', '--no-wasm-dry-run'], {
  cwd: app,
  stdio: 'inherit',
  shell: process.platform === 'win32',
});
if (r.error) {
  console.error(`build:client: could not run flutter (${r.error.message}). Install the Flutter SDK and put it on PATH.`);
  process.exit(1);
}
if (r.status !== 0) process.exit(r.status ?? 1);
const web = path.join(app, 'build', 'web');
if (!existsSync(path.join(web, 'index.html'))) {
  console.error(`build:client: ${web}/index.html is missing after the build`);
  process.exit(1);
}
const out = path.join(root, 'dist', 'flutter');
rmSync(out, { recursive: true, force: true });
// Everything but the engine's debug symbols, which only a debugger reads.
cpSync(web, out, { recursive: true, filter: (src) => !src.endsWith('.symbols') });
console.log(`build:client: copied ${path.relative(root, web)} to ${path.relative(root, out)}`);
