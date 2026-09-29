// Golf off the balcony (world/golf.ts): the tee out there (a square of turf, a ball on a tee, a bag of
// clubs), the hole across the street it's hit at (a green with a flag on it, a fairway up to it,
// bunkers), and the balls on their way. A shot is only a heading, a loft and how hard it was hit;
// where it goes from there is worked out the same way on every screen ([fly]), so everyone on the
// floor sees the same ball land in the same place.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:office_shared/layout.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'collider.dart';
import 'label_widgets.dart';
import 'labels.dart';
import 'office/geo.dart';
import 'office/outside.dart' show neighbourBoxes;
import 'office/parts.dart';
import 'text.dart';
import 'toon.dart';

/// A shot: its heading (0 is straight out, south, +z; it turns toward +x), how steeply it leaves the
/// club, and how hard it's hit (0–1).
typedef Shot = ({double yaw, double loft, double power});

double _deg(double d) => d * math.pi / 180;
double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);
double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// The lofts you can pick, in radians. Much under 30° and the ball won't clear the railing.
final double loftMin = _deg(20);
final double loftMax = _deg(60);

/// How far either side of straight out you can aim.
const double aimMax = 1.2;

/// How fast the ball leaves the club at full power, in m/s.
const double _speed = 30;

/// The ball's radius. A real one's is 2.1 cm; this one's bigger, so it can be seen from the tee.
const double golfBallR = 0.05;

/// The turf mat, and the tee on it.
const double _matH = 0.03;
const double _teeH = 0.015;

/// The ball on the tee, ready to hit.
final vm.Vector3 teeBall = vm.Vector3(GolfTee.ball.x, _matH + _teeH + golfBallR, GolfTee.ball.z);

/// The golfer stands this far from the ball, square to the line.
const double _stance = 0.57;

/// Where the golfer stands for a shot heading [yaw], and which way they face: across the line, with
/// the hole on their left.
({double x, double z, double facing}) stance(double yaw) => (
  x: GolfTee.ball.x + math.cos(yaw) * _stance,
  z: GolfTee.ball.z - math.sin(yaw) * _stance,
  facing: yaw - math.pi / 2,
);

/// Which way from the tee the pin is.
final double pinYaw = math.atan2(GolfHole.x - GolfTee.ball.x, GolfHole.z - GolfTee.ball.z);

/// From the tee to the pin, along the ground.
final double pinDistance = _hypot(GolfHole.x - GolfTee.ball.x, GolfHole.z - GolfTee.ball.z);

// ---- The course -------------------------------------------------------------------------------------

/// The green's collar of longer grass.
const double _fringe = 0.7;

/// The fairway starts past the far sidewalk.
const double _fairwayZ0 = Road.maxZ + 2.5;

/// Sand traps round the green: (x, z, radius). The first two make one kidney-shaped trap in front.
const List<(double, double, double)> _bunkers = [
  (GolfHole.x - 5.4, GolfHole.z - 4.4, 1.7),
  (GolfHole.x - 3.7, GolfHole.z - 5.7, 1.25),
  (GolfHole.x + 5.6, GolfHole.z + 3.2, 1.6),
];

/// How far from the pin a ball drops in: rolling in slower than [_cupSpeed], or landing straight in.
const double _cup = 0.12;
const double _cupSpeed = 1.8;

/// The flagstick, taller than a real one so it shows up from the balcony.
const double _stick = 3.4;

/// What a ball can come down on. `below` is a balcony further down the building; `lost` is off out of the world.
enum Lie { green, fringe, fairway, rough, sand, road, deck, roof, below, lost }

