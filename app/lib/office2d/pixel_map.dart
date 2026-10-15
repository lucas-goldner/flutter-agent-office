// The 2D office's map (👾 2D view): the floor from above as 16-bit pixel art (retro.dart: the Mega
// Drive's colors, shaded ramps, dark outlines, light from the top left), drawn from the same layout
// the 3D office is built from (office_shared/layout.dart), so the two always agree. Everything is
// drawn in map pixels, [kPx] to a meter, on whole pixels and without smoothing; the view scales the
// result up with nearest-neighbour filtering. Outside, Green Hill's checkered earth.

import 'dart:math' as math;
import 'dart:ui';

import 'package:office_shared/layout.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:office_shared/nav.dart' show Bounds, deskPoint;

import 'retro.dart';

/// Map pixels to a meter.
const double kPx = 12;

/// What the map shows, in meters: the office's floor with a meter round it, the back office when it's
/// built out, and the balcony to the south; or, on a map of its own (the castle, the space station),
/// its hall with a couple of meters round it. [office] and [plan] pick which; the office's to start.
abstract final class MapBounds {
  static double minX = Floor.minX - 2.2;
  static double maxX = Floor.maxX + 1;
  static double minZ = Floor.minZ - 1;
  static double maxZ = Balcony.maxZ + 0.6;

  /// The office, built out [wing] rows into the back office.
  static void office([int wing = 0]) {
    minX = Floor.minX - 2.2;
    maxX = Floor.maxX + 1;
    minZ = wingMinZ(wing) - 1;
    maxZ = Balcony.maxZ + 0.6;
  }

  /// A map of its own: its hall [b], with room round it for its walls and what's outside.
  static void plan(Bounds b) {
    minX = b.minX - 2;
    maxX = b.maxX + 2;
    minZ = b.minZ - 2;
    maxZ = b.maxZ + 2;
  }

  static int get width => ((maxX - minX) * kPx).round();
  static int get height => ((maxZ - minZ) * kPx).round();
}

/// A floor point (meters) on the map (map pixels).
Offset mapPoint(double x, double z) => Offset((x - MapBounds.minX) * kPx, (z - MapBounds.minZ) * kPx);

/// A map point (map pixels) on the floor (meters).
({double x, double z}) floorPoint(Offset p) => (x: p.dx / kPx + MapBounds.minX, z: p.dy / kPx + MapBounds.minZ);

/// The palette: warm wood, cream walls, the 3D office's furniture colors.
abstract final class Pal {
  static const outside = Color(0xFF263238);
  static const grass = Color(0xFF2E5E3E);
  static const floorA = Color(0xFFE8C99B);
  static const floorB = Color(0xFFDDBB8B);
  static const floorLine = Color(0xFFC9A574);
  static const wall = Color(0xFF5B4636);
  static const wallTop = Color(0xFF7A604B);
  static const window = Color(0xFF9AD1F5);
  static const door = Color(0xFFB98B5A);
  static const desk = Color(0xFFB08968);
  static const deskEdge = Color(0xFF7F5539);
  static const monitor = Color(0xFF2B2D42);
  static const screen = Color(0xFF4CC9F0);
  static const chair = Color(0xFF3D405B);
  static const cork = Color(0xFFC49A6C);
  static const paper = Color(0xFFFFFAF3);
  static const ink = Color(0xFF2B2D42);
  static const plant = Color(0xFF52B788);
  static const plantDark = Color(0xFF2D6A4F);
  static const pot = Color(0xFFBC6C25);
  static const couch = Color(0xFF457B9D);
  static const couchDark = Color(0xFF1D3557);
  static const rug = Color(0xFFF4A261);
  static const steel = Color(0xFF8D99AE);
  static const glass = Color(0x5590E0EF);
  static const deck = Color(0xFF9C6644);
  static const deckLine = Color(0xFF7F5539);
  static const deckEdge = Color(0xFF6F4518);
  static const kitchen = Color(0xFFE5E5E5);
  static const counter = Color(0xFF6C757D);
  static const red = Color(0xFFEF476F);
  static const green = Color(0xFF06D6A0);
  static const yellow = Color(0xFFFFD166);
  static const blue = Color(0xFF118AB2);
  static const stairs = Color(0xFFA98467);
  static const floorC = Color(0xFFD9B27C);
  static const soilA = Color(0xFFD08A3C);
  static const soilB = Color(0xFF8E4E1E);
  static const grassTop = Color(0xFF3CC03C);
  static const carpet = Color(0xFFE6D3B0);
  static const gold = Color(0xFFE9C46A);
  static const purple = Color(0xFF9D4EDD);
  static const metal = Color(0xFFB0B8C4);
}

/// Draws whole map pixels, in the Mega Drive's colors.
class Pixels {
  Pixels(this.c);
  final Canvas c;
  final Paint _p = Paint()..isAntiAlias = false;

  /// Map pixels from meters, on whole pixels.
  static int _x(double x) => ((x - MapBounds.minX) * kPx).round();
  static int _z(double z) => ((z - MapBounds.minZ) * kPx).round();

  /// A rectangle of whole map pixels, x0..x1 by y0..y1 exclusive.
  void rect(int x0, int y0, int x1, int y1, Color color) {
    if (x1 <= x0 || y1 <= y0) return;
    c.drawRect(Rect.fromLTRB(x0.toDouble(), y0.toDouble(), x1.toDouble(), y1.toDouble()), _p..color = md(color));
  }

  /// A filled box from (x0, z0) to (x1, z1) in meters, snapped to whole map pixels.
  void box(double x0, double x1, double z0, double z1, Color color) {
    final a = _x(math.min(x0, x1)), b = _x(math.max(x0, x1)), t = _z(math.min(z0, z1)), u = _z(math.max(z0, z1));
    rect(a, t, math.max(a + 1, b), math.max(t + 1, u), color);
  }

