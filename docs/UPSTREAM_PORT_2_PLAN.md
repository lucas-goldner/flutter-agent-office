# Port 2: upstream 44aecc1..upstream/main (77 commits) — server and client plan

Repo: `/home/user/flutter-agent-office`. Upstream remote `upstream` (AgentSystemLabs/agent-office) is fetched.
Read upstream code with `git show upstream/main:<path>` and one commit with `git show <sha>`.
`git log --no-merges --reverse 44aecc1..upstream/main` lists the commits.

Every group below gets its own worktree, **branched from `port2/shared`**. That branch holds the
`packages/office_shared` port of `src/shared` (the protocol split into domains, providers, maps, garage,
scenic, bargames, palette, floorplan, drops, rng, sun, avatar and so on). **Use those types and messages
as they are. Don't redeclare them.** If something shared is missing, add it in `office_shared` in your own
branch and mention it in your report, because the shared agent may have named it differently.

Conventions are in `UPSTREAM_PORT.md`, `server/README.md` and `FLUTTER_WEB_PLAN.md`. In short: the
server has one Dart file per TS module and keeps the same wire JSON and files on disk. The client runs
under the mirrored root (`world/space.dart`), uses toon materials (`world/toon.dart`), and draws labels as
Flutter widgets (`world/labels.dart`). `office/controller.dart` is the port of main.ts and `ui/modal.dart`
holds the windows. Any change to a sound in `audio/sound_web.dart` also needs the same change in
`audio/sound_native.dart`, `audio/office_render.dart` and `audio/synth.dart`. Web-only code goes behind the
`x.dart` → `x_web.dart`/`x_stub.dart` exports, and `test/native_compile_test.dart` guards that.

Run these checks before you're done:
- `dart analyze` and `dart test` in `server/` and `packages/office_shared`
- `flutter analyze lib test` and `flutter test` in `app/`
- `dart format -l 120` on the files you touch

Toolchain: `export PATH=/opt/flutter/bin:$PATH`.

---

## 0. Overview

