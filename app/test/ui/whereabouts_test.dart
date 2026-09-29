import 'package:agent_office/ui/whereabouts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof;

PeerInfo peer(double x, double z, {String? floor, double y = 0, String? seat, String? doing, bool? smoking}) =>
    PeerInfo(
      id: 'p',
      name: 'P',
      color: '#fff',
      look: const Look(skin: 0, hair: 0, style: 0),
      x: x,
      y: y,
      z: z,
      rotY: 0,
      moving: false,
      voice: false,
      muted: false,
      sharing: false,
      floor: floor,
      seat: seat,
      doing: doing,
      smoking: smoking,
    );

void main() {
  test("the roof's corner over the meeting room is a tall table, not the meeting room", () {
    final t = roofTables.firstWhere((t) => t.x > 9 && t.z > 8);
    expect(whereabouts(peer(t.x + 0.7, t.z, floor: 'agent-office')), '🤝 in the meeting room');
    expect(whereabouts(peer(t.x + 0.7, t.z, floor: roof)), '🕯️ at a tall table');
  });

  test('up on the roof, the dance floor and the bar have their own words, and the rest none', () {
    expect(
      whereabouts(peer((DanceFloor.minX + DanceFloor.maxX) / 2, (DanceFloor.minZ + DanceFloor.maxZ) / 2, floor: roof)),
      '🪩 on the dance floor',
    );
    expect(whereabouts(peer(11.5, 0, floor: roof)), '🍸 at the bar');
    expect(whereabouts(peer(0, 3, floor: roof)), isNull);
    expect(whereabouts(peer(12, 0, floor: roof, seat: 'roof-stool-3:0')), '🪑 on the bar stool');
  });

  test('what they have open comes first, then a smoke, then where they are', () {
    expect(whereabouts(peer(0, 20, doing: "💻 in Pixel's terminal")), "💻 in Pixel's terminal");
    expect(whereabouts(peer(0, 20, smoking: true)), '🚬 on a smoke break');
    expect(whereabouts(peer(0, 14)), '🌇 on the balcony');
    expect(whereabouts(peer(15, 15)), '🚶 outside');
    expect(whereabouts(peer(0, 0, y: -3)), '🚶 outside');
    expect(whereabouts(peer(12, 10, y: 3)), "👔 in the boss's office");
    expect(whereabouts(peer(0, 0)), isNull);
  });

  test('what you have open is cut to 60 units between whole characters', () {
    expect(clipDoing(null), isNull);
    expect(clipDoing('📌 at the issues board'), '📌 at the issues board');
    final long = '💻 ${'x' * 57}🙂🙂';
    final cut = clipDoing(long)!;
    expect(cut.endsWith('…'), isTrue);
    expect(cut.length, lessThanOrEqualTo(61));
    expect(cut.contains('\uD83D…'), isFalse);
  });
}
