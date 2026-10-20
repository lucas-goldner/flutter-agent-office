// A label's line of sight (OfficeController.labelBlocked): boxes in the way hide it; the box the
// person stands in, a fence, or nothing at all doesn't.

import 'package:agent_office/world/collider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final wall = Collider(minX: 4, maxX: 4.2, minZ: -10, maxZ: 10, top: 3);
  final herald = Collider(minX: 9.6, maxX: 10.4, minZ: -0.4, maxZ: 0.4, top: 99);

  test('a wall between the eye and the label hides it', () {
    expect(segmentBlocked([wall], 0, 1.6, 0, 10, 1.8, 0), isTrue);
    expect(segmentBlocked([wall], 0, 1.6, 0, 3, 1.8, 0), isFalse, reason: 'this side of the wall');
    expect(segmentBlocked([wall], 0, 4, 0, 10, 4, 0), isFalse, reason: 'over the top of it');
  });

  test("the label's own person, and fences, don't count", () {
    expect(segmentBlocked([herald], 0, 1.6, 0, 10, 2.1, 0), isFalse);
    expect(
      segmentBlocked([Collider(minX: 4, maxX: 4.2, minZ: -10, maxZ: 10, top: 3, fence: true)], 0, 1.6, 0, 10, 1.8, 0),
      isFalse,
    );
    expect(segmentBlocked(const [], 0, 0, 0, 1, 1, 1), isFalse);
  });

  test('a box off to the side, or one you walk beneath, is not in the way', () {
    expect(segmentBlocked([Collider(minX: 4, maxX: 5, minZ: 3, maxZ: 4, top: 3)], 0, 1.6, 0, 10, 1.8, 0), isFalse);
    expect(
      segmentBlocked([Collider(minX: 4, maxX: 5, minZ: -1, maxZ: 1, top: 4, bottom: 2.5)], 0, 1.6, 0, 10, 1.8, 0),
      isFalse,
    );
  });
}
