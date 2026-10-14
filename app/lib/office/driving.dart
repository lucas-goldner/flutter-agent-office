// Driving the cars in the garage (features/cars/controller.ts): E at one gets you in (behind the wheel,
// or beside whoever's there), and it takes hold of you (PlayerController.rig) until you get out. The
// driver's page runs the car (shared garage.dart) and tells the office where it's got to; everyone
// else's follows it.

import 'dart:math' as math;

import 'package:office_shared/garage.dart';
import 'package:office_shared/scenic.dart' show loopPaved, nearLoop;

import '../world/office/fleet.dart';
import '../world/player.dart';

/// What the driver tells the office and the page.
class DriveHooks {
  DriveHooks({required this.moved, required this.bump});

  /// The car you're driving has got to [pose]: tell the office, for everyone else on the floor.
  final void Function(int car, CarPose pose) moved;

  /// You ran into something at [speed] m/s, at (x, z).
  final void Function(({double x, double z}) at, double speed) bump;
}

/// How often the office hears where your car is, at most (seconds).
const double _sendEvery = 0.066;

/// How soon after one crunch another can sound (seconds).
const double _bumpEvery = 0.35;

/// The longest step a car takes in one go (m), so it never jumps a lamp post between two frames.
const double _step = 0.25;

double _wrap(double a) => math.atan2(math.sin(a), math.cos(a));

CarPose _with(CarPose p, {double? x, double? z, double? rotY, double? speed, double? steer}) =>
    CarPose(x: x ?? p.x, z: z ?? p.z, rotY: rotY ?? p.rotY, speed: speed ?? p.speed, steer: steer ?? p.steer);

class Driver {
  Driver(this.player, this.fleet, this.hooks);

  final PlayerController player;
  final Fleet fleet;
  final DriveHooks hooks;

  /// The car you're in (its place in shared `cars`), and your seat; null on your feet.
  int? car;
  CarSeat? seat;

  /// How hard you're on the gas (-1 in reverse), for the engine.
  double gas = 0;

  /// Seconds behind the wheel (or beside it), for how often things happen.
  double _clock = 0;
  ({double at, double x, double z, double rotY, double speed, double steer}) _sent = (
    at: double.negativeInfinity,
    x: 0,
    z: 0,
    rotY: 0,
    speed: 0,
    steer: 0,
  );
  double _bumpedAt = double.negativeInfinity;

  /// The way the car pointed last frame, to turn a first-person view along with it.
  double _yaw = 0;

  /// How the third-person camera was before you got in: it pulls back to see the car.
  ({double dist, double pitch})? _camWas;

  bool get active => car != null;

  /// Behind the wheel, rather than beside it.
  bool get driving => seat == CarSeat.driver;

  /// The car you're in, as it's drawn.
  LivePose? get pose => car == null ? null : fleet.views[car!].pose;

  /// Gets into [seat] of car [i], looking out over its hood.
  void enter(int i, CarSeat seat) {
    if (active || i < 0 || i >= fleet.views.length) return;
    final v = fleet.views[i];
    car = i;
    this.seat = seat;
    gas = 0;
    final p = player
      ..stopWalking()
      ..moving = false
      ..vy = 0;
    _yaw = v.pose.rotY;
    if (p.view == ViewMode.first) {
      p
        ..camYaw = v.pose.rotY + math.pi
        ..lookPitch = -0.12;
    } else {
      _camWas = (dist: p.camDist, pitch: p.camPitch);
      p
        ..camDist = math.max(p.camDist, 9)
        ..camPitch = math.min(p.camPitch, 0.32)
        ..camYaw = v.pose.rotY + math.pi;
    }
    p
      ..rig = _stepIn
      ..riding = true;
    _sit(0);
  }