/// How each surface takes a ball: how much of its fall it bounces back up, how much speed along it
/// keeps on a bounce, and how fast it slows a rolling ball (m/s²).
const Map<Lie, ({double bounce, double keep, double roll})> _ground = {
  Lie.green: (bounce: 0.28, keep: 0.45, roll: 2.5),
  Lie.fringe: (bounce: 0.28, keep: 0.45, roll: 3.2),
  Lie.fairway: (bounce: 0.32, keep: 0.55, roll: 2.4),
  Lie.rough: (bounce: 0.22, keep: 0.35, roll: 5.5),
  Lie.sand: (bounce: 0.04, keep: 0.1, roll: 20),
  Lie.road: (bounce: 0.5, keep: 0.8, roll: 1.1),
  Lie.deck: (bounce: 0.42, keep: 0.7, roll: 1.8),
  Lie.roof: (bounce: 0.42, keep: 0.7, roll: 1.8),
  Lie.below: (bounce: 0, keep: 0, roll: 99),
};

/// The building, walls included.
const _b = (minX: Floor.minX - wallT, maxX: Floor.maxX + wallT, minZ: Floor.minZ - wallT, maxZ: Floor.maxZ + wallT);

/// What's underfoot at (x, z) down on the street.
Lie lieAt(double x, double z) {
  for (final (bx, bz, r) in _bunkers) {
    if (_hypot(x - bx, z - bz) < r) return Lie.sand;
  }
  final d = _hypot(x - GolfHole.x, z - GolfHole.z);
  if (d < GolfHole.green) return Lie.green;
  if (d < GolfHole.green + _fringe) return Lie.fringe;
  if (x > GolfHole.fairway.$1 && x < GolfHole.fairway.$2 && z > _fairwayZ0 && z < GolfHole.z) return Lie.fairway;
  // The road and its sidewalks, the lot out front, the one beside the building, and the garage under it.
  if (z > Road.minZ - 2 && z < Road.maxZ + 2) return Lie.road;
  if (x.abs() < 30 && z > _b.minZ && z < Road.minZ - 2) return Lie.road;
  if (x > _b.maxX && x < _b.maxX + 12 && z > _b.minZ - 2 && z < _b.maxZ + 4) return Lie.road;
  return Lie.rough;
}

// ---- A ball on its way ------------------------------------------------------------------------------

/// Steps a second the flight's worked out in, and every how many of them the path keeps a point (60 a second).
const int _steps = 240;
const int _keep = 4;
const double _gravity = 9.81;

/// Air slows it a little.
const double _drag = 0.05;

/// Coming down slower than this, it stops bouncing and rolls.
const double _rollV = 1.2;

/// Longest a ball's followed.
const double _maxSeconds = 25;

/// The top of the balcony's railing, and the balcony inside it that a ball rattles round (its center, at least).
const double _railTop = 1.11;
const _inside = (
  minX: Balcony.minX + 0.12 + golfBallR,
  maxX: Balcony.maxX - 0.12 - golfBallR,
  minZ: Balcony.minZ + golfBallR,
  maxZ: Balcony.maxZ - 0.12 - golfBallR,
);

enum HitKind { bounce, rail, wall, cup }

class GolfHit {
  const GolfHit(this.t, this.kind, this.x, this.y, this.z, this.speed, [this.lie]);

  /// Seconds after the shot.
  final double t;
  final HitKind kind;
  final double x, y, z;

  /// How hard, in m/s.
  final double speed;
  final Lie? lie;
}

class Flight {
  Flight({
    required this.shot,
    required this.path,
    required this.hits,
    required this.seconds,
    required this.rest,
    required this.holed,
    required this.lie,
    required this.fromPin,
  });

  final Shot shot;

  /// Where the ball is, every 1/60 s from the moment it's hit: x, y, z.
  final Float32List path;
  final List<GolfHit> hits;

  /// From the hit until it stops.
  final double seconds;
  final vm.Vector3 rest;
  final bool holed;

  /// What it stopped on.
  final Lie lie;

  /// How far from the pin it stopped, or NaN if it isn't down on the street.
  final double fromPin;

  /// Where it is [t] seconds after the hit.
  vm.Vector3 at(double t) {
    final n = path.length ~/ 3;
    final i = _clamp(t, 0, seconds) * (_steps / _keep);
    final i0 = math.min(i.floor(), n - 1);
    final i1 = math.min(i0 + 1, n - 1);
    final k = i - i0;
    final p = path;
    return vm.Vector3(
      p[i0 * 3] + (p[i1 * 3] - p[i0 * 3]) * k,
      p[i0 * 3 + 1] + (p[i1 * 3 + 1] - p[i0 * 3 + 1]) * k,
      p[i0 * 3 + 2] + (p[i1 * 3 + 2] - p[i0 * 3 + 2]) * k,
    );
  }
}

