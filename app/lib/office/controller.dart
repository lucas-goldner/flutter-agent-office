// The office: everything that happens on your floor, wired together. A port of main.ts: it keeps
// the scene in step with the store (people, workers, their laptops, the dog, the boards), runs the
// frame loop (you, the camera, everyone else, the sky, sounds), and does what the keys and the
// windows ask (hire, prompt, send home, sit, coffee, the gong…).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../audio/sound.dart';
import '../caffeine.dart';
import '../interop/browser.dart';
import '../interop/open_link.dart';
import '../net/api.dart';
import '../net/office_socket.dart' hide Profile;
import '../notify.dart';
import '../office_scope.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/floors.dart';
import 'package:office_shared/jukebox.dart';
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import 'package:office_shared/layout.dart' as lay show Elevator;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof;
import 'package:office_shared/status.dart';
import '../state/store.dart';
import '../ui/ask.dart';
import '../ui/boards.dart';
import '../ui/changes.dart';
import '../ui/character.dart';
import '../ui/elevator.dart';
import '../ui/floormenu.dart';
import '../ui/help.dart';
import '../ui/hud.dart';
import '../ui/jukebox.dart';
import '../ui/menu_logic.dart' show waitingInOrder, waitingLabel;
import '../ui/modal.dart';
import '../ui/prompt.dart';
import '../ui/provider.dart';
import '../ui/pull.dart';
import '../ui/queue.dart';
import '../ui/search.dart';
import '../ui/services.dart';
import '../ui/settings.dart';
import '../ui/team.dart';
import '../ui/accounts.dart';
import '../ui/arcade.dart';
import '../ui/terminal.dart';
import '../ui/title.dart' show waitingElsewhere;
import '../ui/upgrade.dart';
import '../ui/whiteboard.dart';
import '../ui/whiteboard_logic.dart' show othersDrawing, whiteboardHint;
import '../ui/usage.dart' show hiringPaused, usageLabel, usageTitle;
import '../ui/worker_text.dart' show statusLabel;
import '../voice/office_voice.dart';
import '../world/board_faces.dart';
import '../world/character.dart';
import '../world/collider.dart';
import '../world/confetti.dart';
import '../world/dog.dart';
import '../world/gallery.dart';
import '../world/hands.dart';
import '../world/label_widgets.dart';
import '../world/labels.dart';
import '../world/laptop.dart';
import '../world/leaving.dart';
import '../world/office/office.dart';
import '../world/player.dart';
import '../world/sky_model.dart';
import '../world/sky_view.dart';
import '../world/smoke.dart';
import '../world/space.dart';
import '../world/toon.dart';
import 'blast.dart';
import 'hanging.dart';

/// How close (meters) you stop a worker jumping, and how far you go before it starts again.
const double _holdNear = 4;
const double _holdLeave = 5;
const int _smokeBreakMs = 90000;

/// How close (meters from your eyes) you must be to use each kind of thing.
const Map<InteractKind, double> _reach = {
  InteractKind.desk: 4.5,
  InteractKind.coffee: 3,
  InteractKind.issues: 9,
  InteractKind.pulls: 9,
  InteractKind.services: 9,
  InteractKind.queue: 9,
  InteractKind.tv: 10,
  InteractKind.decor: 9,
  InteractKind.smoke: 3,
  InteractKind.elevator: 4.5,
  InteractKind.gong: 3.5,
  InteractKind.dog: 3.2,
  InteractKind.jukebox: 4,
  InteractKind.seat: 3,
  InteractKind.whiteboard: 7,
};

/// Keys that use what you're facing: at a desk, each does something else (see [_interact]).
enum DeskKey { e, p, r, x, b, c, o }

final Map<PhysicalKeyboardKey, DeskKey> _deskKeys = {
  PhysicalKeyboardKey.keyE: DeskKey.e,
  PhysicalKeyboardKey.keyP: DeskKey.p,
  PhysicalKeyboardKey.keyR: DeskKey.r,
  PhysicalKeyboardKey.keyX: DeskKey.x,
  PhysicalKeyboardKey.keyB: DeskKey.b,
  PhysicalKeyboardKey.keyC: DeskKey.c,
  PhysicalKeyboardKey.keyO: DeskKey.o,
};

class _Remote {
  _Remote(this.person, this.look);
  final Person person;
  Look look;
  String label = '';
  double stepT = 0;
  WorldLabel? bubble;
  double bubbleUntil = 0;
}

class _WorkerView {
  _WorkerView(this.model, this.laptop, this.deskId);
  final Worker model;
  final Laptop laptop;
  final String deskId;
  WorkerStatus? status;
  bool acked = true;
}

/// A desk as Departures needs it.
class _Leaving implements LeavingDesk {
  _Leaving(this.view);
  final DeskView view;
  @override
  DeskDef get def => view.def;
  @override
  Node? get chair => view.def.beanbag ? null : view.chair;
}

class OfficeController implements OfficeActions {
  OfficeController();

  final Store store = Store();
  late final OfficeSocket net = OfficeSocket(
    profile: () => (name: store.profile.name, color: store.profile.color, look: store.profile.look),
    floor: () => store.floor ?? lastFloor(),
  );
  final Settings settings = Settings.load();
  final Scene scene = Scene();
  final LabelHub labels = LabelHub();
  final Node root = officeRoot();
  late final OfficeScope scope = OfficeScope(
    store: store,
    net: net,
    settings: settings,
    actions: this,
    child: const SizedBox(),
  );

  // What the page shows over the scene.
  final ValueNotifier<bool> ready = ValueNotifier(false);
  final ValueNotifier<bool> connected = ValueNotifier(true);
  final ValueNotifier<List<HintPart>?> hint = ValueNotifier(null);
  final ValueNotifier<CrosshairState> crosshair = ValueNotifier(const CrosshairState());
  final ValueNotifier<VoiceState> voice = ValueNotifier(const VoiceState(available: false));
  final ValueNotifier<bool> hanging = ValueNotifier(false);
  final ValueNotifier<Color> sky = ValueNotifier(const Color(0xFFBFE3FF));
  final ValueNotifier<bool> fade = ValueNotifier(false);

  /// The white flash of a floor being blown up under you, 0-1 (see [Blast]).
  final ValueNotifier<double> flash = ValueNotifier(0);
  final Blast blast = Blast();

  /// Messages held back while the floor you're on blows up, so the ride down waits for the boom.
  List<ServerMsg>? _held;
  late final HudController hud = HudController(
    HudCallbacks(
      onElevator: showElevator,
      onVoice: () => voiceRoom.toggleVoice(),
      onMute: () => voiceRoom.toggleMute(),
      onShare: () => voiceRoom.toggleShare(),
      onIssues: () => openBoard(scope, BoardKind.issues),
      onPulls: () => openBoard(scope, BoardKind.pulls),
      onServices: () => openServices(scope),
      onQueue: showQueue,
      onTeam: () => openTeam(scope),
      onAccounts: () => openAccounts(scope),
      onUpgrade: () => openUpgrade(scope),
      onSearch: showSearch,
      onWhiteboard: () => whiteboard.open(),
      onDecor: () => hanger.active ? hanger.cancel() : hanger.start(),
      onSettings: showSettings,
      onHelp: openHelp,
      onOpenWorker: openWorkerTerminal,
      onEditProfile: editProfile,
      onFloors: showFloors,
      onTalk: talk,
    ),
    prefs: HudPrefs(settings: settings, save: settings.save)..actions = hudActions(),
  );

  late final Office office;

  /// Voice chat and screen sharing (the TV, the thumbnails, mouths and proximity volume).
  late final OfficeVoice voiceRoom;
  /// The 📝 whiteboard: its window, and the drawing on the board in the office.
  late final WhiteboardHub whiteboard;
  late final PlayerController player;
  late final Person me;
  late final Hands hands;
  late final Dog dog;
  late final Departures departures;
  late final Confetti confetti;
  late final Smoke smoke;
  late final OfficeSound sound;
  late final DesktopNotifier notifier;
  late final Gallery gallery;
  late final Hanger hanger;
  late final Arcade arcade;
  final SkyModel skyModel = SkyModel();
  late final SkyView skyView;
  final Caffeine caffeine = Caffeine();

  final Map<String, _Remote> _remotes = {};
  final Map<String, _WorkerView> _workerViews = {};

  /// Workers a `worker.remove` is taking out of the store right now: they walk out of the building.
  final Set<String> _sentHome = {};
  final List<VoidCallback> _unsubscribe = [];
  StreamSubscription<ServerMsg>? _messages;
  bool _firstWelcome = true;
  String _bootVersion = '';
  UpgradePhase? _upgradePhase;
  ({String floor, Timer timer})? _riding;
  int _painted = -1;

  Interactable? _target;
  String _hintKey = '';
  double _elapsed = 0;
  double _lastSentAt = -1e9;
  ({double x, double y, double z, double rotY, bool moving}) _lastSent = (x: 0, y: 0, z: 0, rotY: 0, moving: false);
  int _stride = 0;
  double _fallV = 0;
  double _smokeBreakUntil = 0;
  double _lastHit = 0;
  double _lastActSent = 0;
  bool _askedToNotify = false;

  /// The camera this frame, in engine space.
  late PerspectiveCamera camera = PerspectiveCamera(fovRadiansY: 55 * math.pi / 180, fovNear: 0.1, fovFar: 200);

  // ---- Boot -----------------------------------------------------------------------------------

