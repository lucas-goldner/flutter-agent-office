// A station's walls, and what's cut through them (a station-style map, see station.dart): the hatch
// workers come in and go home through, the windows out into space (its `viewport` props), and the
// airlock (the config's `airlock`), whose chamber sticks out of the hull beyond one wall. A worker
// sent home on a map whose script ejects it (see dungeon.dart) is shoved into that chamber and blown
// out of the outer hatch, and is kept out there for good, adrift: [adrift] says where each one has got
// to, from when it was blown out, the same in every browser.
//
// It's all worked out from plain numbers, like the dungeon, so another station is other numbers.
// Ported from src/shared/maps/airlock.ts.

import 'dart:math' as math;

import '../nav.dart';
import '../rng.dart';
import 'check.dart';
import 'types.dart';

/// How thick a station's hull is (TS HULL).
const double hullThickness = 0.5;

/// The hatch workers come in through: across and high (TS HATCH).
abstract final class HatchSize {
  static const double width = 3.2;
  static const double height = 3.1;
}

/// The airlock: its inner door (across and high), the chamber beyond the wall (across, and out from
/// the wall's outside face), and how far in front of the inner door a worker's brought (TS AIRLOCK).
abstract final class AirlockSize {
  static const double door = 2;
  static const double height = 2.7;
  static const double width = 3.4;
  static const double depth = 3.6;
  static const double front = 1.5;
}

/// What a `viewport` is when its map doesn't say: its sill, across and high (TS VIEWPORT).
abstract final class ViewportSize {
  static const double y = 1.1;
  static const double width = 5;
  static const double height = 3.6;
}

/// How far short of a wall's ends and top an opening has to stop, and how far apart two have to be.
const double _margin = 0.6;

const List<WallSide> _sides = [WallSide.west, WallSide.east, WallSide.north, WallSide.south];

/// Which wall (x, z) is nearest, and how far off it is.
({WallSide wall, double gap}) nearestWall(Bounds b, double x, double z) {
  final gaps = {
    WallSide.west: x - b.minX,
    WallSide.east: b.maxX - x,
    WallSide.north: z - b.minZ,
    WallSide.south: b.maxZ - z,
  };
  var wall = WallSide.south;
  for (final k in _sides) {
    if (gaps[k]! < gaps[wall]!) wall = k;
  }
  return (wall: wall, gap: gaps[wall]!);
}

/// The way out through [wall]: a step along x or z.
Pt wallOut(WallSide wall) => switch (wall) {
  WallSide.west => (-1.0, 0.0),
  WallSide.east => (1.0, 0.0),
  WallSide.north => (0.0, -1.0),
  WallSide.south => (0.0, 1.0),
};

/// The point [u] along [wall], on its inside face.
Pt wallPoint(Bounds b, WallSide wall, double u) => switch (wall) {
  WallSide.west => (b.minX, u),
  WallSide.east => (b.maxX, u),
  WallSide.north => (u, b.minZ),
  WallSide.south => (u, b.maxZ),
};

/// Where [wall] starts and ends, along itself.
(double, double) _wallSpan(Bounds b, WallSide wall) =>
    wall == WallSide.north || wall == WallSide.south ? (b.minX, b.maxX) : (b.minZ, b.maxZ);

/// How far along its wall (x, z) is.
double _along(WallSide wall, double x, double z) => wall == WallSide.north || wall == WallSide.south ? x : z;

/// Checks a map's airlock, and works out where its door, its chamber and its outer hatch are.
AirlockPlan planAirlock(Object? input, Bounds hall) {
  if (!isObj(input)) throw const MapError('airlock should be { x, z }: just inside its inner door');
  final a = objOf(input);
  final x = checkNum(a['x'], 'airlock.x');
  final z = checkNum(a['z'], 'airlock.z');
  if (x < hall.minX || x > hall.maxX || z < hall.minZ || z > hall.maxZ) {
    throw MapError('airlock (${fixed1(x)}, ${fixed1(z)}) is outside the hall');
  }
  final wall = nearestWall(hall, x, z).wall;
  final out = wallOut(wall);
  final door = wallPoint(hall, wall, _along(wall, x, z));
  Pt at(double d) => (door.$1 + out.$1 * d, door.$2 + out.$2 * d);
  return AirlockPlan(
    wall: wall,
    out: out,
    door: door,
    front: at(-AirlockSize.front),
    chamber: at(hullThickness + AirlockSize.depth * 0.45),
    hatch: at(hullThickness + AirlockSize.depth),
  );
}

