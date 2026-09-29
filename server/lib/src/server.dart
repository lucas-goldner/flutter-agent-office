import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';

import 'package:office_shared/shared.dart' hide Floor, Jukebox, Whiteboard;
import 'package:path/path.dart' as p;
import 'package:relic/relic.dart';
import 'package:web_socket/web_socket.dart' show BinaryDataReceived, CloseReceived, TextDataReceived;

import 'accounts.dart';
import 'agents.dart';
import 'auth.dart';
import 'building.dart';
import 'cabinet.dart';
import 'config.dart';
import 'decor.dart' show ImageData, ImageError, ImageProxy;
import 'floor.dart';
import 'headless.dart' show ScreenFrame;
import 'history.dart';
import 'limits.dart';
import 'models.dart';
import 'relay.dart';
import 'secrets.dart' show writePrivateFile;
import 'services.dart';
import 'sky.dart';
import 'static.dart';
import 'team.dart';
import 'theme.dart';
import 'upgrade.dart';
import 'usage.dart';
import 'webhook.dart';
import 'workers.dart';

/// Content types by extension, with the charset the text ones are sent in.
const Map<String, (MimeType, bool)> _mime = {
  '.html': (MimeType.html, true),
  '.js': (MimeType('text', 'javascript'), true),
  '.css': (MimeType.css, true),
  '.svg': (MimeType('image', 'svg+xml'), false),
  '.png': (MimeType('image', 'png'), false),
  '.jpg': (MimeType('image', 'jpeg'), false),
  '.ico': (MimeType('image', 'x-icon'), false),
  '.json': (MimeType.json, false),
  '.woff2': (MimeType('font', 'woff2'), false),
  '.mjs': (MimeType('text', 'javascript'), true),
  '.map': (MimeType.json, false),
  '.webmanifest': (MimeType('application', 'manifest+json'), false),
  '.wasm': (MimeType('application', 'wasm'), false),
  '.otf': (MimeType('font', 'otf'), false),
  '.ttf': (MimeType('font', 'ttf'), false),
  '.woff': (MimeType('font', 'woff'), false),
  '.bin': (MimeType.octetStream, false),
  '.frag': (MimeType.octetStream, false),
  '.shaderbundle': (MimeType.octetStream, false),
  '.fsceneb': (MimeType.octetStream, false),
  '.gif': (MimeType('image', 'gif'), false),
  '.webp': (MimeType('image', 'webp'), false),
  '.wav': (MimeType('audio', 'wav'), false),
  '.mp3': (MimeType('audio', 'mpeg'), false),
  '.ogg': (MimeType('audio', 'ogg'), false),
};

/// Someone in the office: where they stand and what they look like. [PeerInfo] is the wire type,
/// made fresh from this whenever it's sent.
class _Peer {
  _Peer({
    required this.id,
    required this.name,
    required this.color,
    required this.look,
    required this.x,
    required this.z,
    this.account,
    this.floor,
  });

  final String id;
  String name;
  String color;
  Look look;
  double x;
  double y = 0;
  double z;
  double rotY = 0;
  bool moving = false;
  bool voice = false;
  bool muted = true;
  bool sharing = false;
  bool? smoking;
  bool? golfing;
  String? seat;
  CarriedIssue? carrying;
  DrinkId? drink;
  final bool? account;
  String? floor;
  String? doing;
  bool? reading;

  PeerInfo get info => PeerInfo(
    id: id,
    name: name,
    color: color,
    look: look,
    x: x,
    y: y,
    z: z,
    rotY: rotY,
    moving: moving,
    voice: voice,
    muted: muted,
    sharing: sharing,
    smoking: smoking,
    golfing: golfing,
    seat: seat,
    carrying: carrying,
    drink: drink,
    account: account,
    floor: floor,
    doing: doing,
    reading: reading,
  );
}

class _Client {
  _Client(this.id, this.ws, this.peer, {this.accountId, required this.admin});

  final String id;
  final RelicWebSocket ws;
  final _Peer peer;

  /// Signed in with this account; none means the shared office password.
  final String? accountId;

  /// Whether this person was last told they're an admin (see `me`).
  bool admin;

  /// Signed out while connected; whatever it still sends is dropped until the socket closes.
  bool out = false;
  final Set<String> attached = {};

  /// Terminals whose output was skipped because this client fell behind; re-snapshotted later.
  final Set<String> stale = {};
  int lastActAt = 0;
  int lastGongAt = 0;

  /// When they last hit a golf ball off the balcony.
  int lastGolfAt = 0;

  /// When they last blew the DJ's air horn on the roof.
  int lastHornAt = 0;

  /// A little more lenient than the page's own, so emotes it let through aren't dropped for arriving bunched up.
  final EmoteBucket emotes = EmoteBucket(emoteEvery * 0.8);

  /// Has the floor's whiteboard open.
  bool whiteboard = false;
  int lastWbPointerAt = 0;

  /// At the arcade cabinet on their floor, playing [game] (see Arcade); [frame] is it as it looks now.
  bool playing = false;
  String? game;
  CabinetFrame? frame;
  int lastFrameAt = 0;

  bool get open => !ws.isClosed;
}

const _slowClientBytes = 8 * 1024 * 1024;

/// The most a client may send in one message (the Node server's `maxPayload`).
const _maxPayload = 2 * 1024 * 1024;

/// How much a client's socket has queued and not yet sent. dart:io's WebSocket doesn't say, so
/// this is always 0: nobody is ever skipped as slow, and a slow client's socket buffers instead.
/// Kept as the one place the Node server's `bufferedAmount` checks go through.
int _buffered(_Client c) => 0;

/// A path under the home folder as ~/…, for showing people.
String _tildify(String path) {
  final home = Platform.environment['HOME'] ?? '';
  if (home.isEmpty) return path;
  return path == home || path.startsWith('$home${p.separator}') ? '~${path.substring(home.length)}' : path;
}

String _clientIp(Request req, bool trustProxy) {
  if (trustProxy) {
    final fwd = headerValue(req.headers, 'x-forwarded-for');
    // The rightmost hop is the one our proxy appended; anything left of it is client-controlled.
    if (fwd != null && fwd.isNotEmpty) return fwd.split(',').last.trim();
  }
  final remote = req.connectionInfo.remote;
  return remote.port == 0 ? '?' : remote.address.toString();
}

bool _isSecure(Request req, Config cfg) {
  if (cfg.tls != null) return true;
  return cfg.trustProxy && headerValue(req.headers, 'x-forwarded-proto') == 'https';
}

/// A URL's host as the browser's `URL.host` has it: with the port unless it's the default one.
String? _urlHost(String raw) {
  try {
    final u = Uri.parse(raw);
    if (!u.hasScheme || !u.hasAuthority) return null;
    final host = u.host.contains(':') ? '[${u.host}]' : u.host;
    return u.hasPort ? '$host:${u.port}' : host;
  } catch (_) {
    return null;
  }
}

/// Whether the page asking is the office itself, so another site can't open a socket with a visitor's cookie.
bool _sameOrigin(Request req, Config cfg) {
  final origin = headerValue(req.headers, 'origin');
  final forwarded = cfg.trustProxy ? headerValue(req.headers, 'x-forwarded-host') : null;
  final host = forwarded != null && forwarded.isNotEmpty ? forwarded : headerValue(req.headers, 'host');
  if (origin == null || origin.isEmpty) return false;
  return _urlHost(origin) == host;
}

bool _isUpgrade(Request req) => req.headers['upgrade']?.any((v) => v.toLowerCase().contains('websocket')) ?? false;

Response _refuseUpgrade() =>
    Response(401, headers: Headers.build((h) => h['connection'] = ['close']), body: Body.empty());

/// JSON as the Node server wrote it: whole numbers without a trailing `.0` (JavaScript has one
/// number type), so the office's messages read the same whichever server sent them.
Object? _jsNumbers(Object? v) {
  if (v is double) return v.isFinite && v == v.truncateToDouble() && v.abs() < 1e21 ? v.toInt() : v;
  if (v is Map) return {for (final e in v.entries) '${e.key}': _jsNumbers(e.value)};
  if (v is List) return [for (final x in v) _jsNumbers(x)];
  return v;
}

String _json(Object? v) => jsonEncode(_jsNumbers(v));

Response _send(int status, Object? body, [Map<String, String> headers = const {}]) => Response(
  status,
  headers: Headers.build((h) {
    h['cache-control'] = ['no-store'];
    headers.forEach((k, v) => h[k] = [v]);
  }),
  body: Body.fromString(_json(body), mimeType: MimeType.json),
);

Response _notFoundText() => Response(404, body: Body.fromString('Not found', mimeType: MimeType.plainText));

/// A string field, cut to [max]; anything else is ''.
String _str(Object? v, int max) => v is String ? (v.length > max ? v.substring(0, max) : v) : '';

