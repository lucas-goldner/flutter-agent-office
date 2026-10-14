import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/maps/maps.dart' show planOf;
import 'package:office_shared/maps/types.dart' show WallSide;
import 'package:vector_math/vector_math.dart' as vm;

import 'package:agent_office/world/station/shell.dart';
import 'package:agent_office/world/station/space.dart';

void main() {
  test('skyward: forward is -z, starboard +x, up +y', () {
    expect((skyward(0, 0) - vm.Vector3(0, 0, -1)).length, lessThan(1e-9));
    expect((skyward(90, 0) - vm.Vector3(1, 0, 0)).length, lessThan(1e-9));
    expect((skyward(0, 90) - vm.Vector3(0, 1, 0)).length, lessThan(1e-9));
    // The Sun is up and off to port.
    expect(sunward.y, greaterThan(0));
    expect(sunward.x, lessThan(0));
  });

  test('a wall frame builds out through its wall', () {
    final b = planOf('station').bounds;
    final east = WallFrame(b, WallSide.east);
    expect(east.out, (1.0, 0.0));
    expect(east.at(3, 0), (b.maxX, 3.0));
    expect(east.at(3, 0.5), (b.maxX + 0.5, 3.0));
    expect(east.rotY, closeTo(math.pi / 2, 1e-9));
    final north = WallFrame(b, WallSide.north);
    expect(north.at(-2, 1), (-2.0, b.minZ - 1));
    expect(north.rotY.abs(), closeTo(math.pi, 1e-9));
  });

  test("the station's palette fills in what a map leaves out", () {
    final pal = stationPalette(planOf('station'));
    expect(pal.glow, startsWith('#'));
    expect(pal.hull, startsWith('#'));
  });
}