| Group | Scope (one line) | Size |
|---|---|---|
| S1 | Server workers and harnesses: a provider-adapter table plus Grok, Muse, DeepSeek (ACP), Pi and Cursor; model and effort for every harness; worktree fetch; lost-worktree rebuild; issue claim; older gh; Codex needs-input fix; meetings without a budget | XL |
| S2 | Server agents and repos: `agent-office workers` CLI and MCP server, PR ownership, following a worker's own branch, multi-repo workers, clone progress | L |
| S3 | Server ops: per-account sign-ins, `agent-office tunnel`, Tailscale, drops endpoint, come back where you left, sky clock loop and real-time setting, TURN env, deploy scripts and container, docs | L |
| S4 (new) | Server world state: maps, jail, floorplan (desk signs and back office), garage cars, `toss` relay, dog breed and coat, `lite` peers, `sit.refused` | M |
| C1 | Client UI: settings categories, command palette, dictation, terminal upgrades, board filters, random names, closable modals, needs-you, meetings, issues pins, page-turn swish, clone UI, sign-ins UI, tunnel and Tailscale UI, multi-repo UI, provider pickers, lost-worker dialog, mouse fixes, floor switch into the elevator, come back where you left | XL |
| C2 | Client maps: the World abstraction, the castle (throne, herald, court line, aging peasants), the dungeon and jail, the space station and airlock, maps of your own | XL |
| C3 | Client places and driving: garage cars, scenic loop, elevator down to the garage, solid neighbours, desk signs and back office, darts and axes, telescope, meeting-table sizes | XL |
| C4 | Client models and visuals: GLB pipeline (dogs, kitchen, lounge, plants, desk props) and loading screen, dog breed and coat setting, first-person body and hands, lamplight, sky on the clock, fog, holiday outfits, footsteps, drunk warmup, phone ring removed, sign and glass z-fighting | L |
| C5 (new) | Client `/lite` 2D view for phones and slow machines (#182). Nothing in the original list covered it. | M |

**Moved and added since the original list:**
- **New group S4.** These items are server code: `server/{maps,jail,floorplan,garage}.ts`, the `toss` relay, and the dog breed and coat.
- **New group C5.** It covers `/lite` (3cbf451, #182).
- **Fridge (#156) and dog leg (#148): C3 → C4.** #186 replaces the code-built kitchen with `kitchen.glb`, which includes the retro fridge. #177 replaces the code-built dog with skinned GLBs. Both fixes only matter if C4 falls back to the code-built meshes.
- **Meetings budget removal (#264), server side: in S1.** The client side is in C1.
- **Terminal "Hide" button (#322, part of 60a74b4): in C1.** The server part is in S1.

**Merge order: S1 → S2 → S3 → S4, then C1 → C2 → C3 → C4 → C5.** Each later branch rebases on the
earlier ones. The client groups can merge in any order once the server groups they need are in. C1
merges first because it rewrites `ui/settings.dart`.

**Conflict hotspots.** Everyone touches these files. Keep edits there small and put new code in new files.
- `server/lib/src/workers.dart`: S1 restructures it, and S2, S3 and S4 add to it.
- `server/lib/src/server.dart`: all four server groups.
- `app/lib/office/controller.dart`: all five client groups.
- `app/lib/ui/settings.dart`: C1 restructures it, and C2 and C4 add rows.
- `app/lib/ui/elevator.dart`: C1 (clone progress, floor switching) and C3 (Garage stop).
- `audio/*`: C1 (swish, needs-you alarm), C3 (cars, darts), C4 (footsteps, phone) and C2 (castle and station ambience).

**How S1 helps the others.** S1 should commit the provider-adapter refactor of `workers.dart` first, as a
pure move with no behaviour change, and push it early. S2 and S3 rebase onto that commit before they
touch launch or hook code.

### Cross-group dependencies (needs → from)
- **C1 provider and model pickers** need S1's `GET /api/agents/<provider>/models` and the new providers' wire values (shared `providers`).
- **C1 lost-worker dialog** needs S1's `WorkerInfo.lost` and `worker.rebuild` handling.
- **C1 "In progress" moves and 🤖 Hand to a worker** need S1's `GitHub.claim` and the `issue` field on `worker.spawn` and `worker.prompt`.
- **C1 meeting form** needs S1 (and the shared meetings module) to drop `budget`.
- **C1 clone progress** needs S2's `FloorInfo.clone` (CloneProgress) and `floor.cancel`.
- **C1 multi-repo UI** needs S2's `repos` on `worker.spawn` and per-repo changes, worktree state and PRs.
- **C1 sign-ins window** needs S3's `signins*` messages and the server SignIns.
- **C1 terminal drops** need S3's `POST /api/term/drop`.
- **C1 Services panel** needs S3 for the tunnel command, the tailnet addresses and the deploy-script hints.
- **C1 come back where you left** needs S3 to read `x,y,z,rotY` on the WebSocket connect query and send you to the roof when your floor is gone.
- **C1 TURN toast** needs S3's `AGENT_OFFICE_TURN` in the ICE config.
- **C2** needs S4's `map`/`map.set` state, seat checks (`sit.refused`), `worker.remove{jail}`, `JailState` in the welcome, `workedMs`/`workingSince` on WorkerInfo and `via:'herald'` on `worker.spawn`.
- **C2 settings map picker** needs C1's settings category API.
- **C3 cars** need S4's `car.*`/`cars`.
- **C3 darts and axes** need S4's `toss` relay and the `throwing` field on peers.
- **C3 desk signs and back office** need S4's `desk.label`, `floor.expand`/`floor.shrink` and `plan`, plus shared `nav`/`layout` wing.
- **C4 dog** needs S4's `dog.breed`/`dog.coat` and the breed in DogState.
- **C4 sky** needs S3's `sky.clock` and the skyTime loop. Shared `sun.dart` holds `skyTime`.
- **C4 settings rows (dog, sky)** need C1's settings category API.
- **C4 footsteps by surface** need surfaces from C2 (flagstones) and C3 (garage concrete, grass on the scenic loop). Start with a surface function and defaults, and refine once those land.
- **C5** needs S4's `lite` peer flag and the `/lite` route and redirect. It shares terminal code with C1 (keypad, termtheme), so C5 should merge after C1.
- **C2 ↔ C3 ↔ C4, through C2's World interface.** C2 introduces it in `controller.dart`. C3's back office (wing nav, beanbags) and C4's lamplight, fog and footsteps must go through it once it lands. Agree that C2 defines `app/lib/world/world.dart` early and pushes it.

### Where things moved in the refactor 650e872 (#215). Don't port the structure, just find the code there.
- `src/client/main.ts` was split into `src/client/core/*` (arrival, travel, loop, registry, worlds, maps, parts, place, you, hint, hintbar), `src/client/features/<name>/{index,world,ui,sound,controller}.ts`, `src/client/input/*` and `src/client/player/*`.
- `src/client/sound.ts` became `src/client/sound/*`. `state.ts` became `state/{core,persist,store}.ts` and `state/slices/*`.
- `world/character.ts` became `world/character/{person,worker,person-*,worker-*,rig,props,curves}.ts`. `world/office.ts` became `world/office/*`. `world/castle.ts` became `world/castle/*`. `world/scenic.ts` became `world/scenic/*`.
- Moves into features: `throwing.ts` → `features/bargames/controller.ts`, `world/bargames.ts` → `features/bargames/world.ts`, `driving.ts` → `features/cars/controller.ts`, `world/cars.ts` → `features/cars/world.ts`, `laps.ts` → `features/cars/laps.ts`, `telescope.ts` → `features/telescope/controller.ts`, `world/dog.ts` → `features/dog/world.ts`, `world/jail.ts`/`sendhome.ts`/`leaving.ts`/`laptop.ts` → `features/workers/*`, `ui/pulldiff.ts` → `ui/github/pulldiff.ts`. The rest of `pull.ts` was split into `ui/github/*`.
- `src/server/server.ts` became `src/server/{http/*,ws/*,office/*,hooks/*}`. `workers.ts` became `workers/*` (manager, lifecycle, persist, pr, process, terminal, tasks, worktree, acp, env, types) and `providers/*` (claude, codex, opencode, grok, muse, dsh, pi, cursor, custom, types, index).
- `src/shared/protocol.ts` became `src/shared/protocol/*`. Provider metadata moved to `src/shared/providers.ts`.

### Commits that need nothing
| SHA | Why |
|---|---|
| 650e872 (#215) | Restructuring only; see the moves above. Its `rng.ts` is in shared. Its server-dispatch, client-registry, client-store and size tests are TS-only. |
| 4f50d4e (#190), 4e339df (#263) | CLAUDE.md and AGENTS.md for the TS repo. S3 can adapt the rules to this repo's own AGENTS.md/CLAUDE.md (Dart verify commands); that's optional. |
| 0c3b374 (#294) | npm 12 lockfile fix in install.sh and install.ps1. Our install.sh installs a Dart release with no npm. |
| b47eba6 (#224) | Windows `npm run dev` stdin hang. Dart's `stdin.hasTerminal` doesn't open the stream. S3 should check `setup.dart` for 2 minutes and otherwise skip it. Windows PTY is unsupported anyway. |
| e4bafed (#201) | `railway whoami --json`. Take it as part of S3's copy of railway.sh, not as a separate change. |
| Parts of 1bc3028 (#213) | `ptys.ts` resolving a relative `--import` from the office's cwd. That's Node test setup. The visual part is in C4. |
| `blender/`, `src/client/lab/*`, `tests/glb.ts`, `*-model.test.ts`, `loading.test.ts` | Model build scripts and labs. The GLBs are the artifacts. C4 may copy `blender/` verbatim for reference (it's Python, so it isn't part of any build). |
| vite, tsx and `package.json` changes in any commit | TS tooling. |
| `docs/dsh-acp-integration.md` | Design doc. S1 should read it; it doesn't need porting. |

### Binary assets (all in C4)
The ten GLBs are all binary assets; there are no new sounds or textures, because everything else is
synthesized or drawn in code. Copy them from upstream into `app/assets/models/` and list them in
`app/pubspec.yaml`. `git show upstream/main:<path> > app/assets/models/<name>` writes the bytes.

| Upstream path | Bytes |
|---|---|
| src/client/models/dog-pup.glb | 511,704 |
| src/client/models/dog-corgi.glb | 538,792 |
| src/client/models/dog-dachshund.glb | 504,656 |
| src/client/models/dog-pug.glb | 518,840 |
| src/client/models/dog-shiba.glb | 539,180 |
| src/client/models/dog-pomeranian.glb | 546,696 |
| src/client/models/kitchen.glb | 202,204 |
| src/client/models/lounge.glb | 124,704 |
| src/client/models/plants.glb | 313,304 |
| src/client/models/desk_props.glb | 68,360 |
| **Total (10 files)** | **3,868,440 bytes (about 3.69 MiB)** |

The maps also have data files, which are JSON rather than binary: `docs/maps.md` and the
`docs/maps/castle.json` and `docs/maps/station.json` examples. C2 copies them into `docs/` (S4's tests may
load them too).

---

## S1. Server: workers and harnesses (XL)

**Commits**

| SHA (PR) | What |
|---|---|
| 1dcdc52 (#187) | Grok and Muse providers, isolated homes, live status |
| 0378130 (#130) | DeepSeek Harness (DSH) over ACP |
| 2de6bdc (#202) | Pi CLI workers |
| 31afe0f (#271) | Cursor CLI workers |
| b5acbee (#272) | Model and reasoning effort for every harness; `/api/agents/<provider>/models` |
| 1b70be3 (#170) | Worktrees start from origin; fetch before hires, queue and meetings; Changes diffs against the newer of main and origin/main |
| 13c104e (#197) | Workers whose worktree was deleted outside the office become `lost` and can be rebuilt with `worker.rebuild` |
| 6fa06d7 (#268) | Issues move to In progress at once: `GitHub.claim` with a Claims overlay, and `issue` on `worker.spawn` and `worker.prompt` |
| 496a030 (#323) | PR board on older gh: fall back on "Unknown JSON field"; `friendlyGhError` |
| 60a74b4 (#322), server part | Codex clears `permissionUnknown` when no tools are pending |
| 773fe19 (#264), server part | Meetings have no token budget |
| 8631789 (#265) | Shared only (fixed round limits explained). Nothing to do on the server unless shared changed signatures. |

**Upstream files to read (at upstream/main)**
- Adapter design:
  - `src/server/providers/{types,index,claude,codex,opencode,grok,muse,dsh,pi,cursor,custom}.ts`
  - `src/server/workers/{manager,lifecycle,env,process,terminal,acp,persist,types,worktree}.ts`
- Providers:
  - `src/server/grok.ts` (206 lines), `muse.ts` (274), `pi.ts` (104), `cursor.ts` (299)
  - `dsh.ts` (1148), plus `docs/dsh-acp-integration.md` (read "The ACP surface", "Mapping", "Phase 0 findings")
  - `src/server/models.ts` (224), `codex.ts` (187), `opencode.ts` (327), `agents.ts`, `config.ts` (provider flags such as `--dsh-profile`)
  - `src/server/http/routes/agents.ts`, `src/server/usage.ts`, `reported-usage.ts`
- Worktrees: `src/server/worktrees.ts`. `git show 1b70be3 -- src/server` and `git show 13c104e -- src/server` give the diffs.
- GitHub:
  - `src/server/github.ts`, `src/server/office/gates.ts`, `src/server/office/context.ts`
  - `git show 6fa06d7 -- src/server`, `git show 496a030 -- src/server`
- Meetings: `git show 773fe19 -- src/server src/shared`. Also `src/server/meetings.ts` and `queue.ts`, which pick providers and fetch.

**What to build (Dart)**

1. **Provider adapters.** Create `server/lib/src/providers/` with `provider.dart`, the `ProviderAdapter`
   interface that mirrors `providers/types.ts`. Its members: `scrubEnv`, `prepare(floor)`,
   `launch(LaunchInput) → LaunchPlan`, `exited`, `transport` (pty or acp), `signIn`, `bootHint`,
   `titleNoise`, `freshIfResumeFails`, `hook` (`strictJson`, `handle`), `hooksAs`, `screen`
   (progress, blocked), `usage` and `namesTasks`.
   - Add one file per provider: `claude.dart`, `codex.dart` (moved from `workers.dart`), `opencode.dart`, `grok.dart`, `muse.dart`, `dsh.dart`, `pi.dart`, `cursor.dart` and `custom.dart`, plus a `providers.dart` registry with `providerAdapter`, `providerHook` and `titleNoise`.
   - Move the `if provider == …` branches in `workers.dart` into the adapters. Today they're at about lines 349, 455-560, 896-1136, 1264-1500 and 1700-1780.
   - Do this as **commit 1, with no behaviour change**, and push it so the other server groups can rebase.
   - Keep `childEnv` scrubbing, built from every adapter's `scrubEnv`. Upstream has this in `workers/env.ts`.
2. **Lifecycle reducer.** Port `workers/lifecycle.ts` to `server/lib/src/lifecycle.dart`: `reduceLifecycle`, `midTurn` and `LATE_PROMPT_GRACE_MS`. Codex, Grok, Muse and Cursor all use it.
3. **Hook helpers without Node.** Upstream writes `.cjs` helpers that run under `process.execPath`. Use the office's own executable instead:
   - Extend `hook.dart` with `agent-office hook grok <event>`, `agent-office hook muse <event>` and `agent-office hook cursor <event> <workerId>`.
   - Each one ports that provider's `*_HOOK_SOURCE` filtering: bounded stdin, drop child or subagent events, POST to `/hooks/<provider>?worker=…&event=…`.
   - Write the hook config files that point at `officeCommand()`:
     - Grok: `grok-home/hooks/agent-office.json`.
     - Muse: XDG `config/muse` hooks.
     - Cursor: `<cwd>/.cursor/hooks.json` merge and unmerge, with a git exclude.
   - Register `/hooks/grok`, `/hooks/muse`, `/hooks/pi`, `/hooks/cursor` and `/hooks/dsh` (if any) in `server.dart`'s hook port. Today that list is at about line 592.
   - Pi loads its JS extension (`agent-office-pi-extension.mjs`) itself, because Pi is a Node CLI. Keep the JS source as a Dart string. The OpenCode plugin is done the same way already.
4. **Isolated homes.**
   - Grok: `<data>/grok-home` as `GROK_HOME`, with `GROK_AUTH_PATH` taken from `~/.grok/auth.json`, plus `--no-alt-screen --trust --leader-socket`, `--session-id` and `--resume`.
   - Muse: XDG config, data and state under `<data>/muse-home`, with `~/.config/muse/auth.json` linked in. On resume, paste the prompt after SessionStart (`pendingPrompt`).
   - Pi: `pi-sessions/<workerId>`, plus `--session-dir`, `--session-id` and `--extension`. A prompt that starts with `@` gets a leading space.
   - Cursor: `--trust`, `--resume=<chatId>` and `--model`. Read the blocked login screen with `cursorBlocked`.
5. **DSH over ACP** (`server/lib/src/dsh.dart`, the largest single piece).
   - Run `dsh --profile acp` as a child `Process`, not in the PTY host. Speak JSON-RPC over stdio: `initialize`, `session/new` or `session/load`, `session/prompt`, `session/request_permission` and `session/set_config_option`.
   - Render the transcript into the worker's in-process headless terminal (`headless.dart`). Strip C1 controls and bidi characters.
   - Answer approvals from terminal input: Enter approves only an allow-once choice.
   - Report status, actions, usage and the session id.
   - It does not survive an office restart the way PTY workers do. It resumes with `session/load`, as upstream does.
   - `tests/dsh.test.ts` (903 lines) is the spec. Port its fake ACP peer.
6. **Models and efforts** (`models.dart`).
   - Add `fetchGrokModels` (`grok models`), `fetchCodexModels` (`codex debug models`, with the efforts each model supports), `fetchCursorModels` (`cursor-agent models`) and OpenCode with variants. Generalise the catalogue (`createModelCatalogues`) per provider, with a 60 s TTL.
   - Route: `GET /api/agents/<provider>/models` → `{models: [{id, name, efforts}]}`, a 404 for an unknown provider, and a 502 with "Could not load X models" on failure. This replaces the single OpenCode route in `server.dart` (about line 1099).
   - Every provider takes model and effort on its command line:
     - Codex: `--model` and `-c model_reasoning_effort`, on resume too.
     - OpenCode: the effort is the model variant, set by the plugin on the first message.
     - Claude: aliases.
     - DSH: `set_config_option`.
   - Validate per provider with the `*_MODEL_MAX` constants (`agents.dart`'s `validateWorkerModel` and `validateWorkerEffort`).
7. **Config.**
   - Upstream adds `--dsh-profile`, provider executables (`cursor-agent` is not its provider id) and default-provider validation (`config.ts` diff).
   - `agentProviders()` lists every installed provider.
   - Add meeting, queue and restore support for the new providers (`meetings.dart`, `queue.dart`, persistence in `workers.dart`'s `_persist` and restore).
8. **Worktrees from origin** (`worktrees.dart`).
   - `fetch()`: `git fetch origin <branch>` with no prompts (`GIT_TERMINAL_PROMPT=0`, ssh BatchMode), a 15 s timeout, one fetch shared by a burst of hires, logged once on failure.
   - `create()`: branch from `origin/<branch>` unless HEAD already contains it. When both have moved, use origin's and return a toast saying what was left out.
   - The queue fetches before seating a worktree task. Hand hires and meetings await the fetch.
   - `changes.dart`: diff against the newer of `main` and `origin/main`.
9. **Lost worktrees.**
   - At start, a worker whose worktree or workspace folder is gone gets `lost: {branch: here|origin|gone}` and stays asleep, with no "could not start" toast.
   - Handle `worker.rebuild {workerId, all?}`: recreate the worktree on its branch, or origin's copy, or fresh from its base, then start it.
   - `office-workers` shows "deleted" (S2 consumes `WorkerInfo.lost`).
10. **Issue claim** (`github.dart`).
    - `claim()` marks the issue taken for everyone on the floor before gh answers, holds a Claims overlay over stale lists, and rolls back with a warning if gh fails.
    - A refresh requested during a claim waits for it and then looks again.
    - `worker.spawn` and `worker.prompt` with `issue` claim it and take it off the queue.
11. **Older gh.** Use `PULL_LIST_FIELDS`. On `Unknown JSON field: "x"`, drop that field (unless it's in the required set) and retry. Add `friendlyGhError`.
12. **Codex needs-input fix.** In the Codex tool tracker, `if (tools.isEmpty) permissionUnknown = false` on PostToolUse. Port the new workers test (station agent: PreToolUse → PermissionRequest → PostToolUse → working).
13. **Meetings.** Remove `budget` everywhere: the request, the Meeting, the stop reason and `{{budget}}`. The sum of usage stays. Shared meetings and prompts change with it (the shared agent does that part).

**Dart files to touch**
- `server/lib/src/workers.dart` (split), plus new `providers/*.dart`, `lifecycle.dart`, `grok.dart`, `muse.dart`, `pi.dart`, `cursor.dart`, `dsh.dart` and `acp.dart`
- `hook.dart`, `models.dart`, `agents.dart`, `config.dart`, `server.dart` (hook routes, the models route, `worker.rebuild`, `issue`), `worktrees.dart`, `changes.dart`, `github.dart`, `queue.dart`, `meetings.dart`, `codex.dart`, `opencode.dart`, `usage.dart`, `reported_usage.dart`, `bin/agent_office.dart` (hook subcommands)

**Upstream tests to port**
- New: `tests/grok.test.ts` (111 lines), `muse.test.ts` (123), `pi.test.ts` (137), `cursor.test.ts` (231), `dsh.test.ts` (903) and `worktrees.test.ts` (165)
- Diffs since 44aecc1 in `models.test.ts`, `agents.test.ts`, `codex.test.ts`, `opencode.test.ts`, `queue.test.ts`, `meetings.test.ts`, `usage.test.ts` and `github.test.ts`
- The workers.test.ts cases for: lost/rebuild, Grok and Muse status, Cursor hooks.json, Codex station needs-input, and fetch before hire
- Put them in `server/test/<name>_test.dart`, next to the existing `workers_test.dart`, `models_test.dart` and the others.

**Gotchas**
- No Node on the machine. Every `process.execPath <helper>.cjs` must become `agent-office hook …`. Pi's and OpenCode's own JS plugins are fine, because those CLIs run Node themselves.
- The office never writes into `~/.grok`, `~/.config/muse` or `~/.cursor`. Cursor's `<cwd>/.cursor/hooks.json` must be restored exactly as it was when the worker exits, is sent home, or the office stops. Exclude the file from git when the office created it.
- Remember that `--force` and `--yolo` are never passed to Cursor.
- Hook payloads are untrusted. Keep the bounds: 160-character ids, 20k-character text, child-session filtering.
- DSH runs in the office process. Shutting the office down must close the ACP children. A `ptyProtocol` bump isn't needed unless `ptyhost.dart` changes.
- `WorkerInfo.model` validation differs per provider. DSH's model ids are opaque.
- Ask S3 to land RunAs (per-account env) on top of the adapters' `LaunchPlan.env`. The adapter's env goes in *before* the account's sign-ins, as in upstream.

---

## S2. Server: agents and repos (L)

**Commits**

| SHA (PR) | What |
|---|---|
| 6d9a691 (#192) | `/office/workers` endpoint, the `office-workers` command and its MCP server; `Floor.sendHome` with merged heads; `landedWork`/`notLeaving` |
| 6a905e3 (#274) | A Claude worker's own `gh pr create` sets its `pr`; `pastPrs`; `office-workers pr` and the `link_pr` tool (`POST /office/workers/pr`) |
| 722a5ba (#172) | Follow the worker's own branch: `worktree.branch`/`made`, renamed and deleted branches, safe deletes |
| 02e4c44 (#173) | Multi-repo workers: workspace folder, `WorkerRepo`s, `GIT_CEILING_DIRECTORIES`, linked PRs, prune, leave-on-merge across repos |
| dd0b2d8 (#195) | Clone progress (`CloneRun`): progress log, stall at 3 min, own session, `cloning.json` adopt, `floor.cancel` |
| 13c104e (#197), part | `office-workers` reports deleted worktrees (S1 owns `lost`) |

**Upstream files to read**
- Office workers:
  - `src/server/office-workers.ts`, `src/server/hooks/office-workers.ts`
  - `bin/office-workers.js` (546 lines, including its MCP stdio server)
  - `src/server/leave-on-merge.ts`, `floor.ts`
- PRs:
  - `src/server/workers/pr.ts` (277 lines)
  - `src/server/providers/claude.ts` (the PostToolUse `gh pr create` part)
  - `src/shared/status.ts` (`workerPr`)
- Branches: `src/server/worktrees.ts` and `src/server/workers/worktree.ts` (383 lines), `src/server/prune.ts`
- Multi-repo:
  - `git show 02e4c44 -- src/server src/shared/prompts.ts` (`worker.repos` prompt)
  - `src/server/changes.ts` (per-repo), `src/server/queue.ts`
- Clone: `src/server/clone.ts` (249 lines), `src/server/building.ts` (diff of dd0b2d8), `src/server/setup.ts` (6 lines), `src/server/ws/handlers/floors.ts`

**What to build**
1. **`agent-office workers`** (new `server/lib/src/workers_cmd.dart`, modelled on `queue_cmd.dart`).
   - Subcommands: `list [--json]`, `hire`, `home [--merged] [--cleanup]`, `tell`, `pr <n|url> [--worker] | --none`, and `mcp` (a dependency-free MCP stdio server with `list_workers`, `hire_worker`, `send_home`, `tell_worker` and `link_pr`).
   - Wire it in `bin/agent_office.dart`.
   - Next to the `agent-office` shim (`workers.dart` `_writeQueueCommand`), also write an `office-workers` shim (`exec <office> workers "$@"`). Prompts and briefs say `office-workers`.
   - Put the bin dir on **every** worker's PATH, not just board agents'.
2. **`/office/workers`** on the hook port (`server.dart`, next to `/office/queue`).
   - `GET` lists `WorkerRow`s.
   - `POST` hires.
   - `POST /home` sends workers home, with auto cleanup that keeps unpushed work and says so.
   - `POST /tell` prompts a worker.
   - `POST /pr` links or unlinks a PR.
   - Authenticate with the calling worker's token, scoped to its floor.
   - Port `office-workers.ts` into `server/lib/src/office_workers.dart`.
3. **MCP wiring per provider.** This needs S1's adapters.
   - Claude: `--mcp-config` with `list_workers` pre-allowed.
   - Codex: `-c mcp_servers.agent-office…` with `env_vars`.
   - OpenCode: `OPENCODE_CONFIG_CONTENT`.
   - The MCP command is `<office exe> workers mcp`, from `officeCommand()`.
4. **PR ownership.**
   - The Claude hook's PostToolUse or PostToolUseFailure on `gh pr create` parses the printed URL into `pr`, but only for the floor's own repository. The previous `pr` goes to `pastPrs`.
   - `workerPr` (shared) uses `pastPrs` for "landed".
   - `leave_on_merge.dart`: `landedWork` and `notLeaving` split; `Floor.sendHome` passes merged heads to `kill`.
5. **Follow the branch** (`worktrees.dart` plus the worker worktree code).
   - Read the current branch on rest, exit, start, each PR-list refresh, and before O or send-home.
   - Keep `worktree.branch` and `worktree.made`.
   - Detect a rename by reflog.
   - Never delete branches from before the hire (by reflog), such as main.
   - Keep the office branch while it holds unique commits.
   - The worktree state counts commits on both branches.
6. **Multi-repo workers.**
   - `worker.spawn.repos` (floor ids) → a workspace at `.agent-office/worktrees/<name>`, with a worktree of each repo on `office/<name>`.
   - CLAUDE.md and AGENTS.md brief from the shared `worker.repos` prompt.
   - Set `GIT_CEILING_DIRECTORIES` on the workspace.
   - O opens a PR per repository with commits, each carrying a marked block that links the others. The home floor's PR closes the issue; the others mention it as `owner/repo#n`.
   - Per-repo `WorktreeState.repos`.
   - Send home deletes every worktree, then the workspace.
   - Leave-on-merge waits for every repo's PR.
   - Prune leaves workspaces and other floors' branches alone.
   - Per-repo Changes (`changes.dart`).
   - Touches: `workers.dart`, `worktrees.dart`, `changes.dart`, `floor.dart`, `prune.dart`, `leave_on_merge.dart`, `server.dart` (the `pullsOf(floor)` lookup).
7. **Clone progress** (new `server/lib/src/clone.dart`, plus `building.dart`).
   - Run `gh repo clone` with `--progress` to a log file in its own session or process group with no TTY (`setsid`; on the Dart side, `Process.start` with `ProcessStartMode.detached` plus a log file).
   - Parse progress every second into `FloorInfo.clone`. A stall of 3 minutes kills the clone.
   - `floor.cancel` by whoever added it or an admin kills the process group.
   - `cloning.json` lets a restarted office adopt or clean up a clone.
   - `setup.dart` keeps cloning in the terminal.

**Dart files**
- New: `workers_cmd.dart`, `office_workers.dart`, `clone.dart`, `worker_pr.dart`
- Changed: `bin/agent_office.dart`, `server.dart`, `workers.dart`, `worktrees.dart`, `changes.dart`, `floor.dart`, `prune.dart`, `leave_on_merge.dart`, `queue.dart`, `building.dart`, `setup.dart`, `prompts.dart`

**Upstream tests**
- `tests/office-workers.test.ts` (308 lines) and `repos.test.ts` (363)
- `clone.test.ts` (198): `parseProgress`, stall, adopt
- workers.test.ts branch-follow and PR cases (the 722a5ba diff adds 175 lines; 6a905e3 adds 56)
- The `queue.test.ts` and `worktrees.test.ts` parts from 722a5ba and 13c104e

**Gotchas**
- The `office-workers` name must exist on PATH. Agent CLIs and docs call it by that name.
- Never let `git` in the workspace reach the floor's checkout. Set `GIT_CEILING_DIRECTORIES` in every git call made for the workspace.
- Branch deletion is destructive. Port the reflog checks exactly and port the tests first.
- The clone must not inherit the office's controlling terminal. Use detached mode with `stdin` closed, `GIT_TERMINAL_PROMPT=0` and `GIT_SSH_COMMAND='ssh -o BatchMode=yes'`, so a host-key or password prompt fails fast.
- Coordinate with S1: the Claude `gh pr create` hook code belongs in S1's Claude adapter. Put the parsing in `worker_pr.dart` and call it from the adapter.

---

## S3. Server: misc and ops (L)

**Commits**

| SHA (PR) | What |
|---|---|
| 12ba9a0 (#146), 647e674 (#162) | Per-account Claude and GitHub sign-ins: SignIns, RunAs, homes, `signins*` messages; docs |
| 01da81f (#273) | `agent-office tunnel` and the relay's `x-agent-office-service`; `/api/services`; `ss` in the image |
| 31165d6 (#164) | Tailscale: `tailnet.ts`, relay by port, `provision.sh --tailscale`, `aws.sh up --tailscale`; Invite and Services hints |
| c718980 (#171), server part | `POST /api/term/drop` and DropStore, pruned at start and dropped with the worker |
| 745a5d1 (#153), server part | Spot from the connect query; a gone floor sends you to the roof |
| e2c89c8 (#194) | Day and night loop every hour (shared `skyTime`); config |
| 7fb9529 (#219), server part | `--real-time-sky` / `AGENT_OFFICE_SKY_CLOCK`; `sky-clock.json` and `sky.clock`; `sky-place.json`; sooner forecast retry |
| 157b176 (#244), server part | `AGENT_OFFICE_TURN` (several, space-separated) next to `--turn` |
| cf1a228 (#175), 9edfefc (#176), e4bafed (#201), 108a346 (#179), 910e8bd (#180), d96bdb8 (#216) | Deploy scripts: azure, railway, fly, dokploy, coolify; `deploy/container/*`; `AGENT_OFFICE_DEPLOY_SCRIPT`; team invite with `ssh://office@host:port` |
| 0c3b374, b47eba6 | Nothing to port. See the no-op table. |

**Upstream files**
- Sign-ins:
  - `src/server/signins.ts` (660 lines)
  - `git show 12ba9a0 -- src/server` (`server.ts`, `workers.ts`, `github.ts`, `changes.ts`, `queue.ts`, `meetings.ts`, `floor.ts`)
  - `src/server/ws/handlers/signins.ts`, `src/shared/protocol/accounts.ts`
- Tunnel:
  - `src/server/tunnel/{index,forwarder,office,session,ssh,wire}.ts` (about 870 lines)
  - `src/server/relay.ts`, `http/routes/services.ts`, `http/router.ts`, `ws/upgrade.ts`, `cli.ts`, `browser.ts`
  - `docs/tunnel.md`
- Tailnet: `src/server/tailnet.ts`, `relay.ts`, `team.ts`, `config.ts`; `deploy/provision.sh` and `deploy/aws.sh` (31165d6 diff)
- Drops: `src/server/drops.ts`, `src/shared/drops.ts`
- Sky: `src/server/sky.ts`, `config.ts`, `src/shared/sun.ts`, `ws/handlers/settings.ts`
- Arrival: `git show 745a5d1 -- src/server`
- Deploy:
  - `deploy/{azure,railway,fly,dokploy,coolify}.sh`
  - `deploy/container/{Dockerfile,Dockerfile.dockerignore,install.sh,start.sh}`
  - `deploy/provision.sh` diffs
  - `docs/{azure,railway,fly,dokploy,coolify,tunnel}.md`, README sections, `.gitattributes`

**What to build**
1. **SignIns** (new `server/lib/src/signins.dart`). Only applies to offices with accounts.
   - Homes go in `.agent-office/homes/<accountId>/` with `CLAUDE_CONFIG_DIR`, `GH_CONFIG_DIR` and `GIT_CONFIG_GLOBAL`.
   - Claude login: run `claude auth login` in a PTY (`package:office_pty`) with `BROWSER=true`, capture the URL and type back the pasted code.
   - GitHub login: run `gh auth login --web`, capture the one-time code.
   - Pasted tokens: validate with the `CLAUDE_TOKEN` and `GITHUB_TOKEN` regexes.
   - Admins can choose `use: office`. Persist the choices; refresh what each person is signed in as (`seen`), at most every 20 s.
   - RunAs: strip the machine's `CLAUDE_VARS` and `GITHUB_VARS` from anything run for an account.
     - Workers: who a worker runs as is fixed at hire and saved in `workers.json`. Queue tasks run as whoever queued them; meetings as whoever called them.
     - gh writes (comment, merge, close, labels, claim, Open PR, Changes commit and PR) run as the clicker, with their git name and noreply email.
     - Boards are still read with the machine's gh.
   - The ⏳ limits read your own plan.
   - Revoking an account deletes its home; orphaned homes are cleared at startup.
   - Messages: `signins.get`, `signins.start`, `signins.code`, `signins.token`, `signins.cancel`, `signins.signout`, `signins.office`, `signins.needed` → `signins`.
   - Gating: hire, queue, meeting and board-agent ask need your Claude sign-in. Otherwise the window opens with `signins.needed`.
2. **Tunnel.**
   - `agent-office tunnel [office@host | url]`: a subcommand in `bin/agent_office.dart` plus `server/lib/src/tunnel/*.dart`.
   - It polls `GET /api/services` and listens on 127.0.0.1 and ::1 on each port. Each connection forwards to the office port with the session and `x-agent-office-service: <port>`.
   - `office@address` also keeps an `ssh -N -L` alive. Shell out to `ssh`; don't implement SSH.
   - Server side, `relay.dart` treats `x-agent-office-service` like a service tunnel and never answers a tunnel request with office pages.
3. **Tailnet** (`server/lib/src/tailnet.dart`). Sync the served ports through the `agent-office-serve` helper (`AGENT_OFFICE_SERVE_HELPER`). The relay picks a service by `Host` port. Add the `config.dart` flags and the team and services fields from the shared settings.
4. **Drops.** Handle `POST /api/term/drop?worker=…`: check that the session can see that worker, apply the size limit from shared drops, and save to `drops/<worker>/<rand>-<safe name>`. Return the shell-escaped path (Windows-quoted where relevant). Delete on send-home; prune at start.
5. **Come back where you left** (`server.dart` WS upgrade). Read `x,y,z,rotY` from the query (`spotFrom` → `arrivalSpot`). A floor that's gone (and isn't the roof) sends you up to the roof with a toast. Otherwise put you at the elevator spot as before.
6. **Sky** (`sky.dart`, `config.dart`).
   - Hourly loop by default (`skyTime` from shared `sun.dart`).
   - `--real-time-sky` / `AGENT_OFFICE_SKY_CLOCK=real`, or the `sky.clock` message, stored in `sky-clock.json` and shown to everyone.
   - `sky-place.json` keeps the forecast's place; retry sooner after a miss.
7. **TURN.** Merge `AGENT_OFFICE_TURN` (space-separated URLs, with credentials as upstream parses them) into the ICE servers the client gets.
8. **Deploy.**
   - Copy `deploy/{azure,railway,fly,dokploy,coolify}.sh` and `deploy/container/*`. Adapt them to the **Dart release**: in the container, install with this repo's `install.sh` (`AGENT_OFFICE_TARBALL` or `AGENT_OFFICE_VERSION`), or use a multi-stage Dockerfile that runs `dart run tool/build.dart --pack`. Don't use npm.
   - Replace `node /opt/agent-office/bin/agent-office.js …` with the `agent-office` binary path.
   - Copy the `provision.sh` additions: `--tailscale`, `AGENT_OFFICE_DEPLOY_SCRIPT`, keeping the Claude token on re-runs, `AllowStreamLocalForwarding no`, and the sshd-block copy for containers.
   - Make `ss` (iproute2) available in the image.
   - Copy the docs, rewritten where they mention Node. Add `.gitattributes` `*.sh text eol=lf`.
   - `team.dart`: an SSH address with its own port, the script name in the hints.
9. **Docs.** Bring README and docs up to date for everything above. AGENTS.md and CLAUDE.md for this repo are optional.

**Dart files**
- New: `signins.dart`, `tunnel/*.dart` (or `tunnel.dart`), `tailnet.dart`, `drops.dart`
- Changed: `server.dart`, `workers.dart` (RunAs env per launch, on S1's `LaunchPlan`), `github.dart` / `changes.dart` / `queue.dart` / `meetings.dart` (an `as` env parameter), `relay.dart`, `config.dart`, `team.dart`, `sky.dart`, `accounts.dart` (revoke clears the home), `bin/agent_office.dart`, `deploy/*`, `docs/*`, `README.md`

**Upstream tests**
- `tests/tunnel.test.ts` (300 lines), `relay.test.ts` (90), `drops.test.ts` (54), `sky-clock.test.ts` (21), `sun.test.ts` (the shared part), `config.test.ts` (the TURN case)
- There is no signins test upstream. Write unit tests for token validation, env stripping and the homes layout.

**Gotchas**
- Never put a token in argv or a log. Pasted tokens go in the account's home files with 0600 permissions.
- Revoke must delete the folder. Check that the path stays under `homes/` before deleting.
- The tunnel listens on loopback only. A connection that isn't a service request must never be answered with office content (upstream test: "A request the client sends is never answered with the office's own pages").
- The deploy scripts are 700 to 1100 lines of bash each. Copy them and patch only the Node and npm bits, the binary path and the release install, then run `bash -n` and `shellcheck` if it's available. They can't be tested end to end here.

---

## S4. Server: world state (new, M)

**Commits:** a872450 (#184, server), 665aeec (#203, server), 7f7211e (#275, `jail.ts` and `floor.ts`), 4575f6f (#183, server), 8030361 (#181, server), b8e05af (#152, server), 888ad67 and 2b1125a (#177/#220, server dog), 3cbf451 (#182, server), 87ad36e (#267, shared only).

**Upstream files:** `src/server/{maps,jail,floorplan,garage,dog}.ts` and `src/server/ws/handlers/{car,dog,plan,presence,rooftop,settings,floors}.ts`. The diffs are in `git show <sha> -- src/server` for the SHAs above.

**What to build** (new files `maps.dart`, `jail.dart`, `floorplan.dart`, `garage.dart`, plus edits to `server.dart`, `floor.dart`, `workers.dart`, `queue.dart`, `dog.dart` and `building.dart`)
1. **Maps.** The `Maps` class: `.agent-office/map.json` holds the pick (with `by` and `at`), and `.agent-office/maps/*.json` holds your own maps, at most 24 files of 256 KB each, re-read when the folder's stamp changes. `map.set` and `map` broadcast; a map that breaks or comes back gets a toast, and everyone's seats are forgotten.
   - Seats are checked against the plan in effect (`planOf` in shared maps).
   - `sit` refuses a seat someone already has with `sit.refused`, except on a reconnect of the same person.
   - Herald spawn: `via:'herald'` on WorkerInfo.
   - Workers track `workedMs` and `workingSince`.
2. **Jail** (`jail.json`, at most 200 named prisoners, then counted as bones). When a worker is sent home on a map whose `sendHome` keeps them, `worker.remove` carries `jail`. The welcome includes JailState per floor.
3. **Floorplan** (`floorplan.json`).
   - `desk.label` (text, one of 7 colours).
   - `floor.expand` and `floor.shrink` (the shrink is refused while a desk in the back row is taken) → `plan`.
   - The queue and new hires take back-office desks before beanbags.
   - `dog.dart` and other walks use the shared nav with the wing.
4. **Garage.**
   - Per floor, in memory: `car.enter` / `car.leave` / `car.move` / `car.honk` (rate-limited to 250 ms) → `cars` and `car.drive`.
   - Accept a pose only from the car's driver and only on pavement (shared `garage.dart`'s `paved`).
   - Leaving the floor or the office gets you out of the car.
5. **Toss.** A rate-limited `toss` relay to the roof's peers, validated by shared `bargames.dart`. `throwing` lives on the peer.
6. **Dog.** Breed and coat per floor, derived from the floor id by default. `dog.breed` and `dog.coat` (Settings) are persisted and sent with the dog state. Includes the pomeranian and the white coat.
7. **Lite peers.** `?lite=1` on connect → `PeerInfo.lite`: in the office but not standing anywhere. `/lite` is served as the client index, with a `/login?next=/lite` redirect when signed out (`static.dart`).
8. **Static.** Serve `.glb` as `model/gltf-binary` (888ad67) if the Flutter build ships raw GLBs.

**Tests**
- `tests/maps.test.ts` (198 lines), `dungeon.test.ts` (179; the server and jail parts), `station.test.ts` (145; the shared and server parts), `floorplan.test.ts` (96), `garage.test.ts` (145), `bargames.test.ts` (105; mostly shared), `dog-breed.test.ts` (27)
- Shared tests belong to the shared agent. Port the server-facing cases.

**Gotchas**
- Your own map JSON is untrusted. The shared `checkMap` bounds sizes (40 tables, 12 seats a side, 400 props) and `mergeConfig` skips `__proto__`, `constructor` and `prototype`. Make sure the Dart port keeps those bounds.
- A map change must forget seats on the server and broadcast a toast in the same tick.

---

## C1. Client UI (XL)

**Commits**
- **Settings, palette, input:**
  - 000ad9f (#147) settings with categories
  - 69a8d7f (#188) command palette
  - 85fa9c9 (#266) dictation
- **Terminal:**
  - 0538d4b (#167) terminal keys
  - 14f2d8f (#168) ⎋ Esc button
  - c718980 (#171) drop and paste (client)
  - 3cd825a (#212) terminal tabs with a pinned web page
  - 60a74b4 (#322) Hide button and help text
- **Boards and names:**
  - 52fd37f (#165) board title filters
  - 50be1b2 (#166) random names
  - 39c2940 (#262) issues wall pins
  - 6fa06d7 (#268) client: In progress, 🤖 Hand to a worker
- **Windows and alerts:**
  - 85ade62 (#163) every modal closable
  - f958815 (#270) needs-you
  - 773fe19 (#264) and 8631789 (#265) meeting UI
  - be6e20e (#178) bookshelf swish and setting
- **Floors and server-backed panels:**
  - dd0b2d8 (#195) clone UI in the elevator
  - 12ba9a0 (#146) sign-ins window
  - 31165d6 (#164), cf1a228 and 9edfefc (team and services panel strings)
  - 01da81f (#273) tunnel command on the Services board
  - 157b176 (#244) TURN toast
- **Workers:**
  - 02e4c44 (#173) multi-repo UI (ask, prompt, repos picker, changes tabs)
  - 13c104e (#197) lost-worker dialog and look
  - b5acbee (#272), 1dcdc52, 0378130, 2de6bdc and 31afe0f: provider, model and effort pickers, and DSH usage
- **Mouse, view, floors:**
  - d1074d5 (#155) interaction keys
  - 71f1971 (#191) and f88a31f (#198) mouse settle; the final values are in 665aeec
  - 01c1b75 (#193) floor switching into the elevator
  - 745a5d1 (#153) come back where you left (client)

**Upstream files**
- Settings: `src/client/ui/settings.ts`, `settings-rows.ts`, `settings.css`
- Palette: `src/client/ui/palette.ts` and `features/palette/index.ts` (shared `palette` holds matching and ranking)
- Dictation: `src/client/ui/speech.ts` and `ui/dictate.ts`
- Terminal: `src/client/ui/terminal.ts`, `termkeys.ts`, `termtabs.ts`, `termtheme.ts`
- Boards and GitHub: `src/client/ui/boards.ts` and `ui/github/{progress,issue-window,prompts}.ts`
- Workers: `src/client/features/workers/actions.ts`
- Character: `src/client/ui/character.ts`
- Needs-you: `src/client/features/needsyou/{index,logic,sound,ui,world}.ts`, `features/waiting`, `nextup.ts`, `notify.ts`, `ui/workers-panel.ts`, `world/character/worker-badges.ts`
- Meetings: `src/client/ui/meeting.ts` and `features/boards/meeting.ts`
- Bookshelf: `src/client/features/bookshelf/ui.ts` and the swish in `sound/` (`git show be6e20e -- src/client/sound.ts`)
- Elevator: `src/client/ui/elevator.ts` and `floormenu.ts`
- Sign-ins: `src/client/ui/signins.ts`
- Services and team: `ui/services.ts` and `ui/team.ts`
- Multi-repo: `ui/repos.ts`, `ui/ask.ts`, `ui/prompt.ts`, `ui/changes.ts`
- Providers: `ui/provider.ts` (458-line diff), `ui/usage.ts`, `ui/queue.ts`
- Input and player: `src/client/interaction.ts`, `player/pointer.ts`, `core/travel.ts`, `core/arrival.ts`, `net.ts`, `state/persist.ts`

**Flutter targets**
- Settings: `app/lib/ui/settings.dart` (rewrite as categories), plus new `ui/settings_rows.dart`.
  - Categories down the left: You, Sound & voice, Notifications, Building, Workers. On a phone they form a row across the top.
  - A card per setting, labelled Just you, This floor or Everyone. The window is 960 px wide and reopens on the last category. Arrow keys move between categories. The jukebox's "Your volume" opens Sound & voice.
  - Expose a way for other groups to register a card in a category: `settingsCards.add(category, builder)`. C2 and C4 use it.
- Palette: new `ui/palette.dart`, opened with Ctrl/Cmd+K from `office/controller.dart`. It covers workers, issues, PRs, services, boards, teammates and actions. Enter opens the item; Shift+Enter walks there first, using the same router as `walkTo` (back office, maps); in a car it opens right away.
- Dictation: new `ui/dictate.dart`, `interop/speech.dart` → `speech_web.dart` (Web Speech API through `package:web`) and `speech_stub.dart` (no 🎤 on macOS or Firefox).
  - Hold Ctrl+Space or the 🎤 to talk, or tap to leave it listening.
  - It goes into the terminal header and into the hire, ask, queue and meeting prompt boxes.
  - Mute an open voice-chat mic while listening (`voice/voice.dart`).
- Terminal: `app/lib/ui/terminal.dart` and `terminal_logic.dart`.
  - Keys: Shift+Enter→`\n` (Ctrl+J), Ctrl+⌫→Ctrl+W, ⌘⌫→Ctrl+U, ⌘⌦→Ctrl+K, ⌘←/⌘→→Ctrl+A/Ctrl+E.
  - Escape: an ⎋ Esc button. Ctrl+[ and Ctrl+] also match by physical key, and AltGr doesn't close. Show a tip when you leave with Esc while the screen says "Esc".
  - A "Hide" button. The header wraps on narrow windows.
  - Drop and paste: upload with `POST /api/term/drop` and paste the returned path. On web, drop and paste go through `package:web` events; on macOS, through `desktop_drop` or clipboard images if they're available, otherwise skip.
  - Tabs: "+ Web page" pins a named URL in an `HtmlElementView` iframe on web and a `webview_flutter` view on macOS (both are already dependencies). The pinned tabs last for the session, per worker.
- Boards and GitHub: `app/lib/ui/boards.dart` and `gh_logic.dart`.
  - A "Filter by title…" box per column: every word, any case. It shows "shown / total", ✕ clears it, and it survives a refresh with focus and caret intact.
  - The cork board pins only the issues nobody has started on, and redraws when the queue changes (`world/board_faces.dart`, `office/controller.dart` `_cork`).
- Random names: `app/lib/ui/character.dart`, using the shared avatar's random name. A 🎲 button, blank means the suggestion, and ✕/Esc skips with the suggestion.
- Closable modals:
  - `ui/elevator.dart`: the welcome panel gets ✕ and Esc; a backdrop click doesn't close it.
  - `ui/character.dart`: the first pick gets ✕ and Esc.
  - `ui/upgrade.dart`: closable.
- Needs-you: new `app/lib/ui/needs_you.dart`, `world/needs_you_beacon.dart` and `needs_you_logic.dart`.
  - In the room: a red pin over the card, a light pillar over the desk and rings on the floor, fading as you get close.
  - On screen: a banner (click or N to go there, ✕ to dismiss until someone else asks) and a red screen-edge flash.
  - Alarm setting: once, every 30 s until someone opens the terminal, or off. Add it to `sound_web.dart` and `sound_native.dart`.
  - The Workers panel lists them on top in red.
  - N and the waiting chip order: needs-you before done (`nextup.dart`).
  - Clicking a notification opens the terminal at the desk (`notify.dart`).
- Meetings: `app/lib/ui/meeting.dart`. No budget field or bar; the tokens and cost are a plain line. Fixed-round workflows show text such as "3 rounds · fixed by …"; range workflows get a dropdown.
- Bookshelf swish: `app/lib/ui/bookshelf.dart` plus the sound. A short band-passed swish and pat, one per flick, with 🔈 in the bookshelf and a "Page turns at the bookshelf" setting.
- Clone progress: `app/lib/ui/elevator.dart` and `floormenu.dart`. A step, percent and detail bar from `FloorInfo.clone`, ⏹️ to cancel, no endless wait after a restart, and a toast for a failure after the panel closed.
- Sign-ins: new `app/lib/ui/signins.dart` ("🔐 Your sign-ins"), opened from the ☰ menu (`ui/menu.dart`) and automatically on first join and on `signins.needed`.
  - Claude: a link to open and a code box.
  - GitHub: a device code and a link.
  - Paste-a-token boxes, and "Use the office's own" for admins.
- Services and team: `app/lib/ui/services.dart` and `team.dart`. Show the tunnel command, tailnet URLs, deploy-script commands from `AGENT_OFFICE_DEPLOY_SCRIPT`, and an `ssh://office@host:port` address.
- Voice: `voice/voice.dart` shows a toast once per person when ICE fails.
- Multi-repo:
  - `app/lib/ui/prompt.dart` and `ask.dart`: a "🗂️ Also work in" picker (new `ui/repos.dart`).
  - `ui/changes.dart`: a tab per repository.
  - The O action shows each repository's PR.
- Lost worker: `app/lib/ui/prompt.dart` gets a dialog at the desk with Rebuild (here, origin, fresh), Rebuild all and Send home. The "lost" look on the character goes in `world/character.dart` (badge).
- Providers: `app/lib/ui/provider.dart` (577 lines), `queue.dart`, `usage.dart`.
  - The picker is built from shared PROVIDER_META for all nine providers.
  - Models are fetched from `/api/agents/<p>/models` (`net/api.dart`), with efforts per model, and fall back to free text.
  - Claude models are shown by name ("Opus 5.5").
  - A custom `--agent` says why it has neither.
  - DSH has its own usage display.
- Interaction keys: `office/controller.dart`. Port `interactionAvailable` into a new `office/interaction.dart`, so a desk key with nothing to do falls through to movement. Port `tests/interaction.test.ts`.
- Mouse settle: `world/player.dart` and `interop/pointer_lock*.dart`.
  - Closing a window with a click retakes the mouse with `settle`.
  - Hold the view until the mouse rests for 100 ms, at most 150 ms (the final values from 665aeec).
  - A key close turns the view at once.
- Floor switching: in `office/controller.dart` `switchFloor`, when you're outside the office (street, balcony, golf, garage), ride the elevator and step out of that floor's car.
- Come back where you left: `office/controller.dart` and `net/office_socket*.dart`.
  - Save the spot (x, y, z, rotY, seated) every second and on unload (`interop/browser`), next to the floor.
  - Send it in the connect query.
  - On a gone floor, take the elevator to the roof.
  - On a reconnect onto another floor, run the full arrival.
  - Fix the hint bar's stale text.

**Tests to port:** `tests/palette.test.ts` (96 lines), `dictation.test.ts` (222; the bookkeeping logic), `termkeys.test.ts` (42), `needsyou.test.ts` (109), `nextup.test.ts` (diff), `issue-progress.test.ts` (30), `interaction.test.ts` (47), the meetings and prompts UI logic, and `client-help.test.ts`. Put them in `app/test/ui/*`. Keep logic in `*_logic.dart` so it's testable without widgets.

**Gotchas**
- The sound changes (swish, needs-you alarm) must be ported in four places: web, native, `office_render` and `synth`.
- The web-only pieces (Speech API, iframe, drag-drop, beforeunload) go behind conditional exports. `native_compile_test` must still pass.
- `settings.dart` is about 716 lines and upstream keeps each file under 600. Split it: rows helper, `settings_dog.dart`, `settings_sky.dart` and `settings_map.dart` belong to other groups.
- The palette's Shift+Enter walk depends on C2 (map nav) and C3 (back office). Route through the controller's existing walk-to so it picks those up later.

---

## C2. Client maps (XL)

**Commits:** a872450 (#184) maps and castle, 665aeec (#203) dungeon, 7f7211e (#275) space station, and 87ad36e (#267, castle seats part).

**Upstream files**
- World plumbing:
  - `src/client/world/{world,styles,types,texture}.ts`
  - `src/client/core/{worlds,maps,arrival,travel}.ts`
  - `src/client/features/herald/index.ts`, `features/seating/index.ts`
- Castle:
  - `src/client/world/castle/*.ts` (index, shell, props, seats, throne, people, boards, fire, kit, shapes, textures; about 1,900 lines)
  - `src/client/world/court.ts` (290 lines)
- Dungeon and send-home:
  - `src/client/world/dungeon.ts` (288 lines)
  - `src/client/features/workers/{sendhome,jail,lockup,sendoff,adrift,eject,sound}.ts`
- Station: `src/client/world/station/*.ts` (index, shell, space, planets, airlock, seats, props, people, boards, kit, textures; about 2,400 lines)
- Characters:
  - `src/client/world/character/{worker-jail,worker-dress,worker-stance,worker-leave}.ts`
  - Peasant aging and the guard in `person.ts` and `worker.ts`
  - `world/costumes.ts` (peasant clothes)
- Sound: the castle and station acoustics in `sound/{ambience,places,core}.ts`
- Docs: `docs/maps.md`, `docs/maps/{castle,station}.json`

**Flutter targets**
- New `app/lib/world/world.dart`, the World interface. Its members: plan, group (Node), colliders, interactables, pickables, desks, boardMeshes, meetingBoard and sign, gong, nav, ways (home, in), rain, device (laptop or tome), room (wall, enclosed, vault), acoustics, herald, setBeanbags, setLook, setProjectName, update, mood, dungeon, airlock, escort and dispose.
- `officeWorld(...)` adapts `world/office/office.dart`.
- `office/controller.dart`: show one world at a time and switch when `map` changes, the same way the office and the roof swap (`office/roof.dart`). Seats, boards, beanbags, walks, confetti and the herald all go through the World.
- New `app/lib/world/styles.dart` (BUILDERS), `world/castle/*.dart`, `world/court.dart`, `world/dungeon.dart` and `world/station/*.dart`.
- New `office/send_home.dart`, the script runner (pack, fetch, say, walk, jail, leave, wait, return), plus `world/jail.dart`, `world/lockup.dart` and `world/adrift.dart`.
- Characters: `world/character.dart` gets the peasant dress, the aging (beard, dirt, hunch, droop, slower walk, fully aged after 30 minutes of work), the guard, and the starving, dead and skeleton looks. `world/leaving.dart` handles the escort.
- Settings → Building → Map picker (new `ui/settings_map.dart`, registered with C1's settings API). It lists your own maps and why a broken one won't load.
- Other UI: `ui/boards.dart`, `arcade.dart`, `cabinet.dart`, `floormenu.dart` and `whereabouts.dart` name seats by the map. 📚 Docs moves into the ☰ menu off the office.
- Sound: the castle (no phones or fridge, ale poured, gong position, hall reverb) and the station (vacuum outside), in `audio/sound_web.dart` and the native renderer.
- Copy `docs/maps.md` and `docs/maps/*.json` into this repo's `docs/`.

**Tests:** the client-facing parts of `tests/maps.test.ts`, `dungeon.test.ts`, `station.test.ts` and `meeting-table.test.ts` (castle). Most of these are shared or S4. On the client, add a widget or logic test for court line ordering and for the send-home script runner.

**Gotchas**
- The castle's stone textures use their own LCG, **not** the shared rng, or every stone moves. Draw them as canvas textures (`ui.Image` → flutter_scene `Texture`) the way `world/office` already does.
- All numbers stay as they are under the mirrored root. Don't rotate anything to fix handedness.
- A map change while you're travelling (elevator, ladder, floor list): land where the new map says. A roof the map doesn't have sends you down. Holding the basketball or a card: drop it.
- Arriving on the castle must not replay every worker walking in (`seatedAlready`).
- Clicking a worker standing in the court line must not open another worker's terminal. Keep the line's interactables up to date when the line changes, not every frame.
- Performance: the station's planets and space are large. Merge by material (`mergeByMaterial`, as `city.dart` does).

---

## C3. Client places and driving (XL)

**Commits**
- 8030361 (#181) drive the cars
- c1924db (#196) scenic loop
- 4c5e967 (#169) elevator to the garage
- 319bbc8 (#227) solid neighbour buildings
- 4575f6f (#183) desk signs and back office
- b8e05af (#152) darts and axes
- ec77d42 (#154) telescope
- 87ad36e (#267) meeting tables sized to the laptops (office part)
- Moved to C4: 8b4e711 (fridge) and 7c15448 (dog leg).

**Upstream files**
- Cars:
  - `src/client/features/cars/{index,controller,world,laps,sound}.ts`
  - `src/client/world/outside.ts`, `world/office/ground.ts`
  - The shared `garage.ts` and `scenic.ts` are already ported by the shared agent.
- Scenic loop: `src/client/world/scenic/*.ts` (about 1,400 lines) and `world/toon.ts` (diff in c1924db)
- Elevator and building:
  - `src/client/world/elevator.ts`, `ui/elevator.ts`
  - `world/tower.ts` (bottom slab), `player/camera.ts` (garage walls)
- Desk signs and back office:
  - `src/client/world/desksigns.ts` (191 lines), `world/office/wing.ts` (245), `ui/floorplan.ts` (155)
  - `walkto.ts`, `world/stack.ts`
- Bar games: `src/client/features/bargames/{controller,world,index,sound}.ts` (about 1,260 lines), `world/character/person-throw.ts`, `features/rooftop/world.ts`
- Telescope: `src/client/features/telescope/{controller,index}.ts`, `world/office/loft.ts`
- Meeting tables: `src/client/world/office/meeting-room.ts` (the 87ad36e diff) and shared `layout`

**Flutter targets**
- Cars:
  - `app/lib/world/office/cars.dart` (already holds the supercar models): split the models into parts.
  - New `office/driving.dart`: the arcade physics from shared garage. W/A/S/D, Space brakes, H honks, E gets out or in as passenger.
  - Cars slide along walls, knock people aside, are hidden while you're upstairs, snap into place on arrival, and are parked when you close the tab.
  - New `office/laps.dart`.
  - Car sounds (engine, throttle, crunch, honk) in `audio/*`.
  - `ui/whereabouts.dart` says "driving".
- Scenic loop: new `app/lib/world/scenic/*.dart` (road, farm, trees, flora, mountains, tunnel, coast, water, kit). Wire it into `world/office/outside.dart` and `city.dart`. The toon changes (fog and colour on far scenery) go in `world/toon.dart` or `assets/materials/toon.fmat`.
- Elevator to the garage:
  - `world/office/elevator.dart` gets `buildElevator(height)` and `setFloor(y)`, so a short copy follows the street down.
  - The garage stop moves with `setLevel` and gets a keep-clear area in `outside.dart`. The bottom slab in `tower.dart` is seen from below.
  - The camera stays in front of the garage's back and west walls (`world/player.dart`).
  - The Garage stop goes in the `ui/elevator.dart` panel (coordinate with C1).
  - Reloading in the elevator car down there puts you back there.
- Neighbours: building colliders in `world/office/outside.dart` or `city.dart`, for both people and cars.
- Desk signs:
  - New `world/desk_signs.dart`: L at a desk hangs a sign in one of 7 colours, facing the chair, printed on both sides; the desk across the pair stays blank.
  - New `ui/floorplan.dart`: the sign dialog, and E at the "Room to grow" sign.
- Back office:
  - New `world/office/wing.dart`.
  - The office walls, nav, dog, walks, camera, sky (indoor light and rain), sound and outside (the bay on posts) all follow the floor's `wing`.
  - Edits in `world/office/office.dart`, `office_colliders.dart`, `stack.dart`, `tower.dart` and `walkto.dart`.
- Darts and axes:
  - New `world/bar_games.dart`: the axe-throwing booth in the roof's north-west corner, the dart cabinet, chalkboards, and darts and axes stuck in the target.
  - New `office/throwing.dart`: over-the-shoulder camera, aim with the mouse or arrows with a drunk wobble (`booze.dart`), hold Space and release in the green of a meter (reuse `ui/shot_meter.dart`). Three darts or five axes a round.
  - Send `toss`, and show other people's tosses. Keep your best round per game in local storage.
  - Throwing animation in `world/character.dart`. Sounds.
- Telescope: `world/office/loft.dart` and new `office/telescope.dart`. E looks through it with mouse aim, higher magnification and a clear sightline.
- Meeting tables: `world/office/meeting_room.dart` uses the shared layout table sizes.

**Tests:** `tests/driving.test.ts` (151 lines; drives a real Fleet, so mostly shared physics plus the client controller), `scenic.test.ts` (151), `telescope.test.ts` (58), `floorplan.test.ts` (client bits), `nav.test.ts` (wing), `player.test.ts` (the garage camera parts) and `meeting-table.test.ts`.

**Gotchas**
- The scenic loop must use the shared rng (Mulberry32) so trees are in the same places as upstream.
- The car controller runs on the driver's page. Send `car.move` at a bounded rate, and smooth other people's cars between moves.
- The back office changes the nav grid per floor. Everything that calls the office nav must take the wing (`officeNav(wing)` in shared). Coordinate with C2's World, whose `officeWorld` gets `wing()`.
- Hide the garage and cars while you're upstairs, as upstream does, for performance.

---

## C4. Client models and visuals (L)

**Commits**
- **Models and dog:**
  - 888ad67 (#177) model pipeline, dogs, loading screen
  - 267563c (#186) kitchen, plants, lounge, desk props
  - 2b1125a (#220) dog breed and coat setting, pomeranian, white coat
  - 8b4e711 (#156) fridge, 7c15448 (#148) dog leg: only if the code-built meshes stay
- **Characters:**
  - c91bb8f (#223) first-person hands and body
  - 1d5e5e2 (#228) holiday outfits
- **Light and sky:**
  - 7fb9529 (#219) lamplight and sky clock (client)
  - e2c89c8 (#194) sky loop (client)
  - 852e2ab (#320) fog kept out of the interior
- **Sound and effects:**
  - b09d745 (#269) footsteps
  - f2799f7 (#321) drunk warmup
  - 08c1f56 (#261) phone ring removed
- **Geometry:** 1bc3028 (#213) signs and glass z-fighting

**Upstream files**
- Models and loading: `src/client/world/models.ts` (151 lines), `ui/loading.ts` (159), `styles/loading.css`
- Dog: `src/client/features/dog/{world,coat,index,sound}.ts`, `ui/settings-dog.ts`
- Office models: `src/client/world/kitchen.ts`, `world/office/{props,seats,build}.ts` (plants, lounge, desk props), `world/holiday.ts` (finding leaves by name)
- First person: `src/client/world/character/{person-first,person,rig}.ts`, `world/hands.ts`, `core/loop.ts`
- Outfits: `src/client/world/character/person-outfit.ts`
- Light and sky: `src/client/features/lamplight/index.ts`, `world/office/shell.ts`, `world/sky.ts`, `ui/settings-sky.ts`
- Footsteps: `src/client/sound/{feet,steps,buffers,index}.ts`, `features/peers/index.ts`, `player/index.ts`
- Drunk vision: `src/client/features/bar/{drunk,index}.ts`
- Phone ring: `src/client/sound/ambience.ts`
- Signs and glass: `src/client/world/office/{loft,materials,meeting-room}.ts`

**Flutter targets**
- Assets: copy the 10 GLBs (table in §0) into `app/assets/models/` and add them to `pubspec.yaml`. Optionally copy `blender/` to the repo root for the model sources.
- Models: new `app/lib/world/models.dart`.
  - Load with flutter_scene's GLB support: `Node.fromGlbAsset` or the build hook's `buildScenes` importer. Preload kitchen, lounge, plants and desk_props; load a dog breed when it's first needed.
  - `piece(name)` clones a named object.
  - `paintModel` replaces materials by name (Wood, Frame, WoodDark, Cloth and the others) with toon materials.
  - Report progress for the loading screen.
- Loading screen: new `ui/loading.dart`, shown until the preloaded models are in. Hook it into `office_page.dart` and the `controller.ready` notifier.
- Dog: `world/dog.dart` becomes the skinned GLB.
  - Cross-fade the nine clips (stand, walk, run, wag, sniff, sit, bark, lie, nap) by state, with walk and run playback following speed.
  - Keep the woof, panting, blinking, costumes and coat tint in code. Picking uses capsules on its bones.
  - Breed comes from the floor (S4) or the setting. Keep the old model visible until the new one has loaded.
  - New `ui/settings_dog.dart`: breed and coat, including white, registered with C1's settings API.
- Kitchen, plants, lounge and desk props:
  - The kitchen model replaces the code-built kitchen corner in `world/office/office.dart` (about line 549). Same colliders; the coffee interactable covers the machine only.
  - Plants come from `plants.glb` in the existing places, with species taking turns. `world/holiday.dart` hides leaves by node name.
  - Lounge: the sofa, pillows, poufs and table at their old sizes and seat ids. Couch collider top 0.47, pouf top 0.42.
  - Desks: the mug (painted in the chair colour) and book arrangements from `desk_props`.
- First person: `world/hands.dart` and `world/character.dart`. Hands like your character's (skin, sleeves, holiday mittens). Your own body shows below you in first person, hidden for the hands' render pass and casting no headless shadow.
- Holiday outfits: `world/costumes.dart` / `world/holiday.dart` gets a new `HolidayOutfit`.
  - Halloween: a warlock robe, sash, ragged hem, crooked hat and pointed boots.
  - Christmas: a Santa suit with fur trim, a belt and buckle, mittens and boots.
  - The outfits hang off the rig parts, and the hats move there from `setCostume`.
- Lamplight:
  - New `world/lamplight.dart`: indoors, the shadow light swings near-vertical and goes warm. Outside walls get no shadows. The back-office walls are tagged too (C3's wing).
  - Sky clock: `world/sky_model.dart` / `sky_view.dart` follow the hourly `skyTime` loop, or the real clock when the office says `sky.clock = real`. Show the sky's time of day in settings.
  - New `ui/settings_sky.dart`: Building → Outside, for everyone.
- Fog: `world/sky_view.dart` keeps outdoor fog out of the interior. Fade the fog to none while the eye is indoors, or set a per-material "street" uniform in `toon.fmat`. Engine fog is global (see the note at line 28 of `sky_view.dart`).
- Footsteps: `audio/sound_web.dart` `step()`, `sound_native.dart` and `office_render.dart`/`synth.dart`.
  - A heel and a ball for each surface: planks, concrete, grass, flagstones. Six variants each, never the same one twice running.
  - Run versus walk; landing scales with the fall. Peers' and workers' steps the same way.
  - Silent when you walk into a wall.
  - Surface comes from the position: office, garage or street, grass, castle (see deps).
- Drunk vision: `world/drunk.dart` / `booze.dart` warm up the effect (ramp it in) before the bar effect starts.
- Phone ring: delete the `_nextPhone` ring from `audio/sound_web.dart` (around lines 88, 225 and 288) and from the native renderer.
- Signs and glass: `world/office/loft.dart` (the boss sign clear of the roof trim), `meeting_room.dart` (the sign off the glass frame, the booking panel inside the glass), and glints trimmed to each pane.

**Tests:** `tests/dog-breed.test.ts` (27 lines), `drunk-vision.test.ts` (40), `sky-fog.test.ts` (64), `lamplight-walls.test.ts` (37), `sky-clock.test.ts` (client side), `loading.test.ts` (121; progress logic) and `holiday`/`size` (skip). Also write a test that every GLB loads and has the node, bone and clip names the code uses. This takes the place of the `*-model.test.ts` tests; check the names with a GLB JSON-chunk reader in Dart.

**Gotchas**
- **Handedness.** flutter_scene's GLB importer already applies its own z flip (`Node.fromGlbAsset` roots the model under it), and `officeRoot` flips z again. A GLB placed under `officeRoot` would be mirrored twice, so wrap it under a node with diag(1,1,-1), or check by eye with the props.
- **Skinning with toon.** Check that `assets/materials/toon.fmat` works on skinned geometry, since the dog is skinned. If it doesn't, add a skinned variant or use flutter_scene's material for the dog and tint it.
- **Clip blending.** Check that flutter_scene's AnimationPlayer can cross-fade (it has clip weights). Otherwise cross-fade by hand.
- **Web load size.** The GLBs add about 3.7 MiB. Only kitchen, lounge, plants and desk props (about 0.7 MiB) are preloaded; dogs load on demand. The native app bundles everything.
- **Fallback.** The code-built dog and kitchen must stay as fallbacks if a model fails to load (upstream: `piece()` returns an empty group).

---

## C5. Client `/lite` 2D view (new, M)

**Commit:** 3cbf451 (#182), plus the later lite touches in 13c104e, 6fa06d7, b5acbee, dd0b2d8 and 4575f6f.

**Upstream files**
- View: `src/client/lite.ts` (409 lines), `lite.css`, `lite.html`
- Fallback trigger: `framerate.ts`, `ui/litesuggest.ts`
- Terminal: `ui/termtheme.ts` and the keypad in `ui/terminal.ts`
- Small changes: `nextup.ts`, `net.ts` (`?lite=1`), `login.ts` (`next=`), `voice.ts` (skip lite peers)

**Flutter targets**
- New route `/lite` in `app/lib/main.dart`: a new `pages/lite_page.dart`.
  - The workers on the floor, waiting ones first. Each has its terminal (reuse `ui/terminal.dart`), a keypad for keys a phone keyboard lacks (nine keys at 390 px, replacing the header's Esc), and a prompt box with dictation from C1.
  - Also on the page: the boards, the queue, new tasks, the floor switcher, the lost-worker rebuild, and 🤖 Hand to a worker with `issue`.
- The 3D office offers `/lite` on touch-only devices or when frames stay slow: new `ui/lite_suggest.dart` and `framerate.dart`. It falls back to `/lite` without GPU support.
- `net/office_socket*.dart` connects with `lite=1`. `voice/*` skips peers with `lite`. `login_page.dart` honours `next=/lite`.

**Tests:** `tests/framerate.test.ts` (52 lines), the `nextup.test.ts` and `whereabouts.test.ts` diffs.

**Gotchas**
- The web build is a single SPA, so `/lite` is a route, not a separate HTML file. S4 makes the server serve `index.html` there.
- Don't build the flutter_scene `Scene` on `/lite`.
- macOS: offer it as an in-app route, which is cheap.
