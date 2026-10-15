// Everything the office knows, kept up to date from the server's messages: a port of state.ts.
// Widgets listen to a topic ([Store.topic]); the frame loop reads the fields directly.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../interop/browser.dart';

import 'package:office_shared/avatar.dart';
import 'package:office_shared/decor.dart';
import 'package:office_shared/dog.dart';
import 'package:office_shared/floorplan.dart';
import 'package:office_shared/jukebox.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/whiteboard.dart';

import '../world/player.dart' show ViewMode;
import 'cars.dart';
import 'rooms.dart';
import 'screen_state.dart';

export 'rooms.dart';
export 'spot.dart';
export 'screen_state.dart';

enum Topic {
  peers,
  workers,
  issues,
  pulls,
  chat,
  project,
  screens,
  team,
  upgrade,
  services,
  decor,
  usage,
  limits,
  queue,
  me,
  accounts,
  notify,
  floors,
  floor,
  repos,
  dog,
  jukebox,
  sky,
  whiteboard,
  drawing,
  // The building-wide settings (⚙️ Settings): the workspace folder, the holiday theme, the office's
  // prompts and default worker, leave-on-merge, and the machine with its worker limit.
  projectsDir,
  theme,
  prompts,
  leaveOnMerge,
  machine,
  // Your own Claude and GitHub sign-ins (🔐 Your sign-ins).
  signins,
  // The building's map (the office, the castle, the station…), and whoever the floor has kept (its
  // dungeon's prisoners, or the ones adrift outside its airlock).
  map,
  jail,
  // The signs over the desks, and how far the back office is built out (the floor's own plan).
  floorPlan,
}

/// Where someone is right now. peer.move updates it in place; the frame loop eases toward it.
class PeerPose {
  PeerPose(this.x, this.y, this.z, this.rotY, this.moving);
  double x, y, z, rotY;
  bool moving;
}

class Profile {
  Profile({required this.name, required this.color, required this.look});

  String name;
  String color;
  Look look;

  Map<String, dynamic> toJson() => {'name': name, 'color': color, 'look': look.toJson()};
}

const kAvatarColors = ['#ff8a5b', '#4f86f7', '#06d6a0', '#ef476f', '#ffd166', '#9d4edd', '#00b4d8', '#f77f00'];

const _profileKey = 'agent-office.profile';
const _settingsKey = 'agent-office.settings';
const _floorKey = 'agent-office.floor';

/// Your saved profile; `look` is null if you joined before there was a character select screen.
({String name, String color, Look? look})? loadProfile() {
  try {
    final p = jsonDecode(storageGet(_profileKey) ?? 'null');
    if (p is Map && p['name'] is String && p['color'] is String) {
      final look = p['look'] == null ? null : sanitizeLook(p['look'], randomLook());
      return (name: p['name'] as String, color: p['color'] as String, look: look);
    }
  } catch (_) {
    // storage blocked or garbage
  }
  return null;
}

void saveProfile(Profile p) => storageSet(_profileKey, jsonEncode(p.toJson()));

/// Your name and colour without a look (the 2D view's): the 3D office still has you pick a character.
void saveNameOnly(String name, String color) => storageSet(_profileKey, jsonEncode({'name': name, 'color': color}));

/// The floor you were last on, to come back to it after a reload.
String? lastFloor() => storageGet(_floorKey);

/// The panels you can show or hide on screen, from the ☰ menu.
enum HudPanel { workers, people, spend, limits, chat, floor }

/// Out of the way by default: only the chat shows until you turn the rest on.
const Map<HudPanel, bool> kHudDefaults = {
  HudPanel.workers: false,
  HudPanel.people: false,
  HudPanel.spend: false,
  HudPanel.limits: false,
  HudPanel.chat: true,
  HudPanel.floor: false,
};

/// How the office rings when a worker needs you: not at all, once, or again and again until someone's at its
/// terminal (persist.ts NEEDS_YOU_SOUNDS).
enum NeedsYouSound { off, once, remind }

class Settings {
  ViewMode view = ViewMode.first;

  /// The 👾 2D office: a pixel map from above, click to walk, no 3D drawn (easy on the GPU).
  bool twoD = false;

  /// Office sounds, 0-1.
  double volume = 0.7;
  bool muted = false;

  /// The lounge jukebox, 0-1, apart from the office sounds.
  double music = 0.5;
  bool musicMuted = false;

  /// Desktop notifications when a worker needs you while you're in another tab.
  bool notify = true;

