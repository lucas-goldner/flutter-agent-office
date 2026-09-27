# Agent Office on Flutter web + Flutter Scene

This is the plan for rewriting the Agent Office browser client, currently TypeScript, three.js and DOM, as a
Flutter web app. It renders the office in 3D with [`flutter_scene`](https://pub.dev/packages/flutter_scene).

## What moves and what stays

The office has two halves:

| Half | Today | After |
| --- | --- | --- |
| **Client**: the 3D office, HUD, windows and terminals | `src/client` (~16k lines TS, three.js, xterm.js, Excalidraw, marked, WebRTC, Web Audio) | `app/`, a Flutter web app (Dart), with the 3D scene in `flutter_scene` |
| **Server**: PTYs, agents, git, `gh`, accounts, hooks | `src/server` (Node, node-pty, ws) | **Unchanged**, apart from serving `app/build/web` instead of the Vite build |

The server has to keep running on the machine where the agents and their terminals live. It spawns PTYs, runs
`git` and `gh`, and receives hooks from Claude Code, OpenCode and Codex. A browser cannot do any of that, so "run
on Flutter web" means the client. The server stays Node for now. The client and server share one JSON
WebSocket protocol, and every message type is ported to Dart one for one, so the server doesn't need to change.
A Dart server port (`dart:io` plus an FFI PTY) is possible later but is out of scope here.

## Verified up front (the spike)

- Flutter **3.47.5 stable** and `flutter_scene` **0.23.0**. The web target uses Flutter Scene's built-in WebGL2
  backend and needs no flags.
- `flutter build web --release --no-web-resources-cdn` builds, and a lit PBR cube renders in headless Chromium
  (SwiftShader). That gives us a scripted build → screenshot loop for checking every phase.
- `--no-web-resources-cdn` matters. CanvasKit is otherwise fetched from gstatic.com, and offices often run on
  private networks or behind a VPN. The old client had no third-party runtime dependency, and neither will the
  new one.

## How each part of the client maps over

### 3D (three.js → flutter_scene)

The old world is **all procedural**. It has no .glb files and no image assets, so the port builds the same
meshes in code.

| three.js today | flutter_scene |
| --- | --- |
| `BoxGeometry`, `CylinderGeometry`, `SphereGeometry`, `CapsuleGeometry`, `TorusGeometry`, `PlaneGeometry`, `RingGeometry` | The built-in `CuboidGeometry`, `CylinderGeometry` (cones come free), `SphereGeometry`, `CapsuleGeometry`, `TorusGeometry`, `PlaneGeometry`, `RingGeometry` |
| `ExtrudeGeometry` of rounded rects, car side profiles and frames with holes | `ExtrudeGeometry` / `GeometryBuilder`, behind a `roundedBox()` helper like `toon.ts` has |
| `TubeGeometry` (string lights) | `TubeGeometry` |
| `MeshToonMaterial` with a 3-step ramp, and `OutlineEffect` | A custom toon `.fmat` / `ShaderMaterial` with 3 bands and a rim. The outline is an inverted-hull pass (back faces, pushed out along the normals) on the characters and furniture. |
| `MeshBasicMaterial` (screens, boards, glass) | `UnlitMaterial` |
| `HemisphereLight`, `AmbientLight`, and a shadowed `DirectionalLight` sun | A `DirectionalLight` with shadows plus the environment map's ambient; `SunLight` / sky for day and night |
| `Fog` | The engine's fog |
| The `onBeforeCompile` patch for lamp pools, wet ground and snow | Point lights for the lamps (froxel clustering handles 24 of them), plus parameters on the toon `.fmat` for wet ground and snow |
| Canvas-2D `CanvasTexture`s: laptop terminals, cork boards, queue and services boards, whiteboard face, jukebox display | **`WidgetComponent`**: the same boards and screens as real Flutter widgets, streamed into textures, with taps forwarded back through raycasts |
| `Sprite` name tags, task cards, chat bubbles, dog barks | Flutter overlay widgets placed by projecting each anchor's world position through the camera every frame. Text stays crisp at any distance, and there's no texture churn. |
| `InstancedMesh` confetti | `InstancedMesh` |
| `Points` stars and snow, `LineSegments` rain | Particles / `InstancedMesh` quads |
| `VideoTexture` of the WebRTC screen share on the lounge TV | An external-texture / `WidgetComponent` of an `RTCVideoView`. If that's too slow on WebGL2, the TV shows a live thumbnail card and the full-screen viewer shows the video. |
| `Raycaster` with `userData.interact` tags | `scene` raycast picking, with an interactable map keyed by node |
| First-person hands drawn as a second pass after `clearDepth` | A second `SceneView` layer, or nodes parented to the camera |
| Pointer lock | `package:web` `requestPointerLock` on the Flutter view |

### 2D (DOM → Flutter widgets)

| Today | Flutter |
| --- | --- |
| HUD, side panels, chat, toasts, all modals | Widgets in a `Stack` over the `SceneView`, themed to match `style.css`: paper `#fffaf3`, ink `#2b2d42`, 3px borders, hard offset shadows, Nunito |
| xterm.js (raw PTY bytes, plus `term.snapshot` replay) | The pure-Dart [`xterm`](https://pub.dev/packages/xterm) package, fed the same bytes. The fallback is xterm.js in an `HtmlElementView`. |
| marked + DOMPurify | `markdown` + `flutter_markdown_plus` (GFM, with custom syntaxes for alerts, `#123` and `@user`) |
| WebRTC voice and screen share (perfect negotiation over `rtc` messages) | `flutter_webrtc`, which wraps the browser APIs, plus a small `package:web` shim for per-peer volume and speaking levels |
| Web Audio synthesis (`sound.ts`, `music.ts`, all procedural) | A straight port to Dart on `package:web`'s typed `AudioContext` / `OscillatorNode` / `BiquadFilterNode` |
| Excalidraw (React) | **Kept as JS.** The bundle is mounted in an `HtmlElementView` and bridged with `dart:js_interop` (`updateScene`, `onChange`, `exportToBlob`). Nothing in Dart comes close. |
| DEADFALL `<iframe>` | An `HtmlElementView` iframe over the boss monitor |
| Notifications, clipboard, localStorage | `package:web` `Notification`, `Clipboard`, and `shared_preferences` |
| Login, join and claim pages | Flutter routes in the same app, `/login`, `/join#token` and `/claim?t=` |

### Server changes (small, and backwards compatible)

1. `findPublicDir()` also accepts `app/build/web`, and `npm run build:client` runs
   `flutter build web --release --no-web-resources-cdn -o dist/public`.
2. Flutter's bootstrap files (`flutter_bootstrap.js`, `main.dart.js`, `canvaskit/`, `assets/`, `manifest.json`,
   `version.json`, `favicon.png`, `icons/`) are served without a session, so `/login` can load the app.
3. `/login`, `/join` and `/claim` serve `index.html`, and the Flutter router reads the path.
4. MIME types for `.mjs`, `.wasm`, `.otf`, `.ttf`, `.bin` and `.webmanifest`. Flutter's unhashed `assets/` must not
   get the one-year `immutable` cache header that Vite's hashed `/assets/*` has now.
5. Dev: `npm run dev:flutter` runs the server, which serves the Flutter build (`flutter build web` in watch mode,
   or `flutter run -d web-server` behind the server's proxy), so `/ws` and `/api` stay same-origin for the cookie.
6. The whiteboard's Excalidraw bundle: `npm run build:whiteboard` (scripts/build-whiteboard.mjs, esbuild from
   the repo's node_modules) bundles React 18, Excalidraw 0.18 and the bridge (`app/excalidraw/bridge.js`) into
   `app/web/excalidraw/`: `whiteboard.js` (an ES module, ~0.7 MB, plus ~3 MB of chunks it imports), `whiteboard.css`
   and Excalidraw's fonts (no Xiaolai, no other languages), so they're served by the office, never a CDN.
   `flutter build web` copies it into `build/web/excalidraw/`, and the app imports it only when the whiteboard is
   first needed. `npm run build:flutter` runs it first. It's ~7 MB in ~180 files, so it's gitignored: after a
   bare `flutter build web` without it, the whiteboard window says it couldn't load and the board stays blank.

## App layout (`app/lib`)

```
main.dart                 routes: /login /join /claim → pages, / → OfficeApp
shared/                   1:1 Dart ports of src/shared (protocol, layout, nav, avatar, floors, decor,
                          dog, jukebox, status, sun, search, whiteboard), unit tested like the TS
net/                      OfficeSocket (ws + reconnect + whoami), Api (REST)
state/                    Store (ChangeNotifier per topic, port of state.ts apply())
world/                    the flutter_scene side, one Game class owning the Scene
  office_world.dart       builds the floor, owns colliders/interactables, per-frame tick
  toon.dart               toon material, roundedBox, merge helpers
  office/ …               walls, desks, lounge, kitchen, loft, elevator, gong, whiteboard, balcony
  outside/ …              street, garage, cars, sky/weather
  character.dart          Person + Worker (procedural chibi rig and animation)
  laptop.dart             lid + WidgetComponent terminal screen (port of paintScreen)
  boards.dart             cork/services/queue boards as WidgetComponents
  player.dart             PlayerController (port of player.ts collisions/jump/stairs/seats)
  labels.dart             projected overlay labels/cards/bubbles
ui/                       HUD, chat, toasts, modals (terminal, pull, pulldiff, changes, queue, …)
audio/                    sound + music synthesis on Web Audio
interop/                  pointer lock, notifications, Excalidraw bridge, arcade iframe
```

## Phases

Each phase ends with `flutter analyze`, the Dart unit tests, `flutter build web`, and headless screenshots of
the office against a real `agent-office` server.

0. **Spike.** ✅ Toolchain, a web build and a render check.
1. **Foundation.** Dart ports of `src/shared` with the TS tests ported. `OfficeSocket` and `Store`. Login, join
   and claim. The server serves the Flutter build. The theme.
2. **The walkable office.** Floor, walls, windows, desks, chairs, lounge, kitchen, loft, stairs, balcony,
   elevator, gong, whiteboard frame, in the toon look. `PlayerController`, with collisions, stairs, jumping and
   the first- and third-person cameras. Peers drawn as characters with name tags, moving in real time.
3. **Workers and terminals.** Worker characters with status bulbs and task cards. Laptops showing their live
   `screen` frames. The xterm terminal window. Hire, prompt, resume, send home, worktrees and PRs (E/P/B/R/X/O),
   the workers panel, notifications, and the tab title.
4. **Boards and GitHub.** Issues, PR, services and queue boards. Issue and PR windows with markdown, diffs,
   reviews, merge and close. Ask-a-worker, the queue, services, changes, and the gong with confetti.
5. **People.** Chat and bubbles, voice, screen sharing and the TV, search, accounts, invites, settings,
   character select, upgrade.
6. **The rest of the world.** Sky, weather and day/night, the street, garage and cars, the dog, jukebox and music,
   office sounds, smoke breaks, coffee, sitting, floors and the elevator ride, workers leaving, hung pictures,
   the Excalidraw whiteboard, DEADFALL, first-person hands.
7. **Cutover.** `package.json`, CI and the release build Flutter. Delete `src/client`, Vite and three.js.
   Update the README. Run a perf pass with the render-quality tier and adaptive scale, and throttled widget
   captures for off-screen laptops.

## Risks and fallbacks

- **The toon look and ink outlines.** Flutter Scene has no toon material, so this is a custom `.fmat`. If the
  inverted-hull outline costs too much on WebGL2, outlines go on characters only.
- **WebGL2 performance** with ~40 live widget textures (laptops and boards). Captures are throttled by distance,
  as `laptop.ts` already does: 150 ms, 600 ms or 2 s, and manual capture for boards on store changes.
- **The TV video texture.** The fallback is described above.
- **xterm fidelity for full-screen TUIs** (Claude Code, OpenCode). The fallback is xterm.js through interop.
- **Excalidraw** stays JS. It is the one large JS dependency left.
