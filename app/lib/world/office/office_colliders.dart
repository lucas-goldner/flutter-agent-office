// What you bump into in the office, worked out from the layout alone (no GPU), exactly as
// office.ts, outside.ts, elevator.ts, gong.ts, jukebox.ts and whiteboard.ts push them while they
// build. buildOffice uses these lists, so the player and nav see the same numbers as the old client.

import 'dart:math' as math;

import 'package:office_shared/layout.dart' as lay;
import 'package:office_shared/layout.dart' hide Elevator, Gong, Jukebox, Whiteboard;

import '../collider.dart';

// ---------------------------------------------------------------------------------------------
// The outside walls.

/// One box of an outside wall: [u0]..[u1] along it, [y0]..[y1] up.
class WallPiece {
  const WallPiece(this.side, this.at, this.u0, this.u1, this.y0, this.y1);

  final Side side;

  /// Its middle across the wall's thickness (z for north/south, x for east/west).
  final double at;
  final double u0;
  final double u1;
  final double y0;
  final double y1;

  bool get alongX => side == Side.north || side == Side.south;
}

/// The walls, cut into pieces around their windows and doors, with baseboard runs between the
/// doors and what blocks you (buildWalls in office.ts).
class WallsPlan {
  final List<WallPiece> pieces = [];

  /// Baseboards along the floor, between doors (y0/y1 unused).
  final List<WallPiece> runs = [];
  final List<Collider> colliders = [];
}

/// Walls throw shade only this far up: any higher and a low sun's shadow would fill the room.
const double shadeHeight = 4.2;

final List<Opening> officeOpenings = [...windows, exitDoor, balconyDoor];

WallsPlan wallsPlan([List<Opening>? openings]) {
  openings ??= officeOpenings;
  final plan = WallsPlan();
  const t = wallT;
  final walls = <(Side, double, List<(double, double, double)>)>[
    (Side.north, Floor.minZ - t / 2, [(Floor.minX - t, Floor.maxX + t, wallHeight)]),
    (Side.south, Floor.maxZ + t / 2, [(Floor.minX - t, Floor.maxX + t, wallHeight)]),
    (Side.west, Floor.minX - t / 2, [(Floor.minZ, Floor.maxZ, wallHeight)]),
    (Side.east, Floor.maxX + t / 2, [(Floor.minZ, Floor.maxZ, wallHeight)]),
  ];
  for (final (side, at, spans) in walls) {
    final alongX = side == Side.north || side == Side.south;
    void piece(double u0, double u1, double y0, double y1) {
      if (u1 - u0 < 0.001 || y1 - y0 < 0.001) return;
      // Up high the sun shines through, as it does through the ceiling and the loft's roof.
      if (y0 < shadeHeight && y1 > shadeHeight) {
        piece(u0, u1, y0, shadeHeight);
        piece(u0, u1, shadeHeight, y1);
        return;
      }
      plan.pieces.add(WallPiece(side, at, u0, u1, y0, y1));
    }

    void block(double u0, double u1, [double? bottom]) => plan.colliders.add(
      alongX
          ? Collider(minX: u0, maxX: u1, minZ: at - t / 2, maxZ: at + t / 2, top: 99, bottom: bottom)
          : Collider(minX: at - t / 2, maxX: at + t / 2, minZ: u0, maxZ: u1, top: 99, bottom: bottom),
    );
    // Baseboard and collider run between the doors.
    void run(double u0, double u1) {
      if (u1 - u0 < 0.001) return;
      plan.runs.add(WallPiece(side, at, u0, u1, 0, 0.25));
      block(u0, u1);
    }

    final holes = openings.where((o) => o.wall == side).toList()..sort((a, b) => a.u.compareTo(b.u));
    for (final (a, b, top) in spans) {
      var u = a;
      var floorU = a;
      for (final o in holes) {
        final h0 = o.u - o.width / 2;
        final h1 = o.u + o.width / 2;
        if (h0 < a || h1 > b) continue;
        piece(u, h0, 0, top);
        piece(h0, h1, 0, o.y0);
        piece(h0, h1, o.y1, top);
        u = h1;
        if (o.y0 > 0) continue;
        // A door: walk through it, under the wall above.
        run(floorU, h0);
        block(h0, h1, o.y1);
        floorU = h1;
      }
      piece(u, b, 0, top);
      run(floorU, b);
    }
  }
  return plan;
}