  /// The swish of a page turning as you read at the bookshelf.
  bool pageTurns = true;

  /// The alarm when a worker stops to ask you something: not at all, once, or again every half minute until
  /// someone's at its terminal.
  NeedsYouSound needsYouSound = NeedsYouSound.once;

  /// Voice chat starts muted and V is held down to talk, instead of an open mic.
  bool pushToTalk = false;

  /// Which panels show on screen (the ☰ menu's "Show on screen").
  Map<HudPanel, bool> hud = {...kHudDefaults};

  /// The ☰ menu's actions you pinned to the top bar, by id.
  List<String> pins = [];

  /// A copy to change, like the TS `{ ...settings }`.
  Settings copy() => Settings()
    ..view = view
    ..twoD = twoD
    ..volume = volume
    ..muted = muted
    ..music = music
    ..musicMuted = musicMuted
    ..notify = notify
    ..pageTurns = pageTurns
    ..needsYouSound = needsYouSound
    ..pushToTalk = pushToTalk
    ..hud = {...hud}
    ..pins = [...pins];

  static Settings load() {
    Object? saved;
    try {
      saved = jsonDecode(storageGet(_settingsKey) ?? 'null');
    } catch (_) {
      // storage blocked or garbage
    }
    return fromJson(saved);
  }

  static Settings fromJson(Object? saved) {
    final s = Settings();
    try {
      if (saved is Map) {
        if (saved['view'] == 'third') s.view = ViewMode.third;
        if (saved['twoD'] is bool) s.twoD = saved['twoD'] as bool;
        double? unit(Object? v) => v is num && v.isFinite ? v.toDouble().clamp(0, 1) : null;
        s.volume = unit(saved['volume']) ?? s.volume;
        s.music = unit(saved['music']) ?? s.music;
        if (saved['muted'] is bool) s.muted = saved['muted'] as bool;
        if (saved['musicMuted'] is bool) s.musicMuted = saved['musicMuted'] as bool;
        if (saved['notify'] is bool) s.notify = saved['notify'] as bool;
        if (saved['pushToTalk'] is bool) s.pushToTalk = saved['pushToTalk'] as bool;
        if (saved['pageTurns'] is bool) s.pageTurns = saved['pageTurns'] as bool;
        final alarm = NeedsYouSound.values.where((v) => v.name == saved['needsYouSound']).firstOrNull;
        if (alarm != null) s.needsYouSound = alarm;
        final hud = saved['hud'];
        if (hud is Map) {
          for (final k in HudPanel.values) {
            if (hud[k.name] is bool) s.hud[k] = hud[k.name] as bool;
          }
        }
        final pins = saved['pins'];
        if (pins is List) s.pins = pins.whereType<String>().take(30).toList();
      }
    } catch (_) {
      // storage blocked
    }
    return s;
  }

  Map<String, Object?> toJson() => {
    'view': view.name,
    'twoD': twoD,
    'volume': volume,
    'muted': muted,
    'music': music,
    'musicMuted': musicMuted,
    'notify': notify,
    'pushToTalk': pushToTalk,
    'pageTurns': pageTurns,
    'needsYouSound': needsYouSound.name,
    'hud': {for (final e in hud.entries) e.key.name: e.value},
    'pins': pins,
  };

  void save() => storageSet(_settingsKey, jsonEncode(toJson()));
}

/// The worker whose worktree branch a pull request came from, if it is still at a desk.
WorkerInfo? workerForPull(Iterable<WorkerInfo> workers, GhPull pr) {
  for (final w in workers) {
    if (w.pr?.number == pr.number || (w.worktree != null && w.worktree!.branch == pr.headRefName)) return w;
  }
  return null;
}

class _Topic extends ChangeNotifier {
  void emit() => notifyListeners();
}

/// Milliseconds on this page's monotonic clock, like performance.now().
double nowMs() => _clock.elapsedMicroseconds / 1000.0;
final Stopwatch _clock = Stopwatch()..start();

class Store {
  String you = '';
  Profile profile = Profile(name: 'Guest', color: kAvatarColors[1], look: randomLook());
  Map<String, PeerInfo> peers = {};
  final Map<String, PeerPose> poses = {};
  Map<String, WorkerInfo> workers = {};
  final Map<String, ScreenState> screens = {};
  ProjectInfo? project;

  /// Every floor of the building, and the one you're on (null while there are none).
  List<FloorInfo> floors = [];
  String? floor;

