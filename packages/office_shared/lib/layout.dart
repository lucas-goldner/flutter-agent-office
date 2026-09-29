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

/// How high the ceiling is: a meter over the loft's roof (Loft.y + Loft.height), all the way across the room.
const double wallHeight = 6.8;

class DeskDef {
  const DeskDef({
    required this.id,
    required this.x,
    required this.z,
    required this.rotY,
    required this.label,
    this.beanbag = false,
    this.station,
    this.room = false,
  });

  final String id;
  final double x;
  final double z;

  /// Rotation around Y. At 0 the worker sits on the desk's +z side, facing -z.
  final double rotY;
  final String label;

  /// A bean bag on the floor instead of a desk; the worker sits on it at (x, z), facing -z at rotY 0.
  final bool beanbag;

  /// A board agent's kiosk instead of a desk (see [stations]): the worker stands behind it.
  final StationKind? station;

  /// A chair at the meeting room's table (see [meetingSeats]): only a meeting seats a worker here.
  final bool room;

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
    // Out in the north-east corner past the gong, and between the PR board and the elevator, clear of
    // the gong's front and the elevator doors.
    (15.0, -9.8, 0.0),
    (5.4, -9.8, 0.0),
    (-16.1, -9.0, math.pi / 2),
    (-16.1, -3.0, math.pi / 2),
    (-8.8, 10.2, math.pi),
    (0.8, 10.2, math.pi),
    (12.2, -5.6, -math.pi / 2),
    (12.2, 5.6, -math.pi / 2),
    (-16.1, 3.0, math.pi / 2),
    // Clear of the board agents' kiosks, and of the floor in front of them.
    (-13.2, -9.8, 0.0),
    (-12.6, 9.2, math.pi / 2),
    (-5.4, -9.8, 0.0),
  ].indexed)
    DeskDef(id: 'beanbag-${i + 1}', x: x, z: z, rotY: rotY, label: 'Bean bag ${i + 1}', beanbag: true),
]);

/// Everywhere a worker can sit: the desks, then the bean bags.
final List<DeskDef> seats = List.unmodifiable([...desks, ...beanbags]);

/// The boards with an agent standing by: the Issues board, the PR board and the task queue.
enum StationKind implements WireEnum {
  issues('issues'),
  pulls('pulls'),
  queue('queue');

  const StationKind(this.wire);
  @override
  final String wire;