// ---------------------------------------------------------------------------------------------
// Outside: the exit stairs, the balcony, the garage and the street.

List<Collider> exitStairsColliders() {
  const s = ExitStairs.steps;
  const rise = -streetY / s;
  const treads = s - 1;
  const run = ExitStairs.run;
  final out = <Collider>[
    Collider(
      minX: ExitStairs.minX,
      maxX: ExitStairs.maxX,
      minZ: ExitStairs.landingZ0,
      maxZ: ExitStairs.landingZ1,
      bottom: streetY,
      top: 0,
    ),
  ];
  for (var i = 1; i <= treads; i++) {
    final z0 = ExitStairs.landingZ1 + (i - 1) * run;
    out.add(
      Collider(minX: ExitStairs.minX, maxX: ExitStairs.maxX, minZ: z0, maxZ: z0 + run, bottom: streetY, top: -i * rise),
    );
  }
  const bottomZ = ExitStairs.landingZ1 + (treads - 0.5) * run;
  out.add(
    Collider(
      minX: ExitStairs.minX - 0.05,
      maxX: ExitStairs.minX + 0.1,
      minZ: ExitStairs.landingZ0,
      maxZ: bottomZ,
      bottom: streetY,
      top: 99,
    ),
  );
  out.add(
    Collider(
      minX: ExitStairs.minX,
      maxX: ExitStairs.maxX,
      minZ: ExitStairs.landingZ0 - 0.05,
      maxZ: ExitStairs.landingZ0 + 0.1,
      bottom: streetY,
      top: 99,
    ),
  );
  return out;
}

/// The balcony's railing runs: (x0, z0, x1, z1) on its three open sides.
const double balconyInset = 0.06;
const List<(double, double, double, double)> balconySides = [
  (Balcony.minX + balconyInset, Balcony.maxZ - balconyInset, Balcony.maxX - balconyInset, Balcony.maxZ - balconyInset),
  (Balcony.minX + balconyInset, Balcony.minZ, Balcony.minX + balconyInset, Balcony.maxZ - balconyInset),
  (Balcony.maxX - balconyInset, Balcony.minZ, Balcony.maxX - balconyInset, Balcony.maxZ - balconyInset),
];

/// Where the bistro table stands, and the balcony's plants (x, z, scale).
const double balconyTableX = 0.2;
const double balconyTableZ = (Balcony.minZ + Balcony.maxZ) / 2 + 0.2;
const List<(double, double, double)> balconyPlants = [
  (Balcony.maxX - 0.55, Balcony.minZ + 0.5, 1.1),
  (Balcony.minX + 0.55, Balcony.maxZ - 0.55, 0.9),
];

Collider _plant(double x, double z, double s, [double floor = 0]) {
  final r = 0.3 * s;
  return Collider(
    minX: x - r,
    maxX: x + r,
    minZ: z - r,
    maxZ: z + r,
    bottom: floor == 0 ? null : floor,
    top: floor + 0.5 * s,
  );
}

/// The posts under the bottom floor's balcony, down to the street (see buildBalconyPosts).
List<Collider> balconyPostColliders() => [
  for (final x in [Balcony.minX + 0.25, Balcony.maxX - 0.25])
    Collider(
      minX: x - 0.14,
      maxX: x + 0.14,
      minZ: Balcony.maxZ - 0.39,
      maxZ: Balcony.maxZ - 0.11,
      bottom: streetY,
      top: -slab,
    ),
];