/// A finite number, else 0.
double _num(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;

/// JavaScript's truthiness, for fields the Node server read with `!!`.
bool _truthy(Object? v) => v != null && v != false && v != '' && !(v is num && (v == 0 || v.isNaN));

bool _isSafeInteger(double n) => n == n.truncateToDouble() && n.abs() <= 9007199254740991;

/// A spot someone stands on, facing `rotY`.
typedef _Spot = ({double x, double y, double z, double rotY});

/// Where someone going to another floor says they arrive (see `floor.go`): on the grounds, or nowhere (the elevator).
_Spot? _arrivalSpot(Object? at) {
  if (at is! Map) return null;
  double clamp(Object? v, double lo, double hi) => _num(v).clamp(lo, hi).toDouble();
  // Down on the street from a floor high up, the street is a long way down.
  return (
    x: clamp(at['x'], -60, 60),
    y: clamp(at['y'], streetBelow(maxFloors - 1), 10),
    z: clamp(at['z'], -60, 60),
    rotY: _num(at['rotY']),
  );
}

/// A GitHub issue number, else null.
int? _issueNumber(Object? v) => v is num && v.isFinite && v == v.truncate() && v > 0 ? v.toInt() : null;

final _colorRe = RegExp(r'^#[0-9a-fA-F]{6}$');
bool _isColor(Object? v) => v is String && _colorRe.hasMatch(v);

const _tooManyAttempts = 'Too many attempts. Try again in a few minutes.';

/// WebSocket close code for a session that stopped counting: the account was revoked, or the shared password switched off.
const _signedOut = 4001;

/// The most chat lines, and lines per worker's terminal, a search answers with.
const _searchChatHits = 50;
const _searchTerminalHits = 25;

final _random = Random.secure();
String _randomHex(int bytes) =>
    [for (var i = 0; i < bytes; i++) _random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
int _now() => DateTime.now().millisecondsSinceEpoch;

/// The first value of a query parameter, like `URLSearchParams.get`.
String? _query(Uri url, String key) {
  try {
    final all = url.queryParametersAll[key];
    return all == null || all.isEmpty ? null : all.first;
  } catch (_) {
    return null;
  }
}

/// Where the office's executable is, for its version: under `dart run` that's the checkout's
/// server/bin (so the version is the checkout's commit, as the Node server had it), not the SDK's.
String? officeExeDir() {
  final name = p.basenameWithoutExtension(Platform.resolvedExecutable).toLowerCase();
  if (name != 'dart' && name != 'dartvm') return null;
  try {
    return p.dirname(p.fromUri(Platform.script));
  } catch (_) {
    return null;
  }
}

/// A running office: its HTTP server, the floors and everyone in them.
class Office {
  Office._(
    this._server,
    this._shutdown,
    this.accounts,
    this.publicDir,
    this.hookPort,
    this._floors,
    this.resolvedAgent,
  );

  final RelicServer _server;
  final Future<void> Function(bool keep) _shutdown;
  final Accounts accounts;
  final String publicDir;
  final int hookPort;
  final Map<String, Floor> _floors;

  /// The configured agent's full path, or null when only the login shell can find it.
  final String? resolvedAgent;

  /// The port the office listens on.
  int get port => _server.port;

  List<Floor> floors() => [..._floors.values];

  /// With [keep] (a restart), workers' terminals keep running for the next office to pick up.
  Future<void> shutdown({bool keep = false}) => _shutdown(keep);
}

/// Opens the office: the building's floors, the hook endpoint the workers report to, and the web
/// server with the WebSocket everyone in the office talks over. [restart] is what an upgrade calls
/// once the new version is in place (the CLI shuts down gracefully and exits for systemd to start
/// the new one); by default the office just shuts down keeping the workers' terminals. [publicDir] is
/// where the client's files are, when not the usual places (see findPublicDir).
Future<Office> startServer(Config cfg, {String? publicDir, void Function()? restart}) async {
  final String clientDir = publicDir ?? findPublicDir(p.dirname(p.fromUri(Platform.script)));
  final accounts = Accounts(cfg.dataDir);
  final auth = Auth(cfg.verifier, cfg.salt, cfg.secret, accounts);
  final clients = <String, _Client>{};
  // Kept on disk, so a restart doesn't wipe it.
  final chat = ChatLog(cfg.dataDir);

  /// What the office is called where it has no project of its own to go by (webhooks, invites).
  final officeName = cfg.project != null ? p.basename(cfg.project!) : 'the office';
  final modelCommand = configuredProvider(cfg.agentCmd) == AgentProvider.opencode ? cfg.agentCmd : 'opencode';
  final openCodeModels = createOpenCodeModelCatalogue(
    modelCommand.contains('/') ? p.absolute(modelCommand) : modelCommand,
    cfg.dir,
  );

  void sendRaw(_Client c, String json) {
    if (!c.open) return;
    try {
      c.ws.trySendText(json);
    } catch (_) {
      // closing already
    }
  }

  void sendTo(_Client c, ServerMsg msg) {
    if (c.open) sendRaw(c, _json(msg.toJson()));
  }

  void broadcast(ServerMsg msg, {String? except, bool droppable = false}) {
    final json = _json(msg.toJson());
    for (final c in List.of(clients.values)) {
      if (c.id == except || !c.open) continue;
      if (droppable && _buffered(c) > 4 * 1024 * 1024) continue;
      sendRaw(c, json);
    }
  }

  void toastAll(String text, [ToastLevel level = ToastLevel.info]) => broadcast(ToastMsg(text, level));

  // --- The building: a floor per project, each with its own workers, boards and queue -----------
  final building = Building(cfg.dataDir, cfg.projectsDir);
  final floors = <String, Floor>{};
  Floor? floorOf(_Client c) => c.peer.floor != null ? floors[c.peer.floor] : null;

  /// The floor a worker sits on. Worker ids are unique across the building.
  Floor? workerFloor(String workerId) {
    for (final f in floors.values) {
      if (f.workers.get(workerId) != null) return f;
    }
    return null;
  }

  /// To everyone on one floor.
  void toFloor(Floor floor, ServerMsg msg, [bool droppable = false]) {
    final json = _json(msg.toJson());
    for (final c in List.of(clients.values)) {
      if (c.peer.floor != floor.id || !c.open) continue;
      if (droppable && _buffered(c) > 4 * 1024 * 1024) continue;
      sendRaw(c, json);
    }
  }

  void toastFloor(Floor? floor, String text, [ToastLevel? level]) {
    if (floor != null) toFloor(floor, ToastMsg(text, level ?? ToastLevel.info));
  }

  // The arcade's high scores: one table for the whole building, on every floor's cabinet. The office
  // follows every game and puts the scores up itself (see Arcade).
  final highScores = HighScores(cfg.dataDir);
  late final void Function(Floor? floor) cabinetChanged;
  final arcade = Arcade(highScores, (first) {
    for (final f in floors.values) {
      cabinetChanged(f);
    }
    if (first != null) {
      toastFloor(
        floors[first.floor],
        '🏆 ${first.score.name} set a new arcade high score: ${scoreText(first.score.score)}',
      );
    }
  });

  List<FloorInfo> floorInfos() => [
    for (final f in floors.values) f.info(),
    for (final d in building.pending())
      FloorInfo(
        id: d.id,
        name: d.name,
        repo: d.repo,
        dir: d.dir,
        palette: d.palette,
        addedBy: d.addedBy,
        addedAt: d.addedAt,
        cloning: true,
        workers: 0,
        busy: 0,
        waiting: 0,
        people: 0,
      ),
  ];
  // The elevator's counts change with every worker update; tell everyone at most a few times a second.
  var floorsSent = '';
  Timer? floorsTimer;
  void floorsChanged() {
    floorsTimer ??= Timer(const Duration(milliseconds: 250), () {
      floorsTimer = null;
      final list = floorInfos();
      final json = _json([for (final f in list) f.toJson()]);
      if (json == floorsSent) return;
      floorsSent = json;
      broadcast(FloorsMsg(list));
    });
  }

  /// Tells just this person why their request didn't happen; nothing when there's no error.
  void warn(_Client c, String? error) {
    if (error != null && error.isNotEmpty) sendTo(c, ToastMsg(error, ToastLevel.warn));
  }

  // --- Loopback-only endpoint for authenticated agent events -------------------------------
  Future<Response> hookHandler(Request req) async {
    final url = req.url;
    const paths = ['/hooks/claude', '/hooks/opencode', '/hooks/codex'];
    if (req.method != Method.post || !paths.contains(url.path)) return _send(404, {'ok': false});
    Object? payload = <String, dynamic>{};
    try {
      final body = await req.readAsString(encoding: utf8, maxLength: 1024 * 1024);
      payload = body.isNotEmpty ? jsonDecode(body) : <String, dynamic>{};
    } catch (_) {
      if (url.path != '/hooks/claude') return _send(400, {'ok': false});
      // permissive: a bad payload still counts as the event
    }
    final token = (headerValue(req.headers, 'authorization') ?? '').replaceFirst(
      RegExp(r'^Bearer\s+', caseSensitive: false),
      '',
    );
    final workerId = _query(url, 'worker') ?? '';
    final workers = workerFloor(workerId)?.workers;
    if (workers == null) return _send(401, {});
    final event = _query(url, 'event') ?? '';
    final ok = switch (url.path) {
      '/hooks/opencode' => workers.handleOpenCodeHook(workerId, token, payload),
      '/hooks/codex' => workers.handleCodexHook(workerId, token, event, payload),
      _ => workers.handleHook(workerId, token, event, payload),
    };
    return _send(ok ? 200 : 401, {});
  }

  // Workers' terminals outlive a restart of the office (see ptys.dart) with this address in their
  // environment, so listen where the last office did when that port is free.
  final hookPortPath = p.join(cfg.dataDir, 'hook-port');
  var lastHookPort = 0;
  try {
    lastHookPort = int.tryParse(File(hookPortPath).readAsStringSync().trim()) ?? 0;
  } catch (_) {
    // first start
  }
  IOAdapter hookAdapter;
  try {
    hookAdapter = await IOAdapter.bind(InternetAddress.loopbackIPv4, port: lastHookPort);
  } on SocketException {
    hookAdapter = await IOAdapter.bind(InternetAddress.loopbackIPv4, port: 0);
  }
  final hookServer = RelicServer(() => hookAdapter);
  await hookServer.mountAndStart((req) async {
    try {
      return await hookHandler(req);
    } catch (_) {
      return _send(500, {});
    }
  });
  final hookPort = hookServer.port;
  writePrivateFile(hookPortPath, '$hookPort');

  // Day, night and the weather outside the windows, the same for everyone.
  final sky = Sky(city: cfg.city, weather: cfg.weather, onChange: (state) => broadcast(SkyMsg(state)))..start();
  // Halloween or Christmas all over the building, the same for everyone (⚙️ Settings). On 'auto' it
  // goes by the calendar at the office, the sky's clock.
  final themes = Themes(cfg.dataDir, () => sky.state.utcOffset, (state) => broadcast(ThemeMsg(state)))..start();

  // What the workers spend, all time and today, with the optional daily budget.
  final ledger = Ledger(
    cfg.dataDir,
    LedgerOptions(budget: cfg.budget, pauseHiring: cfg.budgetPause),
    (state) => broadcast(UsageMsg(state)),
    (text, level) => toastAll(text, ToastLevel.parse(level)),
  );

  // The Claude plan's 5-hour and weekly limits, for the meter under the workers: one account for
  // every floor.
  final limits = PlanLimitsReader(
    configuredProvider(cfg.agentCmd) == AgentProvider.claude ? resolveCommand(cfg.agentCmd) : resolveCommand('claude'),
    childEnv(),
    () => clients.isNotEmpty,
    (state) => broadcast(LimitsMsg(state)),
  );

  // Slack / Discord pings for workers that need input or finish (set from ⚙️ Settings or --webhook).
  final webhook = Webhook(cfg.dataDir, ([workerId]) {
    final name = workerId != null && workerId.isNotEmpty ? workerFloor(workerId)?.def.name : null;
    return name != null && name.isNotEmpty ? name : officeName;
  }, (state) => broadcast(NotifyMsg(state)));
  if (cfg.webhook != null) {
    final err = webhook.set(cfg.webhook!, 'the command line');
    if (err != null) stderr.writeln('agent-office: --webhook: $err');
  }

  final floorContext = _FloorContext(
    agentCmd: cfg.agentCmd,
    agentArgs: cfg.agentArgs,
    hook: HookEnv(url: 'http://127.0.0.1:$hookPort', token: ''),
    ledger: ledger,
    onEmit: toFloor,
    onToast: toastFloor,
    onTermData: (workerId, data, viewers) {
      final json = _json(TermDataMsg(workerId, data).toJson());
      for (final id in viewers) {
        final c = clients[id];
        if (c == null || !c.open) continue;
        // A viewer on a slow link skips output and gets a fresh snapshot once it catches up,
        // instead of queueing unbounded data in server memory.
        if (c.stale.contains(workerId) || _buffered(c) > _slowClientBytes) {
          c.stale.add(workerId);
        } else {
          sendRaw(c, json);
        }
      }
    },
    onChanges: (state, ids) {
      for (final id in ids) {
        final c = clients[id];
        if (c != null) sendTo(c, ChangesMsg(state));
      }
    },
    onWorkerChanged: (floor, workerId, w) {
      if (w == null) {
        webhook.onWorkerGone(workerId);
      } else {
        webhook.onWorker(w);
      }
      floorsChanged();
    },
    onPeople: (floor) => clients.values.where((c) => c.peer.floor == floor.id).length,
    onPeers: (floor) => [
      for (final c in clients.values)
        if (c.peer.floor == floor.id) c.peer.info,
    ],
  );

  Floor? openFloor(FloorDef def) {
    if (!Directory(def.dir).existsSync()) {
      stderr.writeln(
        "agent-office: the ${def.name} floor's checkout is gone (${def.dir}) — it stays closed until it's back",
      );
      return null;
    }
    try {
      final floor = Floor(def, floorContext);
      floors[def.id] = floor;
      return floor;
    } catch (err) {
      stderr.writeln("agent-office: couldn't open the ${def.name} floor: ${_message(err)}");
      return null;
    }
  }

  // Started in a project: it's a floor too (the one it has always been).
  if (cfg.project != null) building.ensureLocal(cfg.project!, 'the office');
  for (final def in List.of(building.list())) {
    openFloor(def);
  }
  // Workers still running from the last office are back at their desks before anyone walks in.
  await Future.wait([for (final f in floors.values) f.ready]);

  final team = Team(cfg.publicHost, cfg.port);

  // Web servers the workers start, for the Services board and service tunnels (see relay.dart).
  // One scan covers every floor; each floor's board lists its own workers' servers.
  late final Services services;
  ServicesState servicesState(Floor? floor, [List<ServiceInfo>? items]) => ServicesState(
    items: floor == null
        ? const []
        : (items ?? services.list()).where((s) => floor.workers.get(s.workerId) != null).toList(),
    port: cfg.port,
    ssh: team.ssh,
  );
  services = Services(() => [for (final f in floors.values) ...f.workers.owners()], (items) {
    for (final c in List.of(clients.values)) {
      sendTo(c, ServicesMsg(servicesState(floorOf(c), items)));
    }
  });

  /// Who has a floor's whiteboard open.
  List<String> drawing(Floor floor) => [
    for (final c in clients.values)
      if (c.whiteboard && c.peer.floor == floor.id) c.id,
  ];
  void drawingChanged(Floor? floor) {
    if (floor != null) toFloor(floor, WbPeopleMsg(drawing(floor)));
  }

  /// Who's playing the arcade cabinet on a floor.
  _Client? cabinetPlayer(Floor floor) => clients.values.where((c) => c.playing && c.peer.floor == floor.id).firstOrNull;
  CabinetState cabinetState(Floor? floor) {
    final pl = floor != null ? cabinetPlayer(floor) : null;
    return CabinetState(
      player: pl != null ? CabinetPlayer(id: pl.id, name: pl.peer.name, game: pl.game ?? '') : null,
      scores: highScores.top(),
    );
  }

  cabinetChanged = (floor) {
    if (floor != null) toFloor(floor, CabinetMsg(cabinetState(floor)));
  };

  /// `c` stepped away from the cabinet (or left the floor, or the office): their game waits, with its score so far on the table.
  void stopPlaying(_Client c, [Floor? floor]) {
    if (!c.playing) return;
    floor ??= floorOf(c);
    if (floor != null) arcade.leave(c.game, floor.id);
    c
      ..playing = false
      ..game = null
      ..frame = null;
    cabinetChanged(floor);
  }

  /// Everything on a floor, for whoever just arrived there.
  FloorView floorView(Floor? floor, [String? id]) => FloorView(
    floor: id ?? floor?.id,
    project: floor?.project,
    workers: floor?.workers.list() ?? const [],
    issues: floor?.github.issues ?? const GhState(items: [], fetchedAt: 0, loading: false),
    pulls: floor?.github.pulls ?? const GhState(items: [], fetchedAt: 0, loading: false),
    queue: floor?.queue.state() ?? const QueueState(tasks: [], maxWorkers: 0),
    decor: floor?.decor.list() ?? const [],
    services: servicesState(floor),
    dog: floor?.dog.view(),
    jukebox:
        floor?.jukebox.state() ??
        JukeboxState(on: false, track: jukeboxTunes.first.id, startedAt: _now().toDouble(), elapsed: 0),
    cabinet: () {
      final s = cabinetState(floor);
      return CabinetView(player: s.player, scores: s.scores, frame: floor != null ? cabinetPlayer(floor)?.frame : null);
    }(),
    whiteboard: WhiteboardView(
      elements: floor?.whiteboard.scene() ?? const [],
      people: floor != null ? drawing(floor) : const [],
    ),
  );

  /// The rooftop bar: nobody works up there, so it has none of a floor's things.
  FloorView roofView() => floorView(null, roof);
  void screensOf(_Client c, Floor? floor) {
    for (final (:workerId, :frame)
        in floor?.workers.fullScreens() ?? const <({String workerId, ScreenFrame frame})>[]) {
      sendTo(
        c,
        ScreenMsg(
          workerId: workerId,
          cols: frame.cols,
          rows: frame.rows,
          lines: frame.lines,
          full: true,
          cursor: frame.cursor,
        ),
      );
    }
  }

  /// Where someone arriving goes: the floor they asked for, else the first one there is.
  Floor? arrivalFloor(String? wanted) =>
      (wanted != null && wanted.isNotEmpty ? floors[wanted] : null) ?? (floors.isEmpty ? null : floors.values.first);

  final images = ImageProxy();

  late final Future<void> Function(bool keep) shutdown;
  final upgrader = Upgrader(
    (state) => broadcast(UpgradeMsg(state)),
    // The CLI shuts down gracefully; systemd (Restart=always) then starts the new version, which
    // wakes every worker.
    restart ?? () => unawaited(shutdown(true)),
    exeDir: officeExeDir(),
  );

  // --- HTTP ------------------------------------------------------------------------------------
  Response serveFile(String file, String cache) {
    final type = _mime[p.extension(file)];
    final f = File(file);
    return Response(
      200,
      headers: Headers.build((h) {
        h['cache-control'] = [cache];
        h['x-content-type-options'] = ['nosniff'];
        h['x-frame-options'] = ['DENY'];
        h['referrer-policy'] = ['no-referrer'];
      }),
      body: Body.fromDataStream(
        f.openRead().map((c) => c is Uint8List ? c : Uint8List.fromList(c)),
        mimeType: type?.$1 ?? MimeType.octetStream,
        encoding: type != null && type.$2 ? utf8 : null,
        contentLength: f.lengthSync(),
      ),
    );
  }

  /// A password, claim-token or invite guess: counts it against the IP, then reads the small JSON
  /// body. Either the guess, or the answer already given (rate limited, or a bad body).
  Future<({String ip, Map<String, dynamic> body})?> readGuess(Request req, void Function(Response) answer) async {
    final ip = _clientIp(req, cfg.trustProxy);
    // Counted before the body is read, so parallel guesses can't all slip under the limit.
    if (!auth.allowAttempt(ip)) {
      answer(_send(429, {'error': _tooManyAttempts}));
      return null;
    }
    try {
      final body = jsonDecode(await req.readAsString(encoding: utf8, maxLength: 4096));
      if (body is Map) return (ip: ip, body: Map<String, dynamic>.from(body));
    } catch (_) {
      // answered below
    }
    answer(_send(400, {'error': 'Bad request'}));
    return null;
  }

  Map<String, String> signedIn(Request req, [String? accountId]) => {
    'set-cookie': auth.cookie(req.headers, auth.issue(accountId), _isSecure(req, cfg)),
  };

  /// With a name, that person's own account; without one, the shared office password (while it's on).
  Future<Response> login(Request req) async {
    Response? answered;
    final guess = await readGuess(req, (r) => answered = r);
    if (guess == null) return answered!;
    final name = _str(guess.body['name'], 64).trim();
    final password = _str(guess.body['password'], 512);
    if (name.isNotEmpty) {
      final account = await accounts.check(name, password);
      if (account == null) return _send(401, {'error': 'Wrong name or password'});
      auth.recordSuccess(guess.ip);
      return _send(200, {'ok': true}, signedIn(req, account.id));
    }
    if (!accounts.sharedPassword) return _send(401, {'error': 'Sign in with your name and your own password'});
    if (!await auth.checkPassword(password)) {
      return _send(401, {
        'error': accounts.any ? 'Wrong password. With an account of your own, type your name too.' : 'Wrong password',
      });
    }
    auth.recordSuccess(guess.ip);
    return _send(200, {'ok': true}, signedIn(req));
  }

  /// Which fields the sign-in forms ask for.
  Map<String, dynamic> loginOptions() => {'accounts': accounts.any, 'shared': accounts.sharedPassword};

  // Set once the WebSocket side below is defined; the invite route needs it.
  late final void Function() accountsChanged;

  /// An invite link: `peek` says who it's for; otherwise it makes the account and signs it in.
  /// Counted like a password guess, since the token is one.
  Future<Response> join(Request req) async {
    Response? answered;
    final guess = await readGuess(req, (r) => answered = r);
    if (guess == null) return answered!;
    final token = _str(guess.body['token'], 128);
    final invite = accounts.findInvite(token);
    if (invite == null) {
      return _send(410, {
        'error': 'This invite link has expired or was already used. Ask whoever sent it for a new one.',
      });
    }
    auth.recordSuccess(guess.ip);
    if (guess.body['peek'] == true) {
      return _send(200, {'name': invite.name, 'role': invite.role.wire, 'by': invite.createdBy, 'project': officeName});
    }
    final r = await accounts.join(token, _str(guess.body['name'], 64), _str(guess.body['password'], 1024));
    if (r is String) return _send(400, {'error': r});
    final a = r as Account;
    stdout.writeln('  ${a.name} joined the office with an invite from ${a.createdBy}');
    accountsChanged();
    return _send(200, {'ok': true, 'name': a.name}, signedIn(req, a.id));
  }

  /// The 🔎 search: chat lines, and lines of the terminals of every worker on that floor, with the words in them.
  SearchResults search(String q, Floor? floor) {
    if (q.length > searchMax) q = q.substring(0, searchMax);
    final needle = searchKey(q);
    if (needle.length < searchMin) return SearchResults(q: q, chat: const [], terminals: const [], more: false);
    final said = chat.search(needle, _searchChatHits);
    final shown = floor?.workers.search(needle, _searchTerminalHits) ?? (hits: const <TerminalHit>[], more: false);
    return SearchResults(q: q, chat: said.hits, terminals: shown.hits, more: said.more || shown.more);
  }

  /// Who a connection is: its account's current name and role, or an admin guest on the shared password.
  Me meOf(String? accountId) {
    final a = accounts.get(accountId);
    return a != null
        ? Me(
            account: MeAccount(name: a.name, role: a.role),
            admin: a.role == AccountRole.admin,
          )
        : Me(admin: accountId == null);
  }

  // The WebSocket route hands connections to this, defined further down with the protocol.
  late final void Function(RelicWebSocket ws, Uri url, Session session) onConnectionRef;

  Future<Result> handler(Request req) async {
    // A service tunnel (localhost:5173 -> the office): relay to that worker's server.
    final tunneled = tunneledPort(req.headers, cfg.port);
    final svc = tunneled != null ? services.lookup(tunneled) : null;
    if (tunneled != null && svc != null) {
      if (_isUpgrade(req)) {
        if (svc is ServiceLookupFound && auth.fromAnyCookie(req.headers)) return relayUpgrade(req, svc.info);
        return _refuseUpgrade();
      }
      if (req.method == Method.post && req.url.path == relayLogin && !req.url.hasQuery) return await login(req);
      if (!auth.fromAnyCookie(req.headers)) {
        return signInPage(tunneled, accounts: accounts.any, shared: accounts.sharedPassword);
      }
      if (svc is ServiceLookupFound) return relayRequest(req, svc.info);
      return stoppedPage(tunneled);
    }
    Uri url;
    String path;
    try {
      url = req.url.normalizePath();
      path = Uri.decodeComponent(url.path.isEmpty ? '/' : url.path);
    } catch (_) {
      return _send(400, {'error': 'Bad request'});
    }

    // --- WebSocket -------------------------------------------------------------------------------
    if (_isUpgrade(req)) {
      final session = url.path == '/ws' && _sameOrigin(req, cfg) ? auth.fromRequest(req.headers) : null;
      if (session == null) return _refuseUpgrade();
      return WebSocketUpgrade((ws) => onConnectionRef(ws, url, session));
    }

    final method = req.method;
    if (path == '/api/login' && method == Method.post) return await login(req);
    if (path == '/api/login' && method == Method.get) return _send(200, loginOptions());
    if (path == '/api/join' && method == Method.post) return await join(req);
    // One-time reveal of the generated password. After this the plaintext is gone for good.
    final claimable = (cfg.claimToken ?? '').isNotEmpty && !cfg.claimed && (cfg.password ?? '').isNotEmpty;
    if (path == '/api/claim' && method == Method.get) return _send(200, {'claimable': claimable});
    if (path == '/api/claim' && method == Method.post) {
      Response? answered;
      final guess = await readGuess(req, (r) => answered = r);
      if (guess == null) return answered!;
      if (!claimable) {
        return _send(410, {'error': 'This office has already been claimed. Sign in with the password you saved.'});
      }
      if (!auth.checkToken(_str(guess.body['token'], 256), cfg.claimToken!)) {
        return _send(403, {'error': 'That claim link is not valid.'});
      }
      final password = cfg.password!;
      cfg.markClaimed();
      auth.recordSuccess(guess.ip);
      stdout.writeln('  the office password was claimed — it will not be shown again');
      return _send(200, {'password': password}, signedIn(req));
    }
    if (path == '/api/logout' && method == Method.post) {
      return _send(200, {'ok': true}, {'set-cookie': auth.clearCookie(req.headers)});
    }
    if (path == '/api/health') return _send(200, {'ok': true});

    // The client (the Flutter web app): its boot files and sign-in pages are public, the rest
    // needs a session (see static.dart). /api keeps its own auth below.
    if (path != '/api' && !path.startsWith('/api/')) {
      final answer = flutterStatic(clientDir, path, auth.fromRequest(req.headers) != null);
      return switch (answer) {
        StaticFile(:final file, :final cache) => serveFile(file, cache),
        StaticRedirect(:final location) => Response(302, headers: Headers.build((h) => h['location'] = [location])),
        StaticNotFound() => _notFoundText(),
      };
    }

    final session = auth.fromRequest(req.headers);
    if (session == null) return _send(401, {'error': 'Not logged in'});
    if (path == '/api/whoami') return _send(200, {'ok': true, 'me': meOf(session.account?.id).toJson()});
    if (path == '/api/agents/opencode/models' && method == Method.get) {
      try {
        return _send(200, {'models': await openCodeModels.get()});
      } catch (_) {
        return _send(502, {'error': 'Could not load OpenCode models'});
      }
    }
    if (path == '/api/image' && method == Method.get) {
      // A picture on the wall, fetched by the office so the 3D view can draw it (see decor.dart).
      final r = await images.get(_query(url, 'url') ?? '');
      switch (r) {
        case ImageError(:final status, :final error):
          return _send(status, {'error': error});
        case ImageData(:final type, :final body):
          MimeType mime;
          try {
            mime = MimeType.parse(type);
          } catch (_) {
            mime = MimeType.octetStream;
          }
          return Response(
            200,
            headers: Headers.build((h) {
              h['cache-control'] = ['private, max-age=3600'];
              h['x-content-type-options'] = ['nosniff'];
              // Opened on its own (an SVG, say), it still can't run anything on the office's origin.
              h['content-security-policy'] = ["default-src 'none'; style-src 'unsafe-inline'; sandbox"];
              h['cross-origin-resource-policy'] = ['same-origin'];
            }),
            body: Body.fromData(body, mimeType: mime),
          );
      }
    }
    // Which floor a request is about: its boards and its workers.
    final floor = floors[_query(url, 'floor') ?? ''];
    if (path == '/api/whiteboard/file') {
      // Pictures on the whiteboard. Their ids are hashes of what's in them, so they never change.
      if (floor == null) return _send(404, {'error': 'No such floor'});
      if (method == Method.get) {
        final f = floor.whiteboard.file(_query(url, 'id') ?? '');
        if (f == null) return _send(404, {'error': 'No such picture'});
        return _send(200, f.toJson(), {'cache-control': 'private, max-age=31536000, immutable'});
      }
      if (method != Method.post) return _send(405, {'error': 'Method not allowed'});
      if (!_sameOrigin(req, cfg)) return _send(403, {'error': 'Forbidden'});
      Object? body;
      try {
        body = jsonDecode(await req.readAsString(encoding: utf8, maxLength: wbMaxFileBytes + 4096));
      } on MaxBodySizeExceeded {
        return _send(413, {'error': 'That picture is too big for the whiteboard'});
      } catch (_) {
        return _send(400, {'error': 'Bad request'});
      }
      final error = floor.whiteboard.addFile(body);
      return error != null ? _send(400, {'error': error}) : _send(200, {'ok': true});
    }
    if (path == '/api/search' && method == Method.get) {
      return _send(200, search(_query(url, 'q') ?? '', floor).toJson());
    }
    if (path.startsWith('/api/gh/') && method == Method.get) {
      // What the issue and PR windows show beyond the board cards (see github.dart).
      final raw = _query(url, 'number');
      final n = raw == null ? null : num.tryParse(raw.trim().isEmpty ? '0' : raw.trim());
      if (n == null || !_isSafeInteger(n.toDouble()) || n <= 0) return _send(400, {'error': 'Bad number'});
      if (floor == null) return _send(404, {'error': 'No such floor'});
      final github = floor.github;
      try {
        if (path == '/api/gh/pull') return _send(200, (await github.pullDetail(n.toInt())).toJson());
        if (path == '/api/gh/issue') return _send(200, (await github.issueDetail(n.toInt())).toJson());
        if (path == '/api/gh/pull/diff') {
          final diff = await github.pullDiff(n.toInt());
          return Response(
            200,
            headers: Headers.build((h) {
              h['cache-control'] = ['no-store'];
              h['x-content-type-options'] = ['nosniff'];
            }),
            body: Body.fromString(diff, mimeType: MimeType.plainText),
          );
        }
      } catch (err) {
        return _send(502, {'error': _message(err)});
      }
      return _send(404, {'error': 'Not found'});
    }
    return _notFoundText();
  }

  SecurityContext? tls;
  if (cfg.tls != null) {
    tls = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(cfg.tls!.cert))
      ..usePrivateKeyBytes(utf8.encode(cfg.tls!.key));
  }

  /// Still signed in: the account wasn't revoked, and the shared password wasn't switched off.
  bool stillIn(_Client c) => c.accountId != null ? accounts.get(c.accountId) != null : accounts.sharedPassword;
  void signOut(_Client c) {
    c.out = true;
    unawaited(c.ws.tryClose(_signedOut, 'Signed out').catchError((_) => false));
  }

  Set<String> onlineAccounts() => {
    for (final c in clients.values)
      if (c.accountId != null) c.accountId!,
  };

  /// Tells each admin what the accounts are now, and everyone whether they're (still) an admin.
  accountsChanged = () {
    AccountsState? state;
    for (final c in List.of(clients.values)) {
      if (c.out) continue;
      if (!stillIn(c)) {
        signOut(c);
        continue;
      }
      final me = meOf(c.accountId);
      if (me.admin != c.admin) {
        c.admin = me.admin;
        sendTo(c, MeMsg(me));
      }
      if (me.admin) sendTo(c, AccountsMsg(state ??= accounts.state(onlineAccounts())));
    }
  };

  void decorChanged(Floor floor) => toFloor(floor, DecorMsg(floor.decor.list()));
  void jukeboxChanged(Floor floor) => toFloor(floor, JukeboxMsg(floor.jukebox.state()));
  Future<void> teamChanged() async => broadcast(TeamMsg(await team.state()));

  /// To everyone else on the same floor as `c`: nobody on another floor can see them.
  void toNeighbors(_Client c, ServerMsg msg, [bool droppable = false]) {
    if (c.peer.floor == null) return;
    final json = _json(msg.toJson());
    for (final o in List.of(clients.values)) {
      if (o.id == c.id || o.peer.floor != c.peer.floor || !o.open) continue;
      if (droppable && _buffered(o) > 4 * 1024 * 1024) continue;
      sendRaw(o, json);
    }
  }

  /// Off the floor (or the roof) `c` was on, to [at] on the next one, or into its elevator car.
  ({Floor? was, bool wasDrawing}) leave(_Client c, [_Spot? at]) {
    final was = floorOf(c);
    if (was != null) {
      was.workers.detachAll(c.id);
      was.changes.unwatchAll(c.id);
    }
    c.attached.clear();
    c.stale.clear();
    // The whiteboard downstairs stays downstairs, and so does the arcade.
    final wasDrawing = c.whiteboard;
    c.whiteboard = false;
    stopPlaying(c, was);
    final e = elevatorSpot();
    final spot = at ?? (x: e.x, y: 0.0, z: e.z, rotY: 0.0);
    c.peer
      ..x = spot.x
      ..y = spot.y
      ..z = spot.z
      ..rotY = spot.rotY
      ..moving = false
      ..seat = null
      ..golfing = null
      // An issue card belongs to the board it came off, which is on the floor they left; a drink stays at the bar.
      ..carrying = null
      ..drink = null;
    return (was: was, wasDrawing: wasDrawing);
  }

  void arrived(_Client c, ({Floor? was, bool wasDrawing}) left) {
    broadcast(PeerUpdateMsg(c.peer.info), except: c.id);
    if (left.wasDrawing) drawingChanged(left.was);
  }

  /// Takes `c` to another floor: everyone sees them leave and arrive, and they get the new floor's
  /// everything. They arrive in the elevator, or [at] the spot they came by.
  void goToFloor(_Client c, Floor floor, [_Spot? at]) {
    if (c.peer.floor == floor.id) return;
    final left = leave(c, at);
    c.peer.floor = floor.id;
    sendTo(c, FloorEnterMsg(peers: [for (final o in clients.values) o.peer.info], view: floorView(floor)));
    screensOf(c, floor);
    arrived(c, left);
    floor.arrived();
    floor.workers.wakeAll();
    floorsChanged();
  }

  /// Up to the rooftop bar, by elevator.
  void goToRoof(_Client c) {
    if (c.peer.floor == roof) return;
    final left = leave(c);
    c.peer.floor = roof;
    sendTo(c, FloorEnterMsg(peers: [for (final o in clients.values) o.peer.info], view: roofView()));
    arrived(c, left);
    floorsChanged();
  }

  /// Inviting, listing and revoking people. Admins only: an admin account, or the shared password.
  void handleAccounts(_Client c, String t, Map<String, dynamic> msg) {
    final who = c.peer.name;
    if (!meOf(c.accountId).admin) return warn(c, 'Only admins can manage accounts');
    switch (t) {
      case 'accounts.get':
        sendTo(c, AccountsMsg(accounts.state(onlineAccounts())));
      case 'accounts.invite':
        final r = accounts.invite(
          who,
          msg['role'] == 'admin' ? AccountRole.admin : AccountRole.member,
          msg['name'] is String ? msg['name'] as String : null,
        );
        if (r is String) return sendTo(c, AccountsInvitedMsg(error: r));
        sendTo(c, AccountsInvitedMsg(invite: r as AccountInvite));
        accountsChanged();
      case 'accounts.cancel':
        if (accounts.cancel(_str(msg['inviteId'], 32)) != null) accountsChanged();
      case 'accounts.revoke':
        final id = _str(msg['accountId'], 32);
        if (id == c.accountId) return warn(c, "You can't revoke your own account");
        final a = accounts.revoke(id);
        if (a == null) break;
        stdout.writeln("  $who revoked ${a.name}'s account");
        toastAll("$who revoked ${a.name}'s account");
        accountsChanged(); // signs them out everywhere
      case 'accounts.role':
        final id = _str(msg['accountId'], 32);
        if (id == c.accountId) return warn(c, "You can't change your own role");
        final a = accounts.setRole(id, msg['role'] == 'admin' ? AccountRole.admin : AccountRole.member);
        if (a == null) break;
        toastAll(a.role == AccountRole.admin ? '$who made ${a.name} an admin' : '${a.name} is no longer an admin');
        accountsChanged();
      case 'accounts.shared':
        final on = msg['on'];
        if (on == accounts.sharedPassword) break;
        // Only someone who can still get in without it may switch it off.
        if (!_truthy(on) && c.accountId == null) {
          return warn(c, 'Sign in with an admin account of your own first, or nobody could get back in');
        }
        accounts.setSharedPassword(_truthy(on));
        stdout.writeln('  $who switched the shared office password ${_truthy(on) ? 'on' : 'off'}');
        toastAll(
          _truthy(on)
              ? '$who switched the shared office password back on'
              : '🔑 $who switched off the shared office password — everyone signs in with their own account now',
        );
        accountsChanged(); // signs out whoever came in with it
    }
  }

  void handleMessage(_Client c, Map<String, dynamic> msg) {
    final who = c.peer.name;

    /// The floor `c` is on, or a note to them that they have to be on one.
    Floor? here() {
      final f = floorOf(c);
      if (f == null) warn(c, 'Take the elevator to a floor first');
      return f;
    }

    /// A worker by id, with the floor it sits on.
    ({String wid, Floor floor, WorkerInfo info})? worker(Object? id) {
      final wid = _str(id, 32);
      final floor = workerFloor(wid);
      return floor != null ? (wid: wid, floor: floor, info: floor.workers.get(wid)!) : null;
    }

    /// An agent provider the client named: absent, or one of this floor's.
    bool badProvider(Floor floor) {
      if (!msg.containsKey('provider')) return false;
      final provider = AgentProvider.tryParse(msg['provider']);
      return provider == null || !floor.project.agentProviders.contains(provider);
    }

    final t = msg['t'];
    switch (t) {
      case 'move':
        final pe = c.peer
          ..x = _num(msg['x'])
          ..y = _num(msg['y'])
          ..z = _num(msg['z'])
          ..rotY = _num(msg['rotY'])
          ..moving = _truthy(msg['moving']);
        toNeighbors(c, PeerMoveMsg(id: c.id, x: pe.x, y: pe.y, z: pe.z, rotY: pe.rotY, moving: pe.moving), true);
      case 'act':
        if (msg.containsKey('drink')) {
          // A drink from the rooftop bar, which stays up there.
          final drink = c.peer.floor == roof ? DrinkId.tryParse(msg['drink']) : null;
          if (drink == c.peer.drink) break;
          c.peer.drink = drink;
          broadcast(PeerActMsg(c.id, drink: drink, drinkSet: true), except: c.id, droppable: true);
          break;
        }
        final smoke = msg['smoke'];
        if (smoke is bool) {
          if (smoke == (c.peer.smoking ?? false)) break;
          c.peer.smoking = smoke;
          broadcast(PeerActMsg(c.id, smoke: smoke), except: c.id, droppable: true);
          break;
        }
        final golfing = msg['golf'];
        if (golfing is bool) {
          // The tee's on an office floor's balcony; there's none up on the roof.
          final golf = golfing && c.peer.floor != roof;
          if (golf == (c.peer.golfing ?? false)) break;
          c.peer.golfing = golf ? true : null;
          broadcast(PeerActMsg(c.id, golf: golf), except: c.id, droppable: true);
          break;
        }
        final now = _now();
        if (now - c.lastActAt < 100) break;
        c.lastActAt = now;
        toNeighbors(c, PeerActMsg(c.id), true);
      case 'golf':
        final now = _now();
        final (yaw, loft, power) = (_num(msg['yaw']), _num(msg['loft']), _num(msg['power']));
        if (c.peer.golfing != true ||
            now - c.lastGolfAt < 800 ||
            yaw.abs() > 2 ||
            loft < 0 ||
            loft > 1.6 ||
            power < 0 ||
            power > 1) {
          break;
        }
        c.lastGolfAt = now;
        toNeighbors(c, GolfMsg(id: c.id, yaw: yaw, loft: loft, power: power));
      case 'emote':
        final emote = Emote.tryParse(msg['emote']);
        if (emote != null && c.emotes.take(_now())) toNeighbors(c, PeerEmoteMsg(c.id, emote), true);
      case 'sit':
        // Everyone sees them sit down (or get up), and anyone who comes in later finds them sitting.
        // Only on a seat where they are: the roof's up on the roof, the office's on a floor.
        final key = _str(msg['seat'], 40);
        final seat = seatHere(key, c.peer.floor == roof) != null ? key : null;
        if (seat == c.peer.seat) break;
        c.peer.seat = seat;
        broadcast(PeerUpdateMsg(c.peer.info), except: c.id);
      case 'carry':
        // Everyone on the floor sees the issue card in their hands, and whoever comes in later too.
        final issue = _issueNumber(msg['issue']);
        if (issue == c.peer.carrying?.issue) break;
        c.peer.carrying = issue != null ? CarriedIssue(issue: issue, title: _str(msg['title'], 200)) : null;
        broadcast(PeerUpdateMsg(c.peer.info), except: c.id);
      case 'doing':
        final what = _str(msg['what'], 60).trim();
        final reading = msg['reading'] == true ? true : null;
        if ((what.isEmpty ? null : what) == c.peer.doing && reading == c.peer.reading) break;
        c.peer
          ..doing = what.isEmpty ? null : what
          ..reading = reading;
        broadcast(PeerUpdateMsg(c.peer.info));
      case 'profile':
        final name = _str(msg['name'], 24).trim();
        if (name.isNotEmpty && c.accountId == null) c.peer.name = name;
        if (_isColor(msg['color'])) c.peer.color = msg['color'] as String;
        c.peer.look = sanitizeLook(msg['look'], c.peer.look);
        broadcast(PeerUpdateMsg(c.peer.info));
      case 'voice':
        c.peer
          ..voice = _truthy(msg['voice'])
          ..muted = _truthy(msg['muted'])
          ..sharing = _truthy(msg['sharing']);
        broadcast(PeerUpdateMsg(c.peer.info));
      case 'rtc':
        final target = clients[_str(msg['to'], 32)];
        // Passed on as it came; without `data`, the Node server's JSON left it out too.
        if (target != null) {
          sendRaw(target, _json({'t': 'rtc', 'from': c.id, if (msg.containsKey('data')) 'data': msg['data']}));
        }
      case 'chat':
        final text = _str(msg['text'], 500).trim();
        if (text.isEmpty) break;
        final line = ChatLine(
          from: c.id,
          name: who,
          color: c.peer.color,
          text: text,
          at: _now(),
          account: c.accountId != null ? true : null,
        );
        chat.add(line);
        broadcast(ChatMsg(line));
      case 'floor.go':
        if (msg['floor'] == roof) {
          if (floors.isNotEmpty) {
            goToRoof(c);
          } else {
            warn(c, 'There is no building to go up on yet');
          }
          break;
        }
        final floor = floors[_str(msg['floor'], 64)];
        if (floor == null) {
          warn(
            c,
            building.pending().any((d) => d.id == msg['floor'])
                ? "That floor is still being cloned — it'll be ready in a moment"
                : 'No such floor',
          );
        } else {
          goToFloor(c, floor, _arrivalSpot(msg['at']));
        }
      case 'floor.repos':
        unawaited(
          building
              .repos(msg['refresh'] == true)
              .then(
                (repos) => sendTo(c, FloorReposMsg(repos)),
                onError: (Object err) => sendTo(
                  c,
                  FloorReposMsg(const [], error: "Couldn't list your repositories with gh: ${_message(err)}"),
                ),
              ),
        );
      case 'floor.add':
        final repo = _str(msg['repo'], 200);
        unawaited(
          building
              .add(repo, who, (def) {
                floorsChanged();
                toastAll('🛗 $who is adding a floor for ${def.repo ?? def.name}…');
              })
              .then((r) {
                floorsChanged();
                final def = r.floor;
                if (def == null) return sendTo(c, FloorAddedMsg(repo, error: r.error));
                final floor = openFloor(def);
                if (floor == null) {
                  return sendTo(
                    c,
                    FloorAddedMsg(
                      repo,
                      error: "Cloned ${def.repo}, but couldn't open its floor — see the office's log",
                    ),
                  );
                }
                stdout.writeln('  $who added a floor for ${def.repo} (${def.dir})');
                toastAll('🛗 New floor: ${def.name}, added by $who');
                sendTo(c, FloorAddedMsg(repo, floor: floor.id));
              }),
        );
      case 'dog.pet':
        floorOf(c)?.dog.pet(c.peer.info);
      case 'dog.name':
        final floor = here();
        if (floor == null) break;
        final name = floor.dog.rename(_str(msg['name'], 200));
        toastFloor(floor, '🐶 $who named the dog $name');
      case 'worker.spawn':
        final floor = here();
        if (floor == null) break;
        final kind = msg['kind'] == 'shell' ? WorkerKind.shell : WorkerKind.agent;
        if (kind == WorkerKind.agent && badProvider(floor)) {
          warn(c, 'Unknown agent provider');
          break;
        }
        // A shell given any provider at all is refused by spawn, in its own order of checks.
        final provider = !msg.containsKey('provider')
            ? null
            : AgentProvider.tryParse(msg['provider']) ?? AgentProvider.custom;
        final model = msg.containsKey('model') ? _str(msg['model'], openCodeModelMax + 1) : null;
        final prompt = _str(msg['prompt'], 20000);
        final r = floor.workers.spawn(
          _str(msg['deskId'], 32),
          who,
          prompt.isEmpty ? null : prompt,
          msg['worktree'] == true,
          kind,
          provider,
          model,
        );
        final w = r.worker;
        if (w == null) {
          warn(c, r.error);
        } else {
          toastFloor(
            floor,
            kind == WorkerKind.shell
                ? '$who opened a shell at a desk'
                : '$who hired ${w.name}${(w.prompt ?? '').isNotEmpty ? ' with a task' : ''}',
          );
        }
      case 'worker.resume':
        final w = worker(msg['workerId']);
        warn(c, w != null ? w.floor.workers.resume(w.wid) : 'No such worker');
      case 'worker.kill':
        final w = worker(msg['workerId']);
        if (w == null) break;
        final (:floor, :info, wid: _) = w;
        // The worker leaves right away; its worktree is dealt with after that, and the outcome follows.
        final cleanup = parseWireOrNull(WorktreeCleanup.values, msg['cleanup']);
        final done = floor.workers.kill(info.id, cleanup);
        toastFloor(floor, '$who sent ${info.name} home');
        unawaited(
          done.then((r) {
            if (r.note != null) toastFloor(floor, r.note!);
            if (r.error != null) toastFloor(floor, r.error!, ToastLevel.warn);
          }),
        );
      case 'worker.worktree':
        final w = worker(msg['workerId']);
        if (w == null) break;
        unawaited(
          w.floor.workers.inspectWorktree(w.wid).then((state) {
            if (state != null) sendTo(c, WorkerWorktreeMsg(w.wid, state));
          }),
        );
      case 'worker.attach':
        final w = worker(msg['workerId']);
        final snap = w?.floor.workers.attach(w.wid, c.id, who);
        if (w != null && snap != null) {
          c.attached.add(w.wid);
          sendTo(c, TermSnapshotMsg(workerId: w.wid, data: snap.data, cols: snap.cols, rows: snap.rows));
        }
      case 'worker.detach':
        final wid = _str(msg['workerId'], 32);
        c.attached.remove(wid);
        workerFloor(wid)?.workers.detach(wid, c.id);
      case 'worker.prompt':
        final w = worker(msg['workerId']);
        warn(c, w != null ? w.floor.workers.prompt(w.wid, _str(msg['prompt'], 20000), who) : 'No such worker');
      case 'worker.pr':
        final w = worker(msg['workerId']);
        if (w == null) break;
        final (:floor, :wid, info: _) = w;
        unawaited(
          floor.workers.openPr(wid, who).then((r) {
            final pr = r.pr;
            if (pr == null) return warn(c, r.error);
            final name = floor.workers.get(wid)?.name ?? 'the worker';
            toastFloor(
              floor,
              pr.existed ? "$name's branch already has PR #${pr.number}" : '$who opened PR #${pr.number} for $name',
            );
            if (pr.dirty) warn(c, '$name still has uncommitted changes in its worktree — they are not in the PR');
            // Put it on the board now rather than at the next poll. A refresh already in flight
            // returns at once and can miss it, so look again shortly after.
            unawaited(
              floor.github.refresh().then((_) {
                if (!floor.github.pulls.items.any((x) => x.number == pr.number)) {
                  Timer(const Duration(seconds: 3), () => unawaited(floor.github.refresh()));
                }
              }),
            );
          }),
        );
      case 'term.input':
        final wid = msg['workerId'];
        if (wid is String && c.attached.contains(wid)) {
          workerFloor(wid)?.workers.write(wid, _str(msg['data'], 64 * 1024), who);
        }
      case 'term.resize':
        final wid = msg['workerId'];
        if (wid is String && c.attached.contains(wid)) {
          workerFloor(wid)?.workers.resize(wid, _num(msg['cols']), _num(msg['rows']));
        }
      case 'gh.refresh':
        final f = floorOf(c);
        if (f != null) unawaited(f.github.refresh());
      case 'gh.merge':
        final floor = here();
        final n = _num(msg['number']);
        final method = parseWireOrNull(GhMergeMethod.values, msg['method']);
        if (floor == null || !_isSafeInteger(n) || n <= 0 || method == null) break;
        final number = n.toInt();
        final auto = msg['auto'] == true;
        unawaited(
          floor.github.merge(number, method, msg['deleteBranch'] == true, auto).then((error) {
            sendTo(c, GhMergedMsg(number, error: error));
            if (error != null) return;
            toastFloor(
              floor,
              auto ? '$who set PR #$number to merge once its checks pass' : '🎉 $who merged PR #$number',
            );
            // An auto-merge rings once GitHub gets round to it and the boards see it merged.
            if (!auto) floor.merged(number, who);
          }),
        );
      case 'gh.comment':
        final floor = here();
        final n = _num(msg['number']);
        final kind = msg['kind'] == 'pull' ? GhKind.pull : GhKind.issue;
        if (floor == null || !_isSafeInteger(n) || n <= 0) break;
        final number = n.toInt();
        final body = msg['body'] is String ? msg['body'] as String : '';
        // Refused rather than cut short: a comment that silently lost its end would read as finished.
        final invalid = body.trim().isEmpty
            ? 'The comment is empty'
            : body.length > ghCommentMax
            ? 'GitHub takes comments of up to $ghCommentMax characters'
            : '';
        if (invalid.isNotEmpty) {
          sendTo(c, GhCommentedMsg(kind: kind, number: number, error: invalid));
          break;
        }
        unawaited(
          floor.github.comment(kind, number, body).then((r) {
            sendTo(c, GhCommentedMsg(kind: kind, number: number, comment: r.comment, error: r.error));
            if (r.comment != null) {
              toastFloor(floor, '💬 $who commented on ${kind == GhKind.pull ? 'PR' : 'issue'} #$number');
            }
          }),
        );
      case 'gong':
        final floor = floorOf(c);
        final now = _now();
        if (floor == null || now - c.lastGongAt < 500) break;
        c.lastGongAt = now;
        toFloor(floor, GongMsg(GongWhy.hit, by: who));
      case 'horn':
        final now = _now();
        if (c.peer.floor != roof || now - c.lastHornAt < 1500) break;
        c.lastHornAt = now;
        for (final o in List.of(clients.values)) {
          if (o.peer.floor == roof) sendTo(o, HornMsg(who));
        }
      case 'gh.close':
        final floor = here();
        final n = _num(msg['number']);
        final kind = msg['kind'] == 'issue' || msg['kind'] == 'pull' ? GhKind.parse(msg['kind']) : null;
        if (floor == null || !_isSafeInteger(n) || n <= 0 || kind == null) break;
        final number = n.toInt();
        final reason = msg['reason'] == 'not planned' ? GhCloseReason.notPlanned : GhCloseReason.completed;
        final comment = _str(msg['comment'], 20000).trim();
        unawaited(
          floor.github
              .close(
                kind,
                number,
                comment: comment.isEmpty ? null : comment,
                reason: reason,
                deleteBranch: msg['deleteBranch'] == true,
              )
              .then((error) {
                sendTo(c, GhClosedMsg(kind: kind, number: number, error: error));
                if (error != null) return;
                if (kind == GhKind.pull) return toastFloor(floor, '$who closed PR #$number without merging');
                // Nobody should be seated for an issue that's closed.
                final dropped = floor.queue.dropIssue(number);
                toastFloor(
                  floor,
                  '$who closed issue #$number${reason == GhCloseReason.notPlanned ? ' as not planned' : ''}'
                  '${dropped ? ' and took it off the queue' : ''}',
                );
              }),
        );
      case 'queue.add':
        final floor = here();
        if (floor == null) break;
        if (badProvider(floor)) {
          warn(c, 'Unknown agent provider');
          break;
        }
        final raw = msg['issue'];
        final issue = raw is num && raw.isFinite && raw == raw.truncate() && raw > 0 ? raw.toInt() : null;
        final model = msg.containsKey('model') ? _str(msg['model'], openCodeModelMax + 1) : null;
        final err = floor.queue.add(
          _str(msg['prompt'], 20000),
          who,
          _str(msg['title'], 200),
          issue,
          AgentProvider.tryParse(msg['provider']),
          model,
        );
        if (err != null) {
          warn(c, err);
        } else {
          toastFloor(floor, '📋 $who queued ${issue != null ? 'issue #$issue' : 'a task'}');
        }
      case 'queue.remove':
        final floor = here();
        if (floor != null) warn(c, floor.queue.remove(_str(msg['taskId'], 32)));
      case 'queue.move':
        floorOf(c)?.queue.move(_str(msg['taskId'], 32), _num(msg['delta']) < 0 ? -1 : 1);
      case 'queue.retry':
        final floor = here();
        if (floor != null) warn(c, floor.queue.retry(_str(msg['taskId'], 32)));
      case 'queue.clear':
        floorOf(c)?.queue.clear();
      case 'queue.limit':
        floorOf(c)?.queue.setLimit(_num(msg['maxWorkers']));
      case 'notify.webhook':
        final url = _str(msg['url'], 4096).trim();
        final err = webhook.set(url, who);
        warn(c, err);
        if (err == null) {
          toastAll(url.isNotEmpty ? '📣 $who set up team notifications' : '$who turned off team notifications');
        }
      case 'notify.test':
        unawaited(
          webhook
              .test(who)
              .then(
                (err) => sendTo(
                  c,
                  ToastMsg(err ?? '📣 Sent a test message', err != null ? ToastLevel.warn : ToastLevel.info),
                ),
              ),
        );
      case 'changes.watch':
        final w = worker(msg['workerId']);
        if (w != null) w.floor.changes.watch(w.wid, c.id);
      case 'changes.unwatch':
        final wid = _str(msg['workerId'], 32);
        // Its worker may have gone home already; stop watching wherever it was.
        for (final f in floors.values) {
          f.changes.unwatch(wid, c.id);
        }
      case 'changes.diff':
        final workerId = _str(msg['workerId'], 32);
        final file = _str(msg['path'], 4096);
        final floor = workerFloor(workerId);
        if (floor == null) {
          sendTo(
            c,
            ChangesDiffMsg(workerId: workerId, path: file, diff: '', truncated: false, error: 'No such worker'),
          );
          break;
        }
        unawaited(
          floor.changes.diff(workerId, file).then((r) {
            sendTo(
              c,
              ChangesDiffMsg(workerId: workerId, path: file, diff: r.diff, truncated: r.truncated, error: r.error),
            );
          }),
        );
      case 'changes.commit':
        final w = worker(msg['workerId']);
        if (w != null) {
          unawaited(w.floor.changes.commit(w.wid, _str(msg['message'], 5000), who).then((err) => warn(c, err)));
        }
      case 'changes.discard':
        final w = worker(msg['workerId']);
        if (w != null) {
          final path = msg['path'] is String ? _str(msg['path'], 4096) : null;
          unawaited(w.floor.changes.discard(w.wid, path, who).then((err) => warn(c, err)));
        }
      case 'changes.pr':
        final w = worker(msg['workerId']);
        if (w != null) {
          unawaited(
            w.floor.changes
                .pullRequest(w.wid, _str(msg['title'], 300), _str(msg['body'], 20000), who)
                .then((err) => warn(c, err)),
          );
        }
      case 'upgrade.check':
        unawaited(upgrader.check());
      case 'upgrade.start':
        unawaited(
          upgrader.start(who).then((err) {
            if (err != null) {
              warn(c, err);
            } else {
              toastAll('$who is upgrading the office — it restarts when the new version is built');
            }
          }),
        );
      case 'limits.refresh':
        limits.refresh();
      case 'team.get':
        unawaited(team.state().then((state) => sendTo(c, TeamMsg(state))));
      case 'team.invite':
        final user = _str(msg['github'], 64);
        unawaited(
          team.invite(user).then((r) async {
            final error = r.error;
            sendTo(
              c,
              error != null ? TeamInvitedMsg(user, error: error) : TeamInvitedMsg(user, name: r.name, keys: r.keys),
            );
            if (error != null) return;
            toastAll('$who invited ${r.name} to the office');
            await teamChanged();
          }),
        );
      case 'team.remove':
        final name = _str(msg['name'], 64);
        unawaited(
          team.remove(name).then((err) async {
            if (err != null) return warn(c, err);
            toastAll("$who removed $name's access");
            await teamChanged();
          }),
        );
      case 'accounts.get' ||
          'accounts.invite' ||
          'accounts.cancel' ||
          'accounts.revoke' ||
          'accounts.role' ||
          'accounts.shared':
        handleAccounts(c, t as String, msg);
      case 'decor.add':
        final floor = here();
        if (floor == null) break;
        final r = floor.decor.add(msg['decor'], who);
        final d = r.decoration;
        if (d == null) return warn(c, r.error);
        decorChanged(floor);
        toastFloor(floor, '🖼️ $who hung ${d.title != null && d.title!.isNotEmpty ? '“${d.title}”' : 'a picture'}');
      case 'decor.update':
        final floor = here();
        if (floor == null) break;
        final r = floor.decor.update(_str(msg['id'], 32), msg['decor']);
        if (r.decoration == null) return warn(c, r.error);
        decorChanged(floor);
      case 'decor.remove':
        final floor = here();
        if (floor == null) break;
        final d = floor.decor.remove(_str(msg['id'], 32));
        if (d == null) break;
        decorChanged(floor);
        toastFloor(floor, '$who took down ${d.title != null && d.title!.isNotEmpty ? '“${d.title}”' : 'a picture'}');
      case 'wb.open' || 'wb.close':
        final floor = floorOf(c);
        final open = t == 'wb.open' && floor != null;
        if (open == c.whiteboard) break;
        c.whiteboard = open;
        drawingChanged(floor);
      case 'wb.update':
        final floor = here();
        if (floor == null) break;
        final applied = floor.whiteboard.apply(msg['elements']);
        if (applied.accepted.isNotEmpty) toNeighbors(c, WbUpdateMsg(applied.accepted));
        warn(c, applied.error);
      case 'wb.pointer':
        final now = _now();
        if (!c.whiteboard || now - c.lastWbPointerAt < 25) break;
        c.lastWbPointerAt = now;
        final sel = msg['selected'];
        final selected = sel is List
            ? [for (final s in sel.whereType<String>().take(200)) s.length > 100 ? s.substring(0, 100) : s]
            : null;
        final pointer = WbPointerMsg(
          c.id,
          WbPointer(
            x: _num(msg['x']),
            y: _num(msg['y']),
            tool: msg['tool'] == 'laser' ? WbTool.laser : WbTool.pointer,
            button: msg['button'] == 'down' ? WbButton.down : WbButton.up,
          ),
          selected: selected,
        );
        final json = _json(pointer.toJson());
        for (final o in List.of(clients.values)) {
          if (o.id == c.id || !o.whiteboard || o.peer.floor != c.peer.floor || !o.open || _buffered(o) > 1024 * 1024) {
            continue;
          }
          sendRaw(o, json);
        }
      case 'jukebox.play':
        final floor = here();
        if (floor == null) break;
        final r = floor.jukebox.play((track: msg['track'], url: msg['url']), who);
        if (r.error != null) return warn(c, r.error);
        if (!r.changed) break;
        jukeboxChanged(floor);
        toastFloor(
          floor,
          floor.jukebox.state().track == jukeboxStream
              ? '📻 $who tuned the jukebox to ${floor.jukebox.title()}'
              : '🎵 $who put on “${floor.jukebox.title()}”',
        );
      case 'jukebox.skip':
        final floor = here();
        if (floor == null) break;
        floor.jukebox.skip(who);
        jukeboxChanged(floor);
        toastFloor(floor, '⏭️ $who skipped to “${floor.jukebox.title()}”');
      case 'cabinet.play':
        final floor = here();
        final wanted = msg['game'];
        if (floor == null || (c.playing && wanted == c.game)) break;
        final at = cabinetPlayer(floor);
        if (at != null && at != c) {
          warn(c, '${at.peer.name} is on the arcade — press E there to watch');
          sendTo(c, CabinetMsg(cabinetState(floor)));
          break;
        }
        // Already at it: that game's over, and this is the next one.
        if (c.playing) arcade.leave(c.game, floor.id);
        final game = arcade.start(
          Player(
            owner: c.accountId != null ? 'account:${c.accountId}' : 'name:$who',
            name: who,
            color: c.peer.color,
            connection: c.id,
          ),
          wanted,
        );
        c.game = game;
        if (game != wanted && !arcade.counts(game)) {
          warn(c, "🕹️ That's a lot of new games in a row, so this one won't go on the high-score table");
        }
        c
          ..playing = true
          ..frame = null;
        cabinetChanged(floor);
      case 'cabinet.leave':
        stopPlaying(c);
      case 'cabinet.frame':
        final floor = floorOf(c);
        final frame = checkFrame(msg['frame']);
        if (!c.playing || floor == null || frame == null) break;
        // Every frame counts towards the score, even one that comes too soon after the last to pass on.
        if (arcade.frame(c.game, frame, floor.id) == Verdict.voided) {
          warn(c, "🕹️ The office couldn't follow this game, so its score won't go on the high-score table");
        }
        c.frame = frame;
        final now = _now();
        if (now - c.lastFrameAt < 40) break;
        c.lastFrameAt = now;
        toNeighbors(c, CabinetFrameMsg(frame), true);
      case 'jukebox.stop':
        final floor = here();
        if (floor == null || !floor.jukebox.stop(who)) break;
        jukeboxChanged(floor);
        toastFloor(floor, '🔇 $who turned the jukebox off');
      case 'theme.set':
        final pick = ThemePick.tryParse(msg['pick']);
        if (pick == null || pick == themes.state().pick) break;
        themes.set(pick, who);
        final now = themes.state().active;
        toastAll(switch (pick) {
          ThemePick.halloween => '🎃 $who dressed the office up for Halloween',
          ThemePick.christmas => '🎄 $who dressed the office up for Christmas',
          ThemePick.off => '$who took the holiday decorations down',
          ThemePick.auto =>
            '📅 $who set the decorations to follow the calendar'
                '${now != null ? " (it's ${now == HolidayTheme.halloween ? 'Halloween 🎃' : 'Christmas 🎄'} season)" : ''}',
        });
      case 'ping':
        sendTo(c, PongMsg(at: _num(msg['at']), now: _now().toDouble()));
    }
  }

  void onConnection(RelicWebSocket ws, Uri url, Session session) {
    final id = _randomHex(5);
    // Back where they were before a reload or a restart, else the first floor. Everyone arrives by elevator.
    final wanted = _query(url, 'floor');
    // Up on the roof, as long as there's a building under it.
    final onRoof = wanted == roof && floors.isNotEmpty;
    final floor = onRoof ? null : arrivalFloor(wanted);
    final spot = elevatorSpot();
    final account = session.account;
    // An account's name is its own; on the shared password people pick one.
    final picked = _str(_query(url, 'name'), 24).trim();
    final name = account?.name ?? (picked.isNotEmpty ? picked : 'Guest ${id.substring(0, 3)}');
    final colorParam = _query(url, 'color') ?? '';
    // Number(''), like the Node server: a missing parameter is no preference, a bad one is NaN.
    num? intParam(String k) {
      final v = _query(url, k);
      if (v == null || v.isEmpty) return null;
      return num.tryParse(v.trim()) ?? double.nan;
    }

    final me = meOf(account?.id);
    final client = _Client(
      id,
      ws,
      _Peer(
        id: id,
        name: name,
        color: _isColor(colorParam) ? colorParam : '#4f86f7',
        look: sanitizeLook({
          'skin': intParam('skin'),
          'hair': intParam('hair'),
          'style': intParam('style'),
        }, lookFromSeed(id)),
        x: spot.x,
        z: spot.z,
        account: account != null ? true : null,
        floor: onRoof ? roof : floor?.id,
      ),
      accountId: account?.id,
      admin: me.admin,
    );
    clients[id] = client;
    if (account != null) accounts.seen(account.id);
    // dart:io pings on this interval and drops a connection whose pong doesn't come back in time,
    // so ghosts don't linger in the office (the Node server's heartbeat did this by hand).
    ws.pingInterval = const Duration(seconds: 20);

    sendTo(
      client,
      WelcomeMsg(
        you: id,
        peers: [for (final c in clients.values) c.peer.info],
        floors: floorInfos(),
        projectsDir: ProjectsDirState(dir: _tildify(cfg.projectsDir)), // custom, by, at: phase 2
        ice: cfg.iceServers,
        chat: chat.recent(50),
        invites: team.available,
        version: upgrader.version,
        upgrade: upgrader.state,
        usage: ledger.state(),
        limits: limits.state,
        me: me,
        notify: webhook.state(),
        sky: sky.state,
        theme: themes.state(),
        view: onRoof ? roofView() : floorView(floor),
      ),
    );
    screensOf(client, floor);
    broadcast(PeerJoinMsg(client.peer.info), except: id);
    if (account != null) accountsChanged(); // now online
    floorsChanged();
    if (floor != null) {
      floor.arrived();
      // Anyone whose process ended since (exited, or failed to resume) gets up as you walk in.
      floor.workers.wakeAll();
    }
    limits.refresh();

    var closed = false;
    void onClose() {
      if (closed) return;
      closed = true;
      clients.remove(id);
      if (client.whiteboard) drawingChanged(floorOf(client));
      stopPlaying(client);
      for (final f in floors.values) {
        f.workers.detachAll(id);
        f.changes.unwatchAll(id);
      }
      broadcast(PeerLeaveMsg(id));
      if (account != null) accountsChanged();
      floorsChanged();
    }

    void onText(String raw) {
      if (raw.length > _maxPayload) return;
      Object? msg;
      try {
        msg = jsonDecode(raw);
      } catch (_) {
        return;
      }
      if (msg is! Map<String, dynamic> || client.out) return;
      try {
        handleMessage(client, msg);
      } catch (err, st) {
        // One bad message must never take the office down.
        stderr.writeln('agent-office: $err\n$st');
      }
    }

    ws.events.listen(
      (event) {
        switch (event) {
          case TextDataReceived(:final text):
            onText(text);
          case BinaryDataReceived(:final data):
            if (data.length <= _maxPayload) onText(utf8.decode(data, allowMalformed: true));
          case CloseReceived():
            onClose();
        }
      },
      onError: (_) {
        unawaited(ws.tryClose().catchError((_) => false));
        onClose();
      },
      onDone: onClose,
      cancelOnError: false,
    );
  }

  onConnectionRef = onConnection;

  final resync = Timer.periodic(const Duration(seconds: 1), (_) {
    for (final c in List.of(clients.values)) {
      if (c.stale.isEmpty || _buffered(c) > _slowClientBytes ~/ 8) continue;
      for (final wid in c.stale) {
        final snap = c.attached.contains(wid) ? workerFloor(wid)?.workers.attach(wid, c.id, c.peer.name) : null;
        if (snap != null) sendTo(c, TermSnapshotMsg(workerId: wid, data: snap.data, cols: snap.cols, rows: snap.rows));
      }
      c.stale.clear();
    }
  });

  // Signs out anyone `agent-office accounts` revoked, and passes on role changes made there.
  // (Dead connections are dropped by the sockets' own ping, see onConnection.)
  final heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
    var accountsMoved = false;
    for (final c in clients.values) {
      if (!c.out && (!stillIn(c) || c.admin != meOf(c.accountId).admin)) accountsMoved = true;
    }
    if (accountsMoved) accountsChanged();
  });

  final address = InternetAddress.tryParse(cfg.host) ?? (await InternetAddress.lookup(cfg.host)).first;
  IOAdapter adapter;
  try {
    adapter = await IOAdapter.bind(address, port: cfg.port, context: tls);
  } catch (_) {
    await hookServer.close(force: true);
    resync.cancel();
    heartbeat.cancel();
    upgrader.stop();
    webhook.stop();
    sky.stop();
    themes.stop();
    limits.close();
    for (final f in floors.values) {
      await f.shutdown(true);
    }
    rethrow;
  }
  final server = RelicServer(() => adapter);
  await server.mountAndStart((req) async {
    try {
      return await handler(req);
    } catch (err, st) {
      stderr.writeln('agent-office: $err\n$st');
      return _send(500, {'error': 'Internal error'});
    }
  });
  services.start();

  var down = false;
  shutdown = (keep) async {
    if (down) return;
    down = true;
    arcade.flush();
    heartbeat.cancel();
    resync.cancel();
    floorsTimer?.cancel();
    upgrader.stop();
    services.stop();
    webhook.stop();
    sky.stop();
    themes.stop();
    final closing = [for (final f in floors.values) f.shutdown(keep)];
    ledger.flush();
    limits.close();
    images.close();
    for (final c in List.of(clients.values)) {
      unawaited(c.ws.tryClose().catchError((_) => false));
    }
    await Future.wait(closing);
    await server.close(force: true);
    await hookServer.close(force: true);
  };

  return Office._(server, shutdown, accounts, clientDir, hookPort, floors, resolveCommand(cfg.agentCmd));
}