  Future<void> init() async {
    await Scene.initializeStaticResources();
    await Toon.init();
    scene.toneMapping = ToneMappingMode.linear;
    scene.fog
      ..enabled = true
      ..mode = FogMode.linear;
    scene.add(root);
    // Dev switches for measuring what costs what: ?aa=none&scale=0.5&boards=0&hands=0&labels=0.
    final q = _query;
    if (q['aa'] == 'none') scene.antiAliasingMode = AntiAliasingMode.none;
    if (q['aa'] == 'fxaa') scene.antiAliasingMode = AntiAliasingMode.fxaa;
    if (q['scale'] != null) scene.renderScale = double.tryParse(q['scale']!) ?? 1;
    devHands = q['hands'] != '0';
    devPerf = q['perf'] == '1';
    if (q['hour'] != null || q['weather'] != null) {
      skyModel.show(SkyPreview(hour: double.tryParse(q['hour'] ?? ''), weather: q['weather'] == null ? null : Weather.parse(q['weather'])));
    }
    devLabels = q['labels'] != '0';

    office = buildOffice(labels: labels);
    root.add(office.group);
    voiceRoom = OfficeVoice(store: store, net: net, tv: office.tvScreen, state: voice);
    whiteboard = WhiteboardHub(scope, office.whiteboard);
    if (q['boards'] != '0') _mountBoards();
    skyView = SkyView(root, office.night);
    confetti = Confetti((x, z, y) => groundAt(office.colliders, x, z, y));
    smoke = Smoke();
    root
      ..add(confetti.node)
      ..add(smoke.node);

    final saved = loadProfile();
    final me0 = await Api.whoami().catchError((_) => null);
    if (me0 == null && kReleaseMode) return goTo('/login');
    final account = (me0?['me'] as Map?)?['account'] as Map?;
    if (saved != null) {
      store.profile
        ..name = account?['name'] as String? ?? saved.name
        ..color = saved.color
        ..look = saved.look ?? store.profile.look;
    } else if (account != null) {
      store.profile.name = account['name'] as String;
    }

    me = Person(store.profile.name, store.profile.color, store.profile.look, labels)..showLabel(false);
    root.add(me.root);
    player = PlayerController(office.colliders)..view = settings.view;
    player.onStand = _gotUp;
    _placeInCar();
    hands = Hands(store.profile.color, me.skinColor);
    root.add(hands.root);
    me.onSmoke = _myPuff;

    sound = OfficeSound(clock: nowMs)
      ..setVolume(settings.volume, settings.muted)
      ..setMusicVolume(settings.music, settings.musicMuted);
    sound.onMusicError = (text) => toast(text, ToastKind.warn);
    skyModel.onThunder = (delay, loud) => sound.thunder(delay, loud);

    // The floor's dog. It goes quiet once someone has the terminal of the worker it's barking at open.
    dog = Dog(sound, (id) => (store.workers[id]?.viewers.length ?? 0) > 0, labels, now: nowMs);
    root.add(dog.root);
    departures = Departures(
      root,
      (x, z, y) => groundAt(office.colliders, x, z, y),
      (x, y, z) => sound.stepAt(x, z, y),
      (deskId) {
        final desk = office.desks[deskId];
        if (desk != null && store.workerAtDesk(deskId) == null) desk.vacancy.visible = true;
        _arrangeBeanbags();
      },
    );
    notifier = DesktopNotifier(enabled: () => settings.notify, openWorker: openWorkerTerminal);
    // Pictures on the walls (and the one you're hanging), and DEADFALL on the boss's monitor.
    gallery = Gallery();
    office.group.add(gallery.group);
    hanger = Hanger(scope: scope, player: player, office: office, gallery: gallery, camera: () => camera);
    hanger.onChange = () {
      hanging.value = hanger.active;
      _hintKey = 'stale';
    };
    root.add(hanger.ghost.group);
    arcade = Arcade(office.bossScreen);
    _listen(Topic.decor, () => gallery.sync(store.decor));

    _listen(Topic.peers, _syncPeers);
    _listen(Topic.workers, _syncWorkers);
    _listen(Topic.floors, _paintFloor);
    _listen(Topic.dog, () => dog.sync(store.dog, store.dogStart));
    _listen(Topic.jukebox, _syncJukebox);
    _listen(Topic.sky, () {
      if (store.sky != null) skyModel.set(store.sky!);
    });
    _unsubscribe
      ..add(watchTabTitle(store))
      ..add(watchFloorsWaiting(store, ding: () => sound.ding(Ding.needsInput)));
    net.status.listen((up) => connected.value = up);
    HardwareKeyboard.instance.addHandler(_onKeyUp);
    _unsubscribe.add(() => HardwareKeyboard.instance.removeHandler(_onKeyUp));
    _messages = net.messages.listen(_onMessage);

    ready.value = true;
    if (saved?.look != null) {
      net.connect();
    } else {
      // Pick a character first (people from before there was a choice keep their name and colour).
      openCharacter(
        scope,
        first: true,
        onSave: (p) {
          _showMyProfile(p);
          net.connect();
        },
      );
    }
  }

  void _listen(Topic t, VoidCallback fn) {
    store.topic(t).addListener(fn);
    _unsubscribe.add(() => store.topic(t).removeListener(fn));
  }

  void dispose() {
    for (final f in _unsubscribe) {
      f();
    }
    _messages?.cancel();
    voiceRoom.dispose();
    hanger.dispose();
    whiteboard.dispose();
    net.close();
  }

  // ---- Boards: each face is a live Flutter widget on the wall -----------------------------------

  void _mountBoards() {
    void mount(String key, Widget face) {
      final f = office.boardMeshes[key];
      if (f == null) return;
      f.material.baseColorFactor = vm.Vector4(1, 1, 1, 1);
      f.node.addComponent(
        WidgetComponent.bindOnly(
          size: kFaceSize,
          pixelRatio: 0.9,
          update: const WidgetUpdatePolicy.interval(Duration(milliseconds: 500)),
          input: WidgetInput.manual,
          bind: (t) => f.material.baseColorTexture = GpuTextureSource(t),
          child: face,
        ),
      );
    }

    mount('issues', CorkBoardFace(store: store, kind: CorkKind.issues));
    mount('pulls', CorkBoardFace(store: store, kind: CorkKind.pulls));
    mount('services', ServicesBoardFace(store: store));
    mount('queue', QueueBoardFace(store: store));
  }

  // ---- Messages ---------------------------------------------------------------------------------

  void _onMessage(ServerMsg msg) {
    final held = _held;
    if (held != null && msg is! WelcomeMsg) return held.add(msg);
    if (msg is FloorsMsg && floorBlownUp(store.floor, msg.floors)) _blowUp();
    if (msg is WelcomeMsg) voiceRoom.beforeWelcome();
    if (msg is WelcomeMsg || msg is FloorEnterMsg) departures.clear();
    if (msg is WorkerRemoveMsg) _sentHome.add(msg.workerId);
    try {
      store.apply(msg);
    } catch (e, st) {
      // One bad listener mustn't stop the rest of the message from being handled.
      debugPrint('store.apply(${msg.runtimeType}) failed: $e\n$st');
    }
    _sentHome.clear();
    whiteboard.route(msg);
    switch (msg) {
      case WelcomeMsg m:
        // A few pings, to line this page's clock up with the office's for the jukebox.
        for (var i = 0; i < 5; i++) {
          Timer(Duration(milliseconds: 200 + i * 500), () => net.send(PingCmd(nowMs())));
        }
        final mine = store.peers[store.you];
        if (_firstWelcome && mine != null) {
          _placeInCar((x: mine.x, z: mine.z));
          _firstWelcome = false;
          _arrive();
          _devPlace();
        } else if (store.floor == null) {
          _arrive();
        }
        if (player.seat != null) net.send(SitCmd(seat: player.seat!.key));
        // Back from a restart on another version: this page's code is stale, so load the new one.
        if (_bootVersion.isEmpty) {
          _bootVersion = m.version;
        } else if (m.version != _bootVersion || restarting()) {
          showUpgraded(m.upgrade);
        }
        _upgradePhase = m.upgrade.phase;
        voiceRoom.welcomed();
      case RtcMsg m:
        voiceRoom.signal(m.from, m.data);
      case FloorEnterMsg _:
        _arrive();
      case ToastMsg m:
        toast(m.text, switch (m.level) {
          ToastLevel.warn => ToastKind.warn,
          ToastLevel.error => ToastKind.error,
          _ => ToastKind.info,
        });
      case UpgradeMsg m:
        if (m.state.phase == UpgradePhase.restarting) showRestarting(m.state, scope);
        if (m.state.phase == UpgradePhase.failed && _upgradePhase == UpgradePhase.building) {
          toast(
            'The upgrade failed, so the office stays on ${m.state.current?.sha ?? 'this version'}',
            ToastKind.error,
          );
        }
        _upgradePhase = m.state.phase;
      case ChatMsg m:
        _sayBubble(m.line.from, m.line.text);
      case PeerActMsg m:
        final r = _remotes[m.id];
        if (m.smoke == null) {
          r?.person.reach();
        } else {
          r?.person.setSmoking(m.smoke!);
        }
      case GongMsg m:
        _gongRang(m.why, m.pr);
      default:
        break;
    }
  }

  /// Dev switch for screenshots: ?at=x,z[,yaw[,pitch[,y]]] puts you there, ?view=third orbits.
  void _devPlace() {
    final q = _query;
    if (q['view'] == 'third') player.setView(ViewMode.third);
    final at = q['at']?.split(',').map(double.tryParse).toList();
    if (at == null || at.length < 2 || at[0] == null || at[1] == null) return;
    player.pos.setValues(at[0]!, at.length > 4 ? at[4] ?? 0 : 0, at[1]!);
    if (at.length > 2 && at[2] != null) {
      player.facing = at[2]!;
      player.camYaw = player.facing - math.pi;
    }
    if (at.length > 3 && at[3] != null) {
      player.lookPitch = at[3]!;
      player.camPitch = at[3]!.abs();
    }
    player.updateCamera(snap: true);
  }

