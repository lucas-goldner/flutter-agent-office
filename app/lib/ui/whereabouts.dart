// What a teammate is up to, for the line under their name tag and in the people list. A port of
// ui/whereabouts.ts.

import 'package:office_shared/bargames.dart' show BarGame;
import 'package:office_shared/layout.dart';
import 'package:office_shared/maps/maps.dart' show MapPlan, PlanStyle, seatOn;
import 'package:office_shared/protocol.dart';
import 'package:office_shared/rooftop.dart' show roof;

import '../office/roof_logic.dart' show roofWhereabouts;

/// Whatever they have open ("💻 in Pixel's terminal", "🔀 reading PR #12"), else somewhere worth
/// saying they are ("🌇 on the balcony", "🛋️ on the couch"). Nothing while they're just walking
/// around the office. On a map of its own ([plan]), its own seats, and none of the office's rooms.
String? whereabouts(PeerInfo p, [MapPlan? plan]) {
  if (p.doing != null && p.doing!.isNotEmpty) return p.doing;
  if (p.smoking == true) return '🚬 on a smoke break';
  if (p.golfing == true) return '🏌️ teeing off';
  if (p.throwing != null) return p.throwing == BarGame.darts ? '🎯 playing darts' : '🪓 throwing axes';
  final office = plan == null || plan.style == PlanStyle.office || p.floor == roof;
  final key = p.seat;
  final place = key == null ? null : (office ? seatAt(key) : seatOn(plan, key));
  final seat = place == null ? null : (office ? seatingById : plan.seatingById)[place.seatId];
  if (seat != null) {
    // "🛋️ Couch" -> "🛋️ on the couch".
    final words = seat.label.split(' ');
    return '${words.first} ${seat.game ? 'in' : 'on'} the ${words.skip(1).join(' ').toLowerCase()}';
  }
  // On a map of its own, the office's rooms aren't where they'd be.
  if (!office) return null;
  // The roof is the office's size, but none of its rooms are up there.
  if (p.floor == roof) return roofWhereabouts(p.x, p.z);
  // Down on the street, or out the back door on the stairs down to it.
  if (p.y < -1 || p.x < Floor.minX || p.x > Floor.maxX || p.z < Floor.minZ) return '🚶 outside';
  if (p.z > Floor.maxZ) return p.x >= Balcony.minX && p.x <= Balcony.maxX ? '🌇 on the balcony' : '🚶 outside';
  if (p.y > Loft.y - 0.5 && p.x > Loft.minX && p.z > Loft.minZ) return "👔 in the boss's office";
  if (p.x > MeetingRoom.minX && p.z > MeetingRoom.minZ) return '🤝 in the meeting room';
  return null;
}

/// What you have open, as the office keeps it: at most 60 UTF-16 units, cut between whole characters.
String? clipDoing(String? what) {
  if (what == null || what.length <= 60) return what;
  final cut = StringBuffer();
  for (final ch in what.runes.map(String.fromCharCode)) {
    if (cut.length + ch.length >= 60) break;
    cut.write(ch);
  }
  return '$cut…';
}
