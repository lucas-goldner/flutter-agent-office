import { existsSync, statSync } from 'node:fs';
import path from 'node:path';

/** Flutter's files keep their names from build to build, so browsers must revalidate them. */
export const CACHE_REVALIDATE = 'no-cache';

/**
 * Where the client's files are. AGENT_OFFICE_PUBLIC_DIR overrides it (tests, a custom build).
 * `here` is the folder of the running server file: src/server under tsx, dist/server/server once
 * compiled, so each candidate is listed for both.
 */
export function findPublicDir(here: string, override = process.env.AGENT_OFFICE_PUBLIC_DIR): string {
  const candidates = override
    ? [path.resolve(override)]
    : [
        path.resolve(here, '../../flutter'), // dist/server/server -> dist/flutter (packaged)
        path.resolve(here, '../../dist/flutter'), // src/server -> dist/flutter
        path.resolve(here, '../../app/build/web'), // src/server -> app/build/web (checkout)
        path.resolve(here, '../../../app/build/web'), // dist/server/server -> app/build/web
      ];
  for (const c of candidates) if (existsSync(path.join(c, 'index.html'))) return c;
  throw new Error(`The client isn't built (looked in ${candidates.join(', ')}). Run \`npm run build:client\`.`);
}

/** A file of the client bundle, or undefined when it's missing, a folder, or outside the bundle. */
export function publicFile(publicDir: string, p: string): string | undefined {
  if (p.includes('\0')) return undefined;
  const file = path.join(publicDir, path.normalize(p).replace(/^(\.\.[/\\])+/, ''));
  return file.startsWith(publicDir + path.sep) && existsSync(file) && statSync(file).isFile() ? file : undefined;
}

/** The pages the Flutter router shows to people who aren't signed in yet. */
const FLUTTER_PAGES = /^\/(login|join|claim)(\.html)?$/;

/**
 * What the Flutter app needs to boot on /login before anyone is signed in. None of it is secret:
 * it's the same for every office.
 */
const FLUTTER_PUBLIC = [
  /^\/index\.html$/,
  /^\/flutter_bootstrap\.js$/,
  /^\/flutter\.js$/,
  /^\/flutter_service_worker\.js$/,
  /^\/main\.dart(\.[\w-]+)*\.(js|mjs|wasm)$/,
  /^\/version\.json$/,
  /^\/manifest\.json$/,
  /^\/favicon\.[\w]+$/,
  /^\/icons\/.+/,
  /^\/canvaskit\/.+/,
  /^\/assets\/.+/,
];

export type StaticAnswer =
  | { kind: 'file'; file: string; cache: string }
  | { kind: 'redirect'; location: string }
  | { kind: 'notFound' };

/**
 * How the office answers a GET of the Flutter client, for anything that isn't /api (the caller
 * handles those, and their auth, itself). `p` is the decoded path.
 */
export function flutterStatic(publicDir: string, p: string, signedIn: boolean): StaticAnswer {
  // Matched on the normalised path, so /assets/../secret can't borrow /assets' pass.
  p = path.posix.normalize(p);
  const index = (): StaticAnswer => ({ kind: 'file', file: path.join(publicDir, 'index.html'), cache: CACHE_REVALIDATE });
  if (FLUTTER_PAGES.test(p)) return index();
  if (FLUTTER_PUBLIC.some((re) => re.test(p))) {
    const file = publicFile(publicDir, p);
    return file ? { kind: 'file', file, cache: CACHE_REVALIDATE } : { kind: 'notFound' };
  }
  if (!signedIn) return { kind: 'redirect', location: '/login' };
  if (p === '/') return index();
  if (p === '/api' || p.startsWith('/api/') || p === '/ws') return { kind: 'notFound' };
  const file = publicFile(publicDir, p);
  if (file) return { kind: 'file', file, cache: CACHE_REVALIDATE };
  // A route of the app (no extension): the app reads the path. A missing file is a plain 404.
  if (!path.posix.extname(p)) return index();
  return { kind: 'notFound' };
}
