// Static office layout shared by the server (validation) and client (rendering).
// Units are meters; +y is up. The office floor spans Floor.minX..maxX / minZ..maxZ at y = 0,
// upstairs over a garage whose floor is level with the street (streetY).

import 'dart:math' as math;

import 'json_util.dart';

/// The office floor's extent.
abstract final class Floor {
  static const double minX = -18;
  static const double maxX = 18;
  static const double minZ = -13;
  static const double maxZ = 13;
}
const double wallHeight = 4.2;

class DeskDef {
  const DeskDef({required this.id, required this.x, required this.z, required this.rotY, required this.label, this.beanbag = false});

  final String id;
  final double x;
  final double z;

  /// Rotation around Y. At 0 the worker sits on the desk's +z side, facing -z.
  final double rotY;
  final String label;

  /// A bean bag on the floor instead of a desk; the worker sits on it at (x, z), facing -z at rotY 0.
  final bool beanbag;

  @override
  String toString() => 'DeskDef($id)';
}

const double _deskWidth = 2.2;
const double _deskDepth = 1.1;
abstract final class DeskSize {
  static const double width = _deskWidth;
  static const double depth = _deskDepth;
  static const double height = 0.78;
}

List<DeskDef> _buildDesks() {
  final desks = <DeskDef>[];
  const clusterX = [-10.5, -1.5];
  // Each pod is two back-to-back rows; the far row faces +z (rotY = pi).
  const pods = [(back: -4.55, front: -3.45), (back: 3.45, front: 4.55)];
  var n = 1;
  for (final pod in pods) {
    for (final cx in clusterX) {
      for (final (z, rotY) in [(pod.back, math.pi), (pod.front, 0.0)]) {
        for (final dx in [-_deskWidth / 2, _deskWidth / 2]) {
          desks.add(DeskDef(id: 'desk-$n', x: cx + dx, z: z, rotY: rotY, label: 'Desk $n'));
          n++;
        }
      }
    }
  }
  return List.unmodifiable(desks);
}

final List<DeskDef> desks = _buildDesks();

/// Overflow seats: once every desk is taken, bean bags come out around the room, one at a time in
/// this order. Each faces a window or a wall, with open floor behind it to walk up to.
final List<DeskDef> beanbags = List.unmodifiable([
  for (final (i, (x, z, rotY)) in const [
    // Either side of the gong, clear of its front and of the elevator doors at x 7.2..9.8.
    (6.0, -9.8, 0.0),
    (1.0, -9.8, 0.0),
    (-16.1, -9.0, math.pi / 2),
    (-16.1, -3.0, math.pi / 2),
    (-8.8, 10.2, math.pi),
    (0.8, 10.2, math.pi),
    (12.2, -5.6, -math.pi / 2),
    (12.2, 5.6, -math.pi / 2),
    (-16.1, 3.0, math.pi / 2),
    (11.0, -9.8, 0.0),
    (-12.6, 9.2, math.pi / 2),
    (-6.0, -9.8, 0.0),
  ].indexed)
    DeskDef(id: 'beanbag-${i + 1}', x: x, z: z, rotY: rotY, label: 'Bean bag ${i + 1}', beanbag: true),
]);

/// Everywhere a worker can sit: the desks, then the bean bags.
final List<DeskDef> seats = List.unmodifiable([...desks, ...beanbags]);

/// Any seat by id, bean bags included.
final Map<String, DeskDef> deskById = Map.unmodifiable({for (final d in seats) d.id: d});

/// The seat a new worker takes when nobody picks one: the first free desk, else the first free bean bag.
DeskDef? nextFreeSeat(bool Function(String id) taken) {
  for (final d in seats) {
    if (!taken(d.id)) return d;
  }
  return null;
}

/// The bean bags that are out: every one in use, and while every desk is taken, the next free one
/// too, so there's always somewhere to hire the next worker.
Set<String> beanbagsOut(bool Function(String id) taken) {
  final out = {for (final b in beanbags) if (taken(b.id)) b.id};
  if (desks.every((d) => taken(d.id))) {
    for (final b in beanbags) {
      if (!taken(b.id)) {
        out.add(b.id);
        break;
      }
    }
  }
  return out;
}

/// Where the worker (and the interacting player) stands relative to the desk.
({double x, double z}) deskSeat(DeskDef desk, [double offset = 0.85]) =>
    (x: desk.x + math.sin(desk.rotY) * offset, z: desk.z + math.cos(desk.rotY) * offset);

