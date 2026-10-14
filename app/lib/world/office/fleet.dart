// The floor's cars (features/cars/world.ts's Fleet; see shared garage.dart's `cars`), down on the street
// under the floor you're on: in their spots, where somebody's driving them or where they were left.
// The poses, the boxes you bump into and stand on, and what you use are here; the models (cars.dart)
// follow them when there are any (the tests drive cars that aren't drawn).

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/garage.dart';
import 'package:office_shared/layout.dart' show Floor, slab, streetY, wallT;
import 'package:vector_math/vector_math.dart' as vm;

import '../../state/cars.dart' show CarSlot;
import '../collider.dart';
import 'cars.dart';
import 'geo.dart';

/// A car's pose as it's drawn: changed in place as it moves (shared [CarPose] is a value).
class LivePose {
  LivePose(this.x, this.z, this.rotY, [this.speed = 0, this.steer = 0]);
  double x, z, rotY, speed, steer;

  CarPose get value => CarPose(x: x, z: z, rotY: rotY, speed: speed, steer: steer);

  ({double x, double z, double rotY}) get at => (x: x, z: z, rotY: rotY);

  void set(CarPose p) {
    x = p.x;
    z = p.z;
    rotY = p.rotY;
    speed = p.speed;
    steer = p.steer;
  }
}

/// One of the floor's cars, as it's drawn here.
class CarView {
  CarView(this.index, this.def, this.model, this.colliders, this.interactable)
    : pose = LivePose(def.x, def.z, def.rotY);
  final int index;
  final CarDef def;

  /// Its model, if it's drawn.
  final CarModel? model;

  /// Where it's drawn now: the page's own driving, or the office's word smoothed out.
  final LivePose pose;

  /// Somebody's in it: the roof's off.
  bool occupied = false;

  /// What you bump into and stand on: along its body (turned, it takes a few boxes), and its roof.
  final List<Collider> colliders;
  final Interactable interactable;
}

/// Boxes along the car's body, for colliders: a car turned off square takes more than one.
const int _slices = 3;

/// Whether the whole car is in under the building (the office's floor over it), rather than out on the lot or the street.
bool underneath(LivePose p) {
  for (final (sx, sz) in const [(1, 1), (1, -1), (-1, 1), (-1, -1)]) {
    final c = carPoint(p.at, sx * Car.width / 2, sz * Car.length / 2);
    if (!(c.x > Floor.minX - wallT &&
        c.x < Floor.maxX + wallT &&
        c.z > Floor.minZ - wallT &&
        c.z < Floor.maxZ + wallT)) {
      return false;
    }
  }
  return true;
}

class Fleet {
  /// [all] is the office's colliders: the cars' go in with them. [build] makes a car's model (none in tests).
  Fleet(this._all, List<Interactable> interactables, {CarModel Function(CarDef def)? build}) {
    for (final (index, def) in cars.indexed) {
      final model = build?.call(def);
      final interactable = Interactable(
        kind: InteractKind.car,
        x: def.x,
        z: def.z,
        y: _street,
        radius: 3.2,
        car: index,
      );
      if (model != null) {
        tagInteract(model.root, interactable);
        group.add(model.root);
      }
      interactables.add(interactable);
      final colliders = [
        for (var i = 0; i <= _slices; i++) Collider(minX: 0, maxX: 0, minZ: 0, maxZ: 0, top: 0, bottom: 0),
      ];
      _all.addAll(colliders);
      final v = CarView(index, def, model, colliders, interactable);
      views.add(v);
      _show(v);
    }
  }

  final Node group = Node(name: 'cars');
  final List<CarView> views = [];
  final List<Collider> _all;

  /// How far below the floor you're on the street is (see streetBelow).
  double _street = streetY;
  double get street => _street;

  /// The floor you're on is [street] above the street: the cars and everything about them are down there.
  void setStreet(double street) {
    _street = street;
    for (final v in views) {
      _show(v);
    }
  }