  // ---- Floors & the elevator --------------------------------------------------------------------

  /// In the car, facing out through the doors: where you are when you arrive on a floor.
  void _placeInCar([({double x, double z})? at]) {
    if (player.seat != null) standUp();
    final spot = at != null && inElevator(at.x, at.z)
        ? at
        : (x: lay.Elevator.x, z: (ElevatorCar.minZ + ElevatorCar.maxZ) / 2);
    player.pos.setValues(spot.x, 0, spot.z);
    player.vy = 0;
    player.facing = 0;
    player.camYaw = player.facing - math.pi;
    player.lookPitch = -0.08;
  }

  @override
  void showElevator() => openElevator(scope, ride: ride);

  // ---- The HUD: a few buttons on the top bar, everything else in the ☰ menu (#100) -------------

  /// What the ☰ menu offers; any of them can be pinned to the top bar. Other parts of the office add
  /// theirs here.
  List<HudAction> hudActions() {
    int open<T>(Iterable<T> xs, bool Function(T) f) => xs.where(f).length;
    String? noMedia() => voice.value.available
        ? null
        : desktopApp
        ? notInDesktopApp('Voice chat and screen sharing')
        : 'Voice and screen sharing need HTTPS or localhost — use a TLS proxy, --self-signed, or an SSH tunnel';
    List<WorkerInfo> waiting() => waitingInOrder(store.workers.values);
    UpgradeState u() => store.upgrade;
    return [
      HudAction(
        id: 'issues',
        icon: '📌',
        label: 'Issues',
        section: HudSection.open,
        count: () => open(store.issues.items, (i) => i.state == 'OPEN'),
        run: () => openBoard(scope, BoardKind.issues),
      ),
      HudAction(
        id: 'pulls',
        icon: '🔀',
        label: 'Pull requests',
        section: HudSection.open,
        count: () => open(store.pulls.items, (p) => p.state == 'OPEN'),
        run: () => openBoard(scope, BoardKind.pulls),
      ),
      HudAction(
        id: 'queue',
        icon: '📋',
        label: 'Task queue',
        section: HudSection.open,
        count: () => open(store.queue.tasks, (t) => t.status != TaskStatus.done),
        title: () => 'Issues and tasks waiting for a worker',
        run: showQueue,
      ),
      HudAction(
        id: 'services',
        icon: '🌐',
        label: 'Services',
        section: HudSection.open,
        count: () => store.services.items.length,
        title: () => 'Web servers the workers are running',
        run: () => openServices(scope),
      ),
      HudAction(
        id: 'whiteboard',
        icon: '📝',
        label: 'Whiteboard',
        section: HudSection.open,
        title: () => 'Draw together, live',
        run: () => whiteboard.open(),
      ),
      HudAction(
        id: 'search',
        icon: '🔎',
        label: 'Search',
        section: HudSection.open,
        key: '/',
        title: () => 'Search the chat and every terminal',
        run: showSearch,
      ),
      HudAction(
        id: 'elevator',
        icon: '🛗',
        label: 'Elevator',
        section: HudSection.open,
        count: () => waitingElsewhere(store.floors, store.floor),
        title: () => 'Ride to another project',
        run: showElevator,
      ),
      // Up on the top bar while workers wait on someone (N does the same), next to the Workers button.
      HudAction(
        id: 'waiting',
        icon: '🙋',
        iconOf: () => waiting().any((w) => w.status == WorkerStatus.needsInput) ? '🙋' : '✅',
        label: 'Next worker that needs you',
        section: HudSection.open,
        key: 'N',
        shown: () => waiting().isNotEmpty,
        status: () => waiting().isNotEmpty,
        chip: () => waitingLabel(waiting()).replaceFirst(RegExp(r'^(🙋|✅) '), ''),
        on: () => waiting().every((w) => w.status == WorkerStatus.done),
        tone: () => waiting().any((w) => w.status == WorkerStatus.needsInput) ? HudTone.danger : null,
        title: () => 'Go to the worker that has waited longest on someone (N)',
        run: () {
          final w = waiting().firstOrNull;
          if (w != null) goToDesk(w.deskId);
        },
      ),
      // In voice, V is push to talk, so leaving is only from here.
      HudAction(
        id: 'voice',
        icon: '🎙️',
        label: 'Join voice',
        labelOf: () => voice.value.inVoice ? 'Leave voice' : 'Join voice',
        section: HudSection.together,
        keyOf: () => voice.value.inVoice ? null : 'V',
        on: () => voice.value.inVoice,
        blocked: noMedia,
        run: () => voiceRoom.toggleVoice(pushToTalk: settings.pushToTalk),
      ),
      // While you're in voice, the top bar keeps the mute button handy. Muted is the usual with push
      // to talk, so it doesn't stand out then.
      HudAction(
        id: 'mute',
        icon: '🎙️',
        iconOf: () => voice.value.muted ? '🔇' : '🎙️',
        label: 'Mute',
        labelOf: () => voice.value.muted ? 'Unmute' : 'Mute',
        section: HudSection.together,
        key: 'M',
        shown: () => voice.value.inVoice,
        status: () => voice.value.inVoice,
        on: () => voice.value.inVoice,
        tone: () => voice.value.muted && !settings.pushToTalk ? HudTone.danger : null,
        title: () => voice.value.muted ? 'Muted: hold V to talk, or M to unmute' : 'Mute (M) · hold V to talk',
        run: () => voiceRoom.toggleMute(),
      ),
      HudAction(
        id: 'share',
        icon: '🖥️',
        label: 'Share screen',
        labelOf: () => voice.value.sharing ? 'Stop sharing' : 'Share screen',
        section: HudSection.together,
        on: () => voice.value.sharing,
        status: () => voice.value.sharing,
        chip: () => 'Sharing',
        blocked: noMedia,
        run: () => voiceRoom.toggleShare(),
      ),
      HudAction(
        id: 'decor',
        icon: '🖼️',
        label: 'Hang a picture',
        labelOf: () => hanging.value ? 'Stop hanging the picture' : 'Hang a picture',
        section: HudSection.together,
        key: 'F',
        on: () => hanging.value,
        status: () => hanging.value,
        run: () => hanger.active ? hanger.cancel() : hanger.start(),
      ),
      HudAction(
        id: 'team',
        icon: '👥',
        label: 'Invite teammates',
        section: HudSection.together,
        shown: () => store.invites,
        run: () => openTeam(scope),
      ),
      HudAction(
        id: 'accounts',
        icon: '🔑',
        label: 'Accounts',
        section: HudSection.together,
        shown: () => store.me.admin,
        title: () => 'Invite people, see who has an account, revoke them',
        run: () => openAccounts(scope),
      ),
      HudAction(id: 'settings', icon: '⚙️', label: 'Settings', section: HudSection.office, run: showSettings),
      HudAction(id: 'help', icon: '❓', label: 'Controls', section: HudSection.office, key: 'H', run: openHelp),
      HudAction(
        id: 'upgrade',
        icon: '⬆️',
        label: 'Upgrade the office',
        labelOf: () => u().phase == UpgradePhase.building
            ? 'Upgrading…'
            : u().latest != null
            ? 'Update the office'
            : 'Upgrade the office',
        section: HudSection.office,
        shown: () => u().available,
        // A new version, or one being built, gets a place on the top bar until it's in.
        status: () => u().latest != null || u().phase == UpgradePhase.building,
        chip: () => u().phase == UpgradePhase.building ? 'Upgrading…' : 'Update',
        tone: () => u().latest != null && u().phase != UpgradePhase.building ? HudTone.primary : null,
        title: () => u().latest != null ? 'New version: ${u().latest!.subject}' : 'Upgrade the office',
        run: () => openUpgrade(scope),
      ),
    ];
  }

  /// The project in the corner: the floor list under it, or the elevator while there's no floor yet.
  void showFloors(Rect? anchor) {
    if (store.floor == null) return showElevator();
    toggleFloorMenu(
      store,
      FloorMenuOptions(go: switchFloor, elevator: showElevator, roof: () => ride(roof)),
      anchor: anchor,
    );
  }

  /// Straight to another floor from the floor list, to the same spot in the office you're in now.
  void switchFloor(String floorId) {
    // The roof isn't laid out like a floor: to and from it, it's the elevator.
    if (store.floor == roof || floorId == roof) return ride(floorId);
    if (_riding != null || floorId == store.floor) return;
    ModalStack.instance.closeAll();
    hanger.cancel();
    if (player.seat != null) standUp();
    _riding = (floor: floorId, timer: Timer(const Duration(seconds: 10), _rideFailed));
    player.enabled = false;
    player.input.clear();
    fade.value = true;
    final p = player.pos;
    Timer(
      const Duration(milliseconds: 170),
      () => net.send(FloorGoCmd(floorId, at: (x: p.x, y: p.y, z: p.z, rotY: player.facing))),
    );
  }

  /// V: joins voice, and in it, push to talk: the mic is on while it's held (see [_onKeyUp]).
  /// False when there's nothing to do with it (so it isn't eaten).
  bool talk(bool down) {
    if (!down) {
      voiceRoom.stopTalking();
      return true;
    }
    if (voice.value.inVoice) {
      voiceRoom.startTalking();
    } else {
      voiceRoom.joinVoice(pushToTalk: settings.pushToTalk);
    }
    return true;
  }

  /// Letting go of V mutes you again, wherever the key comes up: a window or a terminal opened meanwhile.
  bool _onKeyUp(KeyEvent e) {
    if (e is KeyUpEvent && e.physicalKey == PhysicalKeyboardKey.keyV) talk(false);
    return false;
  }