class BoardDef {
  const BoardDef({required this.x, required this.y, required this.z, required this.rotY, required this.width, required this.height, required this.label});

  final double x;
  final double y;
  final double z;
  final double rotY;
  final double width;
  final double height;
  final String label;
}

/// Wall boards. `rotY` is the way the board faces (0 = +z, like the north-wall boards).
abstract final class Boards {
  static const issues = BoardDef(x: -10.5, y: 2.1, z: Floor.minZ + 0.08, rotY: 0, width: 6, height: 3, label: 'Issues');
  static const pulls = BoardDef(x: -1.5, y: 2.1, z: Floor.minZ + 0.08, rotY: 0, width: 6, height: 3, label: 'Pull Requests');
  // East wall, north of the lounge TV.
  static const services = BoardDef(x: Floor.maxX - 0.08, y: 2.1, z: -8.2, rotY: -math.pi / 2, width: 6, height: 3, label: '🌐 Services');
  // The task queue whiteboard, north wall, in the corner by the services board.
  static const queue = BoardDef(x: 14.5, y: 2.1, z: Floor.minZ + 0.08, rotY: 0, width: 6, height: 3, label: '📋 Task queue');
}

/// The big TV on the east wall that shows whoever is screen sharing.
abstract final class Tv {
  static const double x = Floor.maxX - 0.1;
  static const double y = 2.2;
  static const double z = 0;
  static const double width = 6.4;
  static const double height = 3.6;
}

/// The lounge jukebox, against the east wall south of the TV, facing into the room. `y` is its speaker.
abstract final class Jukebox {
  static const double x = Floor.maxX - 0.42;
  static const double y = 0.75;
  static const double z = 5.4;
  static const double width = 1.3;
  static const double depth = 0.72;
  static const double height = 1.85;
}

/// The upstairs office: a glass-walled loft on posts in the south-east corner, looking down on the desks.
abstract final class Loft {
  static const double minX = 9;
  static const double maxX = Floor.maxX;
  static const double minZ = 8;
  static const double maxZ = Floor.maxZ;
  static const double y = 3;
  static const double height = 2.8;
}

/// Its stairs climb east along the south wall and arrive at the loft's west door.
abstract final class Stairs {
  static const double fromX = 3;
  static const double toX = Loft.minX;
  static const double minZ = 11.2;
  static const double maxZ = Floor.maxZ;
  static const int steps = 15;
}

abstract final class Spawn {
  static const double x = 8;
  static const double z = 7;
}

/// The gong: on the north wall between the PR board and the elevator, facing into the room. It rings when a PR merges.
abstract final class Gong {
  static const double x = 3.5;
  static const double z = Floor.minZ + 0.75;
  static const double width = 1.9;
  static const double height = 2.45;
}

/// The whiteboard on wheels everyone draws on together, out on the open floor between the desks and
/// the lounge, facing into the room (+z). `width` and `height` are its writing surface, whose bottom
/// edge is `bottom` above the Floor.
abstract final class Whiteboard {
  static const double x = 5.4;
  static const double z = -5.4;
  static const double width = 4;
  static const double height = 2.2;
  static const double bottom = 0.5;
}

/// The office is the second Floor. The street, and the open garage under the office, are this far below its Floor.
const double streetY = -3.6;

/// The street runs east–west in front of the building (south, +z), with a sidewalk along either side.
abstract final class Road {
  static const double minZ = 23;
  static const double maxZ = 31;
}

/// The office's floor slab, which is the garage's ceiling: it runs from -slab up to 0.
const double slab = 0.3;

/// How thick the outside walls are. They stand just outside [Floor].
const double wallT = 0.3;

enum Side implements WireEnum {
  north('north'),
  south('south'),
  east('east'),
  west('west');

  const Side(this.wire);
  @override
  final String wire;

  static Side parse(Object? v, [Side fallback = Side.north]) => parseWire(values, v, fallback);
  static Side? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// A hole in an outside wall: `u` is its center along the wall (x on the north and south walls, z on
/// the east and west ones), `y0`..`y1` its sill and head above the office Floor.
class Opening {
  const Opening({required this.wall, required this.u, required this.width, required this.y0, required this.y1});

