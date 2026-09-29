// Walking a path by yourself (walking over to a teammate): there, cancelled by a key, or stuck.

import 'package:agent_office/world/collider.dart';
import 'package:agent_office/world/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

Collider get officeFloor =>
    Collider(minX: Floor.minX, maxX: Floor.maxX, minZ: Floor.minZ, maxZ: Floor.maxZ, bottom: -slab, top: 0);

void main() {
  test('walks through the corners and says it arrived', () {
    final p = PlayerController([officeFloor]);
    final ends = <PathEnd>[];
    p.onPathEnd = ends.add;
    p.walkPath([(x: 2, z: 0), (x: 2, z: 3)]);
    for (var i = 0; i < 200 && p.walkingPath; i++) {
      p.update(1 / 60);
    }
    expect(ends, [PathEnd.arrived]);
    expect(p.pos.x, closeTo(2, 0.3));
    expect(p.pos.z, closeTo(3, 0.3));
  });

  test('a key of your own takes over', () {
    final p = PlayerController([officeFloor]);
    final ends = <PathEnd>[];
    p.onPathEnd = ends.add;
    p.walkPath([(x: 10, z: 0)]);
    p.update(1 / 60);
    p.input.back = true;
    p.update(1 / 60);
    expect(ends, [PathEnd.cancelled]);
    expect(p.walkingPath, isFalse);
  });

  test('up against a wall it gives up', () {
    final wall = Collider(minX: 1, maxX: 1.5, minZ: -5, maxZ: 5, top: 3);
    final p = PlayerController([officeFloor, wall]);
    final ends = <PathEnd>[];
    p.onPathEnd = ends.add;
    p.walkPath([(x: 4, z: 0)]);
    for (var i = 0; i < 200 && p.walkingPath; i++) {
      p.update(1 / 60);
    }
    expect(ends, [PathEnd.stuck]);
  });
}