  /// Rides the elevator to another floor. From outside the car, you step in while the lights are down.
  @override
  void ride(String floorId) {
    if (_riding != null || floorId == store.floor) return;
    ModalStack.instance.closeAll();
    hanger.cancel();
    final inside = inElevator(player.pos.x, player.pos.z);
    _riding = (floor: floorId, timer: Timer(const Duration(seconds: 10), _rideFailed));
    player.enabled = false;
    player.input.clear();
    office.elevator.setOpen(false);
    // Wait for the doors to shut on you, then dim the lights and go.
    Timer(Duration(milliseconds: inside ? 650 : 0), () {
      fade.value = true;
      Timer(const Duration(milliseconds: 320), () {
        _placeInCar(inside ? (x: player.pos.x, z: player.pos.z) : null);
        net.send(FloorGoCmd(floorId));
      });
    });
  }

  /// Someone blew the floor you're on off the building (💣 in the elevator): a flash, smoke and
  /// debris and the screen shaking, then the lights go down and you ride to the next floor.
  void _blowUp() {
    if (_held != null) return;
    _held = [];
    ModalStack.instance.closeAll();
    hanger.cancel();
    if (player.seat != null) standUp();
    player.enabled = false;
    player.input.clear();
    // Out in front of you, where you'll see it.
    final fwd = (player.camTarget - player.camPos)
      ..y = 0
      ..normalize();
    final at = vm.Vector3(player.pos.x, 0.2, player.pos.z) + fwd * 5;
    blast.start();
    smoke.plume(at);
    confetti.burst(at.x, at.y + 0.5, at.z, 90, 1.4);
    sound.thunder(0, 1);
    Timer(Duration(milliseconds: (Blast.ride * 1000).round()), () {
      fade.value = true;
      Timer(const Duration(milliseconds: 350), () {
        final msgs = _held ?? const [];
        _held = null;
        for (final m in msgs) {
          _onMessage(m);
        }
        // Nothing came (no next floor to go to, or the office is gone): back as you were.
        if (!msgs.any((m) => m is FloorEnterMsg)) {
          fade.value = false;
          player.enabled = !ModalStack.instance.open;
        }
      });
    });
  }

  /// The floor never came (it's gone, or the office is unreachable): open up where you are.
  void _rideFailed() {
    if (_riding == null) return;
    _riding = null;
    fade.value = false;
    office.elevator.setOpen(store.floor != null);
    player.enabled = !ModalStack.instance.open;
  }

  void _paintFloor() {
    final p = store.currentFloor()?.palette ?? 0;
    if (p == _painted) return;
    _painted = p;
    office.setLook(floorPalette(p));
  }

  /// You're on a floor (or in the building without one): paint it, and open the doors.
  void _arrive() {
    _paintFloor();
    office.setProjectName(store.project?.name ?? 'Agent Office');
    final r = _riding;
    if (r != null) {
      r.timer.cancel();
      _riding = null;
    }
    if (store.floor == null) {
      // Nowhere to go yet: the doors stay shut until there's a floor, and the panel says how to add one.
      office.elevator.setOpen(false);
      fade.value = false;
      player.enabled = !ModalStack.instance.open;
      showElevator();
      return;
    }
    fade.value = false;
    Timer(const Duration(milliseconds: 450), () {
      office.elevator.setOpen(true);
      sound.ding(Ding.done);
      player.enabled = !ModalStack.instance.open;
    });
  }

  // ---- Peers ------------------------------------------------------------------------------------

  void _syncPeers() {
    for (final peer in store.peers.values) {
      // Only who's on your floor is in the room with you.
      if (peer.id == store.you || !store.onMyFloor(peer)) continue;
      var r = _remotes[peer.id];
      if (r == null) {
        final person = Person(peer.name, peer.color, peer.look, labels)..onSmoke = _puff;
        person.root.position = vm.Vector3(peer.x, peer.y, peer.z);
        root.add(person.root);
        r = _Remote(person, peer.look);
        _remotes[peer.id] = r;
      }
      final label = '${peer.name}|${peer.voice ? (peer.muted ? 'm' : 'v') : '-'}|${peer.color}';
      if (label != r.label) {
        r.label = label;
        r.person.setLabel(peer.name, peer.voice ? peer.muted : null);
        r.person.setColor(peer.color);
      }
      if (!sameLook(peer.look, r.look)) {
        r.look = peer.look;
        r.person.setLook(peer.look);
      }
      r.person.setSmoking(peer.smoking ?? false);
      r.person.sit(peer.seat != null ? seatAt(peer.seat!)?.hips : null);
    }
    for (final id in _remotes.keys.toList()) {
      final peer = store.peers[id];
      if (peer == null || !store.onMyFloor(peer)) {
        final r = _remotes.remove(id)!;
        labels.remove(r.bubble);
        r.person.root.detach();
        r.person.dispose();
      }
    }
  }

  void _sayBubble(String from, String text) {
    if (from == store.you) return;
    final r = _remotes[from];
    if (r == null) return;
    labels.remove(r.bubble);
    r.bubble = labels.add(
      WorldLabel(
        anchor: r.person.root,
        offset: vm.Vector3(0, 2.45, 0),
        child: TagPill('💬 ${clip(text, 60)}', bg: '#ffffff', size: 34),
      ),
    );
    r.bubbleUntil = nowMs() + 6000;
  }

  // ---- Workers ----------------------------------------------------------------------------------

  void _syncWorkers() {
    for (final w in store.workers.values) {
      final desk = office.desks[w.deskId];
      if (desk == null) continue;
      var v = _workerViews[w.id];
      if (v == null) {
        departures.vacate(w.deskId);
        final model = Worker(w.name, w.color, labels);
        desk.seatAnchor.add(model.root);
        final laptop = Laptop();
        desk.laptopAnchor.add(laptop.root);
        desk.vacancy.visible = false;
        desk.chair.rotation = vm.Quaternion.identity();
        v = _WorkerView(model, laptop, w.deskId);
        _workerViews[w.id] = v;
      }
      if (v.status != w.status || v.acked != w.acked) {
        // It just finished or started waiting on you: ding, and notify if you're away.
        if (waitingOnSomeone(w) && v.status != null && w.status != v.status) {
          final ding = Ding.fromStatus(w.status.wire);
          if (ding != null) sound.ding(ding);
          notifier.alert(w);
        }
        v.status = w.status;
        v.acked = w.acked;
        v.model.setStatus(w.status, waitingOnSomeone(w));
      }
      final task = w.task;
      v.model.setTask(
        task != null && w.kind == WorkerKind.agent
            ? WorkerTask(name: '${providerLabel(w.provider, store.project)} · ${task.name}', summary: task.summary)
            : task,
      );
      final def = deskById[w.deskId];
      if (def != null) sound.setTyping(w.id, def.x, def.z, w.status == WorkerStatus.working);
      final again = w.kind == WorkerKind.shell ? 'restart' : 'resume';
      v.laptop.setPlaceholder(
        w.status == WorkerStatus.offline
            ? '💤 ${w.name} is asleep — press R to $again'
            : w.status == WorkerStatus.exited
            ? '${w.name} exited'
            : 'booting…',
      );
    }
    for (final id in _workerViews.keys.toList()) {
      if (store.workers.containsKey(id)) continue;
      final v = _workerViews.remove(id)!;
      final desk = office.desks[v.deskId];
      // Sent home: it packs up and walks out, and the seat shows as free once it's up.
      if (desk != null && _sentHome.contains(id)) {
        departures.add(v.model, v.laptop, _Leaving(desk));
      } else {
        v.model.root.detach();
        v.laptop.root.detach();
        v.model.dispose();
        v.laptop.dispose();
        if (desk != null) desk.vacancy.visible = true;
      }
      sound.removeTypist(id);
    }
    _arrangeBeanbags();
    notifier.sync(store.workers);
  }

  /// Once every desk is taken, bean bags come out for the workers who don't fit.
  void _arrangeBeanbags() {
    final appeared = office.setBeanbags(beanbagsOut((id) => store.workerAtDesk(id) != null || departures.seated(id)));
    // One came out right where you're standing: you end up on top of it.
    final p = player.pos;
    for (final c in appeared) {
      if (p.y > -0.1 &&
          p.y < c.top &&
          p.x > c.minX - 0.3 &&
          p.x < c.maxX + 0.3 &&
          p.z > c.minZ - 0.3 &&
          p.z < c.maxZ + 0.3) {
        p.y = c.top;
      }
    }
  }

  void _syncJukebox() {
    final j = store.jukebox;
    sound.setJukebox(
      j.on ? JukeboxPlay(track: j.track, url: j.url, startedAt: j.startedAt, since: store.jukeboxSince) : null,
    );
    office.jukebox.show(j.on, trackTitle(j.track, j.url));
  }

  // ---- Actions (OfficeActions) --------------------------------------------------------------------

  String? _freeDesk() {
    // Prefer the empty desk nearest to you; when they're all taken, the bean bag that's out.
    String? best;
    var bestD = double.infinity;
    for (final d in desks) {
      if (store.workerAtDesk(d.id) != null) continue;
      final dist = math.sqrt(math.pow(d.x - player.pos.x, 2) + math.pow(d.z - player.pos.z, 2));
      if (dist < bestD) {
        bestD = dist;
        best = d.id;
      }
    }
    return best ?? nextFreeSeat((id) => store.workerAtDesk(id) != null)?.id;
  }

  @override
  void hire(String deskId, {String? prompt, bool worktree = false, AgentProvider? provider, String? model}) {
    net.send(WorkerSpawnCmd(deskId: deskId, prompt: prompt, worktree: worktree, provider: provider, model: model));
    // The moment notifications start to matter: ask once (it has to come from a key press or click).
    if (settings.notify && notifier.permission == NotifyPermission.ask && !_askedToNotify) {
      _askedToNotify = true;
      notifier.askPermission();
    }
  }

