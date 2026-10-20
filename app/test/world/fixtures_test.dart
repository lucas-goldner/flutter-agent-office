// The build tower on the castle and the space station: in 3D what you use sits clear of its stand,
// and on the 👾 2D map it has its tag.
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/maps/maps.dart';

import 'package:agent_office/office2d/office2d_view.dart' show labelOf;
import 'package:agent_office/world/collider.dart';
import 'package:agent_office/world/fixtures.dart';

void main() {
  test('every fixture opens what the office has, and the 2D map tags it', () {
    expect(fixtureKinds.keys.toSet(), FixtureKey.values.toSet());
    expect({for (final (k, _) in fixtureKinds.values) k}, {InteractKind.build});
    for (final (k, _) in fixtureKinds.values) {
      expect(labelOf(k), isNotNull, reason: '$k has a tag on the 2D map');
    }
  });

  for (final id in ['castle', 'station']) {
    test('on the $id, you stand clear of each stand to use it, within reach', () {
      final plan = planOf(id);
      expect(plan.fixtures.keys.toSet(), FixtureKey.values.toSet());
      for (final MapEntry(key: k, value: f) in plan.fixtures.entries) {
        final c = fixtureCollider(f);
        expect(f.x > c.minX && f.x < c.maxX && f.z > c.minZ && f.z < c.maxZ, isTrue, reason: '${k.wire} is in the way');
        final it = fixtureInteractable(k, f);
        expect(
          it.x > c.minX && it.x < c.maxX && it.z > c.minZ && it.z < c.maxZ,
          isFalse,
          reason: 'in front of ${k.wire}',
        );
        expect(it.kind, fixtureKinds[k]!.$1);
      }
    });
  }
}
