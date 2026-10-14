import 'package:agent_office/world/lamplight.dart';
import 'package:agent_office/world/sky_model.dart' show Rgb;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  final lowSun = vm.Vector3(1, 0.1, 0)..normalize();
  final white = Rgb.hex(0xffffff);

  ({vm.Vector3 dir, Rgb color, double intensity}) step(Lamplight l, bool inside, double lampsOn, {double dt = 0.1}) =>
      l.apply(inside: inside, dt: dt, dir: lowSun, color: white, intensity: 0.2, lampsOn: lampsOn);

  test('outdoors the sky light is left alone', () {
    final l = Lamplight();
    final out = step(l, false, 1);
    expect(out.dir, lowSun);
    expect(out.intensity, 0.2);
  });

  test('indoors it eases round to nearly straight down', () {
    final l = Lamplight();
    final first = step(l, true, 0);
    expect(l.indoorness, greaterThan(0));
    expect(l.indoorness, lessThan(1));
    expect(first.dir.y, greaterThan(lowSun.y));
    for (var i = 0; i < 100; i++) {
      step(l, true, 0);
    }
    final settled = step(l, true, 0);
    expect(settled.dir.angleTo(IndoorLight.dir), lessThan(0.01));
    // With the lamps off, it's no brighter than the sky made it.
    expect(settled.intensity, closeTo(0.2, 1e-9));
  });

  test('with the lamps on it is warm and as bright as they are', () {
    final l = Lamplight()..indoorness = 1;
    final lit = step(l, true, 1, dt: 0);
    expect(lit.intensity, closeTo(IndoorLight.lamp, 1e-9));
    expect(lit.color.b, lessThan(white.b));
    expect(lit.color.r, closeTo(white.r, 1e-9));
  });
}