  /// A box [w] by [d] meters centred on (x, z).
  void at(double x, double z, double w, double d, Color color) =>
      box(x - w / 2, x + w / 2, z - d / 2, z + d / 2, color);

  /// One map pixel (or [n] by [n]) at map pixel (px, py).
  void dot(num px, num py, Color color, [int n = 1]) => c.drawRect(
    Rect.fromLTWH(px.floorToDouble(), py.floorToDouble(), n.toDouble(), n.toDouble()),
    _p..color = md(color),
  );

  /// A rough disc of radius [r] meters at (x, z), pixel by pixel.
  void disc(double x, double z, double r, Color color) {
    final o = mapPoint(x, z);
    final rp = r * kPx;
    for (var dy = -rp.ceil(); dy <= rp.ceil(); dy++) {
      for (var dx = -rp.ceil(); dx <= rp.ceil(); dx++) {
        if (dx * dx + dy * dy <= rp * rp) dot(o.dx + dx, o.dy + dy, color);
      }
    }
  }

  /// A solid thing seen from above: a dark outline, its top and left edges catching the light, its
  /// foot and right side in shadow, and its shadow on the floor down and to the right.
  void block(double x0, double x1, double z0, double z1, Color base, {bool shadow = true}) {
    final a = _x(math.min(x0, x1)), b = math.max(_x(math.min(x0, x1)) + 3, _x(math.max(x0, x1)));
    final t = _z(math.min(z0, z1)), u = math.max(_z(math.min(z0, z1)) + 3, _z(math.max(z0, z1)));
    blockPx(a, t, b, u, base, shadow: shadow);
  }

  void blockAt(double x, double z, double w, double d, Color base, {bool shadow = true}) =>
      block(x - w / 2, x + w / 2, z - d / 2, z + d / 2, base, shadow: shadow);

  void blockPx(int a, int t, int b, int u, Color base, {bool shadow = true}) {
    final r = ramp(base);
    if (shadow) {
      c.drawRect(Rect.fromLTRB(a + 2.0, t + 2.0, b + 2.0, u + 2.0), _p..color = const Color(0x4A10102A));
    }
    rect(a, t, b, u, r[0]);
    rect(a + 1, t + 1, b - 1, u - 1, r[2]);
    rect(a + 1, t + 1, b - 1, t + 2, r[4]);
    rect(a + 1, t + 2, a + 2, u - 1, r[3]);
    rect(a + 1, u - 2, b - 1, u - 1, r[1]);
    rect(b - 2, t + 2, b - 1, u - 1, r[1]);
  }

  /// A ball (a beanbag, the leaves of a plant, the gong) shaded from the top left, outlined.
  void ball(double x, double z, double r, Color base, {bool shadow = true, bool outline = true}) {
    final o = mapPoint(x, z);
    final cx = o.dx.roundToDouble(), cy = o.dy.roundToDouble();
    final rp = math.max(1.5, r * kPx);
    final rr = ramp(base);
    final n = rp.ceil() + 1;
    if (shadow) {
      for (var dy = -n; dy <= n; dy++) {
        for (var dx = -n; dx <= n; dx++) {
          if ((dx - 2) * (dx - 2) + (dy - 2) * (dy - 2) <= rp * rp) {
            c.drawRect(Rect.fromLTWH(cx + dx, cy + dy, 1, 1), _p..color = const Color(0x3A10102A));
          }
        }
      }
    }
    for (var dy = -n; dy <= n; dy++) {
      for (var dx = -n; dx <= n; dx++) {
        final d2 = (dx + 0.5) * (dx + 0.5) + (dy + 0.5) * (dy + 0.5);
        if (d2 > rp * rp) {
          if (outline && d2 <= (rp + 1) * (rp + 1)) dot(cx + dx, cy + dy, rr[0]);
          continue;
        }
        final nx = (dx + 0.5) / rp, ny = (dy + 0.5) / rp;
        dot(cx + dx, cy + dy, rr[litShade(nx, ny, math.sqrt(math.max(0, 1 - nx * nx - ny * ny)))]);
      }
    }
  }

  /// A railing round (x, z): a shaded metal ring two pixels wide, outlined.
  void ring(double x, double z, double r, Color base) {
    final o = mapPoint(x, z);
    final cx = o.dx.roundToDouble(), cy = o.dy.roundToDouble();
    final rp = r * kPx;
    final rr = ramp(base);
    final n = rp.ceil() + 2;
    for (var dy = -n; dy <= n; dy++) {
      for (var dx = -n; dx <= n; dx++) {
        final d = math.sqrt((dx + 0.5) * (dx + 0.5) + (dy + 0.5) * (dy + 0.5));
        if (d > rp + 1 || d < rp - 3) continue;
        if (d > rp || d < rp - 2) {
          dot(cx + dx, cy + dy, rr[0]);
          continue;
        }
        // Lit on the side toward the light, as a round rail is.
        final lit = -((dx + 0.5) / d) * 0.6 - ((dy + 0.5) / d) * 0.7;
        dot(cx + dx, cy + dy, rr[lit > 0.5 ? 4 : (lit > 0 ? 3 : (lit > -0.5 ? 2 : 1))]);
      }
    }
  }

  /// A checker of [a] and [b] every [cell] pixels (1: a dither, the 16-bit way to blend two colors).
  void checker(double x0, double x1, double z0, double z1, Color a, Color b, {int cell = 1}) {
    final ax = _x(x0), bx = _x(x1), az = _z(z0), bz = _z(z1);
    rect(ax, az, bx, bz, a);
    for (var y = az; y < bz; y += cell) {
      for (var x = ax; x < bx; x += cell) {
        if (((x ~/ cell) + (y ~/ cell)).isOdd) rect(x, y, math.min(x + cell, bx), math.min(y + cell, bz), b);
      }
    }
  }
}