List<Collider> balconyColliders() {
  const minX = Balcony.minX, maxX = Balcony.maxX, minZ = Balcony.minZ, maxZ = Balcony.maxZ;
  final out = <Collider>[Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, bottom: -slab, top: 0)];
  for (final (x0, z0, x1, z1) in balconySides) {
    out.add(
      Collider(
        minX: math.min(x0, x1) - 0.05,
        maxX: math.max(x0, x1) + 0.05,
        minZ: math.min(z0, z1) - 0.05,
        maxZ: math.max(z0, z1) + 0.05,
        bottom: -slab,
        top: 99,
      ),
    );
  }
  out.add(Collider(minX: -10, maxX: -8, minZ: minZ, maxZ: minZ + 0.55, top: 0.49));
  const tx = balconyTableX, tz = balconyTableZ;
  out.add(Collider(minX: tx - 0.4, maxX: tx + 0.4, minZ: tz - 0.4, maxZ: tz + 0.4, top: 0.77));
  for (final sx in [-1, 1]) {
    final x = tx + sx * 0.8;
    out.add(Collider(minX: x - 0.2, maxX: x + 0.2, minZ: tz - 0.2, maxZ: tz + 0.2, top: 0.49));
  }
  for (final (px, pz, sc) in balconyPlants) {
    out.add(_plant(px, pz, sc));
  }
  out.add(Collider(minX: Ashtray.x - 0.2, maxX: Ashtray.x + 0.2, minZ: Ashtray.z - 0.2, maxZ: Ashtray.z + 0.2, top: 1));
  return out;
}

/// The building's footprint, walls included.
abstract final class Bldg {
  static const double minX = Floor.minX - wallT;
  static const double maxX = Floor.maxX + wallT;
  static const double minZ = Floor.minZ - wallT;
  static const double maxZ = Floor.maxZ + wallT;
}

/// A car's footprint, and how high its body and its roof come up (CAR in cars.ts).
abstract final class CarSize {
  static const double length = 4.6;
  static const double width = 2;
  static const double body = 0.82;
  static const double roof = 1.12;
}

enum CarKind { lambo, ferrari }

/// A parked car: which, its paint, where, and its turn (a multiple of 90°).
typedef ParkedCar = ({CarKind kind, String color, double x, double z, double rotY});

/// The cars: Lambos nose-in along the back wall, Ferraris backed in facing the street, and one
/// left out front, for everyone upstairs to look at.
final List<ParkedCar> parkedCars = [
  for (final (kind, color, x, face) in const [
    (CarKind.lambo, '#8ac926', -14.4, -1),
    (CarKind.lambo, '#ff7b00', -8.0, -1),
    (CarKind.lambo, '#ffd000', 1.6, -1),
    (CarKind.lambo, '#7b2cbf', 11.2, -1),
    (CarKind.ferrari, '#d90429', -14.4, 1),
    (CarKind.ferrari, '#d90429', -4.8, 1),
    (CarKind.ferrari, '#ffc300', 4.8, 1),
    (CarKind.ferrari, '#e5383b', 14.4, 1),
  ])
    (
      kind: kind,
      color: color,
      x: x,
      z: face < 0 ? Bldg.minZ + wallT + 0.4 + CarSize.length / 2 : Bldg.maxZ - 0.5 - CarSize.length / 2,
      rotY: face < 0 ? math.pi : 0.0,
    ),
  (kind: CarKind.lambo, color: '#00b4d8', x: 9.0, z: 18.2, rotY: math.pi / 2),
];

/// A car's colliders, which you can hop up on: its body, and its roof (park() in outside.ts).
List<Collider> carColliders(ParkedCar car) {
  final c = math.cos(car.rotY).round();
  final sn = math.sin(car.rotY).round();
  Collider rect(double x0, double x1, double z0, double z1, double top) {
    final xs = [x0 * c + z0 * sn, x1 * c + z1 * sn];
    final zs = [-x0 * sn + z0 * c, -x1 * sn + z1 * c];
    return Collider(
      minX: car.x + math.min(xs[0], xs[1]),
      maxX: car.x + math.max(xs[0], xs[1]),
      minZ: car.z + math.min(zs[0], zs[1]),
      maxZ: car.z + math.max(zs[0], zs[1]),
      bottom: streetY,
      top: streetY + top,
    );
  }

  return [
    rect(
      -CarSize.width / 2 + 0.08,
      CarSize.width / 2 - 0.08,
      -CarSize.length / 2 + 0.08,
      CarSize.length / 2 - 0.08,
      CarSize.body,
    ),
    rect(-0.6, 0.6, -1.3, 0.1, CarSize.roof),
  ];
}

