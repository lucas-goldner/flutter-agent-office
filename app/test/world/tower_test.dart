// The building from outside: which floors stand round the one you're on, and the haze with height.
import 'package:agent_office/world/office/office_colliders.dart';
import 'package:agent_office/world/office/tower.dart';
import 'package:agent_office/world/player.dart';
import 'package:agent_office/world/sky_view.dart' show hazeFog, hazeMax, hazeReach;
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

void main() {
  test('every floor but yours stands a storey apart, with the top over the highest', () {
    final plan = towerPlan(1, 4);
    expect([for (final f in plan.floors) f.k], [0, 2, 3]);
    expect([for (final f in plan.floors) f.y0], [-storey, storey, 2 * storey]);
    expect(plan.top, closeTo(2 * storey + wallHeight, 1e-9));
    // Alone in the building: nothing but the cornice over you.
    expect(towerPlan(0, 1).floors, isEmpty);
    expect(towerPlan(0, 1).top, wallHeight);
    // Up on the roof: every floor below, and no top (the roof is its own).
    final roof = towerPlan(3, 3);
    expect(roof.floors.map((f) => f.y0), [-3 * storey, -2 * storey, -storey]);
    expect(roof.top, isNull);
  });

  test('from an upper floor the walls below keep you out of the garage from the steps', () {
    expect(towerColliders(0, 3), isEmpty);
    final cs = towerColliders(2, 3);
    expect(cs, hasLength(5));
    final bottom = -2 * storey - slab;
    expect(cs.every((c) => c.bottom == bottom), isTrue);
    // The bottom floor's slab, the garage's ceiling, is solid from out there.
    expect(cs.last.top, closeTo(bottom + slab, 1e-9));
  });

  test('the street is a floor, however far down it goes', () {
    final street = streetColliders();
    expect(groundAt(street, 30, 40, 0), streetY);
    expect(groundAt(street, 500, 500, 0), double.negativeInfinity);
    expect(
      groundColliders(),
      hasLength(
        exitStairsColliders().length + balconyPostColliders().length + garageColliders().length + street.length,
      ),
    );
  });

  test('the haze thins out with height over the street', () {
    expect(hazeReach(1.4, streetY), 1);
    expect(hazeReach(streetY + 6 + 17.5, streetY), closeTo(2, 1e-9));
    // From the roof of six floors, 3.4 times as far.
    final eye = 1.4;
    expect(hazeReach(eye, -roofDrop(6)), closeTo(1 + (eye + roofDrop(6) - 6) / 17.5, 1e-9));
    final f = hazeFog(40, 90, 200, streetY);
    expect(f.end, hazeMax);
    expect(f.start, lessThan(f.end));
    expect(hazeFog(40, 90, 0, streetY).end, 90);
  });
}