/// Where a shot goes, from the tee on floor [index] up the building (the street is [street] below it):
/// up off the tee, over the railing (or off it), down onto the street, a roof or a balcony further
/// down, bouncing and rolling to a stop, or into the cup. The same shot always goes the same way.
Flight fly(Shot shot, double street, int index) {
  final power = _clamp(shot.power, 0, 1);
  final loft = _clamp(shot.loft, loftMin, loftMax);
  final yaw = _clamp(shot.yaw, -aimMax, aimMax);
  final v = _speed * power;
  var x = teeBall.x, y = teeBall.y, z = teeBall.z;
  var vx = v * math.cos(loft) * math.sin(yaw);
  var vy = v * math.sin(loft);
  var vz = v * math.cos(loft) * math.cos(yaw);
  const dt = 1 / _steps;
  final path = <double>[x, y, z];
  final hits = <GolfHit>[];
  // The neighbours stand on the street; the building's floors above its garage stand in the way too.
  final boxes = [
    for (final n in neighbourBoxes())
      (minX: n.minX, maxX: n.maxX, minZ: n.minZ, maxZ: n.maxZ, bottom: street, top: street + n.top, roof: true),
    (
      minX: _b.minX,
      maxX: _b.maxX,
      minZ: _b.minZ,
      maxZ: _b.maxZ,
      bottom: street - streetY - slab,
      top: double.infinity,
      roof: false,
    ),
  ];
  var rolling = false, holed = false;
  var lie = Lie.rough;
  var step = 0;
  void hit(HitKind kind, double speed, [Lie? on]) => hits.add(GolfHit(step * dt, kind, x, y, z, speed, on));

  /// What's under the ball at (px, pz), coming down from [from]: the ground, a neighbour's roof, or a balcony.
  (double, Lie) under(double px, double pz, double from) {
    if (px > Balcony.minX && px < Balcony.maxX && pz > Balcony.minZ && pz < Balcony.maxZ) {
      // This floor's balcony, or one further down the building.
      for (var k = 0; k <= index; k++) {
        final deck = -k * storey;
        if (from > deck - 0.1) return (deck, k > 0 ? Lie.below : Lie.deck);
      }
    }
    for (final b in boxes) {
      if (b.roof && px > b.minX && px < b.maxX && pz > b.minZ && pz < b.maxZ && from > b.top - 0.1) {
        return (b.top, Lie.roof);
      }
    }
    return (street, lieAt(px, pz));
  }

  for (; step < _maxSeconds * _steps; step++) {
    if (!rolling) {
      vy -= _gravity * dt;
      const k = 1 - _drag * dt;
      vx *= k;
      vy *= k;
      vz *= k;
    }
    var nx = x + vx * dt, ny = y + vy * dt, nz = z + vz * dt;

    // Round the balcony: the railing on three sides, as high as its top, and the wall behind.
    if (x > _inside.minX - 0.01 &&
        x < _inside.maxX + 0.01 &&
        z > _inside.minZ - 0.01 &&
        z < _inside.maxZ + 0.01 &&
        y > -0.2 &&
        y < wallHeight) {
      if (ny < _railTop + golfBallR) {
        if (nz > _inside.maxZ) {
          nz = _inside.maxZ;
          hit(HitKind.rail, vz.abs());
          vz = -vz * 0.35;
          vx *= 0.8;
        }
        if (nx < _inside.minX || nx > _inside.maxX) {
          nx = _clamp(nx, _inside.minX, _inside.maxX);
          hit(HitKind.rail, vx.abs());
          vx = -vx * 0.35;
          vz *= 0.8;
        }
      }
      if (nz < _inside.minZ) {
        nz = _inside.minZ;
        hit(HitKind.wall, vz.abs());
        vz = -vz * 0.3;
        vx *= 0.8;
      }
    }
    // Off the side of a building.
    for (final b in boxes) {
      if (nx <= b.minX || nx >= b.maxX || nz <= b.minZ || nz >= b.maxZ || ny >= b.top || ny <= b.bottom) continue;
      if (y >= b.top) continue; // onto its roof: that's the ground, below
      if (x <= b.minX || x >= b.maxX) {
        nx = x <= b.minX ? b.minX : b.maxX;
        hit(HitKind.wall, vx.abs());
        vx = -vx * 0.35;
        vz *= 0.7;
      } else {
        nz = z <= b.minZ ? b.minZ : b.maxZ;
        hit(HitKind.wall, vz.abs());
        vz = -vz * 0.35;
        vx *= 0.7;
      }
    }

    final (floor, on) = under(nx, nz, y - golfBallR);
    x = nx;
    y = ny;
    z = nz;
    if (y - golfBallR <= floor) {
      y = floor + golfBallR;
      lie = on;
      if (on == Lie.below) {
        // Onto a balcony further down: it's not coming back from there.
        hit(HitKind.bounce, -vy, on);
        break;
      }
      final g = _ground[on]!;
      final pin = _hypot(x - GolfHole.x, z - GolfHole.z);
      if (-vy > _rollV) {
        // Straight into the cup.
        if (on == Lie.green && pin < _cup) {
          holed = true;
          break;
        }
        hit(HitKind.bounce, -vy, on);
        vy = -vy * g.bounce;
        vx *= g.keep;
        vz *= g.keep;
        rolling = false;
      } else {
        vy = 0;
        rolling = true;
        final speed = _hypot(vx, vz);
        if (on == Lie.green && pin < _cup && speed < _cupSpeed) {
          holed = true;
          break;
        }
        final slow = g.roll * dt;
        if (speed <= slow) break;
        vx *= (speed - slow) / speed;
        vz *= (speed - slow) / speed;
      }
    } else if (rolling && y - golfBallR > floor + 0.01) {
      rolling = false; // off an edge
    }
    if (x.abs() > 190 || z.abs() > 190 || y < street - 1) {
      lie = Lie.lost;
      break;
    }
    if ((step + 1) % _keep == 0) path.addAll([x, y, z]);
  }
  if (holed) {
    // Down into the cup.
    x = GolfHole.x;
    z = GolfHole.z;
    y = street + golfBallR - 0.12;
    lie = Lie.green;
    hit(HitKind.cup, 0, Lie.green);
  }
  path.addAll([x, y, z]);
  final down = lie != Lie.lost && lie != Lie.deck && lie != Lie.roof && lie != Lie.below;
  return Flight(
    shot: (yaw: yaw, loft: loft, power: power),
    path: Float32List.fromList(path),
    hits: hits,
    seconds: (path.length / 3 - 1) / (_steps / _keep),
    rest: vm.Vector3(x, y, z),
    holed: holed,
    lie: lie,
    fromPin: holed
        ? 0
        : down
        ? _hypot(x - GolfHole.x, z - GolfHole.z)
        : double.nan,
  );
}

