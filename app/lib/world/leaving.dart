// Workers who've been sent home: a port of world/leaving.ts.
//
// Departures needs two things from the office that are ported elsewhere (office.dart's DeskView,
// laptop.dart's Laptop). So it compiles on its own, it asks for them through two small interfaces,
// which those classes implement (or wrap):
//
//  * [LeavingDesk]: the desk's layout entry ([DeskDef]: id, rotY, beanbag) and its desk chair node,
//    which spins after the worker as it hops off (null for a bean bag).
//  * [LeavingLaptop]: the laptop's root node, `shut(dt)` (animates the lid down; true once it's
//    shut) and `dispose()`.

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:office_shared/layout.dart' show Balcony, DeskDef, Parachute;
import 'package:office_shared/nav.dart';

import 'character.dart';
import 'geo.dart';
import 'office/geo.dart' show cyl;
import 'toon.dart' show hex, mesh, toon, toonUnique;

/// What Departures needs of a desk (the old DeskView).
abstract interface class LeavingDesk {
  DeskDef get def;

  /// The desk chair, spun round by whoever hops off it; null for a bean bag.
  Node? get chair;
}

/// What Departures needs of a laptop (the old Laptop).
abstract interface class LeavingLaptop {
  Node get root;

  /// Closes the lid a step; true once it's shut.
  bool shut(double dt);

  void dispose();
}

/// Walking pace on the way out, in m/s: no hurry any more.
const double _pace = 2.3;

/// Seconds sat at the desk while its things go in the box and the laptop shuts.
const double _pack = 0.9;

/// Seconds hopping down off the chair (or the bean bag).
const double _hop = 0.55;

/// A worker's feet are this far above its origin, so standing on something its origin is this far below the top.
const double _feet = 0.07;

/// Seconds to shrink away once it's off down the sidewalk.
const double _gone = 0.6;

/// Seconds for a shut laptop to shrink away.
const double _laptopGone = 0.3;

const List<String> farewells = [
  '😢 bye, everyone',
  '🥲 it was fun',
  '📦 welp',
  '😞 cleaning out my desk',
  '🥺 but my PR…',
  '😶 security is walking me out',
];

// Leaving a floor with no exit door, by parachute off the balcony.
/// Seconds climbing up onto the railing, then teetering on it.
const double _climbUp = 0.6;
const double _teeter = 0.8;

/// Seconds falling before the chute opens, and how hard it jumped out (m/s, out and up).
const double _freefall = 0.7;
const double _leapOut = 2.6, _leapUp = 2.4;
const double _gravity = 9.8;

/// How fast it sinks under the chute (m/s): quicker while it's a long way up, gently at the end.
const double _sinkMin = 2.2, _sinkMax = 9, _sinkPer = 4;

/// How fast it circles down onto the spot it lands on (rad/s).
const double _turn = 1.2;

/// Seconds for the chute to pop open, and to crumple on the ground once it's down.
const double _pop = 0.45;
const double _crumple = 1.3;
const List<String> jumps = ['🪂 geronimo!', '🪂 see ya!', '🪂 wheee!', '🪂 bye bye!', '🪂 I quit!'];
const List<String> _canopies = ['#ef476f', '#ffd166', '#06d6a0', '#118ab2', '#8338ec', '#ff8a5b'];

/// Seen from below too, so both sides of the fabric.
final Map<String, Material> _fabric = {};
Material _cloth(String color) => _fabric[color] ??= (toonUnique(hex(color))..doubleSided = true);

