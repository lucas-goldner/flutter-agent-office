// Getting around the office floor downstairs (no stairs, no loft, no elevator), round the furniture
// on a coarse grid: the dog's walks (server/dog.ts), and a worker's way out when it's sent home.

import 'dart:math' as math;
import 'dart:typed_data';

import 'layout.dart';

/// A point on the floor: (x, z).
typedef Pt = (double, double);

const double _cell = 0.5;

/// Half the width of whoever walks it (the dog, a worker), plus a little room: how far they keep from things.
const double _r = 0.3;
final int _cols = ((Floor.maxX - Floor.minX) / _cell).ceil();
final int _rows = ((Floor.maxZ - Floor.minZ) / _cell).ceil();

typedef _Rect = (double, double, double, double); // minX, maxX, minZ, maxZ
typedef _Circle = (double, double, double); // x, z, radius

/// The desk's own frame: `t` along its width, `s` out toward the side the worker sits on.
Pt deskPoint(DeskDef d, double t, double s) => (
      d.x + math.cos(d.rotY) * t + math.sin(d.rotY) * s,
      d.z - math.sin(d.rotY) * t + math.cos(d.rotY) * s,
    );

/// What's in the way on the floor. The lounge, kitchen and plants are where office.ts puts them.
({List<_Rect> rects, List<_Circle> circles}) _obstacles() {
  final rects = <_Rect>[];
  final circles = <_Circle>[];
  const hw = DeskSize.width / 2;
  const hd = DeskSize.depth / 2;
  for (final d in desks) {
    // Desks face ±z, so their tops are axis-aligned.
    rects.add((d.x - hw, d.x + hw, d.z - hd, d.z + hd));
    final (cx, cz) = deskPoint(d, 0, 0.9);
    circles.add((cx, cz, 0.35)); // the chair
  }
  rects.add((10, 11, -2.2, 2.2)); // couch
  rects.add((12.2, 13.8, -0.8, 0.8)); // coffee table
  circles.addAll([(12.5, 3.5, 0.5), (14.5, -3.4, 0.5)]); // beanbags
  rects.add((-17, -10.75, 11.7, 12.7)); // kitchen counter and fridge
  for (final (x, z, s) in const [
    (-17.2, -12.2, 1.4),
    (17.2, -12.2, 1.5),
    (17.2, 12.2, 1.3),
    (-17.2, 8.5, 1.2),
    (5.5, -12.2, 1.1),
    (-6.0, 0.0, 1.0),
    (3.5, 0.0, 0.9),
    (8.5, 5.0, 1.1),
  ]) {
    circles.add((x, z, 0.3 * s));
  }
  // The loft's posts, the stairs up to it, and the elevator shaft.
  for (final x in [Loft.minX + 0.15, (Loft.minX + Loft.maxX) / 2]) {
    circles.add((x, Loft.minZ + 0.15, 0.14));
  }
  rects.add((Stairs.fromX, Stairs.toX, Stairs.minZ - 0.1, Stairs.maxZ));
  rects.add((Elevator.x - Elevator.width / 2, Elevator.x + Elevator.width / 2, Floor.minZ, elevatorFront));
  // The gong's frame, as office.ts puts it.
  rects.add((Gong.x - Gong.width / 2 - 0.12, Gong.x + Gong.width / 2 + 0.3, Gong.z - 0.3, Gong.z + 0.3));
  // The whiteboard on its wheels, as world/whiteboard.ts puts it.
  rects.add((Whiteboard.x - Whiteboard.width / 2 - 0.2, Whiteboard.x + Whiteboard.width / 2 + 0.2, Whiteboard.z - 0.48, Whiteboard.z + 0.48));
  // The jukebox, against the east wall.
  rects.add((Jukebox.x - Jukebox.depth / 2 - 0.05, Floor.maxX, Jukebox.z - Jukebox.width / 2 - 0.05, Jukebox.z + Jukebox.width / 2 + 0.05));
  // The overflow bean bags and their lap desks. They're only out while every desk is taken, but they
  // always come out in the same spots, so the dog keeps off those.
  for (final b in beanbags) {
    final corners = [deskPoint(b, -0.62, -1.1), deskPoint(b, 0.62, -1.1), deskPoint(b, -0.62, 0.64), deskPoint(b, 0.62, 0.64)];
    final xs = corners.map((p) => p.$1);
    final zs = corners.map((p) => p.$2);
    rects.add((xs.reduce(math.min), xs.reduce(math.max), zs.reduce(math.min), zs.reduce(math.max)));
  }
  return (rects: rects, circles: circles);
}