/// A distance to the pin, as it's read out: "40 cm", "3.4 m", "27 m".
String pinText(double m) {
  if (m < 1) return '${(m * 100).round()} cm';
  return m < 10 ? '${m.toStringAsFixed(1)} m' : '${m.round()} m';
}

/// Where a ball stopped, in words.
String lieText(Flight f) {
  if (f.holed) return 'In the hole!';
  return switch (f.lie) {
    Lie.lost => 'Lost',
    Lie.deck => "Didn't clear the railing",
    Lie.below => 'Onto the balcony below',
    Lie.roof => 'On the roof',
    Lie.sand => 'In the bunker · ${pinText(f.fromPin)}',
    Lie.green => 'On the green · ${pinText(f.fromPin)}',
    _ => '${pinText(f.fromPin)} from the pin',
  };
}

// ---- The tee and the hole -----------------------------------------------------------------------

Node golfBall() => mesh(sphere(golfBallR, 14, 10), tc('#ffffff'), 0, 0, 0, false);

/// The tee on the balcony: a square of turf, a ball on a tee, a pair of tee markers along its front,
/// and a golf bag leaning on the wall behind it. Returns the ball waiting on the tee.
({Node group, Node ball, Interactable interactable}) buildTee() {
  const x = GolfTee.x, z = GolfTee.z, size = GolfTee.size;
  final it = Interactable(kind: InteractKind.golf, x: x, z: z, radius: 1.5);
  final group = Node(name: 'golf-tee');
  final parts = Node(name: 'tee-parts');
  parts.add(mesh(box(size, _matH, size), tc('#3f8f45'), x, _matH / 2, z));
  // The mown top, striped, with a white line round it.
  parts.add(mesh(groundPlane(size - 0.02, size - 0.02), tc('#fffaf3'), x, _matH + 0.001, z, false));
  for (var i = 0; i < 6; i++) {
    final w = (size - 0.12) / 6;
    parts.add(
      mesh(
        groundPlane(size - 0.12, w),
        tc(i.isEven ? '#7ed957' : '#6cc24a'),
        x,
        _matH + 0.002,
        z - (size - 0.12) / 2 + (i + 0.5) * w,
        false,
      ),
    );
  }
  const b = GolfTee.ball;
  parts.add(
    mesh(cyl(0.012, 0.006, _teeH + 0.02, 8), tc('#ffd166'), b.x, _matH + (_teeH + 0.02) / 2 - 0.01, b.z, false),
  );
  // Tee markers: a red ball either side, a little in front of the ball.
  for (final s in [-1, 1]) {
    parts.add(mesh(sphere(0.06, 12, 8), tc('#ef476f'), b.x + s * 0.55, _matH + 0.05, z + size / 2 - 0.12));
  }
  // The bag: leaning back on the wall, three clubs sticking out of the top.
  final bag = Node(name: 'bag');
  bag.add(mesh(cyl(0.17, 0.15, 0.85, 14), tc('#1d3557'), 0, 0.43, 0));
  bag.add(mesh(cyl(0.175, 0.175, 0.1, 14), tc('#ef476f'), 0, 0.62, 0));
  bag.add(mesh(cyl(0.18, 0.18, 0.05, 14), tc('#fffaf3'), 0, 0.86, 0));
  for (final (cx, cz, tilt) in const [(-0.06, 0.04, -0.12), (0.05, 0.05, 0.1), (0.0, -0.06, 0.02)]) {
    final club = Node(name: 'club');
    club.add(mesh(cyl(0.012, 0.012, 0.5, 6), tc('#adb5bd'), 0, 0.25, 0, false));
    club.add(mesh(box(0.1, 0.07, 0.05), tc('#8d99ae'), 0.03, 0.52, 0));
    bag.add(place(club, x: cx, y: 0.8, z: cz, rot: euler(0, 0, tilt)));
  }
  parts.add(place(bag, x: GolfTee.bag.x, z: GolfTee.bag.z, rot: euler(-0.14)));
  final merged = mergeByMaterial(parts);
  tagInteract(merged, it);
  group.add(merged);

  final ball = golfBall();
  ball.position = teeBall.clone();
  tagInteract(ball, it);
  group.add(ball);
  return (group: group, ball: ball, interactable: it);
}

