// What you bump into and what you can use: a port of Collider and Interactable from office.ts.

import 'package:flutter_scene/scene.dart';

/// A box footprint you can't walk through (or can stand on top of, up to [top]).
class Collider {
  Collider({
    required this.minX,
    required this.maxX,
    required this.minZ,
    required this.maxZ,
    required this.top,
    this.bottom,
    this.fence = false,
  });

  /// Mutable for what moves: the garage's cars (world/office/fleet.dart).
  double minX;
  double maxX;
  double minZ;
  double maxZ;

  /// Mutable for the elevator's doors, which stop blocking you once they're open.
  double top;

  /// Underside, for things you walk beneath (the loft). Null means the floor. Mutable for what's
  /// down on the street, which is further down the higher your floor is (Office.setLevel).
  double? bottom;

  /// Only there to keep people out: its top isn't anything to land on, so confetti falls through it.
  final bool fence;

  @override
  String toString() => 'Collider($minX..$maxX, $minZ..$maxZ, top $top${bottom == null ? '' : ', bottom $bottom'})';
}

/// Whether the segment from [a] to [b] (world space) passes through any of [colliders], leaving out those
/// either end stands in (whoever the label is over, say). Boxes only: what label sight lines need, without
/// testing triangles.
bool segmentBlocked(List<Collider> colliders, double ax, double ay, double az, double bx, double by, double bz) {
  final dx = bx - ax, dy = by - ay, dz = bz - az;
  bool inside(Collider c, double x, double y, double z) =>
      x >= c.minX && x <= c.maxX && z >= c.minZ && z <= c.maxZ && y <= c.top && y >= (c.bottom ?? -1e9);
  for (final c in colliders) {
    if (c.fence) continue;
    if (inside(c, ax, ay, az) || inside(c, bx, by, bz)) continue;
    var t0 = 0.0, t1 = 1.0;
    bool slab(double o, double d, double lo, double hi) {
      if (d.abs() < 1e-9) return o >= lo && o <= hi;
      var u = (lo - o) / d, v = (hi - o) / d;
      if (u > v) (u, v) = (v, u);
      if (u > t0) t0 = u;
      if (v < t1) t1 = v;
      return t0 <= t1;
    }

    if (slab(ax, dx, c.minX, c.maxX) && slab(az, dz, c.minZ, c.maxZ) && slab(ay, dy, c.bottom ?? -1e9, c.top)) {
      return true;
    }
  }
  return false;
}

enum InteractKind {
  desk,
  issues,
  pulls,
  services,
  queue,
  tv,
  coffee,
  decor,
  smoke,
  elevator,
  gong,
  dog,
  jukebox,
  seat,
  whiteboard,
  // The games and rooms (office/rooms_hub.dart).
  station,
  cabinet,
  meeting,
  golf,
  ball,
  bookshelf,
  // The rooftop bar (office/roof.dart).
  bar,
  dj,
  // Between floors (world/climb.dart).
  ladder,
  pole,
  // The rooftop bar's dart board and axe lane (office/throwing.dart).
  darts,
  axe,
  // The boss loft's telescope (office/telescope.dart).
  telescope,
  // One of the garage's cars (office/driving.dart).
  car,
  // The "Room to grow" sign: build out the back office (world/office/wing.dart).
  expand,
  // A map's herald, who sends out new workers (the castle's Hand of the King).
  herald,
}

/// Something you can use: walk up to it and press E, or click it.
class Interactable {
  Interactable({
    required this.kind,
    required this.x,
    required this.z,
    this.y,
    required this.radius,
    this.deskId,
    this.decorId,
    this.seatId,
    this.pole,
    this.car,
    this.off = false,
    this.label,
  });

  final InteractKind kind;
  double x;
  double z;

  /// The floor it's on, when that's not the office floor (the loft's).
  double? y;
  double radius;
  String? deskId;
  String? decorId;
  String? seatId;

  /// Which of the fire poles (layout's `poles`), for a pole.
  int? pole;

  /// Which of the garage's cars (shared garage's `cars`), for a car.
  int? car;

  /// Put away for now (a bean bag nobody needs yet): can't be used.
  bool off;

  /// What the hint calls it, where a map's own looks differ from the office's (the castle's ale for the coffee machine).
  final String? label;
}

/// Which node carries which interactable, for clicking: the old `userData.interact`. A raycast hit
/// walks up the parent chain until it finds one (see [interactableOf]).
final Expando<Interactable> _interact = Expando('interact');

void tagInteract(Node node, Interactable? it) => _interact[node] = it;

Interactable? interactableOf(Node? node) {
  for (var n = node; n != null; n = n.parent) {
    final it = _interact[n];
    if (it != null) return it;
  }
  return null;
}
