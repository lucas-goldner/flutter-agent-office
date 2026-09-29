import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

// ---- Its day ------------------------------------------------------------------------------------

/// Spots on the lounge rug, by the TV.
const List<Pt> _lounge = [(16, 1.6), (16, -1.5), (14.8, 1.9), (11.8, 2.4), (11.8, -2.6), (14.6, -1.3)];

const double _trot = 1.3;
const double _run = 3.4;

/// How long a pat lasts, wag and all.
const int _petMs = 2600;

final math.Random _random = math.Random();
double _rand(double a, double b) => a + _random.nextDouble() * (b - a);
T _pick<T>(List<T> xs) => xs[_random.nextInt(xs.length)];
double _dist(Pt a, Pt b) => math.sqrt((a.$1 - b.$1) * (a.$1 - b.$1) + (a.$2 - b.$2) * (a.$2 - b.$2));
double _toward(Pt from, Pt to) => math.atan2(to.$1 - from.$1, to.$2 - from.$2);
int _now() => DateTime.now().millisecondsSinceEpoch;

/// Needs input and nobody has answered yet.
bool callsForDog(WorkerInfo w) => w.status == WorkerStatus.needsInput && !w.acked && deskById.containsKey(w.deskId);

enum _Mode { lounge, nap, wander, follow, bark, pet }

class DogEnv {
  const DogEnv({required this.workers, required this.people, required this.send});

  final List<WorkerInfo> Function() workers;

  /// Everyone on this floor, where they stand now.
  final List<PeerInfo> Function() people;

  /// To everyone on this floor.
  final void Function(DogState dog) send;
}

/// One leg of its day: a [DogState] without its name, coat and elapsed time, and when it began.
class _Leg {
  const _Leg({
    required this.path,
    required this.speed,
    required this.act,
    this.face,
    this.workerId,
    this.following,
    this.petBy,
    required this.start,
  });

  final List<Pt> path;
  final double speed;
  final DogAct act;
  final double? face;
  final String? workerId;
  final String? following;
  final String? petBy;
  final int start;
}

/// A floor's dog. It naps under the desks of workers who are busy, trots after people for a while,
/// sniffs around and hangs out on the lounge rug. When a worker needs input it drops everything, runs
/// to that desk and barks (the browsers do the barking; see app/lib/world/dog.dart). Its name is kept
/// in the floor's .agent-office/dog.json.
class Dog {
  Dog(this.floorId, String dataDir, this._env) : _file = p.join(dataDir, 'dog.json') {
    final d = dogDefaults(floorId);
    _fallbackName = d.name;
    _coat = d.coat;
    _name = _load() ?? d.name;
    // Lying on the rug when the office opens, and up and about a few seconds later.
    final spot = _pick(_lounge);
    _leg = _Leg(path: [spot], speed: 0, act: DogAct.lie, face: math.pi / 2 + _rand(-0.6, 0.6), start: _now() - 60000);
    _wake(_rand(3000, 8000));
  }

  final String floorId;
  final DogEnv _env;
  final String _file;
  late String _name;
  late final int _coat;
  late final String _fallbackName;
  late _Leg _leg;
  _Mode _mode = _Mode.lounge;
  Timer? _timer;

  /// Workers waiting on an answer, and since when. It goes to whoever has waited longest.
  final Map<String, int> _calling = {};

  /// Crawled under a desk from here, so it comes out the same way.
  Pt? _exit;
  ({String id, int until})? _follow;

  /// Its nap is ending (its worker stopped working); it gets up once, however many updates follow.
  bool _waking = false;
  int _lastPet = 0;
  bool _stopped = false;

  DogState view() => DogState(
    name: _name,
    coat: _coat,
    path: _leg.path,
    speed: _leg.speed,
    act: _leg.act,
    face: _leg.face,
    workerId: _leg.workerId,
    following: _leg.following,
    petBy: _leg.petBy,
    elapsed: (_now() - _leg.start).toDouble(),
  );

  /// Where it is right now.
  Pt here() {
    final at = dogAtLeg(_leg.path, _leg.speed, _leg.face, (_now() - _leg.start) / 1000);
    return (at.x, at.z);
  }

  String get dogName => _name;

  /// A worker on this floor changed.
  void onWorker(WorkerInfo w) {
    final calls = callsForDog(w);
    if (calls && !_calling.containsKey(w.id)) {
      _calling[w.id] = _now();
      // Drop everything, except finishing a pat.
      if (_mode != _Mode.bark && _mode != _Mode.pet) return _wake(0);
    } else if (!calls && _calling.remove(w.id) != null && _mode == _Mode.bark && _leg.workerId == w.id) {
      return _wake(_rand(800, 1600));
    }
    // Its worker stopped working: time to get up.
    if (_mode == _Mode.nap && !_waking && _leg.workerId == w.id && w.status != WorkerStatus.working) {
      _waking = true;
      _wake(_rand(1500, 4000));
    }
  }

  void onWorkerGone(String workerId) {
    _calling.remove(workerId);
    if ((_mode == _Mode.bark || _mode == _Mode.nap) && _leg.workerId == workerId) _wake(_rand(800, 1600));
  }