bool _isBlocked(double x, double z, ({List<_Rect> rects, List<_Circle> circles}) o) {
  if (x < Floor.minX + _r || x > Floor.maxX - _r || z < Floor.minZ + _r || z > Floor.maxZ - _r) return true;
  for (final (x0, x1, z0, z1) in o.rects) {
    if (x > x0 - _r && x < x1 + _r && z > z0 - _r && z < z1 + _r) return true;
  }
  for (final (cx, cz, r) in o.circles) {
    if (_hypot(x - cx, z - cz) < r + _r) return true;
  }
  return false;
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

final Uint8List _grid = () {
  final o = _obstacles();
  final g = Uint8List(_cols * _rows);
  for (var r = 0; r < _rows; r++) {
    for (var c = 0; c < _cols; c++) {
      g[r * _cols + c] = _isBlocked(Floor.minX + (c + 0.5) * _cell, Floor.minZ + (r + 0.5) * _cell, o) ? 1 : 0;
    }
  }
  return g;
}();

/// A grid cell, reading anything off the grid as open (as the TS typed-array read of `undefined` does).
bool _blocked(int i) => i >= 0 && i < _grid.length && _grid[i] != 0;

int _colOf(double x) => ((x - Floor.minX) / _cell).floor().clamp(0, _cols - 1);
int _rowOf(double z) => ((z - Floor.minZ) / _cell).floor().clamp(0, _rows - 1);
Pt _centerOf(int i) => (Floor.minX + ((i % _cols) + 0.5) * _cell, Floor.minZ + ((i ~/ _cols) + 0.5) * _cell);

bool walkable(double x, double z) =>
    x > Floor.minX && x < Floor.maxX && z > Floor.minZ && z < Floor.maxZ && !_blocked(_rowOf(z) * _cols + _colOf(x));

int _sign(double v) => v > 0 ? 1 : (v < 0 ? -1 : 0);

/// Whether it can trot straight from a to b: every cell the line crosses is clear.
bool _clearLine(Pt a, Pt b) {
  var c = _colOf(a.$1);
  var r = _rowOf(a.$2);
  final c1 = _colOf(b.$1);
  final r1 = _rowOf(b.$2);
  final dx = b.$1 - a.$1;
  final dz = b.$2 - a.$2;
  final sc = _sign(dx);
  final sr = _sign(dz);
  final stepC = sc != 0 ? _cell / dx.abs() : double.infinity;
  final stepR = sr != 0 ? _cell / dz.abs() : double.infinity;
  var nextC = sc != 0 ? (Floor.minX + (c + (sc > 0 ? 1 : 0)) * _cell - a.$1) / dx : double.infinity;
  var nextR = sr != 0 ? (Floor.minZ + (r + (sr > 0 ? 1 : 0)) * _cell - a.$2) / dz : double.infinity;
  for (var n = 0; n <= _cols + _rows; n++) {
    if (_blocked(r * _cols + c)) return false;
    if (c == c1 && r == r1) return true;
    if ((nextC - nextR).abs() < 1e-9) {
      // Right through a corner: both cells beside it count.
      if (_blocked(r * _cols + c + sc) || _blocked((r + sr) * _cols + c)) return false;
      c += sc;
      r += sr;
      nextC += stepC;
      nextR += stepR;
    } else if (nextC < nextR) {
      c += sc;
      nextC += stepC;
    } else {
      r += sr;
      nextR += stepR;
    }
  }
  return false;
}

/// The middle of the nearest cell it can stand in.
Pt nearestWalkable(Pt p) {
  if (walkable(p.$1, p.$2)) return p;
  var best = -1;
  var bestD = double.infinity;
  for (var i = 0; i < _grid.length; i++) {
    if (_grid[i] != 0) continue;
    final (x, z) = _centerOf(i);
    final d = (x - p.$1) * (x - p.$1) + (z - p.$2) * (z - p.$2);
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best < 0 ? p : _centerOf(best);
}

/// A* over the grid, then pulled tight: the corners of a route from `from` to `to`, both included.
List<Pt> route(Pt from, Pt to) {
  final goal = nearestWalkable(to);
  final start = nearestWalkable(from);
  final lead = start == from ? [from] : [from, start];
  if (_clearLine(start, goal)) return [...lead, goal];
  final s = _rowOf(start.$2) * _cols + _colOf(start.$1);
  final g = _rowOf(goal.$2) * _cols + _colOf(goal.$1);
  final cost = Float64List(_grid.length)..fillRange(0, _grid.length, double.infinity);
  final came = Int32List(_grid.length)..fillRange(0, _grid.length, -1);
  final closed = Uint8List(_grid.length);
  final heap = _Heap();
  final gc = g % _cols;
  final gr = g ~/ _cols;
  double h(int i) {
    final dx = ((i % _cols) - gc).abs();
    final dz = ((i ~/ _cols) - gr).abs();
    return math.max(dx, dz) + (math.sqrt2 - 1) * math.min(dx, dz);
  }

  cost[s] = 0;
  heap.push(s, h(s));
  while (heap.size > 0) {
    final i = heap.pop();
    if (i == g) break;
    if (closed[i] != 0) continue;
    closed[i] = 1;
    final c = i % _cols;
    final r = i ~/ _cols;
    for (var dz = -1; dz <= 1; dz++) {
      for (var dx = -1; dx <= 1; dx++) {
        if (dx == 0 && dz == 0) continue;
        final nc = c + dx;
        final nr = r + dz;
        if (nc < 0 || nr < 0 || nc >= _cols || nr >= _rows) continue;
        final n = nr * _cols + nc;
        if (_grid[n] != 0 || closed[n] != 0) continue;
        // No cutting corners past something in the way.
        if (dx != 0 && dz != 0 && (_grid[r * _cols + nc] != 0 || _grid[nr * _cols + c] != 0)) continue;
        final next = cost[i] + (dx != 0 && dz != 0 ? math.sqrt2 : 1);
        if (next >= cost[n]) continue;
        cost[n] = next;
        came[n] = i;
        heap.push(n, next + h(n));
      }
    }
  }
  if (came[g] < 0) return [...lead, goal]; // nowhere to go round; shouldn't happen in one room
  final cells = <Pt>[];
  for (var i = came[g]; i != s && i >= 0; i = came[i]) {
    cells.add(_centerOf(i));
  }
  final pts = <Pt>[start, ...cells.reversed, goal];
  // Keep only the corners: from each point, straight on to the farthest one it can see.
  final out = <Pt>[...lead];
  for (var i = 0; i < pts.length - 1;) {
    var j = pts.length - 1;
    while (j > i + 1 && !_clearLine(pts[i], pts[j])) {
      j--;
    }
    out.add(pts[j]);
    i = j;
  }
  return out;
}

/// A binary min-heap of grid cells keyed by their A* estimate.
class _Heap {
  final List<int> _items = [];
  final List<double> _keys = [];

  int get size => _items.length;

  void push(int item, double key) {
    var i = _items.length;
    _items.add(item);
    _keys.add(key);
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_keys[p] <= key) break;
      _items[i] = _items[p];
      _keys[i] = _keys[p];
      i = p;
    }
    _items[i] = item;
    _keys[i] = key;
  }

  int pop() {
    final top = _items[0];
    final item = _items.removeLast();
    final key = _keys.removeLast();
    if (_items.isNotEmpty) {
      var i = 0;
      for (;;) {
        final l = 2 * i + 1;
        if (l >= _items.length) break;
        final m = l + 1 < _items.length && _keys[l + 1] < _keys[l] ? l + 1 : l;
        if (_keys[m] >= key) break;
        _items[i] = _items[m];
        _keys[i] = _keys[m];
        i = m;
      }
      _items[i] = item;
      _keys[i] = key;
    }
    return top;
  }
}