int _hash(int a, int b) => ((a * 73856093) ^ (b * 19349663) ^ 0x5bd1e995) & 0x7fffffff;

/// The floor and everything that doesn't move, drawn once into [c] (MapBounds.width × height, after
/// MapBounds.office([wing])). [wing]: how many rows the back office is built out (see [Wing]): its bay
/// through the north wall, with a rug and a pair of desks down each row.
void paintFloorPlan(Canvas c, {int wing = 0}) {
  final px = Pixels(c);
  final level = wingLevel(wing);
  _outside(px, wingMinZ(level));
  _balcony(px);
  _exitStairs(px);
  _planks(px);
  if (level > 0) {
    _planks(px, x0: Wing.minX, x1: Wing.maxX, z0: wingMinZ(level), z1: Floor.minZ);
    for (var row = 1; row <= level; row++) {
      final z = wingRowZ(row);
      _rug(px, Wing.minX + 0.9, Wing.maxX - 0.9, z - 1.7, z + 1.7);
    }
  }

  // The lounge rug, with a border and a diamond pattern.
  _rug(px, 9.4, 15, -3, 3);

  // The kitchen in the south-west corner: checkered tiles, the counter and the fridge.
  px.checker(-17.8, -10.4, 10.6, Floor.maxZ, const Color(0xFFF2F2F2), const Color(0xFFC9D1D9), cell: 6);
  px.block(-17, -10.75, 11.7, 12.7, Pal.counter);
  px.block(-16.8, -12.1, 11.85, 12.5, const Color(0xFFCED4DA), shadow: false);
  px.blockAt(-11.3, 12.2, 1, 0.9, const Color(0xFFF8F9FA)); // the fridge
  px.blockAt(-15.7, 12.2, 0.5, 0.5, const Color(0xFF3D405B), shadow: false); // the coffee machine
  px.dot(Pixels._x(-15.75), Pixels._z(12.1), Pal.red);

  // The meeting room under the loft: carpet, glass walls and the long table.
  px.checker(
    MeetingRoom.minX,
    MeetingRoom.maxX,
    MeetingRoom.minZ,
    MeetingRoom.maxZ,
    Pal.carpet,
    const Color(0xFFD9C29A),
  );
  for (final (a, b, z0, z1) in [
    (MeetingRoom.minX - 0.05, MeetingRoom.minX + 0.05, MeetingRoom.minZ, MeetingRoom.maxZ),
    (MeetingRoom.minX, MeetingRoom.door.x0, MeetingRoom.minZ - 0.05, MeetingRoom.minZ + 0.05),
    (MeetingRoom.door.x1, MeetingRoom.maxX, MeetingRoom.minZ - 0.05, MeetingRoom.minZ + 0.05),
  ]) {
    px.box(a, b, z0, z1, Pal.window);
  }
  px.blockAt(MeetingTable.x, MeetingTable.z, MeetingTable.width, MeetingTable.depth, Pal.desk);
  for (final s in meetingSeats) {
    final (cx, cz) = deskPoint(s, 0, 0.85);
    px.blockAt(cx, cz, 0.46, 0.46, Pal.chair);
  }
  px.blockAt(MeetingBoard.x, Floor.maxZ - 0.07, MeetingBoard.width, 0.14, Pal.paper, shadow: false);

  // The stairs up to the loft, along the south wall: each step a lit edge.
  final stepW = (Stairs.toX - Stairs.fromX) / Stairs.steps;
  for (var i = 0; i < Stairs.steps; i++) {
    final x = Stairs.fromX + i * stepW;
    px.block(x, x + stepW, Stairs.minZ, Stairs.maxZ, i.isEven ? Pal.stairs : Pal.deck, shadow: false);
  }

  for (final d in builtDesks(level)) {
    _desk(px, d);
  }

  // The lounge: the couch and its cushions, the coffee table, the beanbags.
  px.block(10, 11, -2.2, 2.2, Pal.couchDark);
  for (var i = 0; i < 3; i++) {
    final z = -2.05 + i * 1.37;
    px.block(10.3, 10.95, z, z + 1.33, Pal.couch, shadow: false);
  }
  px.block(12.2, 13.8, -0.8, 0.8, Pal.desk);
  px.blockAt(13.2, -0.2, 0.3, 0.3, Pal.red, shadow: false); // a mug
  px.ball(12.5, 3.5, 0.5, Pal.red);
  px.ball(14.5, -3.4, 0.5, Pal.yellow);

  // The boards on the north wall, and the board agents' kiosks.
  for (final (b, face) in [(Boards.issues, Pal.cork), (Boards.queue, Pal.paper), (Boards.pulls, Pal.cork)]) {
    px.blockAt(b.x, Floor.minZ + 0.13, b.width, 0.26, Pal.deckEdge, shadow: true);
    if (face == Pal.cork) {
      px.checker(
        b.x - b.width / 2 + 0.1,
        b.x + b.width / 2 - 0.1,
        Floor.minZ + 0.05,
        Floor.minZ + 0.21,
        Pal.cork,
        const Color(0xFFB0855A),
      );
    } else {
      px.box(b.x - b.width / 2 + 0.1, b.x + b.width / 2 - 0.1, Floor.minZ + 0.05, Floor.minZ + 0.21, face);
    }
    for (var i = 0; i < 6; i++) {
      px.blockAt(
        b.x - b.width / 2 + 0.6 + i * 0.95,
        Floor.minZ + 0.14,
        0.5,
        0.18,
        [Pal.yellow, Pal.paper, Pal.green, Pal.red][i % 4],
        shadow: false,
      );
    }
  }
  for (final k in stations) {
    px.blockAt(k.x, k.z, Kiosk.width, Kiosk.depth, Pal.steel);
    px.box(k.x - Kiosk.width / 2 + 0.12, k.x + Kiosk.width / 2 - 0.12, k.z - 0.08, k.z + 0.08, Pal.screen);
  }
  // The services board and the TV on the east wall; the machine monitor on the west wall.
  px.blockAt(Floor.maxX - 0.12, Boards.services.z, 0.24, Boards.services.width, const Color(0xFF3A5A40), shadow: false);
  px.blockAt(Floor.maxX - 0.1, Tv.z, 0.22, Tv.width, const Color(0xFF2B2D42), shadow: false);
  px.blockAt(Floor.minX + 0.1, MachineMonitor.z, 0.22, MachineMonitor.width, const Color(0xFF2B2D42), shadow: false);

  // The elevator: its shaft, the car's floor and the doors, closed in the middle.
  px.block(
    Elevator.x - Elevator.width / 2,
    Elevator.x + Elevator.width / 2,
    Floor.minZ,
    elevatorFront,
    Pal.metal,
    shadow: false,
  );
  px.checker(
    ElevatorCar.minX,
    ElevatorCar.maxX,
    ElevatorCar.minZ,
    ElevatorCar.maxZ - 0.1,
    const Color(0xFF6C757D),
    const Color(0xFF5A6169),
  );
  px.block(
    Elevator.x - Elevator.doorWidth / 2,
    Elevator.x + Elevator.doorWidth / 2,
    elevatorFront - 0.16,
    elevatorFront,
    const Color(0xFFDEE2E6),
    shadow: false,
  );
  px.box(Elevator.x - 0.5 / kPx, Elevator.x + 0.5 / kPx, elevatorFront - 0.16, elevatorFront, const Color(0xFF6C757D));

  // The gong on its frame.
  px.blockAt(Gong.x, Gong.z, Gong.width, 0.2, Pal.deckEdge);
  px.ball(Gong.x, Gong.z, 0.55, Pal.gold);
  px.ball(Gong.x, Gong.z, 0.2, const Color(0xFFD4A373), shadow: false);

  // The whiteboard on its wheels, with a doodle.
  px.blockAt(Whiteboard.x, Whiteboard.z, Whiteboard.width + 0.2, 0.32, Pal.steel);
  px.box(
    Whiteboard.x - Whiteboard.width / 2,
    Whiteboard.x + Whiteboard.width / 2,
    Whiteboard.z - 0.06,
    Whiteboard.z + 0.06,
    Pal.paper,
  );
  for (var i = 0; i < 5; i++) {
    px.dot(
      Pixels._x(Whiteboard.x - 1.2 + i * 0.5),
      Pixels._z(Whiteboard.z) - (i.isEven ? 0 : 1),
      i < 3 ? Pal.blue : Pal.red,
    );
  }

  // The jukebox and the arcade cabinet on the east wall; the bookshelf on the south wall.
  px.blockAt(Jukebox.x, Jukebox.z, Jukebox.depth, Jukebox.width, Pal.purple);
  px.checker(
    Jukebox.x - 0.25,
    Jukebox.x + 0.1,
    Jukebox.z - Jukebox.width / 2 + 0.2,
    Jukebox.z + Jukebox.width / 2 - 0.2,
    Pal.yellow,
    const Color(0xFFF4A261),
  );
  px.blockAt(Cabinet.x, Cabinet.z, Cabinet.depth, Cabinet.width, const Color(0xFF3D405B));
  px.box(
    Cabinet.x - 0.3,
    Cabinet.x,
    Cabinet.z - Cabinet.width / 2 + 0.12,
    Cabinet.z + Cabinet.width / 2 - 0.12,
    const Color(0xFF7209B7),
  );
  px.box(Cabinet.x - 0.25, Cabinet.x - 0.05, Cabinet.z - 0.1, Cabinet.z + 0.1, Pal.screen);
  px.blockAt(Bookshelf.x, Bookshelf.z, Bookshelf.width, Bookshelf.depth, Pal.deckEdge);
  for (var i = 0; i < 7; i++) {
    px.blockAt(
      Bookshelf.x - Bookshelf.width / 2 + 0.18 + i * 0.22,
      Bookshelf.z - 0.04,
      0.18,
      0.26,
      [Pal.red, Pal.blue, Pal.yellow, Pal.green][i % 4],
      shadow: false,
    );
  }

  // The fire pole's railing, and the ladder on the west wall.
  for (final p in poles) {
    px.disc(p.x, p.z, Pole.radius + 0.3, const Color(0xFF1D1D2E)); // the hole down
    px.ring(p.x, p.z, Pole.rail, Pal.metal);
    px.ball(p.x, p.z, Pole.radius + 0.06, const Color(0xFFE9ECEF), shadow: false);
  }
  px.block(
    Floor.minX,
    Floor.minX + 0.34,
    Ladder.z - Ladder.width / 2,
    Ladder.z + Ladder.width / 2,
    Pal.deckEdge,
    shadow: false,
  );
  for (var z = Ladder.z - Ladder.width / 2 + 0.15; z < Ladder.z + Ladder.width / 2 - 0.1; z += 0.25) {
    px.box(Floor.minX + 0.05, Floor.minX + 0.3, z, z + 1 / kPx, Pal.stairs);
  }

  // Plants in their pots: a terracotta pot, a bush of leaves catching the light.
  for (final (x, z, s) in plantsAt(level)) {
    px.ball(x, z, 0.3 * s, Pal.pot);
    px.ball(x - 0.08 * s, z - 0.06 * s, 0.22 * s, Pal.plant, shadow: false);
    px.ball(x + 0.1 * s, z + 0.02 * s, 0.17 * s, Pal.plantDark, shadow: false);
    px.ball(x - 0.02 * s, z - 0.14 * s, 0.13 * s, Pal.plant, shadow: false, outline: false);
  }

  // The sign that says there's room to grow (or that it's as big as it gets), on the back wall.
  final back = wingMinZ(level);
  px.blockAt(
    (Wing.minX + Wing.maxX) / 2,
    back + 0.08,
    2.6,
    0.14,
    level >= Wing.rows ? Pal.green : Pal.yellow,
    shadow: false,
  );

  _walls(px, level);
}