  /// Where the elevator clones new projects, and who moved it there.
  ProjectsDirState projectsDir = const ProjectsDirState(dir: '');
  ({List<RepoChoice> list, String? error, bool loading, int at}) repos = (
    list: const [],
    error: null,
    loading: false,
    at: 0,
  );
  GhState<GhIssue> issues = GhState(items: const [], fetchedAt: 0, loading: true);
  GhState<GhPull> pulls = GhState(items: const [], fetchedAt: 0, loading: true);
  List<IceServer> ice = [];
  final List<ChatLine> chat = [];
  bool invites = false;

  /// Your own Claude and GitHub sign-ins, once the office has said (accounts only).
  SignInsState? signins;
  String version = '';
  TeamState? team;
  UpgradeState upgrade = UpgradeState.fromJson(const {'available': false, 'phase': 'idle'});
  ServicesState services = ServicesState.fromJson(const {'items': [], 'port': 4600});
  List<Decoration> decor = [];

  /// What the lounge jukebox plays; [jukeboxSince] is when the track started, on [nowMs]'s clock.
  JukeboxState jukebox = JukeboxState.fromJson(const {});
  double jukeboxSince = 0;

  /// The office's clock minus ours, from the quickest ping (see 'pong'); for the jukebox.
  ({double offset, double rtt})? _clockSync;

  /// The office's clock (ms since 1970) as near as this page can tell, which the DJ on the roof keeps time by.
  double officeNow() {
    final c = _clockSync;
    return c != null ? nowMs() + c.offset : DateTime.now().millisecondsSinceEpoch.toDouble();
  }

  /// The floor's whiteboard: the newest copy of every element anyone drew, deleted ones too.
  Map<String, WbElement> whiteboard = {};
  List<String> drawing = [];
  UsageState usage = UsageState.fromJson(const {});
  PlanLimits limits = PlanLimits.fromJson(const {'windows': [], 'at': 0});
  QueueState queue = QueueState.fromJson(const {'tasks': [], 'maxWorkers': 0});
  Me me = Me.fromJson(const {'admin': false});
  AccountsState? accounts;
  NotifyState notify = NotifyState.fromJson(const {});

  /// The dog on your floor, and when ([nowMs]) the leg it's on began.
  DogState? dog;
  double dogStart = 0;
  SkyState? sky;

  // ---- The building's settings, the same on every floor (⚙️ Settings) ----

  /// The holiday decorations.
  ThemeState theme = const ThemeState();

  /// The office's prompts as rewritten, and the worker everyone starts on.
  PromptsState prompts = const PromptsState();

  /// Whether workers whose pull request merged go home by themselves.
  LeaveOnMergeState leaveOnMerge = const LeaveOnMergeState();

  /// How busy the office's machine is, and its worker limit.
  MachineState machine = MachineState.empty;

  /// What the building looks like inside (see shared maps): the same on every floor.
  MapState map = const MapState();

  /// Where everything is on the building's map.
  MapPlan plan() => planOf(map.pick, map.custom);

  /// Workers sent home and kept on this floor (locked up in its dungeon, or adrift outside its airlock).
  JailState jail = const JailState();

  /// The signs over the desks, and how far the back office is built out (not the map's plan: see plan()).
  FloorPlan floorPlan = emptyPlan;

  /// The games and rooms on your floor: the cabinet, the ball, the meeting room, the machine monitor.
  final Rooms rooms = Rooms();

  /// The cars in the garage, and who's in which (state/cars.dart).
  final CarsState cars = CarsState();

  final Map<Topic, _Topic> _topics = {for (final t in Topic.values) t: _Topic()};

  /// Listen to a topic, e.g. with ListenableBuilder.
  Listenable topic(Topic t) => _topics[t]!;
  Listenable topics(Iterable<Topic> ts) => Listenable.merge([for (final t in ts) _topics[t]]);
  void emit(Topic t) => _topics[t]!.emit();

  FloorInfo? currentFloor() {
    for (final f in floors) {
      if (f.id == floor) return f;
    }
    return null;
  }

  /// Whether someone is on your floor (people on other floors aren't in the room with you).
  bool onMyFloor(PeerInfo p) => p.floor == floor;

  WorkerInfo? workerAtDesk(String deskId) {
    for (final w in workers.values) {
      if (w.deskId == deskId) return w;
    }
    return null;
  }

