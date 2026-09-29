// The way over to a teammate you clicked in the people list: round the furniture downstairs (see
// office_shared's nav.dart), and up the stairs to the boss's office or out through the balcony
// doors when that's where they are. A port of walkto.ts.

import 'package:office_shared/layout.dart';
import 'package:office_shared/nav.dart' show route;

typedef WalkSpot = ({double x, double y, double z});
typedef Corner = ({double x, double z});

enum _Zone { floor, stairs, loft, balcony, outside }

const double _stairsZ = (Stairs.minZ + Stairs.maxZ) / 2;

/// Just inside the boss's office door at the top of the stairs, and just off the bottom step.
const Corner _stairsTop = (x: Loft.minX + 0.6, z: _stairsZ);
const Corner _stairsFoot = (x: Stairs.fromX - 0.6, z: _stairsZ);

/// The points on the way from each part of the building out onto the office floor: down the stairs
/// from the boss's office (out through its door at the top), in through the balcony doors.
final Map<_Zone, List<Corner>> _wayDown = {
  _Zone.floor: const [],
  _Zone.stairs: const [_stairsFoot],
  _Zone.loft: const [_stairsTop, _stairsFoot],
  _Zone.balcony: [(x: balconyDoor.u, z: Floor.maxZ + wallT + 0.6), (x: balconyDoor.u, z: Floor.maxZ - 0.7)],
  _Zone.outside: const [],
};

_Zone _zoneOf(WalkSpot p) {
  if (p.y < -1 || p.x < Floor.minX || p.x > Floor.maxX || p.z < Floor.minZ) return _Zone.outside;
  if (p.z > Floor.maxZ) return p.x >= Balcony.minX && p.x <= Balcony.maxX ? _Zone.balcony : _Zone.outside;
  if (p.x > Loft.minX && p.z > Loft.minZ && p.y > Loft.y - 0.5) return _Zone.loft;
  // Off the office floor's map, which has the stairs down as a wall.
  if (p.x > Stairs.fromX - 0.1 && p.x < Stairs.toX + 0.1 && p.z > Stairs.minZ - 0.1 && p.y > 0.05) return _Zone.stairs;
  return _Zone.floor;
}

/// The corners of a walk from [from] to [to], [to] included when it's somewhere you can stand.
List<Corner> wayTo(WalkSpot from, WalkSpot to) {
  final a = _zoneOf(from), b = _zoneOf(to);
  final end0 = (x: to.x, z: to.z);
  // Across the same room upstairs or on the balcony, or somewhere the office has no map of: straight there.
  if ((a == b && a != _Zone.floor) || a == _Zone.outside || b == _Zone.outside) return [end0];
  // Between the stairs and the boss's office at the top of them: through its door.
  if ((a == _Zone.stairs && b == _Zone.loft) || (a == _Zone.loft && b == _Zone.stairs)) return [_stairsTop, end0];
  final out = _wayDown[a]!;
  final into = _wayDown[b]!.reversed.toList();
  final start = out.isNotEmpty ? out.last : (x: from.x, z: from.z);
  final end = into.isNotEmpty ? into.first : end0;
  // Across the office floor; route stops at the nearest place to stand if they're in a chair or on the couch.
  final across = [for (final (x, z) in route((start.x, start.z), (end.x, end.z)).skip(1)) (x: x, z: z)];
  return [...out, ...across, ...into.skip(1), if (b != _Zone.floor) end0];
}