  final Side wall;
  final double u;
  final double width;
  final double y0;
  final double y1;
}

/// Windows you can see out of, and the loft's two, which sit higher up.
const List<Opening> windows = [
  Opening(wall: Side.south, u: -14, width: 3, y0: 1.1, y1: 3.3),
  Opening(wall: Side.south, u: -9, width: 3, y0: 1.1, y1: 3.3),
  Opening(wall: Side.south, u: 1, width: 3, y0: 1.1, y1: 3.3),
  Opening(wall: Side.west, u: -9, width: 3, y0: 1.1, y1: 3.3),
  Opening(wall: Side.west, u: -3, width: 3, y0: 1.1, y1: 3.3),
  Opening(wall: Side.west, u: 3, width: 3, y0: 1.1, y1: 3.3),
  Opening(wall: Side.south, u: Loft.minX + 2, width: 2.8, y0: Loft.y + 0.9, y1: Loft.y + 2.5),
  Opening(wall: Side.east, u: (Loft.minZ + Loft.maxZ) / 2, width: 2.8, y0: Loft.y + 0.9, y1: Loft.y + 2.5),
];

/// The way out: a door in the west wall onto a landing, with stairs down to the street.
const Opening exitDoor = Opening(wall: Side.west, u: 6.5, width: 1.4, y0: 0, y1: 2.4);

abstract final class ExitStairs {
  static const double maxX = Floor.minX - wallT;
  static const double minX = Floor.minX - wallT - 1.6;

  /// The landing outside the door, level with the office Floor.
  static const double landingZ0 = 5.6;
  static const double landingZ1 = 7.5;

  /// The steps run south from the landing down to the street.
  static const int steps = 15;
  static const double run = 0.34;
}

/// Glass doors out to the balcony, on the south wall. They slide apart into the wall on either side.
const Opening balconyDoor = Opening(wall: Side.south, u: -4, width: 3, y0: 0, y1: 2.5);

/// The smoking balcony, hanging over the garage entrance.
abstract final class Balcony {
  static const double minX = -10.5;
  static const double maxX = 2.5;
  static const double minZ = Floor.maxZ + wallT;
  static const double maxZ = Floor.maxZ + wallT + 3.4;
}

/// The ashtray on the balcony, where a smoke break starts.
abstract final class Ashtray {
  static const double x = -8.2;
  static const double z = Balcony.maxZ - 0.55;
}

/// Something to sit on, standing at x, z on the floor at `y` (the loft's, for what's up there). You
/// sit facing `rotY` (0 = +z). A couch or a bench has a few places side by side; a chair, a stool or a beanbag has one.
class SeatDef {
  const SeatDef({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    required this.z,
    required this.rotY,
    required this.places,
    required this.hips,
    required this.depth,
    required this.out,
    this.tv = false,
    this.game = false,
  });

  final String id;

  /// What the hint calls it.
  final String label;
  final double x;
  final double y;
  final double z;
  final double rotY;

  /// Where each place is along it, sideways from its middle.
  final List<double> places;

  /// How high above its floor your hips go: on the cushion, sunk in a little.
  final double hips;

  /// How far in front of its middle you sit (negative: further back, against the backrest).
  final double depth;

  /// Getting up, you step off this far in front of where you sat (negative: behind, away from a desk or a table).
  final double out;

  /// It faces the lounge TV: sitting down there puts whatever's being shared up on your screen.
  final bool tv;

