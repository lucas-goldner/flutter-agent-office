// Getting around a floor on a coarse grid, round the furniture: the dog's walks (server/dog.ts), a
// worker's way out when it's sent home, and on a map of its own (see maps/), a worker's walks about
// the hall. The office's grid is below; a map builds one from its plan ([NavGrid]).
// An office floor built out into the back office (see [Wing]) has more of it to get round: the
// office's helpers take how many rows it's built out (`wing`), and each level gets a grid of its own.
//
// Ported from src/shared/nav.ts.

import 'dart:math' as math;
import 'dart:typed_data';

import 'layout.dart';

/// A point on the floor: (x, z).
typedef Pt = (double, double);

const double _cell = 0.5;

/// Half the width of whoever walks it (the dog, a worker), plus a little room: how far they keep from things.
const double _r = 0.3;

/// A box on the floor: minX, maxX, minZ, maxZ (TS Rect).
typedef NavRect = (double, double, double, double);

/// A round thing on the floor: x, z, radius (TS Circle).
typedef NavCircle = (double, double, double);

/// What's in the way on a floor.
class Obstacles {
  const Obstacles({required this.rects, required this.circles});

  final List<NavRect> rects;
  final List<NavCircle> circles;
}

/// The floor a grid covers.
class Bounds {
  const Bounds({required this.minX, required this.maxX, required this.minZ, required this.maxZ});

  final double minX;
  final double maxX;
  final double minZ;
  final double maxZ;

  @override
  bool operator ==(Object other) =>
      other is Bounds && other.minX == minX && other.maxX == maxX && other.minZ == minZ && other.maxZ == maxZ;

  @override
  int get hashCode => Object.hash(minX, maxX, minZ, maxZ);

  @override
  String toString() => 'Bounds($minX..$maxX, $minZ..$maxZ)';
}

/// Whether (x, z) is on the floor, at least `m` in from its walls: for a floor that isn't just its bounds.
typedef Floorplan = bool Function(double x, double z, double m);

/// A floor that fills its bounds.
Floorplan _within(Bounds b) =>
    (x, z, m) => x > b.minX + m && x < b.maxX - m && z > b.minZ + m && z < b.maxZ - m;

/// The desk's own frame: `t` along its width, `s` out toward the side the worker sits on.
Pt deskPoint(DeskDef d, double t, double s) =>
    (d.x + math.cos(d.rotY) * t + math.sin(d.rotY) * s, d.z - math.sin(d.rotY) * t + math.cos(d.rotY) * s);

NavRect _cornersBox(List<Pt> corners) {
  final xs = corners.map((p) => p.$1);
  final zs = corners.map((p) => p.$2);
  return (xs.reduce(math.min), xs.reduce(math.max), zs.reduce(math.min), zs.reduce(math.max));
}