  /// Takes in whiteboard elements: each one newer than the copy here replaces it.
  void drew(List<WbElement> elements) {
    var changed = false;
    for (final e in elements) {
      if (!newer(e, whiteboard[e.id])) continue;
      whiteboard[e.id] = e;
      changed = true;
    }
    if (changed) emit(Topic.whiteboard);
  }

  /// The queue task for an issue: the one on the queue if there is one, else the latest finished one.
  QueueTask? taskForIssue(int issue) {
    final tasks = queue.tasks.where((t) => t.issue == issue).toList();
    for (final t in tasks) {
      if (t.status != TaskStatus.done) return t;
    }
    return tasks.isEmpty ? null : tasks.last;
  }

  void _setPeers(List<PeerInfo> list) {
    peers = {for (final p in list) p.id: p};
    poses
      ..clear()
      ..addAll({for (final p in list) p.id: PeerPose(p.x, p.y, p.z, p.rotY, p.moving)});
  }

  /// Everything on the floor you just arrived on, in place of the last one's.
  void _enter(FloorView v) {
    floor = v.floor;
    if (v.floor != null) storageSet(_floorKey, v.floor!);
    project = v.project;
    workers = {for (final w in v.workers) w.id: w};
    screens.clear(); // fresh full frames follow
    issues = v.issues;
    pulls = v.pulls;
    queue = v.queue;
    decor = v.decor;
    services = v.services;
    whiteboard = {for (final e in v.whiteboard.elements) e.id: e};
    drawing = v.whiteboard.people;
    jail = v.jail;
    floorPlan = v.plan;
    _setDog(v.dog);
    _setJukebox(v.jukebox);
    for (final t in [
      Topic.floor,
      Topic.project,
      Topic.workers,
      Topic.issues,
      Topic.pulls,
      Topic.queue,
      Topic.decor,
      Topic.services,
      Topic.dog,
      Topic.jukebox,
      Topic.whiteboard,
      Topic.drawing,
      Topic.jail,
      Topic.floorPlan,
    ]) {
      emit(t);
    }
  }

  void _setDog(DogState? d) {
    dog = d;
    dogStart = nowMs() - (d?.elapsed ?? 0);
  }

  /// When the track started on this page's clock: from the office's clock once it's known, else from `elapsed`.
  void _setJukebox(JukeboxState j) {
    jukebox = j;
    final c = _clockSync;
    jukeboxSince = c != null ? j.startedAt - c.offset : nowMs() - j.elapsed;
  }

