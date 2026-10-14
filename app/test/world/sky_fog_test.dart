import 'package:agent_office/world/sky_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

// Upstream's tests/sky-fog.test.ts checked the shader; here the engine's fog is one distance for the
// whole view, so the room is kept clear by where the fog starts.
void main() {
  const fog = (start: 3.0, end: 28.0);

  test('in the office, the fog starts past the room, with the same ramp', () {
    final f = clearRoomFog(fog, vm.Vector3(0, 1.6, 0));
    // The far corner from the middle: about 18 x 13 out and up to the ceiling.
    expect(f.start, greaterThan(22));
    expect(f.end - f.start, closeTo(25, 1e-9));
  });

  test('from a corner, it reaches the far one', () {
    final f = clearRoomFog(fog, vm.Vector3(-17, 1.6, 12));
    expect(f.start, greaterThan(40));
  });

  test('out on the street, the fog is left as it is', () {
    expect(clearRoomFog(fog, vm.Vector3(0, 1.6, 30)), fog);
  });

  test('in the back office too, once the floor is built out into it', () {
    const wing = (minX: -18.2, maxX: 18.2, minZ: -25.0, maxZ: -13.0);
    expect(clearRoomFog(fog, vm.Vector3(0, 1.6, -20)), fog);
    final f = clearRoomFog(fog, vm.Vector3(0, 1.6, -20), wing: wing);
    expect(f.start, greaterThan(30));
  });

  test('a fog that already starts past the room stays put', () {
    const thin = (start: 80.0, end: 150.0);
    expect(clearRoomFog(thin, vm.Vector3(0, 1.6, 0)), thin);
  });
}