/// The garage's back and west walls (x0, x1, z0, z1).
const List<(double, double, double, double)> garageWalls = [
  (Bldg.minX, Bldg.maxX, Bldg.minZ, Bldg.minZ + wallT),
  (Bldg.minX, Bldg.minX + wallT, Bldg.minZ, Bldg.maxZ),
];

/// Columns holding up the office, along the open sides and down the middle.
final List<(double, double)> garageColumns = [
  for (final x in [Bldg.maxX - 0.25, -9.6, 0.0, 9.6]) ...[(x, Bldg.maxZ - 0.25), (x, 0.0)],
  (Bldg.maxX - 0.25, -6.5),
  (Bldg.maxX - 0.25, 6.5),
  (Bldg.maxX - 0.25, Bldg.minZ + 0.25),
];

/// The garage's walls, columns and cars. The slab over it, which is the office's floor, is
/// stack_plan.dart's: holes go through it to the floor below.
List<Collider> garageColliders() {
  const ceiling = -slab;
  final out = <Collider>[];
  for (final (x0, x1, z0, z1) in garageWalls) {
    out.add(Collider(minX: x0, maxX: x1, minZ: z0, maxZ: z1, bottom: streetY, top: ceiling));
  }
  for (final (x, z) in garageColumns) {
    out.add(Collider(minX: x - 0.25, maxX: x + 0.25, minZ: z - 0.25, maxZ: z + 0.25, bottom: streetY, top: ceiling));
  }
  for (final car in parkedCars) {
    out.addAll(carColliders(car));
  }
  return out;
}

/// Street lamps down both sidewalks: (x, z, which way the arm reaches in z).
final List<(double, double, double)> streetLamps = [
  for (final x in [-40.0, -28.0, -16.0, -4.0, 8.0, 16.0, 28.0, 40.0]) (x, 22.2, 1.0),
  for (final x in [-34.0, -22.0, -4.0, 8.0, 26.0, 36.0]) (x, 31.8, -1.0),
];
const double streetLampHeight = 5;

List<Collider> streetColliders() => [
  // What you stand on anywhere out there, the lot and the road and the grass alike.
  Collider(minX: -200, maxX: 200, minZ: -200, maxZ: 200, bottom: streetY - 1, top: streetY),
  for (final (x, z, _) in streetLamps)
    Collider(
      minX: x - 0.2,
      maxX: x + 0.2,
      minZ: z - 0.2,
      maxZ: z + 0.2,
      bottom: streetY,
      top: streetY + streetLampHeight,
    ),
];

// ---------------------------------------------------------------------------------------------
// Inside.

Collider deskCollider(DeskDef def) {
  const hw = DeskSize.width / 2 - 0.05;
  const hd = DeskSize.depth / 2 - 0.02;
  return Collider(minX: def.x - hw, maxX: def.x + hw, minZ: def.z - hd, maxZ: def.z + hd, top: DeskSize.height);
}

/// A bean bag's footprint, with the lap desk in front of it (-z), in its own frame.
abstract final class BeanbagBox {
  static const double minX = -0.62;
  static const double maxX = 0.62;
  static const double minZ = -1.1;
  static const double maxZ = 0.64;
  static const double top = 0.62;
}

/// A bean bag's footprint turned the way it faces (a quarter turn at a time).
Collider beanbagCollider(DeskDef def) {
  final c = math.cos(def.rotY).round();
  final s = math.sin(def.rotY).round();
  final xs = [
    for (final lx in [BeanbagBox.minX, BeanbagBox.maxX])
      for (final lz in [BeanbagBox.minZ, BeanbagBox.maxZ]) def.x + lx * c + lz * s,
  ];
  final zs = [
    for (final lx in [BeanbagBox.minX, BeanbagBox.maxX])
      for (final lz in [BeanbagBox.minZ, BeanbagBox.maxZ]) def.z - lx * s + lz * c,
  ];
  return Collider(
    minX: xs.reduce(math.min),
    maxX: xs.reduce(math.max),
    minZ: zs.reduce(math.min),
    maxZ: zs.reduce(math.max),
    top: BeanbagBox.top,
  );
}

/// The lounge's two beanbags (colour, x, z).
const List<(String, double, double)> loungeBeanbags = [('#06d6a0', 12.5, 3.5), ('#ffd166', 14.5, -3.4)];

