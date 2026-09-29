import 'package:agent_office/ui/emote_wheel.dart';
import 'package:agent_office/world/character.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/emotes.dart';

void main() {
  group('emoteEnvelope', () {
    test('eases in fast, holds, and eases out by the end', () {
      const secs = 2.2;
      expect(emoteEnvelope(0, secs), 0);
      expect(emoteEnvelope(0.09, secs), closeTo(0.5, 1e-9));
      expect(emoteEnvelope(0.18, secs), 1);
      expect(emoteEnvelope(1.1, secs), 1);
      expect(emoteEnvelope(secs - 0.15, secs), closeTo(0.5, 1e-9));
      expect(emoteEnvelope(secs, secs), 0);
      expect(emoteEnvelope(secs + 1, secs), 0);
    });

    test('every emote plays for a couple of seconds, the dance for longest', () {
      for (final e in emotes) {
        expect(e.seconds, inInclusiveRange(1.5, 4));
        expect(emoteEnvelope(e.seconds / 2, e.seconds), 1);
      }
      expect(emotes.map((e) => e.seconds).reduce((a, b) => a > b ? a : b), Emote.dance.seconds);
    });
  });

  test('popCurve overshoots on the way to 1 and stays there', () {
    expect(popCurve(0), closeTo(0, 1e-9));
    expect(popCurve(0.7), greaterThan(1));
    expect(popCurve(1), 1);
    expect(popCurve(3), 1);
  });

  group('the emote wheel', () {
    test('points at the emote in that direction, clockwise from the top, past a dead zone', () {
      expect(emoteAt(0, -80), 0); // up: wave
      expect(emoteAt(0, 80), 3); // down: dance
      expect(emoteAt(10, 5), -1);
      for (var i = 0; i < emotes.length; i++) {
        final at = emoteSpot(i);
        expect(emoteAt(at.dx, at.dy), i);
      }
    });

    test('hold G, point and let go: plays that emote and closes', () {
      var now = 0.0;
      final picked = <Emote>[];
      final toggles = <bool>[];
      final w = EmoteWheel(onPick: picked.add, onToggle: toggles.add, now: () => now);
      w.press();
      expect(w.isOpen, isTrue);
      expect(w.caption.how, 'Point at one, or 1–6');
      w.move(60, 0);
      expect(w.at, emoteAt(60, 0));
      expect(w.caption.how, 'Let go of G');
      now = 600;
      w.release();
      expect(picked, [emotes[emoteAt(60, 0)]]);
      expect(w.isOpen, isFalse);
      expect(toggles, [true, false]);
    });

    test('a quick tap leaves it open to click; a long hold on nothing closes it', () {
      var now = 0.0;
      final picked = <Emote>[];
      final w = EmoteWheel(onPick: picked.add, now: () => now);
      w.press();
      now = 100;
      w.release();
      expect(w.isOpen, isTrue);
      expect(w.caption.how, 'Point at one, or 1–6');
      w.aimAt(0, 90);
      expect(w.caption.how, 'Click');
      w.click();
      expect(picked, [Emote.dance]);
      expect(w.isOpen, isFalse);

      w.press();
      now = 1000;
      w.release();
      expect(w.isOpen, isFalse);
      expect(picked, hasLength(1));
      // G again while it's open closes it.
      w.press();
      now = 1050;
      w.release();
      w.press();
      expect(w.isOpen, isFalse);
    });

    test('captured-mouse aim stays within the ring, so turning back answers at once', () {
      final w = EmoteWheel(onPick: (_) {}, now: () => 0);
      w.press();
      w.move(0, 5000);
      expect(w.at, 3);
      w.move(0, -kEmoteRadius * 2);
      expect(w.at, 0);
    });
  });

  test('EmoteBucket: three in a row, then one every two seconds', () {
    final b = EmoteBucket();
    expect([for (var i = 0; i < 4; i++) b.take(1000)], [true, true, true, false]);
    expect(b.take(2000), isFalse);
    expect(b.take(3000), isTrue);
  });
}