/// The golf bag leaning on the wall, to walk into.
Collider golfBagCollider() => Collider(
  minX: GolfTee.bag.x - 0.2,
  maxX: GolfTee.bag.x + 0.2,
  minZ: Balcony.minZ,
  maxZ: GolfTee.bag.z + 0.2,
  top: 1,
);

/// The hole across the street, [street] below the office floor: a mown fairway from the far sidewalk
/// up to a round green with the cup and the flag in it, bunkers either side, trees behind, and a sign.
/// Returns the flag, which flaps in the wind.
Node buildGreen(Node ground, double street) {
  final g = street;
  const px = GolfHole.x, pz = GolfHole.z;
  final (fx0, fx1) = GolfHole.fairway;
  const fairLen = pz - _fairwayZ0;
  final parts = Node(name: 'green-parts');
  // The fairway, mown in stripes every couple of meters.
  final stripes = (fairLen / 2).ceil();
  for (var i = 0; i < stripes; i++) {
    final len = math.min(2.0, fairLen - i * 2);
    parts.add(
      mesh(
        groundPlane(fx1 - fx0, len),
        tc(i.isEven ? '#8fd16f' : '#7fc463'),
        (fx0 + fx1) / 2,
        g + 0.004,
        _fairwayZ0 + i * 2 + len / 2,
        false,
      ),
    );
  }
  Node disc(double r, String color, double x, double y, double z) =>
      place(mesh(circleXY(r, 48), tc(color), 0, 0, 0, false), x: x, y: y, z: z, rot: euler(-math.pi / 2));
  parts.add(disc(GolfHole.green + _fringe, '#6cc24a', px, g + 0.008, pz));
  parts.add(disc(GolfHole.green, '#9be07a', px, g + 0.012, pz));
  for (final (bx, bz, r) in _bunkers) {
    parts.add(disc(r + 0.12, '#d9c48a', bx, g + 0.016, bz));
    parts.add(disc(r, '#f3e3b3', bx, g + 0.02, bz));
  }
  // The cup (bigger than a real one, like the ball) with a white rim.
  parts.add(disc(0.17, '#fffaf3', px, g + 0.016, pz));
  parts.add(disc(0.13, '#1d1d1d', px, g + 0.02, pz));
  parts.add(mesh(cyl(0.035, 0.035, _stick, 8), tc('#fffaf3'), px, g + _stick / 2, pz));
  parts.add(mesh(sphere(0.06, 10, 8), tc('#ffd166'), px, g + _stick + 0.03, pz));
  // Trees round the back of the green.
  for (final (tx, tz, s) in const [
    (px - 9, pz + 7, 1.2),
    (px + 8.5, pz + 8, 1.05),
    (px - 1, pz + 12, 1.3),
    (px + 11, pz - 3, 0.95),
  ]) {
    final t = Node(name: 'tree');
    t.add(mesh(cyl(0.22, 0.3, 2.2, 8), tc('#8a5a3b'), 0, 1.1, 0));
    t.add(mesh(sphere(1.6, 12, 10), tc('#5fb760'), 0, 3.2, 0));
    t.add(mesh(sphere(1.1, 10, 8), tc('#4fa150'), 0.6, 4.1, 0.3));
    parts.add(place(t, x: tx, y: g, z: tz, scale: s));
  }
  // A sign where the fairway starts, facing the office: which hole it is.
  final sx = fx1 + 1.8;
  const sz = _fairwayZ0 + 0.6;
  for (final dx in [-1.1, 1.1]) {
    parts.add(mesh(box(0.12, 1.5, 0.12), tc('#8a5a3b'), sx + dx, g + 0.75, sz));
  }
  ground.add(mergeByMaterial(parts));
  ground.add(
    place(
      textPlane('⛳ Hole 1 · Par 1', const TextOpts(bg: '#2b2d42', color: '#fffaf3', size: 64, border: '#fffaf3')),
      x: sx,
      y: g + 1.5,
      z: sz - 0.07,
      rot: yaw(math.pi),
    ),
  );
  // The flag: a red pennant off the top of the stick.
  final flag = Node(name: 'flag');
  flag.add(mesh(planeXY(1.2, 0.75, both: true), tc('#ef476f'), 0.6, 0, 0, false));
  flag.position = vm.Vector3(px + 0.03, g + _stick - 0.42, pz);
  ground.add(flag);
  return flag;
}

