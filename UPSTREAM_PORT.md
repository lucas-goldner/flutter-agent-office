# Porting upstream's 58 commits (e41436e..upstream/main) — done

Upstream (AgentSystemLabs/agent-office, remote `upstream`) kept building the TypeScript office after
this fork moved to Dart + Flutter. Its history is merged (01a19ed); its features are ported here.
Read upstream's code from git, e.g. `git show upstream/main:src/client/world/rooftop.ts`,
`git show <sha>` for one commit, `git diff e41436e upstream/main -- src/server/workers.ts`.

Phase 1 (done, 88fcc19): all of `src/shared` is in `packages/office_shared` — every new message
(`ClientMsg.parse` covers all client messages; `ServerMsg.parse` all server ones), field, layout
constant (rooftop, stations, meeting room, ladder, poles, cabinet, bookshelf, hoop, golf, parachute,
`storey`, `roofDrop`), and rule (actions, cabinet, docs, emotes, hoop physics, meetings, prompts,
rooftop drinks, holiday themes). Renames: `HolidayTheme` (TS Theme), `launchBall`/`stepBall`,
`cabinetGame`. Use these; don't redeclare.

## Conventions

- Server: see `server/README.md` (one Dart file per TS module, same wire JSON and files on disk).
- Client: see `FLUTTER_WEB_PLAN.md` ("How each part maps over", "Where it ended up"). Key points:
  the office hangs under a mirrored root (`world/space.dart`), so ported three.js numbers stay as they
  are — never rotate things to "fix" handedness; toon materials (`world/toon.dart`); labels are Flutter
  widgets over the scene (`world/labels.dart`); 3D screens/boards are `WidgetComponent`s; the second
  RenderView for hands (`world/hands.dart`); `office/controller.dart` is the port of `main.ts`; HUD in
  `ui/hud.dart`; windows use `ui/modal.dart`; look in `ui/theme.dart`.
- The client also builds natively (macOS). Browser-only code goes behind the existing
  `x.dart` → `x_web.dart` / `x_stub.dart` conditional exports. Sound on native is
  `audio/sound_native.dart` (the same API as `audio/sound_web.dart`): each Web Audio graph is ported
  to the offline synth (`audio/synth.dart`, `audio/office_render.dart`, `audio/music_render.dart`)
  and played through flutter_soloud; a change to a sound in `sound_web.dart` needs the same change there.
  `test/native_compile_test.dart` fails if web-only imports leak into main.
- Checks before you're done: `dart analyze` + `dart test` in server/ and packages/office_shared;
  `flutter analyze lib test` + `flutter test` in app/; `dart format -l 120` on files you touch.

## Groups

| Group | Commits (upstream PR numbers) |
|---|---|
| S1 server: workers & agents | #76 board agents/stations, #86 office-queue (→ `agent-office queue` subcommand), #85 OpenCode mouse encoding (screen.ts), #79 #88 model/effort/agent-args, #92 machine limits (machine.ts), #105 meetings (meetings.ts), #137 prompts (prompts.ts, tasks), #141 leave-on-merge, #140 upgrades keep workers, #91 #95 #97 worker fields (waitingSince, viewerIds, typing, action), #117 queue limit |
| S2 server: building & extras | #96 #107 cabinet (arcade high scores), #133 court (hoop ball), #138 docs, #106 theme, #101 projects dir, #126 floor remove, #139 onboarding (setup.ts) + removable start-in project, #113 changed images, #135 #136 GitHub labels, #145 secure by default (auth/cli/config/team/upgrade), #90 emotes, #93 carry, #132 golf, #108 #111 roof/drinks relays, #94 #109 floor.go at |
| C1 client: HUD & settings | #100 ☰ menu + quiet HUD, #94 floors dropdown, #112 #115 fff492d Esc/✕/mouse, #127 #126 #139 elevator (top floor first, remove with a 💣 and an explosion, onboarding), #101 #106 #92 #129 #141 #137 #79 #88 settings/prompts/provider model+effort, #116 queue UI, #140 upgrade UI, #145 login, 2b11a97 556a045 worker counts |
| C2 client: boards & presence | #135 #136 label filter/edit, #80 worker on issue, #93 carry a card, #110 take a note, #113 changed pictures, #95 whereabouts/terminal typing/presence, #91 N next-up + compass, #117 worker bubble PR, #98 |
| C3 client: building & outside | #99 ceiling, #94 #104 #128 ladder/climb + fire poles (stack/climb), #109 #114 tower/city/outside/sky + roof height, #109 parachute (leaving) |
| C4 client: rooftop bar | #108 #111 rooftop, DJ + drum and bass (dnb.ts, music), drinks/drunk, bar UI, city from the roof |
| C5 client: characters | #90 emote wheel, #97 workers act out, #103 dance party + confetti, #106 costumes + holiday decorations (holiday.ts, costumes.ts, dog, sky), edfdeaa, #93 card in hands |
| C6 client: games & rooms | #74 minesweeper, #96 #107 cabinet + blocks, #133 hoop, #132 golf, #138 bookshelf + book, #92 machine monitor, #105 meeting room (world + ui/meeting), #76 #75 kiosks/queue board placement |

Left out for now: Windows (#78, #102) — the PTY layer is Unix-only.

## Where it ended up

All eight groups are ported and merged (server 238 tests, office_shared 77, app 355). Known gaps, from
the groups' reports:

- Not seen on a real screen yet (this sandbox renders in software): the held issue card, compass pins,
  holiday decorations, emote poses, golf, the hoop, the drunk screen effect.
- Simplified visuals: Halloween's gradient sky dome, halos round pumpkins, tree and roof string lights,
  witch-fire as spheres, cobwebs as strips; the drunk double-vision is a sway/blur/warm vignette.
- Not done: books, balls and clubs in hands (throws and swings use the reach animation) and seeing
  others read; golf sounds, the green's colliders, the flag; golf assumes the bottom floor
  (`streetBelow(0)`) rather than following `Office.setLevel`; climbing sounds and hands on the
  ladder/pole; the meeting-table cards and meeting presets from issues/PRs; the garage lamplight in the
  toon shader on upper floors; the hiccup camera jolt.
- `provision.sh` still needs `deploy/aws.sh` (upstream's #145 made it standalone with Caddy).
- Windows (#78, #102): the PTY layer is Unix-only.
- `docs/` came from upstream as-is and still describes the Node install in places.