/// A parachute, to hang from a worker's shoulders: striped gores in a dome over its head, and the
/// cords down to it. Its origin is where it's strapped on, so it pops open (and crumples) from there.
({Node group, Node dome}) _parachute(String color) {
  final group = Node(name: 'parachute')..position = vm.Vector3(0, 0.88, 0);
  final dome = Node(name: 'dome');
  const r = 1.35, rim = 1.15, gores = 10;
  for (var i = 0; i < gores; i++) {
    final geo = sphere(r, 3, 5, i / gores * math.pi * 2, math.pi * 2 / gores, 0, rim);
    dome.add(mesh(geo, _cloth(i.isOdd ? '#fffaf3' : color), 0, 0, 0, false));
  }
  dome
    ..scale = vm.Vector3(1, 0.62, 1)
    ..position = vm.Vector3(0, 1.25, 0);
  group.add(dome);
  // A cord from each seam at the rim down to a shoulder.
  final ink = toon(hex('#2b2d42'));
  final rimY = 1.25 + r * math.cos(rim) * 0.62;
  for (var i = 0; i < gores; i++) {
    final a = i / gores * math.pi * 2;
    final top = vm.Vector3(math.sin(a) * r * math.sin(rim), rimY, math.cos(a) * r * math.sin(rim));
    final end = vm.Vector3(top.x < 0 ? -0.24 : 0.24, 0, 0.02);
    final d = top - end;
    final cord = mesh(cyl(0.008, 0.008, d.length, 3), ink, 0, 0, 0, false)
      ..position = (top + end) * 0.5
      ..rotation = vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), d.normalized());
    group.add(cord);
  }
  return (group: group, dome: dome);
}

enum _ChutePhase { walk, climb, teeter, fall, glide, down, off }

/// How it gets down from a floor with no exit door, and how far along it is.
class _Chute {
  _Chute(this.color);

  _ChutePhase phase = _ChutePhase.walk;
  double t = 0;
  final String color;

  /// Once it's open.
  ({Node group, Node dome})? canopy;
  vm.Vector3 from = vm.Vector3.zero();
  vm.Vector3 vel = vm.Vector3.zero();

  /// Where it lands (its origin's height there), the way round to it now, how wide it circles, and from how high.
  vm.Vector3 land = vm.Vector3.zero();
  double angle = 0;
  double radius = 0;
  double height = 1;
}

class _Leaver {
  _Leaver({
    required this.model,
    required this.deskId,
    required this.way,
    required this.seat,
    required this.heading,
    required this.chair,
    required this.scale,
    this.chute,
  });

  final Worker model;
  final String deskId;
  List<Pt> way;

  /// Off a floor with no exit door: out over the balcony railing by parachute.
  final _Chute? chute;

  /// Tumbling (x) and teetering (z), on the way over the railing.
  double rotX = 0, rotZ = 0;

  /// The point on [way] it's walking to; 0 until it has hopped down.
  int next = 0;

  /// Seconds since it was sent home.
  double t = 0;

  /// Where it sat.
  final vm.Vector3 seat;

  /// The way it's walking (rotation around y; 0 is +z), and the way it faces now.
  double heading;
  late double yaw = heading;

  /// Seconds until its next footstep.
  double stepIn = 0;

  /// The desk chair it got up from, spinning after it (null for a bean bag, or once someone new sits there).
  Node? chair;
  double spin = 0;
  final double scale;

  /// 0 → 1 as it shrinks away at the end.
  double gone = 0;
}

class _Closing {
  _Closing(this.laptop, this.deskId);
  final LeavingLaptop laptop;
  final String deskId;

  /// 0 → 1 as it shrinks away, once the lid is shut.
  double gone = 0;
}

double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));
double _lerp(double a, double b, double t) => a + (b - a) * t;
final math.Random _rng = math.Random();

/// Workers who've been sent home. Each one packs its things into a cardboard box while its laptop
/// shuts, hops down off its chair, and walks out of the building with the box (see [wayHome]): out
/// the exit door, down the steps and off along the sidewalk, where it's gone. Only the bottom floor
/// has an exit door, so from the floors above it goes out onto the balcony instead, climbs up on the
/// railing and jumps, and its parachute brings it down onto the lot out front, box and all.
class Departures {
  Departures(this._parent, this._ground, this._footstep, this._onUp, {bool Function()? upstairs})
    : _upstairs = upstairs ?? (() => false);

  /// Whether this floor is above the bottom one, with no exit door: the way out is off the balcony.
  final bool Function() _upstairs;

  final Node _parent;

  /// The top of whatever is underfoot at (x, z) for feet at `y`: the floor, a step, the street.
  final double Function(double x, double z, double y) _ground;
  final void Function(double x, double y, double z) _footstep;