// ---- The balls in play ------------------------------------------------------------------------------

class _Flying {
  _Flying(this.flight, this.node, this.who, this.mine);
  final Flight flight;
  final Node node;
  final String who;
  final bool mine;

  /// Seconds since the hit.
  double t = 0;

  /// The next of `flight.hits` still to happen.
  int next = 0;

  /// Seconds since it stopped, or -1 while it's still going.
  double still = -1;
  WorldLabel? label;
  final List<Node> dots = [];
}

/// How long a stopped ball stays lying there, and its label over it, in seconds.
const double _lieSeconds = 90;
const double _labelSeconds = 14;

/// At most this many balls lying about: the oldest go first.
const int _maxBalls = 12;

/// The balls in the air or lying where they stopped, everyone's, played back along their flights.
class GolfBalls {
  GolfBalls(this.labels);

  final LabelHub labels;
  final Node group = Node(name: 'golf-balls');
  final List<_Flying> _balls = [];

  /// It hit something: `mine` if it's your ball.
  void Function(GolfHit hit, bool mine)? onHit;

  /// It stopped (or went in).
  void Function(Flight flight, String who, bool mine)? onRest;

  /// Sends a ball off along [flight], hit by [who].
  void launch(Flight flight, String who, bool mine) {
    final node = golfBall();
    node.position = flight.at(0);
    group.add(node);
    _balls.add(_Flying(flight, node, who, mine));
    while (_balls.length > _maxBalls) {
      _drop(_balls.first);
    }
  }