  void _openShell(String deskId) => net.send(WorkerSpawnCmd(deskId: deskId, kind: WorkerKind.shell));

  void _promptAtDesk(String deskId) {
    final w = store.workerAtDesk(deskId);
    final desk = deskById[deskId]!;
    if (w == null) {
      openPrompt(
        PromptOptions(
          title: '✨ New task at ${desk.label}',
          subtitle: 'A fresh worker will sit down and start on this right away. Choose the worker engine below.',
          submitLabel: 'Hire & start',
          providerOption: true,
          worktreeOption: store.project?.branch != null,
          project: store.project,
          onSubmit: (text, o) => hire(deskId, prompt: text, worktree: o.worktree, provider: o.provider, model: o.model),
        ),
      );
    } else if (isAsleep(w.status)) {
      toast('${w.name} is asleep — press R to resume first', ToastKind.warn);
    } else if (w.kind == WorkerKind.shell) {
      openPrompt(
        PromptOptions(
          title: '🐚 Run in ${w.name}',
          placeholder: 'npm run dev',
          submitLabel: 'Run ▶',
          onSubmit: (text, _) => net.send(WorkerPromptCmd(w.id, text)),
        ),
      );
    } else {
      openPrompt(
        PromptOptions(
          title: '💬 Prompt ${w.name}',
          subtitle: w.status == WorkerStatus.working
              ? '${w.name} is busy — your message will be queued in their input box.'
              : null,
          onSubmit: (text, _) => net.send(WorkerPromptCmd(w.id, text)),
        ),
      );
    }
  }

  /// Direct hire from an empty desk, with an optional first prompt and provider choice.
  void _hireAtDesk(String deskId) {
    final desk = deskById[deskId]!;
    openPrompt(
      PromptOptions(
        title: '✨ Hire a worker at ${desk.label}',
        subtitle: 'Choose the worker engine. You can start with an empty prompt and send work later.',
        placeholder: 'Optional first task…',
        submitLabel: 'Hire & start',
        allowEmpty: true,
        providerOption: true,
        worktreeOption: store.project?.branch != null,
        project: store.project,
        onSubmit: (text, o) => hire(
          deskId,
          prompt: text.isEmpty ? null : text,
          worktree: o.worktree,
          provider: o.provider,
          model: o.model,
        ),
      ),
    );
  }

  @override
  void killWorker(String workerId) {
    final w = store.workers[workerId];
    if (w == null) return;
    final where = deskById[w.deskId]?.label ?? 'the desk';
    final session = w.kind == WorkerKind.shell ? 'shared shell' : '${providerLabel(w.provider, store.project)} session';
    final wt = w.worktree;
    if (wt != null) {
      // A worker with its own worktree: choose what becomes of the worktree and its branch.
      sendHomeDialog(
        scope,
        SendHomeOptions(
          workerId: workerId,
          name: w.name,
          where: where,
          worktree: (path: wt.path, branch: wt.branch),
          ask: () => net.send(WorkerWorktreeCmd(workerId)),
          onConfirm: (cleanup) => net.send(WorkerKillCmd(workerId, cleanup: cleanup)),
        ),
      );
      return;
    }
    confirmDialog(
      'Send ${w.name} home?',
      'This stops the $session at $where for everyone and frees the desk.',
      'Send home',
      () => net.send(WorkerKillCmd(workerId)),
    );
  }

  @override
  void resumeWorker(WorkerInfo w) {
    if (w.sessionId == null && w.kind != WorkerKind.shell) {
      toast('${w.name} has no saved Claude session — starting a fresh one', ToastKind.warn);
    }
    net.send(WorkerResumeCmd(w.id));
  }

  /// Whether a worker's branch can become a PR: it has its own worktree and isn't mid-turn.
  bool _prReady(WorkerInfo w) => w.worktree != null && !isBusy(w.status);

  /// O at a desk: see the worker's pull request, or push its branch and open one.
  void _pullRequestFor(WorkerInfo w) {
    final pr = w.pr;
    if (pr != null) {
      final it = store.pulls.items.where((p) => p.number == pr.number).firstOrNull;
      if (it != null) {
        openPull(scope, it);
      } else {
        openInNewTab(pr.url);
      }
      return;
    }
    if (w.worktree == null) {
      return toast(
        '${w.name} works in the main checkout — only workers with their own worktree can open a PR',
        ToastKind.warn,
      );
    }
    if (w.prOpening == true) return;
    if (!_prReady(w)) {
      return toast("${w.name} is still ${statusLabel(w.status)} — wait until it's done", ToastKind.warn);
    }
    toast('Pushing ${w.worktree!.branch} and opening a pull request…');
    net.send(WorkerPrCmd(w.id));
  }

  /// Puts you in front of a desk, looking at it: the PR board's "Go to desk".
  @override
  void goToDesk(String deskId) {
    final desk = deskById[deskId];
    if (desk == null) return;
    ModalStack.instance.closeAll();
    // Behind the worker, looking over their shoulder at the laptop.
    final spot = deskSeat(desk, desk.beanbag ? 1.6 : 2.4);
    player.pos.setValues(spot.x, 0, spot.z);
    player.vy = 0;
    player.facing = math.atan2(desk.x - spot.x, desk.z - spot.z);
    player.camYaw = player.facing - math.pi;
    player.lookPitch = -0.2;
    final w = store.workerAtDesk(deskId);
    toast(w != null ? "You're at ${desk.label}, ${w.name}'s desk" : "You're at ${desk.label}");
  }

  /// Opening a sleeping worker's terminal wakes it, so there's nothing to press first.
  @override
  void openWorkerTerminal(String workerId, {({int row, String needle})? find}) {
    final w = store.workers[workerId];
    if (w == null) return;
    if (isAsleep(w.status)) resumeWorker(w);
    openTerminal(scope, workerId, onChanges: () => openWorkerChanges(workerId), find: find);
  }

  @override
  void openWorkerChanges(String workerId) {
    if (!store.workers.containsKey(workerId)) return;
    openChanges(scope, workerId, onTerminal: () => openWorkerTerminal(workerId));
  }

  @override
  void showSearch() => openSearch(scope);

  @override
  void showQueue() => openQueue(scope);

  /// A prompt from the boards goes to a new worker at a free desk, or to one already at a desk.
  @override
  void sendToWorker(String title, {String? context, String? initial}) {
    final desk = _freeDesk();
    final awake = store.workers.values.where((w) => w.kind == WorkerKind.agent && !isAsleep(w.status)).toList();
    if (desk == null && awake.isEmpty) {
      toast('Every desk and bean bag is taken — send a worker home first', ToastKind.warn);
      return;
    }
    openAsk(
      scope,
      AskOptions(
        title: title,
        context: context,
        initial: initial,
        newDesk: desk == null ? null : deskById[desk]!.label,
        workers: [for (final w in awake) AskWorker(id: w.id, name: w.name, color: w.color, status: w.status)],
        worktreeOption: store.project?.branch != null,
        providerOption: true,
        onSubmit: (prompt, to, worktree, provider, model) {
          if (to != null) {
            net.send(WorkerPromptCmd(to, prompt));
          } else if (desk != null) {
            hire(desk, prompt: prompt, worktree: worktree, provider: provider, model: model);
          }
        },
      ),
    );
  }

  @override
  void showSettings() => openSettings(
    scope,
    settings: settings,
    onChange: (s) {
      // Switching to push to talk mutes you now; back to an open mic turns it on.
      final talkChanged = s.pushToTalk != settings.pushToTalk;
      settings
        ..pushToTalk = s.pushToTalk
        ..view = s.view
        ..volume = s.volume
        ..muted = s.muted
        ..music = s.music
        ..musicMuted = s.musicMuted
        ..notify = s.notify
        ..save();
      if (talkChanged) voiceRoom.setMuted(settings.pushToTalk);
      player.setView(settings.view);
      sound.setVolume(settings.volume, settings.muted);
      sound.setMusicVolume(settings.music, settings.musicMuted);
    },
    onCharacter: editProfile,
    previewSound: () => sound.ding(Ding.done),
    notifier: notifier,
    onSignOut: signOut,
    outside: store.sky == null ? null : (now: describeSky(store.sky!), live: store.sky!.city != null),
  );

  @override
  Future<void> signOut() async {
    await Api.postJson('/api/logout', {}).catchError((_) => ApiResult(0, {}));
    goTo('/login');
  }

  @override
  void editProfile() => openCharacter(
    scope,
    onSave: (p) {
      _showMyProfile(p);
      net.send(ProfileCmd(name: p.name, color: p.color, look: p.look));
    },
  );

  void _showMyProfile(Profile p) {
    store.profile = p;
    saveProfile(p);
    me.setColor(p.color);
    me.setLook(p.look);
    hands.setColor(p.color);
    hands.setSkin(me.skinColor);
  }