  /// Where you'd be getting out: by your own door, else the other one, else behind the car or in front
  /// of it. Null if there's no room anywhere (or you're not in a car).
  ({double x, double y, double z})? wayOut() {
    final i = car, s0 = seat;
    if (i == null || s0 == null) return null;
    final pose = fleet.views[i].pose;
    final y = fleet.seatAt(i, s0)!.y;
    final s = carSeats[s0]!;
    // Far enough out to clear the car's boxes at any angle (turned, they stick out past its sides).
    const out = Car.width / 2 + 0.8;
    final side = s.x.sign;
    for (final (lx, lz) in [
      (side * out, s.z),
      (side * out, 0.9),
      (-side * out, s.z),
      (0.0, -Car.length / 2 - 0.6),
      (0.0, Car.length / 2 + 0.6),
    ]) {
      final q = carPoint(pose.at, lx, lz);
      if (player.fits(q.x, q.z, y)) return (x: q.x, y: y, z: q.z);
    }
    return null;
  }

  /// Out onto your feet beside the car (see [wayOut]). False if there's no room, unless [anyway] (you
  /// stand up where you sat).
  bool leave([bool anyway = false]) {
    final pose = this.pose;
    if (pose == null) return true;
    final rotY = pose.rotY;
    final at = wayOut();
    if (at == null && !anyway) return false;
    drop();
    final p = player;
    if (at != null) p.pos.setValues(at.x, at.y, at.z);
    p
      ..facing = rotY
      ..camYaw = rotY + math.pi
      ..lookPitch = -0.08;
    return true;
  }

  /// Lets go of the car where you are (something else is moving you: another floor, a desk): driving, it
  /// stops there.
  void drop() {
    final i = car;
    if (i == null) return;
    if (driving) {
      final pose = _with(fleet.views[i].pose.value, speed: 0);
      fleet.place(i, pose);
      hooks.moved(i, pose);
    }
    final p = player
      ..rig = null
      ..riding = false;
    final was = _camWas;
    if (was != null) {
      p
        ..camDist = was.dist
        ..camPitch = was.pitch;
      _camWas = null;
    }
    car = null;
    seat = null;
    gas = 0;
  }

  /// Each frame in the car: drive it (behind the wheel), and sit in your seat wherever it's got to.
  void _stepIn(double dt) {
    final i = car;
    if (i == null) return;
    _clock += dt;
    if (driving) {
      final k = player.input;
      final pedals = (
        gas: (k.forward ? 1.0 : 0.0) - (k.back ? 1.0 : 0.0),
        turn: (k.left ? 1.0 : 0.0) - (k.right ? 1.0 : 0.0),
        brake: k.jump,
      );
      gas = pedals.gas;
      final from = fleet.views[i].pose.value;
      final reach = Car.length + from.speed.abs() * dt + 1;
      final pose = _move(from, pedals, dt, fleet.solids(i, (x: from.x, z: from.z, r: reach)));
      fleet.place(i, pose);
      _send(i, pose);
    }
    _sit(dt);
  }