/// Green Hill: checkered earth all round, and a band of grass along the building with tufts.
void _outside(Pixels px, [double top = Floor.minZ]) {
  const cell = 8;
  final w = MapBounds.width, h = MapBounds.height;
  final a = ramp(Pal.soilA), b = ramp(Pal.soilB);
  for (var y = 0; y < h; y += cell) {
    for (var x = 0; x < w; x += cell) {
      final odd = ((x ~/ cell) + (y ~/ cell)).isOdd;
      final r = odd ? b : a;
      px.rect(x, y, x + cell, y + cell, r[2]);
      px.rect(x, y, x + cell, y + 1, r[3]);
      px.rect(x, y + cell - 1, x + cell, y + cell, r[1]);
    }
  }
  const pad = wallT + 0.6;
  final g = ramp(Pal.grass);
  final x0 = Pixels._x(Floor.minX - pad), x1 = Pixels._x(Floor.maxX + pad);
  final z0 = Pixels._z(top - pad), z1 = Pixels._z(Floor.maxZ + pad);
  px.rect(x0 - 1, z0 - 1, x1 + 1, z1 + 1, g[0]);
  px.rect(x0, z0, x1, z1, g[2]);
  // Tufts: a scalloped light edge and blades scattered over it.
  for (var x = x0; x < x1; x++) {
    if (x % 4 < 2) {
      px.rect(x, z0, x + 1, z0 + 2, g[4]);
      px.rect(x, z1 - 2, x + 1, z1, g[1]);
    }
  }
  for (var y = z0; y < z1; y++) {
    if (y % 4 < 2) {
      px.rect(x0, y, x0 + 2, y + 1, g[3]);
      px.rect(x1 - 2, y, x1, y + 1, g[1]);
    }
  }
  for (var i = 0; i < 400; i++) {
    final hsh = _hash(i, 77);
    final x = x0 + hsh % (x1 - x0), y = z0 + (hsh >> 9) % (z1 - z0);
    px.rect(x, y, x + 1, y + 2, (hsh >> 3).isOdd ? g[3] : g[1]);
  }
}

