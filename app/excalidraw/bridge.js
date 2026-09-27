// The whiteboard's Excalidraw, for the Flutter client (app/lib/ui/whiteboard.dart). Excalidraw is a
// React component and stays JavaScript: scripts/build-whiteboard.mjs bundles this module with React
// and Excalidraw into app/web/excalidraw/, which the office loads the first time the whiteboard is
// needed. This side only drives Excalidraw; the syncing (what to send, when, pictures, who's drawing)
// is in Dart. Everything crosses as JSON strings.
//
// A port of the Excalidraw half of the legacy src/client/ui/whiteboard-app.ts.

import { createElement as e } from 'react';
import { createRoot } from 'react-dom/client';
import '@excalidraw/excalidraw/index.css';
import { CaptureUpdateAction, Excalidraw, MainMenu, WelcomeScreen, exportToCanvas, reconcileElements, restoreElements } from '@excalidraw/excalidraw';

// Excalidraw's fonts come from the office, next to this bundle, never from its CDN.
window.EXCALIDRAW_ASSET_PATH ??= new URL('./', import.meta.url).href;

/** Excalidraw's styles, next to this bundle: added to the page once. */
function addStyles() {
  const href = new URL('./whiteboard.css', import.meta.url).href;
  if (document.querySelector(`link[href="${href}"]`)) return;
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = href;
  document.head.append(link);
}

const POINTER_MS = 40;

const restore = (els) => restoreElements(els, null);

/** The pictures this page has, for the window and the board in the office alike (Excalidraw's BinaryFileData). */
const files = new Map();

/** Adds pictures the office sent (a JSON array of BinaryFileData). */
export function addFiles(json) {
  const got = JSON.parse(json);
  for (const f of got) files.set(f.id, f);
  for (const app of apps) app.api?.addFiles(got);
}

/** Whether this page has the picture already. */
export const hasFile = (id) => files.has(id);

/**
 * The drawing (a JSON array of elements, deleted ones left out) as a canvas for the board in the
 * office, as big as fits in maxW × maxH pixels (small drawings are scaled up, but not past 3×).
 */
export async function renderPreview(json, maxW, maxH) {
  const live = restore(JSON.parse(json).filter((el) => !el.isDeleted));
  if (!live.length) return null;
  return exportToCanvas({
    elements: live,
    files: Object.fromEntries(files),
    appState: { exportBackground: false, exportWithDarkMode: false },
    exportPadding: 12,
    getDimensions: (w, h) => {
      const scale = Math.min(maxW / w, maxH / h, 3);
      return { width: Math.max(1, Math.round(w * scale)), height: Math.max(1, Math.round(h * scale)), scale };
    },
  });
}

/** The image elements' picture ids this page doesn't have yet (JSON array of elements in, JSON array of ids out). */
export function missingFiles(json) {
  const want = new Set();
  for (const el of JSON.parse(json)) if (el.type === 'image' && !el.isDeleted && el.fileId && !files.has(el.fileId)) want.add(el.fileId);
  return JSON.stringify([...want]);
}

// ---- Cursor colors ---------------------------------------------------------------------------------

/** Excalidraw's own hash of a collaborator id. */
function hashToInteger(id) {
  let hash = 0;
  for (let i = 0; i < id.length; i++) hash = (hash << 5) - hash + id.charCodeAt(i);
  return hash;
}

function hueOf(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b);
  const d = max - Math.min(r, g, b);
  if (!d) return 0;
  const h = max === r ? ((g - b) / d) % 6 : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return (h * 60 + 360) % 360;
}

const tints = new Map();
/**
 * Excalidraw colors each collaborator's cursor with a pastel it picks from a hash of their id, and
 * takes no color of ours. So this picks an id for them whose pastel is the nearest to their own color.
 */
function tintedId(peerId, color) {
  const key = `${peerId}|${color}`;
  let id = tints.get(key);
  if (id) return id;
  const want = hueOf(color);
  let best = Infinity;
  for (let n = 0; n < 80 && best > 5; n++) {
    const candidate = `${peerId}~${n}`;
    const off = Math.abs((Math.abs(hashToInteger(candidate)) % 37) * 10 - want);
    const d = Math.min(off, 360 - off);
    if (d < best) {
      best = d;
      id = candidate;
    }
  }
  tints.set(key, id);
  return id;
}

// ---- The window --------------------------------------------------------------------------------------

/** The mounted Excalidraws (one at most, in practice). */
const apps = new Set();

/**
 * Mounts Excalidraw in `host`. `opts`: name (for exports), elements (JSON, the board as the office has
 * it), heading (the welcome screen's), and the callbacks onChange() (something changed: call
 * takeChanges), onPointer(x, y, tool, button, selectedJson) and onReady().
 */
