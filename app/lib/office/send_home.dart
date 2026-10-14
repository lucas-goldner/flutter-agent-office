// Workers sent home on a map with a script for it (MapPlan.sendHome, see office_shared's
// maps/dungeon.dart), acting its steps out one after another: the castle's Kingsguard runs up from the
// dungeon, the worker packs its things, and it's marched off down the stairs with a hand on its
// shoulder, thrown into its cell, and the door slams behind it; or the station's Security marches it to
// the airlock, and out it goes. Each step is a `begin` (once) and a `tick` (each frame, until it's
// done) below; the cell ([_lockUp]) and the airlock ([_eject]) have the most to act out. A map without
// a script sees its workers out the office's way (world/leaving.dart). A port of
// features/workers/{sendhome,sendoff,lockup,eject}.ts.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/nav.dart' show Pt;
import 'package:office_shared/protocol.dart' show WorkerStatus;
import 'package:vector_math/vector_math.dart' as vm;

import '../world/adrift.dart';
import '../world/character.dart';
import '../world/court.dart' show yawOf;
import '../world/geo.dart' show euler;
import '../world/jail.dart';
import '../world/laptop.dart';
import '../world/world.dart';

/// Paces (m/s): the worker's walk (slower the more worn out it is), or at a run; the escort's run to
/// fetch it, and its walk.
const double _walkPace = 2.3;
const double _runPace = 3.8;
const double _guardRun = 4.8;
const double _guardWalk = 2.6;

/// Seconds packing up at its seat, hopping down off it, and shrinking away once it's gone.
const double _pack = 0.9;
const double _hop = 0.55;
const double _gone = 0.6;
const double _laptopGone = 0.3;

/// A worker's feet are this far above its origin (see leaving.dart).
const double _feet = 0.07;

/// How far behind the worker its escort walks, a hand on its shoulder.
const double _behind = 0.8;

/// The most escorts out at once: anyone else sent home meanwhile waits for one.
const int _guards = 4;
const List<String> _farewells = [
  '😢 bye, everyone',
  '🥲 it was fun',
  '📦 welp',
  '😞 cleaning out my desk',
  '🥺 but my PR…',
];

/// Thrown into its cell: the door swinging open, a step up to it, the throw, and the door slamming.
const ({double open, double step, double fly, double shut}) _jailTimes = (open: 0.5, step: 0.35, fly: 0.75, shut: 0.3);

/// Out of the airlock: the inner door going up, the shove through it, the door coming down, the wait
/// under the red lights, the outer hatch parting, being blown out to where it drifts from, and the
/// hatch closing.
const _ejectTimes = (open: 0.5, step: 0.6, seal: 0.5, wait: 1.8, part: 0.22, blow: 5.5, shut: 0.8);

/// A worker's middle is this far above its feet (see adrift.dart).
const double _middle = 0.45;

const List<String> _pleas = [
  '😨 Wait, wait, wait!',
  '🥺 Let’s talk about this!',
  '😰 I’ll fix the tests!',
  '🙏 One more chance!',
  '😳 Is this thing on?',
  '🚪 Hello? The door?',
];
const List<String> _cries = [
  '😱 AAAAAAH!',
  '😵 NOOOoooo…',
  '🫨 WHOAAAA!',
  '😭 I regret nothiiing!',
  '🚀 Wheeeee!',
  '🫠 Tell my PR I loved it!',
];

final math.Random _rng = math.Random();
T _pick<T>(List<T> xs) => xs[_rng.nextInt(xs.length)];
double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));
double _lerp(double a, double b, double t) => a + (b - a) * t;
double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// What a sendoff is heard by: footsteps, a cell's door, someone landing on the straw, and the airlock
/// (its doors, its alarm, and the air going out of it).
abstract interface class SendoffSounds {
  void step(double x, double y, double z);
  void door(vm.Vector3 at, bool open);
  void thud(vm.Vector3 at);
  void airlock(vm.Vector3 at, String what);
}

/// Someone walking a way: the worker, or its escort. Where it is and which way it faces are kept here,
/// and put on its node by [pose].
class _Walk {
  _Walk(this.root, this.pos, this.yaw);
  final Node root;
  vm.Vector3 pos;
  double yaw;

  /// Tipped forward (being thrown into a cell).
  double tilt = 0;
  List<Pt> way = const [];
  int next = 0;
  double heading = 0;
  double stepIn = 0;

  void pose() {
    root.position = pos.clone();
    root.rotation = tilt != 0 ? euler(tilt, yaw) : vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), yaw);
  }
}

enum _GuardMode { idle, go, wait, follow, home }

class _Guard extends _Walk {
  _Guard(this.person, {required this.posted}) : super(person.root, vm.Vector3.zero(), 0);
  final Person person;

  /// The map's own, on watch at its post; the others are called out while it's busy, and put away after.
  final bool posted;
  _GuardMode mode = _GuardMode.idle;
  double speed = _guardWalk;
}

enum _State { seated, hop, stand, walk, fly, done }

enum _Phase { go, open, step, fly, seal, wait, blow, shut }

