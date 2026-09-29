// The rooftop bar's rules that need no scene: where on the roof someone is (for the line under their
// name), and what the bar's and the DJ booth's hints say. Pure, so it's tested on the Dart VM.

import 'dart:math' as math;

import 'package:office_shared/layout.dart' show DanceFloor, FirePit, RoofBar, Stage, roofTables;

import '../audio/dnb_score.dart';
import '../ui/hud_parts.dart' show HintAside, HintKey, HintPart, HintTitle;

/// Somewhere on the rooftop bar worth saying someone standing at ([x], [z]) is, or null. The roof
/// is the office's size, but none of its rooms are up there (whereabouts.ts's onTheRoof).
String? roofWhereabouts(double x, double z) {
  if (x > Stage.minX && x < Stage.maxX && z < Stage.maxZ) return '🎧 up on the stage';
  if (x > DanceFloor.minX && x < DanceFloor.maxX && z > DanceFloor.minZ && z < DanceFloor.maxZ) {
    return '🪩 on the dance floor';
  }
  if (x > RoofBar.x - 2.5 && z > RoofBar.minZ - 0.5 && z < RoofBar.maxZ + 0.5) return '🍸 at the bar';
  if (roofTables.any((t) => math.sqrt(math.pow(x - t.x, 2) + math.pow(z - t.z, 2)) < 1.3)) return '🕯️ at a tall table';
  if (math.sqrt(math.pow(x - FirePit.x, 2) + math.pow(z - FirePit.z, 2)) < 3.5) return '🔥 by the fire';
  return null;
}

/// The bar's hint: [cutOff] once you've had enough.
(String, List<HintPart>) barHint(bool cutOff) => (
  '$cutOff',
  [
    const HintTitle('🍸 Sky Bar'),
    HintAside(cutOff ? "you've had enough" : 'drinks on the house'),
    HintKey('E', cutOff ? 'Ask for water' : 'Order a drink'),
  ],
);

/// The DJ booth's hint, saying what the set is doing.
(String, List<HintPart>) djHint(DjFrame f) {
  final what = djDoing(f.part);
  return (
    what,
    [const HintTitle('🎧 DJ Merge Conflict'), HintAside('drum & bass · $what'), const HintKey('E', '📯 Air horn!')],
  );
}