/// Everything cut through a station's walls: the hatch in the wall nearest its `door`, its airlock's
/// inner door, and a window for each `viewport` prop, in the wall it's on. None may run into another,
/// or off the end or the top of its wall. [c] is the map's config (its `door` and `props` already checked).
List<WallOpening> wallOpenings(MapConfig c, Bounds hall, double height, AirlockPlan? airlock) {
  final out = <WallOpening>[];
  void add(WallOpening o, String what) {
    final (lo, hi) = _wallSpan(hall, o.wall);
    if (o.u - o.width / 2 < lo + _margin || o.u + o.width / 2 > hi - _margin) {
      throw MapError('$what runs off the end of the ${o.wall.wire} wall: move it along, or make it narrower');
    }
    if (o.y + o.height > height - _margin) {
      throw MapError(
        "$what reaches ${fixed1(o.y + o.height)} m up, and the hall's walls are ${jsNum(height)} m: it needs ${jsNum(_margin)} m of wall over it",
      );
    }
    for (final p in out) {
      if (p.wall == o.wall && (p.u - o.u).abs() < (p.width + o.width) / 2 + _margin) {
        final which = switch (p.kind) {
          OpeningKind.door => 'the way in',
          OpeningKind.airlock => 'the airlock',
          OpeningKind.viewport => 'another viewport',
        };
        throw MapError('$what runs into $which in the ${o.wall.wire} wall');
      }
    }
    out.add(o);
  }

  final door = objOf(c['door']);
  final dx = (door['x'] as num).toDouble();
  final dz = (door['z'] as num).toDouble();
  final d = nearestWall(hall, dx, dz);
  add(
    WallOpening(
      wall: d.wall,
      kind: OpeningKind.door,
      u: _along(d.wall, dx, dz),
      y: 0,
      width: HatchSize.width,
      height: HatchSize.height,
    ),
    'the way in (door)',
  );
  if (airlock != null) {
    add(
      WallOpening(
        wall: airlock.wall,
        kind: OpeningKind.airlock,
        u: _along(airlock.wall, airlock.door.$1, airlock.door.$2),
        y: 0,
        width: AirlockSize.door,
        height: AirlockSize.height,
      ),
      'the airlock',
    );
  }
  final props = c['props'] is List ? c['props'] as List : const [];
  for (var i = 0; i < props.length; i++) {
    final p = PropConfig.fromJson(objOf(props[i]));
    if (p.kind != 'viewport') continue;
    final w = nearestWall(hall, p.x, p.z);
    if (w.gap > 1)
      throw MapError("props[$i] (a viewport) should be on a wall: it's ${fixed1(w.gap)} m from the nearest");
    add(
      WallOpening(
        wall: w.wall,
        kind: OpeningKind.viewport,
        u: _along(w.wall, p.x, p.z),
        y: p.y ?? ViewportSize.y,
        width: p.width ?? ViewportSize.width,
        height: p.height ?? ViewportSize.height,
      ),
      'props[$i] (a viewport)',
    );
  }
  return out;
}

// ---- Adrift ------------------------------------------------------------------------------------

/// Whoever's been blown out of the airlock: how many of them are still to be seen out there (the
/// latest ones); how far from the outer hatch one starts (m), how much further it gets in its first
/// couple of minutes ([soon], while you watch it go), and how far off it ends up ([far]), which
/// takes it [hours] to get most of the way to (TS ADRIFT).
abstract final class Adrift {
  static const int shown = 30;
  static const double near = 5;
  static const double soon = 9;
  static const double far = 42;
  static const double hours = 6;
}

/// Where someone adrift is, their middle, and how they've tumbled round to (radians, about x, y and z).
typedef Drift = ({double x, double y, double z, double rx, double ry, double rz});

/// A few numbers in [0, 1) that are [id]'s own, so everyone sees it drift the same way.
List<double> _own(String id) {
  var h = 2166136261;
  for (var i = 0; i < id.length; i++) {
    h = imul32(h ^ id.codeUnitAt(i), 16777619);
  }
  return List.generate(9, (_) {
    h = imul32(h ^ (h >> 15), 2246822507);
    h = imul32(h ^ (h >> 13), 3266489909);
    h = u32(h ^ (h >> 16));
    return h / 4294967296;
  });
}

/// Where [id] is, [age] ms after it was blown out of [a]: off on a heading of its own, out from the
/// hatch and well to one side of it or the other (so it shows from the window that side of the
/// airlock, clear of the chamber), quickly at first and ever slower, turning over and over as it goes.
/// The same for everyone, whenever they look.
Drift adrift(AirlockPlan a, String id, num age) {
  final u = _own(id);
  final secs = math.max(0, age) / 1000;
  final yaw = (u[0] < 0.5 ? -1 : 1) * (0.35 + 0.6 * (u[0] - 0.5).abs() * 2);
  final pitch = -0.1 + u[1] * 0.46;
  final dist =
      Adrift.near +
      Adrift.soon * (1 - math.exp(-secs / 75)) +
      (Adrift.far - Adrift.near - Adrift.soon) * (0.7 + 0.3 * u[2]) * (1 - math.exp(-secs / 3600 / Adrift.hours));
  final fwd = dist * math.cos(pitch) * math.cos(yaw);
  final side = dist * math.cos(pitch) * math.sin(yaw) + math.sin(secs / 23 + u[3] * 6.3) * 0.5;
  final (ox, oz) = a.out;
  // How fast it turns about an axis (rad/s): slowly, one way or the other.
  double spin(double v) => (v < 0.5 ? -1 : 1) * (0.07 + 0.25 * (v - 0.5).abs() * 2);
  return (
    x: a.hatch.$1 + ox * fwd - oz * side,
    y: 1.3 + dist * math.sin(pitch) + math.sin(secs / 31 + u[4] * 6.3) * 0.4,
    z: a.hatch.$2 + oz * fwd + ox * side,
    rx: u[5] * 6.3 + secs * spin(u[6]),
    ry: u[6] * 6.3 + secs * spin(u[7]),
    rz: u[7] * 6.3 + secs * spin(u[8]),
  );
}

/// Which of [n] kept (the first to go first) are still to be seen adrift: the latest [Adrift.shown] of them.
int adriftFrom(int n) => math.max(0, n - Adrift.shown);