  /// Someone gave it a pat: it stops, turns to them and wags for everyone to see.
  bool pet(PeerInfo by) {
    if (by.floor != floorId || by.y > 1) return false;
    final now = _now();
    if (now - _lastPet < 400) return false;
    final at = here();
    if (_dist((by.x, by.z), at) > 3.5) return false;
    _lastPet = now;
    final workerId = _mode == _Mode.bark || _mode == _Mode.nap ? _leg.workerId : null;
    _mode = _Mode.pet;
    _go([at], 0, DogAct.wag, face: _toward(at, (by.x, by.z)), petBy: by.name, workerId: workerId);
    _wake(_petMs.toDouble(), () {
      // Back to the worker that needs someone; otherwise tag along with whoever petted it for a bit.
      if (_nextCall() != null) return _think();
      PeerInfo? p;
      for (final q in _env.people()) {
        if (q.id == by.id) {
          p = q;
          break;
        }
      }
      if (p != null && p.y < 0.5 && _random.nextDouble() < 0.7) return _startFollow(p.id, _rand(10000, 20000));
      _think();
    });
    return true;
  }

  /// Renames it ('' goes back to its first name). Answers with the name it has now.
  String rename(String raw) {
    final clean = cleanDogName(raw);
    _name = clean.isNotEmpty ? clean : _fallbackName;
    try {
      _writePrivate(_file, const JsonEncoder.withIndent('  ').convert({'name': _name}));
    } catch (err) {
      stderr.writeln("agent-office: couldn't save the dog's name: $err");
    }
    _send();
    return _name;
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  String? _load() {
    final file = File(_file);
    if (!file.existsSync()) return null;
    try {
      final saved = jsonDecode(file.readAsStringSync());
      final name = saved is Map ? saved['name'] : null;
      if (name is! String) return null;
      final clean = cleanDogName(name);
      return clean.isNotEmpty ? clean : null;
    } catch (_) {
      return null;
    }
  }

  void _send() => _env.send(view());

  void _wake(double ms, [void Function()? fn]) {
    _timer?.cancel();
    if (_stopped) return;
    _timer = Timer(Duration(milliseconds: ms.round()), fn ?? _think);
  }

  /// Starts a leg from where it is now.
  void _go(
    List<Pt> pathPts,
    double speed,
    DogAct act, {
    double? face,
    String? workerId,
    String? following,
    String? petBy,
  }) {
    _leg = _Leg(
      path: pathPts,
      speed: speed,
      act: act,
      face: face,
      workerId: workerId,
      following: following,
      petBy: petBy,
      start: _now(),
    );
    _send();
  }

  /// Walks to `to` (out from under a desk first, if it's under one) and says how long that takes, in ms.
  double _walkTo(Pt to, double speed, DogAct act, {double? face, String? workerId, String? following, Pt? last}) {
    final from = here();
    final pts = <Pt>[from];
    var start = from;
    // Still under the desk (or on its way in), not just somewhere on the way there.
    final exit = _exit;
    if (exit != null && !walkable(from.$1, from.$2)) {
      pts.add(exit);
      start = exit;
    }
    _exit = null;
    pts.addAll(route(start, to).skip(1));
    if (last != null) pts.add(last);
    _go(pts, speed, act, face: face, workerId: workerId, following: following);
    return legSeconds(_leg.path, _leg.speed) * 1000;
  }

  /// The worker that has waited longest for an answer.
  WorkerInfo? _nextCall() {
    final byId = {for (final w in _env.workers()) w.id: w};
    WorkerInfo? best;
    var since = double.infinity;
    for (final MapEntry<String, int>(key: id, value: t) in [..._calling.entries]) {
      final w = byId[id];
      if (w == null || !callsForDog(w)) {
        _calling.remove(id);
        continue;
      }
      if (t < since) {
        since = t.toDouble();
        best = w;
      }
    }
    return best;
  }

  /// Picks what to do next.
  void _think() {
    if (_stopped) return;
    _waking = false;
    final call = _nextCall();
    if (call != null) return _barkAt(call);
    final busy = _env
        .workers()
        .where(
          // Only at a desk or a bean bag: a board agent's kiosk has nothing to curl up under.
          (w) =>
              w.status == WorkerStatus.working && deskById.containsKey(w.deskId) && deskById[w.deskId]!.station == null,
        )
        .toList();
    final people = _env.people().where((p) => p.y < 0.5).toList();
    final was = _mode;
    final options = <(double, void Function())>[(was == _Mode.lounge ? 1 : 2.5, _goLounge), (1.5, _wander)];
    if (busy.isNotEmpty) options.add((was == _Mode.nap ? 1.5 : 3, () => _nap(_pick(busy))));
    if (people.isNotEmpty) {
      options.add((was == _Mode.follow ? 0.5 : 2, () => _startFollow(_pick(people).id, _rand(15000, 30000))));
    }
    var roll = _random.nextDouble() * options.fold<double>(0, (n, o) => n + o.$1);
    for (final (w, fn) in options) {
      roll -= w;
      if (roll <= 0) return fn();
    }
    options[0].$2();
  }

  void _goLounge() {
    _mode = _Mode.lounge;
    final at = here();
    final spot = _pick(_lounge.where((p) => _dist(p, at) > 1).toList());
    // Settles down facing the TV, more or less.
    final ms = _walkTo(spot, _trot, DogAct.lie, face: math.pi / 2 + _rand(-0.7, 0.7));
    _wake(ms + _rand(20000, 45000));
  }

  void _wander() {
    _mode = _Mode.wander;
    final at = here();
    var spot = at;
    for (var i = 0; i < 30; i++) {
      final Pt p = (_rand(Floor.minX + 1, Floor.maxX - 1), _rand(Floor.minZ + 1, Floor.maxZ - 1));
      if (walkable(p.$1, p.$2) && _dist(p, at) > 4) {
        spot = p;
        break;
      }
    }
    final ms = _walkTo(spot, _trot, DogAct.sniff);
    _wake(ms + _rand(4000, 9000));
  }

  /// Curls up under a busy worker's desk, at its feet.
  void _nap(WorkerInfo w) {
    final desk = deskById[w.deskId]!;
    _mode = _Mode.nap;
    var side = _sideOf(desk);
    // A bean bag has no desk to get under, so it curls up beside it, on whichever side has room.
    if (desk.beanbag) {
      final (x, z) = deskPoint(desk, side * 1.05, 0.1);
      if (!walkable(x, z)) side = -side;
    }
    final approach = desk.beanbag ? deskPoint(desk, side * 1.3, 1.2) : deskPoint(desk, side * 0.8, 1.3);
    final under = desk.beanbag ? deskPoint(desk, side * 1.05, 0.1) : deskPoint(desk, side * 0.45, 0.15);
    // Head out toward the chair.
    final ms = _walkTo(approach, _trot, DogAct.nap, workerId: w.id, face: desk.rotY, last: under);
    _exit = approach;
    _wake(ms + _rand(30000, 70000));
  }

  void _startFollow(String id, double ms) {
    _mode = _Mode.follow;
    _follow = (id: id, until: _now() + ms.round());
    _followStep();
  }

  /// Every second or so: keep up with them, and sit when they stop.
  void _followStep() {
    final f = _follow;
    PeerInfo? p;
    if (f != null) {
      for (final q in _env.people()) {
        if (q.id == f.id) {
          p = q;
          break;
        }
      }
    }
    // Gone upstairs: it doesn't do stairs.
    if (f == null || p == null || _now() > f.until || p.y > 1.5) {
      _follow = null;
      return _think();
    }
    final Pt person = (p.x, p.z);
    final behind = nearestWalkable((p.x - math.sin(p.rotY) * 1.1, p.z - math.cos(p.rotY) * 1.1));
    final end = _leg.path.last;
    final along = _leg.act == DogAct.sit && _leg.following == p.id;
    // Someone standing still who just turns around doesn't need it circling round behind them.
    final settled =
        along && ((!p.moving && _dist(end, person) < 1.8 && _dist(end, person) > 0.4) || _dist(end, behind) < 0.8);
    if (!settled) {
      final at = here();
      if (_dist(at, behind) < 0.8) {
        _go([at], 0, DogAct.sit, face: _toward(at, person), following: p.id);
      } else {
        _walkTo(
          behind,
          _dist(at, behind) > 4 ? _run * 0.8 : 1.8,
          DogAct.sit,
          face: _toward(behind, person),
          following: p.id,
        );
      }
    }
    _wake(900, _followStep);
  }

  /// Runs to the desk of a worker that needs input, and barks at it.
  void _barkAt(WorkerInfo w) {
    final desk = deskById[w.deskId]!;
    final already = _mode == _Mode.bark && _leg.workerId == w.id;
    _mode = _Mode.bark;
    _follow = null;
    if (!already) {
      final side = _sideOf(desk);
      // At a board agent, out in front of its kiosk, looking up at the agent behind it.
      final station = desk.station != null;
      final spot = station ? deskPoint(desk, side * 0.6, -1.1) : deskPoint(desk, side * 0.75, 1.45);
      _walkTo(
        spot,
        _run,
        DogAct.bark,
        workerId: w.id,
        face: _toward(spot, deskPoint(desk, 0, station ? Kiosk.stand : 0.9)),
      );
    }
    // Checks now and then that it's still the one to bark at.
    _wake(5000);
  }

  /// Which end of a desk (-1 or +1 along its width) is nearer.
  double _sideOf(DeskDef desk) {
    final at = here();
    final s = desk.station != null ? -1.1 : 1.3;
    return _dist(at, deskPoint(desk, 1, s)) <= _dist(at, deskPoint(desk, -1, s)) ? 1 : -1;
  }
}

/// Writes [text] to [file] readable by this user only: to `<file>.tmp` first, then moved into place.
void _writePrivate(String file, String text) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(text);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', tmp]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
  File(tmp).renameSync(file);
}
