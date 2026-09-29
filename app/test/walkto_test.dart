import 'package:agent_office/walkto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

void main() {
  test('across the office floor, the route ends where they stand', () {
    final way = wayTo((x: -10, y: 0, z: -8), (x: 5, y: 0, z: 5));
    expect(way, isNotEmpty);
    expect(way.last.x, closeTo(5, 1));
    expect(way.last.z, closeTo(5, 1));
  });

  test('up to the boss\'s office: via the foot of the stairs and its door', () {
    final way = wayTo((x: -10, y: 0, z: -8), (x: 14, y: Loft.y, z: 11));
    expect(way.last, (x: 14.0, z: 11.0));
    expect(way[way.length - 2], (x: Loft.minX + 0.6, z: (Stairs.minZ + Stairs.maxZ) / 2));
    expect(way[way.length - 3], (x: Stairs.fromX - 0.6, z: (Stairs.minZ + Stairs.maxZ) / 2));
  });

  test('out onto the balcony through its doors, and within a room straight there', () {
    final way = wayTo((x: 0, y: 0, z: 0), (x: -5, y: 0, z: 14.5));
    expect(way.last, (x: -5.0, z: 14.5));
    expect(way[way.length - 2].x, balconyDoor.u);
    expect(wayTo((x: -8, y: 0, z: 14.5), (x: -5, y: 0, z: 14.5)), [(x: -5.0, z: 14.5)]);
    expect(wayTo((x: 0, y: -3.6, z: 20), (x: 0, y: 0, z: 0)), [(x: 0.0, z: 0.0)]);
  });
}