// ---- Sent home ----------------------------------------------------------------------------------

/// Just inside the exit door, in the west wall.
final Pt _exit = (Floor.minX + 0.45, exitDoor.u);
/// Down the middle of the steps outside it.
const double _stepsX = (ExitStairs.minX + ExitStairs.maxX) / 2;

/// Along the near sidewalk, between the lot and the trees planted in it.
const double _sidewalkZ = Road.minZ - 1.7;

/// How far west along the sidewalk they get before they're gone.
const double _walkOffX = -38;

double _pathLength(List<Pt> pts) {
  var n = 0.0;
  for (var i = 1; i < pts.length; i++) {
    n += _hypot(pts[i].$1 - pts[i - 1].$1, pts[i].$2 - pts[i - 1].$2);
  }
  return n;
}

/// A worker's walk out of the building once it's sent home. The first point is where it hops down,
/// beside its chair (or its bean bag) on whichever side is the shorter way out; then round the
/// furniture to the exit door in the west wall, across the landing outside, down the steps to the
/// street and off along the sidewalk.
List<Pt> wayHome(DeskDef seat) {
  final ways = [-1.0, 1.0].map((side) {
    // Beside the chair and back from the desk into the aisle, or off the bean bag and round behind it.
    final (down, back) = seat.beanbag
        ? (deskPoint(seat, side * 1.05, 0.1), deskPoint(seat, side * 1.05, 1.25))
        : (deskPoint(seat, side * 0.7, 0.95), deskPoint(seat, side * 0.7, 1.75));
    // A bean bag can stand with one side up against something.
    final blocked = seat.beanbag && !walkable(down.$1, down.$2);
    final pts = [down, ...route(back, _exit)];
    return (pts: pts, cost: (blocked ? 1000 : 0) + _pathLength(pts));
  }).toList();
  final inside = ways[0].cost <= ways[1].cost ? ways[0].pts : ways[1].pts;
  return [
    ...inside,
    (_stepsX, exitDoor.u),
    (_stepsX, ExitStairs.landingZ1 + (ExitStairs.steps - 1) * ExitStairs.run + 0.6),
    (_stepsX, _sidewalkZ),
    (_walkOffX, _sidewalkZ),
  ];
}
