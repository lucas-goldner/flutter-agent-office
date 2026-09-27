// Builds the Flutter web client (app/) and copies it to dist/flutter, where a packaged office
// serves it from with --client flutter. Needs the Flutter SDK on PATH.
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, rmSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const app = path.join(root, 'app');
const r = spawnSync('flutter', ['build', 'web', '--release', '--no-web-resources-cdn'], {
  cwd: app,
  stdio: 'inherit',
  shell: process.platform === 'win32',
});
if (r.error) {
  console.error(`build:flutter: could not run flutter (${r.error.message}). Install the Flutter SDK and put it on PATH.`);
  process.exit(1);
}
if (r.status !== 0) process.exit(r.status ?? 1);
const web = path.join(app, 'build', 'web');
if (!existsSync(path.join(web, 'index.html'))) {
  console.error(`build:flutter: ${web}/index.html is missing after the build`);
  process.exit(1);
}
const out = path.join(root, 'dist', 'flutter');
rmSync(out, { recursive: true, force: true });
cpSync(web, out, { recursive: true });
console.log(`build:flutter: copied ${path.relative(root, web)} to ${path.relative(root, out)}`);