  /// Each frame: every car where the office says it is ([slots], smoothed out, and carried on a little
  /// the way it's going, since its driver said so, [at] being when each last did), but for the one
  /// you're in ([mine]) if you're driving it, which is where your own driving put it. The office doesn't
  /// tell you your own moves, so that goes back into [slots] for when you get out. [eye] is the camera
  /// (office space): from up in the office, the cars in under it aren't drawn at all.
  void update(
    double dt,
    List<CarSlot> slots,
    List<double> at,
    double now,
    ({int car, bool driving})? mine,
    vm.Vector3 eye,
  ) {
    final k = 1 - math.exp(-dt * 12);
    final indoors =
        eye.y > -slab && eye.x > Floor.minX && eye.x < Floor.maxX && eye.z > Floor.minZ && eye.z < Floor.maxZ;
    for (final v in views) {
      v.model?.root.visible = !indoors || !underneath(v.pose);
    }
    for (final v in views) {
      if (v.index >= slots.length) continue;
      final c = slots[v.index];
      final occupied = c.driver != null || c.passenger != null || v.index == mine?.car;
      if (occupied != v.occupied) {
        v.occupied = occupied;
        v.model?.top.visible = !occupied;
        v.model?.open.visible = occupied;
        _show(v);
      }
      final p = v.pose;
      if (v.index == mine?.car && mine!.driving) {
        c
          ..x = p.x
          ..z = p.z
          ..rotY = p.rotY
          ..speed = p.speed
          ..steer = p.steer;
        if (v.index < at.length) at[v.index] = now;
        continue;
      }
      // Where it'd be by now, going on as it was: at most a quarter of a second on.
      final since = v.index < at.length ? at[v.index] : now;
      final ahead = c.speed != 0 ? math.min(0.25, math.max(0.0, (now - since) / 1000)) * c.speed : 0.0;
      final x = c.x + math.sin(c.rotY) * ahead;
      final z = c.z + math.cos(c.rotY) * ahead;
      final far = math.sqrt(math.pow(x - p.x, 2) + math.pow(z - p.z, 2)) > 8;
      final turn = math.atan2(math.sin(c.rotY - p.rotY), math.cos(c.rotY - p.rotY));
      p.x = far ? x : p.x + (x - p.x) * k;
      p.z = far ? z : p.z + (z - p.z) * k;
      p.rotY = far ? c.rotY : p.rotY + turn * k;
      p.speed = c.speed;
      p.steer += (c.steer - p.steer) * k;
      _show(v);
    }
  }

  /// Every car straight to where the office says it is, not smoothed: a floor's cars as you arrive on it.
  void snap(List<CarSlot> slots) {
    for (final v in views) {
      if (v.index >= slots.length) continue;
      final c = slots[v.index];
      v.pose
        ..x = c.x
        ..z = c.z
        ..rotY = c.rotY
        ..speed = c.speed
        ..steer = c.steer;
      _show(v);
    }
  }

  /// Puts car [i] at [pose] (your own driving).
  void place(int i, CarPose pose) {
    if (i < 0 || i >= views.length) return;
    views[i].pose.set(pose);
    _show(views[i]);
  }

  /// Where someone sitting in [seat] of car [i] is: their feet (on the street; sitting lifts them) and the way they face.
  ({double x, double y, double z, double rotY})? seatAt(int i, CarSeat seat) {
    if (i < 0 || i >= views.length) return null;
    final v = views[i];
    final s = carSeats[seat]!;
    final at = carPoint(v.pose.at, s.x, s.z);
    return (x: at.x, y: _street, z: at.z, rotY: v.pose.rotY);
  }