/// What's in the way on the office floor, built out [wing] rows. The lounge, kitchen and plants are
/// where the office's world puts them.
Obstacles _officeObstacles(int wing) {
  final rects = <NavRect>[];
  final circles = <NavCircle>[];
  const hw = DeskSize.width / 2;
  const hd = DeskSize.depth / 2;
  for (final d in builtDesks(wing)) {
    // Desks face ±z, so their tops are axis-aligned.
    rects.add((d.x - hw, d.x + hw, d.z - hd, d.z + hd));
    final (cx, cz) = deskPoint(d, 0, 0.9);
    circles.add((cx, cz, 0.35)); // the chair
  }
  rects.add((10, 11, -2.2, 2.2)); // couch
  rects.add((12.2, 13.8, -0.8, 0.8)); // coffee table
  circles.addAll([(12.5, 3.5, 0.5), (14.5, -3.4, 0.5)]); // beanbags
  rects.add((-17, -10.75, 11.7, 12.7)); // kitchen counter and fridge
  for (final (x, z, s) in plantsAt(wing)) {
    circles.add((x, z, 0.3 * s));
  }
  // The loft's posts, the stairs up to it, and the elevator shaft.
  for (final x in [Loft.minX + 0.15, (Loft.minX + Loft.maxX) / 2]) {
    circles.add((x, Loft.minZ + 0.15, 0.14));
  }
  rects.add((Stairs.fromX, Stairs.toX, Stairs.minZ - 0.1, Stairs.maxZ));
  rects.add((Elevator.x - Elevator.width / 2, Elevator.x + Elevator.width / 2, Floor.minZ, elevatorFront));
  // The gong's frame.
  rects.add((Gong.x - Gong.width / 2 - 0.12, Gong.x + Gong.width / 2 + 0.3, Gong.z - 0.3, Gong.z + 0.3));
  // The whiteboard on its wheels.
  rects.add((
    Whiteboard.x - Whiteboard.width / 2 - 0.2,
    Whiteboard.x + Whiteboard.width / 2 + 0.2,
    Whiteboard.z - 0.48,
    Whiteboard.z + 0.48,
  ));
  // The jukebox, against the east wall.
  rects.add((
    Jukebox.x - Jukebox.depth / 2 - 0.05,
    Floor.maxX,
    Jukebox.z - Jukebox.width / 2 - 0.05,
    Jukebox.z + Jukebox.width / 2 + 0.05,
  ));
  // The arcade cabinet next to it (its control panel sticks out a little).
  rects.add((Cabinet.x - 0.45, Floor.maxX, Cabinet.z - Cabinet.width / 2 - 0.02, Cabinet.z + Cabinet.width / 2 + 0.02));
  // The bookshelf against the south wall.
  rects.add((
    Bookshelf.x - Bookshelf.width / 2 - 0.04,
    Bookshelf.x + Bookshelf.width / 2 + 0.04,
    Bookshelf.z - Bookshelf.depth / 2 - 0.03,
    Floor.maxZ,
  ));
  // The ladder up the west wall, and the fire poles: a hole with a railing round it, or a landing mat.
  // Which spot has which changes floor by floor, so the dog keeps off both.
  rects.add((Floor.minX, Floor.minX + 0.3, Ladder.z - Ladder.width / 2 - 0.05, Ladder.z + Ladder.width / 2 + 0.05));
  for (final p in poles) {
    rects.add((p.x - Pole.rail - 0.05, p.x + Pole.rail + 0.05, p.z - Pole.rail - 0.05, p.z + Pole.rail + 0.05));
  }
  // The overflow bean bags and their lap desks. They're only out while every desk is taken, but they
  // always come out in the same spots, so the dog keeps off those.
  for (final b in beanbags) {
    rects.add(
      _cornersBox([
        deskPoint(b, -0.62, -1.1),
        deskPoint(b, 0.62, -1.1),
        deskPoint(b, -0.62, 0.64),
        deskPoint(b, 0.62, 0.64),
      ]),
    );
  }
  // The board agents' kiosks, and the agent standing behind each one.
  for (final k in stations) {
    rects.add(
      _cornersBox([
        deskPoint(k, -Kiosk.width / 2, -Kiosk.depth / 2),
        deskPoint(k, Kiosk.width / 2, -Kiosk.depth / 2),
        deskPoint(k, -Kiosk.width / 2, Kiosk.stand + 0.35),
        deskPoint(k, Kiosk.width / 2, Kiosk.stand + 0.35),
      ]),
    );
  }
  // The meeting room under the loft: its glass walls, with the doorway in the north one, and the
  // table with its chairs.
  const g = 0.06;
  rects.add((MeetingRoom.minX - g, MeetingRoom.minX + g, MeetingRoom.minZ - g, MeetingRoom.maxZ));
  rects.add((MeetingRoom.minX - g, MeetingRoom.door.x0, MeetingRoom.minZ - g, MeetingRoom.minZ + g));
  rects.add((MeetingRoom.door.x1, MeetingRoom.maxX, MeetingRoom.minZ - g, MeetingRoom.minZ + g));
  const t = (x: MeetingTable.x, z: MeetingTable.z, width: MeetingTable.width, depth: MeetingTable.depth);
  rects.add((t.x - t.width / 2, t.x + t.width / 2, t.z - t.depth / 2, t.z + t.depth / 2));
  // Chairs tucked in at the table: just the middle of each, so there's a way round behind them, between
  // their backs and the glass (or the back wall), which is one cell wide.
  for (final d in meetingSeats) {
    final (cx, cz) = deskPoint(d, 0, 0.85);
    circles.add((cx, cz, 0.18));
  }
  return Obstacles(rects: rects, circles: circles);
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

/// Whether (x, z) is too close to anything in the way, or to the walls, to stand in.
bool _isBlocked(double x, double z, Floorplan on, Obstacles o) {
  if (!on(x, z, _r)) return true;
  for (final (x0, x1, z0, z1) in o.rects) {
    if (x > x0 - _r && x < x1 + _r && z > z0 - _r && z < z1 + _r) return true;
  }
  for (final (cx, cz, r) in o.circles) {
    if (_hypot(x - cx, z - cz) < r + _r) return true;
  }
  return false;
}

int _sign(double v) => v > 0 ? 1 : (v < 0 ? -1 : 0);

/// A floor on a half-meter grid, with what's in the way marked: where you can walk, and the way round.
class NavGrid {
  /// [on]: the floor's shape, when it doesn't fill [bounds] (the office built out into its back office).
  NavGrid(this.bounds, Obstacles obstacles, [Floorplan? on])
    : _on = on ?? _within(bounds),
      cols = ((bounds.maxX - bounds.minX) / _cell).ceil(),
      rows = ((bounds.maxZ - bounds.minZ) / _cell).ceil() {
    _grid = Uint8List(cols * rows);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        _grid[r * cols + c] =
            _isBlocked(bounds.minX + (c + 0.5) * _cell, bounds.minZ + (r + 0.5) * _cell, _on, obstacles) ? 1 : 0;
      }
    }
  }

  final Bounds bounds;
  final int cols;
  final int rows;
  final Floorplan _on;
  late final Uint8List _grid;

  /// A grid cell, reading anything off the grid as open (as the TS typed-array read of `undefined` does).
  bool _blocked(int i) => i >= 0 && i < _grid.length && _grid[i] != 0;

  int _colOf(double x) => ((x - bounds.minX) / _cell).floor().clamp(0, cols - 1);
  int _rowOf(double z) => ((z - bounds.minZ) / _cell).floor().clamp(0, rows - 1);
  Pt _centerOf(int i) => (bounds.minX + ((i % cols) + 0.5) * _cell, bounds.minZ + ((i ~/ cols) + 0.5) * _cell);

  bool walkable(double x, double z) => _on(x, z, 0) && !_blocked(_rowOf(z) * cols + _colOf(x));

  /// Whether it can trot straight from a to b: every cell the line crosses is clear.
  bool clearLine(Pt a, Pt b) {
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
    var nextC = sc != 0 ? (bounds.minX + (c + (sc > 0 ? 1 : 0)) * _cell - a.$1) / dx : double.infinity;
    var nextR = sr != 0 ? (bounds.minZ + (r + (sr > 0 ? 1 : 0)) * _cell - a.$2) / dz : double.infinity;
    for (var n = 0; n <= cols + rows; n++) {
      if (_blocked(r * cols + c)) return false;
      if (c == c1 && r == r1) return true;
      if ((nextC - nextR).abs() < 1e-9) {
        // Right through a corner: both cells beside it count.
        if (_blocked(r * cols + c + sc) || _blocked((r + sr) * cols + c)) return false;
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

  /// A* over the grid, then pulled tight: the corners of a route from [from] to [to], both included.
  List<Pt> route(Pt from, Pt to) {
    final goal = nearestWalkable(to);
    final start = nearestWalkable(from);
    final lead = start == from ? [from] : [from, start];
    if (clearLine(start, goal)) return [...lead, goal];
    final s = _rowOf(start.$2) * cols + _colOf(start.$1);
    final g = _rowOf(goal.$2) * cols + _colOf(goal.$1);
    final cost = Float64List(_grid.length)..fillRange(0, _grid.length, double.infinity);
    final came = Int32List(_grid.length)..fillRange(0, _grid.length, -1);
    final closed = Uint8List(_grid.length);
    final heap = _Heap();
    final gc = g % cols;
    final gr = g ~/ cols;
    double h(int i) {
      final dx = ((i % cols) - gc).abs();
      final dz = ((i ~/ cols) - gr).abs();
      return math.max(dx, dz) + (math.sqrt2 - 1) * math.min(dx, dz);
    }

    cost[s] = 0;
    heap.push(s, h(s));
    while (heap.size > 0) {
      final i = heap.pop();
      if (i == g) break;
      if (closed[i] != 0) continue;
      closed[i] = 1;
      final c = i % cols;
      final r = i ~/ cols;
      for (var dz = -1; dz <= 1; dz++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dz == 0) continue;
          final nc = c + dx;
          final nr = r + dz;
          if (nc < 0 || nr < 0 || nc >= cols || nr >= rows) continue;
          final n = nr * cols + nc;
          if (_grid[n] != 0 || closed[n] != 0) continue;
          // No cutting corners past something in the way.
          if (dx != 0 && dz != 0 && (_grid[r * cols + nc] != 0 || _grid[nr * cols + c] != 0)) continue;
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
      while (j > i + 1 && !clearLine(pts[i], pts[j])) {
        j--;
      }
      out.add(pts[j]);
      i = j;
    }
    return out;
  }

  /// From beside [seat], where a worker hops down, round the furniture to [to]. It gets down on
  /// whichever side of its chair (its bean bag, its kiosk) is the shorter way.
  List<Pt> wayFrom(DeskDef seat, Pt to) {
    final ways = [-1.0, 1.0].map((side) {
      // Beside the chair and back from the desk into the aisle, off the bean bag and round behind it, or
      // out from behind the kiosk and round its front, into the room.
      final (down, back) = seat.beanbag
          ? (deskPoint(seat, side * 1.05, 0.1), deskPoint(seat, side * 1.05, 1.25))
          : seat.station != null
          ? (deskPoint(seat, side * 0.95, Kiosk.stand), deskPoint(seat, side * 0.95, -1))
          : (seat.wing ?? 0) > 0
          // In the back office the chair has its back to a wall or the next row: out to the side of it instead.
          ? (deskPoint(seat, side * 0.7, 0.95), deskPoint(seat, side * 0.95, 1.25))
          // At the meeting table there's less room behind the chair, before the glass.
          : (deskPoint(seat, side * 0.7, 0.95), deskPoint(seat, side * 0.7, seat.room ? 1.4 : 1.75));
      // A bean bag or a kiosk can stand with one side up against something (the elevator, by the queue).
      final blocked = (seat.beanbag || seat.station != null) && !walkable(down.$1, down.$2);
      final pts = [down, ...route(back, to)];
      return (pts: pts, cost: (blocked ? 1000 : 0) + pathLength(pts));
    }).toList();
    return ways[0].cost <= ways[1].cost ? ways[0].pts : ways[1].pts;
  }

  /// From [from], round the furniture to beside [seat]'s chair (the last point), on whichever side is
  /// the shorter way, where it hops on.
  List<Pt> wayTo(Pt from, DeskDef seat) {
    final ways = [-1.0, 1.0].map((side) {
      final pts = [
        ...route(from, deskPoint(seat, side * 0.7, seat.room ? 1.4 : 1.75)),
        deskPoint(seat, side * 0.7, 0.95),
      ];
      return (pts: pts, cost: pathLength(pts));
    }).toList();
    return ways[0].cost <= ways[1].cost ? ways[0].pts : ways[1].pts;
  }
}

/// How far it is along [pts], corner to corner.
double pathLength(List<Pt> pts) {
  var n = 0.0;
  for (var i = 1; i < pts.length; i++) {
    n += _hypot(pts[i].$1 - pts[i - 1].$1, pts[i].$2 - pts[i - 1].$2);
  }
  return n;
}

/// The office floor downstairs (no stairs, no loft, no elevator), built out by level, each made the
/// first time it's needed.
final List<NavGrid?> _officeNavs = List.filled(Wing.rows + 1, null);

/// The office floor downstairs, built out [wing] rows.
NavGrid officeNav([int wing = 0]) {
  final level = wingLevel(wing);
  // Through where the north wall was, into the back office: between its walls, short of its back one.
  bool on(double x, double z, double m) =>
      (x > Floor.minX + m && x < Floor.maxX - m && z > Floor.minZ + m && z < Floor.maxZ - m) ||
      (level > 0 && x > Wing.minX + m && x < Wing.maxX - m && z > wingMinZ(level) + m && z < Floor.maxZ - m);
  return _officeNavs[level] ??= NavGrid(
    Bounds(minX: Floor.minX, maxX: Floor.maxX, minZ: wingMinZ(level), maxZ: Floor.maxZ),
    _officeObstacles(level),
    on,
  );
}

/// The office floor as it is until it's built out (TS OFFICE_NAV).
final NavGrid officeNavGrid = officeNav(0);

bool walkable(double x, double z, [int wing = 0]) => officeNav(wing).walkable(x, z);

/// The middle of the nearest cell it can stand in on the office floor.
Pt nearestWalkable(Pt p, [int wing = 0]) => officeNav(wing).nearestWalkable(p);

/// A* over the office floor's grid, then pulled tight: the corners of a route from [from] to [to], both included.
List<Pt> route(Pt from, Pt to, [int wing = 0]) => officeNav(wing).route(from, to);

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

/// Just inside the balcony doors, in the south wall.
final Pt _balconyIn = (balconyDoor.u, Floor.maxZ - 0.45);

/// Down the middle of the steps outside it.
const double _stepsX = (ExitStairs.minX + ExitStairs.maxX) / 2;

/// Along the near sidewalk, between the lot and the trees planted in it.
const double _sidewalkZ = Road.minZ - 1.7;

/// How far west along the sidewalk they get before they're gone.
const double _walkOffX = -38;

/// Where a worker called to a meeting comes in: out of the elevator.
const Pt _inFrom = (Elevator.x, elevatorFront + 0.5);

/// A worker's walk in to its seat when it's called to a meeting: out of the elevator and round the
/// furniture to beside its chair (the last point), on whichever side is the shorter way, where it hops on.
List<Pt> wayIn(DeskDef seat, [int wing = 0]) => officeNav(wing).wayTo(_inFrom, seat);

/// A worker's walk out of the building once it's sent home. The first point is where it hops down,
/// beside its chair (or its bean bag) on whichever side is the shorter way out; then round the
/// furniture to the exit door in the west wall, across the landing outside, down the steps to the
/// street and off along the sidewalk.
List<Pt> wayHome(DeskDef seat, [int wing = 0]) {
  final inside = officeNav(wing).wayFrom(seat, _exit);
  return [
    ...inside,
    (_stepsX, exitDoor.u),
    ...walkOff((_stepsX, ExitStairs.landingZ1 + (ExitStairs.steps - 1) * ExitStairs.run + 0.6)),
  ];
}

/// The same walk on a floor above the bottom one, which has no exit door: round the furniture to the
/// balcony doors, out across the balcony and up to its railing ([Parachute.jump]), where it goes over.
List<Pt> wayToBalcony(DeskDef seat, [int wing = 0]) {
  final inside = officeNav(wing).wayFrom(seat, _balconyIn);
  return [...inside, (balconyDoor.u, Balcony.minZ + 0.4), (Parachute.jump.x, Parachute.jump.z)];
}

/// From [from], down on the street, over to the near sidewalk and off along it to the west, where they're gone.
List<Pt> walkOff(Pt from) => [from, (from.$1, _sidewalkZ), (_walkOffX, _sidewalkZ)];