  /// It has got up from `deskId`, so the seat is free to see.
  final void Function(String deskId) _onUp;

  List<_Leaver> _leavers = [];
  List<_Closing> _laptops = [];

  /// Takes over a worker's model and laptop the moment it's sent home from [desk].
  void add(Worker model, LeavingLaptop laptop, LeavingDesk desk) {
    // Where it sits, in the space it walks out in (the parent's, not the engine's mirrored world).
    final local = vm.Matrix4.inverted(_parent.globalTransform) * model.root.globalTransform as vm.Matrix4;
    final seat = local.getTranslation();
    final scale = local.getColumn(0).xyz.length;
    model.root.parent?.remove(model.root);
    _parent.add(model.root);
    // On the seat it faces the desk: the seat anchor is turned round from the desk's own rotation.
    final yaw = desk.def.rotY + math.pi;
    model.root.localTransform = vm.Matrix4.compose(seat, euler(0, yaw), vm.Vector3.all(scale));
    model.leave(farewells[_rng.nextInt(farewells.length)]);
    final up = _upstairs();
    _leavers.add(
      _Leaver(
        model: model,
        deskId: desk.def.id,
        chute: up ? _Chute(_canopies[_rng.nextInt(_canopies.length)]) : null,
        way: up ? wayToBalcony(desk.def) : wayHome(desk.def),
        seat: seat,
        heading: yaw,
        chair: desk.def.beanbag ? null : desk.chair,
        scale: scale,
      ),
    );
    _laptops.add(_Closing(laptop, desk.def.id));
  }

  /// Whether someone sent home from [deskId] is still sitting there, packing up.
  bool seated(String deskId) => _leavers.any((l) => l.deskId == deskId && l.next == 0);

  /// Someone new sat down at [deskId]: the old laptop goes at once, and whoever was packing there gets up.
  void vacate(String deskId) {
    for (final c in _laptops) {
      if (c.deskId == deskId) _dropLaptop(c);
    }
    _laptops = _laptops.where((c) => c.deskId != deskId).toList();
    for (final l in _leavers) {
      if (l.deskId != deskId) continue;
      l.t = math.max(l.t, _pack + _hop);
      l.chair = null;
    }
  }

  /// Off to another floor: nobody from this one is left walking out.
  void clear() {
    final laptops = _laptops, leavers = _leavers;
    _laptops = [];
    _leavers = [];
    for (final c in laptops) {
      _dropLaptop(c);
    }
    for (final l in leavers) {
      _drop(l);
    }
  }

  /// Where each of them is, for the doors to open.
  List<vm.Vector3> positions() => [for (final l in _leavers) l.model.root.position];

  void update(double dt, double t) {
    _laptops = _laptops.where((c) {
      if (!c.laptop.shut(dt)) return true;
      c.gone = math.min(1, c.gone + dt / _laptopGone);
      c.laptop.root.scale = vm.Vector3.all(math.max(0.001, 1 - c.gone * c.gone));
      if (c.gone < 1) return true;
      _dropLaptop(c);
      return false;
    }).toList();
    _leavers = _leavers.where((l) {
      final here = _step(l, dt);
      l.model.update(dt, t);
      if (!here) _drop(l);
      return here;
    }).toList();
  }

