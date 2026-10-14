// The castle's line for the throne (world/court.dart), and the escort's step behind a worker it marches
// along (office/send_home.dart).
import 'package:agent_office/office/send_home.dart' show behind;
import 'package:agent_office/world/court.dart' show lineGoals, yawOf;
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/maps/maps.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  test('whoever has waited longest is at the front of the line, as many as there are spots', () {
    final goals = lineGoals(['b', 'gone', 'a', 'c'], ['a', 'b', 'c', 'd'], 2);
    expect(goals, {'b': 0, 'a': 1, 'c': null, 'd': null});
  });

  test('when the one at the front is seen to, the rest shuffle forward', () {
    final before = lineGoals(['a', 'b', 'c'], ['a', 'b', 'c'], 8);
    final after = lineGoals(['b', 'c'], ['a', 'b', 'c'], 8);
    expect(before, {'a': 0, 'b': 1, 'c': 2});
    expect(after, {'a': null, 'b': 0, 'c': 1});
  });

  test('the castle has a line, a spot for each of its places', () {
    final plan = planOf('castle');
    expect(plan.lineup.length, 8);
    // Facing the throne, one behind another.
    for (var i = 1; i < plan.lineup.length; i++) {
      expect(plan.lineup[i].z, greaterThan(plan.lineup[i - 1].z));
    }
  });

  test('an escort keeps a step behind the worker, back along the way it walked', () {
    final trail = <(double, double)>[(0, 0), (0, 1), (0, 2), (1, 2)];
    final (x, z) = behind(trail, 0.8)!;
    expect(x, closeTo(0.2, 1e-9));
    expect(z, closeTo(2, 1e-9));
    final (x2, z2) = behind(trail, 1.5)!;
    expect(x2, closeTo(0, 1e-9));
    expect(z2, closeTo(1.5, 1e-9));
    // Not that far along yet: nowhere to be.
    expect(behind(trail, 10), isNull);
  });

  test('a heading is which way +z points, round y', () {
    for (final a in [0.0, 0.7, -2.1, 3.0]) {
      final m = vm.Matrix4.compose(
        vm.Vector3(1, 2, 3),
        vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), a),
        vm.Vector3.all(0.8),
      );
      expect(yawOf(m), closeTo(a, 1e-6));
    }
  });
}