  void apply(ServerMsg msg) {
    rooms.apply(msg);
    cars.apply(msg);
    switch (msg) {
      case WelcomeMsg m:
        // The map first, so the floor's workers sit down in its seats and not the last one's.
        map = m.map;
        emit(Topic.map);
        you = m.you;
        _setPeers(m.peers);
        floors = m.floors;
        projectsDir = m.projectsDir;
        theme = m.theme;
        prompts = m.prompts;
        leaveOnMerge = m.leaveOnMerge;
        machine = m.machine;
        ice = m.ice;
        chat
          ..clear()
          ..addAll(m.chat);
        invites = m.invites;
        version = m.version;
        upgrade = m.upgrade;
        usage = m.usage;
        limits = m.limits;
        me = m.me;
        notify = m.notify;
        _clockSync = null; // compared again, in case it's another office (or the same one, restarted)
        sky = m.sky;
        _enter(m.view);
        for (final t in [
          Topic.peers,
          Topic.chat,
          Topic.upgrade,
          Topic.usage,
          Topic.limits,
          Topic.me,
          Topic.notify,
          Topic.floors,
          Topic.sky,
        ]) {
          emit(t);
        }
        for (final t in [Topic.projectsDir, Topic.theme, Topic.prompts, Topic.leaveOnMerge, Topic.machine]) {
          emit(t);
        }
      case FloorEnterMsg m:
        _setPeers(m.peers);
        _enter(m.view);
        emit(Topic.peers);
      case FloorsMsg m:
        floors = m.floors;
        emit(Topic.floors);
      case PlanMsg m:
        floorPlan = m.plan;
        emit(Topic.floorPlan);
      case FloorReposMsg m:
        repos = (list: m.repos, error: m.error, loading: false, at: DateTime.now().millisecondsSinceEpoch);
        emit(Topic.repos);
      case PeerJoinMsg(:final peer) || PeerUpdateMsg(:final peer):
        peers[peer.id] = peer;
        final pose = poses[peer.id];
        if (pose == null) {
          poses[peer.id] = PeerPose(peer.x, peer.y, peer.z, peer.rotY, peer.moving);
        }
        emit(Topic.peers);
      case PeerMoveMsg m:
        final p = poses[m.id];
        if (p != null) {
          p
            ..x = m.x
            ..y = m.y
            ..z = m.z
            ..rotY = m.rotY
            ..moving = m.moving;
        }
      case PeerLeaveMsg m:
        peers.remove(m.id);
        poses.remove(m.id);
        emit(Topic.peers);
      case WorkerUpdateMsg m:
        workers[m.worker.id] = m.worker;
        emit(Topic.workers);
      case WorkerRemoveMsg m:
        final kept = m.jail;
        if (kept != null) {
          jail = kept;
          emit(Topic.jail);
        }
        workers.remove(m.workerId);
        screens.remove(m.workerId);
        emit(Topic.workers);
      case ScreenMsg m:
        var s = screens[m.workerId];
        if (s == null || m.full || s.cols != m.cols || s.rows != m.rows) {
          s = ScreenState(cols: m.cols, rows: m.rows, cursor: m.cursor, version: (s?.version ?? 0) + 1);
          screens[m.workerId] = s;
        }
        s.lines.addAll(m.lines);
        s.cursor = m.cursor;
        s.version++;
        emit(Topic.screens);
      case GhIssuesMsg m:
        issues = m.state;
        emit(Topic.issues);
      case GhPullsMsg m:
        pulls = m.state;
        emit(Topic.pulls);
      case TeamMsg m:
        team = m.state;
        emit(Topic.team);
      case MeMsg m:
        me = m.me;
        emit(Topic.me);
      case AccountsMsg m:
        accounts = m.state;
        emit(Topic.accounts);
      case UpgradeMsg m:
        upgrade = m.state;
        emit(Topic.upgrade);
      case ServicesMsg m:
        services = m.state;
        emit(Topic.services);
      case DecorMsg m:
        decor = m.items;
        emit(Topic.decor);
      case JukeboxMsg m:
        _setJukebox(m.state);
        emit(Topic.jukebox);
      case PongMsg m:
        // The answer that came back quickest says best how the two clocks line up.
        final rtt = nowMs() - m.at;
        final c = _clockSync;
        if (c != null && rtt >= c.rtt) break;
        _clockSync = (offset: m.now - (m.at + rtt / 2), rtt: rtt);
        final was = jukeboxSince;
        _setJukebox(jukebox);
        if ((jukeboxSince - was).abs() > 20) emit(Topic.jukebox);
      case WbUpdateMsg m:
        drew(m.elements);
      case WbPeopleMsg m:
        drawing = m.people;
        emit(Topic.drawing);
      case UsageMsg m:
        usage = m.state;
        emit(Topic.usage);
      case LimitsMsg m:
        limits = m.state;
        emit(Topic.limits);
      case QueueMsg m:
        queue = m.state;
        emit(Topic.queue);
      case NotifyMsg m:
        notify = m.state;
        emit(Topic.notify);
      case DogMsg m:
        _setDog(m.dog);
        emit(Topic.dog);
      case SignInsMsg m:
        signins = m.state;
        emit(Topic.signins);
      case SkyMsg m:
        sky = m.state;
        emit(Topic.sky);
      case ProjectsDirMsg m:
        projectsDir = m.state;
        emit(Topic.projectsDir);
      case ThemeMsg m:
        theme = m.state;
        emit(Topic.theme);
      case MapMsg m:
        // Onto another map: nobody's on a seat of the last one any more (the office forgot them too).
        final moved = m.state.pick != map.pick;
        map = m.state;
        if (moved) {
          peers = {
            for (final e in peers.entries)
              e.key: e.value.seat == null ? e.value : PeerInfo.fromJson(e.value.toJson()..remove('seat')),
          };
        }
        emit(Topic.map);
        if (moved) emit(Topic.peers);
      case PromptsMsg m:
        prompts = m.state;
        emit(Topic.prompts);
      case LeaveOnMergeMsg m:
        leaveOnMerge = m.state;
        emit(Topic.leaveOnMerge);
      case MachineMsg m:
        machine = m.state;
        emit(Topic.machine);
      case ChatMsg m:
        chat.add(m.line);
        if (chat.length > 200) chat.removeAt(0);
        emit(Topic.chat);
      default:
        break;
    }
  }
}