class _Sendoff {
  _Sendoff(this.id, this.model, this.desk, this.laptop, this.steps, this.walk, this.scale, this.cell);
  final String id;
  final Worker model;
  final DeskView desk;
  ({Laptop laptop, double gone, bool closing})? laptop;
  final List<SendHomeStep> steps;

  /// The step it's on, whether it's begun, and seconds into it.
  int i = 0;
  bool begun = false;
  double t = 0;
  _State state = _State.seated;
  final _Walk walk;
  double speed = _walkPace;
  ({vm.Vector3 from, double t}) hop = (from: vm.Vector3.zero(), t: 0);
  Node? chair;
  double spin = 0;
  final double scale;

  /// Where it's walked, for its escort to follow.
  List<Pt> trail = [];
  _Guard? guard;

  /// Its seat in the dungeon, if it's to be locked up.
  final CellSeat? cell;

  /// Being thrown into its cell, or put out of the airlock: how far through it is, where it was (and which
  /// way up, when the hatch blew), and whether it had to be walked there first.
  ({_Phase phase, double t, vm.Vector3 from, vm.Quaternion turn, bool walked})? jail, eject;

  /// 0 → 1 as it shrinks away.
  double gone = 0;
  bool leaving = false;

  /// What it (or its escort) said last, for how long to give it.
  String said = '';

  /// Its script has run to the end.
  bool over = false;

  /// Put out of the airlock: its node is posed by the step, not by its walk.
  bool floating = false;
}

/// The point [dist] back along [trail] from its end (where it is now), or null while it hasn't gone that far.
Pt? behind(List<Pt> trail, double dist) {
  var left = dist;
  for (var i = trail.length - 1; i > 0; i--) {
    final (x1, z1) = trail[i];
    final (x0, z0) = trail[i - 1];
    final d = _hypot(x1 - x0, z1 - z0);
    if (d >= left) {
      final k = left / d;
      return (x1 + (x0 - x1) * k, z1 + (z0 - z1) * k);
    }
    left -= d;
  }
  return null;
}

/// Whose turn it is in each airlock: one at a time.
final Expando<String> _using = Expando('airlock turn');

/// The airlock shut up again, its lights off, and nobody's turn in it: whoever was being put out of it isn't any more.
void shutAirlock(AirlockSite? lock) {
  if (lock == null) return;
  lock.inner(0);
  lock.outer(0);
  lock.alarm(false);
  _using[lock] = null;
}

class Sendoffs {
  Sendoffs({
    required this.parent,
    required this.ground,
    required this.sounds,
    required this.onUp,
    required this.world,
    required this.jail,
    required this.adrift,
  });

  final Node parent;

  /// The top of whatever is underfoot at (x, z) for feet at `y`.
  final double Function(double x, double z, double y) ground;
  final SendoffSounds sounds;

  /// It has got up from `deskId`, so the seat is free to see.
  final void Function(String deskId) onUp;
  final World Function() world;
  final Jail jail;
  final Drifters adrift;

  List<_Sendoff> _list = [];
  List<_Guard> _guardsOut = [];
  World? _guardsOf;

  /// Takes over a worker's model and laptop the moment it's sent home from [desk], and plays the map's
  /// script out on it. [from] is where it stands if it's up out of its seat (in line for the throne).
  void add(String id, Worker model, Laptop laptop, DeskView desk, [Pt? from]) {
    final plan = world().plan.sendHome;
    if (plan == null) return;
    model
      ..stopDancing()
      ..setAction(null)
      ..setStatus(WorkerStatus.idle, false);
    final local = vm.Matrix4.inverted(parent.globalTransform) * model.root.globalTransform as vm.Matrix4;
    final pos = local.getTranslation();
    final scale = local.getColumn(0).xyz.length;
    model.root.parent?.remove(model.root);
    parent.add(model.root);
    final yaw = from != null ? yawOf(local) : desk.def.rotY + math.pi;
    model.root.scale = vm.Vector3.all(scale);
    final cell = plan.keeps ? jail.seatOf(id) : null;
    if (cell != null) jail.hold(id);
    // Not adrift outside the airlock till it's blown out of it.
    if (plan.keeps) adrift.hold(id);
    final walk = _Walk(model.root, pos, yaw)..heading = yaw;
    walk.pose();
    final s = _Sendoff(id, model, desk, (laptop: laptop, gone: 0, closing: false), plan.steps, walk, scale, cell)
      ..state = from != null ? _State.stand : _State.seated
      ..hop = (from: pos.clone(), t: 0)
      ..chair = from != null || desk.def.beanbag ? null : desk.chair;
    _list.add(s);
  }

  /// Whether someone sent home from [deskId] is still sitting there.
  bool seated(String deskId) =>
      _list.any((s) => s.desk.def.id == deskId && (s.state == _State.seated || s.state == _State.hop));