  void _interact(Interactable? target, DeskKey key) {
    if (target == null) return;
    if (target.kind == InteractKind.desk && target.deskId != null) {
      final deskId = target.deskId!;
      final w = store.workerAtDesk(deskId);
      switch (key) {
        case DeskKey.b when w == null:
          return _openShell(deskId);
        case DeskKey.p:
          return _promptAtDesk(deskId);
        case DeskKey.e:
          return w != null ? openWorkerTerminal(w.id) : _hireAtDesk(deskId);
        case DeskKey.c when w != null:
          return openWorkerChanges(w.id);
        case DeskKey.r when w != null && isAsleep(w.status):
          return resumeWorker(w);
        case DeskKey.x when w != null:
          return killWorker(w.id);
        case DeskKey.o when w != null:
          return _pullRequestFor(w);
        default:
          return;
      }
    }
    if (key != DeskKey.e) return;
    switch (target.kind) {
      case InteractKind.elevator:
        showElevator();
      case InteractKind.issues:
        openBoard(scope, BoardKind.issues);
      case InteractKind.pulls:
        openBoard(scope, BoardKind.pulls);
      case InteractKind.services:
        openServices(scope);
      case InteractKind.queue:
        showQueue();
      case InteractKind.jukebox:
        openJukebox(scope, openVolume: showSettings);
      case InteractKind.seat when target.seatId != null:
        _useSeat(target.seatId!);
      case InteractKind.dog:
        net.send(const DogPetCmd());
      case InteractKind.coffee:
        _drinkCoffee();
      case InteractKind.smoke:
        if (_smokeBreakUntil > 0) {
          _setSmoking(false);
          toast('You stub it out in the ashtray');
        } else {
          _setSmoking(true);
          toast('🚬 Smoke break');
        }
      case InteractKind.gong:
        _hitGong();
      case InteractKind.tv:
        voiceRoom.watchShare();
      case InteractKind.decor when target.decorId != null:
        hanger.view(target.decorId!);
      case InteractKind.whiteboard:
        whiteboard.open();
      default:
        break;
    }
  }

  /// A cup from the kitchen machine: a minute of quicker feet and higher jumps, and a mug in your hand.
  void _drinkCoffee() {
    final jittery = caffeine.drink(nowMs() / 1000);
    sound.coffee();
    if (player.view == ViewMode.first) hands.sip();
    if (jittery) {
      toast('☕ One cup too many… you’ve got the jitters!', ToastKind.warn);
    } else if (caffeine.cups > 1) {
      toast('☕ Another cup: back to a full minute of buzz');
    } else {
      toast('☕ Fresh coffee! A minute of quicker feet and higher jumps');
    }
  }

  // ---- Smoke breaks -----------------------------------------------------------------------------

  void _setSmoking(bool on) {
    if (on == _smokeBreakUntil > 0) return;
    _smokeBreakUntil = on ? nowMs() + _smokeBreakMs : 0;
    me.setSmoking(on);
    hands.setSmoking(on);
    net.send(ActCmd(smoke: on));
  }

  /// Out on the balcony (a little slack at the door), where smoking is allowed.
  bool _onBalcony() {
    final p = player.pos;
    return p.y > -0.5 &&
        p.y < 2 &&
        p.x > Balcony.minX - 0.5 &&
        p.x < Balcony.maxX + 0.5 &&
        p.z > Balcony.minZ - 0.8 &&
        p.z < Balcony.maxZ + 0.5;
  }

  /// Ends the break when the cigarette burns down, or when you take it back inside.
  void _checkSmokeBreak(double now) {
    if (_smokeBreakUntil == 0) return;
    if (!_onBalcony()) {
      _setSmoking(false);
      toast('🚭 No smoking inside, so you put it out');
    } else if (now > _smokeBreakUntil) {
      _setSmoking(false);
      toast("That one's done. Back to work!");
    }
  }

  void _puff(Puff kind, vm.Vector3 at, vm.Vector3 dir) => kind == Puff.wisp ? smoke.wisp(at) : smoke.exhale(at, dir);

  /// In first person yours comes off the cigarette in your hand and out in front of the camera.
  void _myPuff(Puff kind, vm.Vector3 at, vm.Vector3 dir) {
    if (player.view != ViewMode.first) return _puff(kind, at, dir);
    final eye = player.camPos, fwd = (player.camTarget - player.camPos).normalized();
    if (kind == Puff.wisp) return smoke.wisp(hands.cigTip());
    smoke.exhale(eye + fwd * 0.3 - vm.Vector3(0, 0.14, 0), (vm.Vector3(fwd.x, 0.1, fwd.z))..normalize());
  }

  // ---- Sitting ----------------------------------------------------------------------------------

  /// The free place on a seat nearest you, or null when everyone else on your floor has taken them all.
  SeatPlace? _freePlace(SeatDef seat) {
    final taken = <String>{
      for (final p in store.peers.values)
        if (p.seat != null && p.id != store.you && store.onMyFloor(p)) p.seat!,
    };
    SeatPlace? best;
    var bestD = double.infinity;
    for (var i = 0; i < seat.places.length; i++) {
      final place = seatPlace(seat, i);
      final d = math.sqrt(math.pow(place.x - player.pos.x, 2) + math.pow(place.z - player.pos.z, 2));
      if (!taken.contains(place.key) && d < bestD) {
        best = place;
        bestD = d;
      }
    }
    return best;
  }

  /// E at a seat: sit down on it. Sitting there already, get up, or on the couch facing the TV, watch it.
  void _useSeat(String seatId) {
    final seat = seatingById[seatId];
    if (seat == null) return;
    if (player.seat?.seatId == seatId) {
      if (seat.tv && voiceRoom.tvShowing) return voiceRoom.watchShare();
      if (seat.game) return arcade.play();
      return standUp();
    }
    final place = _freePlace(seat);
    if (place == null) {
      toast('No room on that ${seat.label.replaceFirst(RegExp(r'^\S+ '), '').toLowerCase()} right now', ToastKind.warn);
      return;
    }
    player.sit(place);
    me.sit(place.hips);
    net.send(SitCmd(seat: place.key));
    // The couch in front of the TV is where you watch whoever's sharing.
    if (seat.tv && voiceRoom.tvShowing) voiceRoom.watchShare();
  }

  void standUp() {
    player.stand();
    _gotUp();
  }

  /// On your feet again, by E or by walking off.
  void _gotUp() {
    me.sit(null);
    net.send(const SitCmd());
  }

  /// What you're sitting on, so it's what E is about unless you're looking at something else.
  Interactable? _mySeat() {
    final id = player.seat?.seatId;
    if (id == null) return null;
    return office.interactables.where((it) => it.kind == InteractKind.seat && it.seatId == id).firstOrNull;
  }

  // ---- The gong -----------------------------------------------------------------------------------

  /// E at the gong. The office rings it for everyone on the floor, you included (see _gongRang).
  void _hitGong() {
    final now = nowMs();
    if (now - _lastHit < 500) return;
    _lastHit = now;
    net.send(const GongCmd());
  }

  /// Where confetti comes from over a desk: above the worker's head.
  void _burstOver(String deskId, int n) {
    final d = deskById[deskId];
    if (d != null) confetti.burst(d.x, 2.3, d.z, n);
  }

  /// Someone hit the gong, a pull request merged (confetti over its desk), or the queue emptied (a party).
  void _gongRang(GongWhy why, int? pr) {
    office.gong.strike(why == GongWhy.hit ? 0.7 : 1);
    sound.gong(why);
    final top = office.gong.top;
    if (why == GongWhy.merged) {
      // Over the desk it came from while its worker is still there, who jumps for joy; otherwise over the gong.
      final it = store.pulls.items.where((p) => p.number == pr).firstOrNull;
      final w = pr == null
          ? null
          : store.workers.values
                .where((w) => w.pr?.number == pr || (it != null && w.worktree?.branch == it.headRefName))
                .firstOrNull;
      if (w != null && _workerViews.containsKey(w.id)) {
        _burstOver(w.deskId, 220);
        if (!isAsleep(w.status)) _workerViews[w.id]!.model.cheer();
      } else {
        confetti.burst(top.x, top.y, top.z, 220);
      }
    } else if (why == GongWhy.queue) {
      // Three strokes: a burst at the gong, then every desk, then a cannon.
      confetti.burst(top.x, top.y, top.z, 160);
      Timer(const Duration(milliseconds: 850), () {
        office.gong.strike(0.85);
        for (final e in _workerViews.entries) {
          _burstOver(e.value.deskId, 120);
          if (!isAsleep(store.workers[e.key]?.status ?? WorkerStatus.offline)) e.value.model.cheer(4);
        }
      });
      Timer(const Duration(milliseconds: 1700), () {
        office.gong.strike(1.2);
        confetti.burst(top.x, top.y, top.z, 450, 1.5);
      });
    }
  }

  // ---- Targeting and the hint -------------------------------------------------------------------

  Interactable? _pickTarget() {
    // Everything you can use is upstairs; down on the street you're under it all.
    if (player.pos.y < -slab - 1) return null;
    Interactable? best;
    var bestD = double.infinity;
    for (final list in [office.interactables, gallery.interactables, dog.interactables]) {
      for (final it in list) {
        if (it.off) continue;
        // Up on the loft, or down underneath it.
        if (((it.y ?? 0) - player.pos.y).abs() > 1.5) continue;
        final d = math.sqrt(math.pow(it.x - player.pos.x, 2) + math.pow(it.z - player.pos.z, 2));
        if (d < it.radius && d < bestD) {
          best = it;
          bestD = d;
        }
      }
    }
    return best;
  }

  /// What the ray through [screen] lands on first, and whether it is within reach (plus [slack] meters).
  ({Interactable it, bool near})? aimedAt(Offset screen, Size view, [double slack = 0]) {
    final ray = camera.screenPointToRay(screen, view);
    final hit = scene.raycast(ray, maxDistance: 60, layerMask: ~Hands.layer);
    if (hit == null) return null;
    final it = interactableOf(hit.node);
    if (it == null) return null; // a wall, the floor, a plant… is in the way
    final eye = toEngine(vm.Vector3(player.pos.x, player.pos.y + kEyeHeight, player.pos.z));
    return (it: it, near: hit.worldPoint.distanceTo(eye) <= _reach[it.kind]! + slack);
  }

