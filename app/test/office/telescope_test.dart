// tests/telescope.test.ts: the telescope's view is its own while you look, the mouse aims it, and
// stepping away hands the camera back, however many times you visit.

import 'dart:math' as math;

import 'package:agent_office/office/telescope.dart';
import 'package:agent_office/world/space.dart';
import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  test('telescope view restores its camera and callbacks across repeated visits', () {
    final camera = PerspectiveCamera(
      fovRadiansY: 61 * math.pi / 180,
      position: vm.Vector3(2, 3, 4),
      target: vm.Vector3(2, 3, 3),
    );
    var enters = 0, exits = 0;
    final view = TelescopeView(onEnter: () => enters++, onExit: () => exits++);
    for (var visit = 0; visit < 3; visit++) {
      expect(view.enter(), isTrue);
      expect(view.enter(), isFalse, reason: 'enter is idempotent');
      final through = view.update(camera);
      expect(through.fovRadiansY, closeTo(telescopeFov * math.pi / 180, 1e-9));
      expect(through.position, toEngine(telescopeEye));
      expect(view.showing.value, isTrue);

      final aimed = view.forward;
      view.look(80, -25);
      expect(math.acos(aimed.dot(view.forward).clamp(-1, 1)), greaterThan(0.05), reason: 'the mouse aims it');
      // It only swings so far.
      view.look(-1e6, 1e6);
      expect((view.yaw - view.baseYaw).abs(), lessThanOrEqualTo(0.42 + 1e-9));
      expect(view.pitch, greaterThanOrEqualTo(-0.5));

      expect(view.exit(), isTrue);
      expect(view.active, isFalse);
      expect(identical(view.update(camera), camera), isTrue, reason: 'the camera is yours again');
      expect(view.showing.value, isFalse);
      expect(view.exit(), isFalse, reason: 'exit is idempotent');
    }
    expect(enters, 3);
    expect(exits, 3);
  });

  test('it looks from the loft toward the desks, and starts aimed there each visit', () {
    final view = TelescopeView(onEnter: () {}, onExit: () {});
    view.enter();
    final f = view.forward;
    expect(f.x, lessThan(0), reason: 'west, toward the desks');
    expect(f.y, lessThan(0), reason: 'down from the loft');
    view.look(300, 0);
    view.exit();
    view.enter();
    expect(view.yaw, view.baseYaw);
  });
}