  /// Someone new sat down at [deskId]: the old laptop goes at once, and whoever's still sitting there gets up.
  void vacate(String deskId) {
    for (final s in _list) {
      if (s.desk.def.id != deskId) continue;
      if (s.laptop != null) _dropLaptop(s);
      s.chair = null;
      if (s.state == _State.seated) {
        // Up and out of the way, beside the seat, to wait for whatever's next.
        final w = world();
        final way = w.nav.wayFrom(s.desk.def, (w.plan.door.x, w.plan.door.z));
        s.walk.way = [way[0]];
        _getUp(s);
      }
    }
  }

  /// Off to another floor or map: nobody's left being seen out, and the escorts are back at their posts.
  void clear() {
    for (final s in _list) {
      _drop(s);
    }
    _list = [];
    _resetGuards();
  }

  /// Where each of them is, and their escorts, for the doors to open.
  List<vm.Vector3> positions() => [
    for (final s in _list)
      if (s.state != _State.done) s.walk.pos,
    for (final g in _guardsOut)
      if (g.mode != _GuardMode.idle) g.pos,
  ];

  /// How many are being seen out right now.
  int get busy => _list.length;

  void update(double dt, double t) {
    final w = world();
    if (!identical(w, _guardsOf)) _resetGuards();
    for (final s in _list) {
      _step(s, dt, t);
    }
    _list = _list.where((s) {
      if (!s.over || s.laptop != null) return true;
      // Done with: the escort takes itself back to its post.
      final g = s.guard;
      if (g != null && g.mode != _GuardMode.home && g.mode != _GuardMode.idle) _sendBack(g);
      return false;
    }).toList();
    for (final g in _guardsOut) {
      _moveGuard(g, dt, t);
    }
  }

  // ---- The script --------------------------------------------------------------------------------