void _balcony(Pixels px) {
  final x0 = Pixels._x(Balcony.minX), x1 = Pixels._x(Balcony.maxX);
  final z0 = Pixels._z(Balcony.minZ), z1 = Pixels._z(Balcony.maxZ);
  final r = ramp(Pal.deck);
  var row = 0;
  for (var y = z0; y < z1; y += 6, row++) {
    px.rect(x0, y, x1, math.min(y + 6, z1), r[row.isEven ? 2 : 3]);
    px.rect(x0, y, x1, y + 1, r[4]);
    px.rect(x0, math.min(y + 6, z1) - 1, x1, math.min(y + 6, z1), r[1]);
    for (var x = x0 + (_hash(row, 3) % 20); x < x1; x += 24) {
      px.rect(x, y, x + 1, math.min(y + 6, z1), r[0]);
    }
  }
  px.blockPx(x0, z1 - 2, x1, z1 + 1, Pal.metal, shadow: false);
  px.blockPx(x0 - 1, z0, x0 + 2, z1 + 1, Pal.metal, shadow: false);
  px.blockPx(x1 - 2, z0, x1 + 1, z1 + 1, Pal.metal, shadow: false);
  px.ball(Ashtray.x, Ashtray.z, 0.22, Pal.metal);
  px.checker(
    GolfTee.x - GolfTee.size / 2,
    GolfTee.x + GolfTee.size / 2,
    GolfTee.z - GolfTee.size / 2,
    GolfTee.z + GolfTee.size / 2,
    Pal.plant,
    Pal.grassTop,
  );
  px.ball(GolfTee.ball.x, GolfTee.ball.z, 0.07, Pal.paper);
}

void _exitStairs(Pixels px) {
  px.block(ExitStairs.minX, ExitStairs.maxX, ExitStairs.landingZ0, ExitStairs.landingZ1, Pal.metal, shadow: false);
  for (var i = 0; i < 6; i++) {
    final z = ExitStairs.landingZ1 + i * ExitStairs.run;
    px.block(ExitStairs.minX, ExitStairs.maxX, z, z + ExitStairs.run, i.isEven ? Pal.stairs : Pal.deck, shadow: false);
  }
}

/// The floor: staggered planks of a few tones, each with a lit top edge, a dark seam and some grain.
void _planks(
  Pixels px, {
  double x0 = Floor.minX,
  double x1 = Floor.maxX,
  double z0 = Floor.minZ,
  double z1 = Floor.maxZ,
}) {
  _plankRows(px, Pixels._x(x0), Pixels._x(x1), Pixels._z(z0), Pixels._z(z1));
}