  /// What a car bumps into on the street, besides the pavement's edge: whatever stands on it (the
  /// garage's columns and walls, street lamps, trees, the elevator, the other cars), but not car
  /// [except]'s own boxes. With [near], only what's within its r of (x, z): out on the scenic loop
  /// there are trees by the thousand, nearly all of them nowhere near you.
  List<GroundBox> solids(int except, [({double x, double z, double r})? near]) {
    final own = except >= 0 && except < views.length ? views[except].colliders : const <Collider>[];
    final out = <GroundBox>[];
    for (final c in _all) {
      // Not the ground itself (the lawn, the lots), nor anything overhead.
      if ((c.bottom ?? 0) > _street + 1 || c.top < _street + 0.3 || own.contains(c)) continue;
      if (near != null &&
          (c.minX > near.x + near.r ||
              c.maxX < near.x - near.r ||
              c.minZ > near.z + near.r ||
              c.maxZ < near.z - near.r)) {
        continue;
      }
      out.add(GroundBox(minX: c.minX, maxX: c.maxX, minZ: c.minZ, maxZ: c.maxZ));
    }
    return out;
  }

  /// Out of the way of a car that's come at you where you stand ([pos], on the street): shoved out of
  /// its side, or its nose or tail if that's nearer, and off to the side from there, so it doesn't push
  /// you along in front of it. Returns how fast it was going, or 0.
  double shove(vm.Vector3 pos, int? except) {
    if ((pos.y - _street).abs() > 0.4) return 0;
    const r = 0.32;
    for (final v in views) {
      if (v.index == except) continue;
      final p = v.pose;
      final s = math.sin(p.rotY), c = math.cos(p.rotY);
      final dx = pos.x - p.x, dz = pos.z - p.z;
      // Where you are in the car's own frame: across it (+ left), and along it (+ ahead).
      final lx = dx * c - dz * s;
      final lz = dx * s + dz * c;
      const hx = Car.width / 2 + r;
      const hz = Car.length / 2 + r;
      if (lx.abs() >= hx || lz.abs() >= hz) continue;
      final side = hx - lx.abs();
      final end = hz - lz.abs();
      final aside = lx == 0 ? 1.0 : lx.sign;
      final out = side < end
          ? (x: aside * (hx + 0.01), z: lz)
          : (x: lx + aside * math.min(side, 0.08), z: (lz == 0 ? 1.0 : lz.sign) * (hz + 0.01));
      final at = carPoint(p.at, out.x, out.z);
      pos.x = at.x;
      pos.z = at.z;
      return p.speed.abs();
    }
    return 0;
  }

  /// Draws car [v] where its pose says, and moves its boxes and its interactable along with it.
  void _show(CarView v) {
    final p = v.pose;
    final m = v.model;
    if (m != null) {
      // The cars hang under the ground, which goes down with the street (see Office.setLevel).
      m.root.position = vm.Vector3(p.x, streetY, p.z);
      m.root.rotation = yaw(p.rotY);
      for (final w in m.wheels) {
        w.rotation = yaw(p.steer);
      }
    }
    final s = math.sin(p.rotY).abs();
    final c = math.cos(p.rotY).abs();
    const hx = Car.width / 2 - 0.08;
    const len = (Car.length - 0.16) / _slices;
    // Along the body a slice at a time, each slice's box round it as turned.
    for (var i = 0; i < _slices; i++) {
      final mid = carPoint(p.at, 0, -Car.length / 2 + 0.08 + len * (i + 0.5));
      final ex = c * hx + s * len / 2;
      final ez = s * hx + c * len / 2;
      _set(v.colliders[i], mid.x - ex, mid.x + ex, mid.z - ez, mid.z + ez, _street + Car.body);
    }
    // The roof, over the cabin; with it off, only the body's there to stand on.
    final roof = carPoint(p.at, 0, -0.6);
    final rx = c * 0.6 + s * 0.7;
    final rz = s * 0.6 + c * 0.7;
    _set(
      v.colliders[_slices],
      roof.x - rx,
      roof.x + rx,
      roof.z - rz,
      roof.z + rz,
      _street + (v.occupied ? Car.body : Car.roof),
    );
    v.interactable
      ..x = p.x
      ..z = p.z
      ..y = _street;
  }

  void _set(Collider c, double minX, double maxX, double minZ, double maxZ, double top) {
    c
      ..minX = minX
      ..maxX = maxX
      ..minZ = minZ
      ..maxZ = maxZ
      ..bottom = _street
      ..top = top;
  }
}
