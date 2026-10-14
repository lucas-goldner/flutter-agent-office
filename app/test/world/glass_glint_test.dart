import 'package:agent_office/world/office/parts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  test('a glint on a narrow pane is trimmed to the pane', () {
    const w = 0.5, h = 2.0;
    final strip = slantedStrip(-w * 0.2, h * 0.07, 0.18, h * 0.55, -0.5);
    // Untrimmed, the slanted strip runs out over the frame.
    expect(strip.any((p) => p.x.abs() > w / 2 - 0.02 || p.y.abs() > h / 2 - 0.02), isTrue);
    final out = clipToBox(strip, w / 2 - 0.02, h / 2 - 0.02);
    expect(out.length, greaterThanOrEqualTo(3));
    for (final p in out) {
      expect(p.x.abs(), lessThanOrEqualTo(w / 2 - 0.02 + 1e-6));
      expect(p.y.abs(), lessThanOrEqualTo(h / 2 - 0.02 + 1e-6));
    }
  });

  test('a strip wholly inside is left alone, one wholly outside is gone', () {
    final inside = [vm.Vector2(-0.1, -0.1), vm.Vector2(0.1, -0.1), vm.Vector2(0.1, 0.1), vm.Vector2(-0.1, 0.1)];
    expect(clipToBox(inside, 1, 1), hasLength(4));
    final outside = [for (final p in inside) p + vm.Vector2(5, 0)];
    expect(clipToBox(outside, 1, 1), isEmpty);
  });
}