  /// Whether something solid stands between the camera and [point] (engine space): for labels.
  bool labelBlocked(vm.Vector3 point) {
    final eye = camera.position;
    final to = point - eye;
    final dist = to.length;
    if (dist < 0.5) return false;
    final ray = vm.Ray.originDirection(eye, to / dist);
    return scene.raycast(ray, maxDistance: dist - 0.35, layerMask: ~Hands.layer) != null;
  }

  void _renderHint() {
    if (hanger.active && !ModalStack.instance.open) {
      final (k, parts) = hanger.hint();
      if (k == _hintKey) return;
      _hintKey = k;
      hint.value = parts;
      return;
    }
    final t = _target;
    if (t == null || ModalStack.instance.open) {
      if (_hintKey.isNotEmpty) {
        hint.value = null;
        _hintKey = '';
      }
      return;
    }
    final (k, parts) = _hintFor(t);
    final key = '${t.kind}${t.deskId ?? ''}|$k';
    if (key == _hintKey) return;
    _hintKey = key;
    hint.value = parts;
  }

  (String, List<HintPart>) _hintFor(Interactable it) {
    (String, List<HintPart>) board(String name) => ('', [HintTitle(name), const HintKey('E', 'Open')]);
    switch (it.kind) {
      case InteractKind.desk:
        return it.deskId != null ? _deskHint(it.deskId!) : ('', []);
      case InteractKind.issues:
        return board('📌 Issues board');
      case InteractKind.pulls:
        return board('🔀 Pull request board');
      case InteractKind.services:
        return board('🌐 Services board');
      case InteractKind.queue:
        final n = store.queue.tasks.where((t) => t.status != TaskStatus.done).length;
        return ('$n', [HintTitle('📋 Task queue${n > 0 ? ' · $n' : ''}'), const HintKey('E', 'Open')]);
      case InteractKind.tv:
        return voiceRoom.tvHint();
      case InteractKind.coffee:
        final buzzed = caffeine.buzzed(nowMs() / 1000);
        return ('$buzzed', [const HintTitle('☕ Coffee machine'), HintKey('E', buzzed ? 'Another cup' : 'Grab a cup')]);
      case InteractKind.smoke:
        final on = _smokeBreakUntil > 0;
        return ('$on', [const HintTitle('🚬 Ashtray'), HintKey('E', on ? 'Stub it out' : 'Take a smoke break')]);
      case InteractKind.gong:
        return (
          '',
          [const HintTitle('🎉 Merge gong'), const HintAside('rings when a PR merges'), const HintKey('E', 'Bang it')],
        );
      case InteractKind.jukebox:
        final j = store.jukebox;
        final what = j.on ? trackTitle(j.track, j.url) : '';
        return (
          '${j.on}|$what',
          [
            const HintTitle('🎵 Jukebox'),
            HintAside(j.on ? '♪ ${clip(what, 40)}' : 'off'),
            HintKey('E', j.on ? 'Change the song' : 'Put on a song'),
          ],
        );
      case InteractKind.whiteboard:
        return whiteboardHint(othersDrawing(store.drawing, store.you, store.peers));
      case InteractKind.elevator:
        final f = store.currentFloor();
        final n = store.floors.length;
        return (
          '${f?.name}|$n',
          [
            const HintTitle('🛗 Elevator'),
            if (f != null) HintAside('${f.name} · $n floor${n == 1 ? '' : 's'}'),
            HintKey('E', n > 1 ? 'Choose a floor' : 'Floors & projects'),
          ],
        );
      case InteractKind.decor:
        final d = store.decor.where((x) => x.id == it.decorId).firstOrNull;
        final name = d?.title?.isNotEmpty == true ? d!.title! : 'A picture';
        return (
          '${d?.title}|${d?.by}',
          [HintTitle('🖼️ $name'), if (d != null) HintAside('hung by ${d.by}'), const HintKey('E', 'Look closer')],
        );
      case InteractKind.seat:
        final seat = seatingById[it.seatId ?? ''];
        if (seat == null) return ('', []);
        if (player.seat?.seatId == seat.id) {
          return (
            '${seat.id}|sitting',
            [
              HintTitle(seat.label),
              const HintAside('sitting'),
              if (seat.game) ...[const HintKey('E', 'Play DEADFALL'), const HintKey('W A S D', 'Get up')]
              else const HintKey('E', 'Get up'),
            ],
          );
        }
        final full = _freePlace(seat) == null;
        return (
          '${seat.id}|$full',
          [
            HintTitle(seat.label),
            if (seat.game) const HintAside('🌲 DEADFALL on the monitor'),
            full ? const HintAside('no room') : const HintKey('E', 'Sit down'),
          ],
        );
      case InteractKind.dog:
        final doing = dog.doing(
          (id) => store.workers[id]?.name,
          (id) => id == store.you ? 'you' : store.peers[id]?.name,
        );
        return (
          '${dog.name}|$doing',
          [HintTitle('🐶 ${dog.name}'), if (doing.isNotEmpty) HintAside(doing), const HintKey('E', 'Pet')],
        );
    }
  }

  (String, List<HintPart>) _deskHint(String deskId) {
    final w = store.workerAtDesk(deskId);
    if (w == null) {
      final paused = hiringPaused(store.usage);
      return (
        '$paused',
        [
          HintTitle('${deskById[deskId]!.label} · empty'),
          if (paused)
            const HintCost('💸 Budget spent — hiring resumes tomorrow')
          else ...[
            const HintKey('E', 'Hire a worker'),
            const HintKey('P', 'Hire with a task'),
          ],
          const HintKey('B', 'Shell'),
        ],
      );
    }
    final doing = w.activity != null ? clip(w.activity!, 48) : '';
    final provider = w.kind == WorkerKind.agent ? resolvedProvider(w.provider, store.project) : AgentProvider.claude;
    final spent = w.kind == WorkerKind.agent && w.usage != null ? usageLabel(w.usage!, provider) : '';
    final shell = w.kind == WorkerKind.shell;
    return (
      '${w.status}${w.id}${w.pr?.number ?? ''}${w.prOpening == true ? '!' : ''}$doing$spent',
      [
        HintTitle('${w.name} · ${statusLabel(w.status)}'),
        if (doing.isNotEmpty) HintAside(doing),
        if (spent.isNotEmpty) HintCost(spent, tooltip: usageTitle(w.usage!, provider)),
        const HintKey('E', 'Open terminal'),
        const HintKey('C', 'Changes'),
        isAsleep(w.status)
            ? HintKey('R', shell ? 'Restart' : 'Resume')
            : HintKey('P', shell ? 'Run command' : 'Prompt'),
        if (w.pr != null)
          HintKey('O', 'PR #${w.pr!.number}')
        else if (w.prOpening == true)
          const HintAside('⏳ Opening PR…')
        else if (_prReady(w))
          const HintKey('O', 'Open PR'),
        const HintKey('X', 'Send home'),
      ],
    );
  }

  // ---- Reaching out and keys --------------------------------------------------------------------

  /// Plays the reach on your hands and your character, and shows it to everyone else.
  void _reachOut() {
    if (player.view == ViewMode.first) hands.reach();
    me.reach();
    final now = nowMs();
    if (now - _lastActSent > 120) {
      _lastActSent = now;
      net.send(const ActCmd());
    }
  }

  void _use(Interactable? it, DeskKey key) {
    if (it == null) return;
    _reachOut();
    _interact(it, key);
  }