  /// It faces the boss's monitor: E there, sitting down, plays DEADFALL on it.
  final bool game;
}

/// Where people can sit: the office's couches, beanbags, chairs and the balcony bench. Workers have
/// their own seats, the desks and bean bags in [seats].
final List<SeatDef> seating = List.unmodifiable([
  // The lounge couch, its back to the room, facing the TV.
  const SeatDef(id: 'couch', label: '🛋️ Couch', x: 10.5, y: 0, z: 0, rotY: math.pi / 2, places: [-1.2, 0, 1.2], hips: 0.5, depth: -0.05, out: 0.9, tv: true),
  // Beanbags either side of the lounge, turned to the TV.
  SeatDef(id: 'lounge-beanbag-1', label: '🫘 Beanbag', x: 12.5, y: 0, z: 3.5, rotY: math.atan2(Tv.x - 12.5, Tv.z - 3.5), places: const [0], hips: 0.42, depth: -0.1, out: 1.2),
  SeatDef(id: 'lounge-beanbag-2', label: '🫘 Beanbag', x: 14.5, y: 0, z: -3.4, rotY: math.atan2(Tv.x - 14.5, Tv.z + 3.4), places: const [0], hips: 0.42, depth: -0.1, out: 1.2),
  // Up in the boss office: the couch against the east wall, and the chair at the big desk, facing the glass.
  const SeatDef(id: 'loft-couch', label: '🛋️ Couch', x: Loft.maxX - 0.65, y: Loft.y, z: (Loft.minZ + Loft.maxZ) / 2, rotY: -math.pi / 2, places: [-0.5, 0.5], hips: 0.5, depth: -0.05, out: 0.9),
  const SeatDef(id: 'boss-chair', label: "🪑 Boss's chair", x: (Loft.minX + Loft.maxX) / 2 + 0.5, y: Loft.y, z: (Loft.minZ + Loft.maxZ) / 2 + 0.7, rotY: math.pi, places: [0], hips: 0.62, depth: -0.05, out: -0.8, game: true),
  // Out on the balcony: the bench under the window, looking out over the street, and a stool either side of the bistro table.
  const SeatDef(id: 'bench', label: '🪑 Bench', x: -9, y: 0, z: Balcony.minZ + 0.3, rotY: 0, places: [-0.5, 0.5], hips: 0.47, depth: 0, out: 0.8),
  const SeatDef(id: 'stool-1', label: '🪑 Stool', x: -0.6, y: 0, z: (Balcony.minZ + Balcony.maxZ) / 2 + 0.2, rotY: math.pi / 2, places: [0], hips: 0.5, depth: 0, out: -0.7),
  const SeatDef(id: 'stool-2', label: '🪑 Stool', x: 1, y: 0, z: (Balcony.minZ + Balcony.maxZ) / 2 + 0.2, rotY: -math.pi / 2, places: [0], hips: 0.5, depth: 0, out: -0.7),
]);

final Map<String, SeatDef> seatingById = Map.unmodifiable({for (final s in seating) s.id: s});

/// One place on a seat: where your feet go on its floor, the way you face, and the rest of what sitting there takes.
class SeatPlace {
  const SeatPlace({required this.key, required this.seatId, required this.x, required this.y, required this.z, required this.rotY, required this.hips, required this.out});

  /// What a peer's `seat` says while they sit here: the seat's id and which place, like "couch:1".
  final String key;
  final String seatId;
  final double x;
  final double y;
  final double z;
  final double rotY;
  final double hips;
  final double out;
}

SeatPlace seatPlace(SeatDef seat, int i) {
  final fx = math.sin(seat.rotY);
  final fz = math.cos(seat.rotY);
  final along = i >= 0 && i < seat.places.length ? seat.places[i] : 0.0;
  return SeatPlace(
    key: '${seat.id}:$i',
    seatId: seat.id,
    x: seat.x + fx * seat.depth + fz * along,
    y: seat.y,
    z: seat.z + fz * seat.depth - fx * along,
    rotY: seat.rotY,
    hips: seat.hips,
    out: seat.out,
  );
}

final RegExp _seatKey = RegExp(r'^([\w-]+):(\d+)$');

/// The place a peer's `seat` names, or null if there's no such place.
SeatPlace? seatAt(String key) {
  final m = _seatKey.firstMatch(key);
  if (m == null) return null;
  final seat = seatingById[m.group(1)];
  final i = int.tryParse(m.group(2)!);
  return seat != null && i != null && i < seat.places.length ? seatPlace(seat, i) : null;
}

/// The elevator: a shaft against the north wall, between the PR board and the task queue, with its
/// doors facing into the room. Every floor has it in the same spot, so you step out where you got in.
abstract final class Elevator {
  static const double x = 8.5;
  static const double width = 2.6;
  static const double depth = 2.4;
  static const double wall = 0.14;
  static const double doorWidth = 1.4;
  static const double doorHeight = 2.4;
}

/// Where the doors are: the front of the shaft.
const double elevatorFront = Floor.minZ + Elevator.depth;

/// The inside of the car, where you stand to ride.
abstract final class ElevatorCar {
  static const double minX = Elevator.x - Elevator.width / 2 + Elevator.wall;
  static const double maxX = Elevator.x + Elevator.width / 2 - Elevator.wall;
  static const double minZ = Floor.minZ;
  static const double maxZ = elevatorFront - Elevator.wall;
}

/// Somewhere inside the car, facing the doors (+z), a little apart from anyone else arriving.
({double x, double z}) elevatorSpot([math.Random? random]) {
  final r = random ?? math.Random();
  final x = Elevator.x + (r.nextDouble() - 0.5) * 0.7;
  final z = (ElevatorCar.minZ + ElevatorCar.maxZ) / 2 + (r.nextDouble() - 0.5) * 0.6;
  return (x: x, z: z);
}

bool inElevator(double x, double z) => x > ElevatorCar.minX && x < ElevatorCar.maxX && z > ElevatorCar.minZ && z < ElevatorCar.maxZ;