Collider jukeboxCollider() {
  const d = lay.Jukebox.depth, r = lay.Jukebox.width / 2;
  return Collider(
    minX: lay.Jukebox.x - d / 2 - 0.05,
    maxX: lay.Jukebox.x + d / 2,
    minZ: lay.Jukebox.z - r - 0.05,
    maxZ: lay.Jukebox.z + r + 0.05,
    top: lay.Jukebox.height,
  );
}

List<Collider> loungeColliders() => [
  Collider(minX: 10, maxX: 11, minZ: -2.2, maxZ: 2.2, top: 0.55),
  Collider(minX: 12.2, maxX: 13.8, minZ: -0.8, maxZ: 0.8, top: 0.46),
  for (final (_, x, z) in loungeBeanbags)
    Collider(minX: x - 0.5, maxX: x + 0.5, minZ: z - 0.5, maxZ: z + 0.5, top: 0.6),
  jukeboxCollider(),
];

List<Collider> kitchenColliders() => [
  Collider(minX: -17, maxX: -12, minZ: 11.7, maxZ: 12.7, top: 1.03),
  Collider(minX: -11.85, maxX: -10.75, minZ: 11.7, maxZ: 12.7, top: 2.2),
];

/// Plants around the room (x, z, scale).
const List<(double, double, double)> roomPlants = [
  (-17.2, -12.2, 1.4),
  (17.2, -12.2, 1.5),
  (17.2, 12.2, 1.3),
  (-17.2, 8.5, 1.2),
  (5.5, -12.2, 1.1),
  (-6, 0, 1),
  (3.5, 0, 0.9),
  (8.5, 5, 1.1),
];

List<Collider> plantColliders() => [for (final (x, z, s) in roomPlants) _plant(x, z, s)];

/// The loft's measurements that the building and the colliders share.
abstract final class LoftPlan {
  static const double slabT = 0.25;

  /// The glass walls' thickness.
  static const double glassT = 0.12;
  static const double cx = (Loft.minX + Loft.maxX) / 2;
  static const double cz = (Loft.minZ + Loft.maxZ) / 2;
  static const double roofY = Loft.y + Loft.height;
  static const double doorZ = Stairs.minZ;
  static const double doorTop = Loft.y + 2.3;
  static const double deskX = cx + 0.5;
  static const double deskZ = cz - 0.3;
  static const List<(double, double, double)> plants = [
    (Loft.maxX - 0.6, Loft.minZ + 0.6, 1),
    (Loft.maxX - 0.6, Loft.maxZ - 0.6, 1.2),
  ];
}

List<Collider> loftColliders() {
  const minX = Loft.minX, maxX = Loft.maxX, minZ = Loft.minZ, maxZ = Loft.maxZ, floorY = Loft.y;
  const cx = LoftPlan.cx, cz = LoftPlan.cz, roofY = LoftPlan.roofY, t = LoftPlan.glassT;
  final out = <Collider>[
    Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, bottom: floorY - LoftPlan.slabT, top: floorY),
  ];
  for (final x in [minX + 0.15, cx]) {
    out.add(
      Collider(minX: x - 0.14, maxX: x + 0.14, minZ: minZ + 0.01, maxZ: minZ + 0.29, top: floorY - LoftPlan.slabT),
    );
  }
  out.add(Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ, bottom: roofY, top: roofY + 0.2));
  out.add(Collider(minX: minX, maxX: maxX, minZ: minZ, maxZ: minZ + t, bottom: floorY, top: 99));
  out.add(Collider(minX: minX, maxX: minX + t, minZ: minZ, maxZ: LoftPlan.doorZ, bottom: floorY, top: 99));
  out.add(Collider(minX: minX, maxX: minX + t, minZ: LoftPlan.doorZ, maxZ: maxZ, bottom: LoftPlan.doorTop, top: roofY));
  // The stairs, step by step.
  const run = (Stairs.toX - Stairs.fromX) / Stairs.steps;
  const rise = floorY / Stairs.steps;
  for (var i = 1; i <= Stairs.steps; i++) {
    out.add(
      Collider(
        minX: Stairs.fromX + (i - 1) * run,
        maxX: Stairs.fromX + i * run,
        minZ: Stairs.minZ,
        maxZ: Stairs.maxZ,
        top: i * rise,
      ),
    );
  }
  // You can't step off the side of the stairs, or climb on from it.
  out.add(Collider(minX: Stairs.fromX, maxX: Stairs.toX, minZ: Stairs.minZ - 0.1, maxZ: Stairs.minZ, top: 99));
  const dx = LoftPlan.deskX, dz = LoftPlan.deskZ;
  out.add(Collider(minX: dx - 1.3, maxX: dx + 1.3, minZ: dz - 0.6, maxZ: dz + 0.6, bottom: floorY, top: floorY + 0.8));
  out.add(Collider(minX: maxX - 1.15, maxX: maxX, minZ: cz - 1.2, maxZ: cz + 1.2, bottom: floorY, top: floorY + 0.55));
  out.add(
    Collider(
      minX: minX + 0.65,
      maxX: minX + 1.15,
      minZ: minZ + 0.65,
      maxZ: minZ + 1.15,
      bottom: floorY,
      top: floorY + 1.3,
    ),
  );
  for (final (px, pz, s) in LoftPlan.plants) {
    out.add(_plant(px, pz, s, floorY));
  }
  return out;
}

