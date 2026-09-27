// Bundles the whiteboard (Excalidraw 0.18, React 18 and app/excalidraw/bridge.js) for the Flutter
// client into app/web/excalidraw/, which `flutter build web` copies to build/web/excalidraw/:
//   whiteboard.js     the bridge, as an ES module the app imports the first time the whiteboard is needed
//   chunk-*.js        what it loads from there (Excalidraw's font subsetting worker, for one)
//   whiteboard.css    Excalidraw's styles, which the bridge adds to the page
//   fonts/            Excalidraw's hand-drawn fonts, served by the office rather than a CDN
// Xiaolai (CJK, 12 MB) is left out, as in vite.config.ts: Excalidraw falls back to its CDN for that one,
// only when someone writes Chinese, Japanese or Korean. So are the other languages: the board is in English.
//
// Run by `npm run build:flutter` before the Flutter build, or alone: `npm run build:whiteboard`.
// The output is gitignored (it's several MB).
import { build } from 'esbuild';
import { cpSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'app', 'web', 'excalidraw');
const excalidraw = path.join(root, 'node_modules', '@excalidraw', 'excalidraw', 'dist', 'prod');

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

/** Every language but English becomes an empty module: nothing ever asks for them. */
const englishOnly = {
  name: 'english-only',
  setup(b) {
    b.onResolve({ filter: /^\.\/locales\/[\w-]+\.js$/ }, (args) =>
      /^\.\/locales\/(en|percentages)-/.test(args.path) ? undefined : { path: args.path, namespace: 'no-locale' },
    );
    b.onLoad({ filter: /.*/, namespace: 'no-locale' }, () => ({ contents: 'export default {};', loader: 'js' }));
  },
};

await build({
  entryPoints: { whiteboard: path.join(root, 'app', 'excalidraw', 'bridge.js') },
  outdir: out,
  bundle: true,
  splitting: true,
  format: 'esm',
  minify: true,
  target: 'es2022',
  conditions: ['production'],
  define: { 'process.env.NODE_ENV': '"production"', 'process.env.IS_PREACT': '"false"' },
  // Excalidraw's CSS points at ./fonts/…, which are copied next to it below.
  external: ['*.woff2'],
  plugins: [englishOnly],
  logLevel: 'warning',
  // Excalidraw's Radix UI parts start with "use client", which means nothing outside React Server Components.
  logOverride: { 'unsupported-directive': 'silent' },
});

cpSync(path.join(excalidraw, 'fonts'), path.join(out, 'fonts'), {
  recursive: true,
  filter: (src) => path.basename(src) !== 'Xiaolai',
});

const size = (p) => (statSync(p).isDirectory() ? readdirSync(p).reduce((n, f) => n + size(path.join(p, f)), 0) : statSync(p).size);
console.log(`build:whiteboard: ${path.relative(root, out)} (${(size(out) / 1024 / 1024).toFixed(1)} MB)`);