  /// Your ball still on its way (or just stopped), for the camera to follow.
  ({vm.Vector3 at, Flight flight, double still})? get mine {
    for (final b in _balls.reversed) {
      if (b.mine) return (at: b.node.position, flight: b.flight, still: b.still);
    }
    return null;
  }

  void update(double dt) {
    for (final b in [..._balls]) {
      final f = b.flight;
      if (b.still < 0) {
        final was = b.t;
        b.t = math.min(b.t + dt, f.seconds);
        b.node.position = f.at(b.t);
        // A dot every tenth of a second behind it, as its trail.
        for (var s = (was * 10).floor() + 1; s <= (b.t * 10).floor(); s++) {
          final dot = place(
            mesh(sphere(0.03, 6, 4), tc(b.mine ? '#ffd166' : '#fffaf3'), 0, 0, 0, false),
            x: 0,
            y: 0,
            z: 0,
          );
          dot.position = f.at(s / 10);
          group.add(dot);
          b.dots.add(dot);
        }
        while (b.next < f.hits.length && f.hits[b.next].t <= b.t) {
          onHit?.call(f.hits[b.next++], b.mine);
        }
        if (b.t >= f.seconds) {
          b.still = 0;
          // In the cup, it's out of sight.
          b.node.visible = !f.holed;
          final text = '${b.mine ? '' : '${b.who} · '}${f.holed ? '⛳ ' : ''}${lieText(f)}';
          final anchor = Node(name: 'lie')..position = f.rest + vm.Vector3(0, f.holed ? 1.2 : 0.7, 0);
          group.add(anchor);
          b.label = labels.add(
            WorldLabel(
              anchor: anchor,
              maxDistance: 120,
              child: TagPill(
                text,
                bg: f.holed ? '#ffd166' : '#2b2d42',
                color: f.holed ? '#2b2d42' : '#fffaf3',
                size: 36,
                border: '#fffaf3',
              ),
            ),
          );
          onRest?.call(f, b.who, b.mine);
        }
        continue;
      }
      b.still += dt;
      // The trail goes once it's down, then the label, and in the end the ball's picked up.
      if (b.still > 2 && b.dots.isNotEmpty) {
        for (final d in b.dots) {
          d.detach();
        }
        b.dots.clear();
      }
      if (b.label != null && b.still > _labelSeconds) {
        labels.remove(b.label);
        b.label!.anchor.detach();
        b.label = null;
      }
      if (b.still > _lieSeconds) _drop(b);
    }
  }

  /// Every ball, gone: off to another floor.
  void clear() {
    for (final b in [..._balls]) {
      _drop(b);
    }
  }

  void _drop(_Flying b) {
    _balls.remove(b);
    b.node.detach();
    for (final d in b.dots) {
      d.detach();
    }
    if (b.label != null) {
      labels.remove(b.label);
      b.label!.anchor.detach();
    }
  }
}