  /// The car [dt] on from [from]: in short steps, stopping at whatever's in the way. At an angle to it,
  /// the car slides along it (along the scenic loop's edge, the way the road curves); head on, it
  /// bounces back off.
  CarPose _move(CarPose from, Pedals pedals, double dt, List<GroundBox> solids) {
    final n = math.max(1, (from.speed.abs() * dt / _step).ceil());
    final h = dt / n;
    // Already in something (someone parked on top of you): drive out of it any way you like.
    final stuck = !carFits(poseOf(from), solids);
    var pose = from;
    for (var i = 0; i < n; i++) {
      final next = drive(pose, pedals, h);
      if (stuck ? onPavement(poseOf(next)) : carFits(poseOf(next), solids)) {
        pose = next;
        continue;
      }
      // Sliding keeps only the part of the move along what's in the way (the town's things are all
      // square to the street; the loop's edge goes the way the road does), and only that much of the
      // speed; the car swings round to run along it. `off` is the way off what it's run into.
      final dx = next.x - pose.x;
      final dz = next.z - pose.z;
      final hyp = math.sqrt(dx * dx + dz * dz);
      final want = hyp == 0 ? 1.0 : hyp;
      final slides = <({CarPose to, double keep, double heading, ({double x, double z}) off})>[
        (
          to: _with(next, z: pose.z),
          keep: dx.abs() / want,
          heading: dx.sign * (math.pi / 2),
          off: (x: 0.0, z: -dz.sign),
        ),
        (
          to: _with(next, x: pose.x),
          keep: dz.abs() / want,
          heading: dz > 0 ? 0.0 : math.pi,
          off: (x: -dx.sign, z: 0.0),
        ),
      ].where((q) => q.keep > 0.25 && carFits(poseOf(q.to), solids)).toList();
      final road = nearLoop(pose.x, pose.z);
      if (road != null && road.off < loopPaved + 2) {
        // Along the road here, and in off its edge toward the middle: round the outside of a bend,
        // going straight on along it runs a little off, so it's nudged back in as it goes.
        final run = dx * road.tx + dz * road.tz;
        final inward = road.off > 1e-6
            ? (x: (road.x - pose.x) / road.off, z: (road.z - pose.z) / road.off)
            : (x: 0.0, z: 0.0);
        final base = _with(next, x: pose.x + road.tx * run, z: pose.z + road.tz * run);
        CarPose? to;
        for (final d in const [0.0, 0.04, 0.12, 0.25]) {
          final q = _with(base, x: base.x + inward.x * d, z: base.z + inward.z * d);
          if (carFits(poseOf(q), solids)) {
            to = q;
            break;
          }
        }
        final keep = run.abs() / want;
        if (to != null && keep > 0.25) {
          slides.add((to: to, keep: keep, heading: math.atan2(road.tx * run.sign, road.tz * run.sign), off: inward));
        }
      }
      slides.sort((a, b) => b.keep.compareTo(a.keep));
      final along = slides.firstOrNull;
      if (along != null) {
        _bumped(pose, next.speed.abs() * (1 - along.keep));
        final slid = _with(along.to, speed: next.speed * along.keep);
        // Backing along it, it's the tail that leads.
        final heading = along.heading + (next.speed < 0 ? math.pi : 0);
        final rotY = _wrap(slid.rotY + _wrap(heading - slid.rotY) * 0.3);
        // Swinging round about its middle takes its far end into it: a nudge off it, the way it came.
        final off = along.off;
        CarPose? turned;
        for (final d in const [0.0, 0.03, 0.08]) {
          final q = _with(slid, rotY: rotY, x: slid.x + off.x * d, z: slid.z + off.z * d);
          if (carFits(poseOf(q), solids)) {
            turned = q;
            break;
          }
        }
        pose = turned ?? slid;
        continue;
      }
      _bumped(pose, pose.speed.abs());
      pose = _with(pose, steer: next.steer, speed: -pose.speed * 0.3);
      break;
    }
    return pose;
  }

  /// Ran into something, losing [speed] m/s of the car's: a crunch, if it's enough to hear.
  void _bumped(CarPose pose, double speed) {
    if (speed < 2 || _clock - _bumpedAt < _bumpEvery) return;
    _bumpedAt = _clock;
    hooks.bump(carPoint(poseOf(pose), 0, pose.speed.sign * Car.length / 2), speed);
  }

  /// Tells the office where the car is, every so often while it's going (and once more when it stops).
  void _send(int i, CarPose pose) {
    final s = _sent;
    final changed =
        (pose.x - s.x).abs() + (pose.z - s.z).abs() > 0.01 ||
        _wrap(pose.rotY - s.rotY).abs() > 0.004 ||
        pose.speed != s.speed ||
        (pose.steer - s.steer).abs() > 0.02;
    if (!changed || _clock - s.at < _sendEvery) return;
    _sent = (at: _clock, x: pose.x, z: pose.z, rotY: pose.rotY, speed: pose.speed, steer: pose.steer);
    hooks.moved(i, pose);
  }

  /// You in your seat, wherever the car's got to. In first person you look round from it, turning as it
  /// turns; in third, the camera swings round behind it as it goes.
  void _sit(double dt) {
    final p = player;
    final at = fleet.seatAt(car!, seat!)!;
    p.pos.setValues(at.x, at.y, at.z);
    p
      ..facing = at.rotY
      ..moving = false;
    final turned = _wrap(at.rotY - _yaw);
    _yaw = at.rotY;
    if (p.view == ViewMode.first) {
      p.camYaw += turned;
    } else {
      final speed = fleet.views[car!].pose.speed.abs();
      final k = math.min(1.0, dt * 2.5 * math.min(1.0, speed / 4));
      p.camYaw += _wrap(at.rotY + math.pi - p.camYaw) * k;
    }
  }
}