void _plankRows(Pixels px, int x0, int x1, int z0, int z1) {
  const plankH = 6, plankW = 29;
  final tones = [
    ramp(const Color(0xFFCEAC74)),
    ramp(const Color(0xFFCEAC74)),
    ramp(const Color(0xFFCEAC57)),
    ramp(const Color(0xFFCE9074)),
  ];
  var row = 0;
  for (var y = z0; y < z1; y += plankH, row++) {
    final yb = math.min(y + plankH, z1);
    var col = 0;
    for (var x = x0 - (row.isOdd ? plankW ~/ 2 : 0); x < x1; x += plankW, col++) {
      final int a = math.max(x, x0), b = math.min(x + plankW, x1);
      final hsh = _hash(row, col);
      final r = tones[hsh % 3];
      px.rect(a, y, b, yb, r[2]);
      px.rect(a, y, b, y + 1, r[3]);
      px.rect(a, yb - 1, b, yb, r[1]);
      if (x + plankW <= x1) px.rect(b - 1, y, b, yb, r[1]);
      // Grain: a streak or two, and now and then a knot.
      for (var k = 0; k < 1; k++) {
        final g = _hash(hsh, k);
        final int gx = a + 2 + g % math.max(1, b - a - 8), gy = y + 2 + (g >> 5) % 2;
        px.rect(gx, gy, math.min(b - 1, gx + 3 + (g >> 8) % 5), gy + 1, r[1]);
      }
      if (hsh % 23 == 0) {
        final int k = a + 1 + (hsh >> 4) % math.max(1, b - a - 3);
        px.rect(k, y + 2, k + 2, y + 3, r[1]);
      }
    }
  }
}

void _rug(Pixels px, double x0, double x1, double z0, double z1) {
  px.block(x0, x1, z0, z1, const Color(0xFFC8553D), shadow: false);
  final a = Pixels._x(x0) + 3, b = Pixels._x(x1) - 3, t = Pixels._z(z0) + 3, u = Pixels._z(z1) - 3;
  final r = ramp(Pal.rug);
  px.rect(a, t, b, u, r[2]);
  // Diamonds.
  for (var y = t + 2; y < u - 2; y += 8) {
    for (var x = a + 2; x < b - 2; x += 8) {
      for (var d = 0; d < 3; d++) {
        px.rect(x + 3 - d, y + d, x + 4 + d, y + d + 1, r[3]);
        px.rect(x + 3 - d, y + 6 - d, x + 4 + d, y + 7 - d, r[1]);
      }
    }
  }
}

/// One desk: its top, monitor and keyboard, and the chair on the worker's side.
void _desk(Pixels px, DeskDef d) {
  const w = DeskSize.width, dd = DeskSize.depth;
  px.blockAt(d.x, d.z, w - 0.06, dd, Pal.desk);
  final toWorker = d.rotY == 0 ? 1.0 : -1.0;
  px.blockAt(d.x, d.z - toWorker * 0.28, 0.82, 0.18, Pal.monitor, shadow: false);
  px.box(d.x - 0.32, d.x + 0.32, d.z - toWorker * 0.28 - 0.02, d.z - toWorker * 0.28 + 0.03, Pal.screen);
  px.blockAt(d.x, d.z + toWorker * 0.12, 0.54, 0.18, const Color(0xFFE9ECEF), shadow: false);
  px.blockAt(d.x + 0.5, d.z + toWorker * 0.1, 0.18, 0.18, const Color(0xFFF1FAEE), shadow: false); // a mug
  final (cx, cz) = deskPoint(d, 0, 0.9);
  px.blockAt(cx, cz, 0.52, 0.52, Pal.chair);
  px.box(cx - 0.24, cx + 0.24, cz + toWorker * 0.2, cz + toWorker * 0.26, const Color(0xFF22223B));
}

/// The outside walls in brick, with their windows (glass with a glint) and doors.
void _walls(Pixels px, [int wing = 0]) {
  const t = wallT;
  final back = wingMinZ(wing);
  for (final (x0, x1, z0, z1) in [
    // The north wall, with the bit past the gong knocked through to the back office once it's built.
    if (wing > 0) ...[
      (Floor.minX - t, Wing.minX, Floor.minZ - t, Floor.minZ),
      (Wing.minX - t, Wing.minX, back - t, Floor.minZ),
      (Wing.minX - t, Floor.maxX + t, back - t, back),
    ] else
      (Floor.minX - t, Floor.maxX + t, Floor.minZ - t, Floor.minZ),
    (Floor.minX - t, Floor.maxX + t, Floor.maxZ, Floor.maxZ + t),
    (Floor.minX - t, Floor.minX, Floor.minZ - t, Floor.maxZ + t),
    (Floor.maxX, Floor.maxX + t, back - t, Floor.maxZ + t),
  ]) {
    _bricks(px, Pixels._x(x0), Pixels._z(z0), Pixels._x(x1), Pixels._z(z1));
  }
  for (var row = 1; row <= wing; row++) {
    _opening(px, Opening(wall: Side.east, u: wingRowZ(row), width: 2.4, y0: 1.1, y1: 3.3), Pal.window, glass: true);
  }
  for (final o in windows) {
    if (o.y0 > Loft.y) continue; // the loft's, upstairs
    _opening(px, o, Pal.window, glass: true);
  }
  _opening(px, exitDoor, Pal.door);
  _opening(px, balconyDoor, Pal.window, glass: true);
}

void _bricks(Pixels px, int x0, int y0, int x1, int y1, [Color color = Pal.wall]) {
  final r = ramp(color);
  px.rect(x0, y0, x1, y1, r[2]);
  var row = 0;
  for (var y = y0; y < y1; y += 2, row++) {
    px.rect(x0, y, x1, y + 1, r[1]);
    for (var x = x0 + (row.isOdd ? 2 : 0); x < x1; x += 4) {
      px.rect(x, y, x + 1, math.min(y + 2, y1), r[0]);
      px.rect(x + 1, y + 1, x + 3, math.min(y + 2, y1), r[3]);
    }
  }
}