  /// Moves one along; false once it's gone.
  bool _step(_Leaver l, double dt) {
    l.t += dt;
    final root = l.model.root;
    var pos = root.position;
    l.model.walking = false;
    final chair = l.chair;
    if (chair != null && l.spin != 0) {
      chair.rotation = chair.rotation * vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), l.spin * dt);
      l.spin *= math.exp(-dt * 1.4);
      if (l.spin.abs() < 0.05) l.spin = 0;
    }
    void pose() => root.localTransform = vm.Matrix4.compose(
      pos,
      euler(l.rotX, l.yaw, l.rotZ),
      vm.Vector3.all(math.max(0.001, l.scale * (1 - l.gone * l.gone))),
    );
    if (l.t < _pack) return true;
    final (x0, z0) = l.way[0];
    if (l.next == 0) {
      final floor = _ground(x0, z0, l.seat.y) - _feet;
      if (l.t < _pack + _hop) {
        // Down off the seat in a little arc, turning round on the way to face where it's going.
        final p = (l.t - _pack) / _hop;
        if (chair != null && l.spin == 0) l.spin = (_rng.nextBool() ? -1 : 1) * (5 + _rng.nextDouble() * 3);
        pos = vm.Vector3(
          _lerp(l.seat.x, x0, p),
          _lerp(l.seat.y, floor, p) + math.sin(p * math.pi) * 0.35,
          _lerp(l.seat.z, z0, p),
        );
        final (x1, z1) = l.way[1];
        l.yaw += _wrap(math.atan2(x1 - x0, z1 - z0) - l.yaw) * math.min(1, dt * 7);
        pose();
        return true;
      }
      pos = vm.Vector3(x0, floor, z0);
      l.next = 1;
      _onUp(l.deskId);
    }
    final c = l.chute;
    if (c != null && c.phase != _ChutePhase.walk && c.phase != _ChutePhase.off) {
      final here = _jump(l, c, dt, pos);
      pose();
      return here;
    }
    var move = _pace * dt;
    var x = pos.x, z = pos.z;
    while (move > 0 && l.next < l.way.length) {
      final (wx, wz) = l.way[l.next];
      final dx = wx - x, dz = wz - z;
      final d = math.sqrt(dx * dx + dz * dz);
      if (d > 1e-4) l.heading = math.atan2(dx, dz);
      if (d <= move) {
        x = wx;
        z = wz;
        move -= d;
        l.next++;
      } else {
        x += dx / d * move;
        z += dz / d * move;
        move = 0;
      }
    }
    // Down the steps a stair at a time.
    final g = _ground(x, z, pos.y + _feet) - _feet;
    pos = vm.Vector3(x, pos.y + (g - pos.y) * math.min(1, dt * 14), z);
    l.yaw += _wrap(l.heading - l.yaw) * math.min(1, dt * 8);
    if (l.next < l.way.length) {
      l.model.walking = true;
      l.stepIn -= dt;
      if (l.stepIn <= 0) {
        l.stepIn += math.pi / 9;
        _footstep(pos.x, pos.y, pos.z);
      }
      pose();
      return true;
    }
    if (c?.phase == _ChutePhase.walk) {
      // At the railing: up and over it.
      c!
        ..phase = _ChutePhase.climb
        ..t = 0
        ..from = pos.clone();
      pose();
      return true;
    }
    // Off down the sidewalk: gone.
    l.gone = math.min(1, l.gone + dt / _gone);
    pose();
    return l.gone < 1;
  }

  /// Over the balcony railing and down by parachute, then onto its feet on the lot out front. Moves
  /// [pos] (the root's position, which the caller poses).
  bool _jump(_Leaver l, _Chute c, double dt, vm.Vector3 pos) {
    c.t += dt;
    void turn(double to, double rate) => l.yaw += _wrap(to - l.yaw) * math.min(1, dt * rate);
    switch (c.phase) {
      case _ChutePhase.climb:
        // Up onto the top rail in a little hop, turning to face out over the street.
        final p = math.min(1.0, c.t / _climbUp);
        final e = p * p * (3 - 2 * p);
        pos.setValues(
          c.from.x,
          _lerp(c.from.y, Parachute.railTop - _feet, e) + math.sin(p * math.pi) * 0.35,
          _lerp(c.from.z, Balcony.maxZ - 0.06, e),
        );
        turn(0, 8);
        if (p < 1) return true;
        c
          ..phase = _ChutePhase.teeter
          ..t = 0;
        l.model.say(jumps[_rng.nextInt(jumps.length)]);
        return true;
      case _ChutePhase.teeter:
        // A wobble up there, then the leap.
        l.rotZ = math.sin(c.t * 11) * 0.1 * (1 - c.t / _teeter);
        turn(0, 8);
        if (c.t < _teeter) return true;
        l.rotZ = 0;
        c
          ..phase = _ChutePhase.fall
          ..t = 0
          ..vel = vm.Vector3(0, _leapUp, _leapOut);
        return true;
      case _ChutePhase.fall:
        c.vel.y -= _gravity * dt;
        pos.add(c.vel * dt);
        // Tumbling forward a little on the way down.
        l.rotX = math.min(0.6, c.t * 0.9);
        if (c.t < _freefall) return true;
        // The chute pops open, and it'll circle down onto a spot out on the lot.
        final chute = _parachute(c.color);
        chute.group.scale = vm.Vector3.all(0.05);
        l.model.root.add(chute.group);
        c.canopy = chute;
        final (e0, e1) = Parachute.east;
        final x = pos.x + e0 + _rng.nextDouble() * (e1 - e0);
        final z = pos.z + Parachute.out;
        c.land = vm.Vector3(x, _ground(x, z, pos.y) - _feet, z);
        c.radius = math.sqrt(math.pow(pos.x - x, 2) + math.pow(pos.z - z, 2));
        c.angle = math.atan2(pos.x - x, pos.z - z);
        c.height = math.max(0.1, pos.y - c.land.y);
        c
          ..phase = _ChutePhase.glide
          ..t = 0;
        return true;
      case _ChutePhase.glide:
        final canopy = c.canopy!;
        // Open with a pop that overshoots a little, then swaying under it on the way down.
        final p = math.min(1.0, c.t / _pop);
        final u = p - 1;
        canopy.group
          ..scale = vm.Vector3.all(math.max(0.05, 1 + 2.7 * u * u * u + 1.7 * u * u))
          ..rotation = euler(0, 0, math.sin(c.t * 1.9) * 0.08);
        l.rotX *= math.exp(-dt * 4);
        final h = pos.y - c.land.y;
        final sink = (h / _sinkPer).clamp(_sinkMin, _sinkMax);
        c.vel.y += (-sink - c.vel.y) * math.min(1, dt * 4);
        pos.y += c.vel.y * dt;
        // Round and round, closing in on the spot as it gets lower.
        c.angle += _turn * dt;
        final r = c.radius * (h / c.height).clamp(0.0, 1.0);
        final k = math.min(1.0, dt * 3);
        final dx = (c.land.x + math.sin(c.angle) * r - pos.x) * k;
        final dz = (c.land.z + math.cos(c.angle) * r - pos.z) * k;
        pos.x += dx;
        pos.z += dz;
        if (math.sqrt(dx * dx + dz * dz) > 1e-4) l.heading = math.atan2(dx, dz);
        turn(l.heading, 3);
        if (pos.y > c.land.y) return true;
        // Down, with a thump.
        pos.y = c.land.y;
        l.rotX = 0;
        _footstep(pos.x, pos.y, pos.z);
        c
          ..phase = _ChutePhase.down
          ..t = 0;
        return true;
      case _ChutePhase.down:
        // On the ground: the chute sags down behind it and is bundled away, and off it goes.
        final canopy = c.canopy!;
        final p = math.min(1.0, c.t / _crumple);
        final s = math.max(0.001, 1 - math.pow(math.max(0, (p - 0.55) / 0.45), 2).toDouble());
        canopy.group
          ..rotation = euler(-1.35 * math.min(1, p * 1.6), 0)
          ..scale = vm.Vector3.all(s);
        canopy.dome.scale = vm.Vector3(1, 0.62 * (1 - 0.65 * p), 1);
        if (p < 1) return true;
        _dropChute(c);
        c.phase = _ChutePhase.off;
        l.way = walkOff((pos.x, pos.z));
        l.next = 1;
        return true;
      case _ChutePhase.walk || _ChutePhase.off:
        return true;
    }
  }

  void _dropChute(_Chute c) {
    c.canopy?.group.detach();
    c.canopy = null;
  }

  void _drop(_Leaver l) {
    if (l.chute != null) _dropChute(l.chute!);
    if (l.next == 0) _onUp(l.deskId);
    l.model.root.parent?.remove(l.model.root);
    l.model.dispose();
  }

  void _dropLaptop(_Closing c) {
    c.laptop.root.parent?.remove(c.laptop.root);
    c.laptop.dispose();
  }
}
