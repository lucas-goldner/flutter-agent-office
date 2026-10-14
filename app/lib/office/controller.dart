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
import '../audio/sound_model.dart' show Pos, SoundHall;
import '../caffeine.dart';
import '../interop/browser.dart';
import '../interop/open_link.dart';
import '../net/api.dart';
import '../net/office_socket.dart' hide Profile;
import '../nextup.dart';
import '../notify.dart';
import '../office_scope.dart';

import 'package:office_shared/avatar.dart';
import 'package:office_shared/emotes.dart';
import 'package:office_shared/floors.dart';
import 'package:office_shared/jukebox.dart';
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;
import 'package:office_shared/layout.dart' as lay show Elevator;
import 'package:office_shared/palette.dart' show isPaletteKey;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof, roofName;
import 'package:office_shared/status.dart';

import '../state/store.dart';
import '../ui/ask.dart';
import '../ui/boards.dart';
import '../ui/changes.dart';
import '../ui/compass.dart';
import '../ui/dictate.dart' show dictating;
import '../ui/character.dart';
import '../ui/elevator.dart';
import '../ui/floormenu.dart';
import '../ui/emote_wheel.dart';
import '../ui/help.dart';
import '../ui/hud.dart';
import '../ui/jukebox.dart';
import '../ui/modal.dart';
import '../ui/palette.dart';
import '../ui/prompt.dart';
import '../ui/provider.dart';
import '../ui/pull.dart';
import '../ui/repos.dart';
import '../ui/queue.dart';
import '../ui/search.dart';
import '../ui/services.dart';
import '../ui/settings.dart';
import '../ui/settings_map.dart';
import '../ui/signins.dart';
import '../ui/team.dart';
import '../ui/accounts.dart';
import '../ui/arcade.dart';
import '../ui/terminal.dart';
import '../ui/terminal_logic.dart' show isMacKeyboard;
import '../ui/title.dart' show waitingElsewhere;
import '../ui/upgrade.dart';
import '../ui/whiteboard.dart';
import '../ui/worker_limit.dart' show pressureNote;
import '../ui/whereabouts.dart';
import '../ui/whiteboard_logic.dart' show othersDrawing, whiteboardHint;
import '../ui/usage.dart' show hiringPaused, usageLabel, usageTitle;
import '../ui/worker_text.dart' show statusLabel;
import '../voice/office_voice.dart';
import '../walkto.dart';
import '../world/board_faces.dart';
import '../world/character.dart';
import '../world/climb.dart';
import '../world/collider.dart';
import '../world/confetti.dart';
import '../world/dog.dart';
import '../world/gallery.dart';
import '../world/geo.dart' show pointIn;
import '../world/hands.dart';
import '../world/holiday.dart';
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
import 'carry.dart';
import 'hanging.dart';
import 'rooms_hub.dart';
import 'interaction.dart';
import 'needs_you.dart';
import 'palette_entries.dart';
import 'places_hub.dart';
import 'roof.dart';
import 'worlds.dart';
import 'send_home.dart';
import '../world/jail.dart';
import '../world/adrift.dart';
import '../world/world.dart' show DeskView, OfficeWorld, World, WorldDevice, streetOf;

import 'package:office_shared/maps/maps.dart' show MapPlan, PlanStyle, levelRoute, officeMap, seatHereOn;
import 'package:office_shared/nav.dart' show Pt;