void _opening(Pixels px, Opening o, Color color, {bool glass = false}) {
  const t = wallT;
  final a = o.u - o.width / 2, b = o.u + o.width / 2;
  final (x0, x1, z0, z1) = switch (o.wall) {
    Side.north => (a, b, Floor.minZ - t + 0.06, Floor.minZ - 0.06),
    Side.south => (a, b, Floor.maxZ + 0.06, Floor.maxZ + t - 0.06),
    Side.west => (Floor.minX - t + 0.06, Floor.minX - 0.06, a, b),
    Side.east => (Floor.maxX + 0.06, Floor.maxX + t - 0.06, a, b),
  };
  final r = ramp(color);
  px.box(x0, x1, z0, z1, r[2]);
  if (!glass) return;
  // A glint across the glass, every so often.
  final ax = Pixels._x(x0), bx = Pixels._x(x1), az = Pixels._z(z0), bz = Pixels._z(z1);
  for (var y = az; y < bz; y++) {
    for (var x = ax; x < bx; x++) {
      final k = (x + y) % 9;
      if (k == 0) px.rect(x, y, x + 1, y + 1, r[4]);
      if (k == 1) px.rect(x, y, x + 1, y + 1, r[3]);
    }
  }
}

// ---- A map of its own: the castle's hall, the space station's deck --------------------------------

/// A color off the map's own palette (its config's `palette`), or [fallback].
Color _paletteColor(MapPlan plan, String key, Color fallback) {
  final palette = plan.config?['palette'];
  final hex = palette is Map ? palette[key] : null;
  final v = hex is String ? int.tryParse(hex.replaceFirst('#', ''), radix: 16) : null;
  return v == null ? fallback : Color(0xFF000000 | v);
}