  void _step(_Sendoff s, double dt, double t) {
    // Its chair spins on after it, the laptop (or tome) shuts once it's packing or up.
    final chair = s.chair;
    if (chair != null && s.spin != 0) {
      chair.rotation = chair.rotation * vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), s.spin * dt);
      s.spin *= math.exp(-dt * 1.4);
      if (s.spin.abs() < 0.05) s.spin = 0;
    }
    final lap = s.laptop;
    if (lap != null && lap.closing && lap.laptop.shut(dt)) {
      final gone = math.min(1.0, lap.gone + dt / _laptopGone);
      lap.laptop.root.scale = vm.Vector3.all(math.max(0.001, 1 - gone * gone));
      s.laptop = (laptop: lap.laptop, gone: gone, closing: true);
      if (gone >= 1) _dropLaptop(s);
    }
    if (s.state != _State.done) _move(s, dt);
    // Through the script, as far as it goes this frame. Past its end, whatever's left of the worker goes.
    var left = dt;
    while (!s.over) {
      if (s.i >= s.steps.length) {
        if (s.state == _State.done) {
          s.over = true;
        } else {
          s.leaving = true;
        }
        break;
      }
      final step = s.steps[s.i];
      if (!s.begun) {
        s.begun = true;
        s.t = 0;
        _begin(s, step);
      }
      s.t += left;
      left = 0;
      if (!_tick(s, step)) break;
      s.i++;
      s.begun = false;
    }
    if (s.state != _State.done) {
      if (!s.floating) s.walk.pose();
      s.model.update(dt, t);
    }
  }

  void _begin(_Sendoff s, SendHomeStep step) {
    switch (step.kind) {
      case SendHomeStepKind.pack:
        // What it says next, if the script has it say something, or a farewell of its own.
        final next = s.i + 1 < s.steps.length ? s.steps[s.i + 1] : null;
        s.model.leave(next?.kind == SendHomeStepKind.say && next?.who != SendHomeWho.escort ? '📦' : _pick(_farewells));
        _closeLaptop(s);
      case SendHomeStepKind.say:
        final text = s.said = _pick(step.text ?? const ['…']);
        if (step.who == SendHomeWho.escort) {
          (s.guard?.person ?? _guardsOut.firstOrNull?.person)?.say(text, 3.4);
        } else {
          s.model.say(text);
        }
      case SendHomeStepKind.walk:
        _walkTo(s, step.to ?? const SendHomePlace.named(SendHomeSpot.door), step.run ?? false);
      case SendHomeStepKind.leave:
        s.leaving = true;
      case SendHomeStepKind.jail:
        if (s.cell != null) {
          s.jail = (phase: _Phase.go, t: 0, from: vm.Vector3.zero(), turn: vm.Quaternion.identity(), walked: false);
        }
      case SendHomeStepKind.eject:
        s.eject = (phase: _Phase.go, t: 0, from: vm.Vector3.zero(), turn: vm.Quaternion.identity(), walked: false);
      case SendHomeStepKind.return_:
        final g = s.guard;
        if (g != null) _sendBack(g);
      case SendHomeStepKind.fetch || SendHomeStepKind.wait:
        break;
    }
  }

  /// Whether [step] is done with.
  bool _tick(_Sendoff s, SendHomeStep step) => switch (step.kind) {
    SendHomeStepKind.pack => s.t >= _pack,
    SendHomeStepKind.wait => s.t >= (step.seconds ?? 0),
    SendHomeStepKind.say => s.t >= math.min(2.4, 0.9 + s.said.length * 0.025),
    SendHomeStepKind.fetch => _fetch(s, step.run != false),
    SendHomeStepKind.walk => s.state == _State.stand,
    // With no seat for it down there (the map changed its mind), it's just gone.
    SendHomeStepKind.jail => s.jail == null ? (s.leaving = true) : _lockUp(s),
    SendHomeStepKind.eject => _eject(s),
    SendHomeStepKind.leave => s.state == _State.done,
    SendHomeStepKind.return_ => true,
  };

  void _closeLaptop(_Sendoff s) {
    final lap = s.laptop;
    if (lap != null) s.laptop = (laptop: lap.laptop, gone: lap.gone, closing: true);
  }

  /// The escort comes for it: true once it's there, beside it.
  bool _fetch(_Sendoff s, bool run) {
    if (s.guard == null) {
      final g = s.guard = _freeGuard();
      // Every escort's out: it waits its turn.
      if (g == null) return false;
      g.speed = run ? _guardRun : _guardWalk;
      // Up beside it, where it'll get down (or in front of it, if it's on its feet already).
      final p = s.walk.pos;
      Pt to;
      if (s.state == _State.seated) {
        final way = _plot(s, _nextPlace(s));
        to = way.length > 1 ? way[1] : (way.isNotEmpty ? way[0] : (p.x, p.z));
      } else {
        final a = s.walk.heading;
        to = (p.x + math.sin(a) * 0.9, p.z + math.cos(a) * 0.9);
      }
      g.way = _between((g.pos.x, g.pos.z), _levelOf(g.pos.y), to, _levelOf(p.y));
      g.next = 1;
      g.mode = _GuardMode.go;
    }
    return s.guard!.mode == _GuardMode.wait;
  }

  // ---- Walking ----------------------------------------------------------------------------------

  /// Where the script walks it next (or out of the door, if it doesn't).
  SendHomePlace _nextPlace(_Sendoff s) {
    for (var i = s.i; i < s.steps.length; i++) {
      final st = s.steps[i];
      if (st.kind == SendHomeStepKind.walk) return st.to ?? const SendHomePlace.named(SendHomeSpot.door);
      if (st.kind == SendHomeStepKind.jail) return const SendHomePlace.named(SendHomeSpot.cell);
      if (st.kind == SendHomeStepKind.eject) return const SendHomePlace.named(SendHomeSpot.airlock);
    }
    return const SendHomePlace.named(SendHomeSpot.door);
  }

  /// Where [to] is: a spot, and whether it's down in the dungeon.
  ({Pt at, bool below})? _placeOf(_Sendoff s, SendHomePlace to) {
    final w = world();
    final d = w.dungeon?.plan;
    final spot = to.spot;
    if (spot == null) return (at: (to.x, to.z), below: to.below && d != null);
    switch (spot) {
      case SendHomeSpot.stairs:
        return d != null ? (at: d.stairs.top, below: false) : null;
      case SendHomeSpot.dungeon:
        return d != null ? (at: d.stairs.foot, below: true) : null;
      case SendHomeSpot.cell:
        final cell = s.cell;
        final c = cell != null && d != null ? d.cells[cell.cell] : null;
        return c != null
            ? (at: c.outside, below: true)
            : d != null
            ? (at: d.stairs.foot, below: true)
            : null;
      case SendHomeSpot.airlock:
        final a = w.airlock;
        return a != null ? (at: a.plan.front, below: false) : null;
      case SendHomeSpot.post:
        final e = w.escort;
        return e != null ? (at: (e.post.x, e.post.z), below: e.below) : null;
      case SendHomeSpot.door:
        return null;
    }
  }

  /// The way from where it is (its seat, or where it stands) to [to]: the first point is where it gets
  /// down, if it's seated.
  List<Pt> _plot(_Sendoff s, SendHomePlace to) {
    final w = world();
    final d = w.dungeon;
    final seated = s.state == _State.seated;
    final Pt here = (s.walk.pos.x, s.walk.pos.z);
    final below = _levelOf(s.walk.pos.y);
    if (to.spot == SendHomeSpot.door) {
      if (seated) return w.ways.home(s.desk.def).way;
      if (!below || d == null) return w.ways.home(s.desk.def, here).way;
      final up = _between(here, true, d.plan.stairs.top, false);
      return [...up, ...w.ways.home(s.desk.def, d.plan.stairs.top).way.skip(1)];
    }
    final p = _placeOf(s, to);
    if (p == null) return seated ? w.ways.home(s.desk.def).way : w.ways.home(s.desk.def, here).way;
    if (!seated) return _between(here, below, p.at, p.below);
    // Off its seat on whichever side's the shorter way, then round the hall, and down the stairs if it's going down.
    final hallTo = p.below && d != null ? d.plan.stairs.top : p.at;
    final off = w.nav.wayFrom(s.desk.def, hallTo);
    return p.below && d != null ? [...off, ..._between(d.plan.stairs.top, false, p.at, true).skip(1)] : off;
  }

  /// The way between two spots, up or down the dungeon stairs if they're on different levels.
  List<Pt> _between(Pt from, bool fromBelow, Pt to, bool toBelow) {
    final w = world();
    final d = w.dungeon;
    if (d == null) return w.nav.route(from, to);
    return levelRoute(d.plan, w.nav, d.nav, from, fromBelow, to, toBelow);
  }

  void _walkTo(_Sendoff s, SendHomePlace to, [bool run = false]) {
    s.speed = (run ? _runPace : _walkPace) * s.model.pace;
    s.walk.way = _plot(s, to);
    s.walk.next = 1;
    _closeLaptop(s);
    final g = s.guard;
    if (g != null) {
      g.mode = _GuardMode.follow;
      g.person.holdOn(true);
    }
    if (s.state == _State.seated) {
      _getUp(s);
    } else {
      s.state = _State.walk;
      s.trail = [(s.walk.pos.x, s.walk.pos.z)];
    }
  }

  void _getUp(_Sendoff s) {
    s.state = _State.hop;
    s.hop = (from: s.walk.pos.clone(), t: 0);
    if (s.chair != null && s.spin == 0) s.spin = (_rng.nextBool() ? -1 : 1) * (5 + _rng.nextDouble() * 3);
  }

  /// Moves the worker along: down off its seat, along its way, or shrinking away.
  void _move(_Sendoff s, double dt) {
    final root = s.model.root;
    final pos = s.walk.pos;
    if (s.leaving && s.state != _State.hop) {
      s.model.walking = false;
      s.gone = math.min(1, s.gone + dt / _gone);
      root.scale = vm.Vector3.all(math.max(0.001, s.scale * (1 - s.gone * s.gone)));
      if (s.gone >= 1) {
        root.detach();
        s.model.dispose();
        jail.release(s.id);
        adrift.release(s.id);
        s.state = _State.done;
      }
      return;
    }
    if (s.state == _State.hop) {
      final t = math.min(1.0, s.hop.t + dt / _hop);
      s.hop = (from: s.hop.from, t: t);
      final (x0, z0) = s.walk.way.isNotEmpty ? s.walk.way[0] : (pos.x, pos.z);
      final floor = ground(x0, z0, s.hop.from.y) - _feet;
      pos.setValues(
        _lerp(s.hop.from.x, x0, t),
        _lerp(s.hop.from.y, floor, t) + math.sin(t * math.pi) * 0.35,
        _lerp(s.hop.from.z, z0, t),
      );
      final (x1, z1) = s.walk.way.length > 1
          ? s.walk.way[1]
          : (s.walk.way.isNotEmpty ? s.walk.way[0] : (pos.x, pos.z + 1));
      s.walk.heading = math.atan2(x1 - x0, z1 - z0);
      s.walk.yaw += _wrap(s.walk.heading - s.walk.yaw) * math.min(1, dt * 7);
      if (t < 1) return;
      onUp(s.desk.def.id);
      s.trail = [(x0, z0)];
      s.state = s.walk.way.length > 1 ? _State.walk : _State.stand;
      s.walk.next = 1;
      return;
    }
    if (s.state != _State.walk) return;
    final arrived = _along(s.walk, s.speed, dt);
    s.model.walking = !arrived;
    // Where it's been, for its escort to follow in its footsteps.
    final last = s.trail.isNotEmpty ? s.trail.last : null;
    if (last == null || _hypot(pos.x - last.$1, pos.z - last.$2) > 0.08) s.trail.add((pos.x, pos.z));
    if (s.trail.length > 400) s.trail.removeRange(0, 200);
    if (arrived) s.state = _State.stand;
  }

  /// A step along [m]'s way at [speed], up and down stairs as the ground goes, with footsteps: true once
  /// it's at the end.
  bool _along(_Walk m, double speed, double dt) {
    final pos = m.pos;
    var move = speed * dt;
    while (move > 0 && m.next < m.way.length) {
      final (x, z) = m.way[m.next];
      final dx = x - pos.x, dz = z - pos.z;
      final d = _hypot(dx, dz);
      if (d > 1e-4) m.heading = math.atan2(dx, dz);
      if (d <= move) {
        pos.x = x;
        pos.z = z;
        move -= d;
        m.next++;
      } else {
        pos.x += dx / d * move;
        pos.z += dz / d * move;
        move = 0;
      }
    }
    final g = ground(pos.x, pos.z, pos.y + _feet + 0.35) - _feet;
    pos.y += (g - pos.y) * math.min(1, dt * 14);
    m.yaw += _wrap(m.heading - m.yaw) * math.min(1, dt * 8);
    final walking = m.next < m.way.length;
    if (walking) {
      m.stepIn -= dt;
      if (m.stepIn <= 0) {
        m.stepIn += 0.9 / math.max(1, speed);
        sounds.step(pos.x, pos.y, pos.z);
      }
    }
    return !walking;
  }

  // ---- The cell -----------------------------------------------------------------------------------

  /// Thrown into its cell, and the door locked behind it: true once it's shut.
  bool _lockUp(_Sendoff s) {
    var j = s.jail!;
    final d = world().dungeon;
    final seat = s.cell!;
    final c = d != null && seat.cell < d.plan.cells.length ? d.plan.cells[seat.cell] : null;
    if (d == null || c == null) {
      s.leaving = true;
      return true;
    }
    final pos = s.walk.pos;
    void next(_Phase phase, {vm.Vector3? from}) =>
        j = s.jail = (phase: phase, t: s.t, from: from ?? j.from, turn: j.turn, walked: j.walked);
    if (j.phase == _Phase.go) {
      // Not at its cell's door yet (the script didn't take it there): off it goes, then.
      if (s.state == _State.walk || s.state == _State.hop) return false;
      if (_hypot(pos.x - c.outside.$1, pos.z - c.outside.$2) > 0.35 && !j.walked) {
        s.jail = (phase: j.phase, t: j.t, from: j.from, turn: j.turn, walked: true);
        _walkTo(s, const SendHomePlace.named(SendHomeSpot.cell));
        return false;
      }
      next(_Phase.open);
      sounds.door(d.lock(seat.cell), true);
    }
    final t = s.t - j.t;
    final face = math.atan2(c.x - c.outside.$1, c.z - c.outside.$2);
    switch (j.phase) {
      case _Phase.open:
        d.swing(seat.cell, math.min(1, t / _jailTimes.open));
        s.walk.yaw += _wrap(face - s.walk.yaw) * 0.2;
        if (t < _jailTimes.open) return false;
        next(_Phase.step, from: pos.clone());
        return false;
      case _Phase.step:
        final k = math.min(1.0, t / _jailTimes.step);
        pos.x = _lerp(j.from.x, c.threshold.$1, k);
        pos.z = _lerp(j.from.z, c.threshold.$2, k);
        s.model.walking = k < 1;
        if (k < 1) return false;
        // A shove from behind.
        s.guard?.person.reach();
        next(_Phase.fly, from: pos.clone());
        s.state = _State.fly;
        return false;
      case _Phase.fly:
        final k = math.min(1.0, t / _jailTimes.fly);
        final spot = seat.spot;
        pos.setValues(
          _lerp(j.from.x, spot.x, k),
          _lerp(j.from.y, spot.y, k) + math.sin(k * math.pi) * 0.9,
          _lerp(j.from.z, spot.z, k),
        );
        s.walk.yaw += _wrap(spot.rotY - s.walk.yaw) * math.min(1, k * 0.35);
        s.walk.tilt = math.sin(k * math.pi) * -0.5;
        s.model.walking = false;
        if (k < 1) return false;
        // In a heap on the straw: from here on it's the jail's, sat where it landed.
        sounds.thud(pos.clone());
        jail.release(s.id);
        s.model.root.detach();
        s.model.dispose();
        s.state = _State.done;
        next(_Phase.shut);
        return false;
      default:
        // The door slams.
        final k = math.min(1.0, t / _jailTimes.shut);
        d.swing(seat.cell, 1 - k * k);
        if (k < 1) return false;
        sounds.door(d.lock(seat.cell), false);
        s.guard?.person.holdOn(false);
        return true;
    }
  }

  // ---- The airlock --------------------------------------------------------------------------------

  /// Put out of the airlock: true once it's adrift (or gone) and the hatch has closed behind it.
  bool _eject(_Sendoff s) {
    var j = s.eject!;
    final lock = world().airlock;
    // No airlock here (the map changed its mind): it's just gone.
    if (lock == null) {
      s.leaving = true;
      return true;
    }
    final a = lock.plan;
    final pos = s.walk.pos;
    void next(_Phase phase, {vm.Vector3? from, vm.Quaternion? turn}) =>
        j = s.eject = (phase: phase, t: s.t, from: from ?? j.from, turn: turn ?? j.turn, walked: j.walked);
    if (j.phase == _Phase.go) {
      // Not at the airlock yet (the script didn't take it there): off it goes, then. And one at a time.
      if (s.state == _State.walk || s.state == _State.hop) return false;
      if (_hypot(pos.x - a.front.$1, pos.z - a.front.$2) > 0.35 && !j.walked) {
        s.eject = (phase: j.phase, t: j.t, from: j.from, turn: j.turn, walked: true);
        _walkTo(s, const SendHomePlace.named(SendHomeSpot.airlock));
        return false;
      }
      final turn = _using[lock];
      if (turn != null && turn != s.id) return false;
      _using[lock] = s.id;
      next(_Phase.open);
      sounds.airlock(lock.doorAt, 'door');
    }
    final t = s.t - j.t;
    final outward = math.atan2(a.out.$1, a.out.$2);
    switch (j.phase) {
      case _Phase.open:
        lock.inner(math.min(1, t / _ejectTimes.open));
        s.walk.yaw += _wrap(outward - s.walk.yaw) * 0.2;
        if (t < _ejectTimes.open) return false;
        // A shove from behind.
        s.guard?.person.reach();
        s.state = _State.fly;
        next(_Phase.step, from: pos.clone());
        return false;
      case _Phase.step:
        final k = math.min(1.0, t / _ejectTimes.step);
        pos.setValues(
          _lerp(j.from.x, a.chamber.$1, k),
          j.from.y + math.sin(k * math.pi) * 0.22,
          _lerp(j.from.z, a.chamber.$2, k),
        );
        s.model.walking = k < 1;
        if (k < 1) return false;
        s.guard?.person.holdOn(false);
        sounds.airlock(lock.doorAt, 'door');
        next(_Phase.seal);
        return false;
      case _Phase.seal || _Phase.wait:
        // The door comes down behind it, and it turns round to the porthole.
        s.walk.yaw += _wrap(outward + math.pi - s.walk.yaw) * 0.18;
        if (j.phase == _Phase.seal) {
          final k = math.min(1.0, t / _ejectTimes.seal);
          lock.inner(1 - k);
          if (k < 1) return false;
          lock.alarm(true);
          sounds.airlock(lock.doorAt, 'alarm');
          s.model.say(_pick(_pleas));
          next(_Phase.wait);
          return false;
        }
        // Running on the spot, for all the good it does.
        s.model.walking = true;
        if (t < _ejectTimes.wait) return false;
        sounds.airlock(lock.hatchAt, 'blow');
        s.model.say(_pick(_cries));
        next(_Phase.blow, from: pos.clone(), turn: vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), s.walk.yaw));
        return false;
      case _Phase.blow:
        s.floating = true;
        lock.outer(math.min(1, t / _ejectTimes.part));
        final k = math.min(1.0, t / _ejectTimes.blow);
        // Out like a cork, and ever slower, till it's drifting with the rest.
        final e = 1 - math.pow(1 - k, 3).toDouble();
        final kept = adrift.where(s.id);
        final d = kept ?? adriftOf(a, s.id);
        // Straight out of the hatch first, then round to its own heading.
        final start = vm.Vector3(j.from.x, j.from.y + _middle * s.scale, j.from.z);
        final out = vm.Vector3(a.hatch.$1 + a.out.$1 * 6, 1.5, a.hatch.$2 + a.out.$2 * 6);
        final to = vm.Vector3(d.x, d.y, d.z);
        final u = 1 - e;
        final at = start * (u * u) + out * (2 * u * e) + to * (e * e);
        // Head over heels on the way, settling into the slow turn it drifts with.
        final spin =
            euler(d.rx, d.ry, d.rz) * vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0.35).normalized(), (1 - e) * 11);
        final settle = _smoothstep(k, 0, 0.18);
        final want = _slerp(j.turn, spin, settle);
        // One the office isn't keeping (it's not on its list) dwindles to nothing instead.
        final scale = kept != null ? _lerp(s.scale, adriftScale, e) : math.max(0.001, s.scale * (1 - e));
        float(s.model.root, (x: at.x, y: at.y, z: at.z, rx: d.rx, ry: d.ry, rz: d.rz), scale, want);
        s.model.walking = true;
        if (k < 1) return false;
        // Adrift: from here on it's the drifters', where it is now.
        adrift.release(s.id);
        jail.release(s.id);
        s.model.root.detach();
        s.model.dispose();
        s.state = _State.done;
        next(_Phase.shut);
        return false;
      default:
        // The hatch closes on the empty chamber, and the lights go back to what they were.
        final k = math.min(1.0, t / _ejectTimes.shut);
        lock.outer(1 - k);
        if (k < 1) return false;
        sounds.airlock(lock.hatchAt, 'door');
        shutAirlock(lock);
        return true;
    }
  }

  // ---- The escorts ------------------------------------------------------------------------------

  void _moveGuard(_Guard g, double dt, double t) {
    final pos = g.pos;
    var moving = false;
    if (g.mode == _GuardMode.go || g.mode == _GuardMode.home) {
      moving = !_along(g, g.speed, dt);
      if (!moving) {
        if (g.mode == _GuardMode.home) {
          final post = world().escort?.post;
          if (post != null) g.heading = post.rotY;
          g.mode = _GuardMode.idle;
          g.person.holdOn(false);
          // One called out to help goes back in; the one on watch stays at its post.
          if (!g.posted) g.root.visible = false;
        } else {
          g.mode = _GuardMode.wait;
        }
      }
    } else if (g.mode == _GuardMode.follow || g.mode == _GuardMode.wait) {
      final s = _list.where((x) => identical(x.guard, g)).firstOrNull;
      if (s != null && g.mode == _GuardMode.follow && s.state != _State.fly && s.state != _State.done) {
        // A step behind it, where it's just been.
        final (tx, tz) = behind(s.trail, _behind) ?? (pos.x, pos.z);
        final dx = tx - pos.x, dz = tz - pos.z;
        final d = _hypot(dx, dz);
        final step = math.min(d, math.max(s.speed, 1) * 1.6 * dt);
        if (d > 0.02) {
          pos.x += dx / d * step;
          pos.z += dz / d * step;
          moving = step > 0.004;
        }
        final gr = ground(pos.x, pos.z, pos.y + _feet + 0.35) - _feet;
        pos.y += (gr - pos.y) * math.min(1, dt * 14);
      }
      // Facing whoever it's come for.
      if (s != null && s.state != _State.done) {
        final p = s.walk.pos;
        if (_hypot(p.x - pos.x, p.z - pos.z) > 0.05) g.heading = math.atan2(p.x - pos.x, p.z - pos.z);
      }
      if (moving) {
        g.stepIn -= dt;
        if (g.stepIn <= 0) {
          g.stepIn += 0.35;
          sounds.step(pos.x, pos.y, pos.z);
        }
      }
    }
    g.yaw += _wrap(g.heading - g.yaw) * math.min(1, dt * 8);
    g.pose();
    if (g.root.visible) g.person.update(dt, t, moving, false, moving ? math.max(0.8, g.speed / _guardWalk) : 1);
  }

  /// An escort who isn't busy: the one on watch, or another called out (up to four of them).
  _Guard? _freeGuard() {
    final w = world();
    final e = w.escort;
    if (e == null) return null;
    if (!identical(w, _guardsOf)) _resetGuards();
    var g = _guardsOut.where((x) => x.mode == _GuardMode.idle && !_list.any((s) => identical(s.guard, x))).firstOrNull;
    if (g == null && _guardsOut.length < _guards) {
      final person = e.make();
      w.group.add(person.root);
      g = _Guard(person, posted: false)
        ..heading = e.post.rotY
        ..yaw = e.post.rotY;
      _guardsOut.add(g);
    }
    if (g == null) return null;
    if (!g.posted) {
      // Out of the guardroom, at the post.
      g.pos = vm.Vector3(e.post.x, e.post.y, e.post.z);
      g.yaw = g.heading = e.post.rotY;
      g.root.visible = true;
      g.pose();
    }
    return g;
  }

  void _sendBack(_Guard g) {
    final e = world().escort;
    g.person.holdOn(false);
    if (e == null) {
      g.mode = _GuardMode.idle;
      return;
    }
    g.way = _between((g.pos.x, g.pos.z), _levelOf(g.pos.y), (e.post.x, e.post.z), e.below);
    g.next = 1;
    g.speed = _guardWalk;
    g.mode = _GuardMode.home;
  }

  /// The escorts of the world you're in, all back at their post: the one on watch, and nobody else.
  void _resetGuards() {
    for (final g in _guardsOut) {
      g.person.holdOn(false);
      if (!g.posted) {
        g.root.detach();
        g.person.dispose();
      }
    }
    _guardsOut = [];
    final w = world();
    _guardsOf = w;
    final e = w.escort;
    if (e == null) return;
    final g = _Guard(e.guard, posted: true)
      ..pos = vm.Vector3(e.post.x, e.post.y, e.post.z)
      ..yaw = e.post.rotY
      ..heading = e.post.rotY;
    g.pose();
    _guardsOut.add(g);
  }

  // ---- Bits -----------------------------------------------------------------------------------

  /// Whether feet at [y] are down in the dungeon.
  bool _levelOf(double y) {
    final d = world().dungeon?.plan;
    return d != null && y < d.ceiling - 0.5;
  }

  void _drop(_Sendoff s) {
    if (s.state == _State.seated || s.state == _State.hop) onUp(s.desk.def.id);
    if (s.laptop != null) _dropLaptop(s);
    if (s.state != _State.done) {
      s.model.root.detach();
      s.model.dispose();
    }
    jail.release(s.id);
    adrift.release(s.id);
    final d = world().dungeon;
    final cell = s.cell;
    if (cell != null && d != null) d.swing(cell.cell, 0);
    if (s.eject != null) shutAirlock(world().airlock);
  }

  void _dropLaptop(_Sendoff s) {
    final lap = s.laptop;
    if (lap == null) return;
    lap.laptop.root.detach();
    lap.laptop.dispose();
    s.laptop = null;
  }
}