/// The elevator shaft's colliders; the last is its doors, which open for walking (top -1) once
/// they're most of the way open.
List<Collider> elevatorColliders() {
  const x = lay.Elevator.x, width = lay.Elevator.width, wall = lay.Elevator.wall, doorWidth = lay.Elevator.doorWidth;
  const minX = x - width / 2, maxX = x + width / 2, back = Floor.minZ, front = elevatorFront;
  return [
    for (final sx in [minX + wall / 2, maxX - wall / 2])
      Collider(minX: sx - wall / 2, maxX: sx + wall / 2, minZ: back, maxZ: front, top: 99),
    for (final (x0, x1) in [(minX, x - doorWidth / 2), (x + doorWidth / 2, maxX)])
      Collider(minX: x0, maxX: x1, minZ: front - wall, maxZ: front, top: 99),
    Collider(minX: x - doorWidth / 2, maxX: x + doorWidth / 2, minZ: front - wall - 0.06, maxZ: front, top: 99),
  ];
}

List<Collider> gongColliders() {
  const x = lay.Gong.x, z = lay.Gong.z, half = lay.Gong.width / 2;
  return [
    Collider(minX: x - half - 0.12, maxX: x + half + 0.3, minZ: z - 0.3, maxZ: z + 0.3, top: lay.Gong.height + 0.1),
  ];
}

List<Collider> whiteboardColliders() {
  const x = lay.Whiteboard.x, z = lay.Whiteboard.z, post = lay.Whiteboard.width / 2 + 0.1;
  return [
    Collider(
      minX: x - post - 0.1,
      maxX: x + post + 0.1,
      minZ: z - 0.48,
      maxZ: z + 0.48,
      top: lay.Whiteboard.bottom + lay.Whiteboard.height + 0.35,
    ),
  ];
}

/// Down to the street, which is the bottom floor's: the steps down from its exit door, the posts
/// under its balcony, the garage under it and the street out front. On a floor above it, all of it
/// is that many storeys further down (see Office.setLevel).
List<Collider> groundColliders() => [
  ...exitStairsColliders(),
  ...balconyPostColliders(),
  ...garageColliders(),
  ...streetColliders(),
];

/// Everything in the office you can't walk through, in the order office.ts pushes it. Pass the
/// built elevator's colliders so its door collider is the one it opens and shuts, and the ground's
/// so they're the ones that move down with the street.
List<Collider> officeColliders({List<Collider>? elevator, List<Collider>? ground}) => [
  ...wallsPlan().colliders,
  ...balconyColliders(),
  ...(ground ?? groundColliders()),
  for (final d in desks) deskCollider(d),
  ...loungeColliders(),
  ...kitchenColliders(),
  ...plantColliders(),
  ...loftColliders(),
  ...(elevator ?? elevatorColliders()),
  ...gongColliders(),
  ...whiteboardColliders(),
];
