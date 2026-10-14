// Come back where you left (#153): the spot this browser remembers, and what's sent with the floor.

import 'package:agent_office/state/spot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a spot round-trips, and garbage is nothing', () {
    const s = SavedSpot(floor: 'f1', name: 'web', x: 1.5, y: 0, z: -3.25, facing: 0.7);
    final back = SavedSpot.fromJson(s.toJson())!;
    expect((back.floor, back.name, back.x, back.y, back.z, back.facing), ('f1', 'web', 1.5, 0.0, -3.25, 0.7));
    expect(back.map, isNull);
    expect(back.throne, isFalse);
    final throne = SavedSpot.fromJson({...s.toJson(), 'map': 'castle', 'throne': true})!;
    expect((throne.map, throne.throne), ('castle', true));
    expect(SavedSpot.fromJson(null), isNull);
    expect(SavedSpot.fromJson({'floor': '', 'x': 0, 'y': 0, 'z': 0, 'facing': 0}), isNull);
    expect(SavedSpot.fromJson({'floor': 'f', 'x': double.nan, 'y': 0, 'z': 0, 'facing': 0}), isNull);
    expect(SavedSpot.fromJson({'floor': 'f', 'x': 0, 'y': 0, 'z': 0}), isNull, reason: 'no facing');
  });
}
