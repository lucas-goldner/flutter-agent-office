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

import 'package:office_shared/layout.dart' show DeskDef;
import 'package:office_shared/nav.dart';
import 'character.dart';
import 'geo.dart';

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

class _Leaver {
  _Leaver({
    required this.model,
    required this.deskId,
    required this.way,
    required this.seat,
    required this.heading,
    required this.chair,
    required this.scale,
  });

  final Worker model;
  final String deskId;
  final List<Pt> way;

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
/// the exit door, down the steps and off along the sidewalk, where it's gone.
class Departures {
  Departures(this._parent, this._ground, this._footstep, this._onUp);

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
    _leavers.add(
      _Leaver(
        model: model,
        deskId: desk.def.id,
        way: wayHome(desk.def),
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
      euler(0, l.yaw),
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
        pos = vm.Vector3(_lerp(l.seat.x, x0, p), _lerp(l.seat.y, floor, p) + math.sin(p * math.pi) * 0.35, _lerp(l.seat.z, z0, p));
        final (x1, z1) = l.way[1];
        l.yaw += _wrap(math.atan2(x1 - x0, z1 - z0) - l.yaw) * math.min(1, dt * 7);
        pose();
        return true;
      }
      pos = vm.Vector3(x0, floor, z0);
      l.next = 1;
      _onUp(l.deskId);
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
    // Off down the sidewalk: gone.
    l.gone = math.min(1, l.gone + dt / _gone);
    pose();
    return l.gone < 1;
  }

  void _drop(_Leaver l) {
    if (l.next == 0) _onUp(l.deskId);
    l.model.root.parent?.remove(l.model.root);
    l.model.dispose();
  }

  void _dropLaptop(_Closing c) {
    c.laptop.root.parent?.remove(c.laptop.root);
    c.laptop.dispose();
  }
}