  /// A key went down while the office has the keyboard. True when it was one of the office's own.
  bool onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    if (ModalStack.instance.open || hud.typing) return false;
    final hk = HardwareKeyboard.instance;
    if (hk.isMetaPressed || hk.isControlPressed || hk.isAltPressed) return false;
    if (hanger.key(e.physicalKey, reach: _reachOut)) return true;
    final deskKey = _deskKeys[e.physicalKey];
    if (deskKey != null) {
      _use(_target, deskKey);
      player.input.clear();
      return true;
    }
    if (hud.handleKey(e)) {
      player.input.clear();
      return true;
    }
    if (e.physicalKey == PhysicalKeyboardKey.keyF) {
      hanger.start();
      return true;
    }
    return false;
  }

  /// A click (not a drag) on the scene, at [screen] in a view of [view] size.
  void onClick(Offset screen, Size view) {
    if (ModalStack.instance.open) return;
    if (hanger.active) {
      _reachOut();
      return hanger.place(screen);
    }
    if (player.view == ViewMode.first) {
      // Reach out even at nothing, like poking the air.
      _reachOut();
      if (_target != null) _interact(_target, DeskKey.e);
      return;
    }
    final aim = aimedAt(screen, view, 2.5);
    if (aim == null) return;
    if (!aim.near) {
      toast('Walk closer to that first');
      return;
    }
    _use(aim.it, DeskKey.e);
  }

  // ---- The frame --------------------------------------------------------------------------------

  /// Reads which movement keys are held, unless something else has the keyboard.
  void _readKeys() {
    final i = player.input;
    if (!player.enabled || hud.typing || ModalStack.instance.open) {
      i.clear();
      return;
    }
    final keys = HardwareKeyboard.instance.physicalKeysPressed;
    bool any(List<PhysicalKeyboardKey> ks) => ks.any(keys.contains);
    i
      ..forward = any([PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.arrowUp])
      ..back = any([PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.arrowDown])
      ..left = any([PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.arrowLeft])
      ..right = any([PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.arrowRight])
      ..run = any([PhysicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftRight])
      ..jump = keys.contains(PhysicalKeyboardKey.space);
  }

  final Stopwatch _perf = Stopwatch();
  double _perfTick = 0, _perfDt = 0;
  int _perfN = 0;

  void tick(double dt, Size view) {
    _perf
      ..reset()
      ..start();
    _tick(dt, view);
    _perfTick += _perf.elapsedMicroseconds / 1000;
    _perfDt += dt;
    if (devPerf && ++_perfN == 20) {
      debugPrint('PERF tick ${(_perfTick / _perfN).toStringAsFixed(1)} ms, frame ${(_perfDt / _perfN * 1000).toStringAsFixed(0)} ms');
      _perfTick = _perfDt = 0;
      _perfN = 0;
    }
  }

  void _tick(double dt, Size view) {
    dt = math.min(dt, 0.1);
    _elapsed += dt;
    final t = _elapsed;
    final now = nowMs();

    // Coffee: quicker feet, higher jumps, a mug in hand, and maybe the jitters.
    final secs = now / 1000;
    player.speedBoost = caffeine.speed(secs);
    player.jumpBoost = caffeine.jump(secs);
    player.jitter = caffeine.jitter(secs);
    final mug = caffeine.buzzed(secs);
    me.holdMug(mug);
    hands.holdMug(mug);

    _readKeys();
    player.update(dt);
    me.root.position = vm.Vector3(player.pos.x, player.pos.y + player.stepOffset, player.pos.z);
    me.root.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), player.facing);
    me.update(dt, t, player.moving && player.grounded, !player.grounded, player.speedBoost);
    final firstPerson = player.view == ViewMode.first;
    // In first person you are the camera; in third, hide yourself when it's zoomed in right behind your head.
    me.root.visible =
        !firstPerson && player.camPos.distanceTo(vm.Vector3(player.pos.x, player.pos.y + 1.3, player.pos.z)) > 1.5;
    blast.update(dt);
    flash.value = blast.flash;
    final jolt = blast.shake();
    camera = PerspectiveCamera(
      fovRadiansY: 55 * math.pi / 180,
      position: toEngine(player.camPos + jolt),
      target: toEngine(player.camTarget + jolt * 0.5),
      fovNear: 0.1,
      fovFar: 200,
    );
    camera = arcade.update(camera, dt, view);
    final look = (player.camTarget - player.camPos)..normalize();
    hands.root.visible = firstPerson;
    if (firstPerson) {
      hands.place(player.camPos, look);
      hands.update(
        dt,
        t,
        HandsInput(
          yaw: player.camYaw,
          pitch: player.lookPitch,
          walkPhase: player.walkPhase,
          walking: player.moving && player.grounded,
          airborne: !player.grounded,
          jitter: player.jitter,
        ),
      );
    }

    // Your ears are in your head, facing wherever the camera looks.
    sound.update(SoundListener(x: player.pos.x, y: player.pos.y + kEyeHeight, z: player.pos.z, fx: look.x, fz: look.z));
    final s = (player.walkPhase / math.pi).floor();
    if (s != _stride) {
      _stride = s;
      if (player.moving && player.grounded) sound.step();
    }
    if (!player.grounded) {
      _fallV = math.min(_fallV, player.vy);
    } else {
      if (_fallV < -4) sound.step(StepKind.land);
      _fallV = 0;
    }

    final l = _lastSent, p = player.pos;
    final moved =
        (p.x - l.x).abs() + (p.y - l.y).abs() + (p.z - l.z).abs() > 0.01 || (player.facing - l.rotY).abs() > 0.02;
    if ((moved || player.moving != l.moving) && now - _lastSentAt > 66) {
      _lastSent = (x: p.x, y: p.y, z: p.z, rotY: player.facing, moving: player.moving);
      _lastSentAt = now;
      net.send(MoveCmd(x: p.x, y: p.y, z: p.z, rotY: player.facing, moving: player.moving));
    }

    for (final e in _remotes.entries) {
      final peer = store.peers[e.key];
      final pose = store.poses[e.key];
      if (peer == null || pose == null) continue;
      final r = e.value;
      // Sitting, they're wherever their seat puts them.
      final sat = peer.seat != null ? seatAt(peer.seat!) : null;
      final target = sat != null ? vm.Vector3(sat.x, sat.y, sat.z) : vm.Vector3(pose.x, pose.y, pose.z);
      final rotY = sat?.rotY ?? pose.rotY;
      final pos = r.person.root.position;
      final k = math.min(1.0, dt * 12);
      r.person.root.position = pos + (target - pos) * k;
      final cur = _yawOf(r.person.root.rotation);
      var diff = rotY - cur;
      diff = math.atan2(math.sin(diff), math.cos(diff));
      r.person.root.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), cur + diff * k);
      // On their feet if they're standing on something: the floor, a desk, a stair, the loft.
      final airborne = sat == null && pose.y > groundAt(office.colliders, pose.x, pose.z, pose.y) + 0.05;
      final walking = sat == null && pose.moving && !airborne;
      r.person.update(dt, t, walking, airborne && (pos.y - target.y).abs() > 0.01);
      // Their walk cycle takes a step every pi/11 seconds.
      r.stepT = walking ? r.stepT + dt : 0.2;
      if (r.stepT >= math.pi / 11) {
        r.stepT -= math.pi / 11;
        sound.stepAt(pos.x, pos.z);
      }
      if (r.bubble != null && now > r.bubbleUntil) {
        labels.remove(r.bubble);
        r.bubble = null;
      }
    }

    for (final e in _workerViews.entries) {
      final v = e.value;
      final desk = deskById[v.deskId]!;
      // A jumping worker holds still while you're near enough to read its card, and jumps again once you walk away.
      final d = math.sqrt(math.pow(desk.x - player.pos.x, 2) + math.pow(desk.z - player.pos.z, 2));
      v.model.held = d < (v.model.held ? _holdLeave : _holdNear);
      v.model.update(dt, t);
      v.laptop.update(
        dt,
        store.screens[e.key],
        math.sqrt(math.pow(desk.x - player.camPos.x, 2) + math.pow(desk.z - player.camPos.z, 2)),
      );
    }
    voiceRoom.tick(now, me, {for (final e in _remotes.entries) e.key: e.value.person}, player.pos);
    departures.update(dt, t);
    dog.update(dt);
    office.update(t, dt, [
      player.pos,
      ...[for (final r in _remotes.values) r.person.root.position],
      ...departures.positions(),
    ]);
    office.jukebox.update(t, dt, sound.beat());
    _checkSmokeBreak(now);
    smoke.update(dt, player.camPos, player.camTarget);
    confetti.update(dt);
    hanger.update(view, locked: lockAvailable ? pointerLocked : null);
    _updateSky(dt, t);

    if (ModalStack.instance.open || hanger.active) {
      _target = null;
    } else if (firstPerson) {
      final aim = aimedAt(Offset(view.width / 2, view.height / 2), view);
      _target = aim != null && aim.near ? aim.it : _mySeat();
    } else {
      _target = _mySeat() ?? _pickTarget();
    }
    _renderHint();
    final show = firstPerson && !ModalStack.instance.open;
    final free = show && lockAvailable && !pointerLocked;
    final next = CrosshairState(show: show, on: _target != null, free: free, relookOnKey: free && relookOnKey);
    if (next != crosshair.value) crosshair.value = next;
  }

  /// The page's query string, as the page was opened.
  Map<String, String> get _query => startupQuery;

  bool devHands = true;
  bool devPerf = false;
  bool devLabels = true;

  /// Seconds on the page's clock, for the caffeine meter.
  double get clockSeconds => nowMs() / 1000;

  /// Set by the page: whether the mouse can be captured for looking around, and whether it is.
  bool lockAvailable = true;
  bool pointerLocked = false;

  /// Set by the page when closing the last window may not have given you the mouse back: the next
  /// key you press takes it instead (a key counts for the browser, where the Esc that closed it doesn't).
  bool relookOnKey = false;

  static double _yawOf(vm.Quaternion q) {
    final f = q.rotated(vm.Vector3(0, 0, 1));
    return math.atan2(f.x, f.z);
  }

  // ---- The sky ----------------------------------------------------------------------------------

  void _updateSky(double dt, double t) {
    final m = skyModel..update(dt, t);
    skyView.update(dt, t, m, player.camPos);
    final l = Toon.light
      ..sunDirection = m.lightDir
      ..sunColor = m.lightColor.color
      ..sunIntensity = m.lightIntensity / math.pi
      ..sky = m.hemiSky.color
      ..ground = m.hemiGround.color
      ..hemiIntensity = m.hemiIntensity / math.pi
      ..ambient = m.ambientIntensity / math.pi
      ..officeLight = m.officeLight.vector
      ..garageLight = m.garageLight.vector
      ..wet = m.wet * (1 - m.lying)
      ..snow = m.lying * 0.9;
    // Pools of light round the eight lamps nearest you.
    final lamps = [...office.night.lamps]..sort((a, b) => _d2(a.x, a.z).compareTo(_d2(b.x, b.z)));
    for (var i = 0; i < 8; i++) {
      if (i < lamps.length && m.lampsOn > 0.005) {
        final lamp = lamps[i];
        l.lampPos[i].setValues(lamp.x, lamp.y, lamp.z, lamp.reach);
        final c = Rgb.hex(int.parse(lamp.color.substring(1), radix: 16)).scale(lamp.power * m.lampsOn);
        l.lampColor[i].setValues(c.r, c.g, c.b);
      } else {
        l.lampPos[i].setZero();
      }
    }
    Toon.updateLight();
    for (final b in office.night.bulbs) {
      b.glow(m.lampsOn);
    }
    office.night.setWindowsLit(m.lampsOn * 1.1);
    setToonColor(office.night.clouds, m.clouds.color);
    final fog = scene.fog;
    fog.color = m.background.vector;
    fog.start = m.fogNear;
    fog.end = m.fogFar;
    final bg = m.background.color;
    if (bg != sky.value) sky.value = bg;
    sound.setWeather(m.rain, 1 - m.daylight);
  }

  double _d2(double x, double z) => math.pow(x - player.camPos.x, 2) + math.pow(z - player.camPos.z, 2).toDouble();
}
