import 'package:agent_office/audio/dnb_score.dart';
import 'package:agent_office/office/roof_logic.dart';
import 'package:agent_office/ui/hud_parts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/layout.dart';

void main() {
  test('up on the roof, the line under a name says where on the roof they are', () {
    expect(roofWhereabouts(DjBooth.x, DjBooth.z), '🎧 up on the stage');
    expect(roofWhereabouts(-3, -5), '🪩 on the dance floor');
    expect(roofWhereabouts(RoofBar.x - 1.2, 0), '🍸 at the bar');
    expect(roofWhereabouts(roofTables.first.x, roofTables.first.z), '🕯️ at a tall table');
    expect(roofWhereabouts(FirePit.x + 1.5, FirePit.z), '🔥 by the fire');
    expect(roofWhereabouts(0, 0), isNull);
  });

  test("a tall table in the meeting room's corner is a tall table, not the meeting room", () {
    final t = roofTables.firstWhere(
      (t) => t.x > MeetingRoom.minX && t.z > MeetingRoom.minZ,
      orElse: () => roofTables.last,
    );
    expect(roofWhereabouts(t.x, t.z), '🕯️ at a tall table');
  });

  test("the bar's hint turns to water once you've had enough", () {
    final (k, parts) = barHint(false);
    final (k2, parts2) = barHint(true);
    expect(k, isNot(k2));
    expect(parts.whereType<HintKey>().single.label, 'Order a drink');
    expect(parts2.whereType<HintKey>().single.label, 'Ask for water');
  });

  test("the DJ booth's hint follows the set", () {
    final (k, parts) = djHint(djFrame(24 * djBar + 1));
    expect(k, '🔥 the drop');
    expect(parts.whereType<HintAside>().single.text, contains('the drop'));
    expect(parts.whereType<HintKey>().single.label, '📯 Air horn!');
  });
}