  static StationKind? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// The board agents: a worker standing behind a little kiosk just west of each of those boards (see
/// [Boards]), there for anyone to prompt about it. (x, z) is the kiosk. They face into the room, so at
/// rotY pi the worker stands on the wall side of it. Nobody hires them from the desks or the queue.
const List<DeskDef> stations = [
  // Between the plant in the north-west corner and the Issues board.
  DeskDef(
    id: 'station-issues',
    station: StationKind.issues,
    x: -15.6,
    z: Floor.minZ + 1.3,
    rotY: math.pi,
    label: 'Issues board',
  ),
  // Between the task queue and the PR board.
  DeskDef(id: 'station-pulls', station: StationKind.pulls, x: 0, z: Floor.minZ + 1.3, rotY: math.pi, label: 'PR board'),
  // Between the Issues board and the task queue.
  DeskDef(
    id: 'station-queue',
    station: StationKind.queue,
    x: -7.8,
    z: Floor.minZ + 1.3,
    rotY: math.pi,
    label: 'Task queue',
  ),
];

/// A board agent's kiosk: its top, and how far behind its middle (toward the wall) the agent stands.
abstract final class Kiosk {
  static const double width = 0.8;
  static const double depth = 0.5;
  static const double height = 0.55;
  static const double stand = 0.55;
}

/// Each board agent's name and its color, the same whenever it's hired.
const Map<StationKind, ({String name, String color})> stationAgent = {
  StationKind.issues: (name: 'Issues agent', color: '#ef476f'),
  StationKind.pulls: (name: 'PR agent', color: '#118ab2'),
  StationKind.queue: (name: 'Queue agent', color: '#06d6a0'),
};

/// The meeting room: glass walls round the space under the boss office, from the loft's posts to the
/// outside walls, with a long table in the middle. Workers called to a meeting sit round it (see
/// [meetingSeats] and server/meetings.ts). The glass stops under the loft's floor; the door is in the
/// north wall, facing the lounge.
abstract final class MeetingRoom {
  static const double minX = Loft.minX + 0.15;
  static const double maxX = Floor.maxX;
  static const double minZ = Loft.minZ + 0.15;
  static const double maxZ = Floor.maxZ;
  static const double height = Loft.y - 0.25;
  static const door = (x0: 10.0, x1: 11.4);
}

abstract final class MeetingTable {
  static const double x = 13.7;
  static const double z = 10.55;
  static const double width = 3.6;
  static const double depth = 1.2;
  static const double height = 0.76;
}

/// The chairs round the meeting table, in the order a meeting fills them: the head of the table at its
/// west end (whoever leads or writes the meeting up), then two down each side. (x, z) is where the
/// laptop sits on the table; the chair is out from it the way a desk's is ([deskSeat]).
final List<DeskDef> meetingSeats = List.unmodifiable([
  for (final (i, (x, z, rotY)) in const [
    (MeetingTable.x - MeetingTable.width / 2 + 0.35, MeetingTable.z, -math.pi / 2),
    (MeetingTable.x - 0.6, MeetingTable.z - MeetingTable.depth / 2 + 0.35, math.pi),
    (MeetingTable.x - 0.6, MeetingTable.z + MeetingTable.depth / 2 - 0.35, 0.0),
    (MeetingTable.x + 1.1, MeetingTable.z - MeetingTable.depth / 2 + 0.35, math.pi),
    (MeetingTable.x + 1.1, MeetingTable.z + MeetingTable.depth / 2 - 0.35, 0.0),
  ].indexed)
    DeskDef(
      id: 'meeting-${i + 1}',
      x: x,
      z: z,
      rotY: rotY,
      label: i == 0 ? 'Head of the table' : 'Meeting chair ${i + 1}',
      room: true,
    ),
]);

/// The board on the meeting room's back (south) wall that shows the meeting's output file as it's written.
abstract final class MeetingBoard {
  static const double x = MeetingTable.x;
  static const double y = 1.95;
  static const double z = Floor.maxZ - 0.08;
  static const double width = 3.6;
  static const double height = 1.2;
}

/// Any place a worker can be by id: the seats, the board agents' kiosks and the meeting room's chairs.
final Map<String, DeskDef> deskById = Map.unmodifiable({
  for (final d in [...seats, ...stations, ...meetingSeats]) d.id: d,
});

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
  final out = {
    for (final b in beanbags)
      if (taken(b.id)) b.id,
  };
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

/// The places nobody is at: every seat and board agent's kiosk with no worker there and nobody sent
/// home still packing up there ([packing]). Each shows that it's free, with a '+' over a seat and the
/// board agent waiting at a kiosk. It's worked out afresh from who's there rather than seat by seat as
/// workers come and go, so swapping one floor's workers for another's never leaves a place showing
/// free under someone (two floors can each have a Queue agent at the same kiosk).
Set<String> vacantSeats(Iterable<String> deskIds, [bool Function(String id)? packing]) {
  final taken = deskIds.toSet();
  return {
    for (final id in deskById.keys)
      if (!taken.contains(id) && !(packing?.call(id) ?? false)) id,
  };
}

/// Where the worker (and the interacting player) stands relative to the desk.
({double x, double z}) deskSeat(DeskDef desk, [double offset = 0.85]) =>
    (x: desk.x + math.sin(desk.rotY) * offset, z: desk.z + math.cos(desk.rotY) * offset);

class BoardDef {
  const BoardDef({
    required this.x,
    required this.y,
    required this.z,
    required this.rotY,
    required this.width,
    required this.height,
    required this.label,
  });

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
  // Side by side along the north wall, the way work goes: an issue goes on the task queue (the
  // whiteboard in the middle), and its worker's pull request comes out the other side. Each has its
  // board agent's kiosk just west of it (see [stations]).
  static const issues = BoardDef(x: -11.7, y: 2.1, z: Floor.minZ + 0.08, rotY: 0, width: 6, height: 3, label: 'Issues');
  static const queue = BoardDef(
    x: -3.9,
    y: 2.1,
    z: Floor.minZ + 0.08,
    rotY: 0,
    width: 6,
    height: 3,
    label: '📋 Task queue',
  );
  static const pulls = BoardDef(
    x: 3.9,
    y: 2.1,
    z: Floor.minZ + 0.08,
    rotY: 0,
    width: 6,
    height: 3,
    label: 'Pull Requests',
  );
  // East wall, north of the lounge TV.
  static const services = BoardDef(
    x: Floor.maxX - 0.08,
    y: 2.1,
    z: -8.2,
    rotY: -math.pi / 2,
    width: 6,
    height: 3,
    label: '🌐 Services',
  );
}

/// The big TV on the east wall that shows whoever is screen sharing.
abstract final class Tv {
  static const double x = Floor.maxX - 0.1;
  static const double y = 2.2;
  static const double z = 0;
  static const double width = 6.4;
  static const double height = 3.6;
}

/// The monitor on the west wall, between the first two windows from the north (the ladder has the
/// span between the middle two) and facing the desks: how busy the office's machine is, and how many
/// workers it runs of the most it takes.
abstract final class MachineMonitor {
  static const double x = Floor.minX;
  static const double y = 2.2;
  static const double z = -6;
  static const double width = 2.3;
  static const double height = 1.3;
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

/// The arcade cabinet, against the east wall between the jukebox and the loft, facing into the room. `width` runs along the wall.
abstract final class Cabinet {
  static const double x = Floor.maxX - 0.42;
  static const double z = 7.05;
  static const double width = 0.8;
  static const double depth = 0.8;
  static const double height = 1.9;
}

/// The bookshelf of the project's docs (every Markdown file in it, see docs.dart): against the south
/// wall between the middle window and the balcony doors, facing into the room (-z). `width` runs
/// along the wall.
abstract final class Bookshelf {
  static const double x = -6.5;
  static const double z = Floor.maxZ - 0.21;
  static const double width = 1.7;
  static const double depth = 0.42;
  static const double height = 2.3;
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

/// The gong: on the north wall just past the elevator from the PR board, facing into the room. It rings when a PR merges.
abstract final class Gong {
  static const double x = 11.8;
  static const double z = Floor.minZ + 0.75;
  static const double width = 1.9;
  static const double height = 2.45;
}

/// Potted plants around the room: where each stands, and how big it is.
const List<(double x, double z, double scale)> plants = [
  (-17.2, -12.2, 1.4),
  (17.2, -12.2, 1.5),
  (17.2, 12.2, 1.3),
  (-17.2, 8.5, 1.2),
  (14.2, -12.2, 1.1),
  (-6, 0, 1),
  (3.5, 0, 0.9),
  (8.5, 5, 1.1),
];

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

/// The bottom floor of the building is its second storey: the street, and the open garage under the
/// office, are this far below its floor. Each floor stands one [storey] higher than the one below it,
/// so from floor `i` the street is `streetBelow(i)` down.
const double streetY = -3.6;

/// The street runs east–west in front of the building (south, +z), with a sidewalk along either side.
abstract final class Road {
  static const double minZ = 23;
  static const double maxZ = 31;
}

/// The office's floor slab, which is the garage's ceiling: it runs from -slab up to 0.
const double slab = 0.3;

/// From one floor of the building up to the next: the office's ceiling, and the slab over it.
const double storey = wallHeight + slab;

/// How thick the outside walls are. They stand just outside [Floor].
const double wallT = 0.3;

/// How far below floor [index] of the building (0 is the bottom one) the street is.
double streetBelow(int index) => streetY - math.max(0, index) * storey;

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

/// The way out of the bottom floor: a door in the west wall onto a landing, with stairs down to the
/// street. The floors above have no door there; workers leave them off the balcony (see [Parachute]).
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

/// The golf tee on the balcony, between the ashtray and the doors: a square of turf `size` across,
/// with the ball teed up at `ball`, hit out over the railing at the hole across the street
/// ([GolfHole]). The golf bag leans on the wall behind it at `bag`, just short of the doors.
abstract final class GolfTee {
  static const double x = -6.75;
  static const double z = 14.75;
  static const double size = 1.5;
  static const ball = (x: -6.95, z: 14.75);
  static const bag = (x: -5.8, z: Balcony.minZ + 0.28);
}

/// The hole across the street, out past the far sidewalk where the neighbours leave a gap: its pin,
/// the green round it (`green` its radius) and the fairway leading up to it (x `fairway` wide, from
/// the sidewalk to the green). Down on the street, so it's further down the higher your floor is.
abstract final class GolfHole {
  static const double x = -5;
  static const double z = 58;
  static const double green = 5.5;
  static const fairway = (-11.0, 0.0);
}

/// Leaving a floor above the bottom one, with no exit door: out through the balcony doors to the
/// railing straight ahead (`jump`), up onto its top (`railTop` high), and over it by parachute. The
/// chute circles down onto the lot in front of the garage: `out` further from the building than it
/// opened, and `east` (a random bit of it) along, clear of the balconies below and the street lamp by
/// the balcony doors.
abstract final class Parachute {
  static const jump = (x: -4.0, z: Balcony.maxZ - 0.45); // x is balconyDoor.u
  static const double railTop = 1.09;
  static const double out = 1.2;
  static const east = (0.6, 1.8);
}

// ---- The rooftop bar (see rooftop.dart) ---------------------------------------------------------
// The roof of the building, level with the office floor's y = 0 and the same size, so the elevator
// comes up in its usual spot. A glass railing runs round the edge, and the city is far below.

/// How far below the roof the street is, with [floors] floors under it: the building is this tall.
/// The roof stands a [storey] over the top floor, where a floor above it would be.
double roofDrop(int floors) => -streetBelow(math.max(1, floors));

/// The DJ's stage, against the north edge west of the elevator, with the dance floor in front of it.
abstract final class Stage {
  static const double minX = -8;
  static const double maxX = 2;
  static const double minZ = Floor.minZ;
  static const double maxZ = -9.2;
  static const double height = 0.6;
}

/// Where the DJ stands behind the decks, facing the dance floor (+z).
abstract final class DjBooth {
  static const double x = -3;
  static const double z = -11.3;
}

/// LED tiles, a meter each, lighting up with the music.
abstract final class DanceFloor {
  static const double minX = -8;
  static const double maxX = 2;
  static const double minZ = -9.2;
  static const double maxZ = -2.2;
}

/// The bar along the east side: its counter (x is its middle), with the bartender and the bottles behind it.
abstract final class RoofBar {
  static const double x = 12.95;
  static const double minZ = -6;
  static const double maxZ = 4;
  static const double depth = 0.7;
  static const double height = 1.1;
}

/// The fire pit in the lounge, in the south-west corner, with sofas round three sides of it.
abstract final class FirePit {
  static const double x = -12;
  static const double z = 8.2;
  static const double r = 0.9;
}

/// Tall tables to stand at, between the elevator and the bar.
const List<({double x, double z})> roofTables = [(x: 6.6, z: 5.2), (x: 9.6, z: 8.8), (x: 6, z: 10.8)];

/// Sun loungers along the south edge, looking out over the street.
const List<double> _loungers = [-2.2, 0.6, 3.4];

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
    this.roof = false,
    this.bar = false,
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