String _message(Object err) => switch (err) {
  StateError(:final message) => message,
  FormatException(:final message) => message,
  ProcessException(:final message) => message,
  FileSystemException(:final message) => message,
  _ => '$err'.replaceFirst(RegExp(r'^(Exception|Error): '), ''),
};

/// The floor's view of the building, as closures over [startServer]'s state.
class _FloorContext implements FloorContext {
  _FloorContext({
    required this.agentCmd,
    required this.agentArgs,
    required this.hook,
    required this.ledger,
    required this.onEmit,
    required this.onToast,
    required this.onTermData,
    required this.onChanges,
    required this.onWorkerChanged,
    required this.onPeople,
    required this.onPeers,
  });

  @override
  final String agentCmd;
  @override
  final List<String> agentArgs;
  @override
  final HookEnv hook;
  @override
  final Ledger ledger;
  final void Function(Floor floor, ServerMsg msg, [bool droppable]) onEmit;
  final void Function(Floor? floor, String text, [ToastLevel? level]) onToast;
  final void Function(String workerId, String data, List<String> viewers) onTermData;
  final void Function(ChangesState state, List<String> clients) onChanges;
  final void Function(Floor floor, String workerId, WorkerInfo? worker) onWorkerChanged;
  final int Function(Floor floor) onPeople;
  final List<PeerInfo> Function(Floor floor) onPeers;

  @override
  void emit(Floor floor, ServerMsg msg, [bool droppable = false]) => onEmit(floor, msg, droppable);
  @override
  void toast(Floor floor, String text, [ToastLevel? level]) => onToast(floor, text, level);
  @override
  void termData(String workerId, String data, List<String> viewers) => onTermData(workerId, data, viewers);
  @override
  void changes(ChangesState state, List<String> clients) => onChanges(state, clients);
  @override
  void workerChanged(Floor floor, String workerId, WorkerInfo? worker) => onWorkerChanged(floor, workerId, worker);
  @override
  int people(Floor floor) => onPeople(floor);
  @override
  List<PeerInfo> peers(Floor floor) => onPeers(floor);
}
