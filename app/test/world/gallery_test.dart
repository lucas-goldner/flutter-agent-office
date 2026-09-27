import 'package:office_shared/layout.dart';
import 'package:agent_office/world/wall_aim.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  group('aimAtWall', () {
    test('looking north from the middle of the room meets the north wall', () {
      final hit = aimAtWall(vm.Vector3(0, 1.4, -8), vm.Vector3(0, 0, -1));
      expect(hit?.wall, Side.north);
      expect(hit!.u, closeTo(0, 1e-5));
      expect(hit.y, closeTo(1.4, 1e-5));
    });

    test('u runs along z on the side walls', () {
      final hit = aimAtWall(vm.Vector3(0, 2, 3), vm.Vector3(-1, 0, 0));
      expect(hit?.wall, Side.west);
      expect(hit!.u, closeTo(3, 1e-5));
    });

    test('nothing from outside the room, or past the reach', () {
      expect(aimAtWall(vm.Vector3(0, 1.4, 20), vm.Vector3(0, 0, -1)), isNull);
      expect(aimAtWall(vm.Vector3(0, 1.4, -8), vm.Vector3(0, 0, -1), 2), isNull);
    });

    test('above the wall top misses', () {
      final d = vm.Vector3(0, 1, -0.2)..normalize();
      expect(aimAtWall(vm.Vector3(0, 1.4, -8), d), isNull);
    });

    test('the loft floor hides the wall behind it from below', () {
      // Under the loft, looking up and east: the slab is in the way before the east wall.
      final d = vm.Vector3(1, 0.5, 0)..normalize();
      expect(aimAtWall(vm.Vector3(12, 1.4, 10), d), isNull);
    });
  });
}