  /// It faces the boss's monitor: E there, sitting down, plays Minesweeper on it.
  final bool game;

  /// Up on the rooftop bar, not in the office.
  final bool roof;

  /// At the bar: E there, sitting down, orders a drink.
  final bool bar;
}

/// Where people can sit: the office's couches, beanbags, chairs and the balcony bench. Workers have
/// their own seats, the desks and bean bags in [seats].
final List<SeatDef> seating = List.unmodifiable([
  // The lounge couch, its back to the room, facing the TV.
  const SeatDef(
    id: 'couch',
    label: '🛋️ Couch',
    x: 10.5,
    y: 0,
    z: 0,
    rotY: math.pi / 2,
    places: [-1.2, 0, 1.2],
    hips: 0.5,
    depth: -0.05,
    out: 0.9,
    tv: true,
  ),
  // Beanbags either side of the lounge, turned to the TV.
  SeatDef(
    id: 'lounge-beanbag-1',
    label: '🫘 Beanbag',
    x: 12.5,
    y: 0,
    z: 3.5,
    rotY: math.atan2(Tv.x - 12.5, Tv.z - 3.5),
    places: const [0],
    hips: 0.42,
    depth: -0.1,
    out: 1.2,
  ),
  SeatDef(
    id: 'lounge-beanbag-2',
    label: '🫘 Beanbag',
    x: 14.5,
    y: 0,
    z: -3.4,
    rotY: math.atan2(Tv.x - 14.5, Tv.z + 3.4),
    places: const [0],
    hips: 0.42,
    depth: -0.1,
    out: 1.2,
  ),
  // Up in the boss office: the couch against the east wall, and the chair at the big desk, facing the glass.
  const SeatDef(
    id: 'loft-couch',
    label: '🛋️ Couch',
    x: Loft.maxX - 0.65,
    y: Loft.y,
    z: (Loft.minZ + Loft.maxZ) / 2,
    rotY: -math.pi / 2,
    places: [-0.5, 0.5],
    hips: 0.5,
    depth: -0.05,
    out: 0.9,
  ),
  const SeatDef(
    id: 'boss-chair',
    label: "🪑 Boss's chair",
    x: (Loft.minX + Loft.maxX) / 2 + 0.5,
    y: Loft.y,
    z: (Loft.minZ + Loft.maxZ) / 2 + 0.7,
    rotY: math.pi,
    places: [0],
    hips: 0.62,
    depth: -0.05,
    out: -0.8,
    game: true,
  ),
  // Out on the balcony: the bench under the window, looking out over the street, and a stool either side of the bistro table.
  const SeatDef(
    id: 'bench',
    label: '🪑 Bench',
    x: -9,
    y: 0,
    z: Balcony.minZ + 0.3,
    rotY: 0,
    places: [-0.5, 0.5],
    hips: 0.47,
    depth: 0,
    out: 0.8,
  ),
  const SeatDef(
    id: 'stool-1',
    label: '🪑 Stool',
    x: -0.6,
    y: 0,
    z: (Balcony.minZ + Balcony.maxZ) / 2 + 0.2,
    rotY: math.pi / 2,
    places: [0],
    hips: 0.5,
    depth: 0,
    out: -0.7,
  ),
  const SeatDef(
    id: 'stool-2',
    label: '🪑 Stool',
    x: 1,
    y: 0,
    z: (Balcony.minZ + Balcony.maxZ) / 2 + 0.2,
    rotY: -math.pi / 2,
    places: [0],
    hips: 0.5,
    depth: 0,
    out: -0.7,
  ),
  // On the roof: bar stools along the counter, facing the bar…
  for (var i = 0; i < 6; i++)
    SeatDef(
      id: 'roof-stool-${i + 1}',
      label: '🪑 Bar stool',
      x: RoofBar.x - RoofBar.depth / 2 - 0.45,
      y: 0,
      z: RoofBar.minZ + 0.9 + i * 1.64,
      rotY: math.pi / 2,
      places: const [0],
      hips: 0.78,
      depth: 0,
      out: -0.75,
      roof: true,
      bar: true,
    ),
  // …sofas round the fire pit, open to the view on the south…
  const SeatDef(
    id: 'roof-sofa-1',
    label: '🛋️ Sofa',
    x: FirePit.x,
    y: 0,
    z: FirePit.z - 2.3,
    rotY: 0,
    places: [-1.1, 0, 1.1],
    hips: 0.5,
    depth: -0.05,
    out: 0.8,
    roof: true,
  ),
  const SeatDef(
    id: 'roof-sofa-2',
    label: '🛋️ Sofa',
    x: FirePit.x - 2.9,
    y: 0,
    z: FirePit.z + 0.4,
    rotY: math.pi / 2,
    places: [-0.6, 0.6],
    hips: 0.5,
    depth: -0.05,
    out: 0.8,
    roof: true,
  ),
  const SeatDef(
    id: 'roof-sofa-3',
    label: '🛋️ Sofa',
    x: FirePit.x + 2.9,
    y: 0,
    z: FirePit.z + 0.4,
    rotY: -math.pi / 2,
    places: [-0.6, 0.6],
    hips: 0.5,
    depth: -0.05,
    out: 0.8,
    roof: true,
  ),
  // …and sun loungers facing out over the city.
  for (final (i, x) in _loungers.indexed)
    SeatDef(
      id: 'roof-lounger-${i + 1}',
      label: '🏖️ Lounger',
      x: x,
      y: 0,
      z: Floor.maxZ - 1.5,
      rotY: 0,
      places: const [0],
      hips: 0.42,
      depth: -0.2,
      out: -1,
      roof: true,
    ),
]);

final Map<String, SeatDef> seatingById = Map.unmodifiable({for (final s in seating) s.id: s});

/// One place on a seat: where your feet go on its floor, the way you face, and the rest of what sitting there takes.
class SeatPlace {
  const SeatPlace({
    required this.key,
    required this.seatId,
    required this.x,
    required this.y,
    required this.z,
    required this.rotY,
    required this.hips,
    required this.out,
  });

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

/// The place [key] names, if it's somewhere you can sit from where you are: up on the roof, or down on a floor.
SeatPlace? seatHere(String key, bool onRoof) {
  final place = seatAt(key);
  return place != null && seatingById[place.seatId]!.roof == onRoof ? place : null;
}

/// The elevator: a shaft against the north wall, between the PR board and the gong, with its
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

bool inElevator(double x, double z) =>
    x > ElevatorCar.minX && x < ElevatorCar.maxX && z > ElevatorCar.minZ && z < ElevatorCar.maxZ;

/// The ladder to the floors above and below: against the west wall at `z`, up through a hatch in the
/// ceiling and down through one in the floor (every floor has it in the same spot, one long shaft).
/// You climb it at `x`, facing the wall; `hatch` is the hole in the floor and the ceiling.
abstract final class Ladder {
  static const double z = 0;
  static const double width = 0.62;
  static const double x = Floor.minX + 0.62;
  static const hatch = (minX: Floor.minX, maxX: Floor.minX + 1, minZ: -0.5, maxZ: 0.5);

  /// How far in from the wall the trapdoor starts: the ladder goes through a slot along the wall.
  static const double slot = 0.24;
}

/// Where a fire pole can be. `open` is the way into its hole, where its railing has a gap (0 = +z, like rotY).
class PoleSpot {
  const PoleSpot({required this.x, required this.z, required this.open});

  final double x;
  final double z;
  final double open;
}

/// The fire pole, slid down to the floor below. It goes the whole way down the building, through a hole
/// in every floor but the bottom one (where there's a mat to land on): it takes you down one floor, and
/// on a floor with another below you swing off it through the railing, ready to go again.
const List<PoleSpot> poles = [
  // Out in the open between the desks and the lounge, where you step out of the elevator.
  PoleSpot(x: 6.8, z: 1.6, open: math.pi),
];

/// A pole's hole in the floor, the railing round it, and how far from the pole you hang on.
abstract final class Pole {
  static const double hole = 0.68;
  static const double rail = 0.9;
  static const double grip = 0.4;
  static const double radius = 0.055;
}