import '../world/office/city.dart' show buildCity;

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
  InteractKind.station: 4.5,
  InteractKind.cabinet: 4,
  InteractKind.meeting: 7,
  InteractKind.golf: 3.5,
  InteractKind.ball: 3.2,
  InteractKind.bookshelf: 4,
  InteractKind.ladder: 3,
  InteractKind.pole: 3.5,
  InteractKind.telescope: 3.5,
};

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
    where: _whereNow,
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
      onDecor: () => hanger.active ? hanger.cancel() : _startHanging(),
      onSettings: showSettings,
      onHelp: openHelp,
      onOpenWorker: openWorkerTerminal,
      onEditProfile: editProfile,
      onFloors: showFloors,
      onTalk: talk,
      onWalkTo: walkTo,
    ),
    prefs: HudPrefs(settings: settings, save: settings.save)..actions = hudActions(),
  );
  late final Office office;

  /// The building's map as it's built: the office, or a map of its own (see worlds.dart).
  late final Worlds worlds;

  /// The world the building's map is built as.
  World get world => worlds.world;

  /// Where everything is on the building's map: its seats by id, and places to sit.
  MapPlan get plan => worlds.plan;

  /// Whether the building's on the office's own map (the elevator, the balcony, the lounge…).
  bool get inOffice => worlds.inOffice;

  /// Workers locked up in the dungeon, on a map that has one, wasting away in their cells; or, on a
  /// station, the same ones adrift outside its airlock.
  late final Jail jail = Jail(() => store.jail, store.officeNow, _dressKept, labels);
  late final Drifters adrift = Drifters(() => store.jail, store.officeNow, _dressKept, labels);

  /// Workers sent home on a map with a script for it (the castle's Kingsguard marching them down to the
  /// dungeon, the station's Security to the airlock).
  late final Sendoffs sendoffs = Sendoffs(
    parent: root,
    ground: groundHere,
    sounds: _SendoffSounds(this),
    onUp: (deskId) {
      final desk = world.desks[deskId];
      if (desk != null && store.workerAtDesk(deskId) == null) desk.vacancy.visible = true;
      _arrangeBeanbags();
    },
    world: () => world,
    jail: jail,
    adrift: adrift,
  );

  /// How someone the office has kept is dressed: the map's outfit, and as worn out as it had got working.
  void _dressKept(Worker model, Prisoner p) {
    model
      ..setOutfit(plan.outfit == 'peasant' ? 'peasant' : null)
      ..setAge(_agedBy(p.workedMs ?? 0));
  }

  /// Voice chat and screen sharing (the TV, the thumbnails, mouths and proximity volume).
  late final OfficeVoice voiceRoom;

  /// The 📝 whiteboard: its window, and the drawing on the board in the office.
  late final WhiteboardHub whiteboard;
  late final PlayerController player;

  /// You on the ladder or a fire pole, between the floors (see climb.dart).
  late final Climber climber;
  late final Person me;
  late final Hands hands;
  late final Dog dog;
  late final Departures departures;
  late final Confetti confetti;
  late final Smoke smoke;
  late final OfficeSound sound;
  bool _soundMade = false;
  late final DesktopNotifier notifier;

  /// A worker that needs you: the beacons, the banner, the flash and the alarm (office/needs_you.dart).
  late final NeedsYouHub needsYou;
  late final Gallery gallery;
  late final Hanger hanger;
  late final Arcade arcade;

  /// The games and rooms: board agents, the arcade cabinet, the machine monitor…
  late final RoomsHub rooms = RoomsHub(this);

  /// The places round the building: the loft's telescope, darts and axes, the cars, the desk signs.
  late final PlacesHub places = PlacesHub(this);

  /// Set by the page: let go of the mouse (as a window opening does), and take it back for the game.
  VoidCallback yieldMouse = () {};
  VoidCallback backToGame = () {};

  /// The hint's drawn again next frame.
  void staleHint() => _hintKey = 'stale';

  /// The rooftop bar: up there and back, drinks and the DJ (roof.dart).
  late final RoofHub roofHub;
  final SkyModel skyModel = SkyModel();
  late final SkyView skyView;

  /// Halloween or Christmas decorations, up while the building's dressed up for one (see [_dressUp]).
  late final Holiday holiday;
  HolidayTheme? _theme;

  /// The emote wheel (hold G), and your own emote's emoji popping up on screen in first person.
  late final EmoteWheel emoteWheel = EmoteWheel(onPick: emote);
  final ValueNotifier<(Emote, int)?> emotePop = ValueNotifier(null);
  int _emotePops = 0;

  /// The same limit the server keeps, so an emote you see yourself do is one everyone else sees too.
  final EmoteBucket _emoteLimit = EmoteBucket();
  double _emoteWarnedAt = -1e9;
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

  /// Up the ladder or down a pole to another floor, while it comes.
  ({String floor, Grip how, Timer timer})? _climbing;
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
      skyModel.show(
        SkyPreview(
          hour: double.tryParse(q['hour'] ?? ''),
          weather: q['weather'] == null ? null : Weather.parse(q['weather']),
        ),
      );
    }
    devLabels = q['labels'] != '0';

    office = buildOffice(labels: labels);
    root.add(office.group);
    worlds = Worlds(
      theOffice: OfficeWorld(office, () => office.stack.state.index > 0, () => 0),
      labels: labels,
      parent: root,
      footstep: (x, y, z) => sound.stepAt(x, z, y),
      mount: _mountWorld,
    );
    voiceRoom = OfficeVoice(store: store, net: net, tv: office.tvScreen, state: voice);
    dictating.addListener(_dictatingChanged);
    _unsubscribe.add(() => dictating.removeListener(_dictatingChanged));
    whiteboard = WhiteboardHub(scope, office.whiteboard);
    _boards = q['boards'] != '0';
    if (_boards) _mountBoards(office.boardMeshes);
    skyView = SkyView(root, office.night);
    // What it lands on: anything but what's only there to keep people out.
    confetti = Confetti((x, z, y) => math.max(groundAt(world.colliders, x, z, y, false), player.street));
    smoke = Smoke();
    root
      ..add(confetti.node)
      ..add(smoke.node);
    holiday = Holiday(colliders: office.colliders, plantLeaves: office.plantLeaves);
    root.add(holiday.group);

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
    player.onPathEnd = _pathEnded;
    _placeInCar();
    climber = Climber(
      player,
      ClimbHooks(
        floorThere: (way) => _floorThere(way)?.name,
        travel: _climbTravel,
        sound: _climbSound,
        done: (_, _) => _hintKey = 'stale',
      ),
    );
    office.stack.onHatch = (_, open) {
      if (open) sound.stepAt(Ladder.x + 0.3, Ladder.z);
    };
    hands = Hands(store.profile.color, me.skinColor);
    root.add(hands.root);
    me.onSmoke = _myPuff;

    _soundMade = true;
    sound = OfficeSound(clock: nowMs)
      ..setVolume(settings.volume, settings.muted)
      ..setMusicVolume(settings.music, settings.musicMuted);
    sound.onMusicError = (text) => toast(text, ToastKind.warn);
    skyModel.onThunder = (delay, loud) => sound.thunder(delay, loud);

    // The floor's dog. It goes quiet once someone has the terminal of the worker it's barking at open.
    dog = Dog(sound, (id) => (store.workers[id]?.viewers.length ?? 0) > 0, labels, now: nowMs);
    root.add(dog.root);
    departures = Departures(root, groundHere, (x, y, z) => sound.stepAt(x, z, y), (deskId) {
      final desk = world.desks[deskId];
      if (desk != null && store.workerAtDesk(deskId) == null) desk.vacancy.visible = true;
      _arrangeBeanbags();
    }, ways: () => world.ways);
    // A click on a worker's notification: over to its desk, with its terminal open to answer it.
    notifier = DesktopNotifier(enabled: () => settings.notify, openWorker: answerWorker);
    needsYou = NeedsYouHub(
      NeedsYouHost(
        store: store,
        settings: settings,
        alarm: (again) => sound.needsYou(again),
        labels: labels,
        root: root,
        workerRoot: (id) => _workerViews[id]?.model.root,
        deskFloor: (id) {
          final desk = world.desks[_workerViews[id]?.deskId];
          return desk == null ? null : fromEngine(desk.group.globalTransform.getTranslation()).y;
        },
      ),
    );
    // Pictures on the walls (and the one you're hanging), and Minesweeper on the boss's monitor.
    gallery = Gallery();
    office.group.add(gallery.group);
    hanger = Hanger(scope: scope, player: player, office: office, gallery: gallery, camera: () => camera);
    hanger.onChange = () {
      hanging.value = hanger.active;
      _hintKey = 'stale';
    };
    root.add(hanger.ghost.group);
    arcade = Arcade(office.bossScreen);
    rooms.init();
    places.init();
    worlds.theOffice
      ..meetingBoardFace = rooms.view.meetingBoard
      ..meetingSignFace = rooms.view.meetingSign;
    roofHub = RoofHub(
      root: root,
      office: office,
      store: store,
      net: net,
      sound: sound,
      player: player,
      me: me,
      hands: hands,
      labels: labels,
      remote: (id) => _remotes[id]?.person,
      reach: _reachOut,
      // The same city C3's tower stands in, seen from the roof.
      city: buildCity,
    )..world = (() => world);
    _listen(Topic.decor, () => gallery.sync(store.decor));

    _listen(Topic.peers, _syncPeers);
    _listen(Topic.workers, _syncWorkers);
    _listen(Topic.workers, _renderWaiting);
    _listen(Topic.workers, needsYou.sync);
    _listen(Topic.floor, needsYou.floorChanged);
    // A worker's bubble shows whether it has a pull request open (green) or merged (purple: send it home).
    _listen(Topic.pulls, _paintPrs);
    _listen(Topic.queue, _paintPrs);
    _listen(Topic.floors, _paintFloor);
    _listen(Topic.map, _applyMap);
    _listen(Topic.jail, _syncJail);
    registerMapSettings();
    _listen(Topic.floors, _syncStack);
    _listen(Topic.dog, () => dog.sync(store.dog, store.dogStart));
    _listen(Topic.jukebox, _syncJukebox);
    _listen(Topic.sky, () {
      if (store.sky != null) skyModel.set(store.sky!);
    });
    _unsubscribe
      // Closing the tab, or reloading: the frame loop saves where you are every second, and here's the last word.
      ..add(onPageHide(_saveSpot))
      ..add(watchTabTitle(store))
      ..add(watchFloorsWaiting(store, ding: () => sound.ding(Ding.needsInput)));
    net.status.listen((up) => connected.value = up);
    HardwareKeyboard.instance.addHandler(_onKeyUp);
    _unsubscribe.add(() => HardwareKeyboard.instance.removeHandler(_onKeyUp));
    HardwareKeyboard.instance.addHandler(_onPaletteKey);
    _unsubscribe.add(() => HardwareKeyboard.instance.removeHandler(_onPaletteKey));
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

  /// Dictation muted your voice-chat mic, so it's the one to unmute it.
  bool _mutedToDictate = false;

  /// Dictating a prompt while you're in voice with an open mic: the office mutes you for as long as it
  /// listens, so the others don't hear you talk to a worker.
  void _dictatingChanged() {
    final v = voice.value;
    if (dictating.value) {
      if (!v.inVoice || v.muted) return;
      voiceRoom.setMuted(true);
      _mutedToDictate = true;
    } else if (_mutedToDictate) {
      _mutedToDictate = false;
      if (v.inVoice && v.muted) voiceRoom.setMuted(false);
    }
  }

  void dispose() {
    for (final f in _unsubscribe) {
      f();
    }
    _messages?.cancel();
    voiceRoom.dispose();
    rooms.dispose();
    places.dispose();
    needsYou.dispose();
    hanger.dispose();
    whiteboard.dispose();
    if (_soundMade) sound.dispose();
    net.close();
  }

  // ---- Boards: each face is a live Flutter widget on the wall -----------------------------------

  /// Whether the boards' faces are drawn (the ?boards=0 dev switch leaves them blank).
  bool _boards = true;

  /// A map of its own was just built: its boards and its meeting board show what the office's do.
  void _mountWorld(World w) {
    if (_boards) _mountBoards(w.boardMeshes);
    final board = w.meetingBoard, sign = w.meetingSign;
    if (board != null && sign != null) rooms.meetingFaces(board, sign);
  }

  void _mountBoards(Map<String, Face> faces) {
    void mount(String key, Widget face) {
      final f = faces[key];
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

    mount('issues', CorkBoardFace(store: store, kind: CorkKind.issues, marks: _cork));
    mount('pulls', CorkBoardFace(store: store, kind: CorkKind.pulls));
    mount('services', ServicesBoardFace(store: store));
    mount('queue', QueueBoardFace(store: store));
  }

  // ---- Messages ---------------------------------------------------------------------------------

  /// Whether the sign-ins window has had its chance to greet you (once a page).
  bool _signInsGreeted = false;

  void _onMessage(ServerMsg msg) {
    final held = _held;
    if (held != null && msg is! WelcomeMsg) return held.add(msg);
    if (msg is FloorsMsg && floorBlownUp(store.floor, msg.floors)) _blowUp();
    if (msg is WelcomeMsg) voiceRoom.beforeWelcome();
    // The floor you asked to come back to (see OfficeSocket.connect), to tell if the office put you somewhere else.
    final wasOn = msg is WelcomeMsg ? (store.floor ?? lastFloor()) : null;
    if (msg is WelcomeMsg || msg is FloorEnterMsg) {
      // A floor arriving: nobody's still leaving, and its workers are seated already.
      departures.clear();
      _clearSendoffs();
      _seatedAlready = true;
    }
    if (msg is WorkerRemoveMsg) _sentHome.add(msg.workerId);
    try {
      store.apply(msg);
    } catch (e, st) {
      // One bad listener mustn't stop the rest of the message from being handled.
      debugPrint('store.apply(${msg.runtimeType}) failed: $e\n$st');
    }
    _sentHome.clear();
    _seatedAlready = false;
    whiteboard.route(msg);
    roofHub.onMessage(msg);
    switch (msg) {
      case WelcomeMsg m:
        // A few pings, to line this page's clock up with the office's for the jukebox.
        for (var i = 0; i < 5; i++) {
          Timer(Duration(milliseconds: 200 + i * 500), () => net.send(PingCmd(nowMs())));
        }
        final mine = store.peers[store.you];
        if (_firstWelcome && mine != null) {
          _firstWelcome = false;
          // Where the office put you: back in the spot you left (if there's still room there), or in the car.
          // Back to where you were, if that was on this map (and not in the elevator: that's arriving). A hall
          // of its own has nothing outside it to come back to (and its walls may have moved since).
          final saved = lastSpot();
          final sameMap = saved == null || (saved.map ?? officeMap) == plan.id;
          final b = plan.bounds;
          final inRoom =
              inOffice ||
              (mine.x > b.minX + 0.3 && mine.x < b.maxX - 0.3 && mine.z > b.minZ + 0.3 && mine.z < b.maxZ - 0.3);
          if (sameMap && inRoom && !(inOffice && inElevator(mine.x, mine.z)) && player.fits(mine.x, mine.z, mine.y)) {
            _placeAt((x: mine.x, y: mine.y, z: mine.z, rotY: mine.rotY));
            _arrive(back: true);
          } else {
            _placeInCar((x: mine.x, z: mine.z));
            _arrive();
          }
          _devPlace();
          _floorWentWhileAway(wasOn);
        } else if (store.floor != null && store.floor != wasOn) {
          // Back after the office restarted, but not on your floor: it went while the office was down.
          _takenAway();
          if (_carrying != null) _setCarrying(null);
          _arrive();
          _floorWentWhileAway(wasOn);
        } else if (store.floor == null) {
          _arrive();
        }
        if (player.seat != null) net.send(SitCmd(seat: player.seat!.key));
        final card = _carrying;
        if (card != null) net.send(CarryCmd(issue: card.issue, title: card.title));
        // After a reconnect the office has forgotten what we're doing.
        _doingSent = null;
        _sendDoing();
        // Back from a restart on another version: this page's code is stale, so load the new one.
        if (_bootVersion.isEmpty) {
          _bootVersion = m.version;
        } else if (m.version != _bootVersion || restarting()) {
          showUpgraded(m.upgrade);
        }
        _upgradePhase = m.upgrade.phase;
        voiceRoom.welcomed();
        _dressUp(m.theme.active);
      case RtcMsg m:
        voiceRoom.signal(m.from, m.data);
      case FloorEnterMsg _:
        // Not a trip of yours: the floor you were on was taken off the building, and the elevator took you away.
        if (_riding == null && _climbing == null) _takenAway();
        // The card belongs to the board downstairs (or up): the office already put it back there.
        final card = _carrying;
        if (card != null) {
          toast("📌 #${card.issue} stayed behind on the other floor's board");
          _setCarrying(null);
        }
        _arrive();
      // The panel was closed while it cloned: a clone that failed still says why.
      case FloorAddedMsg m when m.error != null && !elevatorWaitingOn(m.repo):
        toast('🛗 ${m.error}', ToastKind.warn);
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
      case PeerActMsg m when !m.drinkSet:
        final r = _remotes[m.id];
        if (m.smoke == null) {
          r?.person.reach();
        } else {
          r?.person.setSmoking(m.smoke!);
        }
      case GongMsg m:
        _gongRang(m.why, m.pr);
      case PeerEmoteMsg m:
        _remotes[m.id]?.person.emote(m.emote);
      case ThemeMsg m:
        _dressUp(m.state.active);
      // The first word on your sign-ins: still to do, the window says hello.
      case SignInsMsg _ when !_signInsGreeted:
        _signInsGreeted = true;
        if (needsSigningIn(scope)) openSignIns(scope, signInsWelcome);
      // Something you did needs a sign-in first (hiring a worker before signing in to Claude, say).
      case SitRefusedMsg m:
        // Somebody on the floor got there first: back on your feet, next to them.
        if (player.seat?.key == m.seat) {
          player.stand();
          _gotUp();
          toast('${m.by} got there first', ToastKind.warn);
        }
      case SignInsNeededMsg m:
        openSignIns(scope, m.why);
      default:
        break;
    }
  }

  /// Dev switch for screenshots: ?at=x,z[,yaw[,pitch[,y]]] puts you there, ?view=third orbits.
  void _devPlace() {
    final q = _query;
    if (q['view'] == 'third') player.setView(ViewMode.third);
    // ?level=i,n stands you on floor i of a building n floors tall, for looking at the ladder and the tower.
    final level = q['level']?.split(',').map(int.tryParse).toList();
    if (level != null && level.length == 2 && level[0] != null && level[1] != null) {
      final (i, n) = (level[0]!, level[1]!);
      _devLevel = StackState(index: i, count: n, up: i < n - 1 ? 'Above' : null, down: i > 0 ? 'Below' : null);
      _syncStack();
    }
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
    if (!inOffice) return _placeAtSpawn();
    final spot = at != null && inElevator(at.x, at.z)
        ? at
        : (x: lay.Elevator.x, z: (ElevatorCar.minZ + ElevatorCar.maxZ) / 2);
    _placeAt((x: spot.x, y: 0, z: spot.z, rotY: 0));
  }

  /// On your feet at [at], facing its rotY and looking straight ahead.
  void _placeAt(({double x, double y, double z, double rotY}) at) {
    if (player.seat != null) standUp();
    player.pos.setValues(at.x, at.y, at.z);
    player.vy = 0;
    player.facing = at.rotY;
    player.camYaw = player.facing - math.pi;
    player.lookPitch = -0.08;
  }

  /// Not a trip of yours: the office put you on another floor (yours went), in its elevator car. Whatever you
  /// were doing stops.
  void _takenAway() {
    ModalStack.instance.closeAll();
    hanger.cancel();
    climber.abort();
    _stopWalking();
    _placeInCar();
  }

  /// Where you're standing, to come back to (see lastSpot): nowhere while you're between floors, or climbing
  /// between them.
  SavedSpot? _spotHere() {
    final floor = store.floor;
    if (floor == null || _riding != null || _climbing != null || climber.active) return null;
    // Sitting, it's where you'd get up to.
    final at = player.standingSpot() ?? (x: player.pos.x, y: player.pos.y, z: player.pos.z);
    final name = floor == roof ? roofName : (store.floors.where((f) => f.id == floor).firstOrNull?.name ?? '');
    return SavedSpot(
      floor: floor,
      name: name,
      map: plan.id,
      throne: _onThrone(),
      x: at.x,
      y: at.y,
      z: at.z,
      facing: player.facing,
    );
  }

  /// Where to put you back when the office lets you in: where you are now, or before this page was loaded,
  /// where you were last time.
  SavedSpot? _whereNow() => _firstWelcome ? lastSpot() : _spotHere();

  void _saveSpot() {
    final s = _spotHere();
    if (s != null) rememberSpot(s);
  }

  double _spotSavedAt = 0;

  /// You asked to come back to floor [was], and it's gone (taken off the building, or its checkout deleted):
  /// the office sent you up to the roof.
  void _floorWentWhileAway(String? was) {
    if (was == null || was == roof || store.floor != roof || store.floors.any((f) => f.id == was)) return;
    final saved = lastSpot();
    final name = saved?.floor == was && saved!.name.isNotEmpty ? saved.name : 'Your floor';
    toast("🛗 $name isn't in the building any more, so the elevator brought you up to the roof", ToastKind.warn);
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
      HudAction(
        id: 'roof',
        icon: '🍸',
        label: 'Rooftop bar',
        section: HudSection.open,
        shown: () => !roofHub.upTop && store.floors.any((f) => f.cloning != true),
        title: () => 'Ride the elevator up to the roof: a DJ, drinks and the city',
        run: () => ride(roof),
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
        run: goToNextWaiting,
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
      HudAction(
        id: 'signins',
        icon: '🔐',
        label: 'Your sign-ins',
        section: HudSection.together,
        shown: () => store.me.account != null,
        tone: () => needsSigningIn(scope) ? HudTone.danger : null,
        status: () => needsSigningIn(scope),
        chip: () => 'Sign in to Claude',
        title: () => 'The Claude plan and GitHub account your workers run on: your own',
        run: () => openSignIns(scope),
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
      FloorMenuOptions(
        go: switchFloor,
        indoors: indoors,
        elevator: showElevator,
        roof: plan.style == PlanStyle.office ? () => ride(roof) : null,
      ),
      anchor: anchor,
    );
  }

  /// Straight to another floor from the floor list, to the same spot in the office you're in now.
  /// Inside the office on your floor: not out on the balcony, the fire escape, the street or the golf course
  /// across it, nor down in the garage. (C3's back office counts as inside once the floor plan has a wing.)
  bool indoors() {
    final p = player.pos;
    if (roofHub.upTop || !inOffice || p.y < -1 || p.y > wallHeight) return false;
    return p.x > Floor.minX && p.x < Floor.maxX && p.z > Floor.minZ && p.z < Floor.maxZ;
  }

  void switchFloor(String floorId) {
    // The roof isn't laid out like a floor: to and from it, it's the elevator.
    if (store.floor == roof || floorId == roof) return ride(floorId);
    if (_riding != null || floorId == store.floor) return;
    // Outside, the same spot on another floor looks just like this one: the elevator brings you in to that
    // floor instead, into its car.
    if (!indoors()) return ride(floorId);
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
    if (_riding != null || _climbing != null || floorId == store.floor) return;
    // Another floor is somewhere else: a walk over to someone here ends (walkTo rides on with its own).
    if (!_walkRide) _stopWalking();
    ModalStack.instance.closeAll();
    hanger.cancel();
    climber.abort();
    final inside = inElevator(player.pos.x, player.pos.z);
    _riding = (floor: floorId, timer: Timer(const Duration(seconds: 10), _rideFailed));
    player.enabled = false;
    player.input.clear();
    roofHub.lift().setOpen(false);
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
    // The ride out is set up before anything else: if an effect below fails, the held messages
    // (the new floor list, where you ride to) must still come through, or the office freezes.
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
    try {
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
    } catch (e, st) {
      debugPrint('the blast failed: $e\n$st');
    }
  }

  /// The floor never came (it's gone, or the office is unreachable): open up where you are.
  void _rideFailed() {
    if (_riding == null) return;
    _riding = null;
    fade.value = false;
    roofHub.lift().setOpen(store.floor != null);
    player.enabled = !ModalStack.instance.open;
  }

  // ---- The ladder and the fire pole ------------------------------------------------------------

  /// The floors of the building from the bottom up (not the ones still being cloned: nobody can go there yet).
  List<FloorInfo> _builtFloors() => [
    for (final f in store.floors)
      if (f.cloning != true) f,
  ];

  /// The floor above yours (1) or below it (-1), if there is one.
  FloorInfo? _floorThere(Way way) {
    final floors = _builtFloors();
    final i = floors.indexWhere((f) => f.id == store.floor);
    final j = i + way;
    return i < 0 || j < 0 || j >= floors.length ? null : floors[j];
  }

  /// Through the ceiling up the ladder, or through the floor down one: the lights dip as you pass.
  void _climbTravel(Way way, Grip how, Arrival at) {
    final f = _floorThere(way);
    if (f == null || _climbing != null || _riding != null) {
      climber.abort();
      return;
    }
    _climbing = (floor: f.id, how: how, timer: Timer(const Duration(seconds: 10), _climbFailed));
    fade.value = true;
    Timer(const Duration(milliseconds: 170), () => net.send(FloorGoCmd(f.id, at: at)));
  }

  /// The floor never came (it's gone, or the office is unreachable): back where you were.
  void _climbFailed() {
    if (_climbing == null) return;
    _climbing = null;
    fade.value = false;
    climber.abort();
  }

  void _climbSound(String kind, double speed) {
    switch (kind) {
      case 'grab' || 'rung':
        sound.step();
      case 'bonk':
        toast("🔝 ${store.currentFloor()?.name ?? 'This'} is the top floor — the hatch won't budge");
      case 'land':
        sound.step(StepKind.land);
        _landed(speed);
    }
  }

  /// Down the pole: dust flies, and there's the floor you're on now.
  void _landed(double speed) {
    for (var i = 0; i < 10; i++) {
      final a = i / 10 * math.pi * 2;
      smoke.exhale(
        vm.Vector3(player.pos.x + math.sin(a) * 0.3, player.pos.y + 0.08, player.pos.z + math.cos(a) * 0.3),
        vm.Vector3(math.sin(a), 0.15, math.cos(a)).normalized(),
      );
    }
    toast('🚒 Wheee! Down to ${store.currentFloor()?.name ?? 'the floor below'}');
  }

  /// E at the ladder: onto it, facing the wall.
  void _grabLadder() {
    if (_riding != null || _climbing != null || climber.active) return;
    if (_floorThere(1) == null && _floorThere(-1) == null) {
      toast('No other floors yet — add a project in the elevator', ToastKind.warn);
      return;
    }
    if (player.seat != null) standUp();
    hanger.cancel();
    _stopWalking();
    climber.grabLadder();
  }

  /// E at a fire pole: down it, if there's a floor below; else (on the bottom floor) a spin round it.
  void _usePole(int i) {
    if (_riding != null || _climbing != null || climber.active || i < 0 || i >= poles.length) return;
    if (player.seat != null) standUp();
    hanger.cancel();
    _stopWalking();
    if (office.stack.polesGoDown()) {
      climber.slide(poles[i]);
    } else {
      climber.twirl(poles[i]);
    }
  }

  /// Set by the ?level= dev switch: the floor you're on, whatever the building says.
  StackState? _devLevel;

  /// The ladder and the pole go where there are floors to go to from this one, and the building is
  /// as tall as there are floors.
  void _syncStack() {
    final floors = _builtFloors();
    final index = floors.indexWhere((f) => f.id == store.floor);
    // Up on the roof there's no ladder or pole to take: nothing above, nothing below.
    final up = store.floor == roof || index < 0 || index + 1 >= floors.length ? null : floors[index + 1].name;
    final down = index > 0 ? floors[index - 1].name : null;
    final next =
        _devLevel ?? StackState(index: math.max(0, index), count: index < 0 ? 1 : floors.length, up: up, down: down);
    if (next == office.stack.state) return;
    office.stack.set(next);
    // The building is as tall as there are floors, with the street as far down as this one is up.
    office.setLevel(next.index, next.count);
    // The holiday decorations out on the street go down with it.
    holiday.setStreetDrop(next.index * storey);
    if (inOffice) player.street = streetBelow(next.index);
  }

  /// What the hint says while you're on the ladder or a pole.
  (String, List<HintPart>) _climbHint() {
    final l = climber.ladder;
    if (l != null) {
      if (l.waiting || l.auto) return ('climb|auto', [const HintTitle('🪜 Climbing…')]);
      final up = _floorThere(1)?.name, down = _floorThere(-1)?.name;
      return (
        'climb|$up|$down|${l.y > 0.4}',
        [
          const HintTitle('🪜 Ladder'),
          if (up != null) HintKey('W', 'Up to $up') else const HintAside('top floor'),
          if (down != null) HintKey('S', 'Down to $down') else const HintKey('S', 'Down'),
          HintKey('E', l.y < 0.4 ? 'Step off' : 'Let go'),
        ],
      );
    }
    return climber.sliding == 'twirl'
        ? ('twirl', [const HintTitle('🚒 Wheee!')])
        : ('slide', [const HintTitle('🚒 Sliding down…')]);
  }

  /// The top of whatever's underfoot at (x, z) for feet at [y], in the world you're in: its floor, a step, the street.
  double groundHere(double x, double z, double y) => math.max(groundAt(world.colliders, x, z, y), player.street);

  /// The building changed maps (or you arrived and it's not the office): the old world goes, the new one's
  /// put up, every worker sits down in its seat there, and you come in where it has you arrive.
  void _applyMap() {
    final next = worlds.worldFor(store.plan());
    if (identical(next.world, world)) return;
    // Everyone gets up from the old map's seats; they sit down in the new one's below.
    for (final e in _workerViews.entries) {
      worlds.court?.release(e.key);
      final v = e.value;
      v.model.root.detach();
      v.laptop.root.detach();
      v.model.dispose();
      v.laptop.dispose();
      sound.removeTypist(e.key);
    }
    _workerViews.clear();
    departures.clear();
    _clearSendoffs();
    _stopWalking();
    hanger.cancel();
    if (_smokeBreakUntil > 0) _setSmoking(false);
    // The office's things: the ball goes down, the games stop; the card goes back on the board.
    if (rooms.ball.holding) rooms.ball.drop();
    rooms.golf.stop();
    arcade.stop();
    if (_carrying != null) _setCarrying(null);
    if (player.seat != null) standUp();
    world.group.visible = false;
    worlds.enter(next);
    final up = roofHub.upTop;
    world.group.visible = !up;
    if (!up) player.colliders = world.colliders;
    final b = plan.bounds, r = world.room;
    final v = r.vault;
    player.room = CameraRoom(
      minX: b.minX,
      maxX: b.maxX,
      minZ: b.minZ,
      maxZ: b.maxZ,
      wall: r.wall,
      enclosed: r.enclosed,
      vault: v == null
          ? null
          : (minX: v.bounds.minX, maxX: v.bounds.maxX, minZ: v.bounds.minZ, maxZ: v.bounds.maxZ, top: v.top),
    );
    if (!up) player.street = inOffice ? streetBelow(office.stack.state.index) : streetOf(world);
    skyView.indoors = r.enclosed;
    skyView.space = !up && world.ownSky;
    // A map of its own sounds like itself: its gong and its windows, and none of the office's phones or fridge.
    final hall = world.acoustics;
    sound.setHall(
      hall == null
          ? null
          : SoundHall(
              gong: hall.gong == null ? null : Pos(hall.gong!.x, hall.gong!.y, hall.gong!.z),
              windows: [for (final w in hall.windows) Pos(w.x, w.y, w.z)],
              vacuum: hall.vacuum,
            ),
    );
    Toon.light.officeOn = inOffice ? 1 : 0;
    // The office's own: the holiday decorations round it and the street, the dog.
    holiday.group.visible = inOffice && !up;
    dog.root.visible = inOffice && !up;
    _painted = -1;
    _paintFloor();
    world.setProjectName(store.project?.name ?? 'Agent Office');
    _dressUp(_theme);
    // They were there already: nobody walks in (and on a welcome, the floor's workers that come next weren't either).
    _syncWorkersSeated();
    _syncJail();
    if (store.floor != null && !up && _riding == null && _climbing == null) {
      _placeInCar();
      // Back in the office, in its elevator: the doors open onto it.
      if (inOffice) roofHub.lift().setOpen(true);
    }
    _heraldHires.clear();
    _offTheRoof();
    _hintKey = 'stale';
  }

  /// Down off the roof, on a map with no roof to be up on (it changed while you were up there).
  void _offTheRoof() {
    if (!roofHub.upTop || inOffice || _riding != null || _climbing != null) return;
    final f = _builtFloors().firstOrNull;
    if (f == null) return;
    ride(f.id);
    toast("The building's ${plan.icon} ${plan.name} now, with no rooftop bar: down you go");
  }

  /// Where you come in on a map of its own: on the throne if nobody's on it, else on your feet where the map says.
  void _placeAtSpawn() {
    final at = plan.spawn;
    _placeAt((x: at.x, y: groundHere(at.x, at.z, 1.5), z: at.z, rotY: at.rotY));
    // Not on the way to another floor: the throne's this one's.
    if (_riding == null && _climbing == null) _sitOnThrone();
  }

  /// Up onto the map's throne, if it has one and nobody's on it.
  void _sitOnThrone() {
    final throne = plan.throne;
    final seat = throne == null ? null : _freePlace(throne);
    if (seat == null || roofHub.upTop) return;
    if (player.seat != null) player.stand();
    player.sit(seat);
    me.sit(seat.hips);
    if (store.floor != null) net.send(SitCmd(seat: seat.key));
  }

  /// Sitting on the map's throne.
  bool _onThrone() {
    final id = plan.throne?.id;
    return id != null && player.seat?.seatId == id;
  }

  /// E at the herald (the castle's Hand of the King), or K from the throne: what should a new worker do?
  /// It's hired at the first free seat at the tables, and runs off there from beside him (see [_cameFrom]).
  void _hireFromHerald() {
    final h = plan.herald;
    if (h == null) return;
    if (_freeDesk() == null) {
      return toast('${h.name}: every seat at the tables is taken — send someone home first', ToastKind.warn);
    }
    final lineup = plan.lineup.isNotEmpty
        ? ', and comes back to line up${plan.throne != null ? ' before your throne' : ''} once it’s done or needs you'
        : '';
    openPrompt(
      PromptOptions(
        title: '${plan.icon} ${h.name}: send out a worker',
        subtitle: 'Say what it’s to do. A new worker runs off to a free seat and gets started$lineup.',
        warning: pressureNote(store.machine),
        placeholder: h.ask,
        submitLabel: h.button,
        allowEmpty: true,
        providerOption: true,
        worktreeOption: store.project?.branch != null,
        project: store.project,
        office: store.prompts.agent,
        repoOptions: repoChoices(store),
        onSubmit: (text, o) {
          // Whichever seat is free now (someone may have sat down while you were thinking).
          final deskId = _heraldSeat();
          if (deskId == null) return toast('Every seat at the tables is taken now', ToastKind.warn);
          _heraldHires[deskId] = nowMs();
          net.send(
            WorkerSpawnCmd(
              deskId: deskId,
              prompt: text.isEmpty ? null : text,
              worktree: o.worktree,
              provider: o.provider,
              model: o.model,
              effort: o.effort,
              repos: o.repos.isEmpty ? null : o.repos,
              via: 'herald',
            ),
          );
        },
      ),
    );
  }

  /// What the hint says at the herald.
  (String, List<HintPart>) _heraldHint() {
    final h = plan.herald;
    final full = _freeDesk() == null;
    final paused = hiringPaused(store.usage);
    final why = full
        ? 'every seat is taken'
        : paused
        ? '💸 Budget spent — hiring resumes tomorrow'
        : '';
    return (
      '${h?.name}|$why',
      [
        HintTitle('${plan.icon} ${h?.name ?? 'Herald'}'),
        if (why.isNotEmpty) HintCost(why) else HintAside(h?.says ?? ''),
        if (why.isEmpty) const HintKey('E', 'Send out a new worker'),
      ],
    );
  }

  void _paintFloor() {
    final p = store.currentFloor()?.palette ?? 0;
    if (p == _painted) return;
    _painted = p;
    world.setLook(floorPalette(p));
  }

  /// You're on a floor (or in the building without one): paint it, and open the doors.
  /// You're on a floor (or in the building without one): paint it, and open the doors. [back] is standing in
  /// the spot you left from last time, the doors open already.
  void _arrive({bool back = false}) {
    places.placeChanged();
    // Up on the roof, or back down: the roof has no dog, and no walls for pictures.
    if (roofHub.setPlace()) {
      dog.root.visible = !roofHub.upTop;
      skyView.roof = roofHub.upTop;
      skyView.space = !roofHub.upTop && world.ownSky;
      hanger.cancel();
      _hintKey = 'stale';
    }
    _paintFloor();
    _syncStack();
    world.setProjectName(store.project?.name ?? 'Agent Office');
    // Up the ladder or down the pole: carry on the rest of the way on this floor.
    final c = _climbing;
    if (c != null) {
      c.timer.cancel();
      _climbing = null;
      fade.value = false;
      if (store.floor != null) {
        climber.arrived();
        return;
      }
    }
    // Not a climb of yours: the floor you were on was taken off the building.
    if (climber.active) climber.abort();
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
    if (back) {
      // The doors stand open, the way the last one out left them.
      roofHub.lift().setOpen(true);
      player.enabled = !ModalStack.instance.open;
      return;
    }
    Timer(const Duration(milliseconds: 450), () {
      roofHub.lift().setOpen(true);
      sound.ding(Ding.done);
      player.enabled = !ModalStack.instance.open;
    });
  }

  void _paintPrs() {
    for (final e in _workerViews.entries) {
      final w = store.workers[e.key];
      if (w != null) e.value.model.setPr(workerPr(w, store.pulls.items, store.queue.tasks));
    }
  }

  // ---- Carrying an issue card ------------------------------------------------------------------

  /// The issue card in your hands, taken off this floor's issues board, or null.
  CarriedIssue? _carrying;

  /// Cards off the issues board (carried around) and the note you're reaching for (lifted).
  final CorkMarks _cork = CorkMarks();

  /// The note on the issues board under the crosshair (or, in third person, the mouse), which E takes.
  GhIssue? _aimedNote;

  /// Issues whose cards someone on this floor is carrying around, so they're missing from the board.
  Set<int> _offBoard() => {
    if (_carrying != null) _carrying!.issue,
    for (final p in store.peers.values)
      if (p.carrying != null && p.id != store.you && store.onMyFloor(p)) p.carrying!.issue,
  };

  /// The issue whose note on the issues board an aim lands on, or null (bare cork, the frame, anything else).
  GhIssue? _noteUnder(({Interactable it, bool near, SceneRaycastHit hit}) aim) {
    final face = world.boardMeshes['issues'];
    final uv = aim.hit.uv;
    if (aim.it.kind != InteractKind.issues || face == null || !identical(aim.hit.node, face.node) || uv == null) {
      return null;
    }
    final spots = corkLayout(CorkBoardPainter.issueNumbers(store.issues, _cork.off, store.taskForIssue)).spots;
    final n = corkNoteAt(spots, uv.x, uv.y);
    return n == null ? null : store.issues.items.where((i) => i.number == n).firstOrNull;
  }

  void _setCarrying(CarriedIssue? card) {
    if ((card?.issue ?? 0) == (_carrying?.issue ?? 0)) return;
    _carrying = card;
    me.carry(card);
    hands.carry(card);
    net.send(CarryCmd(issue: card?.issue, title: card?.title));
    _cork.off = _offBoard();
    _hintKey = 'stale';
  }

  /// ✋ in an issue's window, or E at its note on the board: its card comes off the board and into your hands.
  @override
  void pickUp(GhIssue it) {
    ModalStack.instance.closeAll();
    if (_carrying?.issue == it.number) return;
    if (_carrying != null) toast('📌 #${_carrying!.issue} went back on the board');
    _setCarrying(CarriedIssue(issue: it.number, title: it.title));
    sound.paper();
    toast('✋ You took #${it.number} off the board: take it to an empty desk, a worker or the 📋 queue and press E');
  }

  /// Q, or E at the issues board: the card goes back where it came from.
  void _putBack() {
    final card = _carrying;
    if (card == null) return;
    toast('📌 #${card.issue} is back on the board');
    _setCarrying(null);
    sound.paper();
  }

  /// The card left your hands for a desk or the queue (the office says who took it).
  void _putDown() {
    _setCarrying(null);
    sound.paper();
  }

  bool _onQueue(int issue) {
    final t = store.taskForIssue(issue);
    return t != null && t.status != TaskStatus.done;
  }

  /// E with a card in your hands: an empty desk hires a worker for the issue (with the prompt 🤖 Hand
  /// to a worker uses), an agent at a desk gets it as its next prompt, the queue board queues it, and
  /// the issues board takes it back (or swaps it for the [note] you point at there). False when it's
  /// none of those, so E does what it always does there.
  bool _dropCard(Interactable it, CarriedIssue card, GhIssue? note) {
    if (it.kind == InteractKind.issues) {
      note != null ? pickUp(note) : _putBack();
      return true;
    }
    final prompt = cardPrompt(card, store.issues.items.where((i) => i.number == card.issue).firstOrNull);
    if (it.kind == InteractKind.queue) {
      if (_onQueue(card.issue)) {
        toast('#${card.issue} is already on the queue', ToastKind.warn);
      } else {
        net.send(
          QueueAddCmd(
            prompt: prompt,
            title: '#${card.issue} ${card.title}',
            issue: card.issue,
            provider: rememberedProvider(store.project),
          ),
        );
        _putDown();
      }
      return true;
    }
    final deskId = it.deskId;
    if (it.kind != InteractKind.desk || deskId == null) return false;
    final w = store.workerAtDesk(deskId);
    final why = w != null
        ? cantTakeCard(w)
        : (hiringPaused(store.usage) ? '💸 Budget spent — hiring resumes tomorrow' : '');
    if (why.isNotEmpty) {
      toast(why, ToastKind.warn);
    } else if (w != null) {
      net.send(WorkerPromptCmd(w.id, prompt, issue: card.issue));
      _putDown();
    } else {
      net.send(
        WorkerSpawnCmd(
          deskId: deskId,
          prompt: prompt,
          worktree: store.project?.branch != null && worktreePref(),
          provider: rememberedProvider(store.project),
          issue: card.issue,
        ),
      );
      _putDown();
    }
    return true;
  }

  /// With an issue card in your hands: what E does with it here, and how to put it back.
  (String, List<HintPart>) _carryHint(CarriedIssue card, Interactable? it) {
    List<HintPart> parts(List<HintPart> mid) => [
      HintTitle('🗂️ #${card.issue} in hand'),
      ...mid,
      const HintKey('Q', 'Put it back'),
    ];
    final note = _aimedNote;
    if (it?.kind == InteractKind.issues) {
      return note != null
          ? ('${note.number}', parts([HintKey('E', 'Swap it for #${note.number}')]))
          : ('', parts([const HintKey('E', 'Pin it back up')]));
    }
    if (it?.kind == InteractKind.queue) {
      final on = _onQueue(card.issue);
      return ('$on', parts([on ? const HintAside('already on the queue') : const HintKey('E', 'Put it on the queue')]));
    }
    final deskId = it?.deskId;
    if (it?.kind == InteractKind.desk && deskId != null) {
      final w = store.workerAtDesk(deskId);
      if (w == null) {
        final paused = hiringPaused(store.usage);
        return (
          '$paused',
          parts([
            paused
                ? const HintCost('💸 Budget spent — hiring resumes tomorrow')
                : const HintKey('E', 'Hire a worker for it'),
          ]),
        );
      }
      final why = cantTakeCard(w);
      return (
        '${w.id}${w.status}$why',
        parts([why.isNotEmpty ? HintAside(why) : HintKey('E', 'Hand it to ${w.name}')]),
      );
    }
    // Anything else works as usual, card in hand.
    if (it != null) {
      final (k, rest) = _hintFor(it);
      return (k, parts(rest));
    }
    return ('', parts([const HintAside('take it to an empty desk, a worker or the 📋 queue')]));
  }

  // ---- Walking over to someone, and what everyone's up to ---------------------------------------

  /// Near enough to talk: where a walk over to someone ends.
  static const double _nearEnough = 1.6;

  /// Who you're on your way to (clicked in the people list), and when to look again at where they've got to.
  ({String id, double replanAt})? _walkingTo;

  /// The elevator ride is walkTo's own, so it doesn't end the walk.
  bool _walkRide = false;

  /// Walks you over to a teammate, riding the elevator first if they're on another floor. A key of yours takes over.
  void walkTo(String id) {
    final p = store.peers[id];
    if (p == null || id == store.you) return;
    if (!store.onMyFloor(p) && p.floor == null) return;
    if (player.seat != null) standUp();
    _errand = null;
    _walkingTo = (id: id, replanAt: 0);
    if (store.onMyFloor(p)) {
      toast('🚶 Walking over to ${p.name}');
    } else {
      final floor = store.floors.where((f) => f.id == p.floor).firstOrNull?.name ?? 'other';
      toast('🛗 Taking the elevator to ${p.name}, on the $floor floor');
      _walkRide = true;
      try {
        ride(p.floor!);
      } finally {
        _walkRide = false;
      }
    }
  }

  /// The corners of a walk from [from] to [to] on the building's map: round the office (and up its stairs),
  /// or round a map of its own's hall (and down to its dungeon).
  List<Corner> _wayTo(WalkSpot from, WalkSpot to) {
    if (inOffice) return wayTo(from, to);
    final d = world.dungeon;
    final hall = world.nav;
    final Pt a = (from.x, from.z), b = (to.x, to.z);
    final pts = d != null
        ? levelRoute(d.plan, hall, d.nav, a, from.y < d.plan.ceiling - 0.5, b, to.y < d.plan.ceiling - 0.5)
        : hall.route(a, b);
    return [for (final (x, z) in pts.skip(1)) (x: x, z: z)];
  }

  void _stopWalking() {
    _walkingTo = null;
    _errand = null;
    player.stopWalking();
  }

  /// What you're on your way to (see [walkThen]): where to stand, what it's called, what to turn to and what
  /// to do there.
  ({PaletteSpot at, String what, PaletteSpot? face, void Function() then})? _errand;

  /// Walks you over to [at] on this floor and does [then] when you get there, as if you'd walked up and
  /// pressed E. Where there's no walking to be done (up on the roof, riding the elevator, on the ladder) it
  /// just does it. A key of yours takes over, and then it doesn't happen.
  void walkThen(PaletteSpot at, String what, void Function() then, {PaletteSpot? face}) {
    if (roofHub.upTop || _riding != null || climber.active) return then();
    ModalStack.instance.closeAll();
    if (player.seat != null) standUp();
    _stopWalking();
    _errand = (at: at, what: what, face: face, then: then);
    toast('🚶 Walking over to $what');
    player.walkPath(_wayTo((x: player.pos.x, y: player.pos.y, z: player.pos.z), (x: at.x, y: 0, z: at.z)));
  }

  void _errandEnd(PathEnd why) {
    final e = _errand!;
    _errand = null;
    if (why == PathEnd.cancelled) return;
    if (why == PathEnd.stuck) {
      toast("🚧 Couldn't find a way over to ${e.what}, so here it is from where you are", ToastKind.warn);
    }
    final face = e.face;
    if (why != PathEnd.stuck && face != null) {
      _arrivedAt((x: face.x, y: 0, z: face.z));
    } else {
      _stopWalking();
    }
    e.then();
  }

  /// Ctrl+K (⌘K on a Mac): the command palette, from anywhere but a text box or a terminal, where the key is
  /// theirs (in a shell, Ctrl+K cuts to the end of the line). In the palette's own box it puts it away.
  bool _onPaletteKey(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final hk = HardwareKeyboard.instance;
    final press = (
      key: e.character ?? e.logicalKey.keyLabel,
      code: e.physicalKey == PhysicalKeyboardKey.keyK ? 'KeyK' : '',
      ctrlKey: hk.isControlPressed,
      altKey: hk.isAltPressed,
      shiftKey: hk.isShiftPressed,
      metaKey: hk.isMetaPressed,
    );
    if (!isPaletteKey(press, isMacKeyboard)) return false;
    final focus = FocusManager.instance.primaryFocus;
    final inPalette = paletteOpen() && identical(focus, paletteFocus);
    if (!inPalette && (_typingIn(focus) || hud.typing)) return false;
    togglePalette(() => paletteEntries(_paletteHost));
    return true;
  }

  /// Whether [focus] is a text box or a terminal.
  static bool _typingIn(FocusNode? focus) {
    if (focus == null) return false;
    if (focus.debugLabel == 'terminal') return true;
    final ctx = focus.context;
    if (ctx == null) return false;
    var typing = false;
    if (ctx.widget is EditableText) return true;
    ctx.visitAncestorElements((el) {
      if (el.widget is EditableText) typing = true;
      return !typing;
    });
    return typing;
  }

  late final PaletteHost _paletteHost = PaletteHost(
    store: store,
    you: () => (x: player.pos.x, z: player.pos.z),
    interactables: () => world.interactables,
    walkThen: walkThen,
    openTerminal: openWorkerTerminal,
    hireAt: _hireAtDesk,
    showQueue: showQueue,
    showSettings: showSettings,
    showSearch: showSearch,
    invite: () {
      if (store.invites) {
        openTeam(scope);
      } else if (store.me.admin) {
        openAccounts(scope);
      }
    },
    startHanging: _startHanging,
    openBoard: (kind) => switch (kind) {
      InteractKind.issues => openBoard(scope, BoardKind.issues),
      InteractKind.pulls => openBoard(scope, BoardKind.pulls),
      InteractKind.services => openServices(scope),
      InteractKind.whiteboard => whiteboard.open(),
      InteractKind.meeting => rooms.showMeeting(),
      _ => null,
    },
    openIssue: (i) => openIssue(scope, i),
    openPull: (p) => openPull(scope, p),
    walkTo: walkTo,
  );

  /// The place a peer's `seat` names on the building's map, from where you are (up on the roof, or down on a floor).
  SeatPlace? _seatAt(String key) => seatHereOn(plan, key, store.floor == roof);

  /// Where they are, sitting or standing.
  WalkSpot _whereIs(PeerInfo p) {
    final s = p.seat != null ? _seatAt(p.seat!) : null;
    return s != null ? (x: s.x, y: s.y, z: s.z) : (x: p.x, y: p.y, z: p.z);
  }

  /// There: stop, and turn to them.
  void _arrivedAt(WalkSpot at) {
    _stopWalking();
    final yaw = math.atan2(at.x - player.pos.x, at.z - player.pos.z);
    player.facing = yaw;
    player.camYaw = yaw - math.pi;
  }

  double _flat(WalkSpot at) => math.sqrt(math.pow(at.x - player.pos.x, 2) + math.pow(at.z - player.pos.z, 2));

  /// Each frame: keep heading for them, looking again every so often in case they've moved on.
  void _walkTick(double now) {
    final w = _walkingTo;
    if (w == null || _riding != null) return;
    // Opening something on the way over to someone is stopping there.
    if (ModalStack.instance.open) return _stopWalking();
    if (!player.enabled) return;
    // Sitting down on the way is stopping there.
    if (player.seat != null) return _stopWalking();
    final p = store.peers[w.id];
    if (p == null || !store.onMyFloor(p)) {
      toast(p != null ? '${p.name} left the floor before you got there' : 'They left the office', ToastKind.warn);
      return _stopWalking();
    }
    final at = _whereIs(p);
    if (_flat(at) < _nearEnough && (at.y - player.pos.y).abs() < 1) return _arrivedAt(at);
    if (now < w.replanAt) return;
    _walkingTo = (id: w.id, replanAt: now + 800);
    player.walkPath(_wayTo((x: player.pos.x, y: player.pos.y, z: player.pos.z), at));
  }

  void _pathEnded(PathEnd why) {
    if (_errand != null) return _errandEnd(why);
    final w = _walkingTo;
    if (w == null) return;
    if (why == PathEnd.cancelled) {
      _walkingTo = null;
      return;
    }
    final p = store.peers[w.id];
    if (p == null) return _stopWalking();
    final at = _whereIs(p);
    // As near as the way goes (they're behind a desk, or on the couch): that'll do.
    if (_flat(at) < 3) return _arrivedAt(at);
    if (why == PathEnd.stuck) {
      toast("🚧 Couldn't find a way over to ${p.name}", ToastKind.warn);
      _stopWalking();
    } else {
      _walkingTo = (id: w.id, replanAt: 0);
    }
  }

  /// What you last told the office you have open (see PeerInfo.doing).
  String? _doingSent;
  bool _readingSent = false;
  double _presenceAt = 0;

  /// Tells everyone what you have open now, for the line under your name tag, and whether you're reading.
  void _sendDoing() {
    final what = clipDoing(ModalStack.instance.doingNow);
    final reading = ModalStack.instance.readingNow;
    if (what == _doingSent && reading == _readingSent) return;
    _doingSent = what;
    _readingSent = reading;
    net.send(DoingCmd(what: what, reading: reading ? true : null));
  }

  /// A few times a second: what you have open, and what people are up to (it changes as they walk
  /// about, not only when they open something).
  void _presenceTick(double now) {
    if (now - _presenceAt < 200) return;
    _presenceAt = now;
    _sendDoing();
    for (final e in _remotes.entries) {
      final p = store.peers[e.key];
      if (p != null) e.value.person.setDoing(whereabouts(p, plan));
    }
  }

  // ---- Peers ------------------------------------------------------------------------------------

  void _syncPeers() {
    for (final peer in store.peers.values) {
      // Only who's on your floor is in the room with you.
      if (peer.id == store.you || !store.onMyFloor(peer)) continue;
      var r = _remotes[peer.id];
      if (r == null) {
        final person = Person(peer.name, peer.color, peer.look, labels)
          ..onSmoke = _puff
          ..setCostume(_theme);
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
      r.person.holdDrink(roofHub.drinkOf(peer));
      r.person.sit(peer.seat != null ? _seatAt(peer.seat!)?.hips : null);
      r.person.setDoing(whereabouts(peer, plan));
      r.person.carry(peer.carrying);
    }
    _cork.off = _offBoard();
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
        offset: vm.Vector3(0, r.person.bubbleY, 0),
        child: TagPill('💬 ${clip(text, 60)}', bg: '#ffffff', size: 34),
      ),
    );
    r.bubbleUntil = nowMs() + 6000;
  }

  // ---- Workers ----------------------------------------------------------------------------------

  void _syncWorkers() {
    for (final w in store.workers.values) {
      final desk = world.desks[w.deskId];
      if (desk == null) continue;
      var v = _workerViews[w.id];
      if (v == null) {
        departures.vacate(w.deskId);
        sendoffs.vacate(w.deskId);
        final model = Worker(w.name, w.color, labels)
          ..setCostume(_theme)
          ..setOutfit(plan.outfit == 'peasant' ? 'peasant' : null)
          ..setAge(_ageOf(w));
        desk.seatAnchor.add(model.root);
        // Its globe floats beside the laptop (or the kiosk's counter), out from behind the card over its
        // head and the back of its chair, so it shows from across the room.
        final beside = desk.def.station != null ? vm.Vector3(0.62, 0.9, 0) : vm.Vector3(0.64, 0.5, -0.1);
        model.setPropSpot(pointIn(model.root, desk.laptopAnchor, beside));
        // In the castle, a worker at the tables gets up and walks about (see Court): a new one runs in to its seat.
        final court = worlds.court;
        if (court != null && _inCourt(w)) court.add(w.id, model, desk, _seatedAlready ? null : _cameFrom(w));
        final laptop = Laptop(tome: world.device == WorldDevice.tome);
        desk.laptopAnchor.add(laptop.root);
        desk.vacancy.visible = false;
        desk.chair.rotation = vm.Quaternion.identity();
        v = _WorkerView(model, laptop, w.deskId);
        _workerViews[w.id] = v;
      }
      if (v.status != w.status || v.acked != w.acked) {
        // It just finished or started waiting on you: ding (one that needs you has an alarm of its own, see
        // office/needs_you.dart), and notify if you're away.
        if (waitingOnSomeone(w) && v.status != null && w.status != v.status) {
          if (w.status == WorkerStatus.done) sound.ding(Ding.done);
          notifier.alert(w);
          rooms.workerChanged(w);
        }
        // Finished what it was on: a little spin and a puff of confetti.
        if (w.status == WorkerStatus.done &&
            (v.status == WorkerStatus.working || v.status == WorkerStatus.needsInput)) {
          v.model.celebrate();
          _burstOver(w.deskId, 40);
        }
        v.status = w.status;
        v.acked = w.acked;
        v.model.setStatus(w.status, waitingOnSomeone(w));
      }
      final task = w.task;
      v.model.setPr(workerPr(w, store.pulls.items, store.queue.tasks));
      v.model.setLost(w.lost != null);
      v.model.setTask(
        task != null && w.kind == WorkerKind.agent
            ? WorkerTask(name: '${providerLabel(w.provider, store.project)} · ${task.name}', summary: task.summary)
            : task,
      );
      v.model.setAction(w.action);
      final def = plan.byId[w.deskId];
      // Keys clack while it types, not while it reads, watches its tests or browses.
      if (def != null) {
        sound.setTyping(
          w.id,
          def.x,
          def.z,
          w.status == WorkerStatus.working && (w.action == null || w.action == WorkerAction.edit),
        );
      }
      final again = w.kind == WorkerKind.shell ? 'restart' : 'resume';
      v.laptop.setPlaceholder(
        w.lost != null
            ? "🌿 ${w.name}'s worktree was deleted — press E to fix it"
            : w.status == WorkerStatus.offline
            ? '💤 ${w.name} is asleep — press R to $again'
            : w.status == WorkerStatus.exited
            ? '${w.name} exited'
            : 'booting…',
      );
    }
    for (final id in _workerViews.keys.toList()) {
      if (store.workers.containsKey(id)) continue;
      final v = _workerViews.remove(id)!;
      final desk = world.desks[v.deskId];
      // Up and about in the castle: it sets off from where it's standing.
      final up = worlds.court?.release(id);
      // Sent home: it packs up and walks out, and the seat shows as free once it's up (see departures),
      // or on a map with its own way of seeing workers off, that (the castle's dungeon, for one it locks up).
      if (desk != null && _sentHome.contains(id) && _sendOff(id, v, desk, up)) {
        // The map's script has it.
      } else if (desk != null && _sentHome.contains(id)) {
        departures.add(v.model, v.laptop, _Leaving(desk), up);
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
    // Whoever's waiting on someone lines up for the throne, the one who's waited longest first.
    worlds.court?.line([
      for (final w in waitingInOrder(store.workers.values))
        if (_inCourt(w)) w.id,
    ]);
    notifier.sync(store.workers);
  }

  /// Set while a floor's workers arrive with it (a welcome, a floor.enter, a change of map): they're in
  /// their seats already, and nobody runs in.
  bool _seatedAlready = false;

  /// Syncs the workers as if they were in their seats already: nobody walks in (see [_applyMap]).
  void _syncWorkersSeated() {
    final already = _seatedAlready;
    _seatedAlready = true;
    _syncWorkers();
    _seatedAlready = already;
  }

  /// A worker that sits at the tables (not a board agent or at the meeting table): it gets up and lines
  /// up for the throne.
  bool _inCourt(WorkerInfo w) {
    final d = plan.byId[w.deskId];
    return w.kind == WorkerKind.agent && d != null && d.station == null && !d.room && w.meeting == null;
  }

  /// How long a worker sent out from the herald has to turn up before its seat's forgotten (ms).
  static const double _heraldWait = 30000;

  /// Seats you've just sent a worker out to from the herald (see [_hireFromHerald]), so a second goes elsewhere.
  final Map<String, double> _heraldHires = {};

  /// The seat a worker sent out from the herald goes to: the first free one, not counting one you've just
  /// sent someone else to (it isn't taken until the office says so).
  String? _heraldSeat() {
    final now = nowMs();
    _heraldHires.removeWhere((_, at) => now - at > _heraldWait);
    return [
      ...plan.desks,
      ...plan.overflow,
    ].where((d) => store.workerAtDesk(d.id) == null && !_heraldHires.containsKey(d.id)).firstOrNull?.id;
  }

  /// Where a worker just hired comes in from, running to its seat: the herald, the doors (off the queue),
  /// or nowhere (it's just there).
  Pt? _cameFrom(WorkerInfo w) {
    _heraldHires.remove(w.deskId);
    // Sent out by the herald (by anyone: the office says so): from beside him.
    final h = plan.herald;
    if (w.via == 'herald' && h != null) return (h.x + math.sin(h.rotY) * 1.1, h.z + math.cos(h.rotY) * 1.1);
    if (w.createdBy.endsWith('(queue)')) return (plan.door.x, plan.door.z);
    return null;
  }

  /// How worn out a worker looks on this map, 0–1: how long it has worked, of the map's ageMinutes.
  double _ageOf(WorkerInfo w) {
    final since = w.workingSince;
    final now = store.officeNow();
    return _agedBy(
      (w.workedMs ?? 0) + (since != null && w.status == WorkerStatus.working ? math.max(0, now - since) : 0),
    );
  }

  /// How worn out [worked] ms of work makes a worker look on this map, 0–1.
  double _agedBy(num worked) {
    final full = plan.ageMinutes;
    return full > 0 ? math.min(1, worked / (full * 60000)) : 0;
  }

  /// When the workers' looks were last brought up to how long they've worked.
  double _agedAt = 0;

  /// A worker sent home on a map with a script for it: true when the script has it (see send_home.dart).
  bool _sendOff(String id, _WorkerView v, DeskView desk, Pt? up) {
    final send = plan.sendHome;
    if (send == null || (send.keeps && !store.jail.prisoners.any((p) => p.id == id))) return false;
    sendoffs.add(id, v.model, v.laptop, desk, up);
    return true;
  }

  /// Nobody's being seen off any more (a floor arriving, a change of map).
  void _clearSendoffs() => sendoffs.clear();

  /// Whoever the floor has kept: locked up in its dungeon, in their cells, or adrift outside its airlock.
  void _syncJail() {
    jail.sync(world.dungeon, plan.sendHome);
    adrift.sync(world.airlock, plan.sendHome);
  }

  /// Once every desk is taken, bean bags come out for the workers who don't fit.
  void _arrangeBeanbags() {
    final appeared = world.setBeanbags(
      beanbagsOut((id) => store.workerAtDesk(id) != null || departures.seated(id) || sendoffs.seated(id)),
    );
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
    for (final d in plan.desks) {
      if (store.workerAtDesk(d.id) != null) continue;
      final dist = math.sqrt(math.pow(d.x - player.pos.x, 2) + math.pow(d.z - player.pos.z, 2));
      if (dist < bestD) {
        bestD = dist;
        best = d.id;
      }
    }
    return best ??
        (inOffice
            ? nextFreeSeat((id) => store.workerAtDesk(id) != null)?.id
            : plan.overflow.where((d) => store.workerAtDesk(d.id) == null).firstOrNull?.id);
  }

  @override
  void hire(
    String deskId, {
    String? prompt,
    bool worktree = false,
    AgentProvider? provider,
    String? model,
    AgentEffort? effort,
    int? issue,
    List<String> repos = const [],
  }) {
    net.send(
      WorkerSpawnCmd(
        deskId: deskId,
        prompt: prompt,
        worktree: worktree,
        provider: provider,
        model: model,
        effort: effort,
        issue: issue,
        repos: repos.isEmpty ? null : repos,
      ),
    );
    // The moment notifications start to matter: ask once (it has to come from a key press or click).
    if (settings.notify && notifier.permission == NotifyPermission.ask && !_askedToNotify) {
      _askedToNotify = true;
      notifier.askPermission();
    }
  }

  void _openShell(String deskId) => net.send(WorkerSpawnCmd(deskId: deskId, kind: WorkerKind.shell));

  void _promptAtDesk(String deskId) {
    final w = store.workerAtDesk(deskId);
    final desk = plan.byId[deskId]!;
    if (w == null) {
      openPrompt(
        PromptOptions(
          title: '✨ New task at ${desk.label}',
          subtitle: 'A fresh worker will sit down and start on this right away. Choose the worker engine below.',
          submitLabel: 'Hire & start',
          providerOption: true,
          worktreeOption: store.project?.branch != null,
          project: store.project,
          office: store.prompts.agent,
          warning: pressureNote(store.machine),
          repoOptions: repoChoices(store),
          onSubmit: (text, o) => hire(
            deskId,
            prompt: text,
            worktree: o.worktree,
            provider: o.provider,
            model: o.model,
            effort: o.effort,
            repos: o.repos,
          ),
        ),
      );
    } else if (w.lost != null) {
      _fixLostWorktree(w);
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
    final desk = plan.byId[deskId]!;
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
        office: store.prompts.agent,
        warning: pressureNote(store.machine),
        repoOptions: repoChoices(store),
        onSubmit: (text, o) => hire(
          deskId,
          prompt: text.isEmpty ? null : text,
          worktree: o.worktree,
          provider: o.provider,
          model: o.model,
          effort: o.effort,
          repos: o.repos,
        ),
      ),
    );
  }

  @override
  void killWorker(String workerId) {
    final w = store.workers[workerId];
    if (w == null) return;
    final where = plan.byId[w.deskId]?.label ?? 'the desk';
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
          repos: workerRepoFolders(w),
          ask: () => net.send(WorkerWorktreeCmd(workerId)),
          onConfirm: (cleanup) => net.send(WorkerKillCmd(workerId, cleanup: cleanup)),
        ),
      );
      return;
    }
    confirmDialog(
      'Send ${w.name} home?',
      plan.byId[w.deskId]?.station != null
          ? 'This stops its $session for everyone, and it forgets what it was asked. The next prompt at the $where starts a fresh one.'
          : 'This stops the $session at $where for everyone and frees the desk.',
      'Send home',
      () => net.send(WorkerKillCmd(workerId)),
    );
  }

  @override
  void resumeWorker(WorkerInfo w) {
    if (w.lost != null) return _fixLostWorktree(w);
    if (w.sessionId == null && w.kind != WorkerKind.shell) {
      toast('${w.name} has no saved Claude session — starting a fresh one', ToastKind.warn);
    }
    net.send(WorkerResumeCmd(w.id));
  }

  /// Anything done with a worker whose worktree was deleted outside agent-office (see WorkerInfo.lost): it
  /// can't work there, so this says so and offers to put the folder back, everyone's at once when more are
  /// lost, or to send it home.
  void _fixLostWorktree(WorkerInfo w) {
    final lost = w.lost, wt = w.worktree;
    if (lost == null || wt == null) return;
    final others = store.workers.values.where((o) => o.lost != null && o.id != w.id).toList();
    lostWorktreeDialog(
      LostWorktreeOptions(
        name: w.name,
        worktree: (path: wt.path, branch: wt.branch),
        lost: lost,
        workspace: (w.repos?.isNotEmpty ?? false) ? wt.path.replaceFirst(RegExp(r'[\\/][^\\/]*$'), '') : null,
        others: [for (final o in others) o.name],
        openTerminal: isAsleep(w.status)
            ? null
            : () => openTerminal(scope, w.id, onChanges: () => openWorkerChanges(w.id)),
        rebuild: (all) {
          toast(all ? 'Rebuilding ${others.length + 1} worktrees…' : "Rebuilding ${w.name}'s worktree…");
          net.send(WorkerRebuildCmd(w.id, all: all));
        },
        sendHome: () => killWorker(w.id),
      ),
    );
  }

  /// Whether a worker's branch can become a PR: it has its own worktree, still there, and isn't mid-turn.
  bool _prReady(WorkerInfo w) => w.worktree != null && w.lost == null && !isBusy(w.status);

  /// O at a desk: see the worker's pull request, or push its branch and open one.
  void _pullRequestFor(WorkerInfo w) {
    if (w.repos?.isNotEmpty ?? false) return _pullRequestsFor(w);
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
    if (w.lost != null) return _fixLostWorktree(w);
    if (w.prOpening == true) return;
    if (!_prReady(w)) {
      return toast("${w.name} is still ${statusLabel(w.status)} — wait until it's done", ToastKind.warn);
    }
    toast('Pushing ${w.worktree!.branch} and opening a pull request…');
    net.send(WorkerPrCmd(w.id));
  }

  /// O at the desk of a worker across repositories: with no pull request yet, the office opens one in each
  /// repository it committed to (and lists them all in each one). Once it has one, O shows each
  /// repository's, with a button for the ones still missing.
  void _pullRequestsFor(WorkerInfo w) {
    void open() {
      final now = store.workers[w.id];
      if (now == null || now.prOpening == true) return;
      if (now.lost != null) return _fixLostWorktree(now);
      if (!_prReady(now)) {
        return toast("${now.name} is still ${statusLabel(now.status)} — wait until it's done", ToastKind.warn);
      }
      toast(
        "Pushing ${now.worktree?.branch ?? 'its branch'} in each of ${now.name}'s repositories and opening pull requests…",
      );
      net.send(WorkerPrCmd(now.id));
    }

    if (!workerRepos(w).any((r) => r.pr != null)) return open();
    openRepoPulls(
      scope,
      w.id,
      RepoPullsActions(
        openPull: (number, url) {
          final it = store.pulls.items.where((p) => p.number == number).firstOrNull;
          if (it != null) {
            openPull(scope, it);
          } else {
            openInNewTab(url);
          }
        },
        openMissing: open,
        changes: (repo) => openWorkerChanges(w.id, repo),
      ),
    );
  }

  /// Puts you in front of a desk, looking at it: the PR board's "Go to desk".
  @override
  void goToDesk(String deskId) {
    final desk = plan.byId[deskId];
    if (desk == null) return;
    ModalStack.instance.closeAll();
    _standAt(desk);
    final w = store.workerAtDesk(deskId);
    toast(w != null ? "You're at ${desk.label}, ${w.name}'s desk" : "You're at ${desk.label}");
  }

  /// Behind the worker, looking over their shoulder at the laptop. From a seat or mid-picture it gets you up first.
  void _standAt(DeskDef desk) {
    if (player.seat != null) standUp();
    if (hanger.active) hanger.cancel();
    _stopWalking();
    // In front of a board agent's kiosk.
    final spot = deskSeat(desk, desk.station != null ? -1.6 : (desk.beanbag ? 1.6 : 2.4));
    player.pos.setValues(spot.x, 0, spot.z);
    player.vy = 0;
    player.facing = math.atan2(desk.x - spot.x, desk.z - spot.z);
    player.camYaw = player.facing - math.pi;
    player.lookPitch = -0.2;
  }

  // ---- Who's waiting on you: N, the chip that counts them, and the compass ------------------------

  final NextUp _nextUp = NextUp();

  /// The chip's text ("🙋 2 waiting · ✅ 1 done", empty for none) and whether they're all done.
  final ValueNotifier<(String, bool)> waitingChip = ValueNotifier(('', false));

  /// N: to the first worker waiting on someone (the ones that need you, then the ones that are done, longest
  /// first), and on each press after, the next.
  void goToNextWaiting() {
    if (_riding != null) return;
    final w = _nextUp.next(store.workers.values, _waitingBeside());
    if (w == null || !goToWorker(w.id)) {
      final other = store.floors.where((f) => f.id != store.floor && f.waiting > 0).firstOrNull;
      toast(
        other != null
            ? "🛗 Nobody's waiting on this floor. ${other.waiting} on the ${other.name} floor: take the elevator"
            : '👍 Nobody is waiting on you',
      );
      return;
    }
    final waiting = waitingInOrder(store.workers.values);
    final of = waiting.length > 1 ? ' (${waiting.indexWhere((x) => x.id == w.id) + 1} of ${waiting.length})' : '';
    toast(
      '${w.status == WorkerStatus.needsInput ? '🙋 ${w.name} needs you' : '✅ ${w.name} is done'}$of. E opens its terminal',
    );
  }

  /// Puts you behind worker [id], looking over its shoulder, with any window closed. False when there's no
  /// getting there (you're between floors, or it's gone).
  bool goToWorker(String id) {
    final w = store.workers[id];
    final desk = w == null ? null : plan.byId[w.deskId];
    if (_riding != null || desk == null) return false;
    ModalStack.instance.closeAll();
    _standAt(desk);
    return true;
  }

  /// From a notification about worker [id]: over to its desk, with its terminal open to answer it.
  void answerWorker(String id) {
    goToWorker(id);
    openWorkerTerminal(id);
  }

  /// The waiting worker you're standing at, if any: N skips it while anyone else is waiting.
  String? _waitingBeside() {
    String? best;
    var bestD = 2.5;
    for (final w in store.workers.values) {
      final desk = plan.byId[w.deskId];
      if (desk == null || !_workerViews.containsKey(w.id) || !waitingOnSomeone(w)) continue;
      final d = math.sqrt(math.pow(desk.x - player.pos.x, 2) + math.pow(desk.z - player.pos.z, 2));
      if (d < bestD) {
        bestD = d;
        best = w.id;
      }
    }
    return best;
  }

  void _renderWaiting() {
    final waiting = waitingInOrder(store.workers.values);
    final next = (waitingLabel(waiting), waiting.every((w) => w.status == WorkerStatus.done));
    if (next != waitingChip.value) waitingChip.value = next;
  }

  /// Arrows to the waiting workers you can't see from where you're looking (engine space, at their heads).
  List<Bearing> waitingBearings() {
    if (_riding != null || ModalStack.instance.open) return const [];
    return [
      for (final w in store.workers.values)
        if (waitingOnSomeone(w) && _workerViews[w.id] != null)
          Bearing(
            id: w.id,
            name: w.name,
            status: w.status,
            at: _workerViews[w.id]!.model.root.globalTransform.transform3(vm.Vector3(0, 1.2, 0)),
          ),
    ];
  }

  /// Opening a sleeping worker's terminal wakes it, so there's nothing to press first.
  @override
  void openWorkerTerminal(String workerId, {({int row, String needle})? find}) {
    final w = store.workers[workerId];
    if (w == null) return;
    if (w.lost != null) return _fixLostWorktree(w);
    if (isAsleep(w.status)) resumeWorker(w);
    openTerminal(scope, workerId, onChanges: () => openWorkerChanges(workerId), find: find);
  }

  @override
  void openWorkerChanges(String workerId, [String? repo]) {
    final w = store.workers[workerId];
    if (w == null) return;
    if (w.lost != null) return _fixLostWorktree(w);
    openChanges(scope, workerId, onTerminal: () => openWorkerTerminal(workerId), repo: repo);
  }

  @override
  void showSearch() => openSearch(scope);

  @override
  void showQueue() => openQueue(scope);

  /// A prompt from the boards goes to a new worker at a free desk, or to one already at a desk.
  @override
  void sendToWorker(String title, {String? context, String? initial, int? issue}) {
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
        newDesk: desk == null ? null : plan.byId[desk]!.label,
        workers: [for (final w in awake) AskWorker(id: w.id, name: w.name, color: w.color, status: w.status)],
        worktreeOption: store.project?.branch != null,
        providerOption: true,
        repoOptions: repoChoices(store),
        onSubmit: (prompt, to, worktree, provider, model, effort, repos) {
          if (to != null) {
            net.send(WorkerPromptCmd(to, prompt, issue: issue));
          } else if (desk != null) {
            hire(
              desk,
              prompt: prompt,
              worktree: worktree,
              provider: provider,
              model: model,
              effort: effort,
              issue: issue,
              repos: repos,
            );
          }
        },
      ),
    );
  }

  @override
  void showSettings([SettingsPane? first]) => openSettings(
    scope,
    first: first,
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
        ..pageTurns = s.pageTurns
        ..needsYouSound = s.needsYouSound
        ..save();
      if (talkChanged) {
        voiceRoom.setMuted(settings.pushToTalk);
        hud.prefs.refresh();
      }
      player.setView(settings.view);
      sound.setVolume(settings.volume, settings.muted);
      sound.setMusicVolume(settings.music, settings.musicMuted);
    },
    onCharacter: editProfile,
    previewSound: () => sound.ding(Ding.done),
    previewNeedsYou: () => sound.needsYou(),
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

  void _interact(Interactable? target, DeskKey key, [GhIssue? note]) {
    if (target == null) return;
    // [note] is the issue note you're pointing at on the issues board, if any (see _aimedNote).
    if (target.kind != InteractKind.issues) note = null;
    final card = _carrying;
    if (key == DeskKey.e && card != null && _dropCard(target, card, note)) return;
    if (rooms.interact(target, key) || places.interact(target, key)) return;
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
    // A note on the issues board: E takes it straight off the cork, O opens it to read first.
    if (note != null && key == DeskKey.e) return pickUp(note);
    if (note != null && key == DeskKey.o) {
      openIssue(scope, note);
      return;
    }
    if (key != DeskKey.e) return;
    if (roofHub.interact(target)) return;
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
        openJukebox(scope, openVolume: () => showSettings(SettingsPane.sound));
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
      case InteractKind.herald:
        _hireFromHerald();
      case InteractKind.tv:
        voiceRoom.watchShare();
      case InteractKind.decor when target.decorId != null:
        hanger.view(target.decorId!);
      case InteractKind.whiteboard:
        whiteboard.open();
      case InteractKind.ladder:
        _grabLadder();
      case InteractKind.pole when target.pole != null:
        _usePole(target.pole!);
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
    final seat = plan.seatingById[seatId];
    if (seat == null) return;
    if (player.seat?.seatId == seatId) {
      if (seat.tv && voiceRoom.tvShowing) return voiceRoom.watchShare();
      if (seat.game) return arcade.play();
      if (seat.bar) return roofHub.showBar();
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
    return (roofHub.usable ?? world.interactables)
        .where((it) => it.kind == InteractKind.seat && it.seatId == id)
        .firstOrNull;
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
    // Up and about in the castle: over wherever it is.
    final w = store.workerAtDesk(deskId);
    final v = w != null && (worlds.court?.away(w.id) ?? false) ? _workerViews[w.id] : null;
    if (v != null) {
      final at = v.model.root.position;
      return confetti.burst(at.x, at.y + 2.1, at.z, n);
    }
    final d = plan.byId[deskId];
    if (d != null) confetti.burst(d.x, 2.3, d.z, n);
  }

  /// Someone hit the gong, a pull request merged (confetti over its desk), or the queue emptied (a party).
  void _gongRang(GongWhy why, int? pr) {
    final gong = world.gong;
    gong?.strike(why == GongWhy.hit ? 0.7 : 1);
    sound.gong(why);
    // A map with no gong: the bursts come from over the middle of the hall.
    final b = plan.bounds;
    final top = gong?.top ?? vm.Vector3((b.minX + b.maxX) / 2, 3, (b.minZ + b.maxZ) / 2);
    if (why == GongWhy.merged) {
      // Confetti rains down all over the floor, and pops over the desk the PR came from while its worker's still there.
      for (final r in world.rain) {
        confetti.rain(r.area, _area(r.area) * _confettiDensity, 3, r.top);
      }
      final it = store.pulls.items.where((p) => p.number == pr).firstOrNull;
      final w = pr == null
          ? null
          : store.workers.values
                .where((w) => w.pr?.number == pr || (it != null && w.worktree?.branch == it.headRefName))
                .firstOrNull;
      if (w != null && _workerViews.containsKey(w.id)) {
        _burstOver(w.deskId, 220);
      } else {
        confetti.burst(top.x, top.y, top.z, 220);
      }
      _danceParty();
    } else if (why == GongWhy.queue) {
      // Three strokes: a burst at the gong, then every desk, then a cannon.
      confetti.burst(top.x, top.y, top.z, 160);
      Timer(const Duration(milliseconds: 850), () {
        world.gong?.strike(0.85);
        for (final e in _workerViews.entries) {
          _burstOver(e.value.deskId, 120);
          if (!isAsleep(store.workers[e.key]?.status ?? WorkerStatus.offline)) e.value.model.cheer(4);
        }
      });
      Timer(const Duration(milliseconds: 1700), () {
        world.gong?.strike(1.2);
        confetti.burst(top.x, top.y, top.z, 450, 1.5);
      });
    }
  }

  /// Confetti a square meter of floor gets when a pull request merges.
  static const double _confettiDensity = 3.5;
  static double _area(ConfettiArea a) => (a.maxX - a.minX) * (a.maxZ - a.minZ);

  /// A pull request merged: every worker awake on the floor gets up on its desk and dances.
  void _danceParty() {
    for (final e in _workerViews.entries) {
      final v = e.value;
      final desk = world.desks[v.deskId];
      final parent = v.model.root.parent;
      if (desk == null || parent == null || isAsleep(store.workers[e.key]?.status ?? WorkerStatus.offline)) continue;
      v.model.dance(stageFrom(parent, desk.stage));
    }
  }

  // ---- Holidays ---------------------------------------------------------------------------------

  /// Dresses the building up for the holiday it's set to (⚙️ Settings), or takes it all down: the sky and
  /// the decorations, the dog, your hands and your character, everyone else, and every worker.
  void _dressUp(HolidayTheme? theme) {
    _theme = theme;
    holiday.set(theme);
    skyModel.setTheme(theme);
    dog.setCostume(theme);
    hands.setCostume(theme);
    me.setCostume(theme);
    for (final r in _remotes.values) {
      r.person.setCostume(theme);
    }
    for (final v in _workerViews.values) {
      v.model.setCostume(theme);
    }
  }

  // ---- Emotes -----------------------------------------------------------------------------------

  /// Plays an emote on your character and your hands, and shows it to everyone else on the floor.
  void emote(Emote e) {
    final now = nowMs().toDouble();
    if (!_emoteLimit.take(now)) {
      if (now - _emoteWarnedAt > 3000) {
        _emoteWarnedAt = now;
        toast('Easy there, one emote at a time', ToastKind.warn);
      }
      return;
    }
    me.emote(e);
    hands.emote(e);
    if (player.view == ViewMode.first) emotePop.value = (e, ++_emotePops);
    net.send(EmoteCmd(e));
  }

  /// G opens the emote wheel (hold it and point, or tap it and click); 1–6 play one straight away.
  bool _emoteKey(KeyEvent e) {
    final k = e.physicalKey;
    if (k == PhysicalKeyboardKey.keyG) {
      if (e is KeyDownEvent) emoteWheel.press();
      if (e is KeyUpEvent) emoteWheel.release();
      return true;
    }
    if (e is! KeyDownEvent) return false;
    if (k == PhysicalKeyboardKey.escape && emoteWheel.isOpen) {
      emoteWheel.close();
      return true;
    }
    final n = _emoteDigits.indexOf(k);
    if (n < 0) return false;
    emoteWheel.close();
    emote(emotes[n % 6]);
    return true;
  }

  static const List<PhysicalKeyboardKey> _emoteDigits = [
    PhysicalKeyboardKey.digit1,
    PhysicalKeyboardKey.digit2,
    PhysicalKeyboardKey.digit3,
    PhysicalKeyboardKey.digit4,
    PhysicalKeyboardKey.digit5,
    PhysicalKeyboardKey.digit6,
    PhysicalKeyboardKey.numpad1,
    PhysicalKeyboardKey.numpad2,
    PhysicalKeyboardKey.numpad3,
    PhysicalKeyboardKey.numpad4,
    PhysicalKeyboardKey.numpad5,
    PhysicalKeyboardKey.numpad6,
  ];

  // ---- Targeting and the hint -------------------------------------------------------------------

  Interactable? _pickTarget() {
    // Everything you can use is upstairs; down on the street you're under it all.
    if (player.pos.y < -slab - 1) return null;
    Interactable? best;
    var bestD = double.infinity;
    final up = roofHub.usable;
    final here = inOffice ? [office.interactables, gallery.interactables, dog.interactables] : [world.interactables];
    for (final list in up != null ? [up] : here) {
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
  ({Interactable it, bool near, SceneRaycastHit hit})? aimedAt(Offset screen, Size view, [double slack = 0]) {
    final ray = camera.screenPointToRay(screen, view);
    final hit = scene.raycast(ray, maxDistance: 60, layerMask: ~Hands.layer);
    if (hit == null) return null;
    final it = interactableOf(hit.node);
    if (it == null) return null; // a wall, the floor, a plant… is in the way
    final eye = toEngine(vm.Vector3(player.pos.x, player.pos.y + kEyeHeight, player.pos.z));
    return (it: it, near: hit.worldPoint.distanceTo(eye) <= _reach[it.kind]! + slack, hit: hit);
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
    if (climber.active && !ModalStack.instance.open) {
      final (k, parts) = _climbHint();
      if (k == _hintKey) return;
      _hintKey = k;
      hint.value = parts;
      return;
    }
    if (hanger.active && !ModalStack.instance.open) {
      final (k, parts) = hanger.hint();
      if (k == _hintKey) return;
      _hintKey = k;
      hint.value = parts;
      return;
    }
    final held = ModalStack.instance.open ? null : places.heldHint() ?? rooms.heldHint();
    if (held != null) {
      if (held.$1 == _hintKey) return;
      _hintKey = held.$1;
      hint.value = held.$2.isEmpty ? null : held.$2;
      return;
    }
    final t = _target;
    final card = _carrying;
    if ((t == null && card == null) || ModalStack.instance.open) {
      // Still up after a redraw was asked for (the key cleared) just as you walked away from it, too.
      if (_hintKey.isNotEmpty || hint.value != null) {
        hint.value = null;
        _hintKey = '';
      }
      return;
    }
    final (k, parts) = card != null ? _carryHint(card, t) : _hintFor(t!);
    final key = '${t?.kind}${t?.deskId ?? ''}|${card?.issue ?? ''}|$k';
    if (key == _hintKey) return;
    _hintKey = key;
    hint.value = parts;
  }

  (String, List<HintPart>) _hintFor(Interactable it) {
    final room = rooms.hint(it) ?? places.hint(it);
    if (room != null) return room;
    (String, List<HintPart>) board(String name) => ('', [HintTitle(name), const HintKey('E', 'Open')]);
    switch (it.kind) {
      case InteractKind.desk:
        return it.deskId != null ? _deskHint(it.deskId!) : ('', []);
      case InteractKind.issues:
        final note = _aimedNote;
        if (note != null) {
          return (
            '${note.number}',
            [
              HintTitle(clip('📌 #${note.number} ${note.title}', 60)),
              const HintKey('E', 'Take it'),
              const HintKey('O', 'Read it'),
            ],
          );
        }
        final notes = CorkBoardPainter.issueNumbers(store.issues, _cork.off, store.taskForIssue).isNotEmpty;
        return notes
            ? (
                'notes',
                [
                  const HintTitle('📌 Issues board'),
                  const HintKey('E', 'Open'),
                  const HintAside('or point at a note to take it'),
                ],
              )
            : board('📌 Issues board');
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
        return (
          '$buzzed',
          [
            HintTitle(it.label ?? '☕ Coffee machine'),
            HintKey(
              'E',
              buzzed
                  ? 'Another ${it.label != null ? 'drink' : 'cup'}'
                  : (it.label != null ? 'Have a drink' : 'Grab a cup'),
            ),
          ],
        );
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
        final seat = plan.seatingById[it.seatId ?? ''];
        if (seat == null) return ('', []);
        if (player.seat?.seatId == seat.id) {
          return (
            '${seat.id}|sitting',
            [
              HintTitle(seat.label),
              const HintAside('sitting'),
              if (seat.game) ...[
                const HintKey('E', 'Play Minesweeper'),
                const HintKey('W A S D', 'Get up'),
              ] else if (seat.bar) ...[
                const HintKey('E', 'Order a drink'),
                const HintKey('W A S D', 'Get up'),
              ] else
                const HintKey('E', 'Get up'),
            ],
          );
        }
        final full = _freePlace(seat) == null;
        return (
          '${seat.id}|$full',
          [
            HintTitle(seat.label),
            if (seat.game) const HintAside('💣 Minesweeper on the monitor'),
            full ? const HintAside('no room') : const HintKey('E', 'Sit down'),
          ],
        );
      case InteractKind.bar || InteractKind.dj:
        return roofHub.hintFor(it) ?? ('', []);
      case InteractKind.ladder:
        final up = _floorThere(1)?.name, down = _floorThere(-1)?.name;
        final where = [if (up != null) '⬆ $up', if (down != null) '⬇ $down'].join(' · ');
        return (
          where,
          [
            const HintTitle('🪜 Ladder'),
            HintAside(where.isEmpty ? 'no other floors yet' : where),
            const HintKey('E', 'Climb on'),
          ],
        );
      case InteractKind.pole:
        final down = _floorThere(-1)?.name;
        return (
          '$down',
          [
            const HintTitle('🚒 Fire pole'),
            if (down != null) ...[
              HintAside('⬇ $down'),
              const HintKey('E', 'Slide down'),
            ] else ...[
              const HintAside('bottom floor'),
              const HintKey('E', 'Spin round it'),
            ],
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
      case InteractKind.herald:
        return _heraldHint();
      case InteractKind.station ||
          InteractKind.cabinet ||
          InteractKind.meeting ||
          InteractKind.golf ||
          InteractKind.ball ||
          InteractKind.bookshelf ||
          InteractKind.telescope:
        return ('', []);
    }
  }

  (String, List<HintPart>) _deskHint(String deskId) {
    final w = store.workerAtDesk(deskId);
    if (w == null) {
      final paused = hiringPaused(store.usage);
      return (
        '$paused',
        [
          HintTitle('${plan.byId[deskId]!.label} · empty'),
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
    if (w.lost != null && w.worktree != null) {
      return (
        'lost|${w.id}|${w.lost!.wire}',
        [
          HintTitle('${w.name} · 🌿 worktree deleted'),
          const HintAside('deleted outside agent-office'),
          const HintKey('E', 'Fix it'),
          const HintKey('X', 'Send home'),
        ],
      );
    }
    final doing = w.activity != null ? clip(w.activity!, 48) : '';
    final provider = w.kind == WorkerKind.agent ? resolvedProvider(w.provider, store.project) : AgentProvider.claude;
    final spent = w.kind == WorkerKind.agent && w.usage != null ? usageLabel(w.usage!, provider) : '';
    final shell = w.kind == WorkerKind.shell;
    return (
      '${w.status}${w.id}${w.pr?.number ?? ''}${w.repos?.map((r) => r.pr?.number ?? '-').join(',') ?? ''}${w.prOpening == true ? '!' : ''}$doing$spent',
      [
        HintTitle('${w.name} · ${statusLabel(w.status)}'),
        if (doing.isNotEmpty) HintAside(doing),
        if (spent.isNotEmpty) HintCost(spent, tooltip: usageTitle(w.usage!, provider)),
        const HintKey('E', 'Open terminal'),
        const HintKey('C', 'Changes'),
        isAsleep(w.status)
            ? HintKey('R', shell ? 'Restart' : 'Resume')
            : HintKey('P', shell ? 'Run command' : 'Prompt'),
        if (w.repos?.isNotEmpty ?? false)
          ...switch (reposKey(w, ready: _prReady(w))) {
            null => const <HintPart>[],
            (key: true, :final text) => [HintKey('O', text)],
            (key: false, :final text) => [HintAside(text)],
          }
        else if (w.pr != null)
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

  /// [key] at [it]: false when it does nothing there, so the key goes on to walking (see interaction.dart).
  bool _use(Interactable? it, DeskKey key, [GhIssue? note]) {
    final n = note ?? _aimedNote;
    final deskId = it?.deskId;
    final worker = deskId == null ? null : store.workerAtDesk(deskId);
    final room = deskId != null && (plan.byId[deskId]?.room ?? false);
    if (!interactionAvailable(it, key, (worker: worker, room: room, note: n, carrying: _carrying != null))) {
      return false;
    }
    _reachOut();
    _interact(it!, key, n);
    return true;
  }

  /// A key went down while the office has the keyboard. True when it was one of the office's own.
  bool onKey(KeyEvent e) {
    // Letting go of G picks what the wheel points at, whatever else has the keyboard now.
    if (e is KeyUpEvent && e.physicalKey == PhysicalKeyboardKey.keyG) {
      emoteWheel.release();
      return emoteWheel.isOpen;
    }
    if (!ModalStack.instance.open && !hud.typing && (places.key(e) || rooms.key(e))) return true;
    if (e is! KeyDownEvent) return false;
    if (ModalStack.instance.open || hud.typing) return false;
    final hk = HardwareKeyboard.instance;
    if (hk.isMetaPressed || hk.isControlPressed || hk.isAltPressed) return false;
    if (_emoteKey(e)) {
      player.input.clear();
      return true;
    }
    if (hanger.key(e.physicalKey, reach: _reachOut)) return true;
    // On the ladder, E gets you off it (and nothing else is in reach); W, S and Space climb.
    if (climber.active && (_deskKeys.containsKey(e.physicalKey) || e.physicalKey == PhysicalKeyboardKey.keyF)) {
      if (e.physicalKey == PhysicalKeyboardKey.keyE) climber.letGo();
      return true;
    }
    final deskKey = _deskKeys[e.physicalKey];
    if (deskKey != null && _use(_target, deskKey)) {
      player.input.clear();
      return true;
    }
    if (hud.handleKey(e)) {
      player.input.clear();
      return true;
    }
    if (e.physicalKey == PhysicalKeyboardKey.keyF) {
      _startHanging();
      return true;
    }
    // On the throne: the herald beside you sends out a new worker.
    if (e.physicalKey == PhysicalKeyboardKey.keyK && _onThrone() && world.herald != null) {
      _reachOut();
      _hireFromHerald();
      return true;
    }
    if (e.physicalKey == PhysicalKeyboardKey.keyN) {
      goToNextWaiting();
      return true;
    }
    if (e.physicalKey == PhysicalKeyboardKey.keyQ && _carrying != null) {
      _reachOut();
      _putBack();
      return true;
    }
    return false;
  }

  /// F: hang a picture on a wall of this floor. There are no walls for them up on the roof.
  void _startHanging() {
    if (roofHub.upTop) {
      return toast('No walls to hang pictures on up here — take the elevator down to a floor', ToastKind.warn);
    }
    hanger.start();
  }

  /// A click (not a drag) on the scene, at [screen] in a view of [view] size.
  void onClick(Offset screen, Size view) {
    if (ModalStack.instance.open) return;
    if (places.click() || rooms.click()) return;
    if (hanger.active) {
      _reachOut();
      return hanger.place(screen);
    }
    if (player.view == ViewMode.first) {
      // Reach out even at nothing, like poking the air.
      _reachOut();
      if (_target != null) _interact(_target, DeskKey.e, _aimedNote);
      return;
    }
    final aim = aimedAt(screen, view, 2.5);
    if (aim == null) return;
    if (!aim.near) {
      toast('Walk closer to that first');
      return;
    }
    _use(aim.it, DeskKey.e, _noteUnder(aim));
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
      debugPrint(
        'PERF tick ${(_perfTick / _perfN).toStringAsFixed(1)} ms, frame ${(_perfDt / _perfN * 1000).toStringAsFixed(0)} ms',
      );
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
    _walkTick(now);
    // Walked into a pole's hole: down you go.
    if (office.stack.polesGoDown() &&
        !climber.active &&
        _climbing == null &&
        _riding == null &&
        player.seat == null &&
        player.enabled) {
      final hole = office.stack
          .poles()
          .where((s) => math.sqrt(math.pow(player.pos.x - s.x, 2) + math.pow(player.pos.z - s.z, 2)) < Pole.hole - 0.15)
          .firstOrNull;
      if (hole != null && player.pos.y > -1.35 && player.pos.y < 0.6) {
        // A trip down the pole ends a walk over to someone (#98).
        _stopWalking();
        climber.slide(hole);
      }
    }
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
      up: _cameraUp(),
      fovNear: 0.1,
      // You can see the whole city from the roof; lower down the haze sets how far (see hazeFog).
      fovFar: roofHub.upTop ? 700 : 320,
    );
    camera = arcade.update(camera, dt, view);
    camera = rooms.update(camera, dt, t, view);
    camera = places.update(camera, dt, t);
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
    // Where you are, to come back to next time.
    if (now - _spotSavedAt > 1000) {
      _spotSavedAt = now;
      _saveSpot();
    }

    for (final e in _remotes.entries) {
      final peer = store.peers[e.key];
      final pose = store.poses[e.key];
      if (peer == null || pose == null) continue;
      final r = e.value;
      // Sitting, they're wherever their seat puts them.
      final sat = peer.seat != null ? _seatAt(peer.seat!) : null;
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
      final airborne = sat == null && pose.y > groundAt(player.colliders, pose.x, pose.z, pose.y) + 0.05;
      final walking = sat == null && pose.moving && !airborne;
      r.person.update(dt, t, walking, airborne && (pos.y - target.y).abs() > 0.01);
      // Their walk cycle takes a step every pi/11 seconds.
      r.stepT = walking ? r.stepT + dt : 0.2;
      if (r.stepT >= math.pi / 11) {
        r.stepT -= math.pi / 11;
        sound.stepAt(pos.x, pos.z);
      }
      r.person.emojiLift = r.bubble != null ? 0.45 : 0;
      if (r.bubble != null && now > r.bubbleUntil) {
        labels.remove(r.bubble);
        r.bubble = null;
      }
    }

    // How worn out each looks, as they work on (every second or so is plenty).
    final aging = plan.ageMinutes > 0 && now - _agedAt > 1000;
    if (aging) _agedAt = now;
    for (final e in _workerViews.entries) {
      final v = e.value;
      final desk = plan.byId[v.deskId];
      if (desk == null) continue;
      if (aging) {
        final w = store.workers[e.key];
        if (w != null) v.model.setAge(_ageOf(w));
      }
      // A jumping worker holds still while you're near enough to read its card, and jumps again once you walk away.
      final at = fromEngine(v.model.root.globalTransform.getTranslation());
      final d = math.sqrt(math.pow(at.x - player.pos.x, 2) + math.pow(at.z - player.pos.z, 2));
      v.model.held = d < (v.model.held ? _holdLeave : _holdNear);
      v.model.update(dt, t);
      // A board agent's kiosk has no laptop to paint.
      if (desk.station == null) {
        v.laptop.update(
          dt,
          store.screens[e.key],
          math.sqrt(math.pow(desk.x - player.camPos.x, 2) + math.pow(desk.z - player.camPos.z, 2)),
        );
      }
    }
    _presenceTick(now);
    voiceRoom.tick(now, me, {for (final e in _remotes.entries) e.key: e.value.person}, player.pos);
    departures.update(dt, t);
    if (!roofHub.upTop) _sendoffsTick(dt, t);
    for (final a in worlds.idleAgents) {
      if (a.view.vacancy.visible) a.model.update(dt, t);
    }
    worlds.court?.update(dt);
    dog.update(dt);
    world.update(t, dt, [
      player.pos,
      ...[for (final r in _remotes.values) r.person.root.position],
      ...departures.positions(),
      ...?worlds.court?.positions(),
      ...sendoffs.positions(),
    ]);
    if (inOffice) _officeTick(t, dt);
    _checkSmokeBreak(now);
    smoke.update(dt, player.camPos, player.camTarget);
    needsYou.update(
      t,
      player.pos,
      player.camPos,
      calm: WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations,
    );
    confetti.update(dt);
    holiday.update(t, skyModel.lampsOn, player.camPos);
    hanger.update(view, locked: lockAvailable ? pointerLocked : null);
    // Drinks from the rooftop bar, and up there everything moving to the DJ's set.
    roofHub.tick(now, t, dt, skyModel.lampsOn);
    _updateSky(dt, t);

    _aimedNote = null;
    if (ModalStack.instance.open || hanger.active || climber.active || places.busy) {
      _target = null;
    } else if (firstPerson) {
      final aim = aimedAt(Offset(view.width / 2, view.height / 2), view);
      _target = aim != null && aim.near ? aim.it : _mySeat() ?? rooms.nearby();
      if (aim != null && aim.near) _aimedNote = _noteUnder(aim);
    } else {
      _target = _mySeat() ?? _pickTarget();
      // By the issues board, the mouse points at the note you'd take.
      final mouse = hanger.mouse;
      if (_target?.kind == InteractKind.issues && mouse != null) {
        final aim = aimedAt(mouse, view, 2.5);
        if (aim != null && aim.near) _aimedNote = _noteUnder(aim);
      }
    }
    _cork.lifted = _aimedNote?.number;
    _renderHint();
    final show = firstPerson && !ModalStack.instance.open;
    final free = show && lockAvailable && !pointerLocked;
    final next = CrosshairState(show: show, on: _target != null, free: free, relookOnKey: free && relookOnKey);
    if (next != crosshair.value) crosshair.value = next;
  }

  /// Each frame, while you're on a map of its own: whoever the map is seeing off, locked up or adrift.
  void _sendoffsTick(double dt, double t) {
    sendoffs.update(dt, t);
    jail.update(dt, t, player.camPos);
    adrift.update(dt, t, player.camPos);
  }

  /// Each frame, while the building's the office: its jukebox, and the ladder and poles between floors.
  void _officeTick(double t, double dt) {
    office.jukebox.update(t, dt, sound.beat());
    office.stack.update(dt, [
      (x: player.pos.x, y: player.pos.y, z: player.pos.z, onLadder: climber.grip == Grip.ladder),
      for (final r in _remotes.values)
        () {
          final q = r.person.root.position;
          final ground = groundAt(office.colliders, q.x, q.z, q.y);
          return (x: q.x, y: q.y, z: q.z, onLadder: gripOf(q.x, q.y, q.z, office.stack.poles(), ground) == Grip.ladder);
        }(),
    ], player.camPos);
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

  /// The camera's up, in engine space: straight up, unless a few drinks have the view rolling.
  vm.Vector3 _cameraUp() {
    final roll = player.roll;
    if (roll == 0) return vm.Vector3(0, 1, 0);
    final look = (player.camTarget - player.camPos)..normalize();
    final right = look.cross(vm.Vector3(0, 1, 0));
    if (right.length2 < 1e-6) return vm.Vector3(0, 1, 0);
    right.normalize();
    final up = right.cross(look)..normalize();
    return toEngine(up * math.cos(roll) + right * math.sin(roll));
  }

  /// Set by the page when closing the last window may not have given you the mouse back: the next
  /// key you press takes it instead (a key counts for the browser, where the Esc that closed it doesn't).
  bool relookOnKey = false;

  /// Someone else on your floor, as you see them.
  Person? personOf(String id) => _remotes[id]?.person;

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
    // Pools of light round the eight lamps nearest you (the office's: a map of its own lights itself, see mood).
    final lamps = inOffice || roofHub.upTop
        ? ([...office.night.lamps]..sort((a, b) => _d2(a.x, a.z).compareTo(_d2(b.x, b.z))))
        : const <Lamp>[];
    for (var i = 0; i < 8; i++) {
      if (i < lamps.length && m.lampsOn > 0.005) {
        final lamp = lamps[i];
        // The ones down by the street are as far down as the street is from the floor you're on.
        final y = lamp.ground ? lamp.y + office.night.street - streetY : lamp.y;
        l.lampPos[i].setValues(lamp.x, y, lamp.z, lamp.reach);
        final c = Rgb.hex(int.parse(lamp.color.substring(1), radix: 16)).scale(lamp.power * m.lampsOn);
        l.lampColor[i].setValues(c.r, c.g, c.b);
      } else {
        l.lampPos[i].setZero();
      }
    }
    roofHub.light(l);
    l.officeOn = inOffice || roofHub.upTop ? 1 : 0;
    final mood = world.mood;
    if (!roofHub.upTop && mood != null) {
      mood((light: l, fog: scene.fog, daylight: m.daylight, t: t, eye: player.camPos));
    }
    Toon.updateLight();
    for (final b in office.night.bulbs) {
      b.glow(m.lampsOn);
    }
    office.night.setWindowsLit(m.lampsOn * 1.1);
    setToonColor(office.night.clouds, m.clouds.color);
    final fog = scene.fog;
    if (!roofHub.upTop && mood != null) {
      // The world's mood set its own fog.
    } else if (roofHub.upTop) {
      fog.color = m.background.vector;
      fog.start = m.fogNear * roofHub.fogReach;
      fog.end = m.fogFar * roofHub.fogReach;
    } else {
      fog.color = m.background.vector;
      // The haze thins out the higher you are over the street (see hazeFog).
      final haze = hazeFog(m.fogNear, m.fogFar, player.camPos.y, office.night.street);
      fog.start = haze.start;
      fog.end = haze.end;
    }
    // Out in space it's black, whatever the hour.
    final bg = !roofHub.upTop && world.ownSky ? const Color(0xFF000000) : m.background.color;
    if (bg != sky.value) sky.value = bg;
    sound.setWeather(m.rain, 1 - m.daylight);
  }

  double _d2(double x, double z) => math.pow(x - player.camPos.x, 2) + math.pow(z - player.camPos.z, 2).toDouble();
}

/// What a sendoff is heard by: the office's sounds.
class _SendoffSounds implements SendoffSounds {
  _SendoffSounds(this.c);
  final OfficeController c;

  @override
  void step(double x, double y, double z) => c.sound.stepAt(x, z, y);

  @override
  void door(vm.Vector3 at, bool open) => c.sound.cellDoor(at.x, at.y, at.z, open);

  @override
  void thud(vm.Vector3 at) => c.sound.thud(at.x, at.y, at.z);

  @override
  void airlock(vm.Vector3 at, String what) => c.sound.airlock(at.x, at.y, at.z, what);
}