export function mount(host, opts) {
  addStyles();
  /** Each element's version and nonce as last sent or merged, so takeChanges hands over only what's new. */
  const seen = new Map();
  const mark = (el) => seen.set(el.id, `${el.version}|${el.versionNonce}`);
  let lastPointer = 0;
  const initial = restore(JSON.parse(opts.elements));
  for (const el of initial) mark(el);

  const app = {
    api: null,
    /** Nothing under way that Esc should finish first: no text being typed, no shape being drawn, no menu open, no tool picked. */
    idle() {
      const s = app.api?.getAppState();
      if (!s) return true;
      return (
        !s.editingTextElement &&
        !s.newElement &&
        !s.multiElement &&
        !s.selectionElement &&
        !s.editingLinearElement &&
        !s.isCropping &&
        !s.openMenu &&
        !s.openPopup &&
        !s.openDialog &&
        !s.contextMenu &&
        s.showHyperlinkPopup !== 'editor' &&
        s.activeTool.type === 'selection'
      );
    },
    /** Lets go of whatever is selected; false when nothing was. */
    deselect() {
      const api = app.api;
      if (!api || !Object.keys(api.getAppState().selectedElementIds).length) return false;
      api.updateScene({ appState: { selectedElementIds: {}, selectedGroupIds: {}, editingGroupId: null, selectedLinearElement: null }, captureUpdate: CaptureUpdateAction.NEVER });
      return true;
    },
    /** The elements changed since they were last taken or merged (all of them with `all`), as JSON. */
    takeChanges(all) {
      const out = [];
      for (const el of app.api?.getSceneElementsIncludingDeleted() ?? []) {
        if (!all && seen.get(el.id) === `${el.version}|${el.versionNonce}`) continue;
        mark(el);
        out.push(el);
      }
      return out.length ? JSON.stringify(out) : '';
    },
    /** Merges elements from the office (JSON) into the drawing; whatever you're in the middle of stays yours. */
    merge(json) {
      const api = app.api;
      if (!api) return;
      const remote = restore(JSON.parse(json));
      if (!remote.length) return;
      const elements = reconcileElements(api.getSceneElementsIncludingDeleted(), remote, api.getAppState());
      const got = new Map(remote.map((el) => [el.id, el]));
      for (const el of elements) {
        const r = got.get(el.id);
        if (r && r.version === el.version && r.versionNonce === el.versionNonce) mark(el);
      }
      api.updateScene({ elements, captureUpdate: CaptureUpdateAction.NEVER });
    },
    /** A picture as Excalidraw has it (JSON BinaryFileData), to put on the office's board; '' if there's none. */
    file(id) {
      const f = app.api?.getFiles()[id];
      return f ? JSON.stringify({ id: f.id, mimeType: f.mimeType, dataURL: f.dataURL, created: f.created }) : '';
    },
    /** Everyone else with the whiteboard open (JSON: [{id, name, color, x?, y?, tool?, button?, selected?}]). */
    setCollaborators(json) {
      if (!app.api) return;
      const collaborators = new Map();
      for (const p of JSON.parse(json)) {
        collaborators.set(p.id, {
          id: tintedId(p.id, p.color),
          socketId: p.id,
          username: p.name,
          color: { background: p.color, stroke: p.color },
          pointer: p.x == null ? undefined : { x: p.x, y: p.y, tool: p.tool ?? 'pointer' },
          button: p.button,
          selectedElementIds: p.selected ? Object.fromEntries(p.selected.map((s) => [s, true])) : undefined,
        });
      }
      app.api.updateScene({ collaborators });
    },
    unmount() {
      apps.delete(app);
      app.api = null;
      root.unmount();
    },
  };
  apps.add(app);

  const root = createRoot(host);
  root.render(
    e(
      Excalidraw,
      {
        excalidrawAPI: (a) => {
          app.api = a;
          if (files.size) a.addFiles([...files.values()]);
          opts.onReady();
        },
        initialData: { elements: initial, appState: { viewBackgroundColor: '#ffffff' }, scrollToContent: true },
        onChange: () => opts.onChange(),
        onPointerUpdate: ({ pointer, button }) => {
          const now = performance.now();
          if (now - lastPointer < POINTER_MS) return;
          lastPointer = now;
          const selected = app.api ? Object.keys(app.api.getAppState().selectedElementIds).slice(0, 200) : [];
          opts.onPointer(pointer.x, pointer.y, pointer.tool, button, JSON.stringify(selected));
        },
        isCollaborating: true,
        name: opts.name,
        theme: 'light',
        langCode: 'en',
        autoFocus: true,
        aiEnabled: false,
        // Opening a file would replace the drawing for you alone; everything else in the menu works for everyone.
        UIOptions: { canvasActions: { loadScene: false, saveToActiveFile: false, changeViewBackgroundColor: false } },
      },
      e(
        MainMenu,
        null,
        e(MainMenu.DefaultItems.SaveAsImage),
        e(MainMenu.DefaultItems.Export),
        e(MainMenu.DefaultItems.SearchMenu),
        e(MainMenu.DefaultItems.Help),
        e(MainMenu.DefaultItems.ClearCanvas),
        e(MainMenu.Separator),
        e(MainMenu.DefaultItems.ToggleTheme),
      ),
      e(
        WelcomeScreen,
        null,
        e(WelcomeScreen.Hints.MenuHint),
        e(WelcomeScreen.Hints.ToolbarHint),
        e(WelcomeScreen.Hints.HelpHint),
        e(WelcomeScreen.Center, null, e(WelcomeScreen.Center.Heading, null, opts.heading)),
      ),
    ),
  );
  return app;
}