/// Where a worker blown out of [a] that the office isn't keeping drifts from (it dwindles away on the way).
Drift adriftOf(AirlockPlan a, String id) => adrift(a, id, 0);

double _smoothstep(double x, double min, double max) {
  if (x <= min) return 0;
  if (x >= max) return 1;
  final k = (x - min) / (max - min);
  return k * k * (3 - 2 * k);
}

/// Spherical interpolation between two turns (three's Quaternion.slerpQuaternions).
vm.Quaternion _slerp(vm.Quaternion a, vm.Quaternion b, double t) {
  var bx = b.x, by = b.y, bz = b.z, bw = b.w;
  var cos = a.x * bx + a.y * by + a.z * bz + a.w * bw;
  if (cos < 0) {
    cos = -cos;
    bx = -bx;
    by = -by;
    bz = -bz;
    bw = -bw;
  }
  double ka, kb;
  if (cos > 0.9995) {
    ka = 1 - t;
    kb = t;
  } else {
    final th = math.acos(cos);
    final s = math.sin(th);
    ka = math.sin((1 - t) * th) / s;
    kb = math.sin(t * th) / s;
  }
  return vm.Quaternion(a.x * ka + bx * kb, a.y * ka + by * kb, a.z * ka + bz * kb, a.w * ka + bw * kb)..normalize();
}