/// A map of its own (the castle, the space station, a custom one) drawn from its [MapPlan] in the same
/// 16-bit style as the office, once, into [c] (after MapBounds.plan(plan.bounds)): what's outside, the
/// floor, what's in the way on it (its props), the tables and benches, the board agents' lecterns
/// the boards on the walls, the throne, and the walls with their doors and
/// windows. The live layer (people, workers, labels) is drawn over it as on the office's.
void paintMapPlan(Canvas c, MapPlan plan) {
  final px = Pixels(c);
  final b = plan.bounds;
  final castle = plan.style == PlanStyle.castle;
  final floor = _paletteColor(
    plan,
    castle ? 'floor' : 'deck',
    castle ? const Color(0xFF6F685F) : const Color(0xFF3D4858),
  );
  final wall = _paletteColor(
    plan,
    castle ? 'stone' : 'hull',
    castle ? const Color(0xFF8C847A) : const Color(0xFFDFE5EE),
  );
  final wood = _paletteColor(
    plan,
    castle ? 'wood' : 'metal',
    castle ? const Color(0xFF6B4526) : const Color(0xFF56627A),
  );
  final trim = _paletteColor(plan, castle ? 'trim' : 'glow', castle ? Pal.gold : const Color(0xFF35D6FF));
  final carpet = _paletteColor(
    plan,
    castle ? 'carpet' : 'panel',
    castle ? const Color(0xFF8E1B1B) : const Color(0xFFAEB8C8),
  );

  // Outside: green hills round a castle; space, with stars, round a station.
  final w = MapBounds.width, h = MapBounds.height;
  if (castle) {
    _outside(px, b.minZ);
  } else {
    px.rect(0, 0, w, h, const Color(0xFF0B0D1A));
    for (var i = 0; i < 260; i++) {
      final hsh = _hash(i, 31);
      px.rect(
        hsh % w,
        (hsh >> 11) % h,
        hsh % w + 1,
        (hsh >> 11) % h + 1,
        i % 7 == 0 ? Pal.yellow : const Color(0xFFDDE6F0),
      );
    }
  }

  // The floor: flagstones in the castle, deck plates on the station.
  final x0 = Pixels._x(b.minX), x1 = Pixels._x(b.maxX), z0 = Pixels._z(b.minZ), z1 = Pixels._z(b.maxZ);
  final r = ramp(floor);
  final cell = castle ? 12 : 16;
  for (var y = z0; y < z1; y += cell) {
    final row = (y - z0) ~/ cell;
    for (var x = x0 - (castle && row.isOdd ? cell ~/ 2 : 0); x < x1; x += cell) {
      final a = math.max(x, x0), e = math.min(x + cell, x1), yb = math.min(y + cell, z1);
      final tone = castle ? 1 + _hash(row, x) % 3 : 2;
      px.rect(a, y, e, yb, r[tone]);
      px.rect(a, y, e, y + 1, r[math.min(4, tone + 1)]);
      px.rect(a, yb - 1, e, yb, r[0]);
      px.rect(e - 1, y, e, yb, r[0]);
      if (!castle) px.rect(a + 2, y + 2, a + 3, y + 3, r[4]); // a rivet
    }
  }

  // The carpet from the door to the throne (or down the middle of the deck).
  final throne = plan.throne;
  if (throne != null) {
    final from = math.min(throne.z, plan.door.z), to = math.max(throne.z, plan.door.z);
    px.block(throne.x - 1.2, throne.x + 1.2, from, to, carpet, shadow: false);
    px.box(throne.x - 1.0, throne.x + 1.0, from, to, ramp(carpet)[3]);
    final dais = plan.dais;
    if (dais != null) {
      final dz = throne.z + math.cos(throne.rotY) * (dais.depth / 2 - 0.4);
      px.blockAt(throne.x, dz, dais.width, dais.depth, wall);
      for (var i = 1; i <= dais.steps; i++) {
        px.box(
          throne.x - dais.width / 2,
          throne.x + dais.width / 2,
          dz + dais.depth / 2 - i * 0.3,
          dz + dais.depth / 2 - i * 0.3 + 0.04,
          ramp(wall)[1],
        );
      }
    }
    // The throne itself: a heap of blades round a seat.
    px.blockAt(throne.x, throne.z, 1.6, 1.4, const Color(0xFF6C757D));
    for (var i = 0; i < 7; i++) {
      px.box(
        throne.x - 0.75 + i * 0.25,
        throne.x - 0.7 + i * 0.25,
        throne.z - 0.9,
        throne.z - 0.35,
        const Color(0xFFCED4DA),
      );
    }
    px.blockAt(throne.x, throne.z, 0.7, 0.6, carpet, shadow: false);
  } else {
    final mx = (b.minX + b.maxX) / 2;
    px.box(mx - 0.9, mx + 0.9, b.minZ + 1, b.maxZ - 1, ramp(floor)[3]);
    px.box(mx - 0.05, mx + 0.05, b.minZ + 1, b.maxZ - 1, trim);
  }

  // What's in the way on the floor: the map's props (pillars, braziers, consoles, crates…).
  final obstacles = plan.obstacles;
  if (obstacles != null) {
    for (final (ax, bx, az, bz) in obstacles.rects) {
      // Walls and anything huge are the walls' to draw; tables and lecterns are drawn below.
      if ((bx - ax) > (b.maxX - b.minX) * 0.8 || (bz - az) > (b.maxZ - b.minZ) * 0.8) continue;
      px.block(ax, bx, az, bz, castle ? ramp(wall)[1] : wood);
    }
    for (final (cx, cz, cr) in obstacles.circles) {
      px.ball(cx, cz, cr, castle ? wall : wood);
    }
  }

  // The tables, and a bench (or a chair) for every seat.
  for (final t in plan.tables) {
    // A table's length runs along its rotY's axis (down the hall, at rotY 0), its benches either side.
    final alongZ = math.cos(t.rotY).abs() > 0.5;
    final (tw, td) = alongZ ? (t.width, t.length) : (t.length, t.width);
    px.blockAt(t.x, t.z, tw, td, wood);
    if (alongZ) {
      px.box(t.x - 0.03, t.x + 0.03, t.z - td / 2 + 0.1, t.z + td / 2 - 0.1, ramp(wood)[4]);
    } else {
      px.box(t.x - tw / 2 + 0.1, t.x + tw / 2 - 0.1, t.z - 0.03, t.z + 0.03, ramp(wood)[4]);
    }
  }
  for (final d in [...plan.desks, ...plan.overflow]) {
    final seat = deskSeat(d);
    px.blockAt(seat.x, seat.z, 0.5, 0.5, castle ? ramp(wood)[1] : Pal.chair);
    // What the worker works on there: a tome in the castle, a console screen on the station.
    final (wx, wz) = deskPoint(d, 0, -0.1);
    px.blockAt(wx, wz, 0.42, 0.3, castle ? const Color(0xFF5A2A17) : Pal.monitor, shadow: false);
    px.box(wx - 0.16, wx + 0.16, wz - 0.05, wz + 0.05, castle ? const Color(0xFFEFE3C2) : Pal.screen);
  }

  // The board agents' lecterns.
  for (final k in plan.stations) {
    px.blockAt(k.x, k.z, Kiosk.width, Kiosk.depth, castle ? wood : Pal.steel);
    px.blockAt(
      k.x,
      k.z,
      Kiosk.width - 0.24,
      Kiosk.depth - 0.24,
      castle ? const Color(0xFFEFE3C2) : Pal.screen,
      shadow: false,
    );
  }

  // The meeting table (the castle's council), if it has one.
  final council = plan.council;
  if (council != null) {
    px.ball(council.x, council.z, 1.2, wood);
    px.ball(council.x, council.z, 0.5, trim, shadow: false);
  }

  // The walls, stone or hull, with the boards on them and what's cut through them.
  const t = 0.5;
  final wallColor = castle ? wall : ramp(wall)[1];
  for (final (ax, bx, az, bz) in [
    (b.minX - t, b.maxX + t, b.minZ - t, b.minZ),
    (b.minX - t, b.maxX + t, b.maxZ, b.maxZ + t),
    (b.minX - t, b.minX, b.minZ - t, b.maxZ + t),
    (b.maxX, b.maxX + t, b.minZ - t, b.maxZ + t),
  ]) {
    _bricks(px, Pixels._x(ax), Pixels._z(az), Pixels._x(bx), Pixels._z(bz), wallColor);
  }
  for (final o in plan.openings ?? const <WallOpening>[]) {
    final a = o.u - o.width / 2, e = o.u + o.width / 2;
    final (ox0, ox1, oz0, oz1) = switch (o.wall) {
      WallSide.north => (a, e, b.minZ - t + 0.06, b.minZ - 0.04),
      WallSide.south => (a, e, b.maxZ + 0.04, b.maxZ + t - 0.06),
      WallSide.west => (b.minX - t + 0.06, b.minX - 0.04, a, e),
      WallSide.east => (b.maxX + 0.04, b.maxX + t - 0.06, a, e),
    };
    final color = switch (o.kind) {
      OpeningKind.door => castle ? const Color(0xFF6B4526) : Pal.metal,
      OpeningKind.airlock => Pal.yellow,
      OpeningKind.viewport => const Color(0xFF1B2440),
    };
    px.box(ox0, ox1, oz0, oz1, color);
  }
  for (final board in plan.boards.values) {
    final alongZ = math.sin(board.rotY).abs() > 0.5;
    if (alongZ) {
      px.blockAt(board.x, board.z, 0.26, board.width, Pal.deckEdge, shadow: false);
      px.box(
        board.x - 0.08,
        board.x + 0.08,
        board.z - board.width / 2 + 0.1,
        board.z + board.width / 2 - 0.1,
        castle ? const Color(0xFFEFE3C2) : Pal.screen,
      );
    } else {
      px.blockAt(board.x, board.z, board.width, 0.26, Pal.deckEdge, shadow: false);
      px.box(
        board.x - board.width / 2 + 0.1,
        board.x + board.width / 2 - 0.1,
        board.z - 0.08,
        board.z + 0.08,
        castle ? const Color(0xFFEFE3C2) : Pal.screen,
      );
    }
  }
}
